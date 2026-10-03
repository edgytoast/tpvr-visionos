import Metal
import QuartzCore
import RealityKit

/// The window's scene mirror: the game's own 3D draws, rebuilt each frame as one RealityKit mesh,
/// so RealityKit renders Hyrule from the viewer's real eyes and the window shows it from any angle,
/// with nothing to fill in behind Link however far you lean. The approach is the SHAR port's scene
/// mirror; the game side is aurora's (extern/aurora/lib/gx/mirror.cpp), which decodes each GX draw
/// on the CPU: vertices in the camera's view space, the TEV combine reduced to texture x colour +
/// colour per vertex, textures as RGBA.
///
/// One mesh with a part per material, refilled each frame (RealityKit's cost is in refilling a
/// mesh, not in its size: SHAR measured ~0.14 ms a mesh). Sits in the portal's world, placed so
/// the game's camera is where a viewer's eye would be for the picture to be exact: the window spans
/// the camera's view at a little short of its focus distance (so Link stands behind the glass).
@MainActor
final class MirrorScene {
    let root = Entity()
    private let entity = ModelEntity()
    // Behind everything: where the game drew nothing the mirror can show (past the edges of its
    // view, seen from the side), black, as the game's own picture is, not the room.
    private let backdrop = ModelEntity(mesh: .generatePlane(width: 1, height: 1),
                                       materials: [UnlitMaterial(color: .black)])
    private var mesh: (mesh: LowLevelMesh, resource: MeshResource)?
    private let queue: MTLCommandQueue

    // MirrorMaterials(Wrap).usda: kind ("Opaque", "Cutout", "Blend") + wrap ("RR", "CC"...).
    private var templates: [String: ShaderGraphMaterial] = [:]
    private var textures: [UInt64: TextureResource] = [:]
    // Their textures, for the ones the game updates (shadows read back each frame).
    private var lowLevelTextures: [UInt64: LowLevelTexture] = [:]
    private var failedTextures: Set<UInt64> = []
    private struct PendingTexture { let id: UInt64; let pixels: Data; let width: Int; let height: Int; let mipmapped: Bool; let cutout: Bool }
    private var pendingTextures: [PendingTexture] = []
    private var wantedTextures: Set<UInt64> = []
    private var texturesArrived = false
    private var white: TextureResource?
    private var materials: [MaterialKey: ShaderGraphMaterial] = [:]
    // The entity's material list, which the parts index; it grows as materials appear, and is set
    // again only then (setting it may cost RealityKit's renderer a frame).
    private var materialList: [MaterialKey] = []
    private var materialIndex: [MaterialKey: Int] = [:]
    private var materialReady: [Bool] = []
    private var serial: UInt64 = 0
    private(set) var hasScene = false
    /// The view distance the glass is at (game units), as last placed.
    private(set) var plane: Float = 1
    /// How much depths are compressed for a narrow view (1 for a normal one), as last placed.
    private(set) var depthScale: Float = 1
    private static let cullTest = ProcessInfo.processInfo.environment["TPVR_TEST_MIRROR_CULL"] ?? ""
    private static let addRed = ProcessInfo.processInfo.environment["TPVR_TEST_MIRROR_ADD_RED"] == "1"

    private var timing = (updates: 0, frames: 0, seconds: 0.0, since: CACurrentMediaTime(), vertices: 0, parts: 0, total: 0)
    private var counts = (texturesMade: 0, texturesFailed: 0, materialSets: 0)
    // Of an update's time: filling the mesh, and setting its parts (where RealityKit waits for its
    // renderer: a mesh with more vertex attributes doubled it).
    private var stages = (fill: 0.0, parts: 0.0)

    private struct MaterialKey: Hashable {
        var texture: UInt64
        var kind: UInt32
        var wrap: String
        var flags: UInt32
        var cutoff: UInt8
        var weights: SIMD8<Int8>

