import SwiftUI
import UniformTypeIdentifiers

struct NSDuoRootView: View {
    @EnvironmentObject private var core: RyujinxController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPreparation = false
    @State private var pendingURL: URL?
    @State private var failure: String?
    @State private var failureTitle = "无法启动"
    @State private var initialized = false
    @State private var preparedResources = false
    @State private var launchTransition: NSDuoGameLaunch?
    @State private var gameSwitch: NSDuoLibraryGame?
    @State private var queuedGame: NSDuoLibraryGame?
    @State private var queuedOwnerStopped = false
    @State private var deferredGame: GameInfo?

    var body: some View {
        ZStack {
            ZStack {
                destination
                if showsLibrary {
                    NSDuoLibraryView(onPlay: selectGame, onPrepare: { showPreparation = true },
                                     onImportFolder: importFolder, onImportFile: importFile, onLibraryAppear: checkFolders,
                                     hasPreparedResources: preparedResources)
                        .disabled(!initialized || core.isStopping || queuedGame != nil)
                }
            }
            .allowsHitTesting(launchTransition == nil)
            .accessibilityHidden(launchTransition != nil)
            if queuedGame != nil || (core.isGameSuspended && core.isStopping) {
                ProgressView(core.isStopping ? "正在关闭当前游戏…" : "正在准备下一款游戏…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            if let launch = launchTransition {
                NSDuoGameLaunchView(launch: launch, onFadeOut: {
                    guard launchTransition?.id == launch.id else { return }
                    launchTransition?.didFadeOut = true
                    NSDuoLibraryStore.shared.releaseCovers()
                }, onFinished: {
                    guard launchTransition?.id == launch.id else { return }
                    launchTransition = nil
                }, onCancel: cancelLaunchTransition)
                .id(launch.id)
            }
        }
        .sheet(isPresented: $showPreparation, onDismiss: {
            refreshReadiness(resumePending: true)
        }) {
            NSDuoPreparationView()
        }
        .onChange(of: showPreparation) { _, shown in
            NSDuoLibraryStore.shared.setCoverLoadingSuspended(shown)
            if shown { launchTransition = nil }
        }
        .onReceive(NSDuoLibraryStore.shared.$message) { message in
            if message != nil { launchTransition = nil; deferredGame = nil }
        }
        .onReceive(NSDuoCheatStore.shared.$message) { message in
            if let message {
                failureTitle = "金手指未应用"
                failure = message
                NSDuoCheatStore.shared.message = nil
            }
        }
        .onChange(of: core.isRunning.isRunning()) { _, running in
            if !running {
                switch core.isRunning {
                case .stopped:
                    launchTransition = nil
                    if queuedGame != nil { queuedOwnerStopped = true }
                case .crashed:
                    queuedGame = nil
                    queuedOwnerStopped = false
                    deferredGame = nil
                    gameSwitch = nil
                    launchTransition = nil
                case .started: break
                }
            }
        }
        .alert(failureTitle, isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("知道了", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .sheet(item: $gameSwitch) { game in
            NSDuoGameSwitchConfirmation(game: game) {
                guard core.isGameSuspended, !core.isStopping else { return }
                queuedOwnerStopped = false
                queuedGame = game
                gameSwitch = nil
                core.stopGame()
            }
        }
        .task(id: queuedOwnerStopped ? queuedGame?.id : nil) { await launchQueuedGameWhenReady() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if let game = deferredGame { startGame(game) }
        }
        .task {
            guard !initialized else { return }
            NativeSettingsManager.setShared()
            core.loadConfig()
            ControllerManager.shared.initAll()
            MetalViewRepresentable.createView()
            UIApplication.shared.isIdleTimerDisabled = false
            AlertHandlers.register()
            preparedResources = (try? await NSDuoLibraryWorker.run { NSDuoLaunchMetadata.resourcesReady() }) ?? false
            initialized = true
            checkFolders()
        }
        .onChange(of: core.isRunning.hasCrashed()) { crashed in
            guard crashed, case .crashed(let result) = core.isRunning else { return }
            queuedGame = nil
            queuedOwnerStopped = false
            deferredGame = nil
            gameSwitch = nil
            failureTitle = "游戏已退出"
            failure = "运行核心已退出（\(result)）。游戏文件仍保留。可以重试，或检查密钥、固件与该游戏的兼容性。"
            core.isRunning = .stopped
        }
        .onChange(of: scenePhase) { phase in
            NSDuoDiagnostics.recordEnvironment()
            if phase == .active {
                if let game = deferredGame { startGame(game) }
                if initialized, !showPreparation, launchTransition == nil, !NSDuoLibraryStore.shared.isBusy {
                    switch core.isRunning {
                    case .stopped, .crashed: refreshReadiness()
                    case .started: break
                    }
                }
                checkFolders()
            }
            guard core.isRunning.isRunning(), !core.wasManuallyPaused else { return }
            core.isPaused = phase != .active
        }
    }

    private var showsLibrary: Bool {
        switch core.isRunning {
        case .stopped, .crashed: true
        case .started: core.isGameSuspended || launchTransition?.didFadeOut == false
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch core.isRunning {
        case .started(let game, .none):
            NSDuoPlayView(onGameReady: { revealLaunchDestination(for: game.fileURL) })
                .opacity(core.isGameSuspended ? 0 : 1)
                .allowsHitTesting(!core.isGameSuspended)
                .accessibilityHidden(core.isGameSuspended)
                .id(game.fileURL)
        case .started(let game, .noJIT):
            NSDuoJITView(game: game)
                .onAppear { revealLaunchDestination(for: game.fileURL) }
        case .started(let game, let state):
            ContentUnavailableView {
                Label("安装权限尚未就绪", systemImage: "signature")
            } description: {
                Text(state == .extendedEntitlement ? "请使用开发签名，并启用 Extended Virtual Addressing。" : "请使用开发签名，并启用 Increased Memory Limit。")
            } actions: {
                Button("返回游戏库") { core.isRunning = .stopped }
            }
            .onAppear { revealLaunchDestination(for: game.fileURL) }
        case .stopped, .crashed:
            Color.clear
        }
    }

    private func checkFolders() {
        guard initialized, !showPreparation, launchTransition == nil, pendingURL == nil,
              queuedGame == nil, deferredGame == nil,
              core.verifyKeysFile(path: .keysFolderURL, keys: .prod) else { return }
        switch core.isRunning {
        case .stopped, .crashed: NSDuoLibraryStore.shared.checkFolders()
        case .started: break // JIT handoff may resume emulation at any moment.
        }
    }

    private func selectGame(_ game: NSDuoLibraryGame, sourceFrame: CGRect) {
        let library = NSDuoLibraryStore.shared
        guard !core.isStopping, queuedGame == nil else { return }
        if core.isGameSuspended {
            if core.isCurrentGame(game) { core.resumeSuspendedGame() }
            else { gameSwitch = game }
            return
        }
        guard !core.isRunning.isRunning() else { return }
        guard launchTransition == nil, library.canPrepareLaunch else { return }
        let launch = NSDuoGameLaunch(title: game.title, cover: library.covers[game.id], sourceFrame: sourceFrame)
        launchTransition = launch
        library.prepareForLaunch(game) { url in
            guard launchTransition?.id == launch.id else { return }
            // Start on the existing metadata lease while the cover animation
            // continues above the still-visible library.
            play(url, launchID: launch.id)
        }
    }

    private func startGame(_ game: GameInfo) {
        guard UIApplication.shared.applicationState == .active else { deferredGame = game; return }
        deferredGame = nil
        if NSDuoIntegratedJIT.shared.isReady { core.startGame(game) }
        else { core.isRunning = .started(game: game, state: .noJIT) }
    }

    private func launchQueuedGameWhenReady() async {
        guard queuedOwnerStopped, let next = queuedGame else { return }
        while !Task.isCancelled, queuedGame?.id == next.id {
            // Keep a confirmed switch pending while the app is in the background,
            // or while a library mutation finishes. Read UIKit's live state here;
            // a long-lived task must not retain an old scenePhase value.
            if case .stopped = core.isRunning,
               UIApplication.shared.applicationState == .active,
               initialized, !showPreparation, !core.isStopping,
               NSDuoLibraryStore.shared.canPrepareLaunch {
                queuedGame = nil
                queuedOwnerStopped = false
                selectGame(next, sourceFrame: .zero)
                return
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    private func revealLaunchDestination(for url: URL) {
        guard launchTransition?.destinationURL == url, launchTransition?.isStopping == false else { return }
        launchTransition?.destinationReady = true
    }

    private func cancelLaunchTransition() {
        deferredGame = nil
        NSDuoLibraryStore.shared.cancelImport()
        switch core.isRunning {
        case .started(_, .none):
            launchTransition?.isStopping = true
            // Keep the live Metal view until the emulation thread has stopped.
            core.stopGame()
        case .started:
            core.lastGameLaunched = nil
            core.isRunning = .stopped
            launchTransition = nil
        case .stopped, .crashed:
            launchTransition = nil
        }
    }

    private func importFolder(_ url: URL) {
        guard !core.isRunning.hasStarted() else { return }
        guard core.verifyKeysFile(path: .keysFolderURL, keys: .prod) else {
            NSDuoLibraryStore.shared.message = "识别游戏、升级包和 DLC 需要密钥。请先在“运行准备”中导入密钥，再添加文件夹。"
            return
        }
        NSDuoLibraryStore.shared.importFolder(from: url)
    }

    private func importFile(_ url: URL) {
        guard !core.isRunning.hasStarted() else { return }
        guard core.verifyKeysFile(path: .keysFolderURL, keys: .prod) else {
            NSDuoLibraryStore.shared.message = "识别游戏需要密钥。请先在“运行准备”中导入密钥。"
            return
        }
        NSDuoLibraryStore.shared.importGame(from: url)
    }

    private func refreshReadiness(resumePending: Bool = false) {
        guard !core.isRunning.hasStarted(), queuedGame == nil, deferredGame == nil else { return }
        NSDuoLibraryStore.shared.refreshResourceReadiness { ready in
            preparedResources = ready
            if resumePending {
                let url = pendingURL
                pendingURL = nil
                if let url, ready { play(url) }
            }
        }
    }
    private func play(_ url: URL, launchID: UUID? = nil) {
        // The library keeps its launch lease until the native read finishes.
        NSDuoLibraryStore.shared.prepareLaunchMetadata(at: url, retainingCovers: launchID != nil) { result in
            guard launchID == nil || launchTransition?.id == launchID else { return }
            switch result {
            case .success(let game):
                preparedResources = true
                if launchID != nil { launchTransition?.destinationURL = game.fileURL }
                startGame(game)
            case .failure(NSDuoLaunchMetadata.Failure.resourcesMissing):
                preparedResources = false
                pendingURL = url
                showPreparation = true
            case .failure(let error):
                launchTransition = nil
                deferredGame = nil
                failureTitle = "无法启动"
                failure = error.localizedDescription
            }
        }
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
                    Text("先在设置中开启开发者模式。NS Duo 需要开发签名和调试权限。")
                    Text("没有配对记录时，在“开启 JIT”的同一位置会显示“首次开启 JIT”。iOS / iPadOS 27 或更高版本按下方步骤完成本机配对；旧系统可导入电脑生成的远程配对文件。")
                    NSDuoFirstPairingInstructions()
                    Text("配对期间请勿从多任务中关闭 NS Duo；系统结束任务后可重新发起。首次连接 VPN 时允许添加本地 VPN 配置。不需要安装或打开 StikDebug、LocalDevVPN。")
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
