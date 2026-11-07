import SwiftUI

struct NSDuoGameSwitchConfirmation: View {
    let game: NSDuoLibraryGame
    let onConfirm: () -> Void
    @EnvironmentObject private var core: RyujinxController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmedSwitch = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: confirmedSwitch ? "exclamationmark.triangle" : "pause.circle")
                        .font(.system(size: 40)).foregroundStyle(.orange)
                    Text(confirmedSwitch ? "确认关闭当前游戏？" : "切换游戏？")
                        .font(.title2.bold())
                    Text(confirmedSwitch
                         ? "当前游戏尚未保存的进度会丢失。请确认已在游戏内保存，再关闭并进入“\(game.title)”。"
                         : "“\(core.runningGame?.titleName ?? "当前游戏")”正在挂起。进入“\(game.title)”前需要先关闭它。")
                        .foregroundStyle(.secondary)
                    if confirmedSwitch {
                        Button("关闭并进入其他游戏", role: .destructive) {
                            onConfirm()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                        Button("返回当前游戏保存") {
                            dismiss()
                            core.resumeSuspendedGame()
                        }
                    } else {
                        Button("继续切换") { confirmedSwitch = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("取消切换", role: .cancel) { dismiss() }
                }
                .multilineTextAlignment(.center).padding(24)
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
            .navigationTitle(confirmedSwitch ? "再次确认" : "切换游戏")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(core.isStopping || !core.isGameSuspended)
        }
        .presentationDetents([.medium, .large])
        .onChange(of: core.isGameSuspended) { _, suspended in if !suspended { dismiss() } }
    }
}
