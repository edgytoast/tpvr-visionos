import SwiftUI
import UIKit

/// What a controls guide draws: a DualSense-style pad, an Xbox-style pad (offset sticks), or a
/// pair of Sense-style hand controllers. Our own illustrations of each kind: no maker's artwork
/// or logos.
public enum ControllerRig: Sendable {
    case dualSense, xbox, sensePair
}

/// A controller drawn in the middle with a callout for each control that does something: its
/// symbol in a chip, what it does and its name, in a column to the left or right (or the row
/// below the drawing: a DualSense's sticks, an Xbox pad's d-pad and right stick), joined to its
/// button by a dotted line that ends in a dot on the button's edge. The drawings are our own
/// illustrations of each kind of controller; the buttons on them show the connected controller's
/// own symbols.
///
/// Controls are named as everywhere in the kit: leftStick, rightStick, a, b, x, y, dpad,
/// leftShoulder, rightShoulder, leftTrigger, rightTrigger, menu, view. 592 x 330 pt.
public struct ControllerCallouts: View {
    private let rig: ControllerRig
    private let controls: [GlyphControl]
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(rig: ControllerRig, controls: [GlyphControl]) {
        self.rig = rig
        self.controls = controls
    }

    static let size = CGSize(width: 592, height: 330)
    static let largestType = DynamicTypeSize.xxLarge

    public var body: some View {
        let used = controls.filter { !$0.actions.isEmpty }
        // Each label's real height, measured at this text size, so the column spaces them apart.
        let size = min(typeSize, Self.largestType)
        let heights = Dictionary(used.map { ($0.control, CalloutLabel.height(of: $0, size: size)) }, uniquingKeysWith: { first, _ in first })
        let layout = CalloutLayout(rig: rig, controls: used, heights: heights)
        ZStack(alignment: .topLeading) {
            // The drawing, then the lines over it, each stopping at a dot on its own button's edge:
            // a line that passes another button on its way is seen to pass over it. Every face
            // button carries its symbol; those that do nothing here, dimmed.
            let usedNames = Set(used.map(\.control))
            let symbols = Dictionary(controls.map { ($0.control, $0.symbol) }, uniquingKeysWith: { first, _ in first })
            ControllerDrawing(rig: rig, layer: .body, used: usedNames, symbols: symbols)
            ControllerDrawing(rig: rig, layer: .buttons, used: usedNames, symbols: symbols)
            ForEach(layout.callouts, id: \.control.control) { callout in
                LeaderLine(points: callout.line)
                    .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1.5, 3]))
            }
            .allowsHitTesting(false)
            // Every dot over every line.
            ForEach(layout.callouts, id: \.control.control) { callout in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
                    .frame(width: 7.2, height: 7.2)
                    .position(callout.end)
            }
            .allowsHitTesting(false)
            ForEach(layout.callouts, id: \.control.control) { callout in
                CalloutLabel(callout: callout)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The columns are 92 pt wide in a fixed area: larger text wouldn't fit.
        .dynamicTypeSize(...Self.largestType)
    }
}

/// A drawing's size, where each control's line ends on it, and which column (or the row below)
/// its callout goes in.
struct RigGeometry {
    /// Something drawn in the buttons layer, as a circle its size: a line crossing it can look as if
    /// it ends there, so lines keep clear. `control` is nil for the buttons no control here uses (PS, mute, guide, share).
    struct Obstacle { let control: String?; let point: CGPoint; let radius: CGFloat }

    /// A control's button as drawn, round its target, for where its line's dot goes: everything
    /// within `radius` of the stretch `length` either side of the target along `axis` (a pill), or
    /// of the target itself (a round button, `length` 0).
    struct Outline {
        let radius: CGFloat
        let length: CGFloat
        let axis: CGVector

        static func round(_ radius: CGFloat) -> Outline { Outline(radius: radius, length: 0, axis: CGVector(dx: 0, dy: 1)) }

        /// A pill `width` across and `height` long, upright, then turned `degrees` as the drawing
        /// turns it (clockwise on screen).
        static func pill(width: CGFloat, height: CGFloat, degrees: CGFloat) -> Outline {
            let turn = degrees * .pi / 180
            return Outline(radius: width / 2, length: (height - width) / 2, axis: CGVector(dx: -sin(turn), dy: cos(turn)))
        }

        func scaled(_ scale: CGFloat) -> Outline { Outline(radius: radius * scale, length: length * scale, axis: axis) }
    }

    let size: CGSize
    let targets: [String: CGPoint]
    let sides: [String: CalloutLayout.Side]
    /// Everything in the buttons layer, in the drawing's space.
    let obstacles: [Obstacle]
    /// Each control's button that's drawn in the buttons layer; none for the triggers and bumpers,
    /// which the lines are drawn over.
    let outlines: [String: Outline]
    /// Where the drawing sits in the callouts' space: centred, near the top.
    let origin: CGPoint

    /// `radii`: each control's button as drawn, at its target, as a circle round it (what a line
    /// keeps clear of); `shapes`, the outline its dot sits on where that's not the same: the pills,
    /// and the sticks, whose caps sit in wider wells; `unnamed`: the other buttons drawn.
    init(size: CGSize, top: CGFloat, targets: [String: CGPoint], sides: [String: CalloutLayout.Side],
         radii: [String: CGFloat], shapes: [String: Outline] = [:], unnamed: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = []) {
        self.size = size
        self.targets = targets
        self.sides = sides
        obstacles = radii.map { Obstacle(control: $0.key, point: targets[$0.key]!, radius: $0.value) }
            + unnamed.map { Obstacle(control: nil, point: CGPoint(x: $0.x, y: $0.y), radius: $0.radius) }
        outlines = radii.mapValues { Outline.round($0) }.merging(shapes) { _, shape in shape }
        origin = CGPoint(x: (ControllerCallouts.size.width - size.width) / 2, y: top)
    }

    static func of(_ rig: ControllerRig) -> RigGeometry {
        switch rig {
        case .dualSense: dualSense
        case .xbox: xbox
        case .sensePair: sensePair
        }
    }

    private static func points(_ list: [String: (CGFloat, CGFloat)]) -> [String: CGPoint] {
        list.mapValues { CGPoint(x: $0.0, y: $0.1) }
    }

