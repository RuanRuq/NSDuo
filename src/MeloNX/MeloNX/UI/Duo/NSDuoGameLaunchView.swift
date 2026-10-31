import SwiftUI
import UIKit

// Keep the transition at the root so replacing the library with the Metal view
// cannot interrupt the fade or recreate the running game's layer.
struct NSDuoGameLaunch: Identifiable {
    let id = UUID()
    let title: String
    let cover: UIImage?
    let sourceFrame: CGRect
    var didFadeOut = false
    var destinationURL: URL?
    var destinationReady = false
    var isStopping = false
}

nonisolated struct NSDuoGameCoverFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct NSDuoGameLaunchView: View {
    let launch: NSDuoGameLaunch
    let onFadeOut: () -> Void
    let onFinished: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fadedOut = false
    @State private var coverScale: CGFloat = 1
    @State private var coverOpacity = 0.5
    @State private var opacity = 1.0

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let origin = geometry.frame(in: .global).origin
            let source = launch.sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let initial = source.width > 0 && source.height > 0 ? source :
                CGRect(x: bounds.midX - 80, y: bounds.midY - 80, width: 160, height: 160)

            ZStack {
                Color.black.opacity(fadedOut ? 1 : 0)
                coverCopy
                    .frame(width: initial.width, height: initial.height)
                    .scaleEffect(coverScale)
                    .opacity(fadedOut ? 0 : coverOpacity)
                    .position(x: initial.midX, y: initial.midY)
                    .accessibilityHidden(true)

                loadingStatus(bottomInset: geometry.safeAreaInsets.bottom)
                    .opacity(launch.didFadeOut && !launch.destinationReady ? 1 : 0)
            }
            .frame(width: bounds.width, height: bounds.height)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
        .statusBarHidden(fadedOut)
        .opacity(opacity)
        .accessibilityAddTraits(.isModal)
        .task { await animateCoverAndFadeOut() }
        .task(id: launch.didFadeOut && launch.destinationReady) {
            guard launch.didFadeOut, launch.destinationReady else { return }
            withAnimation(.easeOut(duration: 0.28)) { opacity = 0 }
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    private var coverCopy: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.accentColor.opacity(0.09))
            .overlay {
                if let image = launch.cover {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func loadingStatus(bottomInset: CGFloat) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text(launch.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
            ProgressView(launch.isStopping ? "正在结束游戏…" : "正在启动游戏…")
                .tint(.white)
            Button("取消", action: onCancel)
                .buttonStyle(.bordered)
                .disabled(launch.isStopping || launch.destinationReady)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.bottom, max(bottomInset, 24) + 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.85)],
                           startPoint: .center, endPoint: .bottom)
        }
    }

    private func animateCoverAndFadeOut() async {
        do {
            if !reduceMotion {
                // Give SwiftUI one frame at the tapped cover's original position.
                try await Task.sleep(for: .milliseconds(16))
                withAnimation(.easeOut(duration: 0.25)) { coverScale = 1.6 }
                withAnimation(.linear(duration: 0.25)) { coverOpacity = 0 }
                try await Task.sleep(for: .milliseconds(250))
            }
            // Begin the library fade after the 250 ms cover echo has disappeared.
            withAnimation(.easeInOut(duration: 0.22)) { fadedOut = true }
            try await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            onFadeOut()
        } catch { /* Removing the presentation cancels its animation tasks. */ }
    }
}
