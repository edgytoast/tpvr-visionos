import CompositorServices
import SwiftUI

/// The frame the game renders into. CompositorServices hands the layer renderer to
/// the OpenXR provider (visionos/openxr-provider) through the game's bridge; the
/// provider paces frames, places the eyes and composites the game's layers into
/// the drawable. A CompositorLayer is immersive-space content, not a view.
enum ImmersiveGame {
    @MainActor
    static func layer(for model: GameModel) -> CompositorLayer {
        let configuration = GameLayerConfiguration(progressive: model.playsProgressive, foveated: model.foveated)
        return CompositorLayer(configuration: configuration) { layerRenderer in
            model.attach(layerRenderer)
        }
    }
}

/// The configuration the provider is written against: sRGB colour, 32-bit float
/// depth, foveation if asked for. One texture per eye for full immersion (the layout
/// WiiCompiled Vision's provider was proven with); one layered texture for
/// progressive immersion, whose portal the system draws with a render context that
/// needs both eyes in one render pass.
struct GameLayerConfiguration: CompositorLayerConfiguration {
    var progressive = false
    var foveated = false

    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.layout = .dedicated
        configuration.colorFormat = .bgra8Unorm_srgb
        if progressive, #available(visionOS 26.0, *) {
            let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = .progressiveImmersionEnabled
            if capabilities.supportedLayouts(options: options).contains(.layered) {
                configuration.layout = .layered
            }
            // The provider draws into whatever colour format the drawable has.
            let colors = capabilities.supportedColorFormats(options: .progressiveImmersionEnabled)
            if !colors.isEmpty, !colors.contains(.bgra8Unorm_srgb) {
                configuration.colorFormat = colors[0]
            }
        }
        configuration.depthFormat = .depth32Float
        // The provider draws every pass through the drawable's rasterization rate
        // map when there is one, and sizes the game's eye images to the views'
        // screen-space viewports: foveated, those are larger, and sharpest where
        // you look.
        configuration.isFoveationEnabled = foveated && capabilities.supportsFoveation
        print("[TPVR] layer: layout \(configuration.layout), colour \(configuration.colorFormat.rawValue), "
              + "progressive \(progressive), foveated \(configuration.isFoveationEnabled)")
    }
}
