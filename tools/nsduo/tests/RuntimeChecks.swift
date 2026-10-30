import Foundation
import CryptoKit
import Combine

// Native ABI substitute. Snapshots deliberately outlive unregister to simulate
// a C# invocation which already fetched its entry on another thread.
typealias DataCallbackFn = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
struct CallbackData { var ptr: UnsafeRawPointer?; var len: Int32 }
final class NativeCallbacks: @unchecked Sendable {
    struct Entry: @unchecked Sendable {
        let callback: DataCallbackFn
        let token: UInt
        func invoke(_ data: Data = Data()) {
            data.withUnsafeBytes { bytes in
                var value = CallbackData(ptr: bytes.baseAddress, len: Int32(data.count))
                withUnsafePointer(to: &value) { callback($0, UnsafeMutableRawPointer(bitPattern: token)) }
            }
        }
    }
    static let shared = NativeCallbacks()
    let lock = NSLock()
    var entries: [String: Entry] = [:]
    func snapshot(_ name: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[name] }
}
func RegisterCallback(_ name: UnsafePointer<CChar>, _ callback: DataCallbackFn, _ userData: UnsafeMutableRawPointer?) {
    let native = NativeCallbacks.shared
    native.lock.lock(); defer { native.lock.unlock() }
    native.entries[String(cString: name)] = .init(callback: callback, token: UInt(bitPattern: userData!))
}
func UnregisterCallback(_ name: UnsafePointer<CChar>) {
    let native = NativeCallbacks.shared
    native.lock.lock(); defer { native.lock.unlock() }
    native.entries.removeValue(forKey: String(cString: name))
}
final class WorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
}
final class Probe {
    let onRelease: () -> Void
    init(_ onRelease: @escaping () -> Void = {}) { self.onRelease = onRelease }
    deinit { onRelease() }
}
final class FakeChannel: RumbleChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var updates = 0, restarts = 0, stops = 0
    var counts: (updates: Int, restarts: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }; return (updates, restarts, stops)
    }
    func update(lowAmplitude: Float, lowFrequency: Float, highAmplitude: Float,
                highFrequency: Float, rumbleMultiplier: Float) {
        lock.lock(); defer { lock.unlock() }; updates += 1
    }
    func restart() -> Bool { lock.lock(); defer { lock.unlock() }; restarts += 1; return true }
    func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
}
// Only content inspection and cover/NSZ dependencies are stubbed; scan,
// bookmarks, coordination, header validation, copying, hashing and manifest IO are real.
nonisolated enum NSDuoCoverIO {
    static func prune(keeping: [NSDuoLibraryGame], root: URL) {}
    static func cachedData(for: NSDuoLibraryGame, root: URL) -> Data? { nil }
}
nonisolated enum NSDuoNSZImporter {
    static func decompress(source: URL, destination: URL, operation: NSDuoImportOperation,
                           progress: @escaping @Sendable (NSDuoImportProgress) -> Void) throws -> String {
        throw LibraryError.message("NSZ codec is outside these host lifecycle checks")
    }
}
nonisolated enum NSDuoPackageInspector {
    static func inspect(_ url: URL) throws -> [NSDuoPackageContent] {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: 0x180)
        let bytes = Array(try handle.read(upToCount: 2)!)
        let kind = bytes[0] == 0 || bytes[0] == 4 ? "application" : bytes[0] == 1 ? "patch" : "dlc"
        return [.init(kind: kind, titleID: bytes[0] == 2 ? "0100000000001001" : "0100000000000000",
                      applicationID: bytes[0] == 3 || bytes[0] == 4 ? "0100000000002000" : "0100000000000000", version: UInt32(bytes[1]),
                      displayVersion: String(bytes[1]), ncaPath: kind == "dlc" ? "/dlc.nca" : nil)]
    }
}

