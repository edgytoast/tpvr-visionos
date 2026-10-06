import ARKit
import AVFAudio
import CompositorServices
import Foundation
import GameController
import SwiftUI
import UIKit

/// The game as the launcher sees it: the disc in the app's Documents folder and,
/// once Play is pressed, the game framework's C bridge.
@MainActor
final class GameModel: ObservableObject {
    static let launcherWindowID = "launcher"
    static let immersiveSpaceID = "game"
    static let progressiveSpaceID = "game-progressive"
    static let windowSceneID = "game-window"

    enum Phase: Equatable {
        case idle
        /// The immersive space is opening; the game starts once its layer exists.
        case opening
        case running
        /// The Digital Crown closed the immersive space: the game is held where it
        /// was, its sound paused, and the launcher offers Resume or Quit.
        case paused
        /// Resume was pressed: the space is opening again for the same game.
        case resuming
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
        /// Twilight Princess in a window beside your other apps, third person, with a
        /// gamepad (GameWindowView). No head tracking reaches a window, so the VR mod is off.
        case window

        var id: String { rawValue }
        var title: String {
            switch self {
            case .full: "Full"
            case .progressive: "Progressive"
            case .window: "Window"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var disc: URL?
    /// Why the disc can't play (another game, an unsupported release, a file that isn't
    /// a disc image), from the game's own check of its header; nil when it can, or while
    /// it's being checked. A copy cut short after the header passes; the import's
    /// .partial file is what keeps those from appearing.
    @Published private(set) var discProblem: String?
    @Published private(set) var checkingDisc = false
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
    /// Hand tracking is turned off for this app in Settings (read without asking).
    @Published private(set) var handTrackingDenied = false
    /// A gamepad or a Sense controller is connected.
    @Published private(set) var controllerConnected = false
    /// Full and Progressive would get no input at all: no hands and no controller.
    var noInputForImmersive: Bool { !playsWindow && handTrackingDenied && !controllerConnected }

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
    var playsWindow: Bool { immersion == .window }
    var playsMixed: Bool { !playsProgressive && !playsWindow && roomBehindMenus }

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
        switch saved {
        case .progressive? where Self.progressiveAvailable: immersion = .progressive
        case .window?: immersion = .window
        default: immersion = .full
        }
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
        removeStalePartials()
        refreshDisc()
    }

    /// Reads whether hand tracking is allowed and a controller is connected, for the
    /// launcher's note. Asks nothing: the immersive space asks for hand tracking itself.
    func refreshInputs() async {
        let status = await ARKitSession().queryAuthorization(for: [.handTracking])
        handTrackingDenied = status[.handTracking] == .denied
        controllerConnected = !GCController.controllers().isEmpty
    }

    var canPlay: Bool {
        phase == .idle && disc != nil && !importing && !checkingDisc && discProblem == nil
    }

    /// The newest disc image in Documents (the Files app shows the folder as
    /// On My Apple Vision Pro > Twilight Princess VR).
    func refreshDisc() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let discs = files.filter { Self.discExtensions.contains($0.pathExtension.lowercased()) }
        // A disc image is 1.4 to 4.7 GB the player can copy in again: keep it out of
        // iCloud backups. Saves, next to it, are backed up as usual.
        for var file in discs {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
        }
        disc = discs
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return l < r
            }
        checkDisc()
    }

    /// Asks the game whether the disc is a Twilight Princess it plays, before Play: a
    /// wrong one would otherwise open Dusklight's flat disc screen inside the space.
    private func checkDisc() {
        guard let path = disc?.path else {
            discProblem = nil
            checkingDisc = false
            return
        }
        checkingDisc = true
        Task.detached(priority: .userInitiated) {
            let problem = dusk_visionos_check_disc(path).map { String(cString: $0) }
            await MainActor.run {
                // Only the answer for the disc still chosen counts.
                guard self.disc?.path == path else { return }
                self.discProblem = problem
                self.checkingDisc = false
            }
        }
    }

