import Foundation
import Combine

struct UIImage: Sendable { let marker: Int }
enum UIApplication { static let didReceiveMemoryWarningNotification = Notification.Name("MemoryWarning") }
struct GameInfo: Sendable { var titleId = "0100000000000000" }
final class Probe: @unchecked Sendable {
    static let shared = Probe()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var active = 0
    var gate: DispatchSemaphore?
    var blockCover = false
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name, default: 0] }
    func enter(_ name: String, wait: Bool = false) {
        lock.lock(); active += 1; precondition(active == 1, "native metadata workers overlapped")
        counts[name, default: 0] += 1; let current = gate; lock.unlock()
        if wait { precondition(current?.wait(timeout: .now() + 5) == .success, "controlled worker timed out") }
        lock.lock(); active -= 1; lock.unlock()
    }
}
nonisolated enum NSDuoLaunchMetadata {
    enum Failure: Error { case resourcesMissing }
    static func resourcesReady() -> Bool { true }
}
nonisolated enum Ryujinx {
    static func reloadKeySet() {}
    static func getGameInfo(arg0: Int32, arg1: NSString, path: URL) -> GameInfo {
        Probe.shared.enter("metadata", wait: true); return GameInfo()
    }
}
@MainActor final class RyujinxController {
    enum State { case started, stopped, crashed }
    static let shared = RyujinxController()
    var isRunning = State.stopped
}
nonisolated enum Fixture {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-fixture-\(UUID())")
    static let url = root.appendingPathComponent("base.xci")
    static var game: NSDuoLibraryGame {
        .init(id: UUID(), title: "Base", relativePath: "base.xci", sha256: String(repeating: "a", count: 64), byteCount: 512,
              importedAt: Date(), folder: .init(bookmark: Data([1]), applicationID: "0100000000000000", files: []))
    }
}
nonisolated enum NSDuoLibraryIO {
    struct Loaded: Sendable { let root: URL; let games: [NSDuoLibraryGame] }
    static func load() throws -> Loaded { .init(root: Fixture.root, games: [Fixture.game]) }
    static func checkedURL(for game: NSDuoLibraryGame, root: URL) throws -> URL { Fixture.url }
    static func save(_ games: [NSDuoLibraryGame], root: URL) throws {}
    static func remove(_ game: NSDuoLibraryGame, root: URL, remaining: [NSDuoLibraryGame]) throws -> String? { nil }
}
nonisolated enum NSDuoFolderIO {
    static func accepts(_ url: URL) -> Bool { true }
    static func resolve(_ folder: NSDuoFolderRecord) throws -> URL { Fixture.root }
    static func scan(source: URL, root: URL, previous: NSDuoLibraryGame?, existing: [NSDuoLibraryGame], operation: NSDuoImportOperation,
                     progress: @escaping @Sendable (NSDuoImportProgress) -> Void) throws -> [NSDuoLibraryGame] {
        if Probe.shared.count("scan") == 0 { Probe.shared.enter("scan", wait: true) }
        else { Probe.shared.enter("scan") }
        try operation.checkCancellation(); return existing
    }
    static func configure(_ game: NSDuoLibraryGame, root: URL) throws { Probe.shared.enter("configure") }
    static func cache(source: URL, sourcePath: String, root: URL, operation: NSDuoImportOperation, created: inout Set<URL>,
                      progress: @escaping @Sendable (NSDuoImportProgress) -> Void) throws -> NSDuoFolderFile { fatalError("unused boundary") }
}
nonisolated enum NSDuoCoverIO {
    struct Prepared: Sendable { let image: UIImage; let cost: Int }
    static func preparedImage(for game: NSDuoLibraryGame, root: URL) -> Prepared? {
        Probe.shared.enter("cover", wait: Probe.shared.blockCover); return .init(image: UIImage(marker: 1), cost: 768 * 768 * 4)
    }
}
@main struct LibrarySchedulingChecks {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        preconditionFailure("condition timed out")
    }
    @MainActor static func main() async throws {
        try FileManager.default.createDirectory(at: Fixture.root, withIntermediateDirectories: true)
        try Data(count: 512).write(to: Fixture.url)
        defer { try? FileManager.default.removeItem(at: Fixture.root) }
        let store = NSDuoLibraryStore()
        store.loadIfNeeded(); try await wait { store.isReady }
        precondition(Probe.shared.count("cover") == 0 && store.covers.isEmpty, "library eagerly decoded invisible artwork")
        let game = store.games[0]
        Probe.shared.gate = DispatchSemaphore(value: 0)
        store.checkFolders(); try await wait { Probe.shared.count("scan") == 1 }
        precondition(store.canPrepareLaunch, "automatic folder scan prevents launch request")
        var ready = false
        store.prepareForLaunch(game) { _ in ready = true }
        precondition(store.isPreparingLaunch, "launch lease not held")
        try await Task.sleep(for: .milliseconds(30))
        precondition(!ready && Probe.shared.count("configure") == 0, "launch did not wait for cancelled worker to exit")
        store.cancelImport()
        Probe.shared.gate!.signal()
        try await wait { !store.isPreparingLaunch }
        precondition(!ready && Probe.shared.count("configure") == 0, "cancelled queued launch still configured a game")
        store.prepareForLaunch(game) { _ in ready = true }
        try await wait { ready }
        precondition(Probe.shared.count("scan") == 2 && Probe.shared.count("configure") == 1)
        Probe.shared.gate = DispatchSemaphore(value: 0)
        var metadataReady = false
        store.prepareLaunchMetadata(at: Fixture.url) { _ in metadataReady = true }
        try await wait { Probe.shared.count("metadata") == 1 }
        precondition(store.isBusy && !metadataReady, "metadata parsing released launch lease early")
        // We reached the MainActor while the native read is blocked on another thread.
        store.cancelImport(); Probe.shared.gate!.signal()
        try await wait { !store.isPreparingLaunch }
        precondition(!metadataReady, "cancelled metadata read launched the game")
        store.requestCover(for: game); try await wait { store.covers[game.id] != nil }
        precondition(Probe.shared.count("cover") == 1)
        store.requestCover(for: game); try await Task.sleep(for: .milliseconds(20))
        precondition(Probe.shared.count("cover") == 1, "cached visible artwork was decoded again")
        store.releaseCovers(); precondition(store.covers.isEmpty)
        store.requestCover(for: game); try await wait { store.covers[game.id] != nil }
        precondition(Probe.shared.count("cover") == 2, "evicted artwork could not reload")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await wait { Probe.shared.count("cover") == 3 && store.covers[game.id] != nil }
        // A new visibility request must survive cancellation of an older read.
        store.releaseCovers()
        Probe.shared.gate = DispatchSemaphore(value: 0)
        Probe.shared.blockCover = true
        store.requestCover(for: game)
        try await wait { Probe.shared.count("cover") == 4 }
        store.releaseCovers()
        store.requestCover(for: game)
        Probe.shared.blockCover = false
        Probe.shared.gate!.signal()
        try await wait { Probe.shared.count("cover") == 5 && store.covers[game.id] != nil }
        var budget = NSDuoCoverBudget(limit: 10)
        let a = UUID(), b = UUID(), c = UUID()
        precondition(budget.insert(a, cost: 4).isEmpty && budget.insert(b, cost: 4).isEmpty)
        budget.touch(a)
        precondition(budget.insert(c, cost: 5) == [b] && budget.totalCost == 9)
        precondition(budget.insert(a, cost: 11) == [a] && budget.totalCost == 5)
        budget.removeAll(); precondition(budget.totalCost == 0)
        print("PASS: automatic-scan preemption, worker serialization, responsive metadata cancellation, visible-only covers, cache reuse/reload, memory warning and hard LRU cost limit")
    }
}
