import Foundation
import UIKit
import os

@_silgen_name("nsduo_diagnostics_mark")
private func markDiagnosticProblem()
@_silgen_name("nsduo_diagnostics_environment")
private func recordDiagnosticEnvironment(_ thermal: Int32, _ lowPower: Int32, _ appState: Int32, _ memoryWarning: Int32)
@_silgen_name("nsduo_memory_budget")
private func recordMemoryBudget(_ availableBytes: UInt64, _ memoryWarning: Int32)

enum NSDuoDiagnostics {
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

    static func export(_ records: [NSDuoDiagnosticRecord]) throws -> URL {
        // Export only the allowlisted diagnostic files, never the game container or keys.
        guard !records.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let fm = FileManager.default
        let folder = exports
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = records.count == 1 ? "NSDuo-\(records[0].id).txt" : "NSDuo-诊断日志-\(UUID().uuidString).txt"
        let destination = folder.appendingPathComponent(filename)
        var data = Data("NS Duo 本地诊断 / Local diagnostics\n未正常结束可能是闪退、强制退出或系统终止；长时间无帧也可能是正常加载。\n".utf8)
        for record in records {
            guard fm.fileExists(atPath: record.directory.appendingPathComponent("info.txt").path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            data.append(Data("\n=== 运行记录 / Session: \(record.id) ===\n".utf8))
            for name in ["info.txt", "problem", "running", "previous.log", "current.log"] {
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
