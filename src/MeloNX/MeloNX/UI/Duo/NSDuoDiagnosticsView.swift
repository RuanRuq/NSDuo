import SwiftUI
import UIKit

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
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var shareItem: NSDuoDiagnosticShareItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("自动记录游戏运行、核心异常和 App 异常，日志保存在手机本地，可导出分析。")
                    Text("系统崩溃报告可能在重新打开 App 后延迟出现；系统强制结束不一定有异常堆栈。")
                    Text("保留最近 5 次普通记录和 10 次问题记录。每份最多约 5 MB，旧记录会轮换；需要长期保存时请导出到“文件”。")
                }.font(.footnote).foregroundStyle(.secondary)
                if let exported {
                    Section("导出已准备好") {
                        ShareLink(item: exported) { Label("分享或存储诊断日志", systemImage: "square.and.arrow.up") }
                    }
                }
                Section("运行记录") {
                    if loading { ProgressView("正在读取…") }
                    else if records.isEmpty {
                        Text(cleared ? "日志已清除，后续会继续自动记录。" : "运行游戏或收集到异常报告后，这里会出现记录。")
                            .foregroundStyle(.secondary)
                    }
                    if !records.isEmpty {
                        HStack {
                            Button(selecting ? "取消选择" : "选择") {
                                selecting.toggle()
                                selectedIDs.removeAll()
                            }
                            Spacer()
                            if selecting {
                                Button(selectedIDs.count == records.count ? "取消全选" : "全选") {
                                    if selectedIDs.count == records.count { selectedIDs.removeAll() }
                                    else { selectedIDs = Set(records.map(\.id)) }
                                }
                            }
                        }.buttonStyle(.borderless).disabled(exporting != nil || clearing)
                    }
                    ForEach(records) { record in
                        Button {
                            if selecting {
                                if selectedIDs.contains(record.id) { selectedIDs.remove(record.id) }
                                else { selectedIDs.insert(record.id) }
                            } else { export(record) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text(record.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                    Text(record.unfinished ? "未正常结束，原因待分析" : record.hasProblem ? "已标记问题" : "正常结束")
                                        .font(.caption).foregroundStyle(record.hasProblem || record.unfinished ? .orange : .secondary)
                                }
                                Spacer()
                                if selecting {
                                    Image(systemName: selectedIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                } else if exporting == record.id { ProgressView() }
                                else { Image(systemName: "square.and.arrow.up") }
                            }.padding(.vertical, 4)
                        }.disabled(exporting != nil || clearing)
                    }
                    if selecting {
                        Button { exportSelected() } label: {
                            HStack {
                                Label("分享已选日志（\(selectedIDs.count)）", systemImage: "square.and.arrow.up")
                                Spacer()
                                if exporting == "selected" { ProgressView() }
                            }
                        }.disabled(selectedIDs.isEmpty || exporting != nil || clearing)
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
            .sheet(item: $shareItem) { item in
                NSDuoDiagnosticShareSheet(url: item.url)
            }
            .confirmationDialog("清除本机的全部诊断日志？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除日志", role: .destructive) { clearLogs() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("清除后无法恢复。后续游玩会继续自动记录，不影响游戏和存档。")
            }
            .task {
                await NSDuoExceptionCollector.shared.flushPendingReports()
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
                selectedIDs.removeAll()
                selecting = false
                cleared = true
            } catch {
                // A partial failure should show any records that remain on disk.
                if let remaining = try? await Task.detached(priority: .utility, operation: { try NSDuoDiagnosticFiles.records() }).value {
                    records = remaining
                    selectedIDs.formIntersection(Set(remaining.map(\.id)))
                }
                failure = "未能清除全部日志：\(error.localizedDescription)"
            }
        }
    }

    private func exportSelected() {
        guard !clearing, exporting == nil else { return }
        let selected = records.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        exported = nil
        exporting = "selected"
        Task {
            defer { exporting = nil }
            do {
                let url = try await Task.detached(priority: .utility) { try NSDuoDiagnosticFiles.export(selected) }.value
                shareItem = NSDuoDiagnosticShareItem(url: url)
            } catch { failure = "无法导出日志：\(error.localizedDescription)" }
        }
    }
}

private struct NSDuoDiagnosticShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct NSDuoDiagnosticShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
