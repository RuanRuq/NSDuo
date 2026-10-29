//
//  NSDuoLibraryView.swift
//  MeloNX
//

import SwiftUI
import UniformTypeIdentifiers

struct NSDuoLibraryView: View {
    let onPlay: (URL) -> Void
    let onPrepare: () -> Void
    let onImportFolder: (URL) -> Void
    let onImportFile: (URL) -> Void
    let onLibraryAppear: () -> Void
    let hasPreparedResources: Bool

    @StateObject private var library = NSDuoLibraryStore.shared
    @ObservedObject private var jit = NSDuoIntegratedJIT.shared
    @State private var showingImporter = false
    @State private var importingFolder = true
    @State private var pendingRemoval: NSDuoLibraryGame?
    @State private var pendingRename: NSDuoLibraryGame?
    @State private var renamedTitle = ""
    @State private var showingDiagnostics = false

    init(onPlay: @escaping (URL) -> Void, onPrepare: @escaping () -> Void,
         onImportFolder: @escaping (URL) -> Void, onImportFile: @escaping (URL) -> Void,
         onLibraryAppear: @escaping () -> Void, hasPreparedResources: Bool) {
        self.onPlay = onPlay
        self.onPrepare = onPrepare
        self.onImportFolder = onImportFolder
        self.onImportFile = onImportFile
        self.onLibraryAppear = onLibraryAppear
        self.hasPreparedResources = hasPreparedResources
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Button {
                        importingFolder = true
                        library.isChoosingFiles = true
                        showingImporter = true
                    } label: {
                        Label("添加游戏文件夹", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!library.isReady || library.isBusy)

                    Text("选择一个游戏的目录，本体、升级包和 DLC 可以放在任意子文件夹里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let progress = library.importProgress {
                        importProgressView(progress)
                    }
                    if library.isLoadingCovers && library.importProgress == nil {
                        ProgressView("正在读取游戏封面…").font(.footnote)
                    }

                    if library.isLoading {
                        ProgressView("正在读取游戏库…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if !library.isReady {
                        Button("重新读取游戏库") { library.loadIfNeeded() }
                            .frame(maxWidth: .infinity)
                    } else if library.games.isEmpty && library.importProgress == nil {
                        emptyLibrary
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 20, alignment: .top)], spacing: 24) {
                            ForEach(library.games) { game in
                                gameItem(game)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 1_040)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("NS Duo")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("添加单个 XCI / NSP / NSZ") {
                            importingFolder = false
                            library.isChoosingFiles = true
                            showingImporter = true
                        }
                        Button("诊断日志", systemImage: "doc.text.magnifyingglass") { showingDiagnostics = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(!library.isReady || library.isBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onPrepare) {
                        HStack(spacing: 6) {
                            Text("运行准备").foregroundStyle(.white)
                            if hasPreparedResources && jit.isReady {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .font(.footnote)
                    .accessibilityLabel(hasPreparedResources && jit.isReady ? "运行准备，已全部就绪" : "运行准备，尚未全部就绪")
                    .disabled(library.isBusy)
                }
            }
        }
        .task { library.loadIfNeeded(); onLibraryAppear() }
        .sheet(isPresented: $showingDiagnostics) { NSDuoDiagnosticsView() }
        .onChange(of: showingImporter) { _, shown in library.isChoosingFiles = shown }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importingFolder ? [.folder] : [.xci, .nsp, UTType(filenameExtension: "nsz") ?? .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let source = urls.first {
                    if importingFolder { onImportFolder(source) }
                    else { onImportFile(source) }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    library.message = "无法选择文件：\(error.localizedDescription)"
                }
            }
        }
        .alert("游戏库", isPresented: Binding(
            get: { library.message != nil },
            set: { if !$0 { library.message = nil } }
        )) {
            Button("好", role: .cancel) { library.message = nil }
        } message: {
            Text(library.message ?? "")
        }
        .alert("重命名", isPresented: Binding(
            get: { pendingRename != nil },
            set: { if !$0 { pendingRename = nil } }
        ), presenting: pendingRename) { game in
            TextField("游戏名称", text: $renamedTitle)
            Button("保存") {
                library.rename(game, to: renamedTitle)
                pendingRename = nil
            }
            .disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isBusy)
            Button("取消", role: .cancel) { pendingRename = nil }
        }
        .sheet(item: $pendingRemoval) { game in
            NSDuoRemovalConfirmationView(game: game, isBusy: library.isBusy) {
                library.remove(game)
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("从“文件”添加游戏目录")
                .font(.headline)
            Text("支持 XCI、NSP 和 NSZ。导入一次，以后点击启动；返回游戏库和启动前自动检查新内容。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func gameItem(_ game: NSDuoLibraryGame) -> some View {
        Button {
            library.prepareForLaunch(game, onReady: onPlay)
        } label: {
            VStack(spacing: 10) {
                gameCover(game)
                VStack(spacing: 3) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Text(ByteCountFormatter.string(fromByteCount: game.byteCount, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let folder = game.folder {
                        Text(folder.summary)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(NSDuoGameItemButtonStyle())
        .disabled(library.isBusy)
        .contextMenu {
            Button("重命名", systemImage: "pencil") {
                renamedTitle = game.title
                pendingRename = game
            }
            .disabled(library.isBusy)
            Button("移除游戏", systemImage: "trash", role: .destructive) {
                pendingRemoval = game
            }
            .disabled(library.isBusy)
        }
        .accessibilityLabel(game.title)
        .accessibilityHint("轻点启动游戏，长按可重命名或移除 App 内的副本")
    }

    private func gameCover(_ game: NSDuoLibraryGame) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.accentColor.opacity(0.09))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cover = library.covers[game.id] {
                    Image(uiImage: cover).resizable().scaledToFit()
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(10)
            }
            .accessibilityHidden(true)
    }

    private func importProgressView(_ progress: NSDuoImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(progressTitle(progress))
                        .font(.subheadline.weight(.semibold))
                    Text(progress.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button("取消") { library.cancelImport() }
                    .font(.subheadline)
                    .disabled(progress.phase == .saving || progress.phase == .cancelling)
            }
            if progress.totalBytes > 0 {
                ProgressView(value: progress.fraction)
                Text("\(ByteCountFormatter.string(fromByteCount: progress.copiedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func progressTitle(_ progress: NSDuoImportProgress) -> String {
        switch progress.phase {
        case .preparing: "正在读取所选文件…"
        case .copying: "正在导入 · \(Int(progress.fraction * 100))%"
        case .decompressing: "正在解压 NSZ · \(Int(progress.fraction * 100))%"
        case .saving: "正在保存游戏记录…"
        case .cancelling: "正在取消并清理…"
        }
    }
}

private struct NSDuoGameItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct NSDuoRemovalConfirmationView: View {
    let game: NSDuoLibraryGame
    let isBusy: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(game.title).font(.title3.bold()).multilineTextAlignment(.center)
                    Text("持续按住下方按钮 5 秒即可移除，松手或移出按钮会取消。游戏存档和“文件”中的源文件会保留。")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if isBusy { ProgressView("游戏库正在更新，请稍候…") }
                    NSDuoHoldToRemoveButton(isEnabled: !isBusy) {
                        onConfirm()
                        dismiss()
                    }
                    .frame(height: 64)
                    Button("取消移除", role: .cancel) { dismiss() }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("移除游戏")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
