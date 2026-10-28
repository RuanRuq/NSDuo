import Foundation
import StikJIT

@objc(NSDuoJITHelper)
nonisolated final class NSDuoJITHelper: NSObject, NSExtensionRequestHandling {
    // StikJIT blocks until the debugger/script has finished. Never move its
    // operations onto the host/main queue or split them into concurrent tasks.
    private static let worker = DispatchQueue(label: "com.nsduo.jit.helper", qos: .userInitiated)

    func beginRequest(with context: NSExtensionContext) {
        guard context.inputItems.count == 1,
              let item = context.inputItems.first as? NSExtensionItem,
              let data = item.userInfo?[NSDuoJITMessage.payloadKey] as? Data,
              data.count <= NSDuoJITMessage.maximumPayloadBytes,
              let request = try? JSONDecoder().decode(NSDuoJITRequest.self, from: data) else {
            context.cancelRequest(withError: HelperError.message("JIT 辅助请求格式无效。"))
            return
        }

        let pending = PendingContext(context)
        Self.worker.async {
            let response = Self.perform(request)
            do {
                let output = NSExtensionItem()
                output.userInfo = [NSDuoJITMessage.payloadKey: try JSONEncoder().encode(response)]
                // No synchronous callback to the host: it may currently be stopped
                // at a breakpoint that this helper must service before returning.
                pending.context.completeRequest(returningItems: [output], completionHandler: nil)
            } catch {
                pending.context.cancelRequest(withError: HelperError.message("无法编码 JIT 辅助结果。"))
            }
        }
    }

    private static func perform(_ request: NSDuoJITRequest) -> NSDuoJITResponse {
        func result(_ success: Bool, _ message: String, txm: Bool? = StikJIT.isTXMPresent) -> NSDuoJITResponse {
            NSDuoJITResponse(requestID: request.requestID, success: success, message: message, txmPresent: txm)
        }

        do {
            let manager = FileManager.default
            let library = try manager.url(for: .libraryDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
            var cache = library.appendingPathComponent("StikJIT", isDirectory: true)
            try manager.createDirectory(at: cache, withIntermediateDirectories: true)
            var excludedFromBackup = URLResourceValues()
            excludedFromBackup.isExcludedFromBackup = true
            try cache.setResourceValues(excludedFromBackup)
            let paths = DDIPaths.default(in: cache)

            // A killed extension cannot run defer; remove only our stale private
            // temporary pairing files on its next serial operation as well.
            let pairingDirectory = library.appendingPathComponent("NSDuoJITPairing", isDirectory: true)
            if manager.fileExists(atPath: pairingDirectory.path) {
                try manager.removeItem(at: pairingDirectory)
            }

            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return result(true, "开发者镜像缓存已清理；设备重启前已挂载的镜像仍可能有效。")
            }

            guard request.targetPID > 0, request.targetPID != getpid() else {
                throw HelperError.message("JIT 目标进程无效，请重新从主 App 发起。")
            }
            guard let pairing = request.pairingData, !pairing.isEmpty,
                  pairing.count <= NSDuoJITMessage.maximumPairingBytes else {
                throw HelperError.message("请先导入有效的设备配对文件。")
            }
            guard let port = request.rsdPort, port > 0 else {
                throw HelperError.message("本地 VPN 尚未提供有效的设备连接端口。")
            }
            let configuration = StikJIT.Configuration(deviceAddress: "10.7.0.1", rsdPort: port,
                                                     connectionTimeout: 5)
            try manager.createDirectory(at: pairingDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700,
                                                     .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            defer { try? manager.removeItem(at: pairingDirectory) }
            var privateDirectory = pairingDirectory
            try privateDirectory.setResourceValues(excludedFromBackup)
            let pairingFile = pairingDirectory.appendingPathComponent(request.requestID.uuidString + ".plist")
            try pairing.write(to: pairingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingFile.path)

            switch request.operation {
            case .enable:
                guard Bundle(identifier: "com.stik.StikJIT")?
                    .object(forInfoDictionaryKey: "NSDuoJITAddressBits") as? Int == 64 else {
                    throw HelperError.message("内置 JIT 组件需要更新，请使用新版构建脚本重新编译安装 NS Duo。")
                }
                guard let script = request.scriptBase64,
                      script.utf8.count <= NSDuoJITMessage.maximumScriptBytes * 2,
                      let source = Data(base64Encoded: script), !source.isEmpty,
                      source.count <= NSDuoJITMessage.maximumScriptBytes,
                      String(data: source, encoding: .utf8) != nil else {
                    throw HelperError.message("主 App 的固定 JIT 脚本无效，请重新安装。")
                }
                // The host's allocator owns its breakpoint protocol. Force its
                // fixed script when it will issue BRK; do not leave that choice
                // to a different framework's hardware detection heuristic.
                if !request.requiresScript && StikJIT.isTXMPresent != false {
                    throw HelperError.message("核心与调试框架未能一致确认 JIT 模式，请重新启动或更新 NS Duo。")
                }
                try StikJIT.enableJIT(targetPID: request.targetPID, pairingFile: pairingFile,
                                     ddiPaths: paths, configuration: configuration,
                                     script: .customBase64(script), forceScript: request.requiresScript)
                return result(true, "JIT 辅助操作已完成，正在由主 App 验证执行核心。")
            case .prepare:
                switch StikJIT.prepareDevice(pairingFile: pairingFile, paths: paths, configuration: configuration) {
                case .ready(let state):
                    return result(true, "设备调试环境已就绪。", txm: state.isTXMPresent)
                case .unreachable(let reason):
                    return result(false, "无法连接设备：\(reason)")
                case .preparationFailed(let reason):
                    return result(false, "设备准备失败：\(reason)")
                @unknown default:
                    return result(false, "当前 JIT 框架返回了无法识别的准备状态。")
                }
            case .resetDDI:
                preconditionFailure("Reset is handled before pairing data is requested")
            }
        } catch {
            // Do not log request data, pairing contents or scripts. Upstream
            // errors preserve useful reachability/download/mount diagnostics.
            return result(false, error.localizedDescription)
        }
    }
}

private nonisolated final class PendingContext: @unchecked Sendable {
    let context: NSExtensionContext
    init(_ context: NSExtensionContext) { self.context = context }
}

private nonisolated enum HelperError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
