import GameController
import SwiftUI
import TrevorbiltKit

// How to play, for each way of playing: a gamepad (DualSense-style or Xbox-style, as connected) or
// the Sense controllers, drawn as the kit's own illustrations, with a callout on each button that
// does something: the controller's own symbol for it (GameController's, or the drawing's family's
// with nothing connected), what it does and its name in that family. Bare hands as the kit's
// drawing, each hand a random skin tone each time the page appears, with numbered markers and a
// legend. The launcher's Controls tab. The mappings are the game's: the VR mod's for Sense
// controllers and hands in Full and Progressive (src/dusk/vr/vr_main.cpp, the provider's gestures
// in xr_visionos_input.mm), Dusklight's for a gamepad (aurora's default buttons), and the Window
// view's Sense pad (visionos_sense_pad.mm).
struct ControlsView: View {
    enum Input: String, CaseIterable, Identifiable {
        case hands = "Hands", sense = "Sense", gamepad = "Gamepad"
        var id: Self { self }
    }

    /// The hands' gestures, in two pages (ten at once didn't fit beside the drawing).
    enum Gestures: String, CaseIterable, Identifiable {
        case moving = "Moving", menus = "Items and menus"
        var id: Self { self }
    }

    @State private var guide = ControlsGuide.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TrevorbiltHeading("how to ", bold: "play", size: 22)
                // What you hold, then (for hands) which gestures, in one row.
                HStack(spacing: 8) {
                    ForEach(Input.allCases) { input in inputButton(input) }
                    if guide.input == .hands {
                        Spacer().frame(width: 8)
                        ForEach(Gestures.allCases) { gestures in
                            TrevorbiltChip(gestures.rawValue, selected: guide.gestures == gestures) { guide.gestures = gestures }
                        }
                    }
                }
                page
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func inputButton(_ input: Input) -> some View {
        let connected = switch input {
        case .hands: false
        case .sense: guide.senseConnected
        case .gamepad: guide.gamepadConnected
        }
        return Button { guide.input = input } label: {
            VStack(spacing: 3) {
                Group {
                    switch input {
                    case .hands: Image(systemName: "hand.raised.fill")
                    case .sense: HStack(spacing: 2) { Image(systemName: "l.joystick.fill"); Image(systemName: "r.joystick.fill") }
                    case .gamepad: Image(systemName: "gamecontroller.fill")
                    }
                }
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 20, weight: .medium))
                .frame(height: 24)
                .accessibilityHidden(true)
                Text(input.rawValue).font(.tbHeader(13, bold: true, relativeTo: .headline))
                Text(connected ? "Connected" : input == .hands ? "Full, Progressive" : "Not connected")
                    .font(.tbBody(11, weight: .medium, relativeTo: .caption2))
                    .foregroundStyle(.white.opacity(connected ? 1 : 0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 4)
            }
            .padding(.vertical, 8)
            .frame(width: 104)
        }
        .buttonStyle(TrevorbiltTileButtonStyle(selected: guide.input == input))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(guide.input == input ? .isSelected : [])
    }

    @ViewBuilder private var page: some View {
        let window = guide.windowView && guide.input != .hands
        let items = items(guide.input, window: window, gestures: guide.gestures)
        switch guide.input {
        case .hands:
            // The drawing and, beside it, what every number on it does, all in view at once.
            HStack(alignment: .center, spacing: 14) {
                ControllerDiagram(art: .hands, items: items, markerSize: 20)
                    .frame(minWidth: 0, maxWidth: .infinity)
                ControlsLegend(items: items)
                    .frame(width: 290)
            }
            // A skin tone for each hand, picked afresh each time the page appears (Trevor's call:
            // hands from across the world, never one baked in).
            .randomHandTones()
        case .gamepad:
            ControllerCallouts(rig: padRig, controls: Self.gamepadControls(window: window).map {
                glyph($0, items: items, on: .gamepad, rig: padRig)
            })
        case .sense:
            ControllerCallouts(rig: .sensePair, controls: Self.senseControls(window: window).map {
                glyph($0, items: items, on: .sense, rig: .sensePair)
            })
            // What no button does (a swing of the sword), in the room under the hands, so the
            // footnote under it stays put between the two views.
            .overlay(alignment: .bottom) {
                unplaced(items, on: Set(Self.senseControls(window: window))).padding(.bottom, 6)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
        }
        footnote
    }

    // The controls each drawing calls out: the ones that do something in that view.
    private static func gamepadControls(window: Bool) -> [String] {
        ["leftTrigger", "rightShoulder", "rightTrigger", "dpad", "leftStick", "view", "menu", "y", "x", "b", "a", "rightStick"]
    }

    private static func senseControls(window: Bool) -> [String] {
        window ? ["leftTrigger", "leftShoulder", "leftStick", "y", "x", "view",
                  "rightTrigger", "rightShoulder", "rightStick", "b", "a", "menu"]
               : ["leftTrigger", "leftShoulder", "leftStick", "y", "x", "view",
                  "rightTrigger", "rightShoulder", "rightStick", "b", "a"]
    }

    /// What no button on the map does (a swing of the sword), as a line under it.
    @ViewBuilder private func unplaced(_ items: [ControlItem], on controls: Set<String>) -> some View {
        let rest = items.filter { $0.anchor.map { !controls.contains($0) } ?? true }
        if !rest.isEmpty {
            HStack(spacing: 14) {
                ForEach(rest) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.anchor == "swing" ? "hand.wave.fill" : "info.circle")
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                        Text("\(Text(item.action).bold()): \(item.how)")
                    }
                    .font(.tbBody(12, relativeTo: .caption))
                }
            }
        }
    }

    /// The gamepad drawing: the connected pad's kind (a DualSense or DualShock, or any other pad
    /// as the Xbox kind), or the DualSense kind with none connected.
    private var padRig: ControllerRig {
        _ = guide.controllerChanges
        // Headless Simulator runs: TPVR_TEST_PAD=none (or xbox) draws as if no pad (an Xbox-kind
        // pad) were connected, with the neutral symbols; the Simulator always has its own pad.
        if let test = TestHooks.value("TPVR_TEST_PAD") { return test == "xbox" ? .xbox : .dualSense }
        guard let pad = GCController.controllers().first(where: {
            $0.productCategory != GCProductCategorySpatialController && $0.extendedGamepad != nil
        })?.extendedGamepad else { return .dualSense }
        return pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? .dualSense : .xbox
    }

    /// A control as the drawing shows it: the connected controller's own symbol for it (or the
    /// drawing's family's), what it does here, and its name in that family.
    private func glyph(_ control: String, items: [ControlItem], on input: Input, rig: ControllerRig) -> GlyphControl {
        var actions = items.filter { $0.anchor == control }.map(\.action)
        actions += items.compactMap { $0.also[control] }
        let connected = TestHooks.value("TPVR_TEST_PAD") == nil ? ControllerGlyph(anchor: control)?.symbol(on: input) : nil
        let symbol = connected ?? GlyphControl.neutralSymbol(control, for: rig)
        return GlyphControl(control, symbol: symbol, actions: actions, name: Self.controlName(control, rig: rig))
    }

    /// A control's name as its controller's family says it.
    private static func controlName(_ control: String, rig: ControllerRig) -> String {
        switch (rig, control) {
        case (_, "leftStick"): "Left stick"
        case (_, "rightStick"): "Right stick"
        case (_, "dpad"): "D-pad"
        case (.xbox, "a"): "A"
        case (.xbox, "b"): "B"
        case (.xbox, "x"): "X"
        case (.xbox, "y"): "Y"
        case (.xbox, "leftShoulder"): "LB"
        case (.xbox, "rightShoulder"): "RB"
        case (.xbox, "leftTrigger"): "LT"
        case (.xbox, "rightTrigger"): "RT"
        case (.xbox, "menu"): "Menu"
        case (.xbox, "view"): "View"
        case (_, "a"): "Cross"
        case (_, "b"): "Circle"
        case (_, "x"): "Square"
        case (_, "y"): "Triangle"
        case (.sensePair, "leftShoulder"): "L1 (grip)"
        case (.sensePair, "rightShoulder"): "R1 (grip)"
        case (.sensePair, "leftTrigger"): "L2 (trigger)"
        case (.sensePair, "rightTrigger"): "R2 (trigger)"
        case (_, "leftShoulder"): "L1"
        case (_, "rightShoulder"): "R1"
        case (_, "leftTrigger"): "L2"
        case (_, "rightTrigger"): "R2"
        case (_, "menu"): "Options"
        case (_, "view"): "Create"
        default: control
        }
    }

    // MARK: Twilight Princess's controls

    private func items(_ input: Input, window: Bool, gestures: Gestures) -> [ControlItem] {
        func button(_ number: Int, _ action: String, _ how: String, _ anchor: String?, also: [String: String] = [:]) -> ControlItem {
            ControlItem(number, action, how, anchor: anchor, also: also)
        }
        func hand(_ number: Int, _ action: String, _ how: String, _ anchor: String, _ pose: HandPose) -> ControlItem {
            ControlItem(number, action, how, anchor: anchor, pose: .hand(pose))
        }
        switch (input, window) {
        case (.hands, _):
            // The provider's gestures (xr_visionos_input.mm) on the VR mod's Touch layout.
            switch gestures {
            case .moving:
                return [hand(1, "Walk", "Pinch your left thumb and middle finger, hold, and move your hand.",
                             "leftMiddle", .pinchMiddleLeftMove),
                        hand(2, "Turn", "Pinch your right thumb and little finger, hold, and move it sideways.",
                             "rightLittle", .pinchLittleRightTurn),
                        hand(3, "Action", "Pinch your right thumb and middle finger: talk, open, roll.",
                             "rightMiddle", .pinchMiddleRight),
                        hand(4, "Sword", "Swing your sword hand, or pinch your right thumb and ring finger.", "rightPalm", .swingRight),
                        hand(5, "Shield", "Make a fist with your left hand and hold it.", "leftPalm", .fistLeft),
                        hand(6, "Target", "Pinch your left thumb and index finger, and hold.", "leftIndex", .pinchIndexLeft)]
            case .menus:
                return [hand(1, "Item (Y)", "Pinch your right thumb and index finger.", "rightIndex", .pinchIndexRight),
                        hand(2, "Item (X)", "Make a fist with your right hand.", "rightPalm", .fistRight),
                        hand(3, "Item ring", "Pinch your left thumb and ring finger.", "leftRing", .pinchRingLeft),
                        hand(4, "Map", "Tap your left thumb and middle finger. (Hold them to walk.)", "leftMiddle",
                             .pinchMiddleLeft),
                        hand(5, "Collection", "Pinch your left thumb and little finger: gear and quest status. The game waits.",
                             "leftLittle", .pinchLittleLeft)]
            }
        case (.sense, false):
            // The VR mod's Touch layout (vr_main.cpp), on the Sense controllers.
            return [button(1, "Move", "Left stick (click it for Midna)", "leftStick", also: ["leftStick": "Midna (click)"]),
                    button(2, "Turn", "Right stick, or just turn around (click it for the collection)", "rightStick",
                           also: ["rightStick": "Collection (click)"]),
                    button(3, "Action", "Cross: talk, open, pick up, roll", "a"),
                    button(4, "Sword", "Circle", "b"),
                    button(5, "Shield", "Hold the left grip", "leftShoulder"),
                    button(6, "Target", "Hold the left trigger", "leftTrigger"),
                    button(7, "Item (Y)", "The right trigger", "rightTrigger"),
                    button(8, "Item (X)", "The right grip", "rightShoulder"),
                    button(9, "Item ring", "Triangle", "y"),
                    button(10, "Map", "Square", "x"),
                    button(11, "Collection", "Create, or click the right stick: gear and quest status", "view"),
                    button(12, "Sword", "swing your sword hand, as Link would", "swing")]
        case (.gamepad, false):
            // Dusklight's own buttons (aurora's defaults), with the VR mod's turn on the right stick.
            return [button(1, "Move", "Left stick", "leftStick"),
                    button(2, "Turn", "Right stick, or just turn around", "rightStick"),
                    button(3, "Action", "A / Cross: talk, open, pick up, roll", "a"),
                    button(4, "Sword", "B / Circle", "b"),
                    button(5, "Shield", "Right trigger", "rightTrigger"),
                    button(6, "Target", "Left trigger", "leftTrigger"),
                    button(7, "Item (X)", "X / Square", "x"),
                    button(8, "Item (Y)", "Y / Triangle", "y"),
                    button(9, "Midna", "RB / R1", "rightShoulder"),
                    button(10, "Item ring and map", "D-pad: up or down for the ring, left or right for the map", "dpad"),
                    button(11, "Collection", "Menu / Options: gear and quest status", "menu"),
                    button(12, "Settings", "View / Create opens Dusklight's menu", "view")]
        case (.sense, true):
            // The two Sense controllers as one gamepad (visionos_sense_pad.mm).
            return [button(1, "Move", "Left stick (click it for the item ring)", "leftStick",
                           also: ["leftStick": "Item ring (click)"]),
                    button(2, "Camera", "Right stick (click it for the map)", "rightStick", also: ["rightStick": "Map (click)"]),
                    button(3, "Action", "Cross: talk, open, pick up, roll", "a"),
                    button(4, "Sword", "Circle", "b"),
                    button(5, "Shield", "R2, the right trigger", "rightTrigger"),
                    button(6, "Target", "L2, the left trigger", "leftTrigger"),
                    button(7, "Item (X)", "Square", "x"),
                    button(8, "Item (Y)", "Triangle", "y"),
                    button(9, "Midna", "R1, the right grip", "rightShoulder"),
                    button(10, "Item ring", "L1, the left grip", "leftShoulder"),
                    button(11, "Map", "Create, on the left controller", "view"),
                    button(12, "Collection", "Options, on the right controller: gear and quest status", "menu")]
        case (.gamepad, true):
            // Dusklight's own buttons (aurora's defaults): the original game's, on a modern pad.
            return [button(1, "Move", "Left stick", "leftStick"),
                    button(2, "Camera", "Right stick", "rightStick"),
                    button(3, "Action", "A / Cross: talk, open, pick up, roll", "a"),
                    button(4, "Sword", "B / Circle", "b"),
                    button(5, "Shield", "Right trigger", "rightTrigger"),
                    button(6, "Target", "Left trigger", "leftTrigger"),
                    button(7, "Item (X)", "X / Square", "x"),
                    button(8, "Item (Y)", "Y / Triangle", "y"),
                    button(9, "Midna", "RB / R1", "rightShoulder"),
                    button(10, "Item ring and map", "D-pad: up or down for the ring, left or right for the map", "dpad"),
                    button(11, "Collection", "Menu / Options: gear and quest status", "menu"),
                    button(12, "Settings", "View / Create opens Dusklight's menu", "view")]
        }
    }

    private var footnote: some View {
        let window = guide.windowView && guide.input != .hands
        let text: String = switch (guide.input, window) {
        case (.hands, _) where guide.gestures == .moving:
            "Hands play in Full and Progressive. A Sense controller takes over the hand holding it. The sword hand is the game's VR setting."
        case (.hands, _):
            "Dusklight's menu: hold a left little-finger pinch and a right index pinch together for a second. Calling Midna needs a controller: no gesture stands in for a stick click."
        case (.sense, false):
            "Dusklight's menu: hold Create and R2 together for a second. Your sword follows your sword hand, the right unless you change it there (VR › Combat › Sword Hand), and the shield your other hand."
        case (.gamepad, false):
            "In Full and Progressive a gamepad plays the original game's buttons while you look around Hyrule. Sense controllers or your hands swing the sword for real."
        case (.sense, true):
            "The Window view plays like the original game, and your Sense controllers act as one gamepad: R2 and Options together open Dusklight's menu. Look at the window to give it your controller."
        case (.gamepad, true):
            "The Window view plays like the original game, and it needs a controller: visionOS gives apps no hand tracking outside Full and Progressive. Look at the window to give it your controller."
        }
        // Top-aligned, so the chips stay put when the note under a tap is a line longer.
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
            Text(text)
                .font(.tbBody(12, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Which view's buttons these are, the other a tap away. (Hands play only in Full and
            // Progressive.)
            if guide.input != .hands {
                HStack(spacing: 6) {
                    TrevorbiltChip("Full, Progressive", selected: !window) { guide.windowView = false }
                    TrevorbiltChip("Window", selected: window) { guide.windowView = true }
                }
                .fixedSize()
                // As the callouts: larger would leave the note no room.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// What the guide shows (the launcher opens it on what's connected, for the way the game will play),
// and which controllers are connected.
@Observable
final class ControlsGuide {
    static let shared = ControlsGuide()
    var input = ControlsView.Input.hands
    var gestures = ControlsView.Gestures.moving
    /// The Window view's buttons (the original game's) rather than Full and Progressive's.
    var windowView = false
    /// Counts controllers connecting and disconnecting; reading it redraws with the new symbols.
    private(set) var controllerChanges = 0

    var senseConnected: Bool {
        _ = controllerChanges
        return GCController.controllers().contains { $0.productCategory == GCProductCategorySpatialController }
    }

    var gamepadConnected: Bool {
        _ = controllerChanges
        return GCController.controllers().contains { $0.productCategory != GCProductCategorySpatialController && $0.extendedGamepad != nil }
    }

    private init() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.controllerChanges += 1
            }
        }
    }
}

/// A button, as the connected controller draws it (GCControllerElement.sfSymbolsName). Sense
/// controllers name each half's elements alike, so X and Y are the left half's A and B.
enum ControllerGlyph {
    case a, b, x, y, menu, view, dpad, leftTrigger, rightTrigger, leftShoulder, rightShoulder, leftStick, rightStick

    /// The control a guide's map names.
    init?(anchor: String) {
        switch anchor {
        case "a": self = .a
        case "b": self = .b
        case "x": self = .x
        case "y": self = .y
        case "menu": self = .menu
        case "view": self = .view
        case "dpad": self = .dpad
        case "leftTrigger": self = .leftTrigger
        case "rightTrigger": self = .rightTrigger
        case "leftShoulder": self = .leftShoulder
        case "rightShoulder": self = .rightShoulder
        case "leftStick": self = .leftStick
        case "rightStick": self = .rightStick
        default: return nil
        }
    }

    /// The symbol on the connected controller of that kind, or nil with none connected.
    func symbol(on input: ControlsView.Input) -> String? {
        _ = ControlsGuide.shared.controllerChanges
        let controllers = GCController.controllers()
        switch input {
        case .hands:
            return nil
        case .sense:
            let spatial = controllers.filter { $0.productCategory == GCProductCategorySpatialController }
            let left = spatial.first { $0.vendorName?.hasSuffix("(L)") == true }
            let right = spatial.first { $0.vendorName?.hasSuffix("(R)") == true }
            func button(_ half: GCController?, _ names: String...) -> String? {
                names.lazy.compactMap { half?.physicalInputProfile.buttons[$0]?.sfSymbolsName }.first
            }
            func stick(_ half: GCController?) -> String? {
                half?.physicalInputProfile.dpads[__GCInputDirectionPadName.thumbstick.rawValue]?.sfSymbolsName
            }
            switch self {
            case .a: return button(right, GCInputButtonA)
            case .b: return button(right, GCInputButtonB)
            case .x: return button(left, GCInputButtonA)
            case .y: return button(left, GCInputButtonB)
            case .menu: return button(right, GCInputButtonMenu)
            case .view: return button(left, GCInputButtonShare, GCInputButtonOptions, GCInputButtonMenu)
            case .leftTrigger: return button(left, __GCInputButtonName.trigger.rawValue)
            case .rightTrigger: return button(right, __GCInputButtonName.trigger.rawValue)
            case .leftShoulder: return button(left, "Grip")
            case .rightShoulder: return button(right, "Grip")
            case .leftStick: return stick(left)
            case .rightStick: return stick(right)
            case .dpad: return nil
            }
        case .gamepad:
            guard let pad = controllers.first(where: {
                $0.productCategory != GCProductCategorySpatialController && $0.extendedGamepad != nil
            })?.extendedGamepad else { return nil }
            switch self {
            case .a: return pad.buttonA.sfSymbolsName
            case .b: return pad.buttonB.sfSymbolsName
            case .x: return pad.buttonX.sfSymbolsName
            case .y: return pad.buttonY.sfSymbolsName
            case .menu: return pad.buttonMenu.sfSymbolsName
            case .view: return pad.buttonOptions?.sfSymbolsName
            case .dpad: return pad.dpad.sfSymbolsName
            case .leftTrigger: return pad.leftTrigger.sfSymbolsName
            case .rightTrigger: return pad.rightTrigger.sfSymbolsName
            case .leftShoulder: return pad.leftShoulder.sfSymbolsName
            case .rightShoulder: return pad.rightShoulder.sfSymbolsName
            case .leftStick: return pad.leftThumbstick.sfSymbolsName
            case .rightStick: return pad.rightThumbstick.sfSymbolsName
            }
        }
    }
}
