import CompositorServices
import SwiftUI

/// The frame the game renders into. CompositorServices hands the layer renderer to
/// the OpenXR provider (visionos/openxr-provider) through the game's bridge; the
/// provider paces frames, places the eyes and composites the game's layers into
/// the drawable. A CompositorLayer is immersive-space content, not a view.
enum ImmersiveGame {
    static func layer(for model: GameModel) -> CompositorLayer {
        CompositorLayer(configuration: GameLayerConfiguration()) { layerRenderer in
            model.attach(layerRenderer)
        }
    }
}

/// The configuration the provider is written against (the same as WiiCompiled
/// Vision's): one texture per eye, sRGB colour, 32-bit float depth.
struct GameLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        // The provider draws full-view quads of the game's eye images at their own
        // resolution rather than through a rasterization rate map.
        configuration.isFoveationEnabled = false
    }
}
