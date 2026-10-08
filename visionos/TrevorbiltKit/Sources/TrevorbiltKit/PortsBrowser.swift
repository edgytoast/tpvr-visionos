import SwiftUI

// The AVP Ports Index's feed (feed/v1/index.json, schema 1.x), as far as a browser needs it. Every
// field but an entry's id and name is optional, and enums stay strings, so a value this build
// doesn't know never breaks reading the rest.
public struct PortsFeed: Decodable {
    public let schemaVersion: String
    public let identifier: String
    public let generatedAt: String?
    public internal(set) var entries: [PortEntry]
    public let tombstones: [String]

    enum CodingKeys: String, CodingKey { case schemaVersion, identifier, generatedAt, entries, tombstones }

    struct Tombstone: Decodable { let id: String }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        identifier = try container.decode(String.self, forKey: .identifier)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        entries = (try? container.decode([Lossy<PortEntry>].self, forKey: .entries))?.compactMap(\.value) ?? []
        if let ids = try? container.decode([String].self, forKey: .tombstones) {
            tombstones = ids
        } else {
            tombstones = ((try? container.decode([Lossy<Tombstone>].self, forKey: .tombstones)) ?? []).compactMap(\.value?.id)
        }
    }
}

/// One entry that fails to decode drops out on its own instead of taking the whole feed with it.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

public struct PortEntry: Decodable, Identifiable, Hashable {
    public struct Game: Decodable, Hashable { public let title: String?; public let originalPlatform: String?; public let originalReleaseYear: Int? }
    public struct Developer: Decodable, Hashable { public let name: String?; public let github: String?; public let url: String? }
    public struct Credit: Decodable, Hashable { public let name: String?; public let role: String?; public let url: String? }
    public struct Health: Decodable, Hashable { public let status: String? }
    public struct License: Decodable, Hashable { public let kind: String?; public let spdx: String? }

    public let id: String
    public let name: String
    public let game: Game?
    public let repoUrl: String?
    public let sourceUrl: String?
    public let installDocUrl: String?
    public let developer: Developer?
    public let credits: [Credit]?
    public let selfReportedStatus: String?
    public let statusNotes: String?
    public let curatorOwn: Bool?
    public let health: Health?
    public let scannedCommit: String?
    public let scannedAt: String?
    public let scanKind: String?
    public let commitsSinceScan: Int?
    public let license: License?
    public let experiences: [String]?
    public let description: String?
    public let pageUrl: String?
    public let archived: Bool?
    /// Its README's screenshots and its icon (feed 1.4); nil in older feeds.
    public internal(set) var media: PortMedia?

    var title: String { game?.title ?? name }
    var developerName: String { developer?.name ?? developer?.github ?? "an unnamed developer" }
}

