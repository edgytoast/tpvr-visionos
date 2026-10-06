import CompositorServices
import os
import SwiftUI

/// The app: a launcher window (the disc, Play) and the immersive space the game
/// renders into. The game is DusklightGame.framework, driven through its C bridge
/// (src/dusk/visionos/visionos_host.h) by GameModel.
@main
struct TPVRVisionApp: App {
    @StateObject private var model = GameModel()
    @State private var space = ImmersionSpaceStyle.shared

    init() {
        MemoryWatch.start()
    }

    var body: some Scene {
        WindowGroup(id: GameModel.launcherWindowID) {
            LauncherView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 640)

        // Two spaces, because a space that lists the progressive style makes every
        // drawable "support progressive": each present then needs the system's
        // render context, which only a layered layout can carry (the headset
        // aborted otherwise; the Simulator's single view hid it).
        // Full: you stand in Hyrule. Mixed: the same, with your room around the
        // menus (GameModel.playsMixed).
        ImmersiveSpace(id: GameModel.immersiveSpaceID) {
            ImmersiveGame.layer(for: model, progressive: false)
        }
        .immersionStyle(selection: $space.style, in: .full, .mixed)
        .upperLimbVisibility(.automatic)

        // Window: the game beside your other apps, with depth (GameWindowView). A WindowGroup
        // (Window needs visionOS 26); only Play opens it, and only once per run.
        WindowGroup(id: GameModel.windowSceneID) {
            GameWindowView()
                .environmentObject(model)
        }
        .windowStyle(.plain)
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentSize)

        // Progressive: Hyrule through a portal the Digital Crown widens.
        ImmersiveSpace(id: GameModel.progressiveSpaceID) {
            ImmersiveGame.layer(for: model, progressive: true)
                // A Digital Crown recenter moves the portal to where you face; the game
                // turns Hyrule to keep the view in it (the SHAR port's fix).
                .onWorldRecenter { dusk_visionos_world_recentered() }
        }
        .immersionStyle(selection: $space.progressiveStyle, in: GameModel.progressiveStyle, .full)
        .upperLimbVisibility(.automatic)
    }
}

/// Logs visionOS's memory warnings with what's left before the app's limit, so a
/// session that ends early (jetsam) can be told apart from a crash in the device log.
/// As in the SHAR port. Nothing is trimmed in response yet: aurora's GPU caches are
/// read by its render worker, so they can only be cleared once it has drained.
@MainActor
enum MemoryWatch {
    private static var source: DispatchSourceMemoryPressure?
    // The unified log, which a headset's device log keeps (print goes to stdout only).
    nonisolated private static let log = Logger(subsystem: "dev.tpvr.vision", category: "memory")

    static func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let level = event.contains(.critical) ? "critical" : "warning"
            log.warning("[TPVR] memory pressure (\(level, privacy: .public)): \(os_proc_available_memory() / 1_048_576, privacy: .public) MB left")
        }
        source.resume()
        Self.source = source
        log.notice("[TPVR] memory: \(os_proc_available_memory() / 1_048_576, privacy: .public) MB available at launch")
    }
}
