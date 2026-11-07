//
//  InGameConfigView.swift
//  MeloNX
//
//  Created by Stossy11 on 7/7/2026.
//

import SwiftUI
import Melo_Controller
import Combine

@MainActor
class InGameConfigView_MenuView: ObservableObject {
    @Published private(set) var showButton = false
    private var hideTask: Task<Void, Never>?
    private var hideDeadline = ContinuousClock.now
    private(set) var cornerRevealOnly = false
    static let shared = InGameConfigView_MenuView()

    func triggerButton() {
        guard !cornerRevealOnly else { return }
        hideDeadline = .now.advanced(by: .seconds(5))
        if !showButton { showButton = true }
        // Pointer movement extends the deadline without publishing or creating
        // and cancelling a new Task for each touch event.
        guard hideTask == nil else { return }
        hideTask = Task { [weak self] in
            while let deadline = self?.hideDeadline {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard !Task.isCancelled else { return }
                if let self, self.hideDeadline <= .now {
                    self.hideTask = nil
                    if self.showButton { self.showButton = false }
                    return
                }
            }
        }
    }

    func setCornerRevealOnly(_ enabled: Bool) {
        guard cornerRevealOnly != enabled else { return }
        cornerRevealOnly = enabled
        hide()
    }

    func handleCornerTap(insideCorner: Bool) {
        guard cornerRevealOnly else { return }
        if insideCorner {
            cancelAutoHide()
            if !showButton { showButton = true }
        } else {
            hide()
        }
    }

    func cancelAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    func hide() {
        cancelAutoHide()
        if showButton { showButton = false }
    }
}

struct InGameConfigView: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @ObservedObject var controllerManager: ControllerManager = .shared
    @StateObject var menuViewHandler: InGameConfigView_MenuView = .shared
    @State var rotationlock: Bool = false
    @State var showingKeyboardConfig: Bool = false
    @State var showControllerSettings: Bool = false
    

    
    var body: some View {
        Menu {
            menuButton
        } label: {
            ButtonView(controller: VirtualControllerManager.shared, disabled: true, button: .guide, opacity: 0.4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding()
        .opacity(menuViewHandler.showButton ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: menuViewHandler.showButton)
        .sheet(isPresented: $showControllerSettings) {
            controllerSelection
        }
    }
    
    
    @ViewBuilder
    private var menuButton: some View {
        Button {
            ryujinxController.isPaused.toggle()
            ryujinxController.wasManuallyPaused = ryujinxController.isPaused
        } label: {
            Label {
                Text(ryujinxController.isPaused ? "Play" : "Pause")
            } icon: {
                Image(systemName: ryujinxController.isPaused ? "play.circle" : "pause.circle")
            }
        }
        
        Button {
            showControllerSettings = true
        } label: {
            Label {
                Text("Configure Controllers")
            } icon: {
                Image(systemName: "gamecontroller")
            }
        }
        
        if UIDevice.current.userInterfaceIdiom == .phone {
            Button {
                rotationlock.toggle()
                if rotationlock {
                    OrientationManager.lockCurrentOrientation(UIDevice.current.orientation)
                } else {
                    OrientationManager.lockOrientation(.all, rotateTo: UIDevice.current.orientation)
                }
            } label: {
                Label {
                    Text("Rotation Lock")
                } icon: {
                    Image(systemName: rotationlock ? "lock" : "lock.open")
                }
            }
        }
        
        
        Button(role: .destructive) {
            Ryujinx.stopEmulation()
            Ryujinx.emulationView = nil
            ryujinxController.isRunning = .stopped
        } label: {
            Label {
                Text("Exit (Unstable)")
            } icon: {
                Image(systemName: "x.circle")
            }
        }
         
    }
    
    @ViewBuilder
    private var controllerSelection: some View {
        List {
            Section("Controller Selection") {
                if controllerManager.selectedControllers.isEmpty {
                    Text("No controllers selected, keyboard will be used")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(controllerManager.selectedControllers.enumerated()), id: \.offset) { index, id in
                        ControllerRow(index: index, controllerId: id, controllerManager: controllerManager)
                    }
                }
                if hasAvailableControllers {
                    Menu {
                        ForEach(controllerManager.allControllers.filter {
                            !contains(controllerManager.selectedControllers, value: $0)
                        }) { controller in
                            Button(controller.name) {
                                controllerManager.selectedControllers.append(controller.id)
                            }
                        }
                    } label: {
                        Label("Add Controller", systemImage: "plus.circle.fill")
                    }
                }
            }
            
            
            if controllerManager.selectedControllers.isEmpty {
                Section {
                    Button("Map Keyboard") {
                        showingKeyboardConfig = true
                    }
                    .sheet(isPresented: $showingKeyboardConfig) {
                        KeyboardConfigView()
                    }
                }
            }
        }
        .padding(.top)
        .onAppear {
            controllerManager.refreshControllersList()
        }
        .onDisappear {
            controllerManager.refreshControllersList(true)
        }
    }
    
    private var hasAvailableControllers: Bool {
        !ControllerManager.shared.allControllers
            .filter { !contains(ControllerManager.shared.selectedControllers, value: $0) }
            .isEmpty
    }
    
    func contains(_ array: [String], value: BaseController) -> Bool {
        array.contains { $0 == value.id }
    }
}
