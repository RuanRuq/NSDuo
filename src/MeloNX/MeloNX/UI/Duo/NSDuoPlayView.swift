import SwiftUI
import MetalKit

struct NSDuoPlayView: View {
    var onGameReady: () -> Void = {}

    @EnvironmentObject private var core: RyujinxController
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var statistics = StatisticsHandler()
    @State private var confirmExit = false

    private var stopping: Bool { core.isStopping }

    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            let gameHeight = portrait ? geometry.size.height * 0.5 : geometry.size.height
            let gamepadHeight = portrait ? geometry.size.height * 0.35 : 0
            let gameAreaHeight = max(0, geometry.size.height - gamepadHeight)
            let viewport = CGSize(width: geometry.size.width, height: gameHeight)
            let renderSize = targetSize(in: viewport, aspectRatio: core.currentSettings.aspectRatio)
            let controlsTop = geometry.safeAreaInsets.top + 8
            let controlsLeading = geometry.safeAreaInsets.leading + 12
            let controlsCorner = CGSize(width: controlsLeading + NSDuoPlayControls.size.width,
                                        height: controlsTop + NSDuoPlayControls.size.height)
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    // Keep this representable in the same position when the window rotates.
                    MetalViewRepresentable()
                        .frame(width: renderSize.width, height: renderSize.height)
                        .allowsHitTesting(!core.isPaused && !stopping && !confirmExit)
                    if !statistics.started {
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("正在启动游戏…").foregroundStyle(.white)
                        }
                        .padding(24)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                    }
                }
                // Center the unchanged game viewport in all space above the gamepad.
                .frame(width: viewport.width, height: gameAreaHeight)
                .clipped()
                .background {
                    NSDuoPlayTapObserver(enabled: !portrait && !core.isGameSuspended && !stopping && !confirmExit,
                                         cornerSize: controlsCorner)
                }
                .overlay(alignment: .topLeading) {
                    NSDuoPlayControls(alwaysVisible: portrait || confirmExit,
                                      isPaused: core.isPaused, stopping: stopping,
                                      pause: {
                        releaseInput()
                        core.isPaused.toggle()
                        core.wasManuallyPaused = core.isPaused
                    }, library: {
                        releaseInput()
                        InGameConfigView_MenuView.shared.hide()
                        core.suspendGameToLibrary()
                    }, exit: {
                        releaseInput()
                        InGameConfigView_MenuView.shared.cancelAutoHide()
                        confirmExit = true
                    })
                    .padding(.top, controlsTop)
                    .padding(.leading, controlsLeading)
                }
                if portrait {
                    NSDuoGamepad()
                        .padding(.horizontal, 8)
                        .disabled(core.isPaused || stopping || confirmExit)
                        .padding(.bottom, geometry.safeAreaInsets.bottom)
                        .frame(width: geometry.size.width, height: gamepadHeight)
                        .background(Color(red: 0.075, green: 0.085, blue: 0.11))
                }
            }
            .onChange(of: portrait, initial: true) { _, portrait in
                InGameConfigView_MenuView.shared.setCornerRevealOnly(!portrait)
            }
            .onChange(of: geometry.size) { _ in releaseInput(); InGameConfigView_MenuView.shared.hide() }
        }
        .ignoresSafeArea()
        .statusBarHidden(!core.isGameSuspended)
        .alert("关闭游戏？", isPresented: $confirmExit) {
            Button("关闭游戏", role: .destructive) {
                releaseInput()
                // Let the emulation thread report stopped; do not replace its live Metal layer.
                core.stopGame()
            }
            Button("取消", role: .cancel) { InGameConfigView_MenuView.shared.triggerButton() }
        } message: {
            Text("未保存的游戏进度会丢失，请先在游戏内保存。")
        }
        .overlay {
            if stopping {
                ProgressView("正在结束游戏…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            InGameConfigView_MenuView.shared.hide()
            statistics.registerPush(includeMetrics: false)
            UIApplication.shared.isIdleTimerDisabled = !core.isGameSuspended
        }
        .onChange(of: core.isGameSuspended) { _, suspended in
            releaseInput()
            InGameConfigView_MenuView.shared.hide()
            UIApplication.shared.isIdleTimerDisabled = !suspended
        }
        .task {
            while !Task.isCancelled {
                if !core.isGameSuspended { NSDuoDiagnostics.recordEnvironment() }
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            NSDuoDiagnostics.recordEnvironment(memoryWarning: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            NSDuoDiagnostics.recordEnvironment()
        }
        .onChange(of: statistics.started) { _, started in
            if started { onGameReady() }
        }
        .onChange(of: scenePhase) { phase in if phase != .active { releaseInput() } }
        .onDisappear {
            InGameConfigView_MenuView.shared.setCornerRevealOnly(false)
            InGameConfigView_MenuView.shared.hide()
            statistics.unregisterPush()
            releaseInput()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func releaseInput() { NotificationCenter.default.post(name: .nsDuoReleaseInput, object: nil) }
}

// Menu visibility only invalidates these small controls, not the Metal viewport
// and the virtual gamepad underneath it.
private struct NSDuoPlayControls: View {
    static let buttonSize: CGFloat = 44
    static let spacing: CGFloat = 2
    static let size = CGSize(width: buttonSize * 3 + spacing * 2, height: buttonSize)

    @ObservedObject private var menu = InGameConfigView_MenuView.shared
    let alwaysVisible: Bool
    let isPaused: Bool
    let stopping: Bool
    let pause: () -> Void
    let library: () -> Void
    let exit: () -> Void

    var body: some View {
        if alwaysVisible || menu.showButton { controls }
    }

    private var controls: some View {
        HStack(spacing: Self.spacing) {
            Button(action: pause) {
                Label(isPaused ? "继续游戏" : "暂停游戏", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
            }
            Button(action: library) {
                Label("返回游戏库", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
            }
            Button(action: exit) {
                Label("关闭游戏", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .disabled(stopping)
    }

}

// Observe the whole game area, including letterboxing and the paused viewport,
// without placing a hit-testing overlay above Metal or cancelling game touches.
private struct NSDuoPlayTapObserver: UIViewRepresentable {
    let enabled: Bool
    let cornerSize: CGSize

    func makeUIView(context: Context) -> NSDuoPlayTapObservationView {
        let view = NSDuoPlayTapObservationView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: NSDuoPlayTapObservationView, context: Context) {
        uiView.cornerSize = cornerSize
        uiView.tapEnabled = enabled
    }

    static func dismantleUIView(_ uiView: NSDuoPlayTapObservationView, coordinator: ()) {
        uiView.tapEnabled = false
        uiView.detach()
    }
}

private final class NSDuoPlayTapObservationView: UIView, UIGestureRecognizerDelegate {
    var cornerSize = CGSize.zero
    var tapEnabled = false {
        didSet {
            if tapEnabled != oldValue { tapRecognizer.isEnabled = tapEnabled }
        }
    }
    private weak var observedWindow: UIWindow?
    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        recognizer.isEnabled = tapEnabled
        return recognizer
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard observedWindow !== window else { return }
        detach()
        if let window {
            window.addGestureRecognizer(tapRecognizer)
            observedWindow = window
        }
    }

    func detach() {
        observedWindow?.removeGestureRecognizer(tapRecognizer)
        observedWindow = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard tapEnabled, bounds.contains(touch.location(in: self)) else { return false }
        // Visible buttons own their taps. Do not reveal/hide the menu as a side
        // effect of pressing pause, return or close.
        return !InGameConfigView_MenuView.shared.showButton || !cornerRect.contains(touch.location(in: self))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private var cornerRect: CGRect { CGRect(origin: .zero, size: cornerSize) }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard tapEnabled, bounds.contains(point) else { return }
        InGameConfigView_MenuView.shared.handleCornerTap(insideCorner: cornerRect.contains(point))
    }
}
