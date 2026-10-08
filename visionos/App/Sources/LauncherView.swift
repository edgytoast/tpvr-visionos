import GameController
import SwiftUI
import TrevorbiltKit
import UniformTypeIdentifiers

/// The launcher: Play (the disc, how to play, Play), Controls, Ports (the AVP Ports Index) and About,
/// in the Trevorbilt launcher every Trevorbilt port shares (visionos/TrevorbiltKit). What you'll
/// play with sits in an ornament under the window. It closes when the game opens, and comes back
/// with Resume and Quit when the Digital Crown pauses Full or Progressive.
struct LauncherView: View {
    enum Tab: String, CaseIterable {
        case play, controls, ports, about
    }

    @EnvironmentObject private var model: GameModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab(rawValue: TestHooks.value("TPVR_TEST_TAB") ?? "") ?? .play
    @State private var pickingDisc = false
    // Headless Simulator runs: TPVR_TEST_SHEET=manage|advanced|credits|diagnostics|port:<index id>
    // opens that sheet (on its own tab: TPVR_TEST_TAB).
    @State private var managing = TestHooks.value("TPVR_TEST_SHEET") == "manage"
    @State private var advanced = TestHooks.value("TPVR_TEST_SHEET") == "advanced"
    // Headless Simulator runs: TPVR_TEST_INPUTS=hands:denied,sense:none,gamepad:none (InputMonitor).
    @State private var inputs = InputMonitor(testOverride: TestHooks.value("TPVR_TEST_INPUTS"))
    @State private var ports = PortsIndex(testFeed: TestHooks.value("TPVR_TEST_FEED").map { URL(fileURLWithPath: $0) },
                                          offline: TestHooks.value("TPVR_TEST_OFFLINE") == "1")

