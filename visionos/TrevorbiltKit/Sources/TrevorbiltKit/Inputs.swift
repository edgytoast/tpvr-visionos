import ARKit
import GameController
import SwiftUI
import UIKit

/// What the player can play with right now: hand tracking's permission, each PS VR2 Sense controller
/// and a gamepad. It only queries permissions, never asks for them (the game does that, when it
/// first needs them).
@MainActor
@Observable
public final class InputMonitor {
    public enum Permission: Equatable {
        case allowed, denied, notAsked, unavailable
    }

    public struct Controller: Equatable {
        public let name: String
        public let battery: Float?
        public let charging: Bool
    }

    public private(set) var hands: Permission = .notAsked
    public private(set) var accessories: Permission = .notAsked
    public private(set) var senseLeft: Controller?
    public private(set) var senseRight: Controller?
    public private(set) var gamepad: Controller?
    /// The first moments after launch, when GameController can still report nothing connected.
    public private(set) var checking = true

    public var anySense: Bool { senseLeft != nil || senseRight != nil }
    public var anyController: Bool { anySense || gamepad != nil }

    private let testOverride: [String: String]
    private let observations = Observations()
    private var started = false

    /// `testOverride`, for headless Simulator runs: "hands:denied,sense:LR,gamepad:none" (hands:
    /// allowed, denied, notasked or unavailable; sense: none, L, R or LR; gamepad: none or yes).
    /// Nothing is read until `start()`.
    public init(testOverride: String? = nil) {
        var parsed: [String: String] = [:]
        for pair in (testOverride ?? "").split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map { String($0).lowercased() }
            if parts.count == 2 { parsed[parts[0]] = parts[1] }
        }
        self.testOverride = parsed
    }

    /// Starts watching controllers come and go and reads the permissions, once (from the view's
    /// `.task`, so a view re-created by SwiftUI doesn't start a monitor it then throws away).
    public func start() async {
        guard !started else { return }
        started = true
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readControllers() }
            })
        }
        await refresh()
        try? await Task.sleep(for: .seconds(1.5))
        checking = false
    }

    /// Reads everything again: call when the app comes back to the foreground (the player may have
    /// changed a permission in Settings, or charged a controller).
    public func refresh() async {
        readControllers()
        if let value = testOverride["hands"] {
            hands = Self.permission(named: value)
            accessories = .allowed
            return
        }
        guard HandTrackingProvider.isSupported else {
            hands = .unavailable
            accessories = .unavailable
            return
        }
        let results = await ARKitSession().queryAuthorization(for: [.handTracking, .accessoryTracking])
        hands = Self.permission(results[.handTracking])
        accessories = Self.permission(results[.accessoryTracking])
    }

    private func readControllers() {
        if testOverride["sense"] != nil || testOverride["gamepad"] != nil {
            let sense = testOverride["sense"] ?? "none"
            senseLeft = sense.contains("l") ? Controller(name: "Sense (L)", battery: 0.8, charging: false) : nil
            senseRight = sense.contains("r") ? Controller(name: "Sense (R)", battery: 0.15, charging: false) : nil
            gamepad = testOverride["gamepad"] == "yes" ? Controller(name: "DualSense", battery: nil, charging: false) : nil
            return
        }
        var left: Controller?, right: Controller?, pad: Controller?
        for controller in GCController.controllers() {
            let name = controller.vendorName ?? "Controller"
            let battery = controller.battery.map { $0.batteryState == .unknown ? nil : $0.batteryLevel } ?? nil
            let entry = Controller(name: name, battery: battery, charging: controller.battery?.batteryState == .charging)
            if controller.productCategory == GCProductCategorySpatialController {
                // Each Sense half says which it is at the end of its name: "... (L)", "... (R)".
                if name.hasSuffix("(R)") { right = entry } else { left = left ?? entry }
            } else if controller.extendedGamepad != nil {
                pad = pad ?? entry
            }
        }
        senseLeft = left
        senseRight = right
        gamepad = pad
    }

    private static func permission(_ status: ARKitSession.AuthorizationStatus?) -> Permission {
        switch status {
        case .allowed: .allowed
        case .denied: .denied
        default: .notAsked
        }
    }

    private static func permission(named value: String) -> Permission {
        switch value {
        case "allowed": .allowed
        case "denied": .denied
        case "unavailable": .unavailable
        default: .notAsked
        }
    }
}

/// NotificationCenter registrations, removed when their owner goes away.
private final class Observations {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

/// What a port says about the inputs, for the selected way of playing: one line, whether play
/// can go ahead, whether hand tracking is what's missing, and whether Settings is where to fix
/// what is (then Open Settings shows).
public struct InputVerdict: Equatable {
    public let text: String
    public let ready: Bool
    public let handsNeeded: Bool
    /// What's missing is fixed in Settings (hand tracking, accessory tracking): the strip offers
    /// Open Settings. Unless the port says, whenever hands are needed.
    public let settingsNeeded: Bool

    public init(_ text: String, ready: Bool, handsNeeded: Bool = false, settingsNeeded: Bool? = nil) {
        self.text = text
        self.ready = ready
        self.handsNeeded = handsNeeded
        self.settingsNeeded = settingsNeeded ?? handsNeeded
    }
}

/// What the player will play with, for an ornament centred under the launcher: a tile each for
/// hands, the two Sense controllers (or one, where they act as a single gamepad) and a gamepad,
/// with the port's verdict under them, and Open Settings when the verdict says that's where to fix it.
public struct InputStatus: View {
    private let monitor: InputMonitor
    private let handsUsed: Bool
    private let handsUnusedReason: String
    private let combinedSenseTitle: String?
    private let verdict: InputVerdict
    @Environment(\.openURL) private var openURL