        init(_ part: dusk_visionos_mirror_part) {
            texture = part.texture
            kind = part.kind
            let letter = { (mode: UInt8) in mode == UInt8(DUSK_MIRROR_WRAP_CLAMP) ? "C" : mode == UInt8(DUSK_MIRROR_WRAP_MIRROR) ? "M" : "R" }
            wrap = letter(part.wrap_s) + letter(part.wrap_t)
            flags = part.flags & (DUSK_MIRROR_CULL_BACK | DUSK_MIRROR_CULL_FRONT | DUSK_MIRROR_DEPTH_WRITE | DUSK_MIRROR_DEPTH_TEST
                                  | DUSK_MIRROR_BACKGROUND)
            cutoff = part.kind == DUSK_MIRROR_PART_CUTOUT ? UInt8(clamping: Int((part.cutoff * 255).rounded())) : 0
            let quantise = { (value: Float) in Int8(clamping: Int((value * 16).rounded())) }
            weights = part.kind == DUSK_MIRROR_PART_BLEND
                ? SIMD8(quantise(part.colour_base), quantise(part.colour_alpha), quantise(part.opacity_base),
                        quantise(part.opacity_alpha), quantise(part.opacity_luma), 0, 0, 0)
                : .zero
        }
    }

    init() async throws {
        guard let queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue() else { throw CancellationError() }
        self.queue = queue
        for kind in ["Opaque", "Cutout", "Blend"] {
            templates[kind + "RR"] = try await ShaderGraphMaterial(named: "/Root/Mirror\(kind)_RR", from: "MirrorMaterials.usda", in: .main)
        }
        // The other wrap modes, separately: without them, textures repeat.
        do {
            for wrap in ["RC", "RM", "CR", "CC", "CM", "MR", "MC", "MM"] {
                for kind in ["Opaque", "Cutout", "Blend"] {
                    templates[kind + wrap] = try await ShaderGraphMaterial(
                        named: "/Root/Mirror\(kind)_\(wrap)", from: "MirrorMaterialsWrap.usda", in: .main)
                }
            }
        } catch {
            print("[TPVR] mirror: clamped and mirrored texture materials failed to load, so they repeat: \(error)")
        }
        white = Self.makeTexture(queue: queue, pixels: [255, 255, 255, 255], width: 1, height: 1)
        entity.isEnabled = false
        root.addChild(entity)
        backdrop.isEnabled = false
        root.addChild(backdrop)
    }

    /// Draws the level as `order` in `group`, so that what the window lays over it comes after.
    func sort(in group: ModelSortGroup, order: Int32) {
        entity.components.set(ModelSortGroupComponent(group: group, order: order))
    }

    /// Takes the game's newest mirror frame no later than game frame `upTo` (the window frame shown
    /// with it) into the mesh. False while there's no 3D scene to show (the window then shows the
    /// game's flat picture).
    func update(upTo: UInt32) -> Bool {
        let start = CACurrentMediaTime()
        defer { report(start) }
        var frame = dusk_visionos_mirror_frame()
        guard dusk_visionos_mirror_acquire(&frame, upTo) else { return false }
        takeTextures(frame, start: start)
        guard frame.serial != serial else { return hasScene }
        serial = frame.serial
        timing.frames += 1
        timing.total += 1
        guard frame.scene, frame.index_count > 0, frame.part_count > 0, frame.tan_half_x > 0,
              let vertices = frame.vertices, let indices = frame.indices, let parts = frame.parts else {
            entity.isEnabled = false
            backdrop.isEnabled = false
            hasScene = false
            return false
        }
        let fillStart = CACurrentMediaTime()
        let filled = fill(vertices: vertices, vertexCount: Int(frame.vertex_count), indices: indices,
                          indexCount: Int(frame.index_count))
        stages.fill += CACurrentMediaTime() - fillStart
        guard filled, let (mesh, _) = mesh else { return hasScene }

        let keys = (0..<Int(frame.part_count)).map { MaterialKey(parts[$0]) }
        updateMaterials(keys)
        let low = SIMD3(frame.bounds_min.0, frame.bounds_min.1, frame.bounds_min.2)
        let high = SIMD3(frame.bounds_max.0, frame.bounds_max.1, frame.bounds_max.2)
        let pad = (high - low) * 0.05 + 1
        let bounds = BoundingBox(min: low - pad, max: high + pad)
        // A part whose texture is still on its way waits: drawn white, it flashed.
        let partsStart = CACurrentMediaTime()
        defer { stages.parts += CACurrentMediaTime() - partsStart }
        mesh.parts.replaceAll((0..<Int(frame.part_count)).compactMap { index in
            let part = parts[index]
            guard let materialIndex = materialIndex[keys[index]], materialReady[materialIndex] else {
                wantedTextures.insert(keys[index].texture)
                return nil
            }
            return LowLevelMesh.Part(indexOffset: Int(part.first_index) * 4, indexCount: Int(part.index_count),
                                     topology: .triangle, materialIndex: materialIndex, bounds: bounds)
        })
        place(frame)
        if Self.dumpFrame == timing.total {
            dump(frame)
        }
        entity.isEnabled = true
        backdrop.isEnabled = true
        hasScene = true
        timing.vertices += Int(frame.vertex_count)
        timing.parts += Int(frame.part_count)
        return true
    }

