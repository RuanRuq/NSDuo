//
//  NSDuoNSZImporter.swift
//  MeloNX
//

import Foundation

private typealias NSDuoNSZProgressCallback = @convention(c)
    (UnsafeMutableRawPointer?, Int64, Int64) -> Int32

@_silgen_name("nsz_decompress_to_nsp")
nonisolated private func c_nsz_decompress_to_nsp(
    _ source: UnsafePointer<CChar>,
    _ destination: UnsafePointer<CChar>,
    _ availableBytes: Int64,
    _ progress: NSDuoNSZProgressCallback,
    _ context: UnsafeMutableRawPointer
) -> Int32

@_silgen_name("nsz_get_last_sha256")
nonisolated private func c_nsz_get_last_sha256() -> UnsafePointer<CChar>?

@_silgen_name("nsz_get_last_error")
nonisolated private func c_nsz_get_last_error() -> UnsafePointer<CChar>?

@_silgen_name("nsz_free_string")
nonisolated private func c_nsz_free_string(_ pointer: UnsafePointer<CChar>)

nonisolated enum NSDuoNSZImporter {
    // Caller keeps file coordination/security scope active and supplies a NEW
    // temporary path. This is synchronous and must run on the import worker.
    static func decompress(source: URL, destination: URL,
                           operation: NSDuoImportOperation,
                           progress: @escaping @Sendable (NSDuoImportProgress) -> Void) throws -> String {
        try operation.checkCancellation()
        guard source.isFileURL, destination.isFileURL else {
            throw NSDuoNSZError.message("NSZ 解压需要本地文件路径。")
        }
        let directory = destination.deletingLastPathComponent()
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available: Int64
        if let importantCapacity = capacity.volumeAvailableCapacityForImportantUsage {
            available = importantCapacity
        } else {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            guard let free = attributes[.systemFreeSize] as? NSNumber else {
                throw NSDuoNSZError.message("无法确认手机剩余空间，请稍后重试。")
            }
            available = free.int64Value
        }
        let reserve: Int64 = 64 * 1024 * 1024
        guard available > reserve else {
            throw NSDuoNSZError.message("手机可用空间不足，无法解压 NSZ。")
        }

        progress(NSDuoImportProgress(fileName: source.lastPathComponent, copiedBytes: 0,
                                     totalBytes: 0, phase: .decompressing))
        let box = NSDuoNSZProgressContext(fileName: source.lastPathComponent,
                                        operation: operation, progress: progress)
        let retained = Unmanaged.passRetained(box)
        defer { retained.release() }
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                c_nsz_decompress_to_nsp(sourcePath, destinationPath, available - reserve,
                                       nsduoNSZProgress, retained.toOpaque())
            }
        }
        if result != 0 {
            // Read on this same worker thread: native error storage is thread-local.
            let message: String
            if let pointer = c_nsz_get_last_error() {
                message = String(cString: pointer)
                c_nsz_free_string(pointer)
            } else {
                message = "NSZ 解压失败，请检查文件是否完整。"
            }
            try operation.checkCancellation()
            throw NSDuoNSZError.message(message)
        }
        do {
            // Close the small race between the final native callback and return.
            try operation.checkCancellation()
            guard let pointer = c_nsz_get_last_sha256() else {
                throw NSDuoNSZError.message("NSZ 解压未返回完整校验值，请重新导入。")
            }
            defer { c_nsz_free_string(pointer) }
            let hash = String(cString: pointer)
            guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw NSDuoNSZError.message("NSZ 解压校验值无效，请重新导入。")
            }
            return hash
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

// Only the synchronous native call touches this context, on its calling worker.
// The operation itself protects cancellation with its own lock.
nonisolated private final class NSDuoNSZProgressContext {
    let fileName: String
    let operation: NSDuoImportOperation
    let progress: @Sendable (NSDuoImportProgress) -> Void
    private var lastReport = -Double.greatestFiniteMagnitude
    private var lastBytes: Int64 = -1

    init(fileName: String, operation: NSDuoImportOperation,
         progress: @escaping @Sendable (NSDuoImportProgress) -> Void) {
        self.fileName = fileName
        self.operation = operation
        self.progress = progress
    }

    func update(written: Int64, total: Int64) -> Int32 {
        if operation.isCancelled { return 1 }
        guard total > 0 else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReport >= 0.1 || (written == total && written != lastBytes) {
            lastReport = now
            lastBytes = written
            progress(NSDuoImportProgress(fileName: fileName, copiedBytes: written,
                                         totalBytes: total, phase: .decompressing))
        }
        return 0
    }
}

nonisolated private func nsduoNSZProgress(_ pointer: UnsafeMutableRawPointer?,
                                        _ written: Int64, _ total: Int64) -> Int32 {
    guard let pointer else { return 1 }
    let context = Unmanaged<NSDuoNSZProgressContext>.fromOpaque(pointer).takeUnretainedValue()
    return context.update(written: written, total: total)
}

nonisolated private enum NSDuoNSZError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
