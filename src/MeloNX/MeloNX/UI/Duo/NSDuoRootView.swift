import SwiftUI
import UniformTypeIdentifiers

struct NSDuoRootView: View {
    @EnvironmentObject private var core: RyujinxController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPreparation = false
    @State private var pendingURL: URL?
    @State private var failure: String?
    @State private var initialized = false
    @State private var preparedResources = false

    var body: some View {
        Group {
            switch core.isRunning {
            case .started(let game, .none):
                NSDuoPlayView().id(game.fileURL)
            case .started(let game, .noJIT):
                NSDuoJITView(game: game)
            case .started(_, let state):
                ContentUnavailableView {
                    Label("安装权限尚未就绪", systemImage: "signature")
                } description: {
                    Text(state == .extendedEntitlement ? "请使用开发签名，并启用 Extended Virtual Addressing。" : "请使用开发签名，并启用 Increased Memory Limit。")
                } actions: {
                    Button("返回游戏库") { core.isRunning = .stopped }
                }
            case .stopped, .crashed:
                NSDuoLibraryView(onPlay: play, onPrepare: { showPreparation = true },
                                 onImportFolder: importFolder, onImportFile: importFile, onLibraryAppear: checkFolders,
                                 hasPreparedResources: preparedResources)
                    .disabled(!initialized)
            }
        }
        .sheet(isPresented: $showPreparation, onDismiss: {
            preparedResources = resourcesReady
            guard let url = pendingURL, preparedResources else { pendingURL = nil; return }
            pendingURL = nil
            play(url)
        }) {
            NSDuoPreparationView()
        }
        .alert("无法启动", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("知道了", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .task {
            guard !initialized else { return }
            NativeSettingsManager.setShared()
            core.loadConfig()
            ControllerManager.shared.initAll()
            MetalViewRepresentable.createView()
            UIApplication.shared.isIdleTimerDisabled = false
            AlertHandlers.register()
            initialized = true
            preparedResources = resourcesReady
            checkFolders()
        }
        .onChange(of: core.isRunning.hasCrashed()) { crashed in
            guard crashed, case .crashed(let result) = core.isRunning else { return }
            failure = "运行核心已退出（\(result)）。游戏文件仍保留。可以重试，或检查密钥、固件与该游戏的兼容性。"
            core.isRunning = .stopped
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if initialized, !showPreparation, !NSDuoLibraryStore.shared.isBusy {
                    switch core.isRunning {
                    case .stopped, .crashed: preparedResources = resourcesReady
                    case .started: break
                    }
                }
                checkFolders()
            }
            guard core.isRunning.isRunning(), !core.wasManuallyPaused else { return }
            core.isPaused = phase != .active
        }
    }

    private func checkFolders() {
        guard initialized, !showPreparation, pendingURL == nil, core.verifyKeysFile(path: .keysFolderURL, keys: .prod) else { return }
        switch core.isRunning {
        case .stopped, .crashed: NSDuoLibraryStore.shared.checkFolders()
        case .started: break // JIT handoff may resume emulation at any moment.
        }
    }

    private func importFolder(_ url: URL) {
        guard core.verifyKeysFile(path: .keysFolderURL, keys: .prod) else {
            NSDuoLibraryStore.shared.message = "识别游戏、升级包和 DLC 需要密钥。请先在“运行准备”中导入密钥，再添加文件夹。"
            return
        }
        NSDuoLibraryStore.shared.importFolder(from: url)
    }

    private func importFile(_ url: URL) {
        guard core.verifyKeysFile(path: .keysFolderURL, keys: .prod) else {
            NSDuoLibraryStore.shared.message = "识别游戏需要密钥。请先在“运行准备”中导入密钥。"
            return
        }
        NSDuoLibraryStore.shared.importGame(from: url)
    }

    private var resourcesReady: Bool {
        core.verifyKeysFile(path: .keysFolderURL, keys: .prod) && core.firmwareInstalled
    }
    private func play(_ url: URL) {
        guard let format = NSDuoGameFormat(url: url), FileManager.default.isReadableFile(atPath: url.path) else {
            failure = "游戏文件无法读取，请重新导入 XCI 或 NSP。"; return
        }
        preparedResources = resourcesReady
        guard preparedResources else { pendingURL = url; showPreparation = true; return }
        // Metadata parsing is deferred until keys are ready; the library works without keys.
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            Ryujinx.reloadKeySet()
            let game = Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: format.rawValue as NSString, path: url)
            guard !game.titleId.isEmpty, game.titleId != "0000000000000000" else {
                failure = "未能识别可启动的游戏本体。请检查文件完整性、密钥与固件；更新包和 DLC 不能单独启动。"; return
            }
            if NSDuoIntegratedJIT.shared.isReady { core.startGame(game) }
            else { core.isRunning = .started(game: game, state: .noJIT) }
        } catch { failure = error.localizedDescription }
    }
}

