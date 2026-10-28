import SwiftUI
import MetalKit

struct NSDuoPlayView: View {
    @EnvironmentObject private var core: RyujinxController
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var statistics = StatisticsHandler()
    @ObservedObject private var menu = InGameConfigView_MenuView.shared
    @State private var confirmExit = false

    private var stopping: Bool { core.isStopping }

    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            let gameHeight = portrait ? geometry.size.height * 0.6 : geometry.size.height
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
                .frame(width: viewport.width, height: viewport.height)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if portrait || menu.showButton || core.isPaused || confirmExit {
                        playControls
                            .padding(.top, geometry.safeAreaInsets.top + 8)
                            .padding(.trailing, geometry.safeAreaInsets.trailing + 12)
                    }
                }
                if portrait {
                    NSDuoGamepad()
                        .padding(.horizontal, 8)
                        .disabled(core.isPaused || stopping || confirmExit)
                        .padding(.bottom, geometry.safeAreaInsets.bottom)
                        .frame(width: geometry.size.width, height: geometry.size.height - gameHeight)
                        .background(Color(red: 0.075, green: 0.085, blue: 0.11))
                }
            }
            .onChange(of: geometry.size) { _ in releaseInput(); menu.showButton = false }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .alert("返回游戏库？", isPresented: $confirmExit) {
            Button("返回游戏库", role: .destructive) {
                releaseInput()
                // Let the emulation thread report stopped; do not replace its live Metal layer.
                core.stopGame()
            }
            Button("取消", role: .cancel) {}
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
            statistics.registerPush()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: scenePhase) { phase in if phase != .active { releaseInput() } }
        .onDisappear {
            releaseInput()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var playControls: some View {
        HStack(spacing: 2) {
            Button {
                releaseInput()
                core.isPaused.toggle()
                core.wasManuallyPaused = core.isPaused
            } label: {
                Label(core.isPaused ? "继续游戏" : "暂停游戏", systemImage: core.isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Button {
                releaseInput()
                menu.hideTask?.cancel()
                confirmExit = true
            } label: {
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

    private func releaseInput() { NotificationCenter.default.post(name: .nsDuoReleaseInput, object: nil) }
}
