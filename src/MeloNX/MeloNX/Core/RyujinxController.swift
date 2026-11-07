//
//  RyujinxController.swift
//  MeloNX
//
//  Created by Stossy11 on 20/4/2026.
//

import SwiftUI
import Combine

extension URL {
    @available(iOS, introduced: 14.0, deprecated: 16.0, message: "Use URL.documentsDirectory on iOS 16 and above")
    static var documentsDirectory: URL {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentDirectory
    }
    
    static var configFolderURL: URL {
        documentsDirectory.appendingPathComponent("config")
    }
    
    static func perGameConfigURL(_ titleId: String) -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configFolderURL.path) {
            try? fileManager.createDirectory(at: configFolderURL, withIntermediateDirectories: true)
        }
        
        return configFolderURL.appendingPathComponent(titleId + "_config.json")
    }
    
    static var configURL: URL {
        documentsDirectory.appendingPathComponent("config.json")
    }
    
    static var romsURL: URL {
        documentsDirectory.appendingPathComponent("roms")
    }
    
    static var keyboardConfigURL: URL {
        documentsDirectory.appendingPathComponent("keyboardConfig.json")
    }
    
    static var keysFolderURL: URL {
        documentsDirectory.appendingPathComponent("system")
    }
    
    static var modsFolderURL: URL {
        documentsDirectory.appendingPathComponent("mods")
    }
    
    static func modFolderURL(for game: GameInfo) -> URL {
        modsFolderURL.appendingPathComponent("contents").appendingPathComponent(game.titleId)
    }
}

extension UIDevice {
    var supportsBCTextureCompression: Bool {
        if #available(iOS 16.4, *), let device = MTLCreateSystemDefaultDevice() {
           return device.supportsBCTextureCompression
        }
        
        return false
    }
}

enum StartedState {
    case none
    case entitlement
    case extendedEntitlement
    case noJIT
    case usersList
}

enum RunningState {
    case started(game: GameInfo, state: StartedState = .none)
    case stopped
    case crashed(result: String)
    
    func hasStarted() -> Bool {
        if case .started(_, let state) = self {
            return state != .noJIT
        }
        return false
    }
    
    func isRunning() -> Bool {
        if case .started(_, let state) = self {
            return state == .none
        }
        return false
    }
    
    func isEntitlement() -> Bool {
        if case .started(_, let state) = self {
            return state == .entitlement
        }
        return false
    }
    
    func hasCrashed() -> Bool {
        if case .crashed = self {
            return true
        }
        return false
    }
}



class RyujinxController: ObservableObject {
    static var shared: RyujinxController = .init()
    
    private init() {}
    
    @Published var isRunning: RunningState = .stopped
    @Published var games: [GameInfo] = []
    @Published var settings: Options = .init(inputPath: "")
    
    @Published var perSettings: [String: Options] = [:]
    
    var currentSettings: Options {
        get {
            if case .started(let game, _) = isRunning {
                return perSettings[game.titleId] ?? settings
            }
            
            return settings
        } set {
            self.objectWillChange.send()
            if case .started(let game, _) = isRunning, perSettings[game.titleId]  != nil {
                perSettings[game.titleId] = newValue
            }
            
            settings = newValue
        }
    }
    
    var lastGameLaunched: String? {
        get {
            UserDefaults.standard.string(forKey: "lastGameLaunched")
        } set {
            if let cool = newValue { UserDefaults.standard.set(newValue, forKey: "lastGameLaunched"); return }
            UserDefaults.standard.removeObject(forKey: "lastGameLaunched")
        }
    }
    
    @Published var _isPaused: Bool = false
    @Published private(set) var isStopping: Bool = false
    @Published private(set) var isGameSuspended = false
    @Published private(set) var motionEnabled = true

    func setMotionEnabled(_ enabled: Bool) {
        guard case .started(let game, _) = isRunning, !isStopping else { return }
        NSDuoMotionPreferences.setEnabled(enabled, titleID: game.titleId)
        motionEnabled = enabled
        controllerManager.setMotionEnabled(enabled)
    }
    
    @Published var wasManuallyPaused: Bool = false
    
    var isPaused: Bool {
        get {
            return _isPaused
        } set {
            guard emulationThreadActive, !isStopping, newValue != _isPaused else { return }
            if newValue { NotificationCenter.default.post(name: .nsDuoReleaseInput, object: nil) }
            _isPaused = newValue
            controllerManager.setEmulationActive(!newValue)
            Ryujinx.togglePauseEmulation(_isPaused)
        }
    }
    
