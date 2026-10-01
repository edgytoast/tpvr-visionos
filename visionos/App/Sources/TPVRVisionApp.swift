import CompositorServices
import SwiftUI

/// The app: a launcher window (the disc, Play) and the immersive space the game
/// renders into. The game is DusklightGame.framework, driven through its C bridge
/// (src/dusk/visionos/visionos_host.h) by GameModel.
@main
struct TPVRVisionApp: App {
    @StateObject private var model = GameModel()

    var body: some Scene {
        WindowGroup(id: GameModel.launcherWindowID) {
            LauncherView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 560)

        ImmersiveSpace(id: GameModel.immersiveSpaceID) {
            ImmersiveGame.layer(for: model)
        }
        // Full immersion: you stand in Hyrule. Mixed is offered for the menus
        // and flat scenes, which the provider can show over the room.
        .immersionStyle(selection: $model.immersionStyle, in: .full, .mixed)
        .upperLimbVisibility(.automatic)
    }
}