struct NSDuoJITView: View {
    let game: GameInfo
    @EnvironmentObject private var core: RyujinxController
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var jit = NSDuoIntegratedJIT.shared
    @State private var cancelled = false
    @State private var showGuide = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 56)).foregroundStyle(.teal)
                Text("准备启动游戏").font(.title2.bold())
                NSDuoJITSetupControls()
                Button("首次使用说明") { showGuide = true }
                Button("返回游戏库") {
                    cancelled = true
                    core.lastGameLaunched = nil
                    core.isRunning = .stopped
                }
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showGuide) { NSDuoPhoneGuide() }
        .task {
            while !Task.isCancelled {
                guard stillWaiting else { return }
                if scenePhase == .active && jit.isReady {
                    core.startGame(game)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
        }
    }

    private var stillWaiting: Bool {
        guard !cancelled, case .started(let waitingGame, .noJIT) = core.isRunning else { return false }
        return waitingGame.fileURL == game.fileURL
    }
}

struct NSDuoPhoneGuide: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showLicenses = false
    var body: some View {
        NavigationStack {
            List {
                Section("首次在手机上准备") {
                    Text("1. 在设置中开启开发者模式。NS Duo 需要开发签名和调试权限。")
                    Text("2. 在 NS Duo 中导入这台手机的远程配对记录。可以复用此前在 StikDebug 中成功使用的文件；配对记录与游戏密钥是两种不同文件。")
                    Text("3. 先点击“连接 VPN”，首次允许添加 NS Duo 本地 VPN 和访问本地网络。VPN 连接后，再点击下方“开启 JIT”。不需要打开 LocalDevVPN 或 StikDebug。")
                }
                Section("以后怎么玩") {
                    Text("点击游戏卡片。如果本次运行尚未准备好，先连接 VPN，再开启 JIT，完成后自动启动已选择的游戏；同一 App 进程内无需重复准备。")
                    Text("首次下载调试环境需要联网。系统更新、重置或配对失效后，可能需要重新配对或清理调试缓存；这些系统首次授权不能由 App 代替确认。")
                }
                Section("没有 Wi-Fi 时开启 JIT") {
                    Text("只有蜂窝网络时，可尝试以下操作，效果取决于设备和系统版本。")
                    Text("1. 在 NS Duo 点击“连接 VPN”，等待显示“VPN 已连接”。")
                    Text("2. 打开控制中心，开启飞行模式。")
                    Text("3. 回到 NS Duo，点击“开启 JIT”，等待显示“JIT 已开启”。")
                    Text("4. 关闭飞行模式，恢复蜂窝网络后继续游戏。")
                }
                Section("组件来源") {
                    Text("内置本地隧道基于 LocalDevVPN，作者包括 SideStore Team、Stossy11 和 Magesh K；调试使用 StikJIT 与 idevice，保留各自许可和署名。")
                        .font(.footnote)
                    Button("开源组件与许可") { showLicenses = true }
                    Link("StikPair · 手机配对", destination: URL(string: "https://github.com/StikDebug/StikPair")!)
                    Link("StikJIT · 内置调试框架", destination: URL(string: "https://github.com/StikDebug/StikJIT")!)
                    Link("LocalDevVPN · 本地隧道来源", destination: URL(string: "https://github.com/jkcoxson/LocalDevVPN")!)
                }
            }
            .sheet(isPresented: $showLicenses) { NSDuoOpenSourceView() }
            .navigationTitle("手机端运行")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
