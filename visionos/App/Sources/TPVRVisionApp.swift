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

        ImmersiveSpace(id: GameModel.immersiveSpaceID) {
            ImmersiveGame.layer(for: model)
        }
        // Full: you stand in Hyrule. Mixed: the same, with your room around the
        // menus (GameModel.playsMixed). Progressive: Hyrule through a portal.
        .immersionStyle(selection: $space.style, in: .full, .mixed, GameModel.progressiveStyle)
        .upperLimbVisibility(.automatic)
    }
}
