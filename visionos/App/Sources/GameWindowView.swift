import GameController
import Metal
import RealityKit
import SwiftUI
import Synchronization

/// Twilight Princess in a window in the shared space (Immersion: Window), beside other apps,
/// moved and resized with visionOS's own controls. visionOS gives no head pose outside a Full
/// Space, so the game plays flat, with its own camera. Behind a portal in the window, the scene
/// mirror (MirrorScene) rebuilds the game's 3D draws each frame for RealityKit to render from the
/// viewer's real eyes, so Hyrule has true depth from any angle; the HUD and Dusklight's menus
/// come from the game's frames (src/dusk/visionos/visionos_window.hpp) and sit flat on the
/// window's glass. As the SHAR port's window does. The frames' relief (a grid displaced by the
/// game's depth) is the fallback: TPVR_TEST_WINDOW_RELIEF=1, or until the mirror has a frame.
struct GameWindowView: View {
    @EnvironmentObject private var model: GameModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var updates: EventSubscription?
    @State private var aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                let screen: GameScreen
                do { screen = try await GameScreen() } catch {
                    print("[TPVR] the game window's materials failed to load: \(error)")
                    return
                }
                screen.aspectChanged = { aspect = CGFloat($0) }
                content.add(screen.root)
                GameScreen.fit(screen.root, to: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
                // RealityKit's updates pace the game: a frame per update while the window shows.
                updates = content.subscribe(to: SceneEvents.Update.self) { _ in screen.update() }
            } update: { content in
                if let root = content.entities.first {
                    GameScreen.fit(root, to: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
                }
            }
            // The window's face takes pinches and taps (the portal's collision box): without a
            // target they went through it to whatever was behind, another app's window or a
            // widget (the SHAR port found this on the headset). Nothing is done with them.
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in })
        }
        // visionOS turns a game controller's buttons into pinches on whatever the player looks at,
        // unless the view says it reads the controller itself: with another window open the game
        // got nothing (SHAR). Looking at the game window gives it the controller.
        .handlesGameControllerEvents(matching: .gamepad)
        // Next to no depth, so the face is where the window's bar and corner handles are: given the
        // depth a plain window offers (as deep as it is tall), the face sat at the back of it and
        // didn't line up with them on the headset (SHAR). What the scene has nearer than the face
        // still shows in front of it, up to where visionOS cuts it off (GameScreen.frontAllowance).
        .frame(depth: 4)
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minWidth: 640, idealWidth: 1280, maxWidth: 4096, minHeight: 300, idealHeight: 720, maxHeight: 2304)
        .onAppear {
            let openWindow = openWindow
            model.showLauncher = { openWindow(id: GameModel.launcherWindowID, value: GameModel.launcherWindowID) }
            model.gameWindowShowing = true
            model.startWindowGame()
            // Out of the way while you play, as with the immersive spaces.
            dismissWindow(id: GameModel.launcherWindowID, value: GameModel.launcherWindowID)
            // Test runs: TPVR_TEST_WINDOW_HOLD=<from>-<to> (seconds after the window appears) does
            // what the window going to the background and coming back does.
            if let hold = TestHooks.value("TPVR_TEST_WINDOW_HOLD")?.split(separator: "-").compactMap({ Double($0) }),
               hold.count == 2 {
                Task {
                    try? await Task.sleep(for: .seconds(hold[0]))
                    dusk_visionos_set_paused(true)
                    try? await Task.sleep(for: .seconds(max(hold[1] - hold[0], 0)))
                    dusk_visionos_set_paused(false)
                }
            }
        }
        .onDisappear {
            model.gameWindowShowing = false
            // Closing the window ends the game, and with it the app (progress is kept up to
            // the last autosave or save).
            model.windowClosed()
        }
        .onChange(of: scenePhase) { _, phase in
            // In the background (hidden): the game holds, as taking the headset off does in the
            // immersive spaces. Not when only inactive: a window still in view (Control Center or
            // a notification over it, say) would freeze while you watched (the SHAR port's rule).
            dusk_visionos_set_paused(phase == .background)
        }
    }
}

/// What the window shows, in window units: 1 wide, its face at z = 0, +z towards the viewer. A
/// portal fills the face and looks into a world holding the relief in two layers; the HUD is a
/// plane just in front of it. Frames are copied in on the main thread (RealityKit's textures and
/// meshes belong to the main actor), on the GPU, after the game's own writes (its MTLSharedEvent).
@MainActor
final class GameScreen {
    let root = Entity()
    var aspectChanged: ((Float) -> Void)?

    private let world = Entity()
    private var portal: ModelEntity
    private var hud: ModelEntity
    // With the mirror: the screen effects (bloom, mist, fades) as a layer over its world, each part
    // at the depth of what it lies on (the game's depth buffer), so that it stays on it from any
    // angle: Link's glow on Link, the sky's in the sky.
    private let effects = ModelEntity()
    // The mirror's level, then the screen effects (when on), then the HUD: drawn in that order,
    // whatever their depths, so nothing of the level nearer than the glass covers the HUD.
    private let sortGroup = ModelSortGroup(depthPass: nil)
    // After the level (0) and its blended parts (1 on, MirrorScene.maxBlendedParts of them at most).
    private static let effectsOrder: Int32 = MirrorScene.maxBlendedParts + 1
    private var effectsMesh: LowLevelMesh?
    private var effectsGrid = SIMD2<Int>.zero
    private var reliefMaterial: ShaderGraphMaterial
    private var hudMaterial: ShaderGraphMaterial
    private var effectsMaterial: ShaderGraphMaterial
    private var primary: ModelEntity?, backstop: ModelEntity?
    private var primaryMesh: LowLevelMesh?, backstopMesh: LowLevelMesh?
    private var colour: LowLevelTexture?, hudTexture: LowLevelTexture?, effectsTexture: LowLevelTexture?
    private var colourSize = SIMD2<Int>.zero, hudSize = SIMD2<Int>.zero
    private var grid = SIMD2<Int>.zero  // columns, rows
    private var aspect: Float = 16.0 / 9.0
    private var distances: MTLBuffer?
    private var surfaces: [UInt: MTLTexture] = [:]
    private var surfaceGeneration: UInt64 = .max
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: Pipelines
    private var frames = 0
    private var mirror: MirrorScene?
    private var mirrorShowing = false
    private let memoryGuard: WindowMemoryGuard
    /// Window frames committed to the GPU and not yet done, for the memory log.
    nonisolated private static let framesInFlight = Atomic<Int>(0)
    private var shownGameFrame: UInt32 = 0

    private static let rows = 216

