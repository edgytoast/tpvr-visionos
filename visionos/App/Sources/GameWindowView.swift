import Metal
import RealityKit
import SwiftUI

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
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minWidth: 640, idealWidth: 1280, maxWidth: 4096, minHeight: 300, idealHeight: 720, maxHeight: 2304)
        .onAppear {
            let openWindow = openWindow
            model.showLauncher = { openWindow(id: GameModel.launcherWindowID) }
            model.startWindowGame()
            // Out of the way while you play, as with the immersive spaces.
            dismissWindow(id: GameModel.launcherWindowID)
        }
        .onDisappear {
            // Closing the window ends the game (it saves first), and with it the app.
            model.windowClosed()
        }
        .onChange(of: scenePhase) { _, phase in
            // Hidden or in the background: hold the game clock, as taking the headset off does
            // in the immersive spaces.
            dusk_visionos_set_paused(phase != .active)
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
    private var reliefMaterial: ShaderGraphMaterial
    private var hudMaterial: ShaderGraphMaterial
    private var primary: ModelEntity?, backstop: ModelEntity?
    private var primaryMesh: LowLevelMesh?, backstopMesh: LowLevelMesh?
    private var colour: LowLevelTexture?, hudTexture: LowLevelTexture?
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

    private static let rows = 216

    init() async throws {
        var relief = try await ShaderGraphMaterial(named: "/Root/ReliefFrame", from: "WindowFrame.usda", in: .main)
        // Seen from the side, a stretch across a depth step can face away; it still hides what's behind.
        relief.faceCulling = .none
        reliefMaterial = relief
        hudMaterial = try await ShaderGraphMaterial(named: "/Root/HudFrame", from: "WindowFrame.usda", in: .main)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CancellationError()
        }
        self.device = device
        self.queue = queue
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
                self.mirror = mirror
                dusk_visionos_set_mirror_enabled(true)
            } catch {
                print("[TPVR] the scene mirror failed to load, so the window shows the relief: \(error)")
                dusk_visionos_set_mirror_enabled(false)
            }
        }
    }

    /// Window units onto the window: its face is the back of the view's bounds (visionOS clips what
    /// stands out of a window), scaled to its width in metres.
    static func fit(_ root: Entity, to bounds: BoundingBox) {
        root.position = [bounds.center.x, bounds.center.y, bounds.min.z]
        root.scale = SIMD3(repeating: bounds.extents.x)
        // Test runs: TPVR_TEST_WINDOW_TILT=<degrees> turns the window about its vertical axis, which
        // shows the relief from the side without moving the Simulator's camera.
        if let tilt = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_TILT"].flatMap(Float.init) {
            root.orientation = simd_quatf(angle: tilt * .pi / 180, axis: [0, 1, 0])
        }
    }

    func update() {
        dusk_visionos_window_tick()
        mirrorShowing = mirror?.update() ?? false
        var frame = dusk_visionos_window_frame()
        guard dusk_visionos_window_acquire(&frame) else { return }
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
        commands.addCompletedHandler { _ in dusk_visionos_window_release(serial) }
        commands.commit()
        frames += 1
        if frames == 1 || frames % 900 == 0 {
            print("[TPVR] window frame \(frames): scene \(frame.scene != nil), ui \(frame.ui != nil), "
                  + "tangents \(frame.tan_half_x) x \(frame.tan_half_y), focus \(frame.focus)")
        }
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
            primary?.isEnabled = false
            backstop?.isEnabled = false
            return true
        }
        if mirrorShowing {
            // The mirror draws the world; only the HUD comes from the frame.
            pipelines.hud(commands, final: final, scene: scene, ui: ui, hud: hud)
            primary?.isEnabled = false
            backstop?.isEnabled = false
            return true
        }
        let sceneSize = SIMD2(scene.width, scene.height)
        if sceneSize != colourSize || primaryMesh == nil, !makeRelief(size: sceneSize) { return false }
        guard let colour, let primaryMesh, let backstopMesh, let distances else { return false }
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: scene, to: colour.replace(using: commands))
            blit.endEncoding()
        }
        pipelines.hud(commands, final: final, scene: scene, ui: ui, hud: hud)
        var params = ReliefParams(frame: frame, columns: grid.x, rows: grid.y)
        pipelines.relief(commands, distance: distance, params: &params,
                         primary: primaryMesh.replace(bufferIndex: 0, using: commands),
                         backstop: backstopMesh.replace(bufferIndex: 0, using: commands),
                         backstopUVs: backstopMesh.replace(bufferIndex: 1, using: commands),
                         distances: distances, indices: primaryMesh.replaceIndices(using: commands))
        primary?.isEnabled = Self.shownLayers.contains("p")
        backstop?.isEnabled = Self.shownLayers.contains("b")
        if Self.dumpFrame == frames {
            Self.dump(frame)
        }
        return true
    }

    // Test runs: TPVR_TEST_WINDOW_LAYERS=p or =b shows only that layer of the relief.
    private static let shownLayers: String = {
        let shown = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_LAYERS"] ?? ""
        return shown.isEmpty ? "pb" : shown
    }()

    // Test runs: TPVR_TEST_WINDOW_DUMP=<frame> writes that frame's scene (BGRA8) and distances
    // (RGBA16F) raw into Documents, named with their sizes.
    private static let dumpFrame = ProcessInfo.processInfo.environment["TPVR_TEST_WINDOW_DUMP"].flatMap(Int.init) ?? -1

    private static func dump(_ frame: dusk_visionos_window_frame) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for (name, pointer) in [("scene", frame.scene), ("distance", frame.distance), ("final", frame.final)] {
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
        // Clipped at the glass, as a real window is (the side towards the viewer, +z, goes): nothing
        // of the mirror's level may come out between the window and the viewer.
        portal.components.set(PortalComponent(target: world,
                                              clippingMode: .plane(.init(position: .zero, normal: [0, 0, 1])),
                                              crossingMode: .disabled))
        hud = ModelEntity(mesh: .generatePlane(width: 1, height: height), materials: [hudMaterial])
        hud.position.z = 0.002
        root.addChild(portal)
        root.addChild(hud)
    }

    private func makeHud(size: SIMD2<Int>) -> Bool {
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: size.x, height: size.y,
                                                    textureUsage: [.shaderRead, .shaderWrite])
        guard let texture = try? LowLevelTexture(descriptor: descriptor),
              let resource = try? TextureResource(from: texture) else {
            print("[TPVR] the window's \(size.x)x\(size.y) HUD texture failed")
            return false
        }
        try? hudMaterial.setParameter(name: "Frame", value: .textureResource(resource))
        hud.model?.materials = [hudMaterial]
        hudTexture = texture
        hudSize = size
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

