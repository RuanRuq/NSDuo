import Foundation
import Combine

nonisolated struct NSDuoCheatEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let name: String
    let instructions: [String]
    let isMaster: Bool
    var isEnabled = false
}

nonisolated struct NSDuoCheatGroup: Codable, Identifiable, Equatable, Sendable {
    let buildID: String
    var entries: [NSDuoCheatEntry]
    // Optional fields keep records imported before editor persistence readable.
    var sourceText: String? = nil
    var sourceDefaultName: String? = nil
    var id: String { buildID }

    var editableSource: String {
        if let sourceText, !sourceText.isEmpty { return sourceText }
        return entries.map { entry in
            let header = entry.isMaster ? "{\(entry.name)}" : "[\(entry.name)]"
            return ([header] + entry.instructions).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

nonisolated struct NSDuoCheatDocument: Codable, Equatable, Sendable {
    var version = 1
    var groups: [NSDuoCheatGroup] = []

    var runtimeGroups: [NSDuoCheatRuntimeGroup] {
        groups.map { group in
            let needsMaster = group.entries.contains { !$0.isMaster && $0.isEnabled }
            // Atmosphère runs the master section before the selected functions.
            let ordered = group.entries.filter(\.isMaster) + group.entries.filter { !$0.isMaster }
            return NSDuoCheatRuntimeGroup(buildID: group.buildID, entries: ordered.map {
                NSDuoCheatRuntimeEntry(id: $0.id.uuidString, name: $0.name, instructions: $0.instructions,
                                      enabled: $0.isMaster ? needsMaster : $0.isEnabled)
            })
        }
    }
}

nonisolated enum NSDuoCheatParser {
    static let maximumTextBytes = 512 * 1024

    static func buildID(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 16, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            throw failure("Build ID 需要填写 16 位十六进制字符，请使用金手指原文件的文件名（不含 .txt）。")
        }
        return value
    }

    static func parse(_ text: String, buildID: String, defaultName: String) throws -> NSDuoCheatGroup {
        let build = try self.buildID(buildID)
        guard !text.isEmpty, text.utf8.count <= maximumTextBytes else {
            throw failure("请粘贴金手指内容，最多支持 512 KB。")
        }
        var entries: [NSDuoCheatEntry] = []
        var name = defaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "自定义金手指" }
        var master = false
        var instructions: [String] = []
        var hasHeader = false
        var names = Set<String>()
        func appendSection() throws {
            guard !instructions.isEmpty else {
                if hasHeader { throw failure("“\(name)”没有代码，请补全后再导入。") }
                return
            }
            guard !name.isEmpty, name.count <= 120, names.insert(name).inserted, entries.count < 256 else {
                throw failure("功能名称不能重复或超过 120 字，每个版本最多支持 256 项。")
            }
            entries.append(NSDuoCheatEntry(name: name, instructions: instructions, isMaster: master))
        }
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            guard index < 20_000 else { throw failure("金手指内容超过 20000 行，请分版本整理后导入。") }
            var line = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.hasPrefix("[") && !line.hasPrefix("{") {
                for marker in ["//", "#", ";"] {
                    if let range = line.range(of: marker) { line = String(line[..<range.lowerBound]) }
                }
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") || line.hasPrefix("{") {
                try appendSection()
                master = line.hasPrefix("{")
                guard line.hasSuffix(master ? "}" : "]"), line.count > 2 else {
                    throw failure("第 \(index + 1) 行的功能名称格式有误，请使用 [功能名称] 或 {基础代码名称}。")
                }
                name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                hasHeader = true
                instructions = []
            } else {
                let words = line.split(whereSeparator: { $0.isWhitespace })
                guard (1...4).contains(words.count), words.allSatisfy({ word in
                    word.utf8.count == 8 && word.utf8.allSatisfy {
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    }
                }) else { throw failure("第 \(index + 1) 行不是有效的 Atmosphère 代码。每组数字需要 8 位十六进制字符。") }
                guard instructions.count < 16_384 else { throw failure("单个功能最多支持 16384 行代码。") }
                instructions.append(words.joined(separator: " ").uppercased())
            }
        }
        try appendSection()
        guard entries.contains(where: { !$0.isMaster }) else {
            throw failure("没有可选择的功能。请使用 [功能名称] 加完整代码；{名称} 仅用于随功能启用的基础代码。")
        }
        return NSDuoCheatGroup(buildID: build, entries: entries, sourceText: text,
                              sourceDefaultName: defaultName)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "NSDuoCheats", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Owns saved choices and the one startup restore task, independently of sheets.
@MainActor
final class NSDuoCheatStore: ObservableObject {
    static let shared = NSDuoCheatStore()
    @Published var message: String?
    private var sessionTask: Task<Void, Never>?
    private var sessionID: UUID?

    private init() {}

    func load(for game: NSDuoLibraryGame) async throws -> NSDuoCheatDocument {
        try await NSDuoLibraryWorker.run { try NSDuoCheatIO.read(game.id) ?? NSDuoCheatDocument() }
    }

    func save(_ document: NSDuoCheatDocument, for game: NSDuoLibraryGame, applyToRunningGame: Bool) async throws {
        if applyToRunningGame {
            let pending = sessionTask
            endSession()
            await pending?.value
        }
        let previous = try await NSDuoLibraryWorker.run { try NSDuoCheatIO.read(game.id) }
        try await NSDuoLibraryWorker.run { try NSDuoCheatIO.write(document, gameID: game.id) }
        guard applyToRunningGame else { return }
        do {
            let core = RyujinxController.shared
            guard core.isCurrentGame(game), core.isGameSuspended, !core.isStopping, let running = core.runningGame else {
                throw NSDuoCheatParser.failure("当前游戏状态已变化，请重新打开金手指。")
            }
            let titleID = running.titleId
            let groups = document.runtimeGroups
            try await Task.detached(priority: .userInitiated) {
                try NSDuoCheatRuntime.apply(titleID: titleID, groups: groups)
            }.value
        } catch {
            do { try await NSDuoLibraryWorker.run { try NSDuoCheatIO.restore(previous, gameID: game.id) } }
            catch { throw NSDuoCheatParser.failure("应用未成功，原配置恢复失败：\(error.localizedDescription)。请重新检查开关。") }
            throw error
        }
    }

    func beginSession(for running: GameInfo) {
        endSession()
        guard let game = NSDuoLibraryStore.shared.games.first(where: {
            running.fileURL.standardizedFileURL.path.hasSuffix("/" + $0.relativePath)
        }) else { return }
        let id = UUID()
        let runningTitleID = running.titleId
        sessionID = id
        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await self.load(for: game)
                guard document.runtimeGroups.contains(where: { $0.entries.contains(where: \.enabled) }) else { return }
                for _ in 0..<180 {
                    try Task.checkCancellation()
                    guard self.sessionID == id, RyujinxController.shared.isCurrentGame(game),
                          !RyujinxController.shared.isStopping else { return }
                    let info = try? await Task.detached { try NSDuoCheatRuntime.info() }.value
                    try Task.checkCancellation()
                    if info?.titleID.caseInsensitiveCompare(runningTitleID) == .orderedSame {
                        let groups = document.runtimeGroups
                        try await Task.detached(priority: .userInitiated) {
                            try NSDuoCheatRuntime.apply(titleID: runningTitleID, groups: groups)
                        }.value
                        return
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                throw NSDuoCheatParser.failure("游戏尚未提供金手指运行信息，本次未恢复开关。可挂起回库后重新应用。")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.sessionID == id else { return }
                self.message = "已保存的金手指未应用：\(error.localizedDescription)"
            }
        }
    }

    func endSession() {
        sessionTask?.cancel()
        sessionTask = nil
        sessionID = nil
    }
}

nonisolated private enum NSDuoCheatIO {
    private static func url(_ gameID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NSDuoCheats", isDirectory: true)
            .appendingPathComponent(gameID.uuidString + ".json")
    }

    static func read(_ gameID: UUID) throws -> NSDuoCheatDocument? {
        let path = url(gameID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw NSDuoCheatParser.failure("金手指记录过大，无法读取。") }
        let document = try JSONDecoder().decode(NSDuoCheatDocument.self, from: Data(contentsOf: path))
        try validate(document)
        return document
    }

    static func write(_ document: NSDuoCheatDocument, gameID: UUID) throws {
        try validate(document)
        let path = url(gameID)
        var directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        let data = try JSONEncoder().encode(document)
        guard data.count <= 2 * 1024 * 1024 else { throw NSDuoCheatParser.failure("金手指记录最多支持 2 MB，请减少导入内容。") }
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func restore(_ document: NSDuoCheatDocument?, gameID: UUID) throws {
        if let document { try write(document, gameID: gameID) }
        else if FileManager.default.fileExists(atPath: url(gameID).path) { try FileManager.default.removeItem(at: url(gameID)) }
    }

    private static func validate(_ document: NSDuoCheatDocument) throws {
        guard document.version == 1, document.groups.count <= 32,
              Set(document.groups.map(\.buildID)).count == document.groups.count else {
            throw NSDuoCheatParser.failure("金手指记录格式无效，最多支持 32 个版本。")
        }
        var entryIDs = Set<UUID>()
        for group in document.groups {
            guard try NSDuoCheatParser.buildID(group.buildID) == group.buildID,
                  !group.entries.isEmpty, group.entries.count <= 256,
                  (group.sourceText?.utf8.count ?? 0) <= NSDuoCheatParser.maximumTextBytes else {
                throw NSDuoCheatParser.failure("金手指版本或功能数量无效。")
            }
            for entry in group.entries {
                guard entryIDs.insert(entry.id).inserted, !entry.name.isEmpty, entry.name.count <= 120,
                      !entry.instructions.isEmpty, entry.instructions.count <= 16_384 else {
                    throw NSDuoCheatParser.failure("金手指功能记录无效。")
                }
                // Validate saved instruction words too; the native compiler checks opcode semantics.
                let source = entry.instructions.joined(separator: "\n")
                _ = try NSDuoCheatParser.parse(source, buildID: group.buildID, defaultName: entry.name)
            }
        }
    }
}