    static let dualSense = RigGeometry(
        size: CGSize(width: 320, height: 212), top: 22,
        targets: points(["leftTrigger": (58, 9), "leftShoulder": (46, 26), "rightTrigger": (262, 9), "rightShoulder": (274, 26),
                         "dpad": (62, 74), "view": (98, 36), "menu": (222, 36),
                         "y": (258, 51), "b": (281, 74), "a": (258, 97), "x": (235, 74),
                         "leftStick": (118, 118), "rightStick": (202, 118)]),
        sides: ["leftTrigger": .left, "leftShoulder": .left, "view": .left, "dpad": .left,
                "rightTrigger": .right, "rightShoulder": .right, "menu": .right, "y": .right, "b": .right, "a": .right, "x": .right,
                "leftStick": .below, "rightStick": .below],
        radii: ["y": 11.5, "b": 11.5, "a": 11.5, "x": 11.5, "dpad": 26, "leftStick": 22, "rightStick": 22, "view": 8, "menu": 8],
        shapes: ["view": .pill(width: 8, height: 16, degrees: -20), "menu": .pill(width: 8, height: 16, degrees: 20),
                 "leftStick": .round(16), "rightStick": .round(16)],
        unnamed: [(160, 110, 7.5), (160, 127.5, 7)])

    static let xbox = RigGeometry(
        size: CGSize(width: 320, height: 212), top: 22,
        targets: points(["leftTrigger": (64, 10), "leftShoulder": (50, 28), "rightTrigger": (256, 10), "rightShoulder": (270, 28),
                         "leftStick": (80, 74), "dpad": (120, 122), "view": (138, 76), "menu": (182, 76),
                         "y": (246, 52), "b": (268, 74), "a": (246, 96), "x": (224, 74), "rightStick": (200, 122)]),
        sides: ["leftTrigger": .left, "leftShoulder": .left, "leftStick": .left, "view": .left,
                "rightTrigger": .right, "rightShoulder": .right, "menu": .right, "y": .right, "b": .right, "a": .right, "x": .right,
                "dpad": .below, "rightStick": .below],
        radii: ["y": 11, "b": 11, "a": 11, "x": 11, "dpad": 21, "leftStick": 22, "rightStick": 22, "view": 6, "menu": 6],
        shapes: ["leftStick": .round(16), "rightStick": .round(16)],
        unnamed: [(160, 48, 11), (160, 93, 6)])

    // The Sense pair: the left hand in 140 x 200, drawn 1.17 times; the right hand its mirror,
    // 24 pt to its right.
    static let handScale: CGFloat = 1.17
    static let handGap: CGFloat = 24
    static let senseLeft: [String: CGPoint] = points(["leftTrigger": (88, 10), "leftShoulder": (99, 96), "leftStick": (80, 44),
                                                      "y": (109, 31), "x": (109, 57), "view": (61, 27)])
    static let senseRightOf = ["leftTrigger": "rightTrigger", "leftShoulder": "rightShoulder", "leftStick": "rightStick",
                               "y": "b", "x": "a", "view": "menu"]
    /// The left hand's buttons as drawn: the grip (an 18 x 32 pill, so its ends 16 out), the stick's
    /// well, the faces, the small button.
    static let senseRadii: [String: CGFloat] = ["leftShoulder": 16, "leftStick": 17, "y": 9.5, "x": 9.5, "view": 7]
    /// The left hand's outlines as drawn (drawHandButtons), where they're not those circles: the
    /// grip, a pill turned -4 degrees, the small button, one turned -35 (the right hand's are turned
    /// the other way), and the stick's cap.
    static let senseShapes: [String: (left: Outline, right: Outline)] = [
        "leftShoulder": (.pill(width: 18, height: 32, degrees: -4), .pill(width: 18, height: 32, degrees: 4)),
        "view": (.pill(width: 7, height: 14, degrees: -35), .pill(width: 7, height: 14, degrees: 35)),
        "leftStick": (.round(12.5), .round(12.5)),
    ]

    static let sensePair: RigGeometry = {
        var targets: [String: CGPoint] = [:], sides: [String: CalloutLayout.Side] = [:], radii: [String: CGFloat] = [:]
        for (control, point) in senseLeft {
            targets[control] = CGPoint(x: point.x * handScale, y: point.y * handScale)
            targets[senseRightOf[control]!] = CGPoint(x: (280 - point.x) * handScale + handGap, y: point.y * handScale)
            sides[control] = .left
            sides[senseRightOf[control]!] = .right
        }
        for (control, radius) in senseRadii {
            radii[control] = radius * handScale
            radii[senseRightOf[control]!] = radius * handScale
        }
        var shapes: [String: Outline] = [:]
        for (control, shape) in senseShapes {
            shapes[control] = shape.left.scaled(handScale)
            shapes[senseRightOf[control]!] = shape.right.scaled(handScale)
        }
        return RigGeometry(size: CGSize(width: 280 * handScale + handGap, height: 200 * handScale), top: 10,
                           targets: targets, sides: sides, radii: radii, shapes: shapes)
    }()
}

/// Where each callout goes, following the mock's rules: each in its side's column, stacked by its
/// label's height near its button's (see `column`), or in the row below the drawing.
struct CalloutLayout {
    enum Side { case left, right, below }

    struct Callout {
        let control: GlyphControl
        let side: Side
        let chip: CGPoint
        let target: CGPoint
        /// The line as drawn: from beside its chip to its end.
        let line: [CGPoint]
        /// Where the line visibly ends: where it leaves its button's outline, a point out (see
        /// `end(of:outline:)`), or the point itself for a trigger or bumper, which the lines are
        /// drawn over.
        let end: CGPoint
    }

    let callouts: [Callout]

    static let width = ControllerCallouts.size.width
    static let row: CGFloat = 40

    /// A control's button, in the callouts' space.
    static func target(_ control: String, rig: ControllerRig) -> CGPoint? {
        let geometry = RigGeometry.of(rig)
        return geometry.targets[control].map { CGPoint(x: geometry.origin.x + $0.x, y: geometry.origin.y + $0.y) }
    }

    /// Where each callout goes, already worked out, by rig and the controls shown: the search below
    /// runs once for each. Only the geometry: the controls themselves (their symbols, which change
    /// as controllers connect) are always the current ones.
    private struct Placement { let control: String; let side: Side; let chip: CGPoint; let target: CGPoint; let line: [CGPoint]; let end: CGPoint }
    private static var cache: [String: [Placement]] = [:]

    /// `heights`: each control's label block, measured (CalloutLabel.height).
    init(rig: ControllerRig, controls: [GlyphControl], heights: [String: CGFloat]) {
        let key = "\(rig)|" + controls.map { "\($0.control):\(Int(((heights[$0.control] ?? 0) * 2).rounded()))" }.joined(separator: ",")
        let current = Dictionary(controls.map { ($0.control, $0) }, uniquingKeysWith: { first, _ in first })
        let placements = Self.cache[key] ?? {
            let worked = Self.place(rig: rig, controls: controls, heights: heights)
            Self.cache[key] = worked
            return worked
        }()
        callouts = placements.compactMap { placement in
            current[placement.control].map {
                Callout(control: $0, side: placement.side, chip: placement.chip, target: placement.target, line: placement.line, end: placement.end)
            }
        }
    }

