import SwiftUI
import UniformTypeIdentifiers

struct NSDuoPreparationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var core: RyujinxController
    @State private var hasKeys = false
    @State private var firmware = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var showPhoneGuide = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("游戏只需导入一次。首次运行还需要你自己的 Switch 密钥和固件，准备好后会保留。")
                }
                Section("首次准备") {
                    Button(action: importKeys) {
                        Label(hasKeys ? "密钥已保存 · 可重新导入" : "选择 prod.keys", systemImage: hasKeys ? "checkmark.circle.fill" : "key")
                    }
                    Button(action: importFirmware) {
                        Label(firmware.isEmpty ? "选择固件 ZIP 或文件夹" : "固件 \(firmware) · 可重新导入", systemImage: firmware.isEmpty ? "shippingbox" : "checkmark.circle.fill")
                    }
                    .disabled(!hasKeys)
                }
                Section("运行准备") {
                    NSDuoJITSetupControls()
                    Button("首次使用说明") { showPhoneGuide = true }
                }
                if busy { ProgressView("正在安装固件，请稍候…") }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle("运行准备")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $showPhoneGuide) { NSDuoPhoneGuide() }
            .onAppear(perform: refresh)

        }
    }

    private func refresh() {
        hasKeys = core.verifyKeysFile(path: .keysFolderURL, keys: .prod)
        firmware = core.firmwareVersion
    }
    private func importKeys() {
        FileImporterManager.shared.importFiles(types: [.item], allowMultiple: true) { result in
            switch result {
            case .success(let urls):
                do {
                    try FileManager.default.createDirectory(at: .keysFolderURL, withIntermediateDirectories: true)
                    for url in urls {
                        guard let key = Keys.keyForFile(url) else { throw PreparationError("请选择 prod.keys 或 title.keys。") }
                        guard core.verifyKeysFile(path: url) else { throw PreparationError("\(key.fileName) 的格式不正确，请重新导出。") }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey])
                        guard let size = values.fileSize, size > 0, size <= 1_048_576 else { throw PreparationError("密钥文件大小不正确。") }
                        let data = try Data(contentsOf: url)
                        try data.write(to: URL.keysFolderURL.appendingPathComponent(key.fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }
                    Ryujinx.reloadKeySet()
                    failure = nil
                    refresh()
                } catch { failure = error.localizedDescription }
            case .failure(let error):
                if (error as NSError).domain != "FileImporterManager" || (error as NSError).code != 2 { failure = error.localizedDescription }
            }
        }
    }
    private func importFirmware() {
        FileImporterManager.shared.importFiles(types: [.zip, .folder]) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                busy = true
                failure = nil
                Task {
                    let error = await Task.detached(priority: .userInitiated) { () -> String? in
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        var coordinationError: NSError?
                        var installationError: String?
                        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                            do { try Ryujinx.installFirmware(at: coordinatedURL.path) }
                            catch FirmwareInstallationError.failedInstall(let reason) { installationError = reason }
                            catch { installationError = error.localizedDescription }
                        }
                        return coordinationError?.localizedDescription ?? installationError
                    }.value
                    busy = false
                    failure = error
                    refresh()
                }
            case .failure(let error):
                if (error as NSError).domain != "FileImporterManager" || (error as NSError).code != 2 { failure = error.localizedDescription }
            }
        }
    }
}

private struct PreparationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
