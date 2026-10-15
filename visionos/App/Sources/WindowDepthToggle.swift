import GameController
import QuartzCore
import SwiftUI

/// The window's 2D/3D choice: the game's world in depth (the scene mirror) or the game's own flat
/// frame, as the player likes it, when a stretch of the game doesn't sit well in 3D, or to compare
/// the two. Self-contained, so another port's window can take it as it is:
///
/// - `WindowDepth` holds the choice (kept across launches) and animates the change. A port's window
///   calls `tick` once per RealityKit update (telling it whether its mirror shows a whole frame, and
///   how flat the last window frame it drew was) and applies what it reads:
///   `flatten` (0 the mirror at full depth, 1 laid flat on the glass, each point along its own line
///   of sight, so the picture from the game camera's place stays the same), `flatFrame` (0 the
///   mirror with the HUD over it, 1 the game's own finished frame, opaque on the glass) and
///   `mirrorWanted` (false once 2D is reached: stop the mirror and the game's 3D capture).
/// - `WindowDepthButton` is the glass button, for an ornament just above the window's top-right
///   corner (inside the picture it covered the game's own HUD there).
/// - `tick` also reads a gamepad chord (`Chord`: two buttons the port's game leaves free; L1 + Create,
///   LB + View on an Xbox pad, in Wind Waker; L1 + R3 in Twilight Princess, where Create opens
///   Dusklight's menu); never a Sense controller's.
///
/// To 2D: the depth flattens onto the glass (0.3 s), then the flat frame fades in (0.2 s), then the
/// mirror stops once a window frame is drawn wholly flat. To 3D: the mirror starts, and once it shows
/// a whole frame (flat, under the flat frame; at most a second's wait for its textures), the flat
/// frame fades out, then the depth comes back. A toggle midway turns back from where it is. Without
/// a mirror (it failed to load, or was dropped), `unavailable()` hides the button and the flattening
/// stays at 2D (Twilight Princess's window shows its relief instead, if 3D was the choice).
@MainActor
@Observable
final class WindowDepth {
    enum Mode: String {
        case threeD = "3d", twoD = "2d"
    }

    /// The gamepad's 2D/3D chord: the second button pressed while the first is held switches.
    enum Chord {
        /// L1 + Create (LB + View).
        case leftShoulderCreate
        /// L1 + R3, a click of the right stick (LB + right stick).
        case leftShoulderRightStick

        /// What the button's help says.
        var name: String {
            switch self {
            case .leftShoulderCreate: "L1 + Create, or LB + View"
            case .leftShoulderRightStick: "L1 + R3, or LB + a right stick click"
            }
        }

        func held(_ pad: GCExtendedGamepad) -> Bool {
            switch self {
            case .leftShoulderCreate:
                guard let create = pad.buttonOptions else { return false }
                return pad.leftShoulder.isPressed && create.isPressed
            case .leftShoulderRightStick:
                guard let click = pad.rightThumbstickButton else { return false }
                return pad.leftShoulder.isPressed && click.isPressed
            }
        }
    }

    /// The choice: what the button shows.
    private(set) var mode: Mode
    /// 0: the mirror at full depth; 1: laid flat on the glass. Eased.
    var flatten: Float { Self.ease(flattenProgress) }
    /// 0: the mirror (and the HUD over it); 1: the game's own flat frame. Eased.
    var flatFrame: Float { Self.ease(frameProgress) }
    /// Whether the port's mirror and the game's 3D capture should run.
    private(set) var mirrorWanted: Bool
    /// False once there's no mirror to show: the button goes.
    private(set) var available = true

    private var flattenProgress: Float
    private var frameProgress: Float
    private var lastTick: CFTimeInterval = 0
    private var chordHeld = false
    private var wholeWait: Float = 0
    private let key: String
    let chord: Chord

    static let flattenSeconds: Float = 0.3
    static let fadeSeconds: Float = 0.2
    /// How long the way back to 3D waits for the mirror's frame to be whole (its textures made).
    static let wholeWaitSeconds: Float = 1