    /// Copies a picked disc image into Documents, where the game reads it in place.
    func importDisc(from url: URL) {
        importing = true
        message = "Copying \(url.lastPathComponent)…"
        let documents = self.documents
        let destination = documents.appendingPathComponent(url.lastPathComponent)
        // A 1.4 to 4.7 GB copy takes a while: keep going if the wearer looks away. If the
        // background time runs out first, the task ends so visionOS suspends the app
        // rather than ending it, and the copy carries on when the app is back.
        importTask = UIApplication.shared.beginBackgroundTask(withName: "Import disc") { [weak self] in
            MainActor.assumeIsolated { self?.endImportTask() }
        }
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let failure: String?
            do {
                if url.standardizedFileURL != destination.standardizedFileURL {
                    let fileManager = FileManager.default
                    // AirDrop and "Open with" hand the file over in the app's own
                    // Documents/Inbox: move it rather than keep two copies of a
                    // 1.4 GB disc (a rename, so it can't be left half done).
                    // Anything picked from elsewhere is copied to a .partial file
                    // first, which the launcher never picks, and renamed once whole:
                    // an interrupted copy can't leave a truncated disc behind, and
                    // the disc it replaces stays until then.
                    let staged: URL
                    if url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) {
                        staged = url
                    } else {
                        staged = destination.appendingPathExtension(Self.partialExtension)
                        try? fileManager.removeItem(at: staged)
                        do {
                            try fileManager.copyItem(at: url, to: staged)
                        } catch {
                            try? fileManager.removeItem(at: staged)
                            throw error
                        }
                    }
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: staged, to: destination)
                    // Copies keep the source's date, and the launcher plays the newest
                    // disc: the one just brought in is the newest.
                    var imported = destination
                    var values = URLResourceValues()
                    values.contentModificationDate = Date()
                    try? imported.setResourceValues(values)
                }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.importing = false
                self.message = failure.map { "Could not copy the disc: \($0)" } ?? ""
                self.refreshDisc()
                self.endImportTask()
            }
        }
    }

    private var importTask: UIBackgroundTaskIdentifier = .invalid

    private func endImportTask() {
        guard importTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(importTask)
        importTask = .invalid
    }

    /// An import in progress (or one the app was closed during).
    nonisolated static let partialExtension = "partial"

    /// Removes .partial copies left by an import the app was closed during.
    private func removeStalePartials() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for file in files where file.pathExtension == Self.partialExtension {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func markOpening() {
        if phase == .idle {
            phase = .opening
            space.style = styleForPlay()
        }
    }

    /// Resume, from the launcher: the same space opens again and the game carries on
    /// once it has the new layer (attach).
    func markResuming() {
        if phase == .paused {
            phase = .resuming
        }
    }

    /// The space didn't open again: still paused, and the launcher says why.
    func resumeFailed(_ reason: String) {
        if phase == .resuming {
            phase = .paused
            message = reason
        }
    }

    /// Quit, from the launcher while paused: the game shuts down and the app ends with
    /// it (checkGame), keeping progress up to the last autosave or save.
    func quitFromPause() {
        guard phase == .paused else { return }
        quitRequested = true
        dusk_visionos_request_quit()
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
            if self.phase == .resuming {
                // The provider took the new layer above; the game's session starts
                // again on it and the game carries on where it was.
                self.message = ""
                self.phase = .running
            } else {
                self.startGame()
            }
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

    /// Window mode: called when the game window appears. The game plays flat (no layer renderer,
    /// so no VR) and hands its frames to the window, which paces it.
    func startWindowGame() {
        guard phase == .opening || phase == .idle else { return }
        // The game's listener follows its own camera, not your head: let visionOS place the sound
        // at the window.
        do {
            try AVAudioSession.sharedInstance().setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        } catch {
            print("[TPVR] window audio: setIntendedSpatialExperience failed: \(error)")
        }
        dusk_visionos_set_window_mode(true)
        startGame()
    }

    /// The game window closed: the game returns (autosave has kept progress up to the last new
    /// area or dungeon door), and the app ends with it. The request
    /// repeats from the watchdog until the game returns (one sent before the game's event loop
    /// is up would be dropped).
    func windowClosed() {
        quitRequested = true
        if phase == .running {
            dusk_visionos_request_quit()
        }
    }
    private var quitRequested = false

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

    /// Notices the game returning, the immersive space closing (the Digital Crown),
    /// which pauses the game, and a quit request still to deliver.
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
                // A clean quit (Quit in the launcher or the game's menu, or the game
                // window closed). The game doesn't save on the way out; autosave (on
                // by default here) covers progress up to the last new area or door.
                // It can't run twice in one process, so the app goes too. Opening it
                // again starts afresh at the launcher.
                exit(0)
            }
            phase = .ended(exitCode: code)
            // Something went wrong: bring the launcher back to say so.
            showLauncher?()
        } else if quitRequested {
            dusk_visionos_request_quit()
        } else if phase == .running && !playsWindow && dusk_visionos_layer_invalidated() {
            if dusk_visionos_session_focused_once() {
                // The Digital Crown closed the space. The game holds where it is (its
                // session waits for a new layer, its clock and sound paused); the
                // launcher offers Resume or Quit. If visionOS doesn't show it now,
                // opening the app from Home does.
                phase = .paused
                showLauncher?()
            } else {
                // Closed before the game was ever seen in it: its VR startup gives up
                // waiting for the space, so there's nothing to resume. Quit, as before.
                quitRequested = true
                dusk_visionos_request_quit()
            }
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
