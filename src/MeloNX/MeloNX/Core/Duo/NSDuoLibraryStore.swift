//
//  NSDuoLibraryStore.swift
//  MeloNX
//

import Foundation
import Combine
import CryptoKit
import UIKit

nonisolated enum NSDuoGameFormat: String, Sendable {
    case xci, nsp

    init?(url: URL) { self.init(rawValue: url.pathExtension.lowercased()) }

    var headerByteCount: Int { self == .xci ? 0x200 : 0x10 }

    func acceptsHeader(_ header: Data, fileSize: Int64) -> Bool {
        guard fileSize >= Int64(headerByteCount), header.count >= headerByteCount else { return false }
        switch self {
        case .xci:
            return header.subdata(in: 0x100..<0x104) == Data("HEAD".utf8)
        case .nsp:
            guard header.prefix(4) == Data("PFS0".utf8) else { return false }
            func uint32(at offset: Int) -> UInt64 {
                (0..<4).reduce(0) { $0 | (UInt64(header[offset + $1]) << ($1 * 8)) }
            }
            let fileCount = uint32(at: 4), stringTableSize = uint32(at: 8)
            // Check declared tables without allocating memory based on untrusted sizes.
            let dataOffset = 0x10 + fileCount * 0x18 + stringTableSize
            return fileCount > 0 && stringTableSize > 0 && dataOffset < UInt64(fileSize)
        }
    }
}

nonisolated struct NSDuoLibraryGame: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    let relativePath: String
    let sha256: String
    let byteCount: Int64
    let importedAt: Date
    var folder: NSDuoFolderRecord? = nil
}

nonisolated struct NSDuoImportProgress: Sendable {
    enum Phase: Sendable {
        case preparing, copying, decompressing, saving, cancelling
    }

    let fileName: String
    let copiedBytes: Int64
    let totalBytes: Int64
    var phase: Phase

    var fraction: Double {
        totalBytes > 0 ? min(Double(copiedBytes) / Double(totalBytes), 1) : 0
    }
}

@MainActor
final class NSDuoLibraryStore: ObservableObject {
    static let shared = NSDuoLibraryStore()

    @Published private(set) var games: [NSDuoLibraryGame] = []
    @Published private(set) var covers: [UUID: UIImage] = [:]
    @Published private(set) var isLoadingCovers = false
    @Published private(set) var importProgress: NSDuoImportProgress?
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var isRemoving = false
    @Published private(set) var isRenaming = false
    @Published private(set) var isCheckingFolders = false
    private var isPreparingLaunch = false
    @Published var message: String?
    @Published private(set) var folderWarnings: [UUID: String] = [:]
    @Published var cachedLaunchURL: URL?
    var isChoosingFiles = false

    var isBusy: Bool { isLoading || isRemoving || isRenaming || isCheckingFolders || isPreparingLaunch || importProgress != nil }

    private var libraryURL: URL?
    private var importOperation: NSDuoImportOperation?
    private var wantsFolderCheck = false
    private var cancelledFolderCheck = false
    private var coverAttempts: [UUID: String] = [:]

    private init() {}

