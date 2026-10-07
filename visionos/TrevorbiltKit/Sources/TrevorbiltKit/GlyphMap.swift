import SwiftUI
import UIKit

/// One control as a guide shows it: the controller's own symbol for it (GCControllerElement's
/// sfSymbolsName, or a neutral one with nothing connected), what it does here, and its name in
/// words ("A / Cross"). No actions: it does nothing here, and isn't shown.
public struct GlyphControl {
    public let control: String
    public let symbol: String
    public let actions: [String]
    public let name: String

    public init(_ control: String, symbol: String, actions: [String], name: String) {
        self.control = control
        self.symbol = symbol
        self.actions = actions
        self.name = name
    }

    /// The symbol for a control with nothing connected, in the drawing's family, so it matches
    /// the buttons drawn: PlayStation shapes and L1 / R2 on the DualSense-style and Sense-style
    /// drawings, letters and LB / RT on the Xbox-style one. For the controls named as in the kit's
    /// guides: leftStick, rightStick, a, b, x, y, dpad, leftShoulder, rightShoulder, leftTrigger,
    /// rightTrigger, menu, view.
    public static func neutralSymbol(_ control: String, for rig: ControllerRig) -> String {
        let xbox = rig == .xbox
        return switch control {
        case "a": xbox ? "a.circle" : "xmark.circle"
        case "b": xbox ? "b.circle" : "circle.circle"
        case "x": xbox ? "x.circle" : "square.circle"
        case "y": xbox ? "y.circle" : "triangle.circle"
        case "leftShoulder": xbox ? "lb.rectangle.roundedbottom" : "l1.rectangle.roundedbottom"
        case "rightShoulder": xbox ? "rb.rectangle.roundedbottom" : "r1.rectangle.roundedbottom"
        case "leftTrigger": xbox ? "lt.rectangle.roundedtop" : "l2.rectangle.roundedtop"
        case "rightTrigger": xbox ? "rt.rectangle.roundedtop" : "r2.rectangle.roundedtop"
        case "leftStick": "l.joystick"
        case "rightStick": "r.joystick"
        case "dpad": "dpad"
        case "menu": "line.3.horizontal.circle"
        case "view": "rectangle.on.rectangle.circle"
        default: "circle"
        }
    }

    /// Every neutral symbol that isn't in this system's SF Symbols (none, normally): for a check
    /// in a port's test runs.
    public static func missingNeutralSymbols() -> [String] {
        let controls = ["a", "b", "x", "y", "leftShoulder", "rightShoulder", "leftTrigger", "rightTrigger",
                        "leftStick", "rightStick", "dpad", "menu", "view"]
        let names = Set([ControllerRig.dualSense, .xbox, .sensePair].flatMap { rig in controls.map { neutralSymbol($0, for: rig) } })
        return names.filter { UIImage(systemName: $0) == nil }.sorted()
    }
}

/// A control's symbol, large, on glass.
struct GlyphTile: View {
    let symbol: String
    var size: CGFloat = 50

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.62, weight: .medium))
            .frame(width: size, height: size)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}
