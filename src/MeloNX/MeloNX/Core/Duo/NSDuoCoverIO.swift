import Foundation
import UIKit
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
              width > 0, height > 0, width <= thumbnailSize, height <= thumbnailSize else { return nil }
        return data
    }

    // Call only from the existing serial library operation, while emulation is
    // stopped and keys are ready. Missing artwork must never fail an import.
    static func load(for game: NSDuoLibraryGame, root: URL) -> Data? {
        if let data = cachedData(for: game, root: root) { return data }
        return extractedData(for: game, root: root)
    }

    private static func extractedData(for game: NSDuoLibraryGame, root: URL) -> Data? {
        guard let url = try? NSDuoLibraryIO.checkedURL(for: game, root: root),
              let original = try? Ryujinx.gameIconData(at: url),
              let thumbnail = makeThumbnail(original) else { return nil }
        let destination = cacheURL(for: game, root: root)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? thumbnail.write(to: destination, options: .atomic)
        return thumbnail
    }

    struct Prepared: @unchecked Sendable {
        let image: UIImage
        let cost: Int
    }

    // Decode once, on the serial worker, before publishing to SwiftUI. UIImage is
    // immutable here; no main-thread lazy JPEG decode is needed for the first draw.
    static func preparedImage(for game: NSDuoLibraryGame, root: URL) -> Prepared? {
        if let data = cachedData(for: game, root: root), let prepared = decode(data) { return prepared }
        guard let data = extractedData(for: game, root: root) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return Prepared(image: UIImage(cgImage: image), cost: image.bytesPerRow * image.height)
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

// A hard decoded-image budget, independent of JPEG file size. Keep deterministic
// LRU accounting so memory pressure and a large library cannot grow it unbounded.
nonisolated struct NSDuoCoverBudget {
    let limit: Int
    private var costs: [UUID: Int] = [:]
    private var order: [UUID] = []
    private(set) var totalCost = 0
    init(limit: Int = 24 * 1024 * 1024) { self.limit = max(0, limit) }
    func contains(_ id: UUID) -> Bool { costs[id] != nil }
    mutating func touch(_ id: UUID) {
        guard costs[id] != nil else { return }
        order.removeAll { $0 == id }; order.append(id)
    }
    mutating func insert(_ id: UUID, cost: Int) -> [UUID] {
        totalCost -= costs.removeValue(forKey: id) ?? 0
        order.removeAll { $0 == id }
        var evicted: [UUID] = []
        guard cost > 0, cost <= limit else { return [id] }
        while totalCost > limit - cost, let oldest = order.first {
            order.removeFirst()
            totalCost -= costs.removeValue(forKey: oldest) ?? 0
            evicted.append(oldest)
        }
        costs[id] = cost; totalCost += cost; order.append(id)
        return evicted
    }
    mutating func remove(_ id: UUID) {
        totalCost -= costs.removeValue(forKey: id) ?? 0
        order.removeAll { $0 == id }
    }
    mutating func removeAll() { costs.removeAll(); order.removeAll(); totalCost = 0 }
}