    private static func place(rig: ControllerRig, controls: [GlyphControl], heights: [String: CGFloat]) -> [Placement] {
        let geometry = RigGeometry.of(rig)
        let placed = controls.compactMap { control in Self.target(control.control, rig: rig).map { (control, $0) } }
        func side(_ control: String) -> Side { geometry.sides[control] ?? .right }
        let bottom = geometry.origin.y + geometry.size.height
        // Every button on the drawing, used or not: a line shouldn't cross another.
        let obstacles = geometry.obstacles.map {
            RigGeometry.Obstacle(control: $0.control, point: CGPoint(x: geometry.origin.x + $0.point.x, y: geometry.origin.y + $0.point.y),
                                 radius: $0.radius)
        }

        var callouts: [Callout] = []
        for (list, isRight) in [(placed.filter { side($0.0.control) == .left }, false), (placed.filter { side($0.0.control) == .right }, true)] {
            callouts += Self.column(list, right: isRight, obstacles: obstacles, outlines: geometry.outlines, heights: heights)
        }
        // The row below the drawing: each out from its control, so two never meet; each from a dot
        // on its stick's edge (or the d-pad's), straight below it.
        for (control, target) in placed where side(control.control) == .below {
            let chip = CGPoint(x: target.x + (target.x < Self.width / 2 ? -50 : 50), y: bottom + 26)
            let end = CGPoint(x: target.x, y: target.y + (geometry.outlines[control.control]?.radius ?? 0) + 1)
            callouts.append(Callout(control: control, side: .below, chip: chip, target: target,
                                    line: [end, CGPoint(x: target.x, y: bottom - 30), CGPoint(x: chip.x, y: chip.y - 14)],
                                    end: end))
        }
        return callouts.map {
            Placement(control: $0.control.control, side: $0.side, chip: $0.chip, target: $0.target, line: $0.line, end: $0.end)
        }
    }

    /// How far a column's stack may move off centre on its buttons, in the order tried: a line that
    /// would cross another button can often clear it with the stack a little higher or lower.
    static let shifts: [CGFloat] = [0, -10, 10, -20, 20, -30, 30, -40, 40, -60, 60]

    /// The angles a line's last leg may come into its button at, in degrees from level: 10 to 90 in
    /// fives, tried nearest 45 first (the lower first on a tie, as the mock tries them).
    static let angles: [CGFloat] = stride(from: 10, through: 90, by: 5).map { CGFloat($0) }
        .sorted { (abs($0 - 45), $0) < (abs($1 - 45), $1) }

    /// A side column: the callouts as a stack centred on their buttons' heights (or shifted, see
    /// `shifts`), each next one far enough below the last for both labels and 8 pt between (a row at
    /// least). Each line runs level from its chip to a knee, then straight into its button at an
    /// angle of its own (see `angles`), so a button can be reached from above or below, round its
    /// neighbours. The lines are placed top to bottom, each at the angle costing least: crossing a
    /// line above it, then crossing another button (within its radius and 3 pt) on either leg,
    /// then coming in away from 45 degrees, and climbing. Of every shift and every order of the
    /// callouts (up to 8; more are taken top to bottom), the one costing least in all, its shift
    /// counted too.
    private static func column(_ list: [(GlyphControl, CGPoint)], right: Bool,
                               obstacles: [RigGeometry.Obstacle], outlines: [String: RigGeometry.Outline],
                               heights: [String: CGFloat]) -> [Callout] {
        guard !list.isEmpty else { return [] }
        let height = ControllerCallouts.size.height
        let chipX = right ? width - 112 : 112, inner = right ? chipX - 14 : chipX + 14
        // A knee past this would run into the chip.
        let limit = right ? inner - 8 : inner + 8
        let n = list.count
        let targets = list.map(\.1)
        let mean = targets.map(\.y).reduce(0, +) / CGFloat(n)
        let blocks = list.map { heights[$0.0.control] ?? row }
        let others = list.map { item in obstacles.filter { $0.control != item.0.control } }

        /// A way into a button from a chip's height, and what it costs but for crossings.
        struct Leg { let line: [CGPoint]; let grazes: Int; let turn: Double; let climb: Double; let cost: Double }
        struct Start: Hashable { let item: Int; let y: CGFloat }
        var cached: [Start: [Leg]] = [:]
        /// Every way into an item's button from a height, cheapest first (in `angles` order on a
        /// tie). The same heights come up again and again across orders, so each is worked out once.
        func legs(_ item: Int, _ y: CGFloat) -> [Leg] {
            if let legs = cached[Start(item: item, y: y)] { return legs }
            let target = targets[item], rise = abs(y - target.y), start = CGPoint(x: inner, y: y)
            var found: [(leg: Leg, rank: Int)] = []
            for (rank, angle) in angles.enumerated() {
                let knee: CGPoint
                if rise < 1 {
                    // Level, straight in: the same line at every angle, cheapest at 45.
                    guard rank == 0 else { break }
                    knee = target
                } else {
                    let run = angle == 90 ? 0 : rise / tan(angle * .pi / 180)
                    let x = right ? target.x + run : target.x - run
                    if right ? x > limit : x < limit { continue }
                    knee = CGPoint(x: x, y: y)
                }
                let (left, rightmost) = (min(inner, knee.x, target.x), max(inner, knee.x, target.x))
                let (low, high) = (min(y, target.y), max(y, target.y))
                var grazes = 0
                for obstacle in others[item] {
                    let p = obstacle.point, reach = obstacle.radius + 3
                    // Too far from the line's box to come within reach of it.
                    if p.y + reach < low || p.y - reach > high || p.x + reach < left || p.x - reach > rightmost { continue }
                    if min(distance(p, start, knee), distance(p, knee, target)) < reach { grazes += 1 }
                }
                let turn = Double(abs(angle - 45)) * 0.6, climb = Double(rise) * 0.2
                found.append((Leg(line: [start, knee, target], grazes: grazes, turn: turn, climb: climb,
                                  cost: Double(grazes) * 1e3 + turn + climb), rank))
            }
            let legs = found.sorted { ($0.leg.cost, $0.rank) < ($1.leg.cost, $1.rank) }.map(\.leg)
            cached[Start(item: item, y: y)] = legs
            return legs
        }

        // The search is the mock's, made quick enough for a Debug build (up to 11 x 5040 orders a
        // column), and picks what it picks. A shift that leaves the stack where a smaller one did is
        // skipped (the same lines, for more shift). An order stops being scored once it costs as
        // much as the best so far (every line only adds), and so does each later one that starts
        // the same way at the same heights. And an order takes over the lines already placed for
        // the last one, as far as they start the same way at the same heights.
        let orders = n > 8 ? [list.indices.sorted { targets[$0].y < targets[$1].y }] : permutations(Array(list.indices))
        // Each order's callouts below its first: each next far enough below the last for both labels
        // and 8 pt between.
        let offsets = orders.map { order in
            order.indices.reduce(into: [CGFloat]()) { offsets, i in
                offsets.append(i == 0 ? 0 : offsets[i - 1] + max(row, (blocks[order[i - 1]] + blocks[order[i]]) / 2 + 8))
            }
        }
        /// The stack's top: centred on its buttons, shifted, kept on the page.
        func stackTop(_ stack: CGFloat, _ shift: CGFloat) -> CGFloat { max(18, min(mean - stack / 2 + shift, height - 24 - stack)) }
        var best: (cost: Double, order: [Int], top: CGFloat, offset: [CGFloat], lines: [[CGPoint]])?
        var placed: [[CGPoint]] = [], costs: [Double] = []
        var last: (order: [Int], top: CGFloat, shift: CGFloat)?
        var dead: (start: ArraySlice<Int>, top: CGFloat, shift: CGFloat)?
        for shift in shifts {
            // The shift before this one on its side (or none): if the stack sits the same with that,
            // it met an edge, and this one gives the same lines for more shift.
            let previous = shifts.filter { $0 * shift > 0 && abs($0) < abs(shift) }.max { abs($0) < abs($1) } ?? 0
            for (k, order) in orders.enumerated() {
                let offset = offsets[k], stack = offset[n - 1]
                let top = stackTop(stack, shift)
                if shift != 0 && top == stackTop(stack, previous) { continue }
                if let dead, dead.top == top, dead.shift == shift, order.starts(with: dead.start) { continue }
                var depth = 0
                if let last, last.top == top, last.shift == shift {
                    while depth < placed.count && last.order[depth] == order[depth] { depth += 1 }
                }
                placed.removeLast(placed.count - depth)
                costs.removeLast(costs.count - depth)
                last = (order, top, shift)
                var cost = depth == 0 ? Double(abs(shift)) * 2 : costs[depth - 1]
                var finished = true
                for i in depth..<n {
                    if let best, cost >= best.cost {
                        dead = (order[..<i], top, shift)
                        finished = false
                        break
                    }
                    // The cheapest way in that crosses no line above it; failing that, the cheapest
                    // with crossings counted.
                    var pick: (local: Double, line: [CGPoint])?
                    for leg in legs(order[i], top + offset[i]) {
                        var crossings = 0
                        for line in placed { crossings += Self.crossings(leg.line, line) }
                        let local = Double(crossings) * 1e6 + Double(leg.grazes) * 1e3 + leg.turn + leg.climb
                        if pick == nil || local < pick!.local { pick = (local, leg.line) }
                        if crossings == 0 { break }
                    }
                    guard let pick else {
                        // No way in from here that misses the chip: no order starting so can finish.
                        dead = (order[...i], top, shift)
                        finished = false
                        break
                    }
                    cost += pick.local
                    placed.append(pick.line)
                    costs.append(cost)
                }
                if finished, best == nil || cost < best!.cost { best = (cost, order, top, offset, placed) }
            }
        }
        // (Every order finishes with a way in at 90 degrees, so there's always a best.)
        guard let best else { return [] }
        return best.order.indices.map { i in
            let item = best.order[i], line = best.lines[i], target = targets[item]
            let (end, drawn) = Self.end(of: line, outline: outlines[list[item].0.control])
            return Callout(control: list[item].0, side: right ? .right : .left, chip: CGPoint(x: chipX, y: best.top + best.offset[i]),
                           target: target, line: drawn, end: end)
        }
    }

