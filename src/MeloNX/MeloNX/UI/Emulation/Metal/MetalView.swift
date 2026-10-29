import SwiftUI
import MetalKit

class MetalView: MTKView {
    private let menuViewShower = InGameConfigView_MenuView.shared
    private var touches = NSDuoTouchSlots<UITouch>()

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        setupTouchTracking()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupTouchTracking()
    }

    private func setupTouchTracking() {
        isMultipleTouchEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(resetTouchTracking),
                                               name: .nsDuoReleaseInput, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetTouchTracking),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    func setAspectRatio() {
        Ryujinx.setViewSize(bounds)
        Ryujinx.setUnboundedPresentTargetFps(for: window?.screen)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { resetTouchTracking() }
        setAspectRatio()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setAspectRatio()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        menuViewShower.triggerButton()
        guard !UserDefaults.standard.bool(forKey: "disableTouch") else { return }
        for touch in touches {
            if let id = self.touches.begin(touch) {
                Ryujinx.touchBegan(touch.location(in: self), index: id)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        menuViewShower.triggerButton()
        guard !UserDefaults.standard.bool(forKey: "disableTouch") else {
            resetTouchTracking()
            return
        }
        for touch in touches {
            if let id = self.touches.index(for: touch) {
                Ryujinx.touchMoved(touch.location(in: self), index: id)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        // Even if touch input was disabled mid-gesture, native contacts must end.
        for touch in touches {
            if let id = self.touches.end(touch) { Ryujinx.touchEnded(index: id) }
        }
    }

    @objc func resetTouchTracking() {
        for id in touches.releaseAll() { Ryujinx.touchEnded(index: id) }
    }
}


struct MetalViewRepresentable: UIViewRepresentable {
    var showView: Bool
    
    init(showView: Bool = true) {
        self.showView = showView
    }
    
    func makeUIView(context: Context) -> UIView {
        if showView {
            return Self.createView()
        } else { return MetalView() }
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        
    }
    
    @discardableResult
    static func createView() -> UIView {
        if Ryujinx.emulationView == nil {
            let view = MetalView()
            
            guard let metalLayer = view.layer as? CAMetalLayer else {
                fatalError("[Swift] Error: MTKView's layer is not a CAMetalLayer")
            }
            
            UIApplication.shared.isIdleTimerDisabled = true
            
            //metalLayer.presentsWithTransaction = false
            //metalLayer.allowsNextDrawableTimeout = false
            
            if metalLayer.device == nil {
                metalLayer.device = MTLCreateSystemDefaultDevice()
            }
            
            let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()
            
            Ryujinx.setNativeWindow(layerPtr)
            Ryujinx.setUnboundedPresentTargetFps(for: view.window?.screen)
            
            Ryujinx.emulationView = view
            return view
        }
        
        return Ryujinx.emulationView!
    }
}
