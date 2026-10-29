import Foundation

// A queued sample belongs to one activation only. Disabling waits for any
// in-flight native submission, then rejects all samples from that generation.
nonisolated final class ControllerMotionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0

    func setActive(_ value: Bool) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard active != value else { return nil }
        active = value
        generation &+= 1
        return generation
    }

    @discardableResult
    func withActive(_ expected: UInt64, _ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, expected == generation else { return false }
        action()
        return true
    }
}
