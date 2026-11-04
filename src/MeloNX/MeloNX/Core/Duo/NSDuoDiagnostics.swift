import Foundation
import UIKit
import os

@_silgen_name("nsduo_diagnostics_mark")
private func markDiagnosticProblem()
@_silgen_name("nsduo_diagnostics_environment")
private func recordDiagnosticEnvironment(_ thermal: Int32, _ lowPower: Int32, _ appState: Int32, _ memoryWarning: Int32)
@_silgen_name("nsduo_memory_budget")
private func recordMemoryBudget(_ availableBytes: UInt64, _ memoryWarning: Int32)
@_silgen_name("nsduo_diagnostics_motion")
nonisolated private func recordDiagnosticMotion(_ source: Int32, _ state: Int32)

enum NSDuoDiagnostics {
    // source: 1 phone, 2 controller; state: -2 sensor error, -1 unavailable, 1 submitting.
    nonisolated static func recordMotion(source: Int32, state: Int32) { recordDiagnosticMotion(source, state) }
    static func markProblem() { markDiagnosticProblem() }
    static func recordEnvironment(memoryWarning: Bool = false) {
        recordMemoryBudget(UInt64(os_proc_available_memory()), memoryWarning ? 1 : 0)
        recordDiagnosticEnvironment(Int32(ProcessInfo.processInfo.thermalState.rawValue),
                                    ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
                                    Int32(UIApplication.shared.applicationState.rawValue), memoryWarning ? 1 : 0)
    }
}

nonisolated struct NSDuoDiagnosticRecord: Identifiable, Sendable {
    let directory: URL
    let title: String
    let date: Date
    let hasProblem: Bool
    let unfinished: Bool
    var id: String { directory.lastPathComponent }
}

