import Foundation
import CryptoKit

// Keep folder provenance in the same atomic manifest as the playable base. Optional
// NSDuoLibraryGame.folder makes pre-folder library records decode unchanged.
nonisolated struct NSDuoFolderRecord: Codable, Sendable {
    var bookmark: Data
    let applicationID: String
    var files: [NSDuoFolderFile]

    var isValid: Bool {
        !bookmark.isEmpty && applicationID.count == 16
            && applicationID.allSatisfy { "0123456789abcdef".contains($0) }
            && files.allSatisfy(\.isValid)
    }

    var selection: NSDuoContentSelection { NSDuoContentSelection(applicationID: applicationID, files: files) }
    var summary: String {
        let selected = selection
        let update = selected.update.map { "更新 \($0.content.displayVersion ?? String($0.content.version))" } ?? "本体"
        return "\(update) · \(selected.dlc.count) 个 DLC"
    }
}

nonisolated struct NSDuoFolderFile: Codable, Sendable {
    let sourcePath: String
    let sourceBytes: Int64
    let sourceModified: Date?
    let relativePath: String
    let sha256: String
    let byteCount: Int64
    let contents: [NSDuoPackageContent]

    var isValid: Bool {
        let format = NSDuoGameFormat(url: URL(fileURLWithPath: relativePath))
        return format != nil && sha256.count == 64
            && sha256.allSatisfy { "0123456789abcdef".contains($0) }
            && relativePath == "Games/\(sha256).\(format!.rawValue)"
            && byteCount >= Int64(format!.headerByteCount)
            && !contents.isEmpty && contents.allSatisfy { content in
                ["application", "patch", "dlc"].contains(content.kind)
                    && [content.titleID, content.applicationID].allSatisfy {
                        $0.count == 16 && $0.allSatisfy { "0123456789abcdef".contains($0) } && UInt64($0, radix: 16) != 0
                    }
                    && (content.kind != "dlc" || content.ncaPath?.hasPrefix("/") == true)
            }
    }
}

nonisolated struct NSDuoContentSelection: Sendable {
    struct Item: Sendable {
        let file: NSDuoFolderFile
        let content: NSDuoPackageContent
    }
    let base: Item?
    let update: Item?
    let dlc: [Item]

    init(applicationID: String, files: [NSDuoFolderFile]) {
        // Numeric CNMT versions, never lexical version text or source file names.
        let items = files.flatMap { file in file.contents.map { Item(file: file, content: $0) } }
            .filter { $0.content.applicationID == applicationID }
            .sorted {
                if $0.content.version != $1.content.version { return $0.content.version > $1.content.version }
                return $0.file.relativePath < $1.file.relativePath
            }
        let selectedBase = items.first { $0.content.kind == "application" }
        base = selectedBase
        update = items.first { $0.content.kind == "patch" && $0.content.version > (selectedBase?.content.version ?? 0) }
        var seen = Set<String>()
        dlc = items.filter { $0.content.kind == "dlc" && $0.content.ncaPath != nil && seen.insert($0.content.titleID).inserted }
    }
}