/// The window's Metal kernels (adapted from the SHAR port's visionos_window.mm).
@MainActor
private struct Pipelines {
    let relief, cut, hud, flat: MTLComputePipelineState

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

    func hud(_ commands: MTLCommandBuffer, final: MTLTexture, scene: MTLTexture, ui: MTLTexture?, hud: MTLTexture) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        var hasUi: UInt32 = ui != nil ? 1 : 0
        compute.setComputePipelineState(self.hud)
        compute.setTexture(final, index: 0)
        compute.setTexture(scene, index: 1)
        compute.setTexture(ui ?? final, index: 2)
        compute.setTexture(hud, index: 3)
        compute.setBytes(&hasUi, length: 4, index: 0)
        compute.dispatchThreads(MTLSize(width: hud.width, height: hud.height, depth: 1),
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

    // The HUD is whatever the game drew over its scene: pixels the 2D pass changed, opaque in their
    // final colour (a translucent panel keeps the scene it was blended with). Dusklight's menus
    // (premultiplied) go over it.
    kernel void WindowHud(texture2d<float, access::read> final [[texture(0)]],
                          texture2d<float, access::read> scene [[texture(1)]],
                          texture2d<float, access::read> ui [[texture(2)]],
                          texture2d<float, access::write> hud [[texture(3)]],
                          constant uint& hasUi [[buffer(0)]],
                          uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= hud.get_width() || id.y >= hud.get_height()) return;
        const float4 drawn = final.read(id), under = scene.read(id);
        const bool changed = any(abs(drawn.rgb - under.rgb) > 0.004);
        float4 colour = changed ? float4(drawn.rgb, 1) : float4(0);
        if (hasUi != 0)
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