nonisolated enum NSDuoDiagnosticFiles {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Diagnostics", isDirectory: true)
    }

    static var exports: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DiagnosticExports", isDirectory: true)
    }

    // App-level failures are ordinary diagnostic records, including failures
    // before a game starts. Commit info.txt last so readers never export a
    // half-written report. A stable MetricKit ID makes repeated delivery safe.
    @discardableResult
    static func storeAppReport(id: String, title: String, source: String, details: String,
                               date: Date = Date(), report: Data? = nil, diagnostics directory: URL = root) throws -> URL {
        guard id.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try requireDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let folder = directory.appendingPathComponent("\(formatter.string(from: date))-\(id)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try requireDirectory(folder)
        let info = folder.appendingPathComponent("info.txt")
        if fm.fileExists(atPath: info.path) { return folder }
        var committed = false
        defer { if !committed { try? fm.removeItem(at: folder) } }

        let timestamp = ISO8601DateFormatter.diagnostics.string(from: date)
        var log = "\(timestamp)\tapp_exception\tsource=\(sanitized(source)); received_at=\(ISO8601DateFormatter.diagnostics.string(from: Date()))\n"
        log += sanitized(String(details.prefix(32 * 1024))) + "\n"
        if details.count > 32 * 1024 { log += "[exception details truncated]\n" }
        if let report {
            // Decode before redacting to preserve valid JSON and call stacks.
            if report.count <= 2 * 1024 * 1024 {
                let object = try JSONSerialization.jsonObject(with: report)
                let data = try JSONSerialization.data(withJSONObject: sanitizedJSON(object), options: [.prettyPrinted, .sortedKeys])
                if data.count <= 2 * 1024 * 1024 {
                    try data.write(to: folder.appendingPathComponent("system-crash.json"), options: .atomic)
                } else { log += "[system report exceeds 2 MiB after redaction; summary retained]\n" }
            } else { log += "[system report exceeds 2 MiB; summary retained]\n" }
        }
        try Data(log.utf8).write(to: folder.appendingPathComponent("current.log"), options: .atomic)
        try Data("Exception report collected; inspect the log and attached system report.".utf8)
            .write(to: folder.appendingPathComponent("problem"), options: .atomic)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let metadata = "\(sanitized(title).replacingOccurrences(of: "\n", with: " "))\n\(timestamp)\nsource=\(sanitized(source)); app=\(version); build=\(build); os=\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        try Data(metadata.utf8).write(to: info, options: .atomic)
        committed = true
        // Never delete a live core's directory from a MetricKit callback.
        let completedProblems = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
                    && fm.fileExists(atPath: url.appendingPathComponent("info.txt").path)
                    && fm.fileExists(atPath: url.appendingPathComponent("problem").path)
                    && !fm.fileExists(atPath: url.appendingPathComponent("running").path)
            }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in completedProblems.dropFirst(10) { try? fm.removeItem(at: old) }
        return folder
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
    }

    private static func sanitized(_ value: String) -> String {
        let paths = value.replacingOccurrences(of: #"/[^\s"']+"#, with: "[path]", options: .regularExpression)
        return paths.replacingOccurrences(of: #"(?i)(password|token|secret|private_key|prod_key|pairing)\s*[:=]\s*\S+"#,
            with: "$1=[redacted]", options: .regularExpression)
    }

    private static func sanitizedJSON(_ value: Any) -> Any {
        if let string = value as? String { return sanitized(string) }
        if let array = value as? [Any] { return array.map { sanitizedJSON($0) } }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let sensitive = entry.key.range(of: #"(?i)^(password|token|secret|private_key|prod_key|pairing)$"#, options: .regularExpression) != nil
                result[entry.key] = sensitive ? "[redacted]" : sanitizedJSON(entry.value)
            }
        }
        return value
    }

    // Available from the library, after the emulation session has ended.
    // Keep the two log directories in place so future sessions record normally.
    static func clear(diagnostics directory: URL = root, exports exportDirectory: URL = exports) throws {
        let fm = FileManager.default
        for folder in [directory, exportDirectory] {
            guard fm.fileExists(atPath: folder.path) else { continue }
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteNoPermission)
            }
            for child in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: child)
            }
        }
    }

    static func records() throws -> [NSDuoDiagnosticRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true && fm.fileExists(atPath: url.appendingPathComponent("info.txt").path)
            }.map { url in
                let data = try readBounded(url.appendingPathComponent("info.txt"), limit: 8192)
                let info = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).components(separatedBy: "\n")
                let date = info.count > 1 ? ISO8601DateFormatter.diagnostics.date(from: info[1]) : nil
                return NSDuoDiagnosticRecord(directory: url, title: info.first ?? "游戏记录",
                    date: date ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                    hasProblem: fm.fileExists(atPath: url.appendingPathComponent("problem").path),
                    unfinished: fm.fileExists(atPath: url.appendingPathComponent("running").path))
            }.sorted { $0.date > $1.date }
    }

    static func export(_ record: NSDuoDiagnosticRecord) throws -> URL {
        try export([record])
    }

    static func export(_ records: [NSDuoDiagnosticRecord], exports folder: URL = exports) throws -> URL {
        // Export only the allowlisted diagnostic files, never the game container or keys.
        guard !records.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = records.count == 1 ? "NSDuo-\(records[0].id).txt" : "NSDuo-诊断日志-\(UUID().uuidString).txt"
        let destination = folder.appendingPathComponent(filename)
        var data = Data("NS Duo 本地诊断 / Local diagnostics\n未正常结束可能是闪退、强制退出或系统终止；长时间无帧也可能是正常加载。\n".utf8)
        for record in records {
            guard fm.fileExists(atPath: record.directory.appendingPathComponent("info.txt").path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            data.append(Data("\n=== 运行记录 / Session: \(record.id) ===\n".utf8))
            for name in ["info.txt", "problem", "running", "previous.log", "current.log", "exceptions.log", "fatal.log", "system-crash.json"] {
                let url = record.directory.appendingPathComponent(name)
                guard fm.fileExists(atPath: url.path) else { continue }
                data.append(Data("\n--- \(name) ---\n".utf8))
                data.append(try readBounded(url, limit: 2 * 1024 * 1024 + 8192))
            }
        }
        try data.write(to: destination, options: .atomic)
        // Limit temporary exports independently from the retained source sessions.
        let old = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "txt" && $0 != destination }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for url in old.dropFirst(2) { try? fm.removeItem(at: url) }
        return destination
    }

    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }
}

private extension ISO8601DateFormatter {
    nonisolated static var diagnostics: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
