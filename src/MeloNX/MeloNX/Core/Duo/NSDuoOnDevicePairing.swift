import Foundation
import UIKit
import UserNotifications
import Combine

/// Shows the protocol PIN while a system continued-processing task keeps pairing alive.
@MainActor
final class NSDuoOnDevicePairing {
    static let shared = NSDuoOnDevicePairing()
    private let notifications = UNUserNotificationCenter.current()
    private let pinNotification = "com.nsduo.pairing.pin"
    private let background = NSDuoPairingBackgroundSession.shared
    private var expired = false
    private var cancelled = false
    private var observing = Set<AnyCancellable>()
    private var diagnosticEvents = [[String: Any]]()
    private var diagnosing = false

    private init() {
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.record(name == UIApplication.didBecomeActiveNotification ? "foreground" : "background")
                    }
                }.store(in: &observing)
        }
    }

    func start(progress: @escaping (String) -> Void, pin: @escaping (String) -> Void,
               completion: @escaping (Data?, Error?) -> Void) async {
        diagnosticEvents = []
        diagnosing = true
        record("start")
        // Optional: users may return to the app to read the code if notifications are denied.
        _ = try? await notifications.requestAuthorization(options: [.alert, .sound])
        guard !Task.isCancelled else { completion(nil, CancellationError()); return }
        expired = false
        cancelled = false
        do {
            try await background.begin { [weak self] in
                self?.expired = true
                self?.record("expired")
                NSDuoPairingBridge.cancel()
            }
            try Task.checkCancellation()
        } catch {
            record("backgroundStartFailed", error: error)
            background.finish(success: false)
            completion(nil, error)
            return
        }
        guard background.isActive, !expired else {
            completion(nil, NSError(domain: "NSDuoOnDevicePairing", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "系统已中止配对后台任务，请回到 NS Duo 后重试。"]))
            return
        }
        record("backgroundTaskActive")
        NSDuoPairingBridge.start(progress: { [weak self] stage in
            self?.record(stage)
            progress(stage)
            if stage == "published" {
                self?.background.update(subtitle: "请到系统开发者模式选择 NS Duo，先输入设备解锁密码", completedUnits: 20)
            } else if stage == "connected" {
                self?.background.update(subtitle: "系统已连接，正在交换配对信息", completedUnits: 40)
            }
        }, pin: { [weak self] code in
            guard let self else { return }
            record("pinReceived")
            pin(code)
            background.update(subtitle: "配对码：\(code) · 请在系统设置中输入", completedUnits: 70)
            showNotification(id: pinNotification, title: "NS Duo 配对验证码",
                             body: "验证码：\(code)。请在系统开发者模式中输入。")
        }, completion: { [weak self] data, error in
            self?.record(data == nil ? "protocolEnded" : "recordReceived", error: error)
            if self?.expired == true {
                let message = "系统已结束或取消本次配对任务。请回到 NS Duo 重新开始，原有记录仍保留。"
                completion(nil, NSError(domain: "NSDuoOnDevicePairing", code: 4,
                                        userInfo: [NSLocalizedDescriptionKey: message]))
            } else if self?.cancelled == true { completion(nil, CancellationError()) }
            else { completion(data, error) }
        })
    }

    func cancel() {
        record("cancel")
        cancelled = true
        background.cancelPendingStart()
        NSDuoPairingBridge.cancel()
    }

    func finish(saved: Bool) {
        record(saved ? "saved" : "ended")
        diagnosing = false
        notifications.removePendingNotificationRequests(withIdentifiers: [pinNotification])
        notifications.removeDeliveredNotifications(withIdentifiers: [pinNotification])
        if saved {
            showNotification(id: "com.nsduo.pairing.complete", title: "NS Duo 配对完成",
                             body: "配对记录已保存。请返回 NS Duo，连接 VPN 后开启 JIT。")
        }
        background.finish(success: saved)
    }

    private func record(_ stage: String, error: Error? = nil) {
        guard diagnosing else { return }
        // Store stages only, never the PIN, protocol data, addresses or pairing keys.
        var event: [String: Any] = ["stage": stage,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "appState": UIApplication.shared.applicationState.rawValue,
            "backgroundTaskActive": background.isActive]
        if let error {
            event["errorDomain"] = (error as NSError).domain
            event["errorCode"] = (error as NSError).code
        }
        diagnosticEvents.append(event)
        diagnosticEvents = Array(diagnosticEvents.suffix(32))
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NSDuoPairing", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: [
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "events": diagnosticEvents
            ], options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("flow.json"), options: .atomic)
        } catch { print("NSDuo pairing stage diagnostics could not be saved.") }
    }

    private func showNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        notifications.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }

}