    var body: some View {
        TabView(selection: $tab) {
            playTab
                .tabItem { Label("Play", systemImage: "play.fill") }
                .tag(Tab.play)
            ControlsView()
                .tabItem { Label("Controls", systemImage: "gamecontroller.fill") }
                .tag(Tab.controls)
            // Text only once the game is open: it stays loaded (about 1.5 GB) until the app ends.
            PortsBrowser(index: ports, ownID: "twilight-princess-vr", buildCommit: BuildInfo.current.commit,
                         buildDirty: BuildInfo.current.dirty,
                         opening: TestHooks.value("TPVR_TEST_SHEET").flatMap { $0.hasPrefix("port:") ? String($0.dropFirst(5)) : nil },
                         showsMedia: model.phase == .idle)
                .tabItem { Label("Ports", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.ports)
            AboutView(content: Self.about, diagnostics: diagnostics,
                      sheet: TestHooks.value("TPVR_TEST_SHEET").flatMap(AboutView.Sheet.init(rawValue:)))
                .tabItem { Label("About", systemImage: "info.circle.fill") }
                .tag(Tab.about)
        }
        // A glanceable glass card, the same size on every tab (the window hugs it: .contentSize).
        .frame(width: 640, height: 600)
        // visionOS turns a game controller's buttons into pinches on whatever window the player
        // looks at. While the game's window shows, a look at the launcher mustn't take the
        // controller from it: here too the controller is read only by the game. Otherwise the
        // controller works the launcher as usual. (The SHAR port's rule.)
        .handlesGameControllerEvents(matching: model.gameWindowShowing ? .gamepad : [])
        // Brought back by a pause, or to say why the game stopped: on Play, where that is.
        .onChange(of: model.launcherReturns) { tab = .play }
        // What you'll play with, centred under the window, while Play is showing.
        .ornament(visibility: tab == .play && discReady && !model.importing && showsInputs ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            InputStatus(monitor: inputs, handsUsed: !model.playsWindow, handsUnusedReason: "Not used in Window",
                        combinedSenseTitle: model.playsWindow ? "Sense (as a gamepad)" : nil, verdict: verdict)
                .padding(.top, 16)
        }
        .fileImporter(isPresented: $pickingDisc, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { importDisc(url) }
        }
        // AirDrop or the share sheet's "Open with Twilight Princess VR".
        .onOpenURL { url in importDisc(url) }
        .sheet(isPresented: $managing) { manageSheet }
        .sheet(isPresented: $advanced) { advancedSheet }
        .onAppear {
            let openWindow = openWindow
            model.showLauncher = { openWindow(id: GameModel.launcherWindowID, value: GameModel.launcherWindowID) }
        }
        // The guide opens on what's connected, for the way the game will play.
        // (Not over a test run's page: TPVR_TEST_CONTROLS sets its own.)
        .onChange(of: tab) { _, tab in
            if tab == .controls && TestHooks.value("TPVR_TEST_CONTROLS") == nil { showGuide() }
        }
        // A disc copied in with the Files app while the launcher was in the background, or hand
        // tracking allowed in Settings.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if !model.importing && model.phase == .idle { model.refreshDisc() }
            Task { await inputs.refresh() }
        }
        .task {
            await inputs.start()
            if tab == .controls && TestHooks.value("TPVR_TEST_CONTROLS") == nil { showGuide() }
        }
        .task {
            // Headless Simulator runs: TPVR_TEST_CONTROLS=hands|sense|gamepad[,window][,menus] shows
            // that page of the guide (menus: the hands' second page).
            if let value = TestHooks.value("TPVR_TEST_CONTROLS") {
                let parts = value.split(separator: ",").map(String.init)
                let guide = ControlsGuide.shared
                guide.windowView = parts.contains("window")
                guide.gestures = parts.contains("menus") ? .menus : .moving
                guide.input = ControlsView.Input.allCases.first { parts.contains($0.rawValue.lowercased()) }
                    ?? (guide.windowView ? .gamepad : .hands)
                tab = .controls
            }
            // Headless Simulator runs: TPVR_TEST_IMPORT=<host path> imports that file as if picked.
            if let path = TestHooks.value("TPVR_TEST_IMPORT") {
                importDisc(URL(fileURLWithPath: path))
            }
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

    // MARK: Play

    private var playTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    TrevorbiltHeader(title: "Twilight Princess ", boldTitle: "VR",
                                     subtitle: "The Legend of Zelda: Twilight Princess on Apple Vision Pro")
                    discStatus
                    if discReady && !model.importing {
                        switch model.phase {
                        case .idle: playAs
                        case .paused, .resuming: paused
                        default: EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 6) {
                if model.phase == .paused || model.phase == .resuming {
                    HStack(spacing: 12) {
                        Button("Resume") { Task { await resume() } }
                            .buttonStyle(TrevorbiltPrimaryButtonStyle(width: 200))
                        Button("Quit", role: .destructive) { model.quitFromPause() }
                            .buttonStyle(TrevorbiltSecondaryButtonStyle())
                    }
                    .disabled(model.phase != .paused)
                } else {
                    Button("Play") { Task { await play() } }
                        .buttonStyle(TrevorbiltPrimaryButtonStyle(width: 240))
                        .disabled(!model.canPlay)
                }
                if let line = statusLine {
                    Text(line).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                if let problem = gameProblem {
                    TrevorbiltCard { StatusHeadline(.problem, title: problem.title, detail: problem.detail) }
                        .frame(maxWidth: 460)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
    }

    private var discReady: Bool { model.disc != nil && model.discProblem == nil && !model.checkingDisc }

    /// The disc at a glance: one capsule once it's in and checked (Manage holds the rest), or the
    /// way to bring one.
    @ViewBuilder private var discStatus: some View {
        if model.importing {
            StatusCapsule {
                if let progress = model.importProgress {
                    ProgressRing(progress: progress)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Copying the disc\(model.importProgress.map { " · \(Int(($0 * 100).rounded()))%" } ?? "…")")
            }
        } else if let disc = model.disc, model.checkingDisc {
            StatusCapsule {
                ProgressView().controlSize(.small)
                Text("Checking \(disc.lastPathComponent)…").lineLimit(1).truncationMode(.middle)
            }
        } else if let disc = model.disc, let problem = model.discProblem {
            TrevorbiltCard(padding: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    StatusHeadline(.problem, title: "\(disc.lastPathComponent) won't play", detail: problem)
                    if model.phase == .idle {
                        Button("Import another disc") { pickingDisc = true }
                            .buttonStyle(TrevorbiltSecondaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: 560)
        } else if let disc = model.disc {
            VStack(spacing: 6) {
                StatusCapsule {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 18))
                        .accessibilityHidden(true)
                    Text("Disc ready · \(disc.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                } action: {
                    Button("Manage") { managing = true }
                }
                if model.importFailure != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Trevorbilt.orangeTint)
                            .accessibilityHidden(true)
                        Text("The last import didn't work. Manage has the details.")
                    }
                    .font(.tbBody(12, weight: .medium))
                }
            }
        } else {
            TrevorbiltCard(padding: 28, alignment: .center) {
                VStack(spacing: 8) {
                    Image(systemName: "opticaldisc.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 28))
                        .accessibilityHidden(true)
                    Text("Bring your copy of the game").font(.tbHeader(18, bold: true, relativeTo: .title3))
                    Text(Self.discHelp)
                        .font(.tbBody(13))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 460)
                    Button("Import disc") { pickingDisc = true }
                        .buttonStyle(TrevorbiltPrimaryButtonStyle(width: 240))
                        .padding(.top, 4)
                    if let failure = model.importFailure {
                        StatusHeadline(.problem, title: "That didn't work", detail: failure)
                            .frame(maxWidth: 460)
                    }
                }
            }
            .frame(maxWidth: 560)
        }
    }

    private static let discHelp = "Your Twilight Princess disc image: GameCube (GZ2E01 or GZ2P01) or any Wii release but the Korean one, as .iso, .rvz, .wbfs, .gcz, .ciso or .wia. AirDrop it to this Vision Pro, put it in Files › On My Apple Vision Pro › Twilight Princess VR, or import it here. Either plays as the GameCube version."

    private var playAs: some View {
        VStack(spacing: 8) {
            TrevorbiltSectionTitle("Play as")
            HStack(spacing: 12) {
                ForEach(GameModel.Immersion.allCases.filter { $0 != .progressive || GameModel.progressiveAvailable }) { mode in
                    ModeCard(Self.playMode(mode), name: mode.title, line: Self.explanation(mode),
                             selected: model.immersion == mode) { model.immersion = mode }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // What only the selected way of playing has: the room around menus in Full, foveated
            // rendering (Advanced) in Full and Progressive.
            if !model.playsWindow {
                HStack(spacing: 10) {
                    if model.immersion == .full {
                        Toggle(isOn: $model.roomBehindMenus) {
                            Text("Show my room around menus").font(.tbBody(13, weight: .medium))
                        }
                        .tint(Trevorbilt.orange)
                        .fixedSize()
                        .padding(.leading, 16)
                        .padding(.trailing, 8)
                        .frame(minHeight: 44)
                        .background(.white.opacity(0.1), in: .capsule)
                    }
                    Button("Advanced \u{203A}") { advanced = true }
                        .buttonStyle(TrevorbiltSecondaryButtonStyle())
                }
            }
            Text(optionNote)
                .font(.tbBody(12))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
    }

    /// One plain line on what the selected way of playing (and its option) does.
    private var optionNote: String {
        switch model.immersion {
        case .full where model.roomBehindMenus:
            "Menus and loading screens float in your room. Walk about 1.2 m from where you started and Hyrule fades into the room."
        case .full:
            "Hyrule stays around you in menus too, with visionOS's own boundary."
        case .progressive:
            "Turn the Digital Crown to widen or narrow the portal. Press it to pause."
        case .window:
            "Third person, with depth you can see as you move. Close the window to quit."
        }
    }

    private static func playMode(_ mode: GameModel.Immersion) -> PlayMode {
        switch mode {
        case .full: .full
        case .progressive: .progressive
        case .window: .window
        }
    }

    private static func explanation(_ mode: GameModel.Immersion) -> String {
        switch mode {
        case .full: "All around you, in first person."
        case .progressive: "A portal in your room. The Digital Crown widens it."
        case .window: "Beside your other apps. Plays with a controller."
        }
    }

    /// While the game is paused (the Digital Crown closed its space): where, and what Quit keeps.
    private var paused: some View {
        VStack(spacing: 6) {
            StatusCapsule {
                Image(systemName: "pause.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18))
                    .accessibilityHidden(true)
                Text(model.phase == .resuming ? "Back to Hyrule…" : "Paused in \(model.immersion.title)")
            }
            Text("Resume carries on where you were. Quit keeps your progress up to the last autosave or save.")
                .font(.tbBody(12))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Under the button: why Play can't be pressed, or what the game is doing.
    private var statusLine: String? {
        switch model.phase {
        case .opening: return "Opening Hyrule…"
        case .running: return "Playing. Press the Digital Crown to pause."
        case .ended, .failed: return "Close Twilight Princess VR and open it again to play."
        case .paused, .resuming: return model.message.isEmpty ? nil : model.message
        case .idle: break
        }
        if model.importing { return "Play is ready as soon as the disc is in." }
        if model.checkingDisc { return "Checking the disc…" }
        if model.disc == nil { return "Bring your disc first." }
        if model.discProblem != nil { return "Import a Twilight Princess disc to play." }
        return nil
    }

    /// Why the game stopped, when it did.
    private var gameProblem: (title: String, detail: String)? {
        switch model.phase {
        case let .ended(code): ("The game stopped", "It ended with an error (code \(code)).")
        case let .failed(reason): ("The game didn't open", reason)
        default: nil
        }
    }

    /// Whether the input ornament has anything to say: before Play, and while paused.
    private var showsInputs: Bool {
        switch model.phase {
        case .idle, .paused, .resuming: true
        default: false
        }
    }

    private var manageSheet: some View {
        SheetContent(done: { managing = false }) {
            TrevorbiltHeading("your ", bold: "disc", size: 22)
            TrevorbiltCard {
                VStack(alignment: .leading, spacing: 10) {
                    if model.importing {
                        StatusHeadline(.working, title: "Copying the disc",
                                       detail: "Keep the app open until this finishes.")
                        if let progress = model.importProgress { ProgressView(value: progress).tint(.white) }
                    } else if let disc = model.disc {
                        if let problem = model.discProblem {
                            StatusHeadline(.problem, title: "\(disc.lastPathComponent) won't play", detail: problem)
                        } else {
                            StatusHeadline(.ready, title: disc.lastPathComponent,
                                           detail: "\(Self.size(of: disc).map { "\($0), in" } ?? "In") Files › On My Apple Vision Pro › Twilight Princess VR. The app plays the newest disc there. It's kept out of iCloud backups; your saves aren't.")
                        }
                    } else {
                        StatusHeadline(.missing, title: "No disc yet", detail: "Import it from Play, or AirDrop it to this Vision Pro.")
                    }
                    if let failure = model.importFailure {
                        StatusHeadline(.problem, title: "The last import didn't work", detail: failure)
                    }
                }
            }
            if !model.importing && model.phase == .idle {
                Button(model.disc == nil ? "Import disc" : "Import another disc") { pickingFromSheet = true }
                    .buttonStyle(TrevorbiltSecondaryButtonStyle())
            }
        }
        // A sheet can't show the launcher's own importer over itself.
        .fileImporter(isPresented: $pickingFromSheet, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { importDisc(url) }
        }
    }

    @State private var pickingFromSheet = false

    private var advancedSheet: some View {
        SheetContent(done: { advanced = false }) {
            TrevorbiltHeading("advanced ", bold: "options", size: 22)
            TrevorbiltCard {
                Toggle(isOn: $model.foveated) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Foveated rendering").font(.tbBody(14, weight: .bold))
                        Text("In Full and Progressive: sharper where you look. The game renders larger eye images for it, which costs GPU time, so if it stutters, lower VR Render Resolution in the game's VR settings.")
                            .font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Trevorbilt.orange)
            }
        }
    }

    private static func size(of file: URL) -> String? {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    /// Which inputs the selected way of playing takes, and whether they're here.
    private var verdict: InputVerdict {
        // Two Sense controllers make one gamepad in the window; a gamepad works anywhere.
        if model.playsWindow {
            if inputs.senseLeft != nil && inputs.senseRight != nil {
                return InputVerdict("Ready to play with your Sense controllers, as a gamepad.", ready: true)
            }
            if inputs.anySense {
                return InputVerdict("Only one Sense controller is connected. Turn on the other, or turn this one off to play with a gamepad.", ready: false)
            }
            if inputs.gamepad != nil { return InputVerdict("Ready to play with your gamepad.", ready: true) }
            return InputVerdict("The Window view plays with a controller. Connect your Sense controllers or a gamepad.", ready: false)
        }
        // Full and Progressive: each hand is a Sense controller if one's in it, else the bare hand
        // (the provider picks per hand); a gamepad plays alongside either.
        let handsPlay = inputs.hands == .allowed || inputs.hands == .notAsked
        if inputs.senseLeft != nil && inputs.senseRight != nil {
            // Their buttons work regardless; where they are needs accessory tracking (or the hands).
            if inputs.accessories == .denied && !handsPlay {
                return InputVerdict("Accessory tracking is off for Twilight Princess VR, so the sword and shield won't follow your controllers. Turn it on in Settings.",
                                    ready: false, settingsNeeded: true)
            }
            return InputVerdict("Ready to play with your Sense controllers. Have fun!", ready: true)
        }
        if inputs.gamepad != nil { return InputVerdict("Ready to play with your gamepad.", ready: true) }
        if inputs.anySense {
            return handsPlay
                ? InputVerdict("Ready with one Sense controller. Your other hand plays bare.", ready: true)
                : InputVerdict("Only one Sense controller is connected and hand tracking is off. Turn on the other controller, or turn hand tracking on in Settings.",
                               ready: false, settingsNeeded: true)
        }
        switch inputs.hands {
        case .allowed:
            return InputVerdict("Ready to play with your hands. The Controls tab shows how.", ready: true)
        case .notAsked:
            return InputVerdict("Your hands play. visionOS asks to track them when the game starts.", ready: true)
        case .denied:
            return InputVerdict("Hand tracking is off for Twilight Princess VR. Turn it on in Settings, or connect a controller.",
                                ready: false, handsNeeded: true)
        case .unavailable:
            return InputVerdict("No controller is connected, and hand tracking isn't available here.", ready: false)
        }
    }

    /// The guide, on what's connected for the way the game will play.
    private func showGuide() {
        let guide = ControlsGuide.shared
        guide.windowView = model.playsWindow
        guide.input = inputs.anySense ? .sense : inputs.gamepad != nil || model.playsWindow ? .gamepad : .hands
    }

    private func importDisc(_ url: URL) {
        // Its progress and any problem show on Play.
        tab = .play
        // Never under a game that's open (it reads the disc in place): said, and AirDrop's copy
        // isn't left behind.
        guard model.phase == .idle else {
            model.declineImport(of: url, because: "The game's open, so the disc wasn't brought in. Quit, then bring it in again.")
            return
        }
        guard !model.importing else {
            model.declineImport(of: url, because: "One disc at a time: bring this one in once the copy that's running is done.")
            return
        }
        model.importDisc(from: url)
    }

    /// Opens the same space again; the game carries on once it has the new layer
    /// (GameModel.attach). The launcher goes, as at Play.
    private func resume() async {
        guard model.phase == .paused else { return }
        model.markResuming()
        switch await openImmersiveSpace(id: model.spaceIDForPlay) {
        case .opened:
            dismissWindow(id: GameModel.launcherWindowID, value: GameModel.launcherWindowID)
        case .userCancelled:
            model.resumeFailed("The immersive space was cancelled.")
        default:
            model.resumeFailed("visionOS couldn't open the immersive space again.")
        }
    }

    private func play() async {
        // The Ports tab's pictures go now, rather than when it's next shown: none stays in memory
        // beside the game.
        PortsBrowser.letGoOfPictures()
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
            dismissWindow(id: GameModel.launcherWindowID, value: GameModel.launcherWindowID)
        case .userCancelled:
            model.openingFailed("The immersive space was cancelled.")
        case .error:
            model.openingFailed("visionOS couldn't open the immersive space.")
        @unknown default:
            model.openingFailed("visionOS couldn't open the immersive space.")
        }
    }

    // MARK: About

    private var diagnostics: [(String, String)] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func controller(_ c: InputMonitor.Controller?) -> String {
            c.map { "\($0.name)\($0.battery.map { ", \(Int(($0 * 100).rounded()))%" } ?? "")" } ?? "None"
        }
        let phase = switch model.phase {
        case .idle: "Not started"
        case .opening: "Opening"
        case .running: "Running"
        case .paused: "Paused"
        case .resuming: "Resuming"
        case let .ended(code): "Ended (code \(code))"
        case .failed: "Didn't open"
        }
        return [("Build", BuildInfo.current.summary),
                ("visionOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
                ("Disc", model.disc.map { "\($0.lastPathComponent)\(Self.size(of: $0).map { ", \($0)" } ?? "")" } ?? "None"),
                ("Play as", model.immersion.title),
                ("Game", phase),
                ("Hand tracking", ["Allowed", "Off in Settings", "Not asked yet", "Not available"][
                    [InputMonitor.Permission.allowed, .denied, .notAsked, .unavailable].firstIndex(of: inputs.hands) ?? 2]),
                ("Sense L", controller(inputs.senseLeft)),
                ("Sense R", controller(inputs.senseRight)),
                ("Gamepad", controller(inputs.gamepad))]
    }

    /// The public repository. Builds from anywhere else (this one's own development included) are
    /// development builds (the "Build commit" phase in project.yml).
    static let repository = "edgytoast/tpvr-visionos"

    /// The built app is GPL-3.0 (it links the OpenXR provider), so the source of this very build is
    /// offered here: the repository at the commit it was built from (a development build's isn't
    /// public, so its branch).
    private static var sourceOfThisBuild: URL? {
        let build = BuildInfo.current
        return URL(string: "https://github.com/\(repository)/tree/\(build.dirty ? "visionos" : build.commit ?? "visionos")")
    }

    static let about = AboutContent(
        appName: "Twilight Princess VR",
        repository: repository,
        releaseBranch: "visionos",
        updateInstructions: "git pull, then visionos/scripts/build-visionos.sh --team <your team> --install (AVP-INSTALL.md has the details). Your disc and saves stay.",
        credits: [
            .init("Trevorbilt", "The Vision Pro port: the visionOS app, the immersive spaces and the room around the menus, the Window view's scene mirror, the input and the build.", "https://trevorbilt.com"),
            .init("Nintendo", "Made The Legend of Zelda: Twilight Princess, released in 2006 for GameCube and Wii.",
                  "https://en.wikipedia.org/wiki/The_Legend_of_Zelda:_Twilight_Princess"),
            .init("zeldaret", "Decompiled it, with the wider GameCube and Wii decompilation community.", "https://github.com/zeldaret/tp"),
            .init("The Twilit Realm team", "Built Dusklight, Twilight Princess on PC.", "https://twilitrealm.dev"),
            .init("JoeyAW", "Made it VR with TPVR: the first-person play, the physical sword, shield and bow. This port builds directly on that work.",
                  "https://github.com/JoeyAW/TPVR"),
            .init("encounter", "Wrote Aurora, the GameCube and Wii graphics layer.", "https://github.com/encounter/aurora"),
            .init("iChris4", "Made WiiCompiled Vision, the source of the visionOS OpenXR provider.", "https://github.com/iChris4/Wiicompiled_VR"),
            .init("Automata and the TP speedrunning community", "TPVR's thanks go to them too.", "https://zsrtp.link"),
            .init("Dawn, SDL, nod and SMAA", "Do a lot of the heavy lifting."),
        ],
        notices: [
            .init("This repository: CC0", "Trevorbilt's code for the port, Dusklight, the decompilation and TPVR are dedicated to the public domain.",
                  URL(string: "https://github.com/\(repository)/blob/visionos/LICENSE.md")),
            .init("This app: GPL-3.0", BuildInfo.current.dirty
                  ? "It links the visionOS OpenXR provider, which is GPL-3.0-or-later, so the app is GPL-3.0. This is a development build: its source is the copy it was built from, and the repository has the released ones."
                  : "It links the visionOS OpenXR provider, which is GPL-3.0-or-later, so the app is GPL-3.0. Its source is the repository at the commit this build came from.",
                  sourceOfThisBuild),
            .init("The launcher's shared code: MIT", "TrevorbiltKit, in visionos/TrevorbiltKit.",
                  URL(string: "https://github.com/\(repository)/blob/visionos/visionos/TrevorbiltKit/LICENSE")),
            .init("The launcher's fonts", "Space Mono and Roboto: SIL Open Font License 1.1.",
                  URL(string: "https://github.com/\(repository)/tree/visionos/visionos/TrevorbiltKit/Sources/TrevorbiltKit/Resources/Fonts")),
            .init("The game's fonts", "Alegreya SC, Fira Sans, Inter and Noto Mono: SIL Open Font License 1.1. Material Symbols: Apache-2.0.",
                  URL(string: "https://github.com/\(repository)/tree/visionos/res/licenses")),
            .init("Third-party code", "SMAA is MIT. Dawn, SDL, nod and the other submodules and downloads keep their own licences."),
            .init("Trevorbilt's name, badge and app icons", "All rights reserved; not covered by the repository's licences."),
        ],
        disclaimer: "Twilight Princess VR is a fan project. It isn't affiliated with or endorsed by Nintendo. The game, its characters and its art belong to Nintendo, and the disc is yours to bring.",
        otherPorts: [(name: "SHAR VR",
                      url: URL(string: "https://github.com/edgytoast/avp-ports-index/blob/main/ports/shar-visionos.md")!)])
}

/// One line of status in a glass capsule, with an optional button at its end.
private struct StatusCapsule<Label: View, Action: View>: View {
    private let label: Label
    private let action: Action

    init(@ViewBuilder label: () -> Label, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.label = label()
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) { label }
                .font(.tbBody(14, weight: .medium, relativeTo: .body))
                .accessibilityElement(children: .combine)
            action.buttonStyle(TrevorbiltSecondaryButtonStyle())
        }
        .padding(.leading, 16)
        .padding(.trailing, Action.self == EmptyView.self ? 16 : 4)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(.white.opacity(0.08), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
    }
}

/// How far an import has got, as a ring.
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 3)
            Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
