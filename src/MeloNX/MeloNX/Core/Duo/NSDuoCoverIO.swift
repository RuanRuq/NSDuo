import Foundation
import ImageIO
import UniformTypeIdentifiers

// Covers are optional, rebuildable thumbnails. Keep them separate from the
// manifest so existing libraries and user-renamed titles remain unchanged.
nonisolated enum NSDuoCoverIO {
    private static let maximumBytes = 1_048_576
    private static let thumbnailSize = 768 // Preserve source detail for larger grid covers.

    static func cachedData(for game: NSDuoLibraryGame, root: URL) -> Data? {
        guard NSDuoLibraryIO.isValidRecord(game) else { return nil }
        let url = cacheURL(for: game, root: root)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= thumbnailSize, height <= thumbnailSize,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return data
    }

    // Call only from the existing serial library operation, while emulation is
    // stopped and keys are ready. Missing artwork must never fail an import.
    static func load(for game: NSDuoLibraryGame, root: URL) -> Data? {
        if let data = cachedData(for: game, root: root) { return data }
        guard let url = try? NSDuoLibraryIO.checkedURL(for: game, root: root),
              let original = try? Ryujinx.gameIconData(at: url),
              let thumbnail = makeThumbnail(original) else { return nil }
        let destination = cacheURL(for: game, root: root)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? thumbnail.write(to: destination, options: .atomic)
        return thumbnail
    }

    static func prune(keeping games: [NSDuoLibraryGame], root: URL) {
        let directory = root.appendingPathComponent("Covers", isDirectory: true)
        let names = Set(games.map { cacheURL(for: $0, root: root).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func cacheURL(for game: NSDuoLibraryGame, root: URL) -> URL {
        // Rebuild the former 192 px thumbnails once when upgrading the layout.
        root.appendingPathComponent("Covers/v2-\(game.sha256).jpg")
    }

    private static func makeThumbnail(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { return nil }
        return output as Data
    }
}