    init() async throws {
        var relief = try await ShaderGraphMaterial(named: "/Root/ReliefFrame", from: "WindowFrame.usda", in: .main)
        // Seen from the side, a stretch across a depth step can face away; it still hides what's behind.
        relief.faceCulling = .none
        reliefMaterial = relief
        hudMaterial = try await ShaderGraphMaterial(named: "/Root/HudFrame", from: "WindowFrame.usda", in: .main)
        // On the glass, over everything (the sort group): the level now comes out nearer than the
        // glass, and depth-tested, the HUD, the fades and the letterbox bars went under it.
        hudMaterial.readsDepth = false
        hudMaterial.writesDepth = false
        // Over the whole level, after it (a sort group, below). What only darkens the picture (a
        // fade, letterbox bars) goes on the glass with the HUD instead (WindowHud): on this layer,
        // seen from the side, its farther parts painted over a bar.
        effectsMaterial = hudMaterial
        effectsMaterial.readsDepth = false
        effectsMaterial.writesDepth = false
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CancellationError()
        }
        self.device = device
        self.queue = queue
        memoryGuard = WindowMemoryGuard(device: device)
        pipelines = try Pipelines(device: device)
        world.components.set(WorldComponent())
        portal = ModelEntity()
        hud = ModelEntity()
        root.addChild(world)
        makePlanes(aspect: aspect)
        root.isEnabled = false  // until the first frame
        if (ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_RELIEF"] ?? "").isEmpty {
            do {
                let mirror = try await MirrorScene()
                world.addChild(mirror.root)
                effects.isEnabled = false
                world.addChild(effects)
                // After every part of the level, translucent ones included: RealityKit's own
                // back-to-front order put the level's translucent rocks over a letterbox bar.
                mirror.sort(in: sortGroup, order: 0)
                effects.components.set(ModelSortGroupComponent(group: sortGroup, order: Self.effectsOrder))
                self.mirror = mirror
                dusk_visionos_set_mirror_enabled(true)
            } catch {
                print("[TPVR] the scene mirror failed to load, so the window shows the relief: \(error)")
                dusk_visionos_set_mirror_enabled(false)
            }
        }
    }

    /// Window units onto the window: its face is the back of the view's bounds, scaled to its width
    /// in metres. (What the portal's world has nearer than the face still shows, inside the opening.)
    static func fit(_ root: Entity, to bounds: BoundingBox) {
        root.position = [bounds.center.x, bounds.center.y, bounds.min.z]
        root.scale = SIMD3(repeating: bounds.extents.x)
        // Test runs: TPVR_TEST_WINDOW_TILT=<degrees> turns the window about its vertical axis, which
        // shows the relief from the side without moving the Simulator's camera.
        if let tilt = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_TILT"].flatMap(Float.init) {
            root.orientation = simd_quatf(angle: tilt * .pi / 180, axis: [0, 1, 0])
        }
        if bounds.extents != loggedExtents {
            loggedExtents = bounds.extents
            dusk_visionos_set_mirror_front_allowance(frontAllowance / max(bounds.extents.x, 0.01), ReliefParams.minViewTangent)
            print(String(format: "[TPVR] window: %.3f x %.3f x %.3f m, from z %.3f to %.3f in the view's scene",
                         bounds.extents.x, bounds.extents.y, bounds.extents.z, bounds.min.z, bounds.max.z))
        }
    }
    private static var loggedExtents = SIMD3<Float>.zero
    /// How far in front of the window the scene may come out (metres). visionOS cuts a window's
    /// content off about 0.47 m in front of its face, whatever its size (measured in the Simulator
    /// with markers at set distances, at 0.72 and 1.15 m wide): the mirror keeps what's nearer than
    /// the glass inside this, so the ground under the camera isn't cut off at the window's foot.
    private static let frontAllowance: Float = 0.40

    func update() {
        switch memoryGuard.check(hasMirror: mirror != nil, mirror: { self.mirror?.diagnostics ?? "off" },
                                 extra: { "\(self.surfaces.count) frame surfaces (\(self.surfaceSizes)), "
                                          + "\(self.frames) window frames (\(self.frameRate())/s), "
                                          + "\(Self.framesInFlight.load(ordering: .relaxed)) in flight" }) {
        case .dropMirror: dropMirror()
        case .quit: dusk_visionos_request_quit()  // the game returns and the app ends with it (GameModel)
        // The game thread is stuck: exit's C++ teardown (Dawn's device, the window's slots) could
        // block on it or crash a worker, so the process ends without it. The log line is synced.
        case .forceExit: _exit(0)
        case .none: break
        }
        dusk_visionos_window_tick()
        var frame = dusk_visionos_window_frame()
        let fresh = dusk_visionos_window_acquire(&frame)
        if fresh {
            shownGameFrame = frame.game_frame
        }
        // The mirror's frame from the same game frame as the HUD and screen effects shown with it
        // (its frames are ready a little sooner): drawn from different frames, they slid apart.
        mirrorShowing = mirror?.update(upTo: shownGameFrame) ?? false
        guard fresh else { return }
        // Test runs: TPVR_TEST_DUMP_AT=<seconds> writes the mirror's frame and the window frame shown
        // with it (the same game frame), the first time the mirror shows one that long after the
        // window opened.
        if let at = Self.dumpAt, !dumpedAt, mirrorShowing, let mirror, CACurrentMediaTime() - opened >= at {
            dumpedAt = true
            dumpingNow = true
            mirror.dumpShown()
        }
        let serial = frame.serial
        guard let commands = queue.makeCommandBuffer() else {
            dusk_visionos_window_release(serial)
            return
        }
        commands.label = "TPVR window frame"
        if let event = frame.event {
            commands.encodeWaitForEvent(Unmanaged<AnyObject>.fromOpaque(event).takeUnretainedValue() as! MTLSharedEvent,
                                        value: frame.value)
        }
        if frame.generation != surfaceGeneration {
            surfaces.removeAll()
            surfaceGeneration = frame.generation
        }
        if encode(frame, into: commands) {
            root.isEnabled = true
        }
        Self.framesInFlight.add(1, ordering: .relaxed)
        // A test dump reads the frame once the GPU is done with it (the game's work on it included:
        // the slot is handed over when submitted, not finished), before it goes back.
        let dumping = dumpThisFrame
        dumpThisFrame = false
        commands.addCompletedHandler { _ in
            if dumping { Self.dump(frame) }
            dusk_visionos_window_release(serial)
            Self.framesInFlight.subtract(1, ordering: .relaxed)
        }
        commands.commit()
        frames += 1
        if frames == 1 || frames % 900 == 0 {
            print("[TPVR] window frame \(frames): scene \(frame.scene != nil), ui \(frame.ui != nil), "
                  + "tangents \(frame.tan_half_x) x \(frame.tan_half_y), focus \(frame.focus), effects \(effects.isEnabled)")
        }
    }

    /// Window frames (the game's) a second since the last call, for the memory log.
    private func frameRate() -> String {
        let now = CACurrentMediaTime()
        defer { rateMark = (now, frames) }
        guard now > rateMark.time else { return "-" }
        return String(format: "%.0f", Double(frames - rateMark.frames) / (now - rateMark.time))
    }
    private var rateMark = (time: CACurrentMediaTime(), frames: 0)

    /// The game's fade (sRGB colour and cover) as the HUD pass lays it on the glass, premultiplied in
    /// linear light. The game blends it on the encoded values (out = e x (1 - a) + f x a, aurora's
    /// targets aren't sRGB), so a linear cover of `a` came out lighter than the game's mid-fade. The
    /// colour is what the fade leaves over black, and the cover what it takes from white, the most
    /// of the three channels: exact over black and over white.
    private static func fadeCover(_ frame: dusk_visionos_window_frame) -> SIMD4<Float> {
        let linear = { (c: Float) -> Float in c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let a = min(max(frame.fade_a, 0), 1)
        guard a > 0 else { return .zero }
        let fade = SIMD3(frame.fade_r, frame.fade_g, frame.fade_b)
        let colour = SIMD3((0..<3).map { linear(fade[$0] * a) })
        let cover = (0..<3).map { 1 + colour[$0] - linear(1 - a + fade[$0] * a) }.max() ?? a
        let clamped = min(max(cover, 0), 1)
        return SIMD4(simd_min(colour, SIMD3(repeating: clamped)), clamped)
    }

    /// The frame surfaces' sizes, for the memory log: they follow the game's internal resolution.
    private var surfaceSizes: String {
        Set(surfaces.values.map { "\($0.width)x\($0.height)" }).sorted().joined(separator: ", ")
    }

    /// Memory ran away (WindowMemoryGuard): the mirror goes, its textures and mesh with it, and the
    /// window shows the game's own picture, as it does before the mirror's first frame.
    private func dropMirror() {
        dusk_visionos_set_mirror_enabled(false)
        mirror?.root.removeFromParent()
        mirror = nil
        mirrorShowing = false
        effects.isEnabled = false
        effects.model = nil
        effectsTexture = nil
        effectsMesh = nil
    }

    // MARK: - One frame

    private func encode(_ frame: dusk_visionos_window_frame, into commands: MTLCommandBuffer) -> Bool {
        guard let final = texture(frame.final, format: .bgra8Unorm_srgb) else { return false }
        let ui = texture(frame.ui, format: .bgra8Unorm_srgb)
        let size = SIMD2(final.width, final.height)
        let frameAspect = Float(size.x) / Float(max(size.y, 1))
        if abs(frameAspect - aspect) > 0.01 {
            aspect = frameAspect
            makePlanes(aspect: aspect)
            aspectChanged?(aspect)
        }
        if size != hudSize, !makeHud(size: size) { return false }
        guard let hudTexture else { return false }
        let hud = hudTexture.replace(using: commands)

        guard let scene = texture(frame.scene, format: .bgra8Unorm_srgb),
              let distance = texture(frame.distance, format: .rgba16Float),
              frame.tan_half_x > 0, frame.tan_half_y > 0 else {
            // No 3D scene (title, loading, films): the whole picture is flat on the glass.
            pipelines.flat(commands, final: final, ui: ui, hud: hud)
            pipelines.mipmaps(commands, hud)
            primary?.isEnabled = false
            backstop?.isEnabled = false
            effects.isEnabled = false
            return true
        }
        if mirrorShowing, let mirror {
            // The mirror draws the world; the HUD and the screen effects come from the frame.
            // The picture before the screen effects: what turned black (fades, letterbox bars) is
            // found from it and goes on the glass, with or without the effects' layer.
            let base = texture(frame.base, format: .bgra8Unorm_srgb)
            var layer: MTLTexture?
            if base != nil, let effectsTexture, let effectsMesh, mirror.plane > 1 {
                layer = effectsTexture.replace(using: commands)
                // Laid out as the mirror is: the glass spans the camera's view at the mirror's plane.
                var params = EffectsGridParams(tanHalf: [frame.tan_half_x, frame.tan_half_y], planeDistance: mirror.plane,
                                               columns: UInt32(effectsGrid.x), rows: UInt32(effectsGrid.y), radius: 8,
                                               depthScale: mirror.depthScale)
                pipelines.effectsGrid(commands, distance: distance, params: &params,
                                      positions: effectsMesh.replace(bufferIndex: 0, using: commands))
            }
            // The screen effects on the surfaces themselves (the mirror's materials read them where
            // each surface is in the camera's picture), unless their test layer is on. The game's
            // fade stays on the glass (it covers what the camera never saw too: past its view, the
            // window's foot): the glow is worked out from the scene with the fade taken out.
            let glowing = Self.glowEffects && layer == nil && base != nil
            let fade = SIMD4(frame.fade_r, frame.fade_g, frame.fade_b, frame.fade_a)
            pipelines.glow(commands, scene: scene, base: glowing ? base : nil, fade: fade,
                           glow: mirror.glowTarget(using: commands))
            pipelines.hud(commands, final: final, scene: scene, base: base, ui: ui, hud: hud, effects: layer,
                          fade: Self.fadeCover(frame), ghost: Self.ghostEffects)
            pipelines.mipmaps(commands, hud)
            effects.isEnabled = layer != nil
            primary?.isEnabled = false
            backstop?.isEnabled = false
            if Self.dumpFrame == frames || dumpingNow {
                dumpingNow = false
                dumpThisFrame = true
            }
            return true
        }
        let sceneSize = SIMD2(scene.width, scene.height)
        if sceneSize != colourSize || primaryMesh == nil, !makeRelief(size: sceneSize) { return false }
        guard let colour, let primaryMesh, let backstopMesh, let distances else { return false }
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: scene, to: colour.replace(using: commands))
            blit.endEncoding()
        }
        // (The relief's picture, from `scene`, has the game's fade in it already.)
        pipelines.hud(commands, final: final, scene: scene, base: nil, ui: ui, hud: hud, effects: nil)
        pipelines.mipmaps(commands, hud)
        effects.isEnabled = false
        var params = ReliefParams(frame: frame, columns: grid.x, rows: grid.y)
        pipelines.relief(commands, distance: distance, params: &params,
                         primary: primaryMesh.replace(bufferIndex: 0, using: commands),
                         backstop: backstopMesh.replace(bufferIndex: 0, using: commands),
                         backstopUVs: backstopMesh.replace(bufferIndex: 1, using: commands),
                         distances: distances, indices: primaryMesh.replaceIndices(using: commands))
        primary?.isEnabled = Self.shownLayers.contains("p")
        backstop?.isEnabled = Self.shownLayers.contains("b")
        if Self.dumpFrame == frames {
            dumpThisFrame = true
        }
        return true
    }

    // Test runs: TPVR_TEST_WINDOW_LAYERS=p or =b shows only that layer of the relief.
    private static let shownLayers: String = {
        let shown = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_LAYERS"] ?? ""
        return shown.isEmpty ? "pb" : shown
    }()

    // The screen effects' layer (bloom, mist, light shafts on a grid draped over the game's depths)
    // is off: from anywhere but the game camera's own eye point it came apart from the 3D scene, a
    // ghost of each figure's glow beside it and faint streaks fanning back from every silhouette
    // (the grid stretched along the view rays there). Fades and letterbox bars stay, on the glass
    // with the HUD. Test runs: TPVR_TEST_WINDOW_EFFECTS=1 brings the layer back; =ghost puts the
    // game's own picture in it at half opacity (one Link if it lines up, two if not).
    private static let showEffects = ["1", "ghost"].contains(ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_EFFECTS"] ?? "")
    private static let ghostEffects = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_EFFECTS"] == "ghost"
    // The screen effects (bloom and its tints above all: TP's warm glow, Link's house's golden haze)
    // on the mirror's surfaces, each where the camera saw it (Pipelines.glow): without them the
    // window looked like the game with its lighting turned down ("like shaders turned off",
    // Trevor). Unlike the layer above, nothing floats off the surfaces: from the side a glow stays
    // on what it lit. Test runs: TPVR_TEST_WINDOW_GLOW=0 leaves them out, as before.
    private static let glowEffects = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_GLOW"] != "0"

    // Test runs: TPVR_TEST_WINDOW_DUMP=<frame> writes that frame's scene, finished frame and (with
    // the mirror) pre-effects scene (BGRA8) and distances (RGBA16F) raw into Documents, named with
    // their sizes.
    private static let dumpFrame = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_DUMP"].flatMap(Int.init) ?? -1
    private static let dumpAt = ProcessInfo.processInfo.environment["TPVR_TEST_DUMP_AT"].flatMap(Double.init)
    private let opened = CACurrentMediaTime()
    private var dumpedAt = false, dumpingNow = false, dumpThisFrame = false

    nonisolated private static func dump(_ frame: dusk_visionos_window_frame) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for (name, pointer) in [("scene", frame.scene), ("distance", frame.distance), ("final", frame.final),
                                ("base", frame.base)] {
            guard let pointer else { continue }
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
            IOSurfaceLock(surface, .readOnly, nil)
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            let rowBytes = IOSurfaceGetBytesPerRow(surface), element = IOSurfaceGetBytesPerElement(surface)
            var data = Data(capacity: width * height * element)
            let base = IOSurfaceGetBaseAddress(surface)
            for row in 0..<height {
                data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: width * element)
            }
            IOSurfaceUnlock(surface, .readOnly, nil)
            try? data.write(to: documents.appendingPathComponent("window-\(name)-\(width)x\(height).raw"))
        }
        print("[TPVR] window frame dumped: tangents \(frame.tan_half_x) x \(frame.tan_half_y), focus \(frame.focus)")
    }

    /// A Metal texture over one of the game's IOSurfaces, made once per surface.
    private func texture(_ pointer: UnsafeMutableRawPointer?, format: MTLPixelFormat) -> MTLTexture? {
        guard let pointer else { return nil }
        let key = UInt(bitPattern: pointer)
        if let cached = surfaces[key] { return cached }
        let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        surfaces[key] = texture
        return texture
    }

    // MARK: - Scene objects

    private func makePlanes(aspect: Float) {
        portal.removeFromParent()
        hud.removeFromParent()
        let height = 1 / aspect
        portal = ModelEntity(mesh: .generatePlane(width: 1, height: height), materials: [PortalMaterial()])
        // Not clipped at the glass, as in the SHAR port: what the mirror has nearer than the glass
        // (TP's pitched-down ground towards the camera) comes out in front of it, inside the
        // window's opening, its straight lines straight (compressed in depth to stay within
        // frontAllowance, the nearest cut off). Clipped there, it had to be squashed into a band
        // behind the glass, which bent the ground. Test runs: AURORA_MIRROR_BAND=1 clips again (and
        // brings back the band).
        if ProcessInfo.processInfo.environment["AURORA_MIRROR_BAND"] == "1" {
            portal.components.set(PortalComponent(target: world,
                                                  clippingMode: .plane(.init(position: .zero, normal: [0, 0, 1])),
                                                  crossingMode: .disabled))
        } else {
            portal.components.set(PortalComponent(target: world))
        }
        // The whole face is a target for pinches and taps (GameWindowView's gesture), so they stop here.
        portal.components.set(InputTargetComponent())
        portal.components.set(CollisionComponent(shapes: [.generateBox(width: 1, height: height, depth: 0.004)]))
        hud = ModelEntity(mesh: .generatePlane(width: 1, height: height), materials: [hudMaterial])
        // In the portal's world, on the glass, last in the sort group: the level's sort group can
        // order only what's in the same world.
        hud.position.z = -0.0005  // behind the glass: AURORA_MIRROR_BAND's clip takes what's in front
        hud.components.set(ModelSortGroupComponent(group: sortGroup, order: Self.effectsOrder + 1))
        root.addChild(portal)
        world.addChild(hud)
    }

    private func makeHud(size: SIMD2<Int>) -> Bool {
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: size.x, height: size.y,
                                                    textureUsage: [.shaderRead, .shaderWrite])
        // The HUD with mipmaps, made by the GPU each frame (Pipelines.mipmaps): written at up to 3x
        // the game's resolution and shown on a window that covers far fewer pixels, it aliased
        // without them, worst with the window small, far off or seen at an angle. Its pixels are
        // premultiplied, so the averaging keeps edges clean.
        let levels = Int(log2(Double(max(size.x, size.y)))) + 1
        let hudDescriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: size.x, height: size.y,
                                                       mipmapLevelCount: levels,
                                                       textureUsage: [.shaderRead, .shaderWrite, .renderTarget])
        guard let texture = try? LowLevelTexture(descriptor: hudDescriptor),
              let resource = try? TextureResource(from: texture) else {
            print("[TPVR] the window's \(size.x)x\(size.y) HUD texture failed")
            return false
        }
        try? hudMaterial.setParameter(name: "Frame", value: .textureResource(resource))
        hud.model?.materials = [hudMaterial]
        hudTexture = texture
        hudSize = size
        let rows = Self.rows
        let columns = max(16, Int((Float(rows) * Float(size.x) / Float(max(size.y, 1))).rounded()))
        if mirror != nil, Self.showEffects, let layer = try? LowLevelTexture(descriptor: descriptor),
           let layerResource = try? TextureResource(from: layer),
           let mesh = try? Self.makeGridMesh(columns: columns, rows: rows),
           let meshResource = try? MeshResource(from: mesh) {
            try? effectsMaterial.setParameter(name: "Frame", value: .textureResource(layerResource))
            effects.model = ModelComponent(mesh: meshResource, materials: [effectsMaterial])
            effectsTexture = layer
            effectsMesh = mesh
            effectsGrid = [columns, rows]
        } else {
            effectsTexture = nil
            effectsMesh = nil
        }
        return true
    }

    private func makeRelief(size: SIMD2<Int>) -> Bool {
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: size.x, height: size.y,
                                                    textureUsage: [.shaderRead])
        let rows = Self.rows
        let columns = max(16, Int((Float(rows) * Float(size.x) / Float(max(size.y, 1))).rounded()))
        guard let texture = try? LowLevelTexture(descriptor: descriptor),
              let resource = try? TextureResource(from: texture),
              let primaryMesh = try? Self.makeMesh(columns: columns, rows: rows),
              let backstopMesh = try? Self.makeMesh(columns: columns, rows: rows),
              let primaryResource = try? MeshResource(from: primaryMesh),
              let backstopResource = try? MeshResource(from: backstopMesh),
              let distances = device.makeBuffer(length: (columns + 3) * (rows + 3) * MemoryLayout<SIMD2<Float>>.stride,
                                                options: .storageModePrivate) else {
            print("[TPVR] the window's \(size.x)x\(size.y) relief failed")
            return false
        }
        try? reliefMaterial.setParameter(name: "Frame", value: .textureResource(resource))
        primary?.removeFromParent()
        backstop?.removeFromParent()
        let primary = ModelEntity(mesh: primaryResource, materials: [reliefMaterial])
        let backstop = ModelEntity(mesh: backstopResource, materials: [reliefMaterial])
        world.addChild(backstop)
        world.addChild(primary)
        self.primary = primary
        self.backstop = backstop
        self.primaryMesh = primaryMesh
        self.backstopMesh = backstopMesh
        self.distances = distances
        colour = texture
        colourSize = size
        grid = [columns, rows]
        return true
    }

    /// The screen effects' layer: (columns + 1) x (rows + 1) vertices over the picture, positions from
    /// the GPU each frame, UVs fixed.
    private static func makeGridMesh(columns: Int, rows: Int) throws -> LowLevelMesh {
        let across = columns + 1, down = rows + 1
        let indexCount = columns * rows * 6
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: across * down,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 12), .init(bufferIndex: 1, bufferStride: 8)],
            indexCapacity: indexCount, indexType: .uint32)
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uvs = raw.bindMemory(to: SIMD2<Float>.self)
            for row in 0..<down {
                for column in 0..<across {
                    uvs[row * across + column] = [Float(column) / Float(columns), 1 - Float(row) / Float(rows)]
                }
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            var next = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    // Two counter-clockwise triangles, facing the viewer.
                    let topLeft = UInt32(row * across + column), bottomLeft = topLeft + UInt32(across)
                    for index in [topLeft, bottomLeft, topLeft + 1, topLeft + 1, bottomLeft, bottomLeft + 1] {
                        indices[next] = index
                        next += 1
                    }
                }
            }
        }
        let bounds = BoundingBox(min: [-60, -40, -60], max: [60, 40, 1])
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indexCount, topology: .triangle, bounds: bounds)])
        return mesh
    }

    /// A relief layer: (columns + 3) x (rows + 3) vertices, the grid and a skirt ring past its edge.
    /// Positions come from the GPU each frame; UVs are fixed (the skirt's at the picture's edge);
    /// the indices start with every cell, which the backstop keeps and the primary cuts each frame.
    private static func makeMesh(columns: Int, rows: Int) throws -> LowLevelMesh {
        let across = columns + 3, down = rows + 3
        let vertexCount = across * down, indexCount = (across - 1) * (down - 1) * 6
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: vertexCount,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 12), .init(bufferIndex: 1, bufferStride: 8)],
            indexCapacity: indexCount, indexType: .uint32)
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uvs = raw.bindMemory(to: SIMD2<Float>.self)
            for row in 0..<down {
                let v = Float(min(max(row - 1, 0), rows)) / Float(rows)
                for column in 0..<across {
                    let u = Float(min(max(column - 1, 0), columns)) / Float(columns)
                    uvs[row * across + column] = [u, 1 - v]
                }
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            var next = 0
            for row in 0..<(down - 1) {
                for column in 0..<(across - 1) {
                    // Two counter-clockwise triangles, facing the viewer.
                    let topLeft = UInt32(row * across + column), bottomLeft = topLeft + UInt32(across)
                    for index in [topLeft, bottomLeft, topLeft + 1, topLeft + 1, bottomLeft, bottomLeft + 1] {
                        indices[next] = index
                        next += 1
                    }
                }
            }
        }
        // Generous bounds, in window units: tighter ones (still enclosing every vertex) blacked out
        // the whole window, HUD and all, in the Simulator.
        let bounds = BoundingBox(min: [-60, -40, -60], max: [60, 40, 1])
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indexCount, topology: .triangle, bounds: bounds)])
        return mesh
    }
}

