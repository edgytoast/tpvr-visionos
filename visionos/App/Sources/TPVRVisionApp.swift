import CompositorServices
import SwiftUI

/// The app: a launcher window (the disc, Play) and the immersive space the game
/// renders into. The game is DusklightGame.framework, driven through its C bridge
/// (src/dusk/visionos/visionos_host.h) by GameModel.
@main
struct TPVRVisionApp: App {
    @StateObject private var model = GameModel()
    @State private var space = ImmersionSpaceStyle.shared

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

        // Progressive: Hyrule through a portal the Digital Crown widens.
        ImmersiveSpace(id: GameModel.progressiveSpaceID) {
            ImmersiveGame.layer(for: model, progressive: true)
        }
        .immersionStyle(selection: $space.progressiveStyle, in: GameModel.progressiveStyle, .full)
        .upperLimbVisibility(.automatic)
    }
}