    /// Where a line visibly ends, and the line as drawn, from its chip to there: where it leaves
    /// its button's outline grown by a point, followed back from the button. On the last leg; on the
    /// level one if the last is shorter than that (or there is none, straight in); at the point
    /// itself for a trigger or bumper, which it's drawn over.
    private static func end(of line: [CGPoint], outline: RigGeometry.Outline?) -> (CGPoint, [CGPoint]) {
        let target = line[2]
        guard let outline else { return (target, line) }
        let reach = CGVector(dx: outline.axis.dx * outline.length, dy: outline.axis.dy * outline.length)
        let (a, b) = (CGPoint(x: target.x - reach.dx, y: target.y - reach.dy), CGPoint(x: target.x + reach.dx, y: target.y + reach.dy))
        func outside(_ p: CGPoint) -> Bool { distance(p, a, b) > outline.radius + 1 }
        var from = target
        for to in [line[1], line[0]] where to != from {
            if outside(to) {
                // Inside at `from`, outside at `to`, and the outline is convex: one crossing.
                func at(_ t: CGFloat) -> CGPoint { CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t) }
                var (inner, outer): (CGFloat, CGFloat) = (0, 1)
                for _ in 0..<40 {
                    let middle = (inner + outer) / 2
                    if outside(at(middle)) { outer = middle } else { inner = middle }
                }
                let end = at(outer)
                return (end, to == line[1] ? [line[0], line[1], end] : [line[0], end])
            }
            from = to
        }
        return (line[0], [line[0], line[0]])
    }

    /// How many times two lines' legs cross.
    private static func crossings(_ a: [CGPoint], _ b: [CGPoint]) -> Int {
        var count = 0
        for s1 in 0..<2 { for s2 in 0..<2 where crosses(a[s1], a[s1 + 1], b[s2], b[s2 + 1]) { count += 1 } }
        return count
    }

    /// Every order of the items, in the order the mock tries them.
    private static func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[Int]] in
            var rest = items
            let first = rest.remove(at: i)
            return permutations(rest).map { [first] + $0 }
        }
    }

    /// Whether two segments cross each other properly (not merely touch).
    private static func crosses(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func turn(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            let value = (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            return value > 0 ? 1 : value < 0 ? -1 : 0
        }
        return turn(a, b, c) * turn(a, b, d) < 0 && turn(c, d, a) * turn(c, d, b) < 0
    }

    /// How far a point is from a segment.
    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y)
    }
}

extension CalloutLabel {
    /// How tall a callout's words are at a text size: each action, wrapped in its 92 pt column, then
    /// the control's name; measured with the fonts the label draws in.
    static func height(of control: GlyphControl, size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: size.contentSizeCategory)
        func font(_ points: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle) -> UIFont {
            let descriptor = UIFontDescriptor(fontAttributes: [.family: "Roboto", .traits: [UIFontDescriptor.TraitKey.weight: weight]])
            return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: points), compatibleWith: traits)
        }
        func measure(_ text: String, _ font: UIFont) -> CGFloat {
            ceil((text as NSString).boundingRect(with: CGSize(width: 92, height: CGFloat.greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                 attributes: [.font: font], context: nil).height)
        }
        let action = font(12, .bold, .caption1), name = font(10.5, .regular, .caption2)
        return control.actions.map { measure($0, action) }.reduce(0, +) + measure(control.name, name)
    }
}

