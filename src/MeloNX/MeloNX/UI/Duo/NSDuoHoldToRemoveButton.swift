import SwiftUI
import UIKit
import CoreHaptics

struct NSDuoHoldToRemoveButton: UIViewRepresentable {
    let isEnabled: Bool
    let onConfirm: () -> Void

    func makeUIView(context: Context) -> NSDuoHoldRemovalControl { NSDuoHoldRemovalControl() }
    func updateUIView(_ view: NSDuoHoldRemovalControl, context: Context) {
        view.onConfirm = onConfirm
        view.isEnabled = isEnabled
    }
    static func dismantleUIView(_ view: NSDuoHoldRemovalControl, coordinator: ()) { view.cancelHold() }
}

final class NSDuoHoldRemovalControl: UIControl {
    var onConfirm: (() -> Void)?
    private var confirmation = NSDuoHoldConfirmation()
    private var displayLink: CADisplayLink?
    private var trackedTouch: UITouch?
    private let title = UILabel()
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private var previousSize = CGSize.zero
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticPatternPlayer?
    private lazy var feedback: UIImpactFeedbackGenerator = {
        if #available(iOS 17.5, *) {
            return UIImpactFeedbackGenerator(style: .light, view: self)
        }
        return UIImpactFeedbackGenerator(style: .light)
    }()
    private var lastPulse: TimeInterval = 0

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelHold() }
            alpha = isEnabled ? 1 : 0.45
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemRed.withAlphaComponent(0.1)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        isMultipleTouchEnabled = false
        isExclusiveTouch = true
        for shape in [track, progress] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 3
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        track.strokeColor = UIColor.systemRed.withAlphaComponent(0.2).cgColor
        progress.strokeColor = UIColor.systemRed.cgColor
        progress.strokeEnd = 0
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .systemRed
        title.textAlignment = .center
        title.numberOfLines = 2
        title.isUserInteractionEnabled = false
        addSubview(title)
        isAccessibilityElement = true
        accessibilityLabel = "长按 5 秒移除游戏"
        accessibilityHint = "持续按住五秒。松手或移出按钮取消。"
        accessibilityTraits = .button
        NotificationCenter.default.addObserver(self, selector: #selector(cancelHold), name: UIApplication.willResignActiveNotification, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelHold() } else { feedback.prepare() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != .zero, previousSize != bounds.size { cancelHold() }
        previousSize = bounds.size
        title.frame = bounds.insetBy(dx: 16, dy: 8)
        let r = bounds.insetBy(dx: 2, dy: 2)
        let radius = min(16, r.height / 2)
        let path = UIBezierPath()
        // Start at the top center and grow clockwise around the button itself.
        path.move(to: CGPoint(x: r.midX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addArc(withCenter: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        path.addArc(withCenter: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addArc(withCenter: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addArc(withCenter: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        path.addLine(to: CGPoint(x: r.midX, y: r.minY))
        path.close()
        track.path = path.cgPath
        progress.path = path.cgPath
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, window != nil, UIApplication.shared.applicationState == .active,
              confirmation.begin(at: CACurrentMediaTime()) else { return false }
        trackedTouch = touch
        lastPulse = 0
        startHaptics()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
        refresh()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard touch === trackedTouch, isEnabled, bounds.contains(touch.location(in: self)) else {
            cancelHold()
            return false
        }
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { cancelHold() }
    override func cancelTracking(with event: UIEvent?) { cancelHold() }

    @objc private func tick() {
        guard isEnabled, isTracking, window != nil, UIApplication.shared.applicationState == .active,
              let touch = trackedTouch, touch.phase != .ended, touch.phase != .cancelled,
              bounds.contains(touch.location(in: self)) else { cancelHold(); return }
        let now = CACurrentMediaTime()
        let completed = confirmation.advance(at: now)
        guard confirmation.isHolding || completed else { cancelHold(); return }
        refresh()
        if completed {
            stopFeedback()
            trackedTouch = nil
            isUserInteractionEnabled = false
            onConfirm?()
        } else if hapticPlayer == nil, now - lastPulse >= 0.22 {
            // Match the virtual gamepad's quiet fallback on each supported OS.
            if #available(iOS 17.5, *) {
                feedback.impactOccurred(intensity: confirmation.hapticIntensity, at: CGPoint(x: bounds.midX, y: bounds.midY))
            } else {
                feedback.impactOccurred(intensity: confirmation.hapticIntensity)
            }
            feedback.prepare()
            lastPulse = now
        }
    }

    @objc func cancelHold() {
        stopFeedback()
        trackedTouch = nil
        confirmation.cancel()
        refresh()
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeEnd = confirmation.progress
        CATransaction.commit()
        let remaining = max(1, Int(ceil((1 - confirmation.progress) * NSDuoHoldConfirmation.duration)))
        title.text = confirmation.completed ? "正在移除…" : confirmation.isHolding ? "保持按住 · \(remaining) 秒" : "长按 5 秒移除游戏"
        accessibilityValue = confirmation.isHolding ? "\(Int(confirmation.progress * 100))%" : nil
    }

    private func startHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try hapticEngine ?? CHHapticEngine()
            hapticEngine = engine
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 1),
                .init(parameterID: .hapticSharpness, value: 0.12)
            ], relativeTime: 0, duration: NSDuoHoldConfirmation.duration)
            let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.06),
                .init(relativeTime: NSDuoHoldConfirmation.duration, value: 0.3)
            ], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameterCurves: [curve])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            hapticPlayer = player
        } catch { hapticPlayer = nil }
    }

    private func stopFeedback() {
        displayLink?.invalidate()
        displayLink = nil
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
    }
}

nonisolated struct NSDuoHoldConfirmation {
    static let duration: TimeInterval = 5
    private var began: TimeInterval?
    private var lastTick: TimeInterval?
    private(set) var progress: Double = 0
    private(set) var completed = false
    var isHolding: Bool { began != nil && !completed }
    var hapticIntensity: Double { 0.06 + 0.24 * progress }

    mutating func begin(at now: TimeInterval) -> Bool {
        guard began == nil, !completed else { return false }
        began = now
        lastTick = now
        progress = 0
        return true
    }
    mutating func cancel() {
        guard !completed else { return }
        began = nil
        lastTick = nil
        progress = 0
    }
    mutating func advance(at now: TimeInterval) -> Bool {
        guard let began, let lastTick, !completed else { return false }
        // A suspended or unresponsive UI cannot silently finish a destructive hold.
        guard now >= lastTick, now - lastTick <= 0.5 else { cancel(); return false }
        self.lastTick = now
        progress = min(1, max(0, (now - began) / Self.duration))
        completed = progress >= 1
        return completed
    }
}