    func loadIfNeeded() {
        guard !isReady, !isBusy else { return }
        isLoading = true
        Task { [self] in
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    try NSDuoLibraryIO.load()
                }.value
                libraryURL = loaded.root
                games = loaded.games
                covers = loaded.covers.compactMapValues { UIImage(data: $0) }
                coverAttempts = Dictionary(uniqueKeysWithValues: loaded.games.filter { covers[$0.id] != nil }.map { ($0.id, $0.sha256) })
                isReady = true
            } catch {
                message = "无法读取游戏库：\(error.localizedDescription)"
            }
            isLoading = false
            if wantsFolderCheck { wantsFolderCheck = false; checkFolders() }
        }
    }

    func importGame(from source: URL) {
        guard isReady, !isBusy else { return }
        guard NSDuoFolderIO.accepts(source) else {
            message = "请选择 XCI、NSP 或 NSZ 游戏文件。"
            return
        }
        importStandaloneGame(from: source)
    }

    // A folder scan is serialized with every import/remove and completes before
    // handing its URL to the emulator. Never scan while a game owns the key set.
    func importFolder(from source: URL) {
        guard isReady, !isBusy else { return }
        Ryujinx.reloadKeySet()
        isCheckingFolders = true
        Task { [self] in
            defer { isCheckingFolders = false }
            _ = await scanFolder(source, previous: nil, reportError: true)
            await refreshCovers()
        }
    }

    func checkFolders() {
        guard isReady else { wantsFolderCheck = true; return }
        guard !isBusy, !isChoosingFiles, cachedLaunchURL == nil, message == nil else { return }
        guard !games.isEmpty else { return }
        Ryujinx.reloadKeySet()
        isCheckingFolders = true
        cancelledFolderCheck = false
        Task { [self] in
            defer { isCheckingFolders = false }
            for game in games where game.folder != nil {
                guard !cancelledFolderCheck else { break }
                do {
                    let source = try NSDuoFolderIO.resolve(game.folder!)
                    _ = await scanFolder(source, previous: game, reportError: false)
                } catch { folderWarnings[game.id] = error.localizedDescription }
            }
            if !cancelledFolderCheck { await refreshCovers() }
        }
    }

    func prepareForLaunch(_ game: NSDuoLibraryGame, onReady: @escaping (URL) -> Void) {
        guard isReady, !isBusy, let root = libraryURL else { return }
        cachedLaunchURL = nil
        isPreparingLaunch = true
        Task { [self] in
            defer { isPreparingLaunch = false }
            var warning: String?
            if let folder = game.folder {
                Ryujinx.reloadKeySet()
                do {
                    let source = try NSDuoFolderIO.resolve(folder)
                    let success = await scanFolder(source, previous: game, reportError: false)
                    if !success {
                        warning = folderWarnings[game.id] ?? "检查已取消。"
                    }
                } catch { warning = error.localizedDescription }
            }
            guard let current = games.first(where: { $0.id == game.id }), let url = url(for: current) else { return }
            do {
                try NSDuoFolderIO.configure(current, root: root)
                if let warning {
                    cachedLaunchURL = url
                    message = "未能检查文件夹的新内容：\(warning)\n可以先使用上次成功导入的版本。若目录已移动，请重新添加该游戏文件夹。"
                } else {
                    isPreparingLaunch = false
                    onReady(url)
                }
            } catch { message = "附加内容准备失败：\(error.localizedDescription)" }
        }
    }

    private func scanFolder(_ source: URL, previous: NSDuoLibraryGame?, reportError: Bool) async -> Bool {
        guard isReady, !isLoading, !isRemoving, importProgress == nil, let root = libraryURL else { return false }
        let scoped = source.startAccessingSecurityScopedResource()
        let operation = NSDuoImportOperation()
        importOperation = operation
        importProgress = NSDuoImportProgress(fileName: source.lastPathComponent, copiedBytes: 0, totalBytes: 0, phase: .preparing)
        let existing = games
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
            importOperation = nil
            importProgress = nil
        }
        do {
            let updated = try await Task.detached(priority: .utility) { [self] in
                try NSDuoFolderIO.scan(source: source, root: root, previous: previous, existing: existing, operation: operation) { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.importOperation === operation, self.importProgress?.phase != .cancelling else { return }
                        self.importProgress = update
                    }
                }
            }.value
            games = updated
            if let previous { folderWarnings[previous.id] = nil }
            return true
        } catch {
            if let previous { folderWarnings[previous.id] = error.localizedDescription }
            if reportError && !operation.isCancelled { message = "导入失败：\(error.localizedDescription)" }
            return false
        }
    }

    private func importStandaloneGame(from source: URL) {
        guard let root = libraryURL else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        let operation = NSDuoImportOperation()
        importOperation = operation
        importProgress = NSDuoImportProgress(fileName: source.lastPathComponent, copiedBytes: 0, totalBytes: 0, phase: .preparing)
        let existing = games
        Ryujinx.reloadKeySet()
        Task { [self] in
            defer {
                if scoped { source.stopAccessingSecurityScopedResource() }
                importOperation = nil
                importProgress = nil
            }
            do {
                games = try await Task.detached(priority: .utility) { [self] in
                    var created = Set<URL>()
                    var committed = false
                    defer { if !committed { for file in created { try? FileManager.default.removeItem(at: file) } } }
                    let file = try NSDuoFolderIO.cache(source: source, sourcePath: source.lastPathComponent, root: root, operation: operation, created: &created) { update in
                        Task { @MainActor [weak self] in
                            guard let self, self.importOperation === operation, self.importProgress?.phase != .cancelling else { return }
                            self.importProgress = update
                        }
                    }
                    let baseIDs = Set(file.contents.filter { $0.kind == "application" }.map(\.applicationID))
                    guard baseIDs.count == 1 else {
                        throw LibraryError.message(baseIDs.isEmpty ? "这是升级包或 DLC，请把它和本体一起放入游戏目录，再添加整个文件夹。" : "文件包含多个游戏本体，暂时不能作为单个游戏加入。")
                    }
                    if let duplicate = existing.first(where: { $0.sha256 == file.sha256 }) {
                        _ = try NSDuoLibraryIO.checkedURL(for: duplicate, root: root)
                        try operation.beginCommit()
                        committed = true // retain a restored, previously missing shared copy
                        return existing
                    }
                    let game = NSDuoLibraryGame(id: UUID(), title: source.deletingPathExtension().lastPathComponent,
                                               relativePath: file.relativePath, sha256: file.sha256, byteCount: file.byteCount, importedAt: Date())
                    try operation.beginCommit()
                    let updated = existing + [game]
                    try NSDuoLibraryIO.save(updated, root: root)
                    committed = true
                    return updated
                }.value
                await refreshCovers()
            } catch {
                if !operation.isCancelled { message = "导入失败：\(error.localizedDescription)" }
            }
        }
    }

    func cancelImport() {
        cancelledFolderCheck = true
        if importOperation?.cancel() == true {
            importProgress?.phase = .cancelling
        }
    }

    // Every caller already holds the library's busy state. This keeps native
    // metadata reads off the main thread and prevents racing the emulation core.
    private func refreshCovers() async {
        guard let root = libraryURL else { return }
        isLoadingCovers = true
        defer { isLoadingCovers = false }
        let currentIDs = Set(games.map(\.id))
        covers = covers.filter { currentIDs.contains($0.key) }
        coverAttempts = coverAttempts.filter { currentIDs.contains($0.key) }
        for game in games {
            guard !Task.isCancelled, importOperation?.isCancelled != true else { return }
            guard coverAttempts[game.id] != game.sha256 else { continue }
            let data = await Task.detached(priority: .utility) {
                autoreleasepool { NSDuoCoverIO.load(for: game, root: root) }
            }.value
            covers[game.id] = data.flatMap { UIImage(data: $0) }
            // Failed artwork is retried next session, without rescanning a large
            // game file every time this library becomes visible in this session.
            coverAttempts[game.id] = game.sha256
        }
    }

    func url(for game: NSDuoLibraryGame) -> URL? {
        guard let root = libraryURL else { return nil }
        do {
            // Only metadata and at most 512 header bytes are read, never the full image.
            return try NSDuoLibraryIO.checkedURL(for: game, root: root)
        } catch {
            message = "无法打开这个游戏：\(error.localizedDescription) 请移除后重新导入。"
            return nil
        }
    }

    func rename(_ game: NSDuoLibraryGame, to title: String) {
        guard isReady, !isBusy, let root = libraryURL,
              let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { message = "游戏名称不能为空。"; return }
        guard games[index].title != name else { return }
        var updated = games
        updated[index].title = name
        let snapshot = updated
        isRenaming = true
        Task { [self] in
            defer { isRenaming = false }
            do {
                try await Task.detached(priority: .utility) {
                    try NSDuoLibraryIO.save(snapshot, root: root)
                }.value
                games = snapshot
            } catch {
                message = "重命名失败：\(error.localizedDescription)"
            }
        }
    }

    func remove(_ game: NSDuoLibraryGame) {
        guard isReady, !isBusy, let root = libraryURL else { return }
        let remaining = games.filter { $0.id != game.id }
        isRemoving = true
        Task { [self] in
            do {
                let warning = try await Task.detached(priority: .utility) {
                    try NSDuoLibraryIO.remove(game, root: root, remaining: remaining)
                }.value
                games = remaining
                covers[game.id] = nil
                coverAttempts[game.id] = nil
                folderWarnings[game.id] = nil
                message = warning
            } catch {
                message = "移除失败：\(error.localizedDescription)"
            }
            isRemoving = false
        }
    }
}

