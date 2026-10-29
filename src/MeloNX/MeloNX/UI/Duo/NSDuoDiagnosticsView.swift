import SwiftUI

struct NSDuoDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [NSDuoDiagnosticRecord] = []
    @State private var loading = true
    @State private var exporting: String?
    @State private var exported: URL?
    @State private var failure: String?
    @State private var confirmClear = false
    @State private var clearing = false
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("日常游玩时自动记录运行情况，无需额外操作。日志保存在手机本地，之后可导出分析。")
                    Text("保留最近 5 次普通记录和 10 次问题记录。每次最多约 4 MB，旧记录会轮换；需要长期保存时请导出到“文件”。")
                }.font(.footnote).foregroundStyle(.secondary)
                if let exported {
                    Section("导出已准备好") {
                        ShareLink(item: exported) { Label("分享或存储诊断日志", systemImage: "square.and.arrow.up") }
                    }
                }
                Section("运行记录") {
                    if loading { ProgressView("正在读取…") }
                    else if records.isEmpty {
                        Text(cleared ? "日志已清除，后续游玩会继续自动记录。" : "运行一次游戏后，这里会出现记录。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
                        Button { export(record) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text(record.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                    Text(record.unfinished ? "未正常结束，原因待分析" : record.hasProblem ? "已标记问题" : "正常结束")
                                        .font(.caption).foregroundStyle(record.hasProblem || record.unfinished ? .orange : .secondary)
                                }
                                Spacer()
                                if exporting == record.id { ProgressView() }
                                else { Image(systemName: "square.and.arrow.up") }
                            }.padding(.vertical, 4)
                        }.disabled(exporting != nil || clearing)
                    }
                }
                Section {
                    Button(role: .destructive) { confirmClear = true } label: {
                        HStack {
                            Label(clearing ? "正在清除…" : "清除日志", systemImage: "trash")
                            Spacer()
                            if clearing { ProgressView() }
                        }
                    }.disabled(loading || exporting != nil || clearing)
                } footer: {
                    Text("只清除本机诊断记录和临时导出文件，不影响游戏、存档及已保存到“文件”的日志副本。")
                }
            }
            .navigationTitle("诊断日志")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(clearing || exporting != nil)
                }
            }
            .interactiveDismissDisabled(clearing || exporting != nil)
            .confirmationDialog("清除本机的全部诊断日志？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除日志", role: .destructive) { clearLogs() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("清除后无法恢复。后续游玩会继续自动记录，不影响游戏和存档。")
            }
            .task {
                do { records = try await Task.detached(priority: .utility) { try NSDuoDiagnosticFiles.records() }.value }
                catch { failure = "无法读取日志：\(error.localizedDescription)" }
                loading = false
            }
            .alert("诊断日志", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }

    private func export(_ record: NSDuoDiagnosticRecord) {
        guard !clearing, exporting == nil else { return }
        exporting = record.id
        Task {
            defer { exporting = nil }
            do { exported = try await Task.detached(priority: .utility) { try NSDuoDiagnosticFiles.export(record) }.value }
            catch { failure = "无法导出日志：\(error.localizedDescription)" }
        }
    }

    private func clearLogs() {
        guard !loading, !clearing, exporting == nil else { return }
        clearing = true
        exported = nil
        Task {
            defer { clearing = false }
            do {
                try await Task.detached(priority: .utility) { try NSDuoDiagnosticFiles.clear() }.value
                records = []
                cleared = true
            } catch {
                // A partial failure should show any records that remain on disk.
                if let remaining = try? await Task.detached(priority: .utility, operation: { try NSDuoDiagnosticFiles.records() }).value {
                    records = remaining
                }
                failure = "未能清除全部日志：\(error.localizedDescription)"
            }
        }
    }
}
