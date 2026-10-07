import SwiftUI
import UIKit

/// What a port puts in its About tab. The kit adds More from Trevorbilt, the update check and the
/// privacy note.
public struct AboutContent {
    public struct Credit {
        public let name: String
        public let role: String
        public let url: URL?

        public init(_ name: String, _ role: String, _ url: String? = nil) {
            self.name = name
            self.role = role
            self.url = url.flatMap(URL.init(string:))
        }
    }

    public struct Notice {
        public let title: String
        public let detail: String
        public let url: URL?

        public init(_ title: String, _ detail: String, _ url: URL? = nil) {
            self.title = title
            self.detail = detail
            self.url = url
        }
    }

    public let appName: String
    /// The public repository, "owner/name", and the branch its releases go to.
    public let repository: String
    public let releaseBranch: String
    /// How a player updates, after the update check finds a newer version.
    public let updateInstructions: String
    public let credits: [Credit]
    public let notices: [Notice]
    public let disclaimer: String
    /// Another port of Trevorbilt's, by name and its listing page.
    public let otherPorts: [(name: String, url: URL)]
    /// Shown only when set; never a placeholder.
    public let supportURL: URL?

    public init(appName: String, repository: String, releaseBranch: String, updateInstructions: String,
                credits: [Credit], notices: [Notice], disclaimer: String,
                otherPorts: [(name: String, url: URL)] = [], supportURL: URL? = nil) {
        self.appName = appName
        self.repository = repository
        self.releaseBranch = releaseBranch
        self.updateInstructions = updateInstructions
        self.credits = credits
        self.notices = notices
        self.disclaimer = disclaimer
        self.otherPorts = otherPorts
        self.supportURL = supportURL
    }
}

/// The build this app came from, as the port's build phase wrote it into Info.plist: TBBuildCommit,
/// the full commit ("unknown" without git), and TBBuildDirty, a development build (changes not
/// committed, or not built from the public repository, so its commit can't be compared with a
/// release's).
public struct BuildInfo {
    public let version: String
    public let build: String
    public let commit: String?
    public let dirty: Bool

    public static var current: BuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["TBBuildCommit"] as? String
        return BuildInfo(version: info["CFBundleShortVersionString"] as? String ?? "?",
                         build: info["CFBundleVersion"] as? String ?? "?",
                         commit: commit == nil || commit == "unknown" || commit!.isEmpty ? nil : commit,
                         dirty: (info["TBBuildDirty"] as? String) == "true" || (info["TBBuildDirty"] as? Bool) == true)
    }

    /// "0.1 (1), abc1234" or "0.1 (1), development build".
    public var summary: String {
        if dirty { return "\(version) (\(build)), development build" }
        return "\(version) (\(build)), \(commit.map { String($0.prefix(7)) } ?? "commit unknown")"
    }
}

public struct AboutView: View {
    /// The sheets About opens.
    public enum Sheet: String { case credits, diagnostics }

    private let content: AboutContent
    private let diagnostics: [(String, String)]
    private let build = BuildInfo.current
    @State private var update: String?
    @State private var checking = false
    @State private var showingCredits = false
    @State private var showingDiagnostics = false