    /// `handsUsed`: whether the selected way of playing reads bare hands at all (if not, the hands
    /// tile says `handsUnusedReason`). `combinedSenseTitle`: where the two Sense controllers act as
    /// one gamepad, they show as one tile with this title, e.g. "Sense (as a gamepad)".
    public init(monitor: InputMonitor, handsUsed: Bool, handsUnusedReason: String = "Not used here",
                combinedSenseTitle: String? = nil, verdict: InputVerdict) {
        self.monitor = monitor
        self.handsUsed = handsUsed
        self.handsUnusedReason = handsUnusedReason
        self.combinedSenseTitle = combinedSenseTitle
        self.verdict = verdict
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                InputTile(symbol: "hand.raised.fill", title: "Hands", status: handsStatus)
                if let combinedSenseTitle {
                    InputTile(symbol: "circle.circle.fill", title: combinedSenseTitle, status: combinedSenseStatus, wide: true)
                } else {
                    InputTile(symbol: "l.joystick.fill", title: "Sense L", status: senseStatus(monitor.senseLeft, other: monitor.senseRight))
                    InputTile(symbol: "r.joystick.fill", title: "Sense R", status: senseStatus(monitor.senseRight, other: monitor.senseLeft))
                }
                InputTile(symbol: "gamecontroller.fill", title: "Gamepad",
                          status: monitor.gamepad.map(controllerStatus) ?? .init("None", .off))
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: monitor.checking ? "ellipsis.circle" : verdict.ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(verdict.ready || monitor.checking ? AnyShapeStyle(.primary) : AnyShapeStyle(Trevorbilt.orangeTint))
                        .font(.system(size: 15))
                        .accessibilityHidden(true)
                    Text(monitor.checking ? "Checking controllers…" : verdict.text)
                        .font(.tbBody(13, weight: .medium, relativeTo: .footnote))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if !monitor.checking && verdict.settingsNeeded {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(TrevorbiltSecondaryButtonStyle())
                }
            }
            .frame(maxWidth: 356)
        }
        .padding(12)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var handsStatus: InputTile.Status {
        guard handsUsed else { return .init(handsUnusedReason, .off) }
        switch monitor.hands {
        case .allowed: return .init("Allowed", .on)
        case .denied: return .init("Off in Settings", .warning)
        case .notAsked: return .init("Asked at Play", .on)
        case .unavailable: return .init("Not available", .off)
        }
    }

    private func controllerStatus(_ controller: InputMonitor.Controller) -> InputTile.Status {
        if controller.charging { return .init("Charging", .on) }
        guard let battery = controller.battery else { return .init("Connected", .on) }
        let percent = Int((battery * 100).rounded())
        return battery < 0.2 ? .init("\(percent)% · charge soon", .warning) : .init("\(percent)%", .on)
    }

    private func senseStatus(_ controller: InputMonitor.Controller?, other: InputMonitor.Controller?) -> InputTile.Status {
        guard let controller else { return other == nil ? .init("None", .off) : .init("Not connected", .warning) }
        return controllerStatus(controller)
    }

    /// Both halves on one tile: "L 80% · R 75%", the one to charge, or the one that's missing.
    private var combinedSenseStatus: InputTile.Status {
        switch (monitor.senseLeft, monitor.senseRight) {
        case let (left?, right?):
            for (side, half) in [("L", left), ("R", right)] {
                let status = controllerStatus(half)
                if status.state == .warning { return .init("\(side) \(status.text)", .warning) }
            }
            func short(_ half: InputMonitor.Controller) -> String {
                half.charging ? "charging" : half.battery.map { "\(Int(($0 * 100).rounded()))%" } ?? "on"
            }
            return .init("L \(short(left)) · R \(short(right))", .on)
        case (_?, nil): return .init("Only L connected", .warning)
        case (nil, _?): return .init("Only R connected", .warning)
        case (nil, nil): return .init("None", .off)
        }
    }
}

/// One input: a symbol over its name over how it is. Its symbol and glass dim when it's not
/// connected or not used, its words stay readable; what needs attention has an orange symbol and
/// its status in bold.
struct InputTile: View {
    enum State { case on, off, warning }

    struct Status {
        let text: String
        let state: State
        init(_ text: String, _ state: State) {
            self.text = text
            self.state = state
        }
    }

    let symbol: String
    let title: String
    let status: Status
    var wide = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(status.state == .warning ? AnyShapeStyle(Trevorbilt.orangeTint) : AnyShapeStyle(.white))
                .opacity(status.state == .off ? 0.4 : 1)
                .frame(height: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(.tbBody(13, weight: .semibold, relativeTo: .footnote))
                .foregroundStyle(.white.opacity(status.state == .off ? 0.8 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            // Two lines at most ("15% ·" over "charge soon"), the same height on every tile.
            Text(status.text)
                .font(.tbBody(12, weight: status.state == .warning ? .bold : .medium, relativeTo: .caption))
                .foregroundStyle(.white.opacity(status.state == .warning ? 1 : 0.8))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.9)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: wide ? 168 : 80)
        .background(.white.opacity(status.state == .off ? 0.04 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