extension DynamicTypeSize {
    /// The UIKit size category for measuring text at this size.
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

/// A callout's chip and words: beside the chip in a side column (each action on its own line,
/// then the control's name), or under it below the drawing.
struct CalloutLabel: View {
    let callout: CalloutLayout.Callout

    var body: some View {
        let control = callout.control
        let words = VStack(alignment: callout.side == .left ? .trailing : callout.side == .right ? .leading : .center, spacing: 0) {
            ForEach(control.actions, id: \.self) { action in
                Text(action).font(.tbBody(12, weight: .bold, relativeTo: .caption))
            }
            Text(control.name)
                .font(.tbBody(10.5, relativeTo: .caption2))
                .foregroundStyle(.white.opacity(0.72))
        }
        .multilineTextAlignment(callout.side == .left ? .trailing : callout.side == .right ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)

        ZStack(alignment: .topLeading) {
            GlyphTile(symbol: control.symbol, size: 26)
                .position(callout.chip)
            switch callout.side {
            case .left:
                words.frame(width: 92, alignment: .trailing).position(x: 96 - 46, y: callout.chip.y)
            case .right:
                words.frame(width: 92, alignment: .leading).position(x: CalloutLayout.width - 96 + 46, y: callout.chip.y)
            case .below:
                words.frame(width: 140).position(x: callout.chip.x, y: callout.chip.y + 34)
            }
        }
        .frame(width: CalloutLayout.width, height: ControllerCallouts.size.height, alignment: .topLeading)
        // VoiceOver finds the chip and its words, not the whole area.
        .contentShape(.accessibility, CalloutShape(callout: callout))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(control.name): \(control.actions.joined(separator: ", "))")
    }
}

/// The area a callout's chip and words take.
struct CalloutShape: Shape {
    let callout: CalloutLayout.Callout

    func path(in rect: CGRect) -> Path {
        let chip = callout.chip
        let area: CGRect = switch callout.side {
        case .left: CGRect(x: 4, y: chip.y - 20, width: chip.x + 14 - 4, height: 40)
        case .right: CGRect(x: chip.x - 14, y: chip.y - 20, width: CalloutLayout.width - 4 - (chip.x - 14), height: 40)
        case .below: CGRect(x: chip.x - 70, y: chip.y - 14, width: 140, height: 78)
        }
        return Path(roundedRect: area, cornerRadius: 10)
    }
}

/// A leader line through its points.
struct LeaderLine: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }
}

/// The drawing itself: our own illustrations of a DualSense-style pad, an Xbox-style pad or a pair
/// of Sense-style hand controllers (the launcher mock's art2.js). Solid and layered, as built:
/// triggers behind the body, the body, bumpers set into its top edge with a seam, recesses, then
/// buttons; opaque, so what's in front hides what's behind. Controls that do something wear an
/// orange ring over a soft glow; face buttons carry the controller's own symbol.
struct ControllerDrawing: View {
    /// The drawing comes in two layers, drawn one over the other: the body (shell, triggers,
    /// bumpers, recesses) and the buttons on it.
    enum Layer { case body, buttons }

    let rig: ControllerRig
    let layer: Layer
    let used: Set<String>
    let symbols: [String: String]

    // The DualSense-style pad, 320 x 212.
    static let dualSenseBody = Path(svg: "M160 26 L214 26 C236 26 250 21 268 23 C290 25 304 40 309 60 C314 84 317 108 316 130 C315 158 307 182 295 197 C285 209 262 211 251 199 C243 189 235 171 224 159 C208 145 190 141 160 141 C130 141 112 145 96 159 C85 171 77 189 69 199 C58 211 35 209 25 197 C13 182 5 158 4 130 C3 108 6 84 11 60 C16 40 30 25 52 23 C70 21 84 26 106 26 Z")
    /// The dark centre: the touchpad down round both sticks to the body's lower edge.
    static let dualSensePlate = Path(svg: "M104 26 L216 26 C214 52 212 76 210 92 C226 96 238 110 238 126 C238 136 233 144 226 150 C208 143 190 141 160 141 C130 141 112 143 94 150 C87 144 82 136 82 126 C82 110 94 96 110 92 C108 76 106 52 104 26 Z")
    static let dualSensePad = Path(svg: "M110 28 L210 28 C212 28 213 30 213 32 L208 82 C207 88 203 91 198 91 L122 91 C117 91 113 88 112 82 L107 32 C107 30 108 28 110 28 Z")
    /// L1 as drawn runs outside the body; it's clipped to it, so the body's edge bounds it and its
    /// lower edge is the seam.
    static let dualSenseBumper = Path(svg: "M4 64 L4 4 L98 4 L98 33 C86 30.5 72 29.5 58 30.5 C42 32 30 40 24 56 Z")
    static let dualSenseTrigger = Path(svg: "M24 34 C24 16 40 5 60 5 C78 5 92 13 94 28 L94 40 L24 40 Z")
    // The Xbox-style pad, 320 x 212.
    static let xboxBody = Path(svg: "M160 30 C196 30 224 22 252 24 C284 26 304 44 310 70 C316 96 316 122 312 142 C306 170 296 192 282 202 C268 212 248 208 240 194 C232 180 222 164 206 156 C190 150 176 150 160 150 C144 150 130 150 114 156 C98 164 88 180 80 194 C72 208 52 212 38 202 C24 192 14 170 8 142 C4 122 4 96 10 70 C16 44 36 26 68 24 C96 22 124 30 160 30 Z")
    static let xboxBumper = Path(svg: "M2 72 L2 4 L108 4 L108 37 C94 34 80 33 64 34 C44 36 28 47 22 66 Z")
    static let xboxTrigger = Path(svg: "M30 36 C30 18 46 6 66 6 C84 6 98 14 100 30 L100 42 L30 42 Z")

