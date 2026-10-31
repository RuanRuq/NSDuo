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
                .overlay(alignment: .topLeading) {
                    NSDuoPlayControls(alwaysVisible: portrait || core.isPaused || confirmExit,
                                      isPaused: core.isPaused, stopping: stopping,
                                      pause: {
                        releaseInput()
                        core.isPaused.toggle()
                        core.wasManuallyPaused = core.isPaused
                    }, exit: {
                        releaseInput()
                        InGameConfigView_MenuView.shared.cancelAutoHide()
                        confirmExit = true
                    })
                    .padding(.top, geometry.safeAreaInsets.top + 8)
                    .padding(.leading, geometry.safeAreaInsets.leading + 12)
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
            .onChange(of: geometry.size) { _ in releaseInput(); InGameConfigView_MenuView.shared.hide() }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .alert("返回游戏库？", isPresented: $confirmExit) {
            Button("返回游戏库", role: .destructive) {
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
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .task {
            while !Task.isCancelled {
                NSDuoDiagnostics.recordEnvironment()
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
    @ObservedObject private var menu = InGameConfigView_MenuView.shared
    let alwaysVisible: Bool
    let isPaused: Bool
    let stopping: Bool
    let pause: () -> Void
    let exit: () -> Void

    var body: some View {
        if alwaysVisible || menu.showButton { controls }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button(action: pause) {
                Label(isPaused ? "继续游戏" : "暂停游戏", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Button(action: exit) {
                Label("返回游戏库", systemImage: "square.grid.2x2.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
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
