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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var disc: URL?
    @Published private(set) var importing = false
    @Published var message = ""
    @Published var immersionStyle: any ImmersionStyle = .full

    /// Disc images nod (the game's disc reader) opens; Dusklight wants GZ2E01 or GZ2P01.
    static let discExtensions: Set<String> = ["iso", "rvz", "gcm", "ciso", "gcz", "wia", "wbfs", "nfs", "tgc"]

    let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var watchdog: Timer?

    init() {
        // visionOS anchors an app's audio to its window by default, so the game
        // would fall silent once the launcher closes. Anchor it to the listener.
        try? AVAudioSession.sharedInstance().setIntendedSpatialExperience(
            .headTracked(soundStageSize: .automatic, anchoringStrategy: .front))
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
            var failure: String?
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
        if phase == .idle { phase = .opening }
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
        if dusk_visionos_start_game() {
            phase = .running
            startWatchdog()
        } else {
            phase = .failed(message: String(cString: dusk_visionos_last_error()))
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
            phase = .ended(exitCode: dusk_visionos_exit_code())
        } else if dusk_visionos_layer_invalidated() {
            dusk_visionos_request_quit()
        }
    }
}