nonisolated enum NSDuoFolderIO {
    static func accepts(_ url: URL) -> Bool { ["xci", "nsp", "nsz"].contains(url.pathExtension.lowercased()) }

    static func resolve(_ folder: NSDuoFolderRecord) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI], relativeTo: nil,
                       bookmarkDataIsStale: &stale)
    }

    static func scan(source: URL, root: URL, previous: NSDuoLibraryGame?, existing: [NSDuoLibraryGame],
                     operation: NSDuoImportOperation,
                     progress: @escaping @Sendable (NSDuoImportProgress) -> Void) throws -> [NSDuoLibraryGame] {
        let manager = FileManager.default
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw LibraryError.message("请选择包含一个游戏本体和附加内容的文件夹。")
        }
        let sourceFiles = try enumerate(source, operation: operation)
        guard !sourceFiles.isEmpty else { throw LibraryError.message("这个目录及其子目录中没有 XCI、NSP 或 NSZ 文件。") }
        var files = previous?.folder?.files ?? []
        var contentsChanged = previous == nil
        var created = Set<URL>()
        var committed = false
        defer { if !committed { for file in created { try? manager.removeItem(at: file) } } }

        for (relativeSource, url) in sourceFiles {
            try operation.checkCancellation()
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let old = files.first(where: { $0.sourcePath == relativeSource }),
               let modified = values.contentModificationDate, old.sourceModified == modified,
               old.sourceBytes == Int64(values.fileSize ?? -1),
               (try? NSDuoLibraryIO.imageSize(at: root.appendingPathComponent(old.relativePath),
                                             format: NSDuoGameFormat(url: URL(fileURLWithPath: old.relativePath))!)) == old.byteCount {
                continue
            }
            contentsChanged = true
            progress(NSDuoImportProgress(fileName: relativeSource, copiedBytes: 0, totalBytes: 0, phase: .preparing))
            let file = try cache(source: url, sourcePath: relativeSource, root: root,
                                 operation: operation, created: &created, progress: progress)
            files.removeAll { $0.sourcePath == relativeSource }
            files.append(file)
        }

        // Every scan still checks nested paths, source size/date and cached copies.
        // A launch immediately after an automatic check need not rewrite the manifest.
        if !contentsChanged, let folder = previous?.folder {
            var stale = false
            _ = try URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
            if !stale {
                try operation.checkCancellation()
                return existing
            }
        }
        let bookmark = try source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let baseIDs = Set(files.flatMap(\.contents).filter { $0.kind == "application" }.map(\.applicationID))
        guard baseIDs.count == 1, let applicationID = baseIDs.first else {
            throw LibraryError.message(baseIDs.isEmpty ? "未找到可启动的本体；升级包和 DLC 需要与本体一起放在所选目录下。" : "发现多个游戏本体，请选择只包含一个游戏及其附加内容的目录。")
        }
        if let oldID = previous?.folder?.applicationID, oldID != applicationID {
            throw LibraryError.message("目录中的游戏与原记录不一致，请通过“添加游戏文件夹”加入另一个游戏。")
        }
        // Unrelated content is never activated. Do not keep its large app-owned copy.
        files = files.filter { $0.contents.contains { $0.applicationID == applicationID } }
        let folder = NSDuoFolderRecord(bookmark: bookmark, applicationID: applicationID, files: files)
        guard let base = folder.selection.base else { throw LibraryError.message("无法识别本体。") }
        let prior = previous ?? existing.first { $0.folder?.applicationID == applicationID || $0.sha256 == base.file.sha256 }
        let title = prior?.title ?? URL(fileURLWithPath: base.file.sourcePath).deletingPathExtension().lastPathComponent
        let game = NSDuoLibraryGame(id: prior?.id ?? UUID(), title: title, relativePath: base.file.relativePath,
                                    sha256: base.file.sha256, byteCount: base.file.byteCount,
                                    importedAt: prior?.importedAt ?? Date(), folder: folder)
        let updated = existing.filter { $0.id != game.id && $0.sha256 != game.sha256 && $0.folder?.applicationID != applicationID } + [game]
        try operation.beginCommit()
        progress(NSDuoImportProgress(fileName: title, copiedBytes: 0, totalBytes: 0, phase: .saving))
        try NSDuoLibraryIO.save(updated, root: root)
        committed = true
        let retained = Set(updated.flatMap { [$0.relativePath] + ($0.folder?.files.map(\.relativePath) ?? []) })
        let oldPaths = Set(existing.flatMap { [$0.relativePath] + ($0.folder?.files.map(\.relativePath) ?? []) })
        let candidates = oldPaths.union(created.map { "Games/\($0.lastPathComponent)" })
        let gamesDirectory = root.appendingPathComponent("Games", isDirectory: true).standardizedFileURL
        // Only reclaim app-owned files after the new manifest is durable. Keep
        // every file referenced by any other library entry, including shared DLC.
        for path in candidates.subtracting(retained) {
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard file.deletingLastPathComponent() == gamesDirectory else { continue }
            try? manager.removeItem(at: file)
        }
        return updated
    }

    // Recurses regardless of directory names. Never follows symlinks out of the
    // user's selected root. An unreadable subtree aborts instead of claiming success.
    private static func enumerate(_ source: URL, operation: NSDuoImportOperation) throws -> [(String, URL)] {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try operation.install(coordinator)
        defer { operation.clearCoordinator() }
        var coordinationError: NSError?
        var result: Result<[(String, URL)], Error>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                var enumerationError: Error?
                guard let enumerator = FileManager.default.enumerator(at: readable,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
                    throw LibraryError.message("无法读取目录。请在“文件”中确认该目录可用。")
                }
                var urls: [(String, URL)] = []
                // Foundation may enumerate /private/var for a coordinated /var URL.
                // Compare canonical paths while keeping the coordinated URLs for IO.
                let rootPath = readable.resolvingSymlinksInPath().path
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                while let url = enumerator.nextObject() as? URL {
                    try operation.checkCancellation()
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    // The enumerator never follows symlinks. Calling skipDescendants
                    // on a link can skip an unrelated directory after batch prefetch.
                    if values.isSymbolicLink == true { continue }
                    if values.isRegularFile == true && accepts(url) {
                        let path = url.resolvingSymlinksInPath().path
                        guard path.hasPrefix(prefix) else { throw LibraryError.message("目录返回了不在所选范围内的文件。") }
                        urls.append((String(path.dropFirst(prefix.count)), url))
                    }
                }
                if let enumerationError { throw enumerationError }
                return urls.sorted { $0.0 < $1.0 }
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? NSError(domain: "NSDuoFolder", code: 1, userInfo: [NSLocalizedDescriptionKey: "读取目录失败。"])
    }

    static func cache(source: URL, sourcePath: String, root: URL, operation: NSDuoImportOperation,
                      created: inout Set<URL>, progress: @escaping @Sendable (NSDuoImportProgress) -> Void) throws -> NSDuoFolderFile {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try operation.install(coordinator)
        defer { operation.clearCoordinator() }
        var coordinationError: NSError?
        var result: Result<NSDuoFolderFile, Error>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                let before = try readable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard before.isRegularFile == true, before.isSymbolicLink != true, let sourceBytes = before.fileSize else {
                    throw LibraryError.message("\(sourcePath) 不是可读取的普通文件。")
                }
                let compressed = source.pathExtension.lowercased() == "nsz"
                let format: NSDuoGameFormat = compressed ? .nsp : NSDuoGameFormat(url: source)!
                let temporary = root.appendingPathComponent("Staging/\(UUID().uuidString).\(format.rawValue)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let hash: String
                if compressed {
                    hash = try NSDuoNSZImporter.decompress(source: readable, destination: temporary, operation: operation, progress: progress)
                } else {
                    let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    if let available = capacity.volumeAvailableCapacityForImportantUsage, available < Int64(sourceBytes) + 1_048_576 {
                        throw LibraryError.message("手机空间不足，需要复制 \(sourcePath)。")
                    }
                    hash = try streamCopy(readable, to: temporary, byteCount: Int64(sourceBytes), operation: operation, progress: progress)
                }
                let after = try readable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate else {
                    throw LibraryError.message("\(sourcePath) 在导入期间发生变化，请重试。")
                }
                let size = try NSDuoLibraryIO.imageSize(at: temporary, format: format)
                let input = try FileHandle(forReadingFrom: temporary)
                defer { try? input.close() }
                try NSDuoLibraryIO.checkHeader(input, format: format, fileSize: size)
                let contents = try NSDuoPackageInspector.inspect(temporary)
                guard !contents.isEmpty else { throw LibraryError.message("\(sourcePath) 没有可识别的游戏内容，请检查文件与密钥。") }
                let path = "Games/\(hash).\(format.rawValue)"
                let destination = root.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    created.insert(destination)
                } else if try NSDuoLibraryIO.imageSize(at: destination, format: format) != size {
                    throw LibraryError.message("已有副本大小异常，文件已保留，请移除该游戏后重新添加。")
                }
                return NSDuoFolderFile(sourcePath: sourcePath, sourceBytes: Int64(sourceBytes), sourceModified: before.contentModificationDate,
                                       relativePath: path, sha256: hash, byteCount: size, contents: contents)
            }
        }
        if let result { return try result.get() }
        try operation.checkCancellation()
        throw coordinationError ?? NSError(domain: "NSDuoFolder", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取 \(sourcePath)。"])
    }

    private static func streamCopy(_ source: URL, to destination: URL, byteCount: Int64,
                                   operation: NSDuoImportOperation,
                                   progress: @escaping @Sendable (NSDuoImportProgress) -> Void) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try Data().write(to: destination, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count: Int64 = 0
        var hasher = SHA256()
        var lastReport = Date.distantPast
        while true {
            try operation.checkCancellation()
            let copied = try autoreleasepool {
                let chunk = try input.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                guard Int64(chunk.count) <= byteCount - count else { throw LibraryError.message("源文件大小发生变化。") }
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                return chunk.count
            }
            if copied == 0 { break }
            count += Int64(copied)
            if Date().timeIntervalSince(lastReport) >= 0.1 || count == byteCount {
                lastReport = Date()
                progress(NSDuoImportProgress(fileName: source.lastPathComponent, copiedBytes: count, totalBytes: byteCount, phase: .copying))
            }
        }
        guard count == byteCount else { throw LibraryError.message("源文件未完整读取。") }
        try output.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func configure(_ game: NSDuoLibraryGame, root: URL) throws {
        guard let folder = game.folder else { return }
        guard folder.isValid else { throw LibraryError.message("游戏目录记录无效，现有副本已保留。") }
        let selection = folder.selection
        for file in Set(([selection.update?.file].compactMap { $0 } + selection.dlc.map(\.file)).map(\.relativePath)) {
            guard FileManager.default.isReadableFile(atPath: root.appendingPathComponent(file).path) else {
                throw LibraryError.message("附加内容副本丢失，请重新添加游戏文件夹。")
            }
        }
        let gameDirectory = URL.documentsDirectory.appendingPathComponent("games/\(folder.applicationID)", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        let updatePath = selection.update.map { root.appendingPathComponent($0.file.relativePath).path } ?? ""
        let updateData = try JSONSerialization.data(withJSONObject: ["selected": updatePath, "paths": updatePath.isEmpty ? [] : [updatePath]])
        let containers: [[String: Any]] = Dictionary(grouping: selection.dlc, by: { $0.file.relativePath }).sorted { $0.key < $1.key }.map { path, items in
            ["path": root.appendingPathComponent(path).path, "dlc_nca_list": items.map {
                ["path": $0.content.ncaPath!, "title_id": UInt64($0.content.titleID, radix: 16)!, "is_enabled": true] as [String: Any]
            }] as [String: Any]
        }
        let dlcData = try JSONSerialization.data(withJSONObject: containers)
        let updatesURL = gameDirectory.appendingPathComponent("updates.json")
        let dlcURL = gameDirectory.appendingPathComponent("dlc.json")
        let oldUpdate = FileManager.default.fileExists(atPath: updatesURL.path) ? try Data(contentsOf: updatesURL) : nil
        do {
            try updateData.write(to: updatesURL, options: .atomic)
            try dlcData.write(to: dlcURL, options: .atomic)
        } catch {
            if let oldUpdate { try? oldUpdate.write(to: updatesURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: updatesURL) }
            throw error // caller must not launch with a partially applied configuration
        }
    }
}