    /// `sheet`: one to open at once (for a port's headless screenshot runs).
    public init(content: AboutContent, diagnostics: [(String, String)] = [], sheet: Sheet? = nil) {
        self.content = content
        self.diagnostics = diagnostics
        _showingCredits = State(initialValue: sheet == .credits)
        _showingDiagnostics = State(initialValue: sheet == .diagnostics)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Trevorbilt.badge
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64)
                        .accessibilityLabel("Trevorbilt")
                    TrevorbiltHeading("from the maker ", bold: "of \(content.appName)", size: 22)
                }
                HStack(alignment: .top, spacing: 12) {
                    ShowcaseCard(icon: Trevorbilt.brandImage("loose-papers-icon"), name: "Loose Papers",
                                 tagline: "The next chapter in reading.",
                                 line: "Physical bookshelves and books for your EPUB, CBR, CBZ and PDF files, right in your room.",
                                 url: URL(string: "https://apps.apple.com/us/app/loose-papers/id6755368606")!)
                    ShowcaseCard(icon: Trevorbilt.brandImage("papas-ball-and-tee-icon"), name: "Papa's Ball & Tee",
                                 tagline: "A delightful frustration.",
                                 line: "A ball and tee in a little glass globe. No levels, no leaderboard, no hero's journey.",
                                 url: URL(string: "https://apps.apple.com/us/app/papas-ball-and-tee/id6757321188")!)
                }
                .frame(maxWidth: 540)
                HStack(spacing: 12) {
                    ForEach(content.otherPorts, id: \.name) { port in
                        CompactLinkCard(symbol: "visionpro", name: port.name, line: "Another free port, on the AVP Ports Index", url: port.url)
                    }
                    if let support = content.supportURL {
                        CompactLinkCard(symbol: "cup.and.saucer.fill", name: "Support", line: "If this made your day.", url: support)
                    }
                }
                .frame(maxWidth: content.otherPorts.count + (content.supportURL == nil ? 0 : 1) > 1 ? .infinity : 300)
                Link(destination: Trevorbilt.website) {
                    Text("trevorbilt.com")
                        .font(.tbBody(13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(.white.opacity(0.8))
                        .underline()
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(.hoverEffect, .capsule)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                thisApp
                HStack(spacing: 10) {
                    Button("Credits, licences and privacy \u{203A}") { showingCredits = true }
                    if !diagnostics.isEmpty {
                        Button("Diagnostics \u{203A}") { showingDiagnostics = true }
                    }
                }
                .buttonStyle(TrevorbiltSecondaryButtonStyle())
                Text("Thanks for playing.")
                    .font(.tbHeader(14, relativeTo: .headline))
                    .padding(.top, 2)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingCredits) { CreditsSheet(content: content) }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsSheet(diagnostics: diagnostics) }
    }

    private var thisApp: some View {
        TrevorbiltCard(padding: 22, alignment: .center) {
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text("\(content.appName) \(build.version)").font(.tbHeader(15, bold: true, relativeTo: .headline))
                    Text(build.dirty ? "A development build" : build.commit.map { "Build \($0.prefix(7))" } ?? "Build \(build.build)")
                        .font(.tbBody(12, relativeTo: .subheadline))
                        .foregroundStyle(.white.opacity(0.8))
                }
                HStack(spacing: 8) {
                    Button(checking ? "Checking…" : "Check for updates") { Task { await checkForUpdates() } }
                        .disabled(checking)
                    Link("Guide", destination: fileURL("AVP-INSTALL.md"))
                    Link("Report a problem", destination: issueURL)
                }
                .buttonStyle(TrevorbiltSecondaryButtonStyle())
                if let update {
                    Text(update)
                        .font(.tbBody(12, relativeTo: .subheadline))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A file at the commit this app was built from, or the release branch's if that's unknown.
    private func fileURL(_ path: String) -> URL {
        let ref = build.dirty ? content.releaseBranch : build.commit ?? content.releaseBranch
        return URL(string: "https://github.com/\(content.repository)/blob/\(ref)/\(path)")!
    }

    /// A new issue, prefilled with what helps and nothing personal.
    private var issueURL: URL {
        var components = URLComponents(string: "https://github.com/\(content.repository)/issues/new")!
        let os = ProcessInfo.processInfo.operatingSystemVersion
        components.queryItems = [URLQueryItem(name: "body", value: """
            **What happened:**


            **What you expected:**


            ---
            \(content.appName) \(build.summary)
            visionOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
            """)]
        return components.url!
    }

    private func checkForUpdates() async {
        checking = true
        defer { checking = false }
        guard let url = URL(string: "https://api.github.com/repos/\(content.repository)/commits/\(content.releaseBranch)") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sha"] as? String else {
            update = "Couldn't reach GitHub just now."
            return
        }
        if build.dirty {
            update = "This is a development build. The latest release is \(latest.prefix(7))."
        } else if let commit = build.commit {
            update = latest.hasPrefix(commit) || commit.hasPrefix(latest)
                ? "You're up to date."
                : "A different version is out (\(latest.prefix(7))). To update: \(content.updateInstructions)"
        } else {
            update = "The latest release is \(latest.prefix(7)); this build's commit is unknown. To update: \(content.updateInstructions)"
        }
    }
}

