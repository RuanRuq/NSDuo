import Foundation

nonisolated struct NSDuoTouchSlots<Key: Hashable> {
    private var slots: [Key: Int] = [:]
    mutating func begin(_ key: Key) -> Int? {
        if let id = slots[key] { return id }
        guard let id = (0..<16).first(where: { !slots.values.contains($0) }) else { return nil }
        slots[key] = id
        return id
    }
    func index(for key: Key) -> Int? { slots[key] }
    mutating func end(_ key: Key) -> Int? { slots.removeValue(forKey: key) }
    mutating func releaseAll() -> [Int] {
        let ids = Array(slots.values)
        slots.removeAll(keepingCapacity: true)
        return ids
    }
}