    private static var hasScript: Bool = false
    private var controllerManager: ControllerManager = .shared
    private var emulationThreadActive = false

    var runningGame: GameInfo? {
        guard case .started(let game, .none) = isRunning else { return nil }
        return game
    }

    func isCurrentGame(_ game: NSDuoLibraryGame) -> Bool {
        guard let runningGame else { return false }
        return runningGame.fileURL.standardizedFileURL.path.hasSuffix("/" + game.relativePath)
    }

    func suspendGameToLibrary() {
        guard emulationThreadActive, runningGame != nil, !isStopping else { return }
        isPaused = true
        wasManuallyPaused = true
        isGameSuspended = true
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resumeSuspendedGame() {
        guard isGameSuspended, emulationThreadActive, !isStopping,
              UIApplication.shared.applicationState == .active else { return }
        isGameSuspended = false
        wasManuallyPaused = false
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    var firmwareVersion: String {
        return Ryujinx.installedFirmwareVersion
    }
    
    var firmwareInstalled: Bool {
        !Ryujinx.installedFirmwareVersion.isEmpty
    }
    
    var isJITEnabled: Bool {
        jitEnabled()
    }

    // Observation only: does not execute BRK while a helper is not attached.
    var hasPreparedJIT: Bool { Self.hasScript }
    
    var hasIncreasedMemoryLimitEntitlement: Bool {
        checkAppEntitlement("com.apple.developer.kernel.increased-memory-limit")
    }
    
    var hasExtendedVirtualAddressingEntitlement: Bool {
        checkAppEntitlement("com.apple.developer.kernel.extended-virtual-addressing")
    }

    func stopGame() {
        guard emulationThreadActive, !isStopping else { return }
        NotificationCenter.default.post(name: .nsDuoReleaseInput, object: nil)
        isStopping = true
        NSDuoCheatStore.shared.endSession()
        controllerManager.setEmulationActive(false)
        wasManuallyPaused = false
        // The owner thread resumes paused guest work before draining the GPU.
        // Keep its Metal view and running state alive until mainRyu returns.
        Ryujinx.stopEmulation()
    }
    
    
    
    func startGame(_ game: GameInfo) {
        guard !emulationThreadActive, !isRunning.hasStarted() else { return }
        
        loadConfig()
        
        if !hasIncreasedMemoryLimitEntitlement {
            isRunning = .started(game: game, state: .entitlement)
            lastGameLaunched = nil
            return
        }
        
        if !hasExtendedVirtualAddressingEntitlement && AppEnvironment.shared.requiresExtendedVirtualAddressing() {
            isRunning = .started(game: game, state: .extendedEntitlement)
            lastGameLaunched = nil
            return
        }
        
        // extendedEntitlement
        
        if !isJITEnabled {
            isRunning = .started(game: game, state: .noJIT)
            return
        }
        
        lastGameLaunched = nil
        
        let config = pullKeyboardConfig()
        Ryujinx.setKeyboardConfig(config)
        
        controllerManager.attachAllControllers()
        
        if NativeSettingsManager.exists(game.titleId) {
            print("true")
            NativeSettingsManager.setShared(game.titleId, pullOriginal: true)
        }
        
        loadWithoutSave(game.titleId)
        
        var settings = perSettings[game.titleId] ?? settings
        
        settings.inputPath = game.fileURL.path
        settings.backendThreading = .on
        // NS Duo keeps a per-title shader disk cache for every game. Apply after
        // global/per-game loading so previously imported games also benefit.
        // Preserve resolution, effects, VSync and asynchronous draw behavior.
        settings.disableShaderCache = false
        // Clear late requests from a completed run before this new run can be stopped.
        Ryujinx.prepareEmulationStart()
        
        isRunning = .started(game: game)
        isGameSuspended = false
        _isPaused = false
        wasManuallyPaused = false
        isStopping = false
        emulationThreadActive = true
        motionEnabled = NSDuoMotionPreferences.isEnabled(titleID: game.titleId)
        controllerManager.setMotionEnabled(motionEnabled)
        controllerManager.setEmulationActive(true)
        NSDuoCheatStore.shared.beginSession(for: game)

        let nativeSettingsManager = NativeSettingsManager.shared
        
        let writeConsoleToFile = !(nativeSettingsManager.writeStdout.value as Bool)
        let logsDirectory = URL.documentsDirectory.appendingPathComponent("logs")

        Thread.detachNewThread {
            // Prepare files on the emulation owner, before any core logs are emitted.
            // A log I/O failure must not prevent starting the game.
            if writeConsoleToFile {
                try? NSDuoConsoleLog.shared.start(in: logsDirectory)
            } else {
                NSDuoConsoleLog.shared.stop()
            }
            let response = Ryujinx.mainRyu(settings)
            NSDuoConsoleLog.shared.stop()
            
            DispatchQueue.main.async {
                self.emulationThreadActive = false
                self.controllerManager.setEmulationActive(false)
                self.isStopping = false
                self.isGameSuspended = false
                NSDuoCheatStore.shared.endSession()
                self._isPaused = false
                self.wasManuallyPaused = false
                
                if response != 0 {
                    self.isRunning = .crashed(result: "Code: \(response)")
                } else {
                    self.isRunning = .stopped
                }
            }
        }
    }
    
    
    func loadConfig() {
        if let settings = try? Options.loadFromJSON(at: .configURL) {
            self.settings = settings
        } else {
            try? self.settings.saveAsJSON(to: .configURL)
        }
    }
    
    func saveConfig() {
        try? settings.saveAsJSON(to: .configURL)
    }
    
    func loadPerGameConfig(_ titleId: String) {
        let setting2s = perSettings[titleId] ??  .init(inputPath: "")
        if let settings = try? Options.loadFromJSON(at: .perGameConfigURL(titleId)) {
            self.perSettings[titleId] = settings
        } else {
            try? setting2s.saveAsJSON(to: .perGameConfigURL(titleId))
            self.perSettings[titleId] = .init(inputPath: "")
        }
    }
    
    func loadWithoutSave(_ titleId: String) {
        if let settings = try? Options.loadFromJSON(at: .perGameConfigURL(titleId)) {
            self.perSettings[titleId] = settings
        }
    }
    
    func savePerGameConfig(_ titleId: String) {
        let setting2s = perSettings[titleId] ??  .init(inputPath: "")
        try? setting2s.saveAsJSON(to: .perGameConfigURL(titleId))
    }
    
    func loadGames() {
        let fileManager = FileManager.default
        guard let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        var romDirectories: [URL] = [documentsDirectory.appendingPathComponent("roms")]
        
        let romFolderManager = ROMFolderManager.shared
        romFolderManager.loadBookmarks()
        
        for bookmarkData in romFolderManager.bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                
                if isStale, fileManager.fileExists(atPath: url.path) {
                    _ = romFolderManager.addFolder(url: url)
                }
                
                if url.startAccessingSecurityScopedResource() {
                    romDirectories.append(url)
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        
        let defaultRomsDirectory = documentsDirectory.appendingPathComponent("roms")
        if !fileManager.fileExists(atPath: defaultRomsDirectory.path) {
            do {
                try fileManager.createDirectory(at: defaultRomsDirectory, withIntermediateDirectories: true)
            } catch {
                print("Failed to create roms directory: \(error)")
            }
        }
        
        var games: [GameInfo] = []
        for romsDirectory in romDirectories {
            guard let enumerator = fileManager.enumerator(at: romsDirectory, includingPropertiesForKeys: nil) else {
                continue
            }
            
            for case let fileURL as URL in enumerator {
                guard GameFileType.isSupported(fileExtension: fileURL.pathExtension) else { continue }
                
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    let fileExtension = fileURL.pathExtension as NSString
                    games.append(Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension, path: fileURL))
                } catch {
                    print("Failed to read file at \(fileURL): \(error)")
                }
            }
        }
        
        self.games = games
        
        sortGames(true)
    }
    
    func sortGames(_ isCalled: Bool = false) {
        let nativeSettingsManager: NativeSettingsManager = .shared
        switch nativeSettingsManager.gameSort(GameSort.none).value {
        case .alphabetical:
            games = games.sorted { $0.titleName < $1.titleName }
        case .newest:
            games = games.sorted { (game, gam2) -> Bool in
                let date1 = (try? game.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let date2 = (try? gam2.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                
                return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
            }
        case .none:
            if !isCalled { loadGames() }
        }
    }
    
    static func attemptToMapDualMapping() -> Bool {
        if hasScript { return true }
        
        hasScript = Ryujinx.initDualMapping()
        
        return hasScript
    }
    
    func attemptToMapDualMapping() -> Bool {
        Self.attemptToMapDualMapping()
    }
}
