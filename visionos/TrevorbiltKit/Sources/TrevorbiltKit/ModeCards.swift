import SwiftUI

/// The ways a port can play, as the AVP Ports Index names them, each with its own small drawing.
public enum PlayMode: Hashable, Sendable {
    /// All around you (a full immersive space).
    case full
    /// A portal in the room that the Digital Crown widens (progressive immersion).
    case progressive
    /// A window beside other apps (the shared space).
    case window
}

/// A large card for one way of playing: its drawing, its name in Space Mono and one line. The
/// selected card wears the orange ring and sits forward.
public struct ModeCard: View {
    private let mode: PlayMode
    private let name: String
    private let line: String
    private let selected: Bool
    private let action: () -> Void

    public init(_ mode: PlayMode, name: String, line: String, selected: Bool, action: @escaping () -> Void) {
        self.mode = mode
        self.name = name
        self.line = line
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ModeIllustration(mode)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(name)
                    .font(.tbHeader(15, bold: true, relativeTo: .headline))
                    .padding(.top, 2)
                Text(line)
                    .font(.tbBody(12, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            // As tall as the tallest card in the row (the row is fixed to its ideal height).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .buttonStyle(TrevorbiltTileButtonStyle(selected: selected))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The drawing on a mode card: a little landscape, all around a viewer (Full), through a portal in
/// a room (Progressive) or in a window beside another (Window). Drawn here, so it scales and every
/// port shares it.
public struct ModeIllustration: View {
    private let mode: PlayMode

    public init(_ mode: PlayMode) {
        self.mode = mode
    }

    public var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            switch mode {
            case .full:
                Self.world(in: bounds, context: context)
                Self.viewer(at: CGPoint(x: size.width / 2, y: size.height * 0.94), scale: size.height / 108, context: context)
                // Around the viewer: the world goes all the way round.
                let ring = CGRect(x: size.width * 0.5 - size.height * 0.5, y: size.height * 0.62,
                                  width: size.height, height: size.height * 0.34)
                context.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6]))
            case .progressive:
                Self.room(in: bounds, context: context)
                let portal = CGRect(x: size.width * 0.2, y: size.height * 0.12, width: size.width * 0.6, height: size.height * 0.62)
                let shape = Path(roundedRect: portal, cornerRadius: portal.height * 0.5, style: .continuous)
                var inside = context
                inside.clip(to: shape)
                Self.world(in: portal.insetBy(dx: -20, dy: -6), context: inside)
                context.stroke(shape, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                // The Digital Crown, turning.
                let crown = CGPoint(x: size.width * 0.9, y: size.height * 0.3)
                let r = size.height * 0.07
                context.fill(Path(ellipseIn: CGRect(x: crown.x - r, y: crown.y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(0.9)))
                var turn = Path()
                turn.addArc(center: crown, radius: r * 1.9, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                context.stroke(turn, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            case .window:
                Self.room(in: bounds, context: context)
                // Another app's window, behind and to the side.
                let other = CGRect(x: size.width * 0.06, y: size.height * 0.14, width: size.width * 0.26, height: size.height * 0.4)
                context.fill(Path(roundedRect: other, cornerRadius: 6, style: .continuous), with: .color(.white.opacity(0.22)))
                for i in 0..<3 {
                    let line = CGRect(x: other.minX + 6, y: other.minY + 8 + CGFloat(i) * 7, width: other.width * (i == 2 ? 0.4 : 0.7), height: 3)
                    context.fill(Path(roundedRect: line, cornerRadius: 1.5), with: .color(.white.opacity(0.35)))
                }
                // The game's window, with its bar below it.
                let window = CGRect(x: size.width * 0.36, y: size.height * 0.1, width: size.width * 0.54, height: size.height * 0.58)
                let shape = Path(roundedRect: window, cornerRadius: 10, style: .continuous)
                var inside = context
                inside.clip(to: shape)
                Self.world(in: window, context: inside)
                context.stroke(shape, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                let bar = CGRect(x: window.midX - window.width * 0.15, y: window.maxY + 6, width: window.width * 0.3, height: 4)
                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(.white.opacity(0.8)))
            }
        }
        .accessibilityHidden(true)
    }

    /// Sky and hills, filling `rect`.
    private static func world(in rect: CGRect, context: GraphicsContext) {
        let sky = Gradient(colors: [Trevorbilt.slate, Color(red: 0.62, green: 0.74, blue: 0.82)])
        context.fill(Path(rect), with: .linearGradient(sky, startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                       endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        // A low sun.
        let sun = CGRect(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.2, width: rect.height * 0.18, height: rect.height * 0.18)
        context.fill(Path(ellipseIn: sun), with: .color(.white.opacity(0.85)))
        func hill(_ base: CGFloat, _ peaks: [(CGFloat, CGFloat)], _ color: Color) {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * base))
            var x = rect.minX
            for (dx, height) in peaks {
                let next = x + rect.width * dx
                path.addQuadCurve(to: CGPoint(x: next, y: rect.minY + rect.height * base),
                                  control: CGPoint(x: (x + next) / 2, y: rect.minY + rect.height * (base - height)))
                x = next
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
        hill(0.68, [(0.3, 0.22), (0.35, 0.3), (0.35, 0.18)], Trevorbilt.sage)
        hill(0.82, [(0.45, 0.2), (0.3, 0.12), (0.25, 0.16)], Trevorbilt.green)
    }

    /// A wall and a floor: the room the portal or window is in.
    private static func room(in rect: CGRect, context: GraphicsContext) {
        context.fill(Path(rect), with: .color(.white.opacity(0.1)))
        var floor = Path()
        floor.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        floor.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.8))
        floor.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.8))
        floor.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        floor.closeSubpath()
        context.fill(floor, with: .color(.white.opacity(0.12)))
    }

    /// The player, from behind: a head over shoulders.
    private static func viewer(at point: CGPoint, scale: CGFloat, context: GraphicsContext) {
        let head = CGRect(x: point.x - 9 * scale, y: point.y - 40 * scale, width: 18 * scale, height: 18 * scale)
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: point.x - 22 * scale, y: point.y))
        shoulders.addQuadCurve(to: CGPoint(x: point.x + 22 * scale, y: point.y),
                               control: CGPoint(x: point.x, y: point.y - 36 * scale))
        shoulders.closeSubpath()
        for (path, color) in [(shoulders, Trevorbilt.darkGreen), (Path(ellipseIn: head), Trevorbilt.darkGreen)] {
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 3)
            context.fill(path, with: .color(color))
        }
    }
}
