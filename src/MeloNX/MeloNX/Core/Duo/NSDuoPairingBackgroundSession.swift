import Foundation
import BackgroundTasks

/// Keeps a user-initiated pairing executable while Settings is in the foreground.
@MainActor
final class NSDuoPairingBackgroundSession {
    static let shared = NSDuoPairingBackgroundSession()

    private var preparedIdentifier: String?
    private var requestID: String?
    private var processingTask: BGTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var submission: Task<Void, Never>?
    private var launchTimeout: DispatchWorkItem?
    private var expiration: (() -> Void)?

    var isActive: Bool { processingTask != nil }
    private var identifierPrefix: String { (Bundle.main.bundleIdentifier ?? "com.nsduo") + ".pairing." }

    func register() {
        guard #available(iOS 27, *), preparedIdentifier == nil, requestID == nil else { return }
        // The wildcard belongs only in Info.plist. Registration and submission
        // must both use this same concrete identifier, including its suffix.
        let identifier = identifierPrefix + UUID().uuidString
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated { self?.accept(task) }
        }
        recordRegistration(identifier: identifier, accepted: accepted)
        if accepted { preparedIdentifier = identifier }
    }

    func begin(onExpiration: @escaping () -> Void) async throws {
        guard #available(iOS 27, *) else { throw failure("本机配对需要 iOS / iPadOS 27 或更高版本。") }
        guard requestID == nil else { throw failure("已有配对后台任务正在运行，请等待它结束。") }
        register()
        guard let id = preparedIdentifier else {
            throw failure("系统未能注册本次配对任务，请重新点击重试。诊断记录中已保存注册结果。")
        }
        try Task.checkCancellation()
        preparedIdentifier = nil
        requestID = id
        expiration = onExpiration

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting in
                continuation = waiting
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.requestID == id, self.continuation != nil else { return }
                    self.rejectStart(self.failure("系统未能及时启动配对后台任务，请保持 NS Duo 在前台后重试。"))
                }
                launchTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
                submission = Task { [weak self] in
                    do {
                        // Construct and submit the request away from the main executor.
                        try await Task.detached(priority: .userInitiated) {
                            let request = BGContinuedProcessingTaskRequest(identifier: id,
                                title: "NS Duo 本机配对", subtitle: "正在准备与系统设置连接…")
                            request.strategy = .fail
                            try await BGTaskScheduler.shared.submitTaskRequest(request)
                        }.value
                    } catch {
                        guard let self, self.requestID == id, self.continuation != nil else { return }
                        let code = (error as NSError).code
                        self.rejectStart(self.failure("系统暂时无法运行配对后台任务（错误 \(code)）。请检查 NS Duo 的后台运行设置后重试。"))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPendingStart() }
        }
    }

    @available(iOS 27, *)
    private func accept(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask,
              requestID == task.identifier, continuation != nil else {
            task.setTaskCompleted(success: false)
            return
        }
        processingTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 10
        let id = task.identifier
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                self.expiration?()
                self.finish(success: false)
            }
        }
        launchTimeout?.cancel()
        launchTimeout = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }

    func update(subtitle: String, completedUnits: Int64) {
        guard #available(iOS 27, *), let task = processingTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, min(completedUnits, 95))
        task.updateTitle("NS Duo 本机配对", subtitle: subtitle)
    }

    func cancelPendingStart() {
        guard continuation != nil else { return }
        rejectStart(CancellationError())
    }

    func finish(success: Bool) {
        launchTimeout?.cancel()
        launchTimeout = nil
        submission?.cancel()
        submission = nil
        if let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID) }
        requestID = nil
        expiration = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(throwing: CancellationError())
        let task = processingTask
        processingTask = nil
        if #available(iOS 27, *), let task = task as? BGContinuedProcessingTask {
            task.updateTitle("NS Duo 本机配对", subtitle: success ? "配对记录已保存，请返回 NS Duo" : "配对已结束，请返回 NS Duo")
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        }
        task?.setTaskCompleted(success: success)
    }

    private func rejectStart(_ error: Error) {
        let waiting = continuation
        continuation = nil
        finish(success: false)
        waiting?.resume(throwing: error)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "NSDuoOnDevicePairing", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func recordRegistration(identifier: String, accepted: Bool) {
        // Configuration evidence only: no PIN, pairing file, device ID or keys.
        let record: [String: Any] = [
            "registered": accepted,
            "identifier": identifier,
            "permittedIdentifiers": Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [],
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NSDuoPairing", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("registration.json"), options: .atomic)
        } catch { print("NSDuo pairing registration diagnostics could not be saved.") }
    }
}
