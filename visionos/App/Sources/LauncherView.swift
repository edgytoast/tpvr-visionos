import SwiftUI
import UniformTypeIdentifiers

/// The launcher window: which disc the game will load, a way to bring one in,
/// and Play, which opens the immersive space.
struct LauncherView: View {
    @EnvironmentObject private var model: GameModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickingDisc = false

    /// Trevorbilt's orange, as in the logo (and the SHAR port's launcher).
    private static let trevorbiltOrange = Color(red: 237 / 255, green: 112 / 255, blue: 20 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Twilight Princess VR")
                    .font(.extraLargeTitle2)
                Text("TPVR on Dusklight, in first person. Bring your own disc.")
                    .foregroundStyle(.secondary)
                // Who made this port; the README credits the game and the ports it builds on.
                Text("An unofficial port by Trevorbilt")
                    .font(.footnote)
                    .foregroundStyle(Self.trevorbiltOrange)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let disc = model.disc {
                        Label(disc.lastPathComponent, systemImage: "opticaldisc")
                            .font(.headline)
                        if let problem = model.discProblem {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Label("No disc yet", systemImage: "opticaldisc")
                            .font(.headline)
                        Text("Add your Twilight Princess disc image: GameCube (GZ2E01, GZ2P01) or Wii (any release but Korean), as .iso, .rvz or .wbfs. AirDrop it and open it with this app, drop it in Files › On My Apple Vision Pro › Twilight Princess VR, or import it below. Either plays as the GameCube version.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Import Disc…") { pickingDisc = true }
                            .disabled(model.importing || model.phase != .idle)
                        Button("Refresh") { model.refreshDisc() }
                            .disabled(model.importing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("Immersion", selection: $model.immersion) {
                    ForEach(GameModel.Immersion.allCases.filter { $0 != .progressive || GameModel.progressiveAvailable }) { immersion in
                        Text(immersion.title).tag(immersion)
                    }
                }
                .pickerStyle(.segmented)
                if model.immersion == .window {
                    Text("Twilight Princess in a window beside your other apps, in third person, with depth you can see as you move. Play it with a gamepad; head and hand tracking stay in the immersive modes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.immersion == .progressive && GameModel.progressiveAvailable {
                    Text("Hyrule opens through a portal in your room. Turn the Digital Crown to widen or narrow it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("Show my room around menus", isOn: $model.roomBehindMenus)
                    Text(model.roomBehindMenus
                         ? "Pause and Dusklight menus float in your room. Walk more than about 1.2 m from where you started and Hyrule fades into the room."
                         : "Hyrule stays around you in menus too, with visionOS's own full-immersion boundary.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(model.phase != .idle)

            // Foveation is the immersive spaces' (a window is drawn by visionOS itself).
            if model.immersion != .window {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Foveated rendering", isOn: $model.foveated)
                Text("Sharper where you look. The game renders larger eye images, which costs GPU time: lower VR Render Resolution in the game's VR settings if it stutters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(model.phase != .idle)
            }

            if model.noInputForImmersive {
                Label("Hand tracking is off for Twilight Princess VR and no controller is connected, so nothing would reach the game. Turn it on in Settings › Privacy & Security › Hand Tracking, or connect a controller.",
                      systemImage: "hand.raised.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.message.isEmpty {
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            status

            Spacer(minLength: 0)

            if model.phase == .paused || model.phase == .resuming {
                // The Digital Crown closed the space; the game is held where it was.
                HStack(spacing: 16) {
                    Button {
                        Task { await resume() }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) {
                        model.quitFromPause()
                    } label: {
                        Label("Quit", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.extraLarge)
                .disabled(model.phase != .paused)
            } else {
                Button {
                    Task { await play() }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.extraLarge)
                .disabled(!model.canPlay)
            }
        }
        .padding(32)
        // Wide enough that the notes wrap to a couple of lines, not a column.
        .frame(minWidth: 680)
        .fileImporter(isPresented: $pickingDisc, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result {
                model.importDisc(from: url)
            }
        }
        .onOpenURL { url in
            model.importDisc(from: url)
        }
        .onAppear {
            let openWindow = openWindow
            model.showLauncher = { openWindow(id: GameModel.launcherWindowID) }
        }
        .task { await model.refreshInputs() }
        // Back from Settings, where hand tracking may have been turned on.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshInputs() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            Task { await model.refreshInputs() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            Task { await model.refreshInputs() }
        }
        .task {
            // Headless runs: `SIMCTL_CHILD_TPVR_AUTO_PLAY=1 xcrun simctl launch ...` (or the
            // same variable in a devicectl launch) presses Play on its own, disc or not.
            // Synthesized taps don't reach visionOS Simulator windows.
            if ProcessInfo.processInfo.environment["TPVR_AUTO_PLAY"] == "1", model.phase == .idle {
                await play()
            }
            // Headless runs of the Digital Crown pause: TPVR_TEST_PAUSED=resume@5 (or quit@5)
            // presses Resume (or Quit) that many seconds after the launcher comes back.
            if model.phase == .paused, let test = ProcessInfo.processInfo.environment["TPVR_TEST_PAUSED"] {
                let parts = test.split(separator: "@")
                let delay = parts.count > 1 ? Double(parts[1]) ?? 5 : 5
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard model.phase == .paused else { return }
                if parts.first == "quit" {
                    model.quitFromPause()
                } else {
                    await resume()
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .opening:
            Label("Opening Hyrule…", systemImage: "hourglass")
        case .running:
            Label("Playing. Press the Digital Crown to pause.", systemImage: "visionpro")
        case .paused:
            Label("Paused where you left off. Resume to carry on, or Quit: progress is kept up to the last autosave or save.",
                  systemImage: "pause.circle")
                .fixedSize(horizontal: false, vertical: true)
        case .resuming:
            Label("Back to Hyrule…", systemImage: "hourglass")
        case let .ended(code):
            Label("The game stopped with an error (code \(code)). Quit and reopen the app to play again.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    /// Opens the same space again; the game carries on once it has the new layer
    /// (GameModel.attach). The launcher goes, as at Play.
    private func resume() async {
        guard model.phase == .paused else { return }
        model.markResuming()
        switch await openImmersiveSpace(id: model.spaceIDForPlay) {
        case .opened:
            dismissWindow(id: GameModel.launcherWindowID)
        case .userCancelled:
            model.resumeFailed("The immersive space was not opened.")
        default:
            model.resumeFailed("The immersive space could not be opened.")
        }
    }

    private func play() async {
        model.markOpening()
        if model.playsWindow {
            // The game window starts the game when it appears and closes this one.
            openWindow(id: GameModel.windowSceneID)
            return
        }
        switch await openImmersiveSpace(id: model.spaceIDForPlay) {
        case .opened:
            // The game starts once the space's layer renderer arrives (GameModel.attach).
            // Out of the way while you play: visionOS lets the last window go only once the
            // space is open, which is now. The game's audio is anchored to the listener
            // (GameModel), so it plays on without this window; reopening the app brings
            // the launcher back.
            dismissWindow(id: GameModel.launcherWindowID)
        case .userCancelled:
            model.openingFailed("The immersive space was not opened.")
        case .error:
            model.openingFailed("The immersive space could not be opened.")
        @unknown default:
            model.openingFailed("The immersive space could not be opened.")
        }
    }
}
