import SwiftUI
import Foundation
import Combine

nonisolated private final class StatisticsDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let includeMetrics: Bool
    private var lastStarted: Bool?

    init(includeMetrics: Bool) { self.includeMetrics = includeMetrics }

    func shouldDeliver(started: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = lastStarted != started
        lastStarted = started
        return includeMetrics || changed
    }
}

@MainActor
final class StatisticsHandler: ObservableObject {
    @Published private(set) var fps: Double = 0
    @Published private(set) var frameTime: Double = 0
    @Published private(set) var started = false
    @Published private(set) var fifo: Double = 0
    private var registration: UInt?
    private var session: UUID?

    func registerPush(includeMetrics: Bool = true) {
        unregisterPush()
        if started { started = false }
        let session = UUID()
        self.session = session
        let gate = StatisticsDeliveryGate(includeMetrics: includeMetrics)
        registration = CallbackManager.register(name: "push_statistics") { [weak self] data in
            guard let ptr = data.ptr, data.len >= 25 else { return }
            let started = ptr.load(fromByteOffset: 16, as: UInt8.self) != 0
            guard gate.shouldDeliver(started: started) else { return }
            let fps = includeMetrics ? ptr.loadUnaligned(fromByteOffset: 0, as: Double.self) : 0
            let frameTime = includeMetrics ? ptr.loadUnaligned(fromByteOffset: 8, as: Double.self) : 0
            let fifo = includeMetrics ? ptr.loadUnaligned(fromByteOffset: 17, as: Double.self) : 0
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                if self.started != started { self.started = started }
                if includeMetrics {
                    if self.fps != fps { self.fps = fps }
                    if self.frameTime != frameTime { self.frameTime = frameTime }
                    if self.fifo != fifo { self.fifo = fifo }
                }
            }
        }
    }

    func unregisterPush() {
        session = nil
        if let registration { CallbackManager.unregister(name: "push_statistics", token: registration) }
        registration = nil
    }

    deinit {
        if let registration { CallbackManager.unregister(name: "push_statistics", token: registration) }
    }

    func formatFPS() -> String { String(format: "FPS: %.2f", fps) }
}