// Explicitly opt out of the target's default MainActor isolation. All multi-GB work
// below is synchronous inside Task.detached, with a fixed maximum read buffer.
nonisolated enum NSDuoLibraryIO {
    private struct Manifest: Codable {
        let version: Int
        let games: [NSDuoLibraryGame]
    }

    struct Loaded: Sendable {
        let root: URL
        let games: [NSDuoLibraryGame]
        let covers: [UUID: Data]
    }

    static func load() throws -> Loaded {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
        var root = support.appendingPathComponent("NSDuoLibrary", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        for folder in ["Games", "Staging"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                        withIntermediateDirectories: true)
        }

        let manifestURL = root.appendingPathComponent("manifest.json")
        let games: [NSDuoLibraryGame]
        if manager.fileExists(atPath: manifestURL.path) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.version == 1,
                  Set(manifest.games.map(\.id)).count == manifest.games.count,
                  Set(manifest.games.map(\.sha256)).count == manifest.games.count,
                  manifest.games.allSatisfy({ isValidRecord($0) && ($0.folder?.isValid ?? true) }) else {
                throw LibraryError.message("游戏库记录格式无效，现有文件已保留。")
            }
            games = manifest.games
        } else {
            games = []
        }

        // Only clean after a valid manifest has been read. A crash before its atomic
        // commit can leave staging/orphan files, but never a successful library item.
        let retained = Set(games.flatMap { [$0.relativePath] + ($0.folder?.files.map(\.relativePath) ?? []) })
        for folder in ["Staging", "Games"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if folder == "Staging" || !retained.contains("Games/\(file.lastPathComponent)") {
                    try manager.removeItem(at: file)
                }
            }
        }
        NSDuoCoverIO.prune(keeping: games, root: root)
        let covers = games.reduce(into: [UUID: Data]()) { result, game in
            result[game.id] = NSDuoCoverIO.cachedData(for: game, root: root)
        }
        return Loaded(root: root, games: games, covers: covers)
    }

    static func checkedURL(for game: NSDuoLibraryGame, root: URL) throws -> URL {
        guard isValidRecord(game), let format = NSDuoGameFormat(url: URL(fileURLWithPath: game.relativePath)) else {
            throw LibraryError.message("游戏记录无效。")
        }
        let url = root.appendingPathComponent(game.relativePath)
        guard try imageSize(at: url, format: format) == game.byteCount else {
            throw LibraryError.message("App 内的游戏副本不完整。")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try checkHeader(input, format: format, fileSize: game.byteCount)
        return url
    }

    static func remove(_ game: NSDuoLibraryGame, root: URL,
                       remaining: [NSDuoLibraryGame]) throws -> String? {
        guard isValidRecord(game) else { throw LibraryError.message("游戏记录无效。") }
        // Commit removal first; a crash or failed unlink only leaves an orphan that
        // startup retries. Source files and emulator save directories are never touched.
        try save(remaining, root: root)
        NSDuoCoverIO.prune(keeping: remaining, root: root)
        let retained = Set(remaining.flatMap { [$0.relativePath] + ($0.folder?.files.map(\.relativePath) ?? []) })
        let removedPaths = Set([game.relativePath] + (game.folder?.files.map(\.relativePath) ?? []))
        do {
            for path in removedPaths.subtracting(retained) {
                let url = root.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            return nil
        } catch {
            return "游戏记录已移除，但 App 副本暂未清理成功；重新打开 App 后会重试。源文件和存档不受影响。"
        }
    }

    static func save(_ games: [NSDuoLibraryGame], root: URL) throws {
        let data = try JSONEncoder().encode(Manifest(version: 1, games: games))
        try data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func isValidRecord(_ game: NSDuoLibraryGame) -> Bool {
        guard let format = NSDuoGameFormat(url: URL(fileURLWithPath: game.relativePath)) else { return false }
        return game.sha256.count == 64 && game.sha256.allSatisfy { "0123456789abcdef".contains($0) }
            && game.relativePath == "Games/\(game.sha256).\(format.rawValue)"
            && game.byteCount >= Int64(format.headerByteCount)
    }

    static func imageSize(at url: URL, format: NSDuoGameFormat) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= format.headerByteCount else {
            throw LibraryError.message("文件为空、过短或不是普通游戏文件。")
        }
        return Int64(size)
    }

    static func checkHeader(_ handle: FileHandle, format: NSDuoGameFormat, fileSize: Int64) throws {
        let header = try handle.read(upToCount: format.headerByteCount) ?? Data()
        guard format.acceptsHeader(header, fileSize: fileSize) else {
            throw LibraryError.message("文件缺少有效的 \(format.rawValue.uppercased()) 文件头，可能已损坏或格式不正确。")
        }
    }
}

nonisolated enum LibraryError: LocalizedError {
    case message(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .cancelled: "导入已取消。"
        }
    }
}

// The lock protects every mutable field. NSFileCoordinator cancellation may be
// requested from the main thread while its synchronous accessor runs off-thread.
nonisolated final class NSDuoImportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var committing = false
    private var coordinator: NSFileCoordinator?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func install(_ coordinator: NSFileCoordinator) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw LibraryError.cancelled }
        self.coordinator = coordinator
    }

    func clearCoordinator() {
        lock.lock()
        defer { lock.unlock() }
        coordinator = nil
    }

    func cancel() -> Bool {
        lock.lock()
        guard !committing else { lock.unlock(); return false }
        cancelled = true
        let current = coordinator
        lock.unlock()
        current?.cancel()
        return true
    }

    func checkCancellation() throws {
        if isCancelled { throw LibraryError.cancelled }
    }

    func beginCommit() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw LibraryError.cancelled }
        committing = true
    }
}