@main struct RuntimeChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func expectFailure(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(message) } catch {}
    }
    static func callbacks() {
        var owner: Probe? = Probe()
        weak let weakOwner = owner
        let old = CallbackManager.register(name: "owner") { [captured = owner!] _ in withExtendedLifetime(captured) {} }
        let stale = NativeCallbacks.shared.snapshot("owner")!
        owner = nil
        check(weakOwner != nil, "registered closure lost its owner")
        var calls = 0
        let new = CallbackManager.register(name: "owner") { _ in calls += 1 }
        check(weakOwner == nil, "replaced callback leaked its capture")
        stale.invoke()
        check(calls == 0, "stale callback was routed to new handler")
        CallbackManager.unregister(name: "owner", token: old)
        NativeCallbacks.shared.snapshot("owner")!.invoke()
        check(calls == 1, "old token removed a newer registration")
        let latest = NativeCallbacks.shared.snapshot("owner")!
        CallbackManager.unregister(name: "owner", token: new)
        latest.invoke()
        check(calls == 1, "unregistered callback still runs")

        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        var inFlight: Probe? = Probe { released.signal() }
        CallbackManager.register(name: "flight") { [captured = inFlight!] _ in
            entered.signal(); _ = proceed.wait(timeout: .now() + 3)
            withExtendedLifetime(captured) {}
        }
        inFlight = nil
        let snapshot = NativeCallbacks.shared.snapshot("flight")!
        DispatchQueue.global().async { snapshot.invoke(); finished.signal() }
        check(entered.wait(timeout: .now() + 2) == .success, "callback did not enter")
        CallbackManager.unregister(name: "flight")
        check(released.wait(timeout: .now()) == .timedOut, "in-flight capture released too early")
        proceed.signal()
        check(finished.wait(timeout: .now() + 2) == .success, "in-flight callback stalled")
        check(released.wait(timeout: .now() + 2) == .success, "in-flight capture leaked after return")
        var reentrant: Probe? = Probe { CallbackManager.unregister(name: "reentrant") }
        CallbackManager.register(name: "reentrant") { [captured = reentrant!] _ in withExtendedLifetime(captured) {} }
        reentrant = nil
        CallbackManager.register(name: "reentrant") { _ in }
        check(NativeCallbacks.shared.snapshot("reentrant") == nil, "capture deinit could not re-enter registry")
        print("PASS: callback replacement, stale tokens, in-flight lifetime, reentrant release")
    }
    static func sample(started: Bool, fps: Double = 30) -> Data {
        var data = Data(count: 33)
        func put<T>(_ value: T, at offset: Int) {
            var value = value
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        put(fps, at: 0); put(33.3, at: 8); put(UInt8(started ? 1 : 0), at: 16); put(10.0, at: 17)
        return data
    }
    @MainActor static func statistics() async throws {
        let handler = StatisticsHandler()
        handler.registerPush(includeMetrics: false)
        let entry = NativeCallbacks.shared.snapshot("push_statistics")!
        var changes = 0
        let observer = handler.objectWillChange.sink { changes += 1 }
        entry.invoke(sample(started: true))
        for i in 0..<200 { entry.invoke(sample(started: true, fps: Double(i))) }
        try await Task.sleep(for: .milliseconds(50))
        check(handler.started && changes == 1 && handler.fps == 0, "hidden metrics still invalidate gameplay view")
        handler.unregisterPush()
        entry.invoke(sample(started: false))
        try await Task.sleep(for: .milliseconds(20))
        check(handler.started, "stale sample changed an unregistered session")
        handler.registerPush()
        NativeCallbacks.shared.snapshot("push_statistics")!.invoke(sample(started: true, fps: 29))
        try await Task.sleep(for: .milliseconds(50))
        check(handler.started && handler.fps == 29 && handler.fifo == 10, "visible metrics were lost")
        // Already queued main-actor delivery must not enter a new session.
        NativeCallbacks.shared.snapshot("push_statistics")!.invoke(sample(started: true, fps: 99))
        handler.unregisterPush(); handler.registerPush(includeMetrics: false)
        try await Task.sleep(for: .milliseconds(20))
        check(!handler.started && handler.fps == 29, "old queued sample crossed a session boundary")
        handler.unregisterPush()
        withExtendedLifetime(observer) {}
        print("PASS: statistics gating, metrics delivery and stale-session rejection")
    }
    static func rumble() async throws {
        let channel = FakeChannel()
        var controller: RumbleController? = RumbleController(channel: channel, rumbleMultiplier: 1, restartInterval: 0.06)
        controller!.rumble(lowFreq: 1, highFreq: 0)
        try await Task.sleep(for: .milliseconds(40))
        check(channel.counts.updates == 0 && channel.counts.restarts == 0, "inactive controller runs haptics")
        controller!.setActive(true)
        controller!.rumble(lowFreq: 1, highFreq: 0, durationMs: 40)
        controller!.rumble(lowFreq: 0.5, highFreq: 0, durationMs: 500)
        try await Task.sleep(for: .milliseconds(200))
        check(channel.counts.updates >= 2 && channel.counts.restarts > 0 && channel.counts.stops == 0,
              "old duration stopped a newer rumble, or active rumble did not renew")
        controller!.setActive(false)
        try await Task.sleep(for: .milliseconds(50))
        let paused = channel.counts
        check(paused.stops > 0, "pause did not stop players")
        try await Task.sleep(for: .milliseconds(200))
        check(channel.counts.updates == paused.updates && channel.counts.restarts == paused.restarts,
              "paused rumble timers kept firing")
        controller!.setActive(true)
        try await Task.sleep(for: .milliseconds(80))
        check(channel.counts.updates == paused.updates, "resume replayed an obsolete rumble")
        controller!.rumble(lowFreq: 1, highFreq: 0, durationMs: 25)
        try await Task.sleep(for: .milliseconds(80))
        check(channel.counts.stops > paused.stops, "finite duration never stopped")
        controller!.rumble(lowFreq: 0, highFreq: 0)
        try await Task.sleep(for: .milliseconds(50))
        let zero = channel.counts
        try await Task.sleep(for: .milliseconds(150))
        check(channel.counts.restarts == zero.restarts, "zero amplitude restarts haptic engines")
        weak let weakController = controller
        controller = nil
        check(weakController == nil, "haptic timers retain controller")
        print("PASS: rumble idle, renewal, duration replacement, pause, resume and release")
    }
    static func library() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NSDuo-check-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        let source = temp.appendingPathComponent("source"), root = temp.appendingPathComponent("library")
        for dir in [source, root.appendingPathComponent("Games"), root.appendingPathComponent("Staging")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func fixture(_ name: String, kind: UInt8, version: UInt8, size: Int = 1024) throws -> URL {
            let url = source.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data(repeating: version, count: size)
            data.replaceSubrange(0x100..<0x104, with: Data("HEAD".utf8))
            data[0x180] = kind; data[0x181] = version
            try data.write(to: url)
            return url
        }
        let base = try fixture("base.xci", kind: 0, version: 0, size: 5 * 1024 * 1024 + 31)
        let copy = temp.appendingPathComponent("copy.xci")
        let bytes = try Data(contentsOf: base)
        let hash = try NSDuoFolderIO.streamCopy(base, to: copy, byteCount: Int64(bytes.count), operation: NSDuoImportOperation()) { _ in }
        check(hash == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "streaming digest differs")
        let copied = try Data(contentsOf: copy)
        check(copied == bytes, "multi-chunk copy changed bytes")
        for offset in [-1, 1] {
            expectFailure("changed source size accepted") {
                _ = try NSDuoFolderIO.streamCopy(base, to: temp.appendingPathComponent("bad\(offset)"), byteCount: Int64(bytes.count + offset), operation: NSDuoImportOperation()) { _ in }
            }
        }
        let cancelled = NSDuoImportOperation(); _ = cancelled.cancel()
        expectFailure("cancelled copy continued") {
            _ = try NSDuoFolderIO.streamCopy(base, to: temp.appendingPathComponent("cancel"), byteCount: Int64(bytes.count), operation: cancelled) { _ in }
        }
        let outside = temp.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try bytes.write(to: outside.appendingPathComponent("another-base.xci"))
        try fm.createSymbolicLink(at: source.appendingPathComponent("outside-link"), withDestinationURL: outside)
        var games = try NSDuoFolderIO.scan(source: source, root: root, previous: nil, existing: [], operation: NSDuoImportOperation()) { _ in }
        check(games.count == 1 && games[0].sha256 == hash, "folder import lost streaming digest")
        let manifest = root.appendingPathComponent("manifest.json")
        let date = Date(timeIntervalSince1970: 1_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: games[0], existing: games, operation: NSDuoImportOperation()) { _ in }
        let attributes = try fm.attributesOfItem(atPath: manifest.path)
        check(attributes[.modificationDate] as? Date == date, "unchanged scan rewrote manifest")
        let repeatedWork = WorkCounter()
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: nil, existing: games, operation: NSDuoImportOperation()) { progress in
            if progress.phase == .copying || progress.phase == .decompressing { repeatedWork.increment() }
        }
        if ProcessInfo.processInfo.environment["NSDUO_SKIP_REPEAT_ASSERT"] == nil {
            check(repeatedWork.value == 0, "re-adding the same folder recopied existing content")
        }
        _ = try fixture("wrong-game-dlc.xci", kind: 3, version: 1)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: games[0], existing: games, operation: NSDuoImportOperation()) { _ in }
        repeatedWork.reset()
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: games[0], existing: games, operation: NSDuoImportOperation()) { progress in
            if progress.phase == .copying || progress.phase == .decompressing { repeatedWork.increment() }
        }
        check(repeatedWork.value == 0, "ignored foreign DLC was copied again without source changes")
        // Replacing an ignored source with a matching DLC must invalidate the negative cache.
        _ = try fixture("wrong-game-dlc.xci", kind: 2, version: 0)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: games[0], existing: games, operation: NSDuoImportOperation()) { _ in }
        check(games[0].folder!.files.contains { $0.sourcePath == "wrong-game-dlc.xci" }, "changed ignored file was never reconsidered")
        // Nested changes must be found even if the selected root's mtime is unchanged.
        let rootDate = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        _ = try fixture("任意名称/二级/patch.xci", kind: 1, version: 3)
        _ = try fixture("额外内容/bonus.xci", kind: 2, version: 1)
        try fm.setAttributes([.modificationDate: rootDate], ofItemAtPath: source.path)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: games[0], existing: games, operation: NSDuoImportOperation()) { _ in }
        check(games[0].folder!.selection.update?.content.version == 3 && games[0].folder!.selection.dlc.count == 1,
              "nested DLC/update was skipped")
        let oldPatch = games[0].folder!.selection.update!.file
        let shared = NSDuoLibraryGame(id: UUID(), title: "shared cache reference",
            relativePath: oldPatch.relativePath, sha256: oldPatch.sha256, byteCount: oldPatch.byteCount,
            importedAt: Date(), folder: nil)
        _ = try fixture("任意名称/二级/patch.xci", kind: 1, version: 4)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: games[0], existing: games + [shared], operation: NSDuoImportOperation()) { _ in }
        check(fm.fileExists(atPath: root.appendingPathComponent(oldPatch.relativePath).path), "shared file was deleted")
        let game4 = games.first { $0.folder != nil }!
        let patch4 = game4.folder!.selection.update!.file
        _ = try fixture("任意名称/二级/patch.xci", kind: 1, version: 5)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: game4, existing: games, operation: NSDuoImportOperation()) { _ in }
        check(!fm.fileExists(atPath: root.appendingPathComponent(patch4.relativePath).path), "unreferenced old update remained after commit")
        let game5 = games.first { $0.folder != nil }!
        let patch5 = game5.folder!.selection.update!.file
        let savedManifest = root.appendingPathComponent("saved-manifest")
        try fm.moveItem(at: manifest, to: savedManifest)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        let filesBeforeFailure = Set(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Games").path))
        _ = try fixture("任意名称/二级/patch.xci", kind: 1, version: 6)
        expectFailure("failed manifest commit was accepted") {
            _ = try NSDuoFolderIO.scan(source: source, root: root, previous: game5, existing: games, operation: NSDuoImportOperation()) { _ in }
        }
        check(fm.fileExists(atPath: root.appendingPathComponent(patch5.relativePath).path), "failed commit deleted playable old update")
        let filesAfterFailure = Set(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Games").path))
        check(filesBeforeFailure == filesAfterFailure, "failed commit leaked temporary content")
        try fm.removeItem(at: manifest)
        try fm.moveItem(at: savedManifest, to: manifest)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: game5, existing: games, operation: NSDuoImportOperation()) { _ in }
        games.sort { $0.folder != nil && $1.folder == nil }
        // Previously imported files are app-owned and survive source disappearance.
        try fm.removeItem(at: base)
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: games[0], existing: games, operation: NSDuoImportOperation()) { _ in }
        check(games[0].folder!.selection.base != nil, "scan discarded app-owned base")
        // Reusing the same directory for a different game must still import it.
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) { try fm.removeItem(at: item) }
        _ = try fixture("different-base.xci", kind: 4, version: 2)
        let oldIDs = Set(games.map(\.id))
        games = try NSDuoFolderIO.scan(source: source, root: root, previous: nil, existing: games, operation: NSDuoImportOperation()) { _ in }
        check(games.contains { !oldIDs.contains($0.id) && $0.folder?.applicationID == "0100000000002000" }, "manual re-add locked a repurposed folder to the old game")
        print("PASS: streaming hash/copy, size changes, cancellation, unchanged manifest, nested content, shared-file retention and commit-safe reclamation")
    }
    @MainActor static func inputLifecycle() async throws {
        var slots = NSDuoTouchSlots<String>()
        let first = slots.begin("first")!, second = slots.begin("second")!
        check(first != second, "two contacts shared an ID")
        check(slots.end("first") == first && slots.index(for: "second") == second,
              "lifting first contact renumbered second")
        check(slots.begin("third") == first, "released slot was not reused")
        check(Set(slots.releaseAll()) == Set([first, second]), "reset did not release all native IDs")
        check(slots.end("second") == nil, "late touch end survived reset")
        for index in 0..<16 { check(slots.begin(String(index)) != nil, "touch capacity too small") }
        check(slots.begin("overflow") == nil, "touch capacity exceeded HID limit")

        let session = ControllerMotionSession()
        var samples = 0
        let old = session.setActive(true)!
        check(session.setActive(true) == nil, "duplicate activation restarted sensors")
        session.withActive(old) { samples += 1 }
        _ = session.setActive(false)
        session.withActive(old) { samples += 1 }
        let current = session.setActive(true)!
        session.withActive(old) { samples += 1 }
        session.withActive(current) { samples += 1 }
        check(samples == 2, "paused or previous-session motion sample was delivered")

        let menu = InGameConfigView_MenuView()
        var publications = 0
        let observer = menu.objectWillChange.sink { publications += 1 }
        for _ in 0..<500 { menu.triggerButton() }
        check(publications == 1 && menu.showButton, "touch movement repeatedly invalidated menu")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        menu.triggerButton()
        try await Task.sleep(nanoseconds: 2_300_000_000)
        check(menu.showButton, "old deadline hid recently used controls")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        check(!menu.showButton && publications == 2, "extended deadline never hid controls")
        menu.triggerButton(); menu.hide(); menu.triggerButton()
        await Task.yield()
        check(menu.showButton, "cancelled task hid a new visibility session")
        menu.hide(); observer.cancel()
        print("PASS: stable touch slots, motion generations, coalesced menu publication/deadlines")
    }
    @MainActor static func main() async throws {
        var hold = NSDuoHoldConfirmation()
        check(hold.begin(at: 10), "hold could not begin")
        check(!hold.begin(at: 11), "duplicate touch restarted hold")
        for tick in 1..<50 { check(!hold.advance(at: 10 + Double(tick) / 10), "hold finished before five seconds") }
        check(!hold.advance(at: 14.999), "hold finished early")
        check(hold.progress < 1 && hold.hapticIntensity <= 0.3, "invalid progress or excessive haptic intensity")
        check(hold.advance(at: 15) && hold.completed && hold.progress == 1, "five-second hold did not complete")
        check(!hold.advance(at: 15.1) && !hold.begin(at: 16), "completed hold could delete twice")
        hold.cancel()
        check(hold.completed, "release after completion rearmed removal")
        var cancelled = NSDuoHoldConfirmation()
        check(cancelled.begin(at: 0), "cancellation fixture failed")
        for tick in 1...49 { check(!cancelled.advance(at: Double(tick) / 10), "hold ended early") }
        cancelled.cancel()
        check(cancelled.progress == 0 && !cancelled.advance(at: 5), "release did not cancel and reset progress")
        check(cancelled.begin(at: 10), "cancelled hold could not restart")
        check(!cancelled.advance(at: 15) && !cancelled.isHolding && cancelled.progress == 0, "suspended UI completed a destructive hold")
        check(cancelled.begin(at: 20), "interrupted hold could not restart")
        check(!cancelled.advance(at: 19) && !cancelled.isHolding, "backward time completed a hold")
        var ramp = NSDuoHoldConfirmation()
        check(ramp.begin(at: 0), "ramp fixture failed")
        var lastIntensity = ramp.hapticIntensity
        for tick in 1...50 {
            _ = ramp.advance(at: Double(tick) / 10)
            check(ramp.hapticIntensity >= lastIntensity && ramp.hapticIntensity <= 0.3, "haptic ramp is not gentle and increasing")
            lastIntensity = ramp.hapticIntensity
        }
        print("PASS: five-second hold, no early or duplicate removal, release/interruption reset and gentle haptic ramp")
        try await inputLifecycle()
        callbacks()
        try library()
        try await statistics()
        try await rumble()
    }
}