/// The index's own words for things, so the app says what the index says.
enum PortsLabels {
    static let experience = ["2d": "2D", "3d-immersive": "3D immersive", "3d-shared-space": "3D shared space",
                             "3d-tabletop": "3D tabletop", "6dof-immersive": "6DoF immersive",
                             "6dof-progressive": "6DoF progressive"]
    static let status = ["developer-verified": "Developer verified", "working": "Working",
                         "partially-working": "Partially working", "not-working": "Not working"]
    static let platform = ["gamecube": "GameCube", "wii": "Wii", "n64": "Nintendo 64", "ps1": "PlayStation",
                           "ps2": "PlayStation 2", "xbox": "Xbox", "dreamcast": "Dreamcast", "pc": "PC", "other": "Other"]
    static func experienceLabel(_ value: String) -> String { experience[value] ?? value }
    /// "GameCube · 2006".
    static func origin(_ game: PortEntry.Game?) -> String? {
        let parts = [game?.originalPlatform.map { platform[$0] ?? $0 }, game?.originalReleaseYear.map(String.init)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    static func statusLabel(_ value: String?) -> String { value.flatMap { status[$0] ?? $0 } ?? "Status not given" }

    static func date(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Only https links leave the app, and only to where they say.
    static func link(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Fetches the feed only when asked (the Ports tab opening), at most once an hour, with a
/// conditional GET, and keeps the last good copy in Application Support.
@MainActor
@Observable
public final class PortsIndex {
    public enum State {
        case idle, loading
        /// `note`: why this is an older list (the newest copy couldn't be read).
        case loaded(PortsFeed, fetched: Date, note: String?)
        case unreadable(String)
        case failed(String)
    }

    public static let feedURL = URL(string: "https://raw.githubusercontent.com/edgytoast/avp-ports-index/main/feed/v1/index.json")!
    public static let readmeURL = URL(string: "https://github.com/edgytoast/avp-ports-index#readme")!

    private static let unreadableNote = "This version can't read the current index. The listing pages still work in Safari."
    private static let olderListNote = "This version can't read the newest index, so this is the last list it could read."

    public private(set) var state: State = .idle

    private let testFeed: URL?
    private let offline: Bool

    /// `testFeed`: read the list from this file, never the network (headless Simulator runs).
    /// `offline`: every picture download fails as it would offline (likewise).
    public init(testFeed: URL? = nil, offline: Bool = false) {
        self.testFeed = testFeed
        self.offline = offline
    }

    /// `etag` and `fetched` belong to the cached copy, which is always one that passed `parse`.
    /// `rejected`: when the index last answered with something this version can't read.
    private struct CacheMeta: Codable { var etag: String?; var fetched: Date; var rejected: Date?; var retryAfter: Date? }

    private var cacheFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TrevorbiltKit")
    }
    private var cacheFile: URL { cacheFolder.appendingPathComponent("ports-feed.json") }
    private var metaFile: URL { cacheFolder.appendingPathComponent("ports-feed-meta.json") }

    /// Shows the cached list, or fetches a newer one: at most hourly, never inside a Retry-After, and
    /// only a copy that reads replaces the last good one.
    public func load() async {
        if case .loading = state { return }
        if offline { await PortImages.shared.setOffline(true) }
        if let testFeed {
            state = (try? Data(contentsOf: testFeed)).flatMap(Self.parse).map { .loaded(prepared($0), fetched: Date(), note: nil) }
                ?? .unreadable(Self.unreadableNote)
            return
        }
        let cached = (try? Data(contentsOf: cacheFile)).flatMap(Self.parse).map(prepared)
        var meta = (try? Data(contentsOf: metaFile)).flatMap { try? JSONDecoder().decode(CacheMeta.self, from: $0) }
        let now = Date()
        func within(_ date: Date?, _ seconds: TimeInterval) -> Bool { date.map { now.timeIntervalSince($0) < seconds } ?? false }
        func showCached(note: String? = nil, otherwise: State) {
            if let cached, let meta { state = .loaded(cached, fetched: meta.fetched, note: note) } else { state = otherwise }
        }
        if let retryAfter = meta?.retryAfter, now < retryAfter {
            showCached(otherwise: .failed("The index is busy. Try again in a while."))
            return
        }
        if cached != nil && within(meta?.fetched, 3600) {
            showCached(otherwise: .idle)
            return
        }
        if within(meta?.rejected, 3600) {
            showCached(note: Self.olderListNote, otherwise: .unreadable(Self.unreadableNote))
            return
        }
        state = .loading
        var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if cached != nil, let etag = meta?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                if let feed = Self.parse(data) {
                    try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
                    try? data.write(to: cacheFile, options: .atomic)
                    meta = CacheMeta(etag: http?.value(forHTTPHeaderField: "ETag"), fetched: now)
                    state = .loaded(prepared(feed), fetched: now, note: nil)
                } else {
                    meta = CacheMeta(etag: meta?.etag, fetched: meta?.fetched ?? .distantPast, rejected: now)
                    showCached(note: Self.olderListNote, otherwise: .unreadable(Self.unreadableNote))
                }
            case 304:
                meta?.fetched = now
                meta?.rejected = nil
                showCached(otherwise: .unreadable(Self.unreadableNote))
            case 429, 503:
                let seconds = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 3600
                meta = CacheMeta(etag: meta?.etag, fetched: meta?.fetched ?? .distantPast, rejected: meta?.rejected,
                                 retryAfter: now.addingTimeInterval(seconds))
                showCached(otherwise: .failed("The index is busy. Try again in a while."))
            default:
                showCached(otherwise: .failed("The index didn't answer just now."))
            }
            if let meta, let encoded = try? JSONEncoder().encode(meta) {
                try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
                try? encoded.write(to: metaFile, options: .atomic)
            }
        } catch {
            showCached(otherwise: .failed("Couldn't reach the index. Are you online?"))
        }
    }

    /// A list as shown, with every cached picture it no longer has dropped.
    private func prepared(_ feed: PortsFeed) -> PortsFeed {
        let hashes = feed.entries.reduce(into: Set<String>()) { $0.formUnion($1.media?.hashes ?? []) }
        Task { await PortImages.shared.prune(keeping: hashes) }
        return feed
    }

    /// The feed, if it's the AVP Ports Index's and a version 1 schema this code reads.
    private static func parse(_ data: Data) -> PortsFeed? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let feed = try? decoder.decode(PortsFeed.self, from: data),
              feed.identifier == "com.trevorbilt.avp-ports-index",
              feed.schemaVersion.hasPrefix("1.") else { return nil }
        return feed
    }
}

/// The Ports tab: other ports in the AVP Ports Index, and this one's own listing.
public struct PortsBrowser: View {
    private let index: PortsIndex
    private let ownID: String
    private let buildCommit: String?
    private let buildDirty: Bool
    @State private var playsAs = "all"
    @State private var search = ""
    @State private var selected: PortEntry?
    @Namespace private var cards