/// Mirrors `ReliefParams` in the shader. The game's camera, in game units: what it looks at
/// (`focus`) sits a little behind the window's face, so the scene recedes into the window and
/// nothing stands out of it (the portal would cut it off).
struct ReliefParams {
    var tanHalf: SIMD2<Float>
    var planeDistance: Float
    var nearest: Float
    var farthest: Float
    var skirt: Float = 0.6
    var cutRatio: Float = 1.12
    var push: Float = 0.05
    /// Neighbouring pixels further apart than this ratio are an occlusion edge.
    var edgeRatio: Float = 1.06
    /// A step between samples a cell apart this large is a foreground object's edge.
    var jumpRatio: Float = 1.25
    /// A depth step whose sides shift apart by less than this (relative to the window's distance)
    /// as the head moves is left whole.
    var minParallax: Float = 0.05
    var columns: UInt32
    var rows: UInt32

    /// How deep the relief reaches behind the window's face, in window widths.
    static let maxDepth: Float = 3
    /// Test runs: TPVR_TEST_WINDOW_FLAT=1 lays the picture flat on the glass.
    static let testFlat = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_FLAT"] == "1"

    /// The narrowest view the relief is laid out for (half-width as a tangent): the picture is
    /// exact from 1 / (2 * this) window widths in front of the glass, and anyone farther away never
    /// sees past its edges. A telephoto shot (the attract demo zooms to 0.25) is re-framed to this,
    /// keeping its depths in proportion; wider views keep the game's own geometry.
    static let minViewTangent: Float = 0.7

