import Foundation
import Combine
import UIKit

/// Owns preparation independently of any particular game view. Leaving a game
/// cancels its auto-launch, never kills a debugger while the host is stopped.
@MainActor
final class NSDuoIntegratedJIT: ObservableObject {
    static let shared = NSDuoIntegratedJIT()

    enum Phase: Equatable {
        case idle, needsPairing, importing, connecting, preparing, ready, failed, resetting
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "先连接 VPN，再点击“开启 JIT”。本次运行只需准备一次。"
    @Published private(set) var hasPairing = false
    @Published private(set) var pairingName = ""
    @Published private(set) var errorMessage: String?

    var isBusy: Bool { [.importing, .connecting, .preparing, .resetting].contains(phase) }
    var isReady: Bool { verifiedSessionComplete && phase == .ready && RyujinxController.shared.hasPreparedJIT }

    private var task: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var verifiedSessionComplete = false
    private var coreVerified = false
    private var helperSucceeded = false

    private init() { refreshPairingStatus() }

    func refreshPairingStatus() {
        hasPairing = (try? NSDuoPairingStore.read()) != nil
        pairingName = hasPairing ? "本机配对记录已保存" : "尚未导入本机配对记录"
        if verifiedSessionComplete, RyujinxController.shared.hasPreparedJIT, !isBusy {
            phase = .ready
            status = "本次运行已就绪，可以直接启动游戏。"
        }
    }

    func importPairing(from source: URL) async {
        guard !isBusy else { return }
        phase = .importing
        status = "正在保存本机配对记录…"
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try await Task.detached(priority: .userInitiated) {
                try NSDuoPairingStore.importFile(source)
            }.value
            errorMessage = nil
            phase = .idle
            status = "配对记录已保存。首次连接时请允许系统添加本地 VPN。"
            refreshPairingStatus()
        } catch { fail(error.localizedDescription) }
    }