    /// A pad's right-hand parts: its left ones mirrored, x to 320 - x (as art2.js's mirrorD).
    static func mirrored(_ path: Path) -> Path {
        path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 320, ty: 0))
    }

    var body: some View {
        let geometry = RigGeometry.of(rig)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                var art = context
                art.translateBy(x: geometry.origin.x, y: geometry.origin.y)
                switch (rig, layer) {
                case (.dualSense, .body): drawDualSenseBody(&art)
                case (.dualSense, .buttons): drawDualSenseButtons(&art)
                case (.xbox, .body): drawXboxBody(&art)
                case (.xbox, .buttons): drawXboxButtons(&art)
                case (.sensePair, _):
                    var left = art
                    left.scaleBy(x: RigGeometry.handScale, y: RigGeometry.handScale)
                    drawHand(&left, mirror: false)
                    var right = art
                    right.translateBy(x: 140 * RigGeometry.handScale + RigGeometry.handGap, y: 0)
                    right.scaleBy(x: RigGeometry.handScale, y: RigGeometry.handScale)
                    drawHand(&right, mirror: true)
                }
            }
            // The face buttons' own symbols, on the drawing's buttons (never mirrored).
            ForEach(["y", "x", "b", "a"], id: \.self) { control in
                if layer == .buttons, let symbol = symbols[control], let point = CalloutLayout.target(control, rig: rig) {
                    Self.mark(symbol)
                        .font(.system(size: rig == .sensePair ? 10 * RigGeometry.handScale : 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(used.contains(control) ? 1 : 0.55)
                        .position(point)
                }
            }
        }
        .frame(width: ControllerCallouts.size.width, height: ControllerCallouts.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A face button's mark: its symbol without the circle round it (the button is the circle):
    /// "triangle.circle" as a triangle, "a.circle" as the letter A.
    @ViewBuilder static func mark(_ symbol: String) -> some View {
        let base = symbol.hasSuffix(".circle.fill") ? String(symbol.dropLast(12)) : symbol.hasSuffix(".circle") ? String(symbol.dropLast(7)) : symbol
        if base.count == 1, let letter = base.first, letter.isLetter {
            Text(String(letter).uppercased())
        } else if base != symbol, UIImage(systemName: base) != nil {
            Image(systemName: base)
        } else {
            Image(systemName: symbol)
        }
    }

    // The paints (art2.js).
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    private static let shellColours = [rgb(0x46524B), rgb(0x252D29)], plateColours = [rgb(0x1E2723), rgb(0x151C18)]
    private static let partColours = [rgb(0x56635B), rgb(0x36403B)], buttonColours = [rgb(0x3E4943), rgb(0x232A26)]
    private static let capColours = [rgb(0x47534C), rgb(0x1F2622)]
    private static let recess = rgb(0x111814), seam = rgb(0x0B100D), contact = rgb(0x0A0E0C), touchpad = rgb(0x28322D)
    private static let shellEdge = Color.white.opacity(0.16), shadowEdge = Color.black.opacity(0.55)
    private static let buttonEdge = Color.white.opacity(0.22)

    /// A top-to-bottom gradient over a shape's bounds (SVG's default object bounding box).
    private func vertical(_ colours: [Color], _ path: Path) -> GraphicsContext.Shading {
        let box = path.boundingRect
        return .linearGradient(Gradient(colors: colours), startPoint: CGPoint(x: box.midX, y: box.minY), endPoint: CGPoint(x: box.midX, y: box.maxY))
    }

    /// Fills a shape with a radial gradient as SVG's object bounding box draws one: an ellipse over
    /// the shape's own box (before it's turned), centred (0.5, `cy`) with radii `r` of its width
    /// and height, turned with the shape.
    private func fillRadial(_ context: inout GraphicsContext, _ shape: Path, box: CGRect, turn: (degrees: CGFloat, pivot: CGPoint)? = nil,
                            colours: [Color], cy: CGFloat, r: CGFloat) {
        context.drawLayer { layer in
            layer.clip(to: shape)
            if let turn {
                layer.translateBy(x: turn.pivot.x, y: turn.pivot.y)
                layer.rotate(by: .degrees(turn.degrees))
                layer.translateBy(x: -turn.pivot.x, y: -turn.pivot.y)
            }
            layer.translateBy(x: box.minX, y: box.minY)
            layer.scaleBy(x: box.width, y: box.height)
            layer.fill(Path(CGRect(x: -1, y: -1, width: 3, height: 3)),
                       with: .radialGradient(Gradient(colors: colours), center: CGPoint(x: 0.5, y: cy), startRadius: 0, endRadius: r))
        }
    }

    /// The button paint over a shape.
    private func fillButton(_ context: inout GraphicsContext, _ shape: Path, box: CGRect? = nil, turn: (degrees: CGFloat, pivot: CGPoint)? = nil) {
        fillRadial(&context, shape, box: box ?? shape.boundingRect, turn: turn, colours: Self.buttonColours, cy: 0.3, r: 0.75)
    }

    /// A used control's ring: a soft orange glow under a crisp orange line.
    private func ring(_ context: inout GraphicsContext, _ name: String, _ path: Path) {
        guard used.contains(name) else { return }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 2.2))
            glow.opacity = 0.55
            glow.stroke(path, with: .color(Trevorbilt.orange), lineWidth: 4)
        }
        context.stroke(path, with: .color(Trevorbilt.orange), lineWidth: 1.8)
    }

    /// A moving part (a trigger, a bumper, a grip): the part paint with a seam, and its ring. (A
    /// turned part's paint follows its bounds as drawn, as SVG's does for the mock's turned grip.)
    private func part(_ context: inout GraphicsContext, _ name: String, _ path: Path) {
        context.fill(path, with: vertical(Self.partColours, path))
        context.stroke(path, with: .color(Self.seam), lineWidth: 1.5)
        ring(&context, name, path)
    }

    /// The shell: its paint with a drop shadow and a dark outer edge, and a light inner one.
    private func shell(_ context: inout GraphicsContext, _ path: Path) {
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 7, x: 0, y: 6))
            layer.fill(path, with: vertical(Self.shellColours, path))
            layer.stroke(path, with: .color(Self.shadowEdge), lineWidth: 1.5)
        }
        context.stroke(path, with: .color(Self.shellEdge), lineWidth: 1)
    }

    private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// A rounded rectangle with circular corners, as SVG's rx.
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .circular)
    }

    /// A shape turned by `degrees` about a point.
    private func turned(_ path: Path, _ degrees: CGFloat, about x: CGFloat, _ y: CGFloat) -> Path {
        path.applying(CGAffineTransform(translationX: x, y: y).rotated(by: degrees * .pi / 180).translatedBy(x: -x, y: -y))
    }

    /// A recess: a dark well with a seam.
    private func recess(_ context: inout GraphicsContext, _ path: Path, line: CGFloat = 1.2) {
        context.fill(path, with: .color(Self.recess))
        context.stroke(path, with: .color(Self.seam), lineWidth: line)
    }

    /// A button: its shadow on the surface, the button, and its ring.
    private func faceButton(_ context: inout GraphicsContext, _ name: String, _ point: CGPoint, _ r: CGFloat) {
        context.fill(circle(point.x, point.y + 1.2, r), with: .color(Self.contact))
        let shape = circle(point.x, point.y, r)
        fillButton(&context, shape)
        context.stroke(shape, with: .color(Self.buttonEdge), lineWidth: 1)
        ring(&context, name, shape)
    }

    /// A small button (Create, Options, View, Menu, PS, guide): button paint, light edge, its ring.
    /// A pill is given unturned, with how it turns, so its shading turns with it.
    private func smallButton(_ context: inout GraphicsContext, _ name: String?, _ shape: Path,
                             turn: (degrees: CGFloat, pivot: CGPoint)? = nil, line: CGFloat = 1) {
        let turned = turn.map { self.turned(shape, $0.degrees, about: $0.pivot.x, $0.pivot.y) } ?? shape
        fillButton(&context, turned, box: shape.boundingRect, turn: turn)
        context.stroke(turned, with: .color(Self.buttonEdge), lineWidth: line)
        if let name { ring(&context, name, turned) }
    }

    private func stick(_ context: inout GraphicsContext, _ name: String, _ point: CGPoint, well: CGFloat = 22, cap: CGFloat = 16) {
        recess(&context, circle(point.x, point.y, well), line: 1.5)
        context.fill(circle(point.x, point.y + 1.5, cap), with: .color(Self.contact))
        let top = circle(point.x, point.y, cap)
        fillRadial(&context, top, box: top.boundingRect, colours: Self.capColours, cy: 0.35, r: 0.7)
        context.stroke(top, with: .color(Self.buttonEdge), lineWidth: 1)
        context.stroke(circle(point.x, point.y, cap * 0.66), with: .color(.white.opacity(0.1)), lineWidth: 2)
        ring(&context, name, top)
    }

    /// The bumpers, set into the body's top corners: each drawn whole (paint, seam, ring) inside
    /// the body's outline, so the body's edge bounds it and its lower edge is the seam.
    private func bumpers(_ context: inout GraphicsContext, _ left: Path, body: Path) {
        context.drawLayer { layer in
            layer.clip(to: body)
            part(&layer, "leftShoulder", left)
            part(&layer, "rightShoulder", Self.mirrored(left))
        }
    }

    /// The DualSense-style body: triggers, shell, bumpers, plate, touchpad, light bars, recesses.
    private func drawDualSenseBody(_ context: inout GraphicsContext) {
        let targets = RigGeometry.dualSense.targets
        part(&context, "leftTrigger", Self.dualSenseTrigger)
        part(&context, "rightTrigger", Self.mirrored(Self.dualSenseTrigger))
        shell(&context, Self.dualSenseBody)
        bumpers(&context, Self.dualSenseBumper, body: Self.dualSenseBody)
        let plate = Self.dualSensePlate.intersection(Self.dualSenseBody)
        context.fill(plate, with: vertical(Self.plateColours, plate))
        context.stroke(plate, with: .color(Self.seam), lineWidth: 1.2)
        context.fill(Self.dualSensePad, with: .color(Self.touchpad))
        context.stroke(Self.dualSensePad, with: .color(Self.seam), lineWidth: 1.2)
        context.stroke(Path(svg: "M112 30 L208 30"), with: .color(.white.opacity(0.12)), lineWidth: 1)
        // The light bar, either side of the touchpad.
        for bar in ["M103 34 C105 58 107 78 111 92", "M217 34 C215 58 213 78 209 92"] {
            let path = Path(svg: bar), box = path.boundingRect
            context.stroke(path, with: .linearGradient(Gradient(colors: [Trevorbilt.orange.opacity(0.9), Trevorbilt.orange.opacity(0.25)]),
                                                       startPoint: CGPoint(x: box.midX, y: box.minY), endPoint: CGPoint(x: box.midX, y: box.maxY)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        let dpad = targets["dpad"]!
        recess(&context, circle(dpad.x, dpad.y, 34))
        recess(&context, circle(258, 74, 37))
    }

    /// The DualSense-style buttons: the d-pad's arms onward.
    private func drawDualSenseButtons(_ context: inout GraphicsContext) {
        let targets = RigGeometry.dualSense.targets
        let dpad = targets["dpad"]!
        // The d-pad: four arms.
        let (dx, dy) = (dpad.x, dpad.y)
        let arms = [
            "M\(dx-7) \(dy-23) Q\(dx-7) \(dy-26) \(dx-4) \(dy-26) H\(dx+4) Q\(dx+7) \(dy-26) \(dx+7) \(dy-23) V\(dy-12) L\(dx) \(dy-5) L\(dx-7) \(dy-12) Z",
            "M\(dx-7) \(dy+23) Q\(dx-7) \(dy+26) \(dx-4) \(dy+26) H\(dx+4) Q\(dx+7) \(dy+26) \(dx+7) \(dy+23) V\(dy+12) L\(dx) \(dy+5) L\(dx-7) \(dy+12) Z",
            "M\(dx-23) \(dy-7) Q\(dx-26) \(dy-7) \(dx-26) \(dy-4) V\(dy+4) Q\(dx-26) \(dy+7) \(dx-23) \(dy+7) H\(dx-12) L\(dx-5) \(dy) L\(dx-12) \(dy-7) Z",
            "M\(dx+23) \(dy-7) Q\(dx+26) \(dy-7) \(dx+26) \(dy-4) V\(dy+4) Q\(dx+26) \(dy+7) \(dx+23) \(dy+7) H\(dx+12) L\(dx+5) \(dy) L\(dx+12) \(dy-7) Z",
        ].map { Path(svg: $0) }
        var allArms = Path()
        for arm in arms {
            fillButton(&context, arm)
            context.stroke(arm, with: .color(Self.buttonEdge), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            allArms.addPath(arm)
        }
        ring(&context, "dpad", allArms)
        for face in ["y", "b", "a", "x"] { faceButton(&context, face, targets[face]!, 11.5) }
        for (name, degrees) in [("view", -20.0), ("menu", 20.0)] {
            let point = targets[name]!
            smallButton(&context, name, rect(point.x - 4, point.y - 8, 8, 16, 4), turn: (degrees, point))
        }
        stick(&context, "leftStick", targets["leftStick"]!)
        stick(&context, "rightStick", targets["rightStick"]!)
        // The PS button (no logo) and the mute button.
        smallButton(&context, nil, circle(160, 110, 7.5))
        smallButton(&context, nil, rect(153, 125, 14, 5, 2.5), line: 0.8)
    }

    /// The Xbox-style body: triggers, shell, bumpers, the d-pad's recess.
    private func drawXboxBody(_ context: inout GraphicsContext) {
        let dpad = RigGeometry.xbox.targets["dpad"]!
        part(&context, "leftTrigger", Self.xboxTrigger)
        part(&context, "rightTrigger", Self.mirrored(Self.xboxTrigger))
        shell(&context, Self.xboxBody)
        bumpers(&context, Self.xboxBumper, body: Self.xboxBody)
        recess(&context, circle(dpad.x, dpad.y, 25))
    }

    /// The Xbox-style buttons: the sticks onward.
    private func drawXboxButtons(_ context: inout GraphicsContext) {
        let targets = RigGeometry.xbox.targets
        stick(&context, "leftStick", targets["leftStick"]!)
        stick(&context, "rightStick", targets["rightStick"]!)
        let dpad = targets["dpad"]!
        let (px, py) = (dpad.x, dpad.y)
        let plus = Path(svg: "M\(px-6) \(py-19) Q\(px-6) \(py-21) \(px-4) \(py-21) H\(px+4) Q\(px+6) \(py-21) \(px+6) \(py-19) V\(py-6) H\(px+19) Q\(px+21) \(py-6) \(px+21) \(py-4) V\(py+4) Q\(px+21) \(py+6) \(px+19) \(py+6) H\(px+6) V\(py+19) Q\(px+6) \(py+21) \(px+4) \(py+21) H\(px-4) Q\(px-6) \(py+21) \(px-6) \(py+19) V\(py+6) H\(px-19) Q\(px-21) \(py+6) \(px-21) \(py+4) V\(py-4) Q\(px-21) \(py-6) \(px-19) \(py-6) H\(px-6) Z")
        fillButton(&context, plus)
        context.stroke(plus, with: .color(Self.buttonEdge), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        ring(&context, "dpad", plus)
        for face in ["y", "b", "a", "x"] { faceButton(&context, face, targets[face]!, 11) }
        // The guide button (no logo), View and Menu, and the share button.
        smallButton(&context, nil, circle(160, 48, 11))
        for name in ["view", "menu"] {
            let point = targets[name]!
            smallButton(&context, name, circle(point.x, point.y, 6))
        }
        smallButton(&context, nil, rect(154, 90, 12, 6, 3), line: 0.8)
    }

    /// One Sense-style hand controller: the left, or the right drawn from mirrored coordinates
    /// (never a mirroring transform, which would flip the symbols).
    private func drawHand(_ context: inout GraphicsContext, mirror: Bool) {
        func mx(_ x: CGFloat) -> CGFloat { mirror ? 140 - x : x }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: mx(x), y: y) }
        func name(_ control: String) -> String { mirror ? RigGeometry.senseRightOf[control]! : control }
        func place(_ control: String) -> CGPoint { let point = RigGeometry.senseLeft[control]!; return p(point.x, point.y) }
        let turn: CGFloat = mirror ? 4 : -4

        guard layer == .body else {
            drawHandButtons(&context, mirror: mirror)
            return
        }
        var trigger = Path()
        trigger.move(to: p(70, 30))
        trigger.addCurve(to: p(90, 4), control1: p(70, 14), control2: p(78, 4))
        trigger.addCurve(to: p(108, 30), control1: p(102, 4), control2: p(108, 14))
        trigger.closeSubpath()
        part(&context, name("leftTrigger"), trigger)
        // The ring round the outside of the hand, down to the handle's foot.
        var centre = Path()
        centre.move(to: p(70, 46))
        centre.addCurve(to: p(20, 144), control1: p(24, 52), control2: p(4, 106))
        centre.addCurve(to: p(96, 166), control1: p(36, 178), control2: p(78, 194))
        shell(&context, centre.strokedPath(StrokeStyle(lineWidth: 15, lineCap: .round)))
        let handle = turned(rect(mirror ? 140 - 115 : 83, 56, 32, 126, 16), turn, about: mx(99), 118)
        context.fill(handle, with: vertical(Self.plateColours, handle))
        context.stroke(handle, with: .color(Self.seam), lineWidth: 1.5)
        let headX: CGFloat = mirror ? 140 - 123 : 53
        let head = rect(headX, 17, 70, 56, 27)
        context.fill(head, with: vertical(Self.shellColours, head))
        context.stroke(head, with: .color(Self.shadowEdge), lineWidth: 1.5)
        let face = rect(headX + 6, 23, 58, 44, 21)
        context.fill(face, with: vertical(Self.plateColours, face))
        context.stroke(face, with: .color(Self.seam), lineWidth: 1.5)
    }

    /// One hand controller's buttons: the grip onward.
    private func drawHandButtons(_ context: inout GraphicsContext, mirror: Bool) {
        func mx(_ x: CGFloat) -> CGFloat { mirror ? 140 - x : x }
        func name(_ control: String) -> String { mirror ? RigGeometry.senseRightOf[control]! : control }
        func place(_ control: String) -> CGPoint { let point = RigGeometry.senseLeft[control]!; return CGPoint(x: mx(point.x), y: point.y) }
        let turn: CGFloat = mirror ? 4 : -4
        let grip = place("leftShoulder")
        part(&context, name("leftShoulder"), turned(rect(grip.x - 9, grip.y - 16, 18, 32, 9), turn, about: grip.x, grip.y))
        stick(&context, name("leftStick"), place("leftStick"), well: 17, cap: 12.5)
        faceButton(&context, name("y"), place("y"), 9.5)
        faceButton(&context, name("x"), place("x"), 9.5)
        let small = place("view")
        smallButton(&context, name("view"), rect(small.x - 3.5, small.y - 7, 7, 14, 3.5), turn: (mirror ? 35 : -35, small))
    }
}

extension Path {
    /// An SVG path's M, L, H, V, C, Q and Z commands (absolute) and l, h, v (relative), all the
    /// drawings here use.
    init(svg: String) {
        self.init()
        var tokens: [String] = [], number = ""
        for character in svg {
            if character.isLetter {
                if !number.isEmpty { tokens.append(number); number = "" }
                tokens.append(String(character))
            } else if character == " " || character == "," {
                if !number.isEmpty { tokens.append(number); number = "" }
            } else if character == "-" && !number.isEmpty {
                tokens.append(number); number = "-"
            } else {
                number.append(character)
            }
        }
        if !number.isEmpty { tokens.append(number) }
        var command = "M", index = 0, point = CGPoint.zero, start = CGPoint.zero
        func value() -> CGFloat {
            defer { index += 1 }
            return index < tokens.count ? CGFloat(Double(tokens[index]) ?? 0) : 0
        }
        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = tokens[index]
                index += 1
                if command == "Z" || command == "z" { closeSubpath(); point = start; continue }
            }
            switch command {
            case "M":
                point = CGPoint(x: value(), y: value()); start = point
                move(to: point)
                command = "L"
            case "L":
                point = CGPoint(x: value(), y: value()); addLine(to: point)
            case "l":
                point = CGPoint(x: point.x + value(), y: point.y + value()); addLine(to: point)
            case "H":
                point.x = value(); addLine(to: point)
            case "h":
                point.x += value(); addLine(to: point)
            case "V":
                point.y = value(); addLine(to: point)
            case "v":
                point.y += value(); addLine(to: point)
            case "C":
                let c1 = CGPoint(x: value(), y: value()), c2 = CGPoint(x: value(), y: value())
                point = CGPoint(x: value(), y: value())
                addCurve(to: point, control1: c1, control2: c2)
            case "Q":
                let control = CGPoint(x: value(), y: value())
                point = CGPoint(x: value(), y: value())
                addQuadCurve(to: point, control: control)
            default:
                index += 1
            }
        }
    }
}