    init(frame: dusk_visionos_window_frame, columns: Int, rows: Int) {
        let viewX = max(frame.tan_half_x, Self.minViewTangent)
        tanHalf = [viewX, viewX * frame.tan_half_y / frame.tan_half_x]
        let focus = frame.focus.isFinite && frame.focus > 1 ? frame.focus : 600
        planeDistance = min(max(focus * 0.85, 100), 4000)
        nearest = planeDistance
        // At most `maxDepth` window widths behind the glass, whatever the camera's zoom: beyond
        // that stereo depth is barely perceptible, while a deeper relief (a telephoto shot put the
        // sky 80 widths back) opens wide gaps for any viewer off the picture's sweet spot.
        farthest = planeDistance * (1 + Self.maxDepth * 2 * viewX)
        if Self.testFlat {
            farthest = planeDistance * 1.001  // test runs: the picture alone, for comparison
        }
        self.columns = UInt32(columns)
        self.rows = UInt32(rows)
    }
}

private struct EffectsGridParams {
    var tanHalf: SIMD2<Float>
    var planeDistance: Float
    var columns: UInt32
    var rows: UInt32
    var radius: UInt32
    var depthScale: Float
}

private struct GlowFlags {
    var fade: SIMD4<Float>
    var hasBase: UInt32
}

