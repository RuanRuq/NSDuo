import SwiftUI
import UniformTypeIdentifiers

/// Shared by first-run/game launch and the optional preparation page.
struct NSDuoJITSetupControls: View {
    @ObservedObject private var jit = NSDuoIntegratedJIT.shared
    @ObservedObject private var vpn = NSDuoVPNManager.shared
    @State private var importing = false
    @State private var importError: String?
    @State private var confirmReset = false

    var body: some View {
        Group {
            Button {
                jit.connectVPN()
            } label: {
                stepLabel(vpn.connected ? "VPN 已连接" : (vpn.isConnecting ? "正在连接 VPN…" : "连接 VPN"),
                          icon: "network", complete: vpn.connected)
            }
            .buttonStyle(.borderedProminent)
            .disabled(jit.isBusy || vpn.isConnecting || vpn.connected)
            Text(vpn.statusText)
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                jit.enableJIT()
            } label: {
                stepLabel(jit.isReady ? "JIT 已开启" : (jit.phase == .preparing ? "正在开启 JIT…" : "开启 JIT"),
                          icon: "bolt.fill", complete: jit.isReady)
            }
            .buttonStyle(.borderedProminent)
            .disabled(jit.isBusy || vpn.isConnecting || !vpn.connected || jit.isReady)
            if jit.isBusy { ProgressView().frame(maxWidth: .infinity) }
            Text(jit.status)
                .font(.subheadline)
                .foregroundStyle(jit.phase == .failed ? .red : .secondary)
            Button {
                importing = true
            } label: {
                Label(jit.hasPairing ? "配对记录已保存 · 重新导入" : "首次导入本机配对记录", systemImage: "iphone.and.arrow.forward")
                    .frame(minHeight: 44)
            }
            .disabled(jit.isBusy)
            Text("VPN 连接和 JIT 开启是两个独立步骤。蜂窝网络下可先连接 VPN，完成需要的网络切换后再开启 JIT；首次请允许添加 VPN 和访问本地网络。")
                .font(.footnote).foregroundStyle(.secondary)
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
            DisclosureGroup("修复工具") {
                Button("清理调试环境缓存", role: .destructive) { confirmReset = true }
                    .disabled(jit.isBusy)
                Text("只有系统升级或调试环境报错时才需要清理，不会删除游戏、存档或配对记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { jit.refreshPairingStatus() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [
            .propertyList,
            UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
            UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!
        ]) { result in
            switch result {
            case .success(let url):
                importError = nil
                Task {
                    await jit.importPairing(from: url)
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { importError = error.localizedDescription }
            }
        }
        .confirmationDialog("清理调试环境缓存？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("清理缓存", role: .destructive) { jit.resetDeveloperImage() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次准备时会根据当前系统重新下载需要的文件。")
        }
    }

    private func stepLabel(_ title: String, icon: String, complete: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 20).accessibilityHidden(true)
            Text(title).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green).opacity(complete ? 1 : 0)
                .frame(width: 20).accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
    }
}