    /// View space into window units: the window spans the camera's view at the frame's `plane` (a
    /// little short of its focus, nothing nearer), so the camera sits 1 / (2 tan) window widths in
    /// front of the glass. A narrower view than ReliefParams.minViewTangent (a cutscene's telephoto
    /// shot) has its depths compressed to the picture it would have from a camera that close, which
    /// is the same picture; left as it was, its camera sat two window widths out and anyone nearer
    /// saw past the edges of what the game drew.
    private func place(_ frame: dusk_visionos_mirror_frame) {
        let plane = max(frame.plane, 1)
        let tan = frame.tan_half_x
        let depthScale = tan / max(tan, ReliefParams.minViewTangent)
        self.plane = plane
        self.depthScale = depthScale
        let scale = 1 / (2 * plane * tan)
        root.scale = SIMD3(scale, scale, scale * depthScale)
        root.position = [0, 0, scale * depthScale * plane]
        let far = max(-frame.bounds_min.2, plane) * 1.05
        let wide = 2 * far * max(tan, ReliefParams.minViewTangent) * 8
        backdrop.position = [0, 0, -far]
        backdrop.scale = [wide, wide, 1]
    }

    // MARK: - The mesh

    /// position float3, uv0 float2, the multiplier half4 (vertex colour), the addend half2 x 2
    /// (uv1, uv2): aurora::mirror::Vertex.
    private static func descriptor(vertices: Int, indices: Int) -> LowLevelMesh.Descriptor {
        LowLevelMesh.Descriptor(
            vertexCapacity: vertices,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 12),
                               .init(semantic: .color, format: .half4, layoutIndex: 0, offset: 20),
                               .init(semantic: .uv1, format: .half2, layoutIndex: 0, offset: 28),
                               .init(semantic: .uv2, format: .half2, layoutIndex: 0, offset: 32)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 36)],
            indexCapacity: indices, indexType: .uint32)
    }

    private func fill(vertices: UnsafePointer<dusk_visionos_mirror_vertex>, vertexCount: Int,
                      indices: UnsafePointer<UInt32>, indexCount: Int) -> Bool {
        let fits = mesh.map { $0.mesh.vertexCapacity >= vertexCount && $0.mesh.indexCapacity >= indexCount } ?? false
        if !fits {
            do {
                let made = try LowLevelMesh(descriptor: Self.descriptor(
                    vertices: max(65536, vertexCount.nextPowerOfTwo), indices: max(131072, indexCount.nextPowerOfTwo)))
                let resource = try MeshResource(from: made)
                mesh = (made, resource)
                if entity.model == nil {
                    entity.model = ModelComponent(mesh: resource, materials: [])
                } else {
                    entity.model?.mesh = resource
                }
            } catch {
                print("[TPVR] mirror: a mesh of \(vertexCount) vertices failed: \(error)")
                return false
            }
        }
        guard let (mesh, _) = mesh else { return false }
        // Into fresh buffers RealityKit swaps in once written (SHAR: written in place, the
        // headset's renderer drew between the vertices and the indices).
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: vertices, count: vertexCount * 36))
            // Test runs: TPVR_TEST_MIRROR_ADD_RED=1 makes every vertex mul 0, add opaque red: the
            // window should be solid red where the mirror draws (it checks uv1/uv2 reach the materials).
            if Self.addRed {
                let red: [UInt16] = [0, 0, 0, 0, 0x3C00, 0, 0, 0x3C00]  // half 1.0 = 0x3C00
                for index in 0..<vertexCount {
                    let at = raw.baseAddress! + index * 36 + 20
                    red.withUnsafeBytes { at.copyMemory(from: $0.baseAddress!, byteCount: 16) }
                }
            }
        }
        mesh.replaceUnsafeMutableIndices { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: indices, count: indexCount * 4))
        }
        return true
    }

    // MARK: - Materials

    private func updateMaterials(_ keys: [MaterialKey]) {
        var changed = false
        // Counting new materials, not parts: blended parts in the game's order repeat theirs, and
        // counting parts cleared and set the list every frame of a busy scene (SHAR's review), which
        // may cost the renderer a frame of the whole level.
        let fresh = Set(keys).filter { materialIndex[$0] == nil }.count
        if materialList.count + fresh > 1024 {
            materialList = []
            materialIndex = [:]
            materialReady = []
            changed = true
        }
        if texturesArrived {
            texturesArrived = false
            changed = changed || materialList.indices.contains { !materialReady[$0] && material(for: materialList[$0]) != nil }
        }
        for key in keys where materialIndex[key] == nil {
            materialIndex[key] = materialList.count
            materialList.append(key)
            changed = true
        }
        guard changed else { return }
        counts.materialSets += 1
        materialReady = materialList.map { material(for: $0) != nil }
        entity.model?.materials = materialList.map { material(for: $0) ?? templates["OpaqueRR"]! }
    }

    private func material(for key: MaterialKey) -> ShaderGraphMaterial? {
        if let made = materials[key] { return made }
        let texture = key.texture == 0 || failedTextures.contains(key.texture) ? white : textures[key.texture]
        guard let texture else { return nil }
        let kind = key.kind == DUSK_MIRROR_PART_CUTOUT ? "Cutout" : key.kind == DUSK_MIRROR_PART_BLEND ? "Blend" : "Opaque"
        guard var made = templates[kind + key.wrap] ?? templates[kind + "RR"] else { return nil }
        try? made.setParameter(name: "Frame", value: .textureResource(texture))
        switch key.kind {
        case DUSK_MIRROR_PART_CUTOUT:
            try? made.setParameter(name: "Cutoff", value: .float(Float(max(key.cutoff, 1)) / 255))
        case DUSK_MIRROR_PART_BLEND:
            for (index, name) in ["ColourBase", "ColourAlpha", "OpacityBase", "OpacityAlpha", "OpacityLuma"].enumerated() {
                try? made.setParameter(name: name, value: .float(Float(key.weights[index]) / 16))
            }
            // Blended surfaces hide what's behind them only where the game's do.
            made.writesDepth = key.flags & DUSK_MIRROR_DEPTH_WRITE != 0
        default:
            break
        }
        // A blend the game draws without a depth test draws over everything, except the sky's
        // layers: pushed behind the level, the level hides them where it stands.
        made.readsDepth = key.flags & (DUSK_MIRROR_DEPTH_TEST | DUSK_MIRROR_BACKGROUND) != 0 || key.kind != DUSK_MIRROR_PART_BLEND
        made.faceCulling = key.flags & DUSK_MIRROR_CULL_BACK != 0 ? .back
            : key.flags & DUSK_MIRROR_CULL_FRONT != 0 ? .front : .none
        // Test runs: TPVR_TEST_MIRROR_CULL=none draws both sides, =flip culls the other side.
        switch Self.cullTest {
        case "none": made.faceCulling = .none
        case "flip": made.faceCulling = made.faceCulling == .back ? .front : made.faceCulling == .front ? .back : .none
        default: break
        }
        if materials.count > 4096 { materials.removeAll(keepingCapacity: true) }
        materials[key] = made
        return made
    }

    // MARK: - Textures

    private func takeTextures(_ frame: dusk_visionos_mirror_frame, start: CFTimeInterval) {
        if let list = frame.textures {
            for index in 0..<Int(frame.texture_count) {
                let texture = list[index]
                let count = Int(texture.width) * Int(texture.height) * 4
                guard let rgba = texture.rgba, count > 0 else { continue }
                // New pixels for one already made (a shadow, each frame): replaced in place.
                if let existing = lowLevelTextures[texture.id], existing.descriptor.width == Int(texture.width),
                   existing.descriptor.height == Int(texture.height), existing.descriptor.mipmapLevelCount == 1 {
                    Self.upload(queue: queue, pixels: rgba, width: Int(texture.width), height: Int(texture.height), into: existing)
                    continue
                }
                let pending = PendingTexture(id: texture.id, pixels: Data(bytes: rgba, count: count),
                                             width: Int(texture.width), height: Int(texture.height),
                                             mipmapped: texture.mipmapped, cutout: texture.cutout)
                // A newer read-back of one still waiting replaces it.
                if let waiting = pendingTextures.firstIndex(where: { $0.id == texture.id }) {
                    pendingTextures[waiting] = pending
                } else {
                    pendingTextures.append(pending)
                }
            }
        }
        // After the new ones: a texture can arrive and be gone in the same frame. An area's
        // textures go together, a few hundred at once: one pass over each collection.
        if let removed = frame.removed, frame.removed_count > 0 {
            let gone = Set((0..<Int(frame.removed_count)).map { removed[$0] })
            for id in gone {
                textures[id] = nil
                lowLevelTextures[id] = nil
                failedTextures.remove(id)
            }
            pendingTextures.removeAll { gone.contains($0.id) }
            materials = materials.filter { !gone.contains($0.key.texture) }
        }
        // Wanted ones first, then a few milliseconds' worth an update, at least one.
        if !wantedTextures.isEmpty {
            let wanted = pendingTextures.filter { wantedTextures.contains($0.id) }
            pendingTextures = wanted + pendingTextures.filter { !wantedTextures.contains($0.id) }
            wantedTextures.removeAll()
        }
        var made = 0
        while !pendingTextures.isEmpty && (made == 0 || CACurrentMediaTime() - start < 0.004) {
            let pending = pendingTextures.removeFirst()
            if Self.dumpFrame >= 0 {
                dumpTextures[pending.id] = pending
            }
            // Read back again before its first was made: into the texture already there.
            if let existing = lowLevelTextures[pending.id], existing.descriptor.width == pending.width,
               existing.descriptor.height == pending.height, existing.descriptor.mipmapLevelCount == 1, !pending.mipmapped {
                pending.pixels.withUnsafeBytes {
                    Self.upload(queue: queue, pixels: $0.bindMemory(to: UInt8.self).baseAddress!, width: pending.width,
                                height: pending.height, into: existing)
                }
                made += 1
                continue
            }
            if let (lowLevel, resource) = makeTexture(pending) {
                textures[pending.id] = resource
                lowLevelTextures[pending.id] = lowLevel
                counts.texturesMade += 1
            } else {
                failedTextures.insert(pending.id)
                counts.texturesFailed += 1
            }
            texturesArrived = true
            made += 1
        }
    }

    private func makeTexture(_ texture: PendingTexture) -> (LowLevelTexture, TextureResource)? {
        let levels = texture.mipmapped && texture.cutout ? Self.coverageMipmaps(texture) : nil
        return (levels ?? texture.pixels).withUnsafeBytes {
            Self.makeTexture(queue: queue, pixels: $0.baseAddress!, width: texture.width, height: texture.height,
                             mipmapped: texture.mipmapped, levelsIncluded: levels != nil)
        }
    }

    private static func makeTexture(queue: MTLCommandQueue, pixels: [UInt8], width: Int, height: Int) -> TextureResource? {
        pixels.withUnsafeBytes { makeTexture(queue: queue, pixels: $0.baseAddress!, width: width, height: height)?.1 }
    }

    /// New level-zero pixels into a texture already made.
    private static func upload(queue: MTLCommandQueue, pixels: UnsafePointer<UInt8>, width: Int, height: Int,
                               into texture: LowLevelTexture) {
        guard let staging = queue.device.makeBuffer(bytes: pixels, length: width * height * 4) else {
            report("a \(width)x\(height) texture update: no staging buffer")
            return
        }
        blit(staging, into: texture, sizes: [(width, height)], generate: false, queue: queue,
             label: "a \(width)x\(height) texture update")
    }

    /// The staging buffer's levels into the texture (the GPU making the rest with `generate`). One the
    /// GPU reports failing is tried again, once, into the same texture, so what draws it needn't
    /// change. (The SHAR port's headset-only "black void", ground and sky gone, was failed uploads
    /// the Simulator never showed: they'd have gone unnoticed here.)
    @discardableResult
    private static func blit(_ staging: MTLBuffer, into texture: LowLevelTexture, sizes: [(Int, Int)], generate: Bool,
                             queue: MTLCommandQueue, label: String, retries: Int = 1) -> Bool {
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            report("\(label): no command buffer")
            return false
        }
        let destination = texture.replace(using: commands)
        var offset = 0
        for (level, (levelWidth, levelHeight)) in sizes.enumerated() {
            blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: levelWidth * 4,
                      sourceBytesPerImage: levelWidth * levelHeight * 4,
                      sourceSize: MTLSize(width: levelWidth, height: levelHeight, depth: 1), to: destination,
                      destinationSlice: 0, destinationLevel: level, destinationOrigin: MTLOrigin())
            offset += levelWidth * levelHeight * 4
        }
        if generate { blit.generateMipmaps(for: destination) }
        blit.endEncoding()
        commands.addCompletedHandler { done in
            guard let error = done.error else { return }
            let message = "\(label): upload failed\(retries > 0 ? ", trying again" : ""): \(error)"
            DispatchQueue.main.async {
                report(message)
                if retries > 0 {
                    Self.blit(staging, into: texture, sizes: sizes, generate: generate, queue: queue, label: label,
                              retries: retries - 1)
                }
            }
        }
        commands.commit()
        return true
    }

    // The first few failures, word for word.
    private static var reports = 0
    private static func report(_ message: String) {
        reports += 1
        if reports <= 20 { print("[TPVR] mirror: \(message)") }
    }

    /// RGBA8 (sRGB) into a texture, its mipmaps made by the GPU or, with `levelsIncluded`, given
    /// one after another in `pixels`.
    private static func makeTexture(queue: MTLCommandQueue, pixels: UnsafeRawPointer, width: Int, height: Int,
                                    mipmapped: Bool = false, levelsIncluded: Bool = false) -> (LowLevelTexture, TextureResource)? {
        let levels = mipmapped ? Int(log2(Double(max(width, height)))) + 1 : 1
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height,
                                                    mipmapLevelCount: levels, textureUsage: [.shaderRead, .renderTarget])
        let label = "a \(width)x\(height) texture"
        let texture: LowLevelTexture
        do { texture = try LowLevelTexture(descriptor: descriptor) } catch {
            report("\(label): LowLevelTexture failed: \(error)")
            return nil
        }
        let sizes = (0..<(levelsIncluded ? levels : 1)).map { (max(1, width >> $0), max(1, height >> $0)) }
        guard let staging = queue.device.makeBuffer(bytes: pixels, length: sizes.reduce(0) { $0 + $1.0 * $1.1 * 4 }) else {
            report("\(label): no staging buffer")
            return nil
        }
        // (It reports its own failures.)
        guard Self.blit(staging, into: texture, sizes: sizes, generate: levels > 1 && !levelsIncluded, queue: queue,
                        label: label) else { return nil }
        do { return (texture, try TextureResource(from: texture)) } catch {
            report("\(label): TextureResource failed: \(error)")
            return nil
        }
    }

    /// A cut-out texture's mipmaps (SHAR's): each texel the alpha-weighted mean of the four below
    /// it, its alpha scaled so as many texels pass a half alpha test as at full size. A box filter
    /// alone thins foliage with distance, and its edges shimmer.
    private static func coverageMipmaps(_ texture: PendingTexture) -> Data? {
        var width = texture.width, height = texture.height
        guard width > 1 || height > 1 else { return nil }
        var level = [UInt8](texture.pixels)
        let covered = { (pixels: [UInt8], scale: Float) -> Int in
            stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (Float(pixels[$1]) * scale >= 127.5 ? 1 : 0) }
        }
        let coverage = Float(covered(level, 1)) / Float(width * height)
        var chain = Data(level)
        while width > 1 || height > 1 {
            let nextWidth = max(1, width / 2), nextHeight = max(1, height / 2)
            var next = [UInt8](repeating: 0, count: nextWidth * nextHeight * 4)
            for y in 0..<nextHeight {
                for x in 0..<nextWidth {
                    var colour = SIMD3<Float>.zero, plain = SIMD3<Float>.zero, alpha: Float = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let at = (min(y * 2 + dy, height - 1) * width + min(x * 2 + dx, width - 1)) * 4
                        let texel = SIMD3<Float>(Float(level[at]), Float(level[at + 1]), Float(level[at + 2]))
                        let a = Float(level[at + 3])
                        colour += texel * a
                        plain += texel
                        alpha += a
                    }
                    let rgb = alpha > 0 ? colour / alpha : plain / 4
                    let at = (y * nextWidth + x) * 4
                    next[at] = UInt8(rgb.x.rounded())
                    next[at + 1] = UInt8(rgb.y.rounded())
                    next[at + 2] = UInt8(rgb.z.rounded())
                    next[at + 3] = UInt8((alpha / 4).rounded())
                }
            }
            var low: Float = 0, high: Float = 8
            for _ in 0..<12 {
                let middle = (low + high) / 2
                if Float(covered(next, middle)) / Float(nextWidth * nextHeight) < coverage { low = middle } else { high = middle }
            }
            for at in stride(from: 3, to: next.count, by: 4) { next[at] = UInt8(min(255, (Float(next[at]) * high).rounded())) }
            chain.append(contentsOf: next)
            (level, width, height) = (next, nextWidth, nextHeight)
        }
        return chain
    }

    // MARK: - Test runs

    // TPVR_TEST_MIRROR_DUMP=<frame> writes that mirror frame raw into Documents/mirror-dump:
    // vertices.bin (36-byte vertices), indices.bin (u32), parts.txt, camera.txt, and the
    // textures made so far (tex-<id>-<w>x<h>.rgba).
    private static let dumpFrame = ProcessInfo.processInfo.environment["TPVR_TEST_MIRROR_DUMP"].flatMap(Int.init) ?? -1
    private var dumpTextures: [UInt64: PendingTexture] = [:]

    private func dump(_ frame: dusk_visionos_mirror_frame) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirror-dump")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let vertices = frame.vertices {
            try? Data(bytes: vertices, count: Int(frame.vertex_count) * 36).write(to: folder.appendingPathComponent("vertices.bin"))
        }
        if let indices = frame.indices {
            try? Data(bytes: indices, count: Int(frame.index_count) * 4).write(to: folder.appendingPathComponent("indices.bin"))
        }
        var parts = ""
        for index in 0..<Int(frame.part_count) {
            let p = frame.parts![index]
            parts += "\(p.first_index) \(p.index_count) \(p.texture) \(p.kind) \(p.flags) \(p.cutoff) "
                + "\(p.colour_base) \(p.colour_alpha) \(p.opacity_base) \(p.opacity_alpha) \(p.opacity_luma) "
                + "\(p.wrap_s) \(p.wrap_t)\n"
        }
        try? parts.write(to: folder.appendingPathComponent("parts.txt"), atomically: true, encoding: .utf8)
        let camera = "\(frame.tan_half_x) \(frame.tan_half_y) \(frame.focus) \(frame.bounds_min) \(frame.bounds_max)\n"
        try? camera.write(to: folder.appendingPathComponent("camera.txt"), atomically: true, encoding: .utf8)
        for (id, texture) in dumpTextures {
            try? texture.pixels.write(to: folder.appendingPathComponent("tex-\(id)-\(texture.width)x\(texture.height).rgba"))
        }
        print("[TPVR] mirror frame dumped: \(frame.vertex_count) vertices, \(frame.part_count) parts, \(dumpTextures.count) textures")
    }

    // MARK: - Report

    /// Every 5 s: how often RealityKit updates, how many game frames came, and what they cost here.
    private func report(_ start: CFTimeInterval) {
        timing.updates += 1
        timing.seconds += CACurrentMediaTime() - start
        guard start - timing.since > 5 else { return }
        let updates = Double(timing.updates), frames = Double(max(timing.frames, 1))
        print(String(format: "[TPVR] mirror: %.0f updates/s, %.0f frames/s, %.2f ms an update (fill %.2f, parts %.2f), "
                     + "%.0f vertices and %.0f parts "
                     + "a frame; %d materials, list set %d times; textures %d made, %d failed, %d waiting",
                     updates / (start - timing.since), Double(timing.frames) / (start - timing.since),
                     timing.seconds / updates * 1000, stages.fill / updates * 1000, stages.parts / updates * 1000,
                     Double(timing.vertices) / frames, Double(timing.parts) / frames,
                     materials.count, counts.materialSets, counts.texturesMade, counts.texturesFailed, pendingTextures.count))
        timing = (0, 0, 0, start, 0, 0, timing.total)
        stages = (0, 0)
        counts.materialSets = 0
    }
}

private extension Int {
    var nextPowerOfTwo: Int { self <= 1 ? 1 : 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount) }
}
