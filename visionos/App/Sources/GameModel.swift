import AVFAudio
import CompositorServices
import Foundation
import SwiftUI

/// The game as the launcher sees it: the disc in the app's Documents folder and,
/// once Play is pressed, the game framework's C bridge.
@MainActor
final class GameModel: ObservableObject {
    static let launcherWindowID = "launcher"
    static let immersiveSpaceID = "game"
    static let progressiveSpaceID = "game-progressive"

    enum Phase: Equatable {
        case idle
        /// The immersive space is opening; the game starts once its layer exists.
        case opening
        case running
        /// The game returned. It cannot run twice in one process, so playing
        /// again needs a relaunch.
        case ended(exitCode: Int32)
        case failed(message: String)
    }

    /// How the game surrounds you, picked in the launcher before Play.
    enum Immersion: String, CaseIterable, Identifiable {
        /// You stand in Hyrule, all around you.
        case full
        /// Hyrule through a portal in your room; the Digital Crown opens it wider
        /// or closes it down (visionOS 26).
        case progressive

        var id: String { rawValue }
        var title: String {
            switch self {
            case .full: "Full"
            case .progressive: "Progressive"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var disc: URL?
    @Published private(set) var importing = false
    @Published var message = ""
    @Published var immersion: Immersion {
        didSet { UserDefaults.standard.set(immersion.rawValue, forKey: Self.immersionKey) }
    }
    /// Full immersion with your room around the game's menus: Dusklight's and TP's
    /// own full-screen ones float in the room, with Hyrule hidden behind them.
    @Published var roomBehindMenus: Bool {
        didSet { UserDefaults.standard.set(roomBehindMenus, forKey: Self.roomBehindMenusKey) }
    }
    /// Foveated rendering: the system's rasterization rate map puts more of the
    /// eye images' pixels where you look. The game renders larger images for it.
    @Published var foveated: Bool {
        didSet { UserDefaults.standard.set(foveated, forKey: Self.foveatedKey) }
    }
    /// The immersive space's style, observed by the scene (TPVRVisionApp).
    let space = ImmersionSpaceStyle.shared

    private static let immersionKey = "immersion"
    private static let roomBehindMenusKey = "roomBehindMenus"
    private static let foveatedKey = "foveated"

    /// Progressive immersion needs the render context CompositorServices gained in
    /// visionOS 26, which draws the portal's edge into the game's frames.
    static var progressiveAvailable: Bool {
        if #available(visionOS 26.0, *) { return true }
        return false
    }

    /// Portrait, as in the SHAR port: the wide default portal cuts off what's below
    /// eye level. The system's own range: a custom one showed nothing on the headset.
    nonisolated static var progressiveStyle: any ImmersionStyle {
        if #available(visionOS 26.0, *) {
            return ProgressiveImmersionStyle.progressive(aspectRatio: .portrait)
        }
        return .progressive
    }

    /// visionOS takes an immersive space's style when it opens; changing it later
    /// is ignored. So the room behind the menus is decided here, before Play: Full
    /// with the room is a mixed space whose game frames are opaque (as WiiCompiled
    /// Vision opens by default), and only the menus' surroundings are see-through.
    var playsProgressive: Bool { immersion == .progressive && Self.progressiveAvailable }
    var playsMixed: Bool { !playsProgressive && roomBehindMenus }

    /// The full space's style (the progressive space has only its own).
    func styleForPlay() -> any ImmersionStyle {
        playsMixed ? .mixed : .full
    }

    /// The immersive space Play opens.
    var spaceIDForPlay: String {
        playsProgressive ? Self.progressiveSpaceID : Self.immersiveSpaceID
    }

    /// Disc images nod (the game's disc reader) opens; Dusklight wants GZ2E01 or GZ2P01.
    static let discExtensions: Set<String> = ["iso", "rvz", "gcm", "ciso", "gcz", "wia", "wbfs", "nfs", "tgc"]

    let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    /// Reopens the launcher window (set by the launcher, which has the scene actions).
    var showLauncher: (() -> Void)?
    private var watchdog: Timer?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.immersionKey).flatMap(Immersion.init(rawValue:))
        immersion = saved == .progressive && Self.progressiveAvailable ? .progressive : .full
        roomBehindMenus = UserDefaults.standard.object(forKey: Self.roomBehindMenusKey) as? Bool ?? true
        foveated = UserDefaults.standard.bool(forKey: Self.foveatedKey)
        // TPVR's audio listener is the headset (Z2Audience follows the HMD pose), so
        // the game already turns every sound with the head; visionOS's head-tracked
        // soundstage would turn the mix a second time. Bypass it and send the game's
        // stereo straight to the speakers, as a PC headset hears it (the SHAR port's
        // fix). Anchored to no window, it also plays on once the launcher closes.
        do {
            try AVAudioSession.sharedInstance().setIntendedSpatialExperience(.bypassed)
        } catch {
            print("[TPVR] setIntendedSpatialExperience(.bypassed) failed: \(error)")
        }
        refreshDisc()
    }

    var canPlay: Bool {
        phase == .idle && disc != nil && !importing
    }

