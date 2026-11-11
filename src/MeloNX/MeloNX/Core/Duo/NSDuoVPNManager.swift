//
//  NSDuoVPNManager.swift
//  MeloNX
//

import Combine
import Foundation
import NetworkExtension
import os

@MainActor
final class NSDuoVPNManager: ObservableObject {
    static let shared = NSDuoVPNManager()
    private static let networkExtensionEntitlement = "com.apple.developer.networking.networkextension"

    @Published private(set) var connected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var statusText = "本地隧道未连接"

    private var manager: NETunnelProviderManager?
    private var statusObserver: AnyCancellable?
    private var connectTask: Task<Void, Error>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NSDuo", category: "VPN")

    private init() {
        Task { await restoreStatus() }
    }

    /// Establishes only the local route. JIT must be verified separately by the core.
    func connect() async throws {
        if let connectTask {
            try await connectTask.value
            return
        }
        isConnecting = true
        statusText = "正在准备本地隧道…"
        let task = Task { @MainActor in try await establishConnection() }
        connectTask = task
        defer {
            connectTask = nil
            isConnecting = false
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            updateStatus()
        } catch {
            connected = manager?.connection.status == .connected
            if error is CancellationError {
                statusText = "本地隧道连接已取消"
                throw error
            }
            let systemError = error as NSError
            logger.error("VPN connection failed: \(systemError.domain, privacy: .public) (\(systemError.code, privacy: .public))")
            statusText = "本地隧道连接失败"
            // This error is returned by NetworkExtension when access to VPN preferences is denied.
            if systemError.domain == "NEConfigurationErrorDomain", systemError.code == 10 {
                throw ConnectionError.configurationPermissionDenied
            }
            throw error
        }
    }

    private func establishConnection() async throws {
        let providerID = try embeddedProviderIdentifier()
        let key = Self.networkExtensionEntitlement
        let capabilities = checkAppEntitlements([key])[key] as? [String]
        guard capabilities?.contains("packet-tunnel-provider") == true else {
            throw ConnectionError.missingPacketTunnelEntitlement
        }
        let saved = try await NETunnelProviderManager.loadAllFromPreferences()
        try Task.checkCancellation()
        let ownManagers = saved.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }
        let existing = ownManagers.first(where: { $0.connection.status == .connected }) ?? ownManagers.first
        let selected = existing ?? NETunnelProviderManager()
        observe(selected)

        if selected.connection.status == .connected {
            updateStatus()
            return
        }

        if existing == nil {
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = providerID
            configuration.serverAddress = "10.7.0.1"
            configuration.includeAllNetworks = false
            configuration.excludeLocalNetworks = false
            selected.protocolConfiguration = configuration
            selected.localizedDescription = "NS Duo 本地隧道"
            selected.isEnabled = true
            // The first save invokes iOS's VPN permission sheet. Denial is thrown.
            statusText = "请允许 NS Duo 添加本地 VPN 配置"
            try await selected.saveToPreferences()
            try await selected.loadFromPreferences()
        } else if !selected.isEnabled {
            selected.isEnabled = true
            try await selected.saveToPreferences()
            try await selected.loadFromPreferences()
        }

        try Task.checkCancellation()
        statusText = "正在连接本地隧道…"
        if selected.connection.status != .connecting && selected.connection.status != .reasserting {
            try selected.connection.startVPNTunnel()
        }
        do {
            try await waitForConnection(selected.connection)
        } catch {
            // Cancel only this app's attempt; never remove or alter another VPN profile.
            selected.connection.stopVPNTunnel()
            throw error
        }
    }

    private func waitForConnection(_ connection: NEVPNConnection) async throws {
        let started = ContinuousClock.now
        var observedConnecting = false
        while ContinuousClock.now - started < .seconds(30) {
            try Task.checkCancellation()
            switch connection.status {
            case .connected:
                updateStatus()
                return
            case .connecting, .reasserting:
                observedConnecting = true
            case .invalid:
                throw ConnectionError.invalidConfiguration
            case .disconnected, .disconnecting:
                // startVPNTunnel returns before all status notifications arrive.
                if observedConnecting || ContinuousClock.now - started > .seconds(1) {
                    let error: Error? = await withCheckedContinuation { continuation in
                        connection.fetchLastDisconnectError { continuation.resume(returning: $0) }
                    }
                    throw error ?? ConnectionError.disconnected
                }
            @unknown default:
                throw ConnectionError.disconnected
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ConnectionError.timedOut
    }

    private func embeddedProviderIdentifier() throws -> String {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let provider = Bundle(url: plugins.appendingPathComponent("NSDuoTunnel.appex")),
              let identifier = provider.bundleIdentifier,
              let hostIdentifier = Bundle.main.bundleIdentifier,
              identifier.hasPrefix(hostIdentifier + ".") else {
            throw ConnectionError.missingExtension
        }
        return identifier
    }

    private func restoreStatus() async {
        guard connectTask == nil else { return }
        do {
            let providerID = try embeddedProviderIdentifier()
            let saved = try await NETunnelProviderManager.loadAllFromPreferences()
            guard connectTask == nil else { return }
            let own = saved.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
            }
            if let selected = own.first(where: { $0.connection.status == .connected }) ?? own.first {
                observe(selected)
            }
        } catch {
            guard connectTask == nil else { return }
            statusText = "本地隧道尚未就绪，请点击“连接 VPN”查看原因。"
        }
    }

    private func observe(_ selected: NETunnelProviderManager) {
        manager = selected
        statusObserver = NotificationCenter.default.publisher(for: .NEVPNStatusDidChange, object: selected.connection)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatus() }
            }
        updateStatus()
    }

    private func updateStatus() {
        let status = manager?.connection.status ?? .disconnected
        connected = status == .connected
        switch status {
        case .connected: statusText = "本地隧道已连接"
        case .connecting, .reasserting: statusText = "正在连接本地隧道…"
        case .disconnecting: statusText = "本地隧道正在断开"
        case .invalid: statusText = "本地隧道配置不可用"
        case .disconnected:
            // Keep the concrete failure visible after a failed connection attempt.
            if !statusText.hasPrefix("本地隧道连接失败") { statusText = "本地隧道未连接" }
        @unknown default: statusText = "本地隧道状态未知"
        }
    }

    private enum ConnectionError: LocalizedError {
        case missingExtension, missingPacketTunnelEntitlement, configurationPermissionDenied
        case invalidConfiguration, disconnected, timedOut

        var errorDescription: String? {
            switch self {
            case .missingExtension: return "安装包中的本地隧道扩展缺失或标识不匹配，请重新构建并安装。"
            case .missingPacketTunnelEntitlement:
                return "当前安装包缺少 Packet Tunnel 权限。请用支持 Network Extensions 的开发签名重新签装，主 App 和 VPN 扩展都要保留这项权限。"
            case .configurationPermissionDenied:
                return "iOS 拒绝访问 VPN 配置。如果出现添加 VPN 的提示，请点“允许”。自行签装时，请确认 VPN 扩展的签名也包含 Packet Tunnel 权限。"
            case .invalidConfiguration: return "系统报告 VPN 配置无效，请检查开发签名是否允许 Packet Tunnel。"
            case .disconnected: return "系统未建立本地隧道连接，请检查 VPN 权限和当前 VPN 状态后重试。"
            case .timedOut: return "等待本地隧道连接超过 30 秒，请检查 VPN 权限和当前 VPN 状态后重试。"
            }
        }
    }
}
