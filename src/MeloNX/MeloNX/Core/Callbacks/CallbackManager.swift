import Foundation

/// Native code carries an opaque registration ID, never a retained Swift pointer.
/// A callback already in flight keeps its local box alive; stale IDs become no-ops.
@dynamicMemberLookup
nonisolated final class CallbackManager {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var nextID: UInt = 0
        var names: [String: UInt] = [:]
        var handlers: [UInt: CallbackBox] = [:]
    }
    private static let registry = Registry()
    private static let callback: DataCallbackFn = { rawPtr, userData in
        guard let userData else { return }
        let id = UInt(bitPattern: userData)
        CallbackManager.registry.lock.lock()
        let box = CallbackManager.registry.handlers[id]
        CallbackManager.registry.lock.unlock()
        guard let box else { return }
        let data = rawPtr.map { $0.loadUnaligned(as: CallbackData.self) } ?? CallbackData(ptr: nil, len: 0)
        box.body(data)
    }

    static subscript(dynamicMember name: String) -> (@escaping (CallbackData) -> Void) -> Void {
        { handler in register(name: name, handler: handler) }
    }

    @discardableResult
    static func register(name: String, handler: @escaping (CallbackData) -> Void) -> UInt {
        registry.lock.lock()
        // IDs are never reused, including after unregistering.
        precondition(registry.nextID < UInt.max)
        registry.nextID += 1
        let id = registry.nextID
        let oldID = registry.names.updateValue(id, forKey: name)
        registry.handlers[id] = CallbackBox(handler)
        name.withCString { RegisterCallback($0, callback, UnsafeMutableRawPointer(bitPattern: id)) }
        let oldBox = oldID.flatMap { registry.handlers.removeValue(forKey: $0) }
        registry.lock.unlock()
        withExtendedLifetime(oldBox) {} // Release captured objects outside the registry lock.
        return id
    }

    /// The token prevents an old view from unregistering a newer subscription.
    static func unregister(name: String, token: UInt? = nil) {
        registry.lock.lock()
        guard let id = registry.names[name], token == nil || token == id else {
            registry.lock.unlock()
            return
        }
        name.withCString { UnregisterCallback($0) }
        registry.names.removeValue(forKey: name)
        let box = registry.handlers.removeValue(forKey: id)
        registry.lock.unlock()
        withExtendedLifetime(box) {}
    }
}
