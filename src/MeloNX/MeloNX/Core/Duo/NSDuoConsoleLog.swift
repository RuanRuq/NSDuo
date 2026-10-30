import Foundation
import Darwin

/// Native and managed console output share two rotating files. Rotation checks
/// run once per second off the main thread, without copying the existing file.
nonisolated final class NSDuoConsoleLog: @unchecked Sendable {
    static let shared = NSDuoConsoleLog()
    private let queue = DispatchQueue(label: "NSDuo.console-log", qos: .utility)
    private let destinations: [Int32]
    private let segmentBytes: Int64
    private var savedDescriptors: [Int32] = []
    private var descriptor: Int32 = -1
    private var currentURL: URL?
    private var previousURL: URL?
    private var timer: DispatchSourceTimer?

    init(destinations: [Int32] = [STDOUT_FILENO, STDERR_FILENO], segmentBytes: Int64 = 2 * 1024 * 1024) {
        self.destinations = destinations
        self.segmentBytes = max(1, segmentBytes)
    }

    func start(in directory: URL) throws {
        try queue.sync {
            stopLocked()
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteNoPermission)
            }
            // Retain at most eight older segments plus this session's two.
            let old = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("MeloNX-Log-") && $0.pathExtension == "log" }
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            for (url, _) in old.dropFirst(8) { try? fm.removeItem(at: url) }
            let name = "MeloNX-Log-" + UUID().uuidString
            let current = directory.appendingPathComponent(name + ".log")
            let fd = open(current.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw posixError() }
            let saved = destinations.map { dup($0) }
            guard saved.allSatisfy({ $0 >= 0 }) else {
                let error = posixError()
                for item in saved where item >= 0 { close(item) }
                close(fd); unlink(current.path)
                throw error
            }
            fflush(nil)
            for (index, destination) in destinations.enumerated() {
                guard duplicate(fd, to: destination) else {
                    let error = posixError()
                    for (destination, original) in zip(destinations.prefix(index), saved.prefix(index)) { _ = duplicate(original, to: destination) }
                    for original in saved { close(original) }
                    close(fd); unlink(current.path)
                    throw error
                }
            }
            descriptor = fd
            savedDescriptors = saved
            currentURL = current
            previousURL = directory.appendingPathComponent(name + "-previous.log")
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in self?.rotateLocked() }
            timer = source
            source.resume()
        }
    }

    func rotateIfNeeded() { queue.sync { rotateLocked() } }
    func stop() { queue.sync { stopLocked() } }

    private func rotateLocked() {
        guard descriptor >= 0, let currentURL, let previousURL else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= segmentBytes else { return }
        let temporary = currentURL.appendingPathExtension("new")
        let next = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW, 0o600)
        guard next >= 0 else { return }
        guard rename(currentURL.path, previousURL.path) == 0 else {
            close(next); unlink(temporary.path); return
        }
        guard rename(temporary.path, currentURL.path) == 0 else {
            rename(previousURL.path, currentURL.path)
            close(next); unlink(temporary.path); return
        }
        // Concurrent writes finish in one of the two segments. Descriptors stay
        // open throughout redirection; only small descriptor operations are used.
        for destination in destinations {
            guard duplicate(next, to: destination) else {
                // Do not leave one stream writing an unmonitored old segment.
                stopLocked()
                close(next)
                return
            }
        }
        close(descriptor)
        descriptor = next
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        if descriptor >= 0 {
            fflush(nil)
            for (destination, original) in zip(destinations, savedDescriptors) { _ = duplicate(original, to: destination); close(original) }
            close(descriptor)
        }
        descriptor = -1
        savedDescriptors.removeAll()
        currentURL = nil
        previousURL = nil
    }

    private func duplicate(_ source: Int32, to destination: Int32) -> Bool {
        while dup2(source, destination) < 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    deinit {
        timer?.cancel()
        for (destination, original) in zip(destinations, savedDescriptors) { _ = duplicate(original, to: destination); close(original) }
        if descriptor >= 0 { close(descriptor) }
    }
}
