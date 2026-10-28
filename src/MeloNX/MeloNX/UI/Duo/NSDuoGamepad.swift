import SwiftUI
import UIKit
import Melo_Controller

/// One UIKit touch surface preserves simultaneous sticks/buttons and cancellation.
struct NSDuoGamepad: UIViewRepresentable {
    func makeUIView(context: Context) -> NSDuoGamepadSurface { NSDuoGamepadSurface() }
    func updateUIView(_ view: NSDuoGamepadSurface, context: Context) {}
    static func dismantleUIView(_ view: NSDuoGamepadSurface, coordinator: ()) { view.releaseAll() }
}

final class NSDuoGamepadSurface: UIView {
    private enum Key: Int, CaseIterable {
        case a, b, x, y, minus, plus, l, r, zl, zr, l3, r3, up, down, left, right
        var mapping: VirtualControllerButton {
            switch self {
            case .a: .A; case .b: .B; case .x: .X; case .y: .Y
            case .minus: .back; case .plus: .start
            case .l: .leftShoulder; case .r: .rightShoulder
            case .zl: .leftTrigger; case .zr: .rightTrigger
            case .l3: .leftStick; case .r3: .rightStick
            case .up: .dPadUp; case .down: .dPadDown
            case .left: .dPadLeft; case .right: .dPadRight
            }
        }
        var label: String {
            switch self {
            case .a: "A"; case .b: "B"; case .x: "X"; case .y: "Y"
            case .minus: "−"; case .plus: "+"; case .l: "L"; case .r: "R"
            case .zl: "ZL"; case .zr: "ZR"; case .l3: "L3"; case .r3: "R3"
            case .up: "▲"; case .down: "▼"; case .left: "◀"; case .right: "▶"
            }
        }
    }
    private enum Control { case button, leftStick, rightStick }
    private var assignments: [ObjectIdentifier: Control] = [:]
    private var points: [ObjectIdentifier: CGPoint] = [:]
    private var pressed: Set<Key> = []
    private var rects: [Key: CGRect] = [:]
    private var leftCenter = CGPoint.zero
    private var rightCenter = CGPoint.zero
    private var leftValue = CGPoint.zero
    private var rightValue = CGPoint.zero
    private var radius: CGFloat = 40
    private var previousBounds = CGRect.zero
    private let input = VirtualControllerManager.shared
    private lazy var buttonFeedback = UIImpactFeedbackGenerator(style: .light, view: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = UIColor(red: 0.075, green: 0.085, blue: 0.11, alpha: 1)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseAll), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseAll), name: .nsDuoReleaseInput, object: nil)
        accessibilityLabel = "NS 手柄，双摇杆、方向键、ABXY、肩键、扳机、加减和摇杆按下"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { buttonFeedback.prepare() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != previousBounds else { return }
        releaseAll()
        previousBounds = bounds
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let unit = min(w / 700, h / 330)
        let diameter = max(28, 49 * unit)
        radius = max(27, 53 * unit)
        leftCenter = CGPoint(x: w * 0.17, y: h * 0.43)
        rightCenter = CGPoint(x: w * 0.66, y: h * 0.68)
        func put(_ key: Key, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat? = nil) {
            let width = width ?? diameter
            rects[key] = CGRect(x: w * x - width / 2, y: h * y - diameter / 2, width: width, height: diameter)
        }
        put(.zl, 0.10, 0.12, diameter * 1.45); put(.l, 0.27, 0.12, diameter * 1.45)
        put(.r, 0.73, 0.12, diameter * 1.45); put(.zr, 0.90, 0.12, diameter * 1.45)
        put(.minus, 0.45, 0.19); put(.plus, 0.55, 0.19)
        let stepX = diameter * 0.92 / w, stepY = diameter * 0.92 / h
        put(.x, 0.84, 0.43 - stepY); put(.b, 0.84, 0.43 + stepY)
        put(.y, 0.84 - stepX, 0.43); put(.a, 0.84 + stepX, 0.43)
        put(.up, 0.35, 0.68 - stepY); put(.down, 0.35, 0.68 + stepY)
        put(.left, 0.35 - stepX, 0.68); put(.right, 0.35 + stepX, 0.68)
        put(.l3, 0.13, 0.84); put(.r3, 0.87, 0.84)
        setNeedsDisplay()
    }

    @objc func releaseAll() {
        for key in pressed { input.buttonReleased(key.mapping) }
        pressed.removeAll(); points.removeAll(); assignments.removeAll()
        leftValue = .zero; rightValue = .zero
        input.joystickMoved(position: .zero, right: false)
        input.joystickMoved(position: .zero, right: true)
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch), point = touch.location(in: self)
            let hasLeft = assignments.values.contains { if case .leftStick = $0 { true } else { false } }
            let hasRight = assignments.values.contains { if case .rightStick = $0 { true } else { false } }
            if distance(point, leftCenter) <= radius * 1.3 && !hasLeft {
                assignments[id] = .leftStick
            } else if distance(point, rightCenter) <= radius * 1.3 && !hasRight {
                assignments[id] = .rightStick
            } else { assignments[id] = .button }
            points[id] = point
        }
        publish()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where assignments[ObjectIdentifier(touch)] != nil {
            points[ObjectIdentifier(touch)] = touch.location(in: self)
        }
        publish()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { remove(touches) }
    private func remove(_ touches: Set<UITouch>) {
        for touch in touches {
            assignments.removeValue(forKey: ObjectIdentifier(touch))
            points.removeValue(forKey: ObjectIdentifier(touch))
        }
        publish()
    }
    private func publish() {
        var next: Set<Key> = []
        leftValue = .zero; rightValue = .zero
        for (id, control) in assignments {
            guard let p = points[id] else { continue }
            switch control {
            case .leftStick: leftValue = normalized(p, around: leftCenter)
            case .rightStick: rightValue = normalized(p, around: rightCenter)
            case .button:
                for (key, rect) in rects where rect.contains(p) { next.insert(key) }
            }
        }
        let newlyPressed = next.subtracting(pressed)
        for key in newlyPressed { input.buttonPressed(key.mapping) }
        // Keep the tap subtle but perceptible; the old soft/0.1 pulse was too faint.
        // One pulse per new press batch, including sliding onto another button.
        // Stick movement, held buttons and releases do not trigger feedback.
        if let key = newlyPressed.min(by: { $0.rawValue < $1.rawValue }), let rect = rects[key] {
            buttonFeedback.impactOccurred(intensity: 0.35, at: CGPoint(x: rect.midX, y: rect.midY))
            buttonFeedback.prepare()
        }
        for key in pressed.subtracting(next) { input.buttonReleased(key.mapping) }
        pressed = next
        input.joystickMoved(position: leftValue, right: false)
        input.joystickMoved(position: rightValue, right: true)
        setNeedsDisplay()
    }
    private func normalized(_ point: CGPoint, around center: CGPoint) -> CGPoint {
        let x = (point.x - center.x) / radius, y = (point.y - center.y) / radius
        let length = hypot(x, y)
        guard length > 0.12 else { return .zero }
        let scale = min(1, (length - 0.12) / 0.88) / length
        return CGPoint(x: x * scale, y: y * scale)
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    override func draw(_ rect: CGRect) {
        for key in Key.allCases {
            guard let frame = rects[key] else { continue }
            let down = pressed.contains(key)
            let shape = UIBezierPath(roundedRect: frame, cornerRadius: frame.height * 0.42)
            (down ? UIColor.systemTeal : UIColor.white.withAlphaComponent(0.10)).setFill(); shape.fill()
            UIColor.white.withAlphaComponent(0.18).setStroke(); shape.lineWidth = 1; shape.stroke()
            drawText(key.label, in: frame, size: min(21, frame.height * 0.43), color: down ? .black : .white)
        }
        drawStick(center: leftCenter, value: leftValue)
        drawStick(center: rightCenter, value: rightValue)
    }
    private func drawStick(center: CGPoint, value: CGPoint) {
        let base = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        UIColor.white.withAlphaComponent(0.06).setFill(); UIBezierPath(ovalIn: base).fill()
        UIColor.white.withAlphaComponent(0.18).setStroke(); UIBezierPath(ovalIn: base).stroke()
        let knobRadius = radius * 0.52
        let knob = CGRect(x: center.x + value.x * radius * 0.55 - knobRadius, y: center.y + value.y * radius * 0.55 - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
        UIColor.systemGray3.setFill(); UIBezierPath(ovalIn: knob).fill()
    }
    private func drawText(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
        let extent = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - extent.width / 2, y: rect.midY - extent.height / 2), withAttributes: attributes)
    }
}

extension Notification.Name {
    static let nsDuoReleaseInput = Notification.Name("NSDuo.releaseInput")
}
