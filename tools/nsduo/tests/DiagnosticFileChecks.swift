import Foundation

@main
enum DiagnosticFileChecks {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let fm = FileManager.default
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("clear-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let diagnostics = fixture.appendingPathComponent("Documents/Diagnostics", isDirectory: true)
        let exports = fixture.appendingPathComponent("Library/Caches/DiagnosticExports", isDirectory: true)
        let protected = fixture.appendingPathComponent("GamesAndSaves", isDirectory: true)
        try fm.createDirectory(at: protected, withIntermediateDirectories: true)
        let sentinel = protected.appendingPathComponent("save.dat")
        try Data("preserved".utf8).write(to: sentinel)

        // Empty first-use and repeated clearing are harmless.
        try NSDuoDiagnosticFiles.clear(diagnostics: diagnostics, exports: exports)
        for directory in [diagnostics.appendingPathComponent("old-session"), exports] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("log".utf8).write(to: diagnostics.appendingPathComponent("old-session/current.log"))
        try Data("report".utf8).write(to: exports.appendingPathComponent("NSDuo-report.txt"))
        try fm.createSymbolicLink(at: diagnostics.appendingPathComponent("outside-link"), withDestinationURL: protected)
        try fm.createSymbolicLink(at: diagnostics.appendingPathComponent("old-session/nested-link"), withDestinationURL: protected)

        try NSDuoDiagnosticFiles.clear(diagnostics: diagnostics, exports: exports)
        try NSDuoDiagnosticFiles.clear(diagnostics: diagnostics, exports: exports)
        check(try fm.contentsOfDirectory(atPath: diagnostics.path).isEmpty)
        check(try fm.contentsOfDirectory(atPath: exports.path).isEmpty)
        check(try Data(contentsOf: sentinel) == Data("preserved".utf8))

        // App reports use the same bounded, allowlisted export as game sessions.
        let report = try NSDuoDiagnosticFiles.storeAppReport(id: "fixture", title: "App 异常",
            source: "objc_exception", details: "reason /private/container/game.nsp token=abcd\nframe at App.main",
            date: Date(timeIntervalSince1970: 100), diagnostics: diagnostics)
        let first = try Data(contentsOf: report.appendingPathComponent("current.log"))
        check(String(decoding: first, as: UTF8.self).contains("App.main"))
        check(!String(decoding: first, as: UTF8.self).contains("abcd"))
        let repeated = try NSDuoDiagnosticFiles.storeAppReport(id: "fixture", title: "App 异常",
            source: "objc_exception", details: "duplicate", date: Date(timeIntervalSince1970: 100), diagnostics: diagnostics)
        let repeatedData = try Data(contentsOf: report.appendingPathComponent("current.log"))
        check(repeated == report && repeatedData == first)
        check(fm.fileExists(atPath: report.appendingPathComponent("problem").path))
        try Data("managed stack".utf8).write(to: report.appendingPathComponent("fatal.log"))
        try Data("core error".utf8).write(to: report.appendingPathComponent("exceptions.log"))
        try Data("never export this".utf8).write(to: report.appendingPathComponent("private.key"))
        let record = NSDuoDiagnosticRecord(directory: report, title: "App 异常", date: Date(), hasProblem: true, unfinished: false)
        let exported = try NSDuoDiagnosticFiles.export([record], exports: exports)
        let exportedText = String(decoding: try Data(contentsOf: exported), as: UTF8.self)
        check(exportedText.contains("managed stack") && exportedText.contains("core error"))
        check(!exportedText.contains("never export this"))
        let systemReport = try NSDuoDiagnosticFiles.storeAppReport(id: "system-fixture", title: "系统报告",
            source: "metrickit_crash", details: "summary", report: Data(#"{"token":"secret-value","stack":"App.main"}"#.utf8), diagnostics: diagnostics)
        let systemText = String(decoding: try Data(contentsOf: systemReport.appendingPathComponent("system-crash.json")), as: UTF8.self)
        check(!systemText.contains("secret-value") && systemText.contains("App.main"))
        do {
            _ = try NSDuoDiagnosticFiles.storeAppReport(id: "../escape", title: "App 异常",
                source: "fixture", details: "", diagnostics: diagnostics)
            fatalError("Report IDs must not escape the diagnostic root")
        } catch is CocoaError { }

        // Root directories survive, so the next recording can write normally.
        let next = diagnostics.appendingPathComponent("next-session", isDirectory: true)
        try fm.createDirectory(at: next, withIntermediateDirectories: true)
        try Data("next log".utf8).write(to: next.appendingPathComponent("current.log"))
        precondition(fm.fileExists(atPath: next.appendingPathComponent("current.log").path))

        // A replaced root must not redirect deletion into another directory.
        let linkedRoot = fixture.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: protected)
        do {
            try NSDuoDiagnosticFiles.clear(diagnostics: linkedRoot, exports: exports)
            fatalError("A symlink root must be rejected")
        } catch is CocoaError { }
        do {
            try NSDuoDiagnosticFiles.clear(diagnostics: diagnostics, exports: sentinel)
            fatalError("A regular file cannot be treated as an export directory")
        } catch is CocoaError { }
        check(try Data(contentsOf: sentinel) == Data("preserved".utf8))
        print("PASS diagnostic clearing: scoped deletion, nested symlinks, protected files, repeated clearing, future recording and errors")
    }
}
