import SwiftUI

enum NSDuoCheatMode: String {
    case edit, enable

    var title: String { self == .edit ? "编辑金手指" : "启用金手指" }
}

struct NSDuoCheatDestination: Identifiable {
    let game: NSDuoLibraryGame
    let mode: NSDuoCheatMode
    // Editing and enabling the same game are separate sheet identities.
    var id: String { game.id.uuidString + ":" + mode.rawValue }
}

struct NSDuoCheatsView: View {
    let game: NSDuoLibraryGame
    let initialMode: NSDuoCheatMode
    @EnvironmentObject private var core: RyujinxController
    @Environment(\.dismiss) private var dismiss
    @State private var document = NSDuoCheatDocument()
    @State private var runtimeInfo: NSDuoCheatRuntimeInfo?
    @State private var mode: NSDuoCheatMode
    @State private var source = ""
    @State private var buildID = ""
    @State private var defaultName = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    init(game: NSDuoLibraryGame, mode: NSDuoCheatMode) {
        self.game = game
        self.initialMode = mode
        _mode = State(initialValue: mode)
    }

    private var isCurrentGame: Bool { core.isCurrentGame(game) }
    private var editingFromEnable: Bool { initialMode == .enable && mode == .edit }
    private var editingExistingGroup: Bool {
        let value = buildID.trimmingCharacters(in: .whitespacesAndNewlines)
        return document.groups.contains { $0.buildID.caseInsensitiveCompare(value) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在读取金手指…")
                } else if mode == .edit {
                    editor
                } else {
                    choices
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editingFromEnable ? "返回" : "取消") {
                        if editingFromEnable { mode = .enable }
                        else { dismiss() }
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if mode == .edit {
                        Button(editingExistingGroup ? "保存修改" : "保存") { saveEditor() }
                            .disabled(loading || saving || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button(isCurrentGame ? "应用并返回游戏" : "保存选择") { saveChoices() }
                            .disabled(loading || saving || core.isStopping || (isCurrentGame && runtimeInfo == nil))
                    }
                }
            }
            .disabled(saving)
            .overlay { if saving { ProgressView(mode == .edit ? "正在保存…" : "正在应用…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .alert(mode.title, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(saving)
        .task { await load() }
        .onChange(of: core.isStopping) { _, stopping in if stopping && !saving { dismiss() } }
    }

    private var choices: some View {
        Form {
            Section {
                Text(game.title).font(.headline)
                Text(isCurrentGame ? "选择需要的功能，点击“应用并返回游戏”后继续当前进度。" : "保存后，下次启动这款游戏时自动应用已开启的功能。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if document.groups.isEmpty {
                Section {
                    ContentUnavailableView("尚未添加金手指", systemImage: "wand.and.stars",
                                           description: Text("长按游戏选择“编辑金手指”，或点击下方按钮，填写 Build ID 并粘贴对应版本的完整代码。"))
                }
            }
            ForEach($document.groups) { $group in
                Section {
                    ForEach($group.entries) { $entry in
                        if !entry.isMaster {
                            Toggle(entry.name, isOn: $entry.isEnabled)
                                .disabled(isCurrentGame && !matchesCurrentBuild(group.buildID) && !entry.isEnabled)
                        }
                    }
                    if group.entries.contains(where: \.isMaster) {
                        Text("本版本的基础代码会随所选功能自动启用。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Build ID · \(group.buildID)")
                } footer: {
                    if isCurrentGame && !matchesCurrentBuild(group.buildID) {
                        Text("与当前运行版本不匹配。请关闭此组开关，或导入当前版本的代码。")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Button("编辑金手指", systemImage: "square.and.pencil") { mode = .edit }
                if isCurrentGame && runtimeInfo == nil {
                    Button("重新读取当前游戏版本") { Task { await readRuntimeInfo() } }
                    Text("游戏尚未提供运行信息，请等待启动完成后重试。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("关闭开关会停止后续修改，已经改变的数值不一定恢复。部分功能需要进入对应场景或按指定按键才会触发。")
            }
        }
    }

    private var editor: some View {
        Form {
            Section {
                Text(game.title).font(.headline)
                if document.groups.count > 1 {
                    Menu("选择已保存版本") {
                        ForEach(document.groups) { group in
                            Button(group.buildID) { restoreEditor(from: group) }
                        }
                    }
                }
                TextField("适用版本 Build ID（16 位）", text: $buildID)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .onChange(of: buildID) { _, value in
                        if value.count > 64 { buildID = String(value.prefix(64)) }
                    }
                if let runtimeInfo, isCurrentGame {
                    ForEach(runtimeInfo.buildIDs, id: \.self) { value in
                        Button("使用当前版本 \(value)") { buildID = value }
                            .font(.footnote.monospaced())
                    }
                }
                TextField("功能名称（代码没有 [名称] 时填写）", text: $defaultName)
            } footer: {
                Text(isCurrentGame
                     ? "已读取当前游戏的版本标识。请确认代码来源与这个版本一致。"
                     : "填写原金手指 .txt 文件名中的 16 位 Build ID，不含扩展名。也可先启动并挂起游戏，再编辑以自动读取。")
            }
            Section {
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first {
                        guard value.utf8.count <= NSDuoCheatParser.maximumTextBytes else {
                            error = "粘贴内容超过 512 KB，请减少内容。"
                            return
                        }
                        source = value
                    }
                }
                TextEditor(text: $source)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .frame(minHeight: 240)
                    .accessibilityLabel("Atmosphère 金手指内容")
                    .onChange(of: source) { previous, value in
                        if value.utf8.count > NSDuoCheatParser.maximumTextBytes {
                            source = previous
                            error = "内容超过 512 KB，本次输入未接受，请减少内容。"
                        }
                    }
            } header: {
                Text("金手指内容")
            } footer: {
                Text("支持 Atmosphère 的 [功能名称] 和 {基础代码名称} 分段。同一 Build ID 的内容会被替换；新增或代码已变化的功能默认关闭，保存后可在“启用金手指”中选择。")
            }
        }
    }

    private func matchesCurrentBuild(_ build: String) -> Bool {
        runtimeInfo?.buildIDs.contains(where: { $0.caseInsensitiveCompare(build) == .orderedSame }) == true
    }

    private func load() async {
        do {
            document = try await NSDuoCheatStore.shared.load(for: game)
            if let group = document.groups.last { restoreEditor(from: group) }
        }
        catch { self.error = error.localizedDescription }
        await readRuntimeInfo()
        loading = false
    }

    private func restoreEditor(from group: NSDuoCheatGroup) {
        buildID = group.buildID
        source = group.editableSource
        defaultName = group.sourceDefaultName ?? ""
    }

    private func readRuntimeInfo() async {
        guard isCurrentGame, !core.isStopping else { runtimeInfo = nil; return }
        let titleID = core.runningGame?.titleId
        if let info = try? await Task.detached(operation: { try NSDuoCheatRuntime.info() }).value,
           info.titleID.caseInsensitiveCompare(titleID ?? "") == .orderedSame {
            runtimeInfo = info
            if buildID.isEmpty { buildID = info.buildIDs.first ?? "" }
        } else { runtimeInfo = nil }
    }

    private func saveEditor() {
        do {
            var group = try NSDuoCheatParser.parse(source, buildID: buildID, defaultName: defaultName)
            if let previous = document.groups.first(where: { $0.buildID == group.buildID }) {
                for index in group.entries.indices {
                    if let old = previous.entries.first(where: {
                        $0.name == group.entries[index].name && $0.instructions == group.entries[index].instructions
                            && $0.isMaster == group.entries[index].isMaster
                    }) { group.entries[index].id = old.id; group.entries[index].isEnabled = old.isEnabled }
                }
            }
            var updated = document
            updated.groups.removeAll { $0.buildID == group.buildID }
            updated.groups.append(group)
            saving = true
            Task {
                defer { saving = false }
                do {
                    try await NSDuoCheatStore.shared.save(updated, for: game, applyToRunningGame: isCurrentGame)
                    document = updated
                    restoreEditor(from: group)
                    if initialMode == .edit { dismiss() }
                    else { mode = .enable }
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func saveChoices() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let resume = isCurrentGame && core.isGameSuspended
                try await NSDuoCheatStore.shared.save(document, for: game, applyToRunningGame: isCurrentGame)
                dismiss()
                if resume && core.isCurrentGame(game) { core.resumeSuspendedGame() }
            } catch { self.error = error.localizedDescription }
        }
    }
}
