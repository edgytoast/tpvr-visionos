import SwiftUI
import UniformTypeIdentifiers

/// The launcher window: which disc the game will load, a way to bring one in,
/// and Play, which opens the immersive space.
struct LauncherView: View {
    @EnvironmentObject private var model: GameModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var pickingDisc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Twilight Princess VR")
                    .font(.extraLargeTitle2)
                Text("TPVR on Dusklight, in first person. Bring your own GameCube disc.")
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
                        Text("Add a GameCube Twilight Princess image (GZ2E01 or GZ2P01, .iso or .rvz): AirDrop it and open it with this app, drop it in Files › On My Apple Vision Pro › Twilight Princess VR, or import it below.")
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
            break  // The game starts once the space's layer renderer arrives (GameModel.attach).
        case .userCancelled:
            model.openingFailed("The immersive space was not opened.")
        case .error:
            model.openingFailed("The immersive space could not be opened.")
        @unknown default:
            model.openingFailed("The immersive space could not be opened.")
        }
    }
}