/// One of Trevorbilt's apps, large: its round icon, name, tagline and a line about it, the whole
/// card opening its App Store page.
struct ShowcaseCard: View {
    let icon: Image
    let name: String
    let tagline: String
    let line: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            VStack(spacing: 6) {
                icon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(.circle)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.tbHeader(16, bold: true, relativeTo: .headline))
                Text(tagline)
                    .font(.tbBody(13, weight: .bold, relativeTo: .footnote))
                    .foregroundStyle(Trevorbilt.orangeTint)
                Text(line)
                    .font(.tbBody(12, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(3, reservesSpace: true)
                Text("View in the App Store")
                    .font(.tbBody(13, weight: .bold, relativeTo: .footnote))
                    .foregroundStyle(Trevorbilt.darkGreen)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(Trevorbilt.orange, in: .capsule)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TrevorbiltTileButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the App Store")
    }
}

/// A smaller link, as a card: a symbol, a name and a line.
struct CompactLinkCard: View {
    let symbol: String
    let name: String
    let line: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.tbHeader(14, bold: true, relativeTo: .headline))
                    Text(line).font(.tbBody(12, relativeTo: .subheadline)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TrevorbiltTileButtonStyle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

/// A name in bold that opens its page, with a small arrow saying so; just the name without one.
/// Either way it takes a link's height (44 pt, to be easy to look at), so what's under it sits
/// the same under every name.
struct NameLink: View {
    let name: String
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Text(name).font(.tbBody(14, weight: .bold))
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.hoverEffect, .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        } else {
            Text(name).font(.tbBody(14, weight: .bold))
                .frame(minHeight: 44)
        }
    }
}

/// Credits, licences and the privacy note, in a sheet.
struct CreditsSheet: View {
    let content: AboutContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetContent(width: 560, height: 520, done: { dismiss() }) {
            TrevorbiltHeading("credits ", bold: "and licences", size: 22)
            TrevorbiltCard {
                VStack(alignment: .leading, spacing: 10) {
                    TrevorbiltSectionTitle("Credits", alignment: .leading)
                    ForEach(content.credits, id: \.name) { credit in
                        VStack(alignment: .leading, spacing: -6) {
                            NameLink(name: credit.name, url: credit.url)
                            Text(credit.role).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            TrevorbiltCard {
                VStack(alignment: .leading, spacing: 10) {
                    TrevorbiltSectionTitle("Licences", alignment: .leading)
                    ForEach(content.notices, id: \.title) { notice in
                        VStack(alignment: .leading, spacing: -6) {
                            NameLink(name: notice.title, url: notice.url)
                            Text(notice.detail).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(content.disclaimer).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TrevorbiltCard {
                VStack(alignment: .leading, spacing: 8) {
                    TrevorbiltSectionTitle("Privacy", alignment: .leading)
                    Text("The Ports tab (only when you open it) and the update check (only when you tap it) contact GitHub, which sees your IP address like any website does. Nothing else leaves your Vision Pro: no analytics, no tracking.")
                        .font(.tbBody(12))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// What helps with a problem report: the build, the system, what's connected.
struct DiagnosticsSheet: View {
    let diagnostics: [(String, String)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetContent(done: { dismiss() }) {
            TrevorbiltHeading("diag", bold: "nostics", size: 22)
            TrevorbiltCard {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    ForEach(diagnostics, id: \.0) { item in
                        GridRow {
                            Text(item.0).font(.tbBody(12, weight: .bold))
                            Text(item.1).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}