    /// `key`: where the choice is kept (UserDefaults). `initial`: a test run's choice, over the kept one.
    init(key: String = "windowDepthMode", initial: Mode? = nil, chord: Chord = .leftShoulderCreate) {
        self.key = key
        self.chord = chord
        let mode = initial ?? UserDefaults.standard.string(forKey: key).flatMap(Mode.init(rawValue:)) ?? .threeD
        self.mode = mode
        let flat: Float = mode == .twoD ? 1 : 0
        flattenProgress = flat
        frameProgress = flat
        mirrorWanted = mode == .threeD
    }

    func toggle() {
        set(mode == .threeD ? .twoD : .threeD)
    }

    /// `persist`: kept for the next launch (a test script's switches aren't).
    func set(_ newMode: Mode, persist: Bool = true) {
        guard available, newMode != mode else { return }
        mode = newMode
        if persist { UserDefaults.standard.set(newMode.rawValue, forKey: key) }
        if newMode == .threeD { mirrorWanted = true }
        wholeWait = 0
    }

    /// No mirror to show (it failed to load, or was dropped): no mirror is wanted, the flattening
    /// stays at 2D and the button goes. The kept choice stays for the next launch.
    func unavailable() {
        available = false
        mirrorWanted = false
        flattenProgress = 1
        frameProgress = 1
    }

    /// Once per update. `mirrorShowing`: the port's mirror shows a frame made since it was last
    /// wanted (on the way back to 3D, the flat frame stays until then); `mirrorWhole`: none of that
    /// frame's parts is waiting for its texture (waited for up to `wholeWaitSeconds`); `flatShown`:
    /// how flat (flatFrame) the last window frame drawn was (the mirror stops only once a wholly flat
    /// one is on the glass).
    func tick(mirrorShowing: Bool, mirrorWhole: Bool = true, flatShown: Float = 1) {
        let now = CACurrentMediaTime()
        let dt = lastTick > 0 ? Float(min(now - lastTick, 0.1)) : 0
        lastTick = now
        readChord()
        switch mode {
        case .twoD:
            // Flatten first, then fade the flat frame in; then the mirror can stop.
            if flattenProgress < 1 {
                flattenProgress = min(1, flattenProgress + dt / Self.flattenSeconds)
            } else if frameProgress < 1 {
                frameProgress = min(1, frameProgress + dt / Self.fadeSeconds)
            } else if flatShown >= 1 {
                mirrorWanted = false
            }
        case .threeD:
            // Fade the flat frame out once the mirror shows, whole, then bring the depth back.
            guard mirrorShowing else { return }
            if !mirrorWhole && wholeWait < Self.wholeWaitSeconds {
                wholeWait += dt
                return
            }
            if frameProgress > 0 {
                frameProgress = max(0, frameProgress - dt / Self.fadeSeconds)
            } else if flattenProgress > 0 {
                flattenProgress = max(0, flattenProgress - dt / Self.flattenSeconds)
            }
        }
    }

    /// A gamepad's chord, on pressing the second of its buttons.
    private func readChord() {
        guard available else { return }
        let held = GCController.controllers().contains { controller in
            guard controller.productCategory != GCProductCategorySpatialController,
                  let pad = controller.extendedGamepad else { return false }
            return chord.held(pad)
        }
        if held && !chordHeld { toggle() }
        chordHeld = held
    }

    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }
}

/// The window's 2D/3D button: a small glass circle (44 pt, in a 60 pt target, as visionOS asks for
/// eyes) showing what the window shows now (a cube for 3D, a flat frame for 2D).
struct WindowDepthButton: View {
    let depth: WindowDepth

    var body: some View {
        Button {
            depth.toggle()
        } label: {
            Image(systemName: depth.mode == .threeD ? "cube" : "rectangle")
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .windowDepthGlass()
                .padding(8)
                .contentShape(.interaction, .circle)
                .contentShape(.hoverEffect, Circle().inset(by: 8))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(depth.mode == .threeD ? "Showing in 3D" : "Showing in 2D")
        .accessibilityHint(depth.mode == .threeD ? "Shows the game flat" : "Shows the game in 3D")
        .help(depth.mode == .threeD ? "Show in 2D (\(depth.chord.name))" : "Show in 3D (\(depth.chord.name))")
    }
}

private extension View {
    /// visionOS's glass; elsewhere (should the file be built for another platform) a material.
    @ViewBuilder func windowDepthGlass() -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: .circle)
        #else
        background(.ultraThinMaterial, in: .circle)
        #endif
    }
}