    /// Step one intentionally never discovers a device or launches the JIT helper.
    func connectVPN() {
        guard !isBusy, !NSDuoJITExtensionBridge.isActive else { return }
        guard preflight() else { return }
        phase = .connecting
        errorMessage = nil
        status = "正在连接内置本地 VPN…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await NSDuoVPNManager.shared.connect()
                phase = .idle
                status = "VPN 已连接。完成网络切换后，请点击“开启 JIT”。"
                refreshPairingStatus()
            } catch { fail(error.localizedDescription) }
        }
    }

    /// Step two requires an existing tunnel and must not reconnect it after the
    /// user has intentionally changed network/airplane-mode settings.
    func enableJIT() {
        guard !isBusy, !NSDuoJITExtensionBridge.isActive else { return }
        // Reading this marker does not execute the breakpoint protocol. CS_DEBUGGED
        // alone can remain set after a failed or detached debug session.
        if verifiedSessionComplete && RyujinxController.shared.hasPreparedJIT {
            phase = .ready
            status = "本次运行已就绪，可以直接启动游戏。"
            return
        }
        guard preflight() else { return }
        guard NSDuoVPNManager.shared.connected else {
            fail("请先点击上方“连接 VPN”，连接成功后再开启 JIT。")
            return
        }
        guard !checkDebugged(), !RyujinxController.shared.hasPreparedJIT else {
            // CS_DEBUGGED is sticky after detachment. A previous incomplete
            // attach must never authorize BRK before this new helper attaches.
            fail("当前进程已有未完成的调试状态。请彻底退出 NS Duo，再从手机桌面打开后重试；不要同时连接 Xcode 调试器。")
            return
        }
        let pairingData: Data
        do { pairingData = try NSDuoPairingStore.read() }
        catch {
            phase = .needsPairing
            status = "首次使用，请导入这台手机已配好的配对记录。只需一次。"
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        verifiedSessionComplete = false
        phase = .preparing
        status = "正在发现本机调试服务…"
        coreVerified = false
        helperSucceeded = false
        let requestID = UUID()
        activeRequestID = requestID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let port = await NSDuoRemotePairingDiscovery.resolve()
                guard activeRequestID == requestID else { return }
                let request = NSDuoJITRequest(requestID: requestID, operation: .enable,
                    targetPID: getpid(), pairingData: pairingData,
                    scriptBase64: EnableJIT.nsDuoScriptBase64, rsdPort: port,
                    requiresScript: ProcessInfo.processInfo.hasTXM)
                phase = .preparing
                status = "正在准备调试环境并开启 JIT。首次可能需要下载，请保持 App 在前台。"
                try send(request)
            } catch { fail(error.localizedDescription) }
        }
    }

    func resetDeveloperImage() {
        guard !isBusy, !NSDuoJITExtensionBridge.isActive else { return }
        guard preflight() else { return }
        let id = UUID()
        activeRequestID = id
        errorMessage = nil
        phase = .resetting
        status = "正在清理内置调试环境缓存…"
        do {
            try send(NSDuoJITRequest(requestID: id, operation: .resetDDI, targetPID: getpid(),
                                    pairingData: nil, scriptBase64: nil, rsdPort: nil))
        } catch { fail(error.localizedDescription) }
    }

    private func preflight() -> Bool {
        guard #available(iOS 26.0, *), getenv("LC_HOME_PATH") == nil else {
            fail("内置运行需要 iOS 26 或更高版本，并直接安装 NS Duo。")
            return false
        }
        guard checkAppEntitlement("get-task-allow") else {
            fail("当前安装包没有调试权限，需要使用保留 get-task-allow 的开发签名重新安装。")
            return false
        }
        guard let plugins = Bundle.main.builtInPlugInsURL,
              Bundle(url: plugins.appendingPathComponent("NSDuoJITHelper.appex")) != nil,
              Bundle(url: plugins.appendingPathComponent("NSDuoTunnel.appex")) != nil else {
            fail("当前安装包缺少内置运行扩展，请安装包含两个扩展的新版 NS Duo。")
            return false
        }
        return true
    }

    private func send(_ request: NSDuoJITRequest) throws {
        let data = try JSONEncoder().encode(request)
        NSDuoJITExtensionBridge.startRequest(data, started: { [weak self] in
            guard let self, activeRequestID == request.requestID else { return }
            if request.operation == .enable { pollCoreReadiness(for: request.requestID) }
        }, completion: { [weak self] data, error in
            guard let self, activeRequestID == request.requestID else { return }
            if let error { fail(error.localizedDescription); return }
            guard let data,
                  let response = try? JSONDecoder().decode(NSDuoJITResponse.self, from: data),
                  response.requestID == request.requestID else {
                fail("内置运行扩展未返回有效结果，请重试。")
                return
            }
            guard response.success else { fail(response.message); return }
            if request.operation == .resetDDI {
                activeRequestID = nil
                phase = .idle
                status = "调试缓存已清理，下次启动会自动重新准备。"
                refreshPairingStatus()
                return
            }
            helperSucceeded = true
            if !coreVerified && !ProcessInfo.processInfo.hasTXM {
                // Without TXM there is no breakpoint to service after detachment.
                coreVerified = RyujinxController.shared.isJITEnabled
            }
            if coreVerified { finishReady() }
            else { fail("调试流程已结束，但核心尚未完成 JIT 内存准备。请重试；若持续出现，请重新启动 NS Duo。") }
        })
    }

    private func pollCoreReadiness(for id: UUID) {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, activeRequestID == id, phase == .preparing {
                // The helper services the fixed script while this call initializes
                // executable regions. Never try this after an unsuccessful detach.
                if NSDuoJITExtensionBridge.isActive, UIApplication.shared.applicationState == .active,
                   checkDebugged(), RyujinxController.shared.isJITEnabled {
                    coreVerified = true
                    if helperSucceeded { finishReady() }
                    else { status = "JIT 内存已准备好，正在完成连接…" }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
        }
    }

    private func finishReady() {
        readinessTask?.cancel()
        activeRequestID = nil
        verifiedSessionComplete = true
        phase = .ready
        status = "本次运行已就绪，可以直接启动游戏。"
        errorMessage = nil
    }

    private func fail(_ message: String) {
        readinessTask?.cancel()
        activeRequestID = nil
        phase = .failed
        let explanation: String
        if message.contains("Timed out connecting to 10.7.0.1:") {
            explanation = "本机 JIT 服务连接超时。仅使用 4G/5G 时，本地 VPN 可能无法连通。请连接 Wi-Fi 后重试“开启 JIT”；VPN 显示已连接并不代表 JIT 已就绪。"
        } else {
            explanation = message
        }
        errorMessage = explanation
        status = explanation
        // The helper is never force-killed here. Its request completion owns
        // the lifetime of a debugger which may have stopped the host process.
    }
}

nonisolated private enum NSDuoPairingStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NSDuoJIT/pairingFile.plist")
    }

    static func read() throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...1_048_576).contains(size) else {
            throw error("配对记录不存在或大小不正确，请重新导入。")
        }
        let data = try Data(contentsOf: url)
        try validate(data)
        return data
    }

    static func importFile(_ source: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { source in
            result = Result {
                let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, (1...1_048_576).contains(size) else {
                    throw error("请选择有效的 .plist 或 .mobiledevicepairing 配对文件。")
                }
                let data = try Data(contentsOf: source)
                try validate(data)
                var directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var attributes = URLResourceValues()
                attributes.isExcludedFromBackup = true
                try directory.setResourceValues(attributes)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? error("无法读取配对文件。")
    }

    private static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 1_048_576,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["public_key"] != nil else {
            throw error("这不是新版远程配对记录。请选择此前在 StikDebug 中成功使用的配对文件；不要选择游戏密钥或旧 USB 配对文件。")
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "NSDuoPairing", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