    /// The newest disc image in Documents (the Files app shows the folder as
    /// On My Apple Vision Pro > Twilight Princess VR).
    func refreshDisc() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        disc = files
            .filter { Self.discExtensions.contains($0.pathExtension.lowercased()) }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return l < r
            }
    }

    /// Copies a picked disc image into Documents, where the game reads it in place.
    func importDisc(from url: URL) {
        importing = true
        message = "Copying \(url.lastPathComponent)…"
        let documents = self.documents
        let destination = documents.appendingPathComponent(url.lastPathComponent)
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let failure: String?
            do {
                if url.standardizedFileURL != destination.standardizedFileURL {
                    try? FileManager.default.removeItem(at: destination)
                    // AirDrop and "Open with" hand the file over in the app's own
                    // Documents/Inbox: move it rather than keep two copies of a
                    // 1.4 GB disc. Anything picked from elsewhere is copied.
                    if url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) {
                        try FileManager.default.moveItem(at: url, to: destination)
                    } else {
                        try FileManager.default.copyItem(at: url, to: destination)
                    }
                }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.importing = false
                self.message = failure.map { "Could not copy the disc: \($0)" } ?? ""
                self.refreshDisc()
            }
        }
    }

    func markOpening() {
        if phase == .idle {
            phase = .opening
            space.style = styleForPlay()
        }
    }

    func openingFailed(_ reason: String) {
        phase = .failed(message: reason)
    }

    /// Called from the CompositorLayer closure once the immersive space has a
    /// layer renderer. The provider retains it; TPVR creates its OpenXR session
    /// against it once the game starts.
    nonisolated func attach(_ layerRenderer: LayerRenderer) {
        dusk_visionos_set_layer_renderer(Unmanaged.passUnretained(layerRenderer).toOpaque())
        nonisolated(unsafe) let renderer = layerRenderer
        Task { @MainActor in
            // visionOS's look-and-pinch: a pinch carries the ray from the eyes to
            // where the user looked, which the provider turns into a pointer.
            renderer.onSpatialEvent = { events in
                for event in events { Self.forward(event) }
            }
            self.startGame()
        }
    }

    private nonisolated static func forward(_ event: SpatialEventCollection.Event) {
        let phase: Int32
        switch event.phase {
        case .active: phase = 0
        case .ended: phase = 1
        default: phase = 2
        }
        let chirality: Int32
        switch event.chirality {
        case .left?: chirality = 1
        case .right?: chirality = 2
        default: chirality = 0
        }
        let id = UInt64(bitPattern: Int64(event.id.hashValue))
        let ray = event.selectionRay
        let pose = event.inputDevicePose?.pose3D.position
        dusk_visionos_spatial_event(
            id, phase, chirality, ray != nil,
            Float(ray?.origin.x ?? 0), Float(ray?.origin.y ?? 0), Float(ray?.origin.z ?? 0),
            Float(ray?.direction.x ?? 0), Float(ray?.direction.y ?? 0), Float(ray?.direction.z ?? 0),
            pose != nil, Float(pose?.x ?? 0), Float(pose?.y ?? 0), Float(pose?.z ?? 0))
    }

    private func startGame() {
        guard phase == .opening || phase == .idle else { return }
        dusk_visionos_set_disc_path(disc?.path)
        // Menus over the room in the mixed space (a progressive portal shows black
        // where the game's frames are transparent, so menus stay as they were);
        // and there, with no visionOS boundary, the provider's own: Hyrule fades
        // into the room as you walk away from where you started.
        dusk_visionos_set_room_behind_menus(playsMixed)
        dusk_visionos_set_safety_boundary(playsMixed)
        if dusk_visionos_start_game() {
            phase = .running
            startWatchdog()
        } else {
            phase = .failed(message: String(cString: dusk_visionos_last_error()))
            // The launcher closed when the space opened; bring it back to say why.
            showLauncher?()
        }
    }

    /// Notices the game returning, and asks it to quit when the immersive space
    /// was closed (the Digital Crown), since it cannot be shown again.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkGame() }
        }
    }

    private func checkGame() {
        if !dusk_visionos_game_running() {
            watchdog?.invalidate()
            watchdog = nil
            let code = dusk_visionos_exit_code()
            if code == 0 {
                // A clean quit (the Digital Crown, or Quit in the game's menu): the
                // game saved on its way out, and it can't run twice in one process,
                // so the app goes too. Opening it again starts afresh at the launcher.
                exit(0)
            }
            phase = .ended(exitCode: code)
            // Something went wrong: bring the launcher back to say so.
            showLauncher?()
        } else if dusk_visionos_layer_invalidated() {
            dusk_visionos_request_quit()
        }
    }
}

/// The immersive space's style, set at Play, before the space opens (the SHAR
/// port's pattern).
@Observable
final class ImmersionSpaceStyle {
    static let shared = ImmersionSpaceStyle()
    /// The full space's: .full, or .mixed for the room around menus.
    var style: any ImmersionStyle = .full
    /// The progressive space's, which has only the one.
    var progressiveStyle: any ImmersionStyle = GameModel.progressiveStyle
}
