import SwiftUI
import UniformTypeIdentifiers

/// The launcher window: which disc the game will load, a way to bring one in,
/// and Play, which opens the immersive space.
struct LauncherView: View {
    @EnvironmentObject private var model: GameModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pickingDisc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Twilight Princess VR")
                    .font(.extraLargeTitle2)
                Text("TPVR on Dusklight, in first person. Bring your own disc.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let disc = model.disc {
                        Label(disc.lastPathComponent, systemImage: "opticaldisc")
                            .font(.headline)
                    } else {
                        Label("No disc yet", systemImage: "opticaldisc")
                            .font(.headline)
                        Text("Add your Twilight Princess disc image: GameCube (GZ2E01, GZ2P01) or Wii (any release but Korean), as .iso, .rvz or .wbfs. AirDrop it and open it with this app, drop it in Files › On My Apple Vision Pro › Twilight Princess VR, or import it below. Either plays as the GameCube version.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
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
                if GameModel.progressiveAvailable {
                    Picker("Immersion", selection: $model.immersion) {
                        ForEach(GameModel.Immersion.allCases) { immersion in
                            Text(immersion.title).tag(immersion)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if model.immersion == .progressive && GameModel.progressiveAvailable {
                    Text("Hyrule opens through a portal in your room. Turn the Digital Crown to widen or narrow it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Show my room around menus", isOn: $model.roomBehindMenus)
                    Text(model.roomBehindMenus
                         ? "Pause and Dusklight menus float in your room. Walk more than about 1.2 m from where you started and Hyrule fades into the room."
                         : "Hyrule stays around you in menus too, with visionOS's own full-immersion boundary.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.phase != .idle)

            if !model.message.isEmpty {
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            status

            Spacer(minLength: 0)

            Button {
                Task { await play() }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.extraLarge)
            .disabled(!model.canPlay)
        }
        .padding(32)
        .fileImporter(isPresented: $pickingDisc, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result {
                model.importDisc(from: url)
            }
        }
        .onOpenURL { url in
            model.importDisc(from: url)
        }
        .task {
            // Headless runs: `SIMCTL_CHILD_TPVR_AUTO_PLAY=1 xcrun simctl launch ...` (or the
            // same variable in a devicectl launch) presses Play on its own, disc or not.
            // Synthesized taps don't reach visionOS Simulator windows.
            if ProcessInfo.processInfo.environment["TPVR_AUTO_PLAY"] == "1", model.phase == .idle {
                await play()
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
            Label("Playing. Press the Digital Crown to leave.", systemImage: "visionpro")
        case let .ended(code):
            Label("The game ended (code \(code)). Relaunch the app to play again.", systemImage: "stop.circle")
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func play() async {
        model.markOpening()
        switch await openImmersiveSpace(id: GameModel.immersiveSpaceID) {
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