    private let openingID: String?
    private let showsMedia: Bool

    /// `buildCommit`: the commit this app was built from (nil if unknown); `buildDirty`: a
    /// development build, whose commit says nothing about the reviewed one (BuildInfo).
    /// `opening`: an entry's id, to open its details once the list is in (for a port's headless
    /// screenshot runs). `showsMedia`: the ports' pictures; off while a game is loaded (one that
    /// runs once per process, with its memory in use), when every card and page is its words,
    /// nothing is downloaded or decoded, and what was decoded is let go.
    public init(index: PortsIndex, ownID: String, buildCommit: String?, buildDirty: Bool, opening: String? = nil,
                showsMedia: Bool = true) {
        self.index = index
        self.ownID = ownID
        self.buildCommit = buildCommit
        self.buildDirty = buildDirty
        openingID = opening
        self.showsMedia = showsMedia
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    TrevorbiltHeading("more games ", bold: "to port in", size: 24)
                    if case .loaded(_, let fetched, _) = index.state {
                        Text("Updated \(fetched.formatted(date: .abbreviated, time: .shortened))")
                            .font(.tbBody(12, relativeTo: .caption))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                switch index.state {
                case .idle, .loading:
                    notice
                    HStack(spacing: 8) { ProgressView(); Text("Reading the index…").font(.tbBody(13)) }
                        .padding(.top, 12)
                case .unreadable(let message), .failed(let message):
                    notice
                    TrevorbiltCard { StatusHeadline(.problem, title: "The index isn't available", detail: message) }
                case .loaded(let feed, _, let note):
                    loaded(feed, note: note)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .task {
            await index.load()
            if let openingID, case .loaded(let feed, _, _) = index.state {
                selected = feed.entries.first { $0.id == openingID }
            }
        }
        .sheet(item: $selected) { PortDetail(entry: $0, showsMedia: showsMedia) }
        .onChange(of: showsMedia, initial: true) { _, shows in
            if !shows { Self.letGoOfPictures() }
        }
    }

    /// Lets go of every picture the Ports tab has decoded and stops its downloads: call it as a
    /// game starts, so none of them stays in memory beside it. (A browser shown with `showsMedia`
    /// off does too.)
    public static func letGoOfPictures() {
        Task { await PortImages.shared.letGo() }
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Other people make these ports; the AVP Ports Index only links to them. Most listings are checked by automation and an AI review, not by a person. Building a port runs its scripts on your Mac, and you bring your own game files. This app shows each port's screenshots and icon from GitHub, but never downloads or installs a port. Links open in Safari.")
                    .font(.tbBody(12, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                if !showsMedia {
                    Text("Screenshots and icons are off while a game is open, so the game has the memory.")
                        .font(.tbBody(12, weight: .bold, relativeTo: .subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                Link(destination: PortsIndex.readmeURL) {
                    Text("Read before installing \u{203A}")
                        .font(.tbBody(12, weight: .bold, relativeTo: .subheadline))
                        .underline()
                        .frame(minHeight: 44)
                        .contentShape(.hoverEffect, .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder private func loaded(_ feed: PortsFeed, note: String?) -> some View {
        let visible = feed.entries.filter { !feed.tombstones.contains($0.id) && $0.archived != true }
        if let note {
            Text(note).font(.tbBody(13, relativeTo: .subheadline)).foregroundStyle(.white.opacity(0.8))
        }
        if let own = visible.first(where: { $0.id == ownID }) { ownListing(own) }
        notice
        let experiences = Array(Set(visible.flatMap { $0.experiences ?? [] })).sorted()
        TrevorbiltFlow(spacing: 8) {
            TrevorbiltChip("All", selected: playsAs == "all") { playsAs = "all" }
            ForEach(experiences, id: \.self) { value in
                TrevorbiltChip(PortsLabels.experienceLabel(value), selected: playsAs == value) { playsAs = value }
            }
        }
        if visible.count > 10 {
            TextField("Search games", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
        let shown = visible
            .filter { playsAs == "all" || ($0.experiences ?? []).contains(playsAs) }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if shown.isEmpty {
            Text("Nothing here plays that way yet.").font(.tbBody(13)).foregroundStyle(.white.opacity(0.8)).padding(.top, 12)
        }
        // Two to a row, each row's cards as tall as its tallest.
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: shown.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(shown[start..<min(start + 2, shown.count)]) { entry in
                        Button { selected = entry } label: {
                            PortCard(entry: entry, group: HoverEffectGroup(id: entry.id, in: cards, behavior: .followsGroup),
                                     showsMedia: showsMedia)
                        }
                        .buttonStyle(TrevorbiltTileButtonStyle())
                        .hoverEffectGroup(id: entry.id, in: cards)
                    }
                    if start + 1 == shown.count { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }

    private func ownListing(_ entry: PortEntry) -> some View {
        var parts = ["Listed in the AVP Ports Index", PortsLabels.statusLabel(entry.selfReportedStatus)]
        parts.append(entry.health?.status == "issues" ? "May have issues" : "Health OK")
        if let reviewed = PortsLabels.date(entry.scannedAt) { parts.append("Reviewed \(reviewed)") }
        let build: String
        if buildDirty {
            build = "This is a development build."
        } else if let buildCommit, let scanned = entry.scannedCommit {
            build = scanned.hasPrefix(buildCommit) || buildCommit.hasPrefix(scanned)
                ? "This build is the reviewed commit."
                : "This build is from \(buildCommit.prefix(7)); the reviewed commit is \(scanned.prefix(7))."
        } else {
            build = "This build's commit is unknown (it wasn't built from a git checkout)."
        }
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 20))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.joined(separator: " · ")).font(.tbBody(13, weight: .bold, relativeTo: .footnote))
                Text(build).font(.tbBody(12, relativeTo: .subheadline)).foregroundStyle(.white.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Trevorbilt.sage.opacity(0.22), in: shape)
        .overlay { shape.strokeBorder(Trevorbilt.sage.opacity(0.45), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// What a card or page loads its pictures for: anew when either changes.
struct MediaRequest: Hashable {
    let media: PortMedia?
    let shown: Bool
}

/// A port, as a card in the grid: led by its README's first screenshot, with its icon half over
/// that screenshot's edge (or, with no screenshot, beside the title). A picture that can't be had
/// is simply not there; the card is its words.
struct PortCard: View {
    let entry: PortEntry
    /// The card's hover group, for the icon's drift.
    var group: HoverEffectGroup?
    var showsMedia = true
    @State private var hero: CGImage?
    @State private var icon: [PortIconView.Layer]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hero {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { Image(decorative: hero, scale: 1).resizable().scaledToFill() }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if let icon { PortIconView(layers: icon, group: group).offset(x: 14, y: 26) }
                    }
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 12) {
                if hero == nil, let icon { PortIconView(layers: icon, group: group) }
                words
            }
            // Below an icon that hangs from the screenshot.
            .padding(.top, hero != nil && icon != nil ? 26 : 0)
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .task(id: MediaRequest(media: entry.media, shown: showsMedia)) {
            guard showsMedia, let media = entry.media else {
                hero = nil
                icon = nil
                return
            }
            async let shot = Self.first(media.screenshots)
            async let layers = Self.icon(media.icon)
            let (loadedHero, loadedIcon) = await (shot, layers)
            // A card that's gone (or asked again) keeps what it has.
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                hero = loadedHero
                icon = loadedIcon
            }
        }
    }

    private static func first(_ screenshots: [PortMedia.Picture]) async -> CGImage? {
        guard let first = screenshots.first else { return nil }
        return await PortImages.shared.image(first, pixels: 600)
    }

    private static func icon(_ icon: PortMedia.Icon?) async -> [PortIconView.Layer]? {
        guard let icon else { return nil }
        return await PortImages.shared.icon(icon, pixels: 128)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let origin = PortsLabels.origin(entry.game) {
                Text(origin.uppercased())
                    .font(.tbBody(11, weight: .bold, relativeTo: .caption2))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text(entry.title)
                .font(.tbHeader(15, bold: true, relativeTo: .headline))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            Text("\(entry.name) by \(entry.developerName) · \(PortsLabels.statusLabel(entry.selfReportedStatus))")
                .font(.tbBody(12, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            TrevorbiltFlow(alignment: .leading, spacing: 4) {
                ForEach(entry.experiences ?? [], id: \.self) { Tag(text: PortsLabels.experienceLabel($0)) }
                if entry.health?.status == "issues" { Tag(text: "May have issues", emphasis: true) }
                if entry.curatorOwn == true { Tag(text: "Trevorbilt's own port") }
            }
            .padding(.top, 2)
        }
    }
}

struct Tag: View {
    let text: String
    var emphasis = false

    var body: some View {
        HStack(spacing: 4) {
            if emphasis {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Trevorbilt.orangeTint).accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.tbBody(11, weight: emphasis ? .bold : .medium, relativeTo: .caption2))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.1), in: .capsule)
    }
}

/// A port's details, in a sheet: what it is, how it's doing, and where to read more.
struct PortDetail: View {
    let entry: PortEntry
    var showsMedia = true
    @Environment(\.dismiss) private var dismiss
    @State private var shots: [(picture: PortMedia.Picture, image: CGImage)] = []
    @State private var page: Int?

    var body: some View {
        SheetContent(width: 560, height: 520, done: { dismiss() }) {
            VStack(spacing: 8) {
                if let origin = PortsLabels.origin(entry.game) {
                    Text(origin.uppercased())
                        .font(.tbBody(11, weight: .bold, relativeTo: .caption))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(entry.title)
                    .font(.tbHeader(22, bold: true, relativeTo: .title2))
                    .multilineTextAlignment(.center)
                Text("\(entry.name) by \(entry.developerName)")
                    .font(.tbBody(13))
                    .foregroundStyle(.white.opacity(0.8))
            }
            if !shots.isEmpty { screenshots }
            if let description = entry.description {
                Text(description)
                    .font(.tbBody(13))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TrevorbiltCard {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                        fact("Status", PortsLabels.statusLabel(entry.selfReportedStatus))
                        fact("Plays as", (entry.experiences ?? []).map(PortsLabels.experienceLabel).joined(separator: ", "))
                        fact("Licence", entry.license?.spdx ?? (entry.license?.kind == "none" ? "No licence stated" : entry.license?.kind ?? "Not stated"))
                        if let scanned = entry.scannedCommit {
                            let when = PortsLabels.date(entry.scannedAt).map { " on \($0)" } ?? ""
                            let since = entry.commitsSinceScan.map { $0 == 0 ? "" : ", \($0) commits since" } ?? ""
                            fact("Reviewed", "\(entry.scanKind == "automated" ? "By automation" : "Reviewed")\(when), at \(scanned.prefix(7))\(since)")
                        }
                        if entry.health?.status == "issues" { fact("Health", "May have issues") }
                    }
                    if let notes = entry.statusNotes {
                        Text(notes).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(spacing: 14) {
                if let url = PortsLabels.link(entry.pageUrl) {
                    VStack(spacing: 4) {
                        Link("Listing page", destination: url).buttonStyle(TrevorbiltPrimaryButtonStyle(width: 240))
                        Text(url.host ?? "").font(.tbBody(11, relativeTo: .caption)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    secondaryLink("Install guide (reviewed commit)", entry.installDocUrl)
                    secondaryLink("Source (reviewed commit)", entry.sourceUrl)
                }
            }
            if let credits = entry.credits, !credits.isEmpty {
                TrevorbiltCard {
                    VStack(alignment: .leading, spacing: 10) {
                        TrevorbiltSectionTitle("Credits", alignment: .leading)
                        ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credit.name ?? "Unnamed").font(.tbBody(13, weight: .bold))
                                if let role = credit.role {
                                    Text(role).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: MediaRequest(media: entry.media, shown: showsMedia)) {
            guard showsMedia else {
                shots = []
                return
            }
            // All of them before any shows, in the README's order, so the strip appears once.
            let pictures = Array((entry.media?.screenshots ?? []).prefix(3))
            let images = await withTaskGroup(of: (Int, CGImage?).self) { group in
                for (index, picture) in pictures.enumerated() {
                    group.addTask { (index, await PortImages.shared.image(picture, pixels: 1200)) }
                }
                return await group.reduce(into: [Int: CGImage]()) { $0[$1.0] = $1.1 }
            }
            let loaded = pictures.indices.compactMap { index in images[index].map { (picture: pictures[index], image: $0) } }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { shots = loaded }
        }
    }

    /// A screenshot's alt text, or, with none (or only spaces), where it's from.
    private static func label(_ alt: String?, port: String) -> String {
        guard let alt, !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Screenshot from \(port)'s README" }
        return alt
    }

    /// Up to three of its README's screenshots, a page each, swiped through.
    private var screenshots: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(shots.indices, id: \.self) { index in
                        Color.black.opacity(0.35)
                            .overlay { Image(decorative: shots[index].image, scale: 1).resizable().scaledToFit() }
                            .containerRelativeFrame(.horizontal)
                            .accessibilityElement()
                            .accessibilityLabel(Self.label(shots[index].picture.alt, port: entry.name))
                            .accessibilityAddTraits(.isImage)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 8) {
                if shots.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(shots.indices, id: \.self) { index in
                            Circle().fill(.white.opacity(index == (page ?? 0) ? 0.9 : 0.35)).frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text("Images from the port's README").font(.tbBody(11, relativeTo: .caption)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.tbBody(12, weight: .bold))
            Text(value).font(.tbBody(12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func secondaryLink(_ title: String, _ string: String?) -> some View {
        if let url = PortsLabels.link(string) {
            VStack(spacing: 4) {
                Link(title, destination: url).buttonStyle(TrevorbiltSecondaryButtonStyle())
                Text(url.host ?? "").font(.tbBody(11, relativeTo: .caption)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}
