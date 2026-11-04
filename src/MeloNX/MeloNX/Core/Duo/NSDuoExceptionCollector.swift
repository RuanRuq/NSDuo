import Foundation
import CryptoKit
@preconcurrency import MetricKit

// Do not install signal/Mach handlers here: the JIT and guest memory tracker
// own them. System crash reports arrive through MetricKit when available.
nonisolated final class NSDuoExceptionCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = NSDuoExceptionCollector()
    private static let installation: Void = { shared.install() }()
    private let queue = DispatchQueue(label: "NSDuo.exception-reports", qos: .utility)
    private let receivedKey = "NSDuo.diagnostics.receivedSystemReports"
    private var previousExceptionHandler: NSUncaughtExceptionHandler?

    private struct CrashReport: Sendable {
        let period: String
        let date: Date
        let data: Data
        let details: String
    }

    static func start() { _ = installation }

    private func install() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // Objective-C exception callbacks are not POSIX signal callbacks.
            // Persist directly; do not wait for a dispatch queue during unwind.
            NSDuoExceptionCollector.shared.record(exception)
        }
        let manager = MXMetricManager.shared
        manager.add(self)
        // Reports not delivered while the app was dead can be available here.
        didReceive(manager.pastDiagnosticPayloads)
    }

    private func record(_ exception: NSException) {
        let details = "name=\(exception.name.rawValue)\nreason=\(exception.reason ?? "unknown")\nmain_thread=\(Thread.isMainThread); thread=\(Thread.current.name ?? "unnamed")\n" + exception.callStackSymbols.joined(separator: "\n")
        _ = try? NSDuoDiagnosticFiles.storeAppReport(id: UUID().uuidString, title: "App 未捕获异常",
            source: "objc_uncaught_exception", details: details)
        previousExceptionHandler?(exception)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Snapshot the immutable system objects into Sendable values before
        // handing file IO to our serial queue.
        let reports = payloads.flatMap { payload in
            (payload.crashDiagnostics ?? []).map { diagnostic in
                CrashReport(period: "\(payload.timeStampBegin.timeIntervalSince1970)-\(payload.timeStampEnd.timeIntervalSince1970)",
                    date: payload.timeStampEnd, data: diagnostic.jsonRepresentation(),
                    details: "System crash report; delivery may be delayed.\nreporting_period_begin=\(payload.timeStampBegin)\nreporting_period_end=\(payload.timeStampEnd)\ncrashed_app_version=\(diagnostic.applicationVersion)\nexception_type=\(diagnostic.exceptionType?.stringValue ?? "unknown"); exception_code=\(diagnostic.exceptionCode?.stringValue ?? "unknown"); signal=\(diagnostic.signal?.stringValue ?? "unknown")\ntermination_reason=\(diagnostic.terminationReason ?? "unknown")\nThis period does not identify a specific game session. See system-crash.json for call stacks.")
            }
        }
        queue.async { [self] in
            var received = UserDefaults.standard.stringArray(forKey: receivedKey) ?? []
            for report in reports {
                // Normalize JSON ordering before hashing repeated deliveries.
                var canonical = report.data
                if report.data.count <= 2 * 1024 * 1024,
                   let object = try? JSONSerialization.jsonObject(with: report.data),
                   let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    canonical = sorted
                }
                // Include the reporting period: identical crash stacks on
                // different days must remain separate reports.
                let id = SHA256.hash(data: Data(report.period.utf8) + canonical).map { String(format: "%02x", $0) }.joined()
                guard !received.contains(id) else { continue }
                do {
                    try NSDuoDiagnosticFiles.storeAppReport(id: id, title: "App 系统崩溃报告",
                        source: "metrickit_crash", details: report.details, date: report.date, report: report.data)
                    received.append(id)
                    // Keep deduplication outside the clearable log directory
                    // so clearing logs does not reimport historical reports.
                    received = Array(received.suffix(100))
                    UserDefaults.standard.set(received, forKey: receivedKey)
                } catch {
                    // A failed write remains eligible for later delivery.
                    print("Unable to save system crash report: \(error.localizedDescription)")
                }
            }
        }
    }

    func flushPendingReports() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
