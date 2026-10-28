import SwiftUI

struct NSDuoOpenSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notices = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(notices)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("开源组件与许可")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                notices = ["StikJIT-ThirdPartyNotices", "LocalDevVPN-ThirdPartyNotices", "NSZ-ThirdPartyNotices"].map { name in
                    guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                          let text = try? String(contentsOf: url, encoding: .utf8) else {
                        return "\(name)：未找到随包许可文件，请参阅 NS Duo 工程中的 distribution/legal。"
                    }
                    return text
                }.joined(separator: "\n\n──────────\n\n")
            }
        }
    }
}
