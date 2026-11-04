import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Shared by first-run/game launch and the optional preparation page.
struct NSDuoJITSetupControls: View {
    @ObservedObject private var jit = NSDuoIntegratedJIT.shared
    @ObservedObject private var vpn = NSDuoVPNManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var importError: String?
    @State private var confirmReset = false
    @State private var showPairingPIN = false
    @State private var lastPresentedPIN: String?

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
            jitButton
            if let code = jit.pairingPIN {
                Text("本机配对码").font(.headline)
                Text(code).font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("配对验证码：\(code.map(String.init).joined(separator: " "))")
            }
            if !jit.hasPairing {
                if #available(iOS 27, *) {
                    NSDuoFirstPairingInstructions()
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("本机首次配对需要 iOS / iPadOS 27 或更高版本。当前系统请先导入通过电脑为本机生成的远程配对文件，之后使用同一按钮开启 JIT。无需安装 StikDebug。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if jit.phase == .pairing {
                if jit.pairingPIN == nil {
                    Text("等待设备验证和配对码…").font(.headline)
                }
                Text("在系统设置中选中 NS Duo 后，第一次输入的是这台设备的解锁密码。验证通过后再返回此页查看配对码，然后切回设置输入配对码。配对码也会显示在系统配对进度提示中；允许通知后可查看通知。配对期间请勿从多任务中关闭 NS Duo。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("取消本次配对") { jit.cancelPairing() }
            }
            if jit.isBusy { ProgressView().frame(maxWidth: .infinity) }
            Text(jit.status)
                .font(.subheadline)
                .foregroundStyle(jit.phase == .failed ? .red : .secondary)
            Button {
                importing = true
            } label: {
                Label(jit.hasPairing ? "配对记录已保存 · 导入其他记录" : "已有配对文件？直接导入", systemImage: "iphone.and.arrow.forward")
                    .frame(minHeight: 44)
            }
            .disabled(jit.isBusy)
            Text("VPN 连接和 JIT 开启是两个独立步骤。蜂窝网络下可先连接 VPN，完成需要的网络切换后再开启 JIT；首次请允许添加 VPN 和访问本地网络。")
                .font(.footnote).foregroundStyle(.secondary)
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
            DisclosureGroup("修复工具") {
                if jit.hasPairing {
                    Button("重新配对") { jit.beginPairing() }
                        .disabled(jit.isBusy || jit.isReady || vpn.isConnecting)
                    if jit.isReady {
                        Text("本次 JIT 已开启。如需重新配对，请完全退出 NS Duo 后再打开。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("清理调试环境缓存", role: .destructive) { confirmReset = true }
                    .disabled(jit.isBusy)
                Text("只有系统升级或调试环境报错时才需要清理，不会删除游戏、存档或配对记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // One stable presenter; modifiers on Group would reach multiple form rows.
    private var jitButton: some View {
        Button {
            jit.startJITSetup()
        } label: {
            stepLabel(jitActionTitle, icon: "bolt.fill", complete: jit.isReady)
        }
        .buttonStyle(.borderedProminent)
        .disabled(jit.isBusy || vpn.isConnecting || jit.isReady || (jit.hasPairing && !vpn.connected))
        .onAppear {
            jit.refreshPairingStatus()
            presentPairingPINIfNeeded()
        }
        .onChange(of: jit.pairingPIN) {
            if jit.pairingPIN == nil {
                showPairingPIN = false
                lastPresentedPIN = nil
            } else { presentPairingPINIfNeeded() }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                showPairingPIN = false
                lastPresentedPIN = nil
            } else { presentPairingPINIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // UIKit activation can follow SwiftUI's scene transition. Present on
            // the next turn so an alert requested during that transition is retried.
            showPairingPIN = false
            lastPresentedPIN = nil
            DispatchQueue.main.async { presentPairingPINIfNeeded() }
        }
        .alert("本机配对码", isPresented: $showPairingPIN) {
            Button("复制配对码") {
                guard let code = jit.pairingPIN else { return }
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: code]],
                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
            }
            Button("关闭", role: .cancel) {}
        } message: {
            Text("\(jit.pairingPIN ?? "")\n设备解锁验证已通过。现在请回到系统设置的 NS Duo 配对页面，输入这个六位配对码。")
        }
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

    private func presentPairingPINIfNeeded() {
        guard scenePhase == .active, let code = jit.pairingPIN, code != lastPresentedPIN else { return }
        lastPresentedPIN = code
        showPairingPIN = true
    }

    private var jitActionTitle: String {
        if jit.isReady { return "JIT 已开启" }
        switch jit.phase {
        case .pairing: return "正在配对…"
        case .importing where !jit.hasPairing: return "正在保存配对…"
        case .preparing: return "正在开启 JIT…"
        default: return jit.hasPairing ? "开启 JIT" : "首次开启 JIT"
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

/// The preparation page and the first-use guide share the same pairing steps.
struct NSDuoFirstPairingInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("首次配对流程").font(.headline).foregroundStyle(.primary)
            Text("1. 点击“首次开启 JIT”，允许访问本地网络，等待提示“配对服务已就绪”。首次配对无需先连接 VPN。")
            Text("2. 打开系统设置 → 隐私与安全性 → 开发者模式，选择“与 NS Duo 配对”（Pair with NS Duo）。")
            Text("3. 系统第一次要求输入密码时，输入**这台 iPhone / iPad 的设备解锁密码**，完成设备身份验证。")
            Text("4. 设备验证通过后，**返回 NS Duo App**，查看弹窗或页面中的六位“本机配对码”。")
            Text("5. **再回到系统设置**的 NS Duo 配对页面，输入刚才在 App 中看到的**六位配对码**，等待系统完成配对。")
            Text("6. 回到 NS Duo，确认配对记录已保存。原位按钮会变为“开启 JIT”；连接 VPN 后再点击即可。")
            Text("第一次输入设备解锁密码，第二次输入 NS Duo 生成的配对码。")
                .fontWeight(.semibold).foregroundStyle(.primary)
        }
    }
}