private struct HudFlags {
    var hasUi: UInt32
    var hasBase: UInt32
    var ghost: UInt32
    var writeEffects: UInt32
    var fade: SIMD4<Float>  // the game's fade on the glass: linear colour times cover, then cover
}

/// The window's Metal kernels (adapted from the SHAR port's visionos_window.mm).
@MainActor
private struct Pipelines {
    let relief, cut, hud, flat, effectsGrid, glow: MTLComputePipelineState

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func make(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw CancellationError() }
            return try device.makeComputePipelineState(function: function)
        }
        relief = try make("WindowRelief")
        cut = try make("WindowCut")
        hud = try make("WindowHud")
        flat = try make("WindowFlat")
        effectsGrid = try make("WindowEffectsGrid")
        glow = try make("WindowGlow")
    }

    func relief(_ commands: MTLCommandBuffer, distance: MTLTexture, params: inout ReliefParams,
                primary: MTLBuffer, backstop: MTLBuffer, backstopUVs: MTLBuffer, distances: MTLBuffer,
                indices: MTLBuffer) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        let across = Int(params.columns) + 3, down = Int(params.rows) + 3
        compute.setComputePipelineState(relief)
        compute.setTexture(distance, index: 0)
        compute.setBuffer(primary, offset: 0, index: 0)
        compute.setBuffer(backstop, offset: 0, index: 1)
        compute.setBuffer(distances, offset: 0, index: 2)
        compute.setBytes(&params, length: MemoryLayout<ReliefParams>.stride, index: 3)
        compute.setBuffer(backstopUVs, offset: 0, index: 4)
        compute.dispatchThreads(MTLSize(width: across, height: down, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.setComputePipelineState(cut)
        compute.setBuffer(distances, offset: 0, index: 0)
        compute.setBuffer(indices, offset: 0, index: 1)
        compute.setBytes(&params, length: MemoryLayout<ReliefParams>.stride, index: 2)
        compute.dispatchThreads(MTLSize(width: across - 1, height: down - 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    /// The HUD over the scene, and (given `base`, the scene before the screen effects, and an
    /// `effects` target) what those effects did to it.
    func hud(_ commands: MTLCommandBuffer, final: MTLTexture, scene: MTLTexture, base: MTLTexture?, ui: MTLTexture?,
             hud: MTLTexture, effects: MTLTexture?, fade: SIMD4<Float> = .zero, ghost: Bool = false) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        let writeEffects = base != nil && effects != nil
        // With the effects' layer on, the fade is in it.
        var flags = HudFlags(hasUi: ui != nil ? 1 : 0, hasBase: base != nil ? 1 : 0,
                             ghost: ghost ? 1 : 0, writeEffects: writeEffects ? 1 : 0,
                             fade: writeEffects ? .zero : fade)
        compute.setComputePipelineState(self.hud)
        compute.setTexture(final, index: 0)
        compute.setTexture(scene, index: 1)
        compute.setTexture(ui ?? final, index: 2)
        compute.setTexture(hud, index: 3)
        compute.setTexture(base ?? scene, index: 4)
        compute.setTexture(effects ?? hud, index: 5)
        compute.setBytes(&flags, length: MemoryLayout<HudFlags>.stride, index: 0)
        compute.dispatchThreads(MTLSize(width: hud.width, height: hud.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    /// The rest of `texture`'s mipmaps from its level 0, on the GPU.
    func mipmaps(_ commands: MTLCommandBuffer, _ texture: MTLTexture) {
        guard texture.mipmapLevelCount > 1, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
    }

    /// The screen effects (what turned `base` into `scene`, the game's `fade` aside: sRGB colour and
    /// cover) as a premultiplied layer, at the glow texture's size, for the mirror's materials; empty
    /// without a `base`. The fade and what turned black (bars) are left to the glass, as the HUD pass
    /// lays them.
    func glow(_ commands: MTLCommandBuffer, scene: MTLTexture, base: MTLTexture?, fade: SIMD4<Float>, glow: MTLTexture) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        var flags = GlowFlags(fade: fade, hasBase: base != nil ? 1 : 0)
        compute.setComputePipelineState(self.glow)
        compute.setTexture(scene, index: 0)
        compute.setTexture(base ?? scene, index: 1)
        compute.setTexture(glow, index: 2)
        compute.setBytes(&flags, length: MemoryLayout<GlowFlags>.stride, index: 0)
        compute.dispatchThreads(MTLSize(width: glow.width, height: glow.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    func effectsGrid(_ commands: MTLCommandBuffer, distance: MTLTexture, params: inout EffectsGridParams,
                     positions: MTLBuffer) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(effectsGrid)
        compute.setTexture(distance, index: 0)
        compute.setBuffer(positions, offset: 0, index: 0)
        compute.setBytes(&params, length: MemoryLayout<EffectsGridParams>.stride, index: 1)
        compute.dispatchThreads(MTLSize(width: Int(params.columns) + 1, height: Int(params.rows) + 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    func flat(_ commands: MTLCommandBuffer, final: MTLTexture, ui: MTLTexture?, hud: MTLTexture) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        var hasUi: UInt32 = ui != nil ? 1 : 0
        compute.setComputePipelineState(flat)
        compute.setTexture(final, index: 0)
        compute.setTexture(ui ?? final, index: 1)
        compute.setTexture(hud, index: 2)
        compute.setBytes(&hasUi, length: 4, index: 0)
        compute.dispatchThreads(MTLSize(width: hud.width, height: hud.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ReliefParams {
        float2 tanHalf;
        float planeDistance, nearest, farthest, skirt, cutRatio, push, edgeRatio, jumpRatio, minParallax;
        uint columns, rows;
    };

    // How far apart two distances move as the viewer's head moves, relative to the window: a step
    // between far terrain and the sky hardly shifts, and isn't worth a cut.
    static float Parallax(float near, float far, constant ReliefParams& p)
    {
        return (1.0 / near - 1.0 / far) * p.planeDistance;
    }

    // One vertex of the grid, in both layers, in window units along its pixel's ray from the
    // game's camera. The primary takes the nearest distance in the cell either side, which keeps a
    // foreground edge's pixels on the foreground; the backstop, which only shows where the primary
    // is cut, takes the background's. A skirt vertex takes the edge's distance, further out, so looking
    // in at an angle shows the picture's edge stretched rather than nothing.
    kernel void WindowRelief(texture2d<float, access::read> distance [[texture(0)]],
                             device packed_float3* primary [[buffer(0)]],
                             device packed_float3* backstop [[buffer(1)]],
                             device float2* distances [[buffer(2)]],
                             constant ReliefParams& p [[buffer(3)]],
                             device float2* backstopUVs [[buffer(4)]],
                             uint2 id [[thread_position_in_grid]])
    {
        const uint across = p.columns + 3, down = p.rows + 3;
        if (id.x >= across || id.y >= down) return;
        const uint2 cell = uint2(clamp(int2(id) - 1, int2(0), int2(p.columns, p.rows)));
        const float u = float(cell.x) / float(p.columns), v = float(cell.y) / float(p.rows);
        const float2 skirt = float2(id.x == 0 ? -1.0 : id.x == across - 1 ? 1.0 : 0.0,
                                    id.y == 0 ? 1.0 : id.y == down - 1 ? -1.0 : 0.0) * p.skirt;
        const int2 size = int2(distance.get_width(), distance.get_height());
        const int2 centre = int2(float2(u, v) * float2(size - 1) + 0.5);
        const int2 reach = int2(ceil(float2(size) / float2(p.columns, p.rows)));
        // The nearest distance in the window, and whether the window holds an occlusion edge: a
        // jump between two neighbouring pixels. A surface seen at a glancing angle (the ground
        // towards the horizon) changes distance quickly across a cell but smoothly pixel to pixel,
        // and must not be cut.
        float nearest = p.farthest;
        bool edge = false;
        for (int y = -reach.y; y <= reach.y; ++y)
        {
            float left = 0;
            for (int x = -reach.x; x <= reach.x; ++x)
            {
                const uint2 at = uint2(clamp(centre + int2(x, y), int2(0), size - 1));
                const float raw = distance.read(at).r;
                const float d = isfinite(raw) && raw > 0 ? min(raw, p.farthest) : p.farthest;
                nearest = min(nearest, d);
                if (x > -reach.x && max(d, left) > min(d, left) * p.edgeRatio) edge = true;
                if (y < reach.y)
                {
                    const uint2 below = uint2(clamp(centre + int2(x, y + 1), int2(0), size - 1));
                    const float rawBelow = distance.read(below).r;
                    const float b = isfinite(rawBelow) && rawBelow > 0 ? min(rawBelow, p.farthest) : p.farthest;
                    if (max(d, b) > min(d, b) * p.edgeRatio) edge = true;
                }
                left = d;
            }
        }
        nearest = clamp(nearest, p.nearest, p.farthest);
        // The backstop fills what the primary can't show from the side: the background behind a
        // foreground object, which the game never drew. Where this vertex is on something with a
        // farther surface beside it, walk out (left, right, up, down; a cell at a time) to the
        // nearest depth jump and take the background just past it, its distance and its colour:
        // the background continued behind the object, at the background's depth. Anywhere else
        // (the ground, the sky, the background itself) it is the primary pushed a little back.
        float backDistance = nearest * (1.0 + p.push);
        float2 backUV = float2(u, 1.0 - v);
        const float own = distance.read(uint2(centre)).r;
        if (isfinite(own) && own > 0 && own < p.farthest)
        {
            int best = 1 << 30;
            const int2 directions[4] = {int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1)};
            for (uint k = 0; k < 4; ++k)
            {
                float previous = own;
                for (int step = 1; step <= 64 && step < best; ++step)
                {
                    const int2 at = centre + directions[k] * reach * step;
                    if (any(at < 0) || any(at >= size)) break;
                    const float raw = distance.read(uint2(at)).r;
                    const float d = isfinite(raw) && raw > 0 ? min(raw, p.farthest) : p.farthest;
                    if (d < previous / p.jumpRatio) break;  // something nearer: not behind us
                    if (d > previous * p.jumpRatio && Parallax(previous, d, p) > p.minParallax)
                    {
                        // Past the edge: one cell further, clear of its antialiased pixels.
                        const int2 past = clamp(at + directions[k] * reach, int2(0), size - 1);
                        const float rawPast = distance.read(uint2(past)).r;
                        const float behind = isfinite(rawPast) && rawPast > 0 ? min(rawPast, p.farthest) : d;
                        best = step;
                        backDistance = max(behind, nearest) * (1.0 + p.push);
                        // Within two cells of the edge the backstop keeps its own colour: that is
                        // where the primary is cut, so seen from the front it must be the picture.
                        // Deeper in, hidden from the front, it takes the background's.
                        backUV = step <= 2 ? float2(u, 1.0 - v)
                                           : float2(float(past.x) / float(size.x - 1),
                                                    1.0 - float(past.y) / float(size.y - 1));
                        break;
                    }
                    previous = d;
                }
            }
        }
        backDistance = min(backDistance, p.farthest * (1.0 + p.push));
        const float tanX = mix(-p.tanHalf.x, p.tanHalf.x, u) + skirt.x;
        const float tanY = mix(p.tanHalf.y, -p.tanHalf.y, v) + skirt.y;
        const float scale = 1.0 / (2.0 * p.planeDistance * p.tanHalf.x);
        const uint index = id.y * across + id.x;
        primary[index] = packed_float3(scale * tanX * nearest, scale * tanY * nearest,
                                       scale * (p.planeDistance - nearest));
        // Along its own pixel's ray (so it sits behind the primary), coloured from the background.
        backstop[index] = packed_float3(scale * tanX * backDistance, scale * tanY * backDistance,
                                        scale * (p.planeDistance - backDistance));
        backstopUVs[index] = id.x == 0 || id.y == 0 || id.x == across - 1 || id.y == down - 1
                                 ? float2(u, 1.0 - v) : backUV;
        distances[index] = float2(nearest, edge ? 1.0 : 0.0);
    }

    // The primary layer's two triangles per cell, or degenerate ones where the cell spans a depth
    // step (cut out, so the backstop shows there instead of a foreground smeared onto the back).
    kernel void WindowCut(device const float2* distances [[buffer(0)]],
                          device uint* indices [[buffer(1)]],
                          constant ReliefParams& p [[buffer(2)]],
                          uint2 id [[thread_position_in_grid]])
    {
        const uint across = p.columns + 3, down = p.rows + 3;
        if (id.x >= across - 1 || id.y >= down - 1) return;
        const uint topLeft = id.y * across + id.x, bottomLeft = topLeft + across;
        const float2 a = distances[topLeft], b = distances[topLeft + 1];
        const float2 c = distances[bottomLeft], d = distances[bottomLeft + 1];
        const float low = min(min(a.x, b.x), min(c.x, d.x)), high = max(max(a.x, b.x), max(c.x, d.x));
        const bool edge = a.y + b.y + c.y + d.y > 0;
        device uint* out = indices + (id.y * (across - 1) + id.x) * 6;
        if (edge && high > low * p.cutRatio && Parallax(low, high, p) > p.minParallax)
        {
            for (uint i = 0; i < 6; ++i) out[i] = topLeft;
        }
        else
        {
            out[0] = topLeft; out[1] = bottomLeft; out[2] = topLeft + 1;
            out[3] = topLeft + 1; out[4] = bottomLeft; out[5] = bottomLeft + 1;
        }
    }

    // Premultiplied `over`.
    static float4 Over(float4 top, float4 under) { return top + under * (1.0 - top.a); }

    // A pixel the HUD changed, as the least cover `a` and premultiplied colour `c` that explain it:
    // after = before * (1 - a) + c. A translucent panel or a soft glow over the 3D then keeps the
    // window's own 3D under it, as the game's scene was, instead of the scene as the game's camera
    // saw it, pinned opaque to the glass (the bright halos behind ITEMS and MAP); an opaque pixel
    // comes out opaque. (Linear values: the views are sRGB.)
    static float4 HudCover(float3 before, float3 after)
    {
        float a = 0.0;
        for (int i = 0; i < 3; ++i)
        {
            if (after[i] > before[i]) a = max(a, (after[i] - before[i]) / max(1.0 - before[i], 1e-4));
            else if (after[i] < before[i]) a = max(a, (before[i] - after[i]) / max(before[i], 1e-4));
        }
        a = saturate(a);
        return float4(clamp(after - before * (1.0 - a), 0.0, a), a);
    }

    // The screen effects (bloom, mist, light shafts, fades, letterbox bars): what they did to the
    // game's 3D picture, as a premultiplied layer over the window's own 3D. The picture went from
    // `before` to `after`; as `after = before * (1 - a) + e` the layer takes the least cover `a`
    // that leaves `e` no darker than black, so a glow only adds light, a fade only covers, and from
    // straight ahead the window matches the game exactly. (Linear values: the views are sRGB.)
    static float4 Effects(float3 after, float3 before)
    {
        if (all(after == before)) return float4(0);
        if (all(after < 1e-4)) return float4(0, 0, 0, 1);  // black: a fade's end, letterbox bars
        // Darkening within a step or two of 8-bit noise doesn't count as cover.
        const float3 slack = 0.004 + 0.02 * after;
        const float3 kept = (after + slack) / max(before, 1e-4);
        const float a = saturate(1.0 - min(min(kept.r, kept.g), kept.b));
        return float4(max(after - before * (1.0 - a), 0.0), a);
    }

    struct HudFlags { uint hasUi, hasBase, ghost, writeEffects; float4 fade; };

    // The screen effects for the mirror's materials (gen-mirror-materials.py): each texel of the
    // layer from the pictures before and after them, filtered where it falls. The layer reaches
    // past the camera's view by GlowReach (each side), for surfaces seen only from the side, and
    // fades out there: what the effects did depends on the colour under them (TP's bloom brightens
    // dark colours more than light ones), so laid on what the camera never saw, the edge's (or the
    // picture's average) tinted it (Link's house's floor went green at the window's edge). Clamped
    // to the edge before that, it streaked. Empty without `base`; what turned black is the glass's
    // (WindowHud).
    constant float GlowReach = 1.25;

    struct GlowFlags { float4 fade; uint hasBase; };

    static float3 Encoded(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }
    static float3 Decoded(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }

    kernel void WindowGlow(texture2d<float, access::sample> scene [[texture(0)]],
                           texture2d<float, access::sample> base [[texture(1)]],
                           texture2d<float, access::write> glow [[texture(2)]],
                           constant GlowFlags& flags [[buffer(0)]],
                           uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= glow.get_width() || id.y >= glow.get_height()) return;
        float4 effect = float4(0);
        if (flags.hasBase != 0 && flags.fade.a < 0.995)
        {
            // In the camera's view, -1..1 across, +1 at the top; the picture's own 0..1, top down.
            const float2 view = ((float2(id) + 0.5) / float2(glow.get_width(), glow.get_height()) * 2.0 - 1.0)
                                * float2(GlowReach, -GlowReach);
            const float2 at = saturate(float2(0.5 + 0.5 * view.x, 0.5 - 0.5 * view.y));
            constexpr sampler linear(filter::linear, address::clamp_to_edge);
            const float3 before = base.sample(linear, at).rgb;
            // The scene without the game's fade, which it blends on the encoded values (fadeCover).
            const float3 faded = Encoded(saturate(scene.sample(linear, at).rgb));
            const float3 after = Decoded(saturate((faded - flags.fade.rgb * flags.fade.a) / (1.0 - flags.fade.a)));
            effect = Effects(after, before);
            if (effect.a > 0.999 && all(effect.rgb < 0.0005)) effect = float4(0);
            // Where a channel came out white, the glow can't show in it: TP's warm bloom over a
            // red-saturated rug added only green and blue, and laid on the floor a side view shows
            // beside it, that turned it green. Such a channel takes at least the next one's glow
            // (red at least green's, green at least blue's): on that white channel itself it changes
            // nothing.
            const bool3 white = after > 0.99;
            if (white.r) effect.r = max(effect.r, effect.g);
            if (white.g) effect.g = max(effect.g, effect.b);
            effect *= 1.0 - saturate((max(abs(view.x), abs(view.y)) - 1.0) / (GlowReach - 1.0));
        }
        glow.write(effect, id);
    }

    struct EffectsGridParams { float2 tanHalf; float planeDistance; uint columns, rows, radius; float depthScale; };

    // The screen effects' layer, laid out as the scene mirror is (the glass spans the camera's view
    // at planeDistance, depths times depthScale): each vertex at the nearest distance within
    // `radius` pixels, so a glow just outside a figure stays on the figure; never in front of the
    // glass.
    kernel void WindowEffectsGrid(texture2d<float, access::read> distance [[texture(0)]],
                                  device packed_float3* positions [[buffer(0)]],
                                  constant EffectsGridParams& p [[buffer(1)]],
                                  uint2 id [[thread_position_in_grid]])
    {
        if (id.x > p.columns || id.y > p.rows) return;
        const float u = float(id.x) / float(p.columns), v = float(id.y) / float(p.rows);
        const int2 size = int2(distance.get_width(), distance.get_height());
        const int2 centre = int2(float2(u, v) * float2(size));
        const int r = int(p.radius), step = max(1, r / 2);
        float nearest = 1e9;
        for (int dy = -r; dy <= r; dy += step)
        {
            for (int dx = -r; dx <= r; dx += step)
            {
                const int2 at = clamp(centre + int2(dx, dy), int2(0), size - 1);
                nearest = min(nearest, distance.read(uint2(at)).r);
            }
        }
        // A hair behind the glass at the least (when the portal clips at the glass, AURORA_MIRROR_BAND=1,
        // what's on it is cut away).
        nearest = clamp(nearest, p.planeDistance * 1.0005, 60000.0);
        const float tanX = mix(-p.tanHalf.x, p.tanHalf.x, u), tanY = mix(p.tanHalf.y, -p.tanHalf.y, v);
        const float scale = 1.0 / (2.0 * p.planeDistance * p.tanHalf.x);
        positions[id.y * (p.columns + 1) + id.x] = packed_float3(scale * tanX * nearest, scale * tanY * nearest,
                                                                 scale * p.depthScale * (p.planeDistance - nearest));
    }

    // The HUD is whatever the game drew over its scene: pixels the 2D pass changed, as the least
    // cover that explains each (HudCover), over what covers the glass beneath it (the game's fade,
    // and what turned black: letterbox bars, a fade's end), with Dusklight's menus (premultiplied)
    // over all that. With the mirror's effects' layer on, the screen effects go to it.
    kernel void WindowHud(texture2d<float, access::read> final [[texture(0)]],
                          texture2d<float, access::read> scene [[texture(1)]],
                          texture2d<float, access::read> ui [[texture(2)]],
                          texture2d<float, access::write> hud [[texture(3)]],
                          texture2d<float, access::read> base [[texture(4)]],
                          texture2d<float, access::write> effects [[texture(5)]],
                          constant HudFlags& flags [[buffer(0)]],
                          uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= hud.get_width() || id.y >= hud.get_height()) return;
        const float4 drawn = final.read(id), under = scene.read(id);
        const bool changed = any(abs(drawn.rgb - under.rgb) > 0.004);
        // What covers the glass under the HUD: the game's fade over its 3D scene, then what turned
        // black (below).
        float4 glass = flags.fade;
        if (flags.hasBase != 0)
        {
            const uint2 at = uint2(float2(id) * float2(base.get_width(), base.get_height()) /
                                   float2(hud.get_width(), hud.get_height()));
            float4 effect = flags.ghost != 0 ? float4(under.rgb * 0.5, 0.5) : Effects(under.rgb, base.read(at).rgb);
            // What turns black (letterbox bars, a fade's end) covers the window itself, on the glass.
            // Only that: a depth of field darkening the dark rocks behind Ilia, laid on the glass,
            // covered half her face from the side; a partial fade is the same at any depth.
            if (flags.ghost == 0 && effect.a > 0.999 && all(effect.rgb < 0.0005))
            {
                glass = Over(float4(0, 0, 0, effect.a), glass);
                effect = float4(0);
            }
            // The effects' own layer, when it's on (TPVR_TEST_WINDOW_EFFECTS); the black ones above
            // go on the glass either way.
            if (flags.writeEffects != 0) effects.write(effect, id);
        }
        // The HUD the game drew over all that: over black, exactly the game's pixel.
        float4 colour = changed ? Over(HudCover(under.rgb, drawn.rgb), glass) : glass;
        if (flags.hasUi != 0)
        {
            const uint2 at = uint2(float2(id) * float2(ui.get_width(), ui.get_height()) /
                                   float2(hud.get_width(), hud.get_height()));
            colour = Over(ui.read(at), colour);
        }
        hud.write(colour, id);
    }

    // No 3D scene (title, loading, films): the whole picture, flat on the glass.
    kernel void WindowFlat(texture2d<float, access::read> final [[texture(0)]],
                           texture2d<float, access::read> ui [[texture(1)]],
                           texture2d<float, access::write> hud [[texture(2)]],
                           constant uint& hasUi [[buffer(0)]],
                           uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= hud.get_width() || id.y >= hud.get_height()) return;
        float4 colour = float4(final.read(id).rgb, 1);
        if (hasUi != 0)
        {
            const uint2 at = uint2(float2(id) * float2(ui.get_width(), ui.get_height()) /
                                   float2(hud.get_width(), hud.get_height()));
            colour = Over(ui.read(at), colour);
        }
        hud.write(colour, id);
    }
    """
}
