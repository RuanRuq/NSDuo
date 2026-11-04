import Foundation
import Darwin

@main struct Checks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let fd = open(original.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        precondition(fd >= 0)
        defer { close(fd) }
        let logs = root.appendingPathComponent("logs")
        let logger = NSDuoConsoleLog(destinations: [fd], segmentBytes: 32)
        try logger.start(in: logs)
        func writeBytes(_ text: String) { text.withCString { precondition(write(fd, $0, strlen($0)) == strlen($0)) } }
        for index in 0..<4 {
            writeBytes(String(repeating: String(index), count: 32))
            logger.rotateIfNeeded()
        }
        writeBytes("tail")
        logger.stop()
        writeBytes("restored")
        let retained = try fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        precondition(retained.count == 2, "only current and previous segments")
        let values = try retained.map { try String(contentsOf: $0, encoding: .utf8) }
        precondition(values.contains("tail") && values.contains(String(repeating: "3", count: 32)))
        let restored = try String(contentsOf: original, encoding: .utf8)
        precondition(restored == "restored", "restore destination on stop")
        try logger.start(in: logs)
        writeBytes("second run")
        logger.stop()
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: logs)
        do { try logger.start(in: link); preconditionFailure("reject symlink log directory") } catch { }
        writeBytes(" after failed start")
        let afterFailure = try String(contentsOf: original, encoding: .utf8)
        precondition(afterFailure == "restored after failed start")

        let suite = "NSDuo.MotionChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(NSDuoMotionPreferences.isEnabled(titleID: "ABCD", defaults: defaults))
        NSDuoMotionPreferences.setEnabled(false, titleID: "ABCD", defaults: defaults)
        precondition(!NSDuoMotionPreferences.isEnabled(titleID: "abcd", defaults: defaults))
        precondition(NSDuoMotionPreferences.isEnabled(titleID: "OTHER", defaults: defaults))
        NSDuoMotionPreferences.setEnabled(true, titleID: "abcd", defaults: defaults)
        precondition(NSDuoMotionPreferences.isEnabled(titleID: "ABCD", defaults: defaults))
        let session = ControllerMotionSession()
        let controllerGeneration = session.setActive(true)!
        precondition(session.withActive(controllerGeneration) {})
        let phoneGeneration = session.setActive(true, useDeviceMotion: true)!
        precondition(!session.withActive(controllerGeneration) {}, "switching sources rejects queued external-controller samples")
        precondition(session.withActive(phoneGeneration) {})
        precondition(session.setActive(true, useDeviceMotion: true) == nil)
        _ = session.setActive(false)
        precondition(!session.withActive(phoneGeneration) {}, "pause rejects queued phone samples")
        print("PASS: console rotation, descriptor restoration, repeated sessions, symlink rejection and per-game motion preferences")
    }
}
