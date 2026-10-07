import CryptoKit
import ImageIO
import SwiftUI

/// A port's pictures, as the index lists them (feed 1.4, `entries[].media`): screenshots from its
/// README and its app icon, each at its reviewed commit and with the SHA-256 it must have. All of it
/// optional: a block this code can't read is simply no pictures.
public struct PortMedia: Decodable, Hashable {
    public struct Picture: Decodable, Hashable {
        public let url: String
        public let alt: String?
        public let width: Int?
        public let height: Int?
        public let bytes: Int?
        public let sha256: String
        /// An icon's layer: back, middle or front.
        public let layer: String?
    }

    /// A layered icon (back, middle, front, drawn in that order) or a flat one.
    public struct Icon: Hashable {
        public let layers: [Picture]
    }

    public let screenshots: [Picture]
    public let icon: Icon?

    enum CodingKeys: String, CodingKey { case screenshots, icon }
    enum IconKeys: String, CodingKey { case layers }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        screenshots = ((try? container?.decode([Lossy<Picture>].self, forKey: .screenshots)) ?? []).compactMap(\.value)
        icon = {
            guard let iconDecoder = try? container?.superDecoder(forKey: .icon),
                  let keyed = try? iconDecoder.container(keyedBy: IconKeys.self) else { return nil }
            // Layers wherever there are some (whatever its kind says); otherwise the icon itself, flat.
            if let listed = try? keyed.decode([Lossy<Picture>].self, forKey: .layers) {
                let order = ["back", "middle", "front"]
                let sorted = listed.compactMap(\.value)
                    .sorted { (order.firstIndex(of: $0.layer ?? "") ?? 3) < (order.firstIndex(of: $1.layer ?? "") ?? 3) }
                // A layer that's the same picture as the one under it would only draw it twice.
                var layers: [Picture] = []
                for layer in sorted where layer.sha256.lowercased() != layers.last?.sha256.lowercased() { layers.append(layer) }
                return layers.isEmpty ? nil : Icon(layers: layers)
            }
            return (try? Picture(from: iconDecoder)).map { Icon(layers: [$0]) }
        }()
    }

    /// Every picture's SHA-256: what the image cache keeps.
    var hashes: Set<String> { Set((screenshots + (icon?.layers ?? [])).map { $0.sha256.lowercased() }) }
}

/// Downloads a port's pictures only from GitHub, checks each against the SHA-256 the index gives,
/// and keeps them in Caches by that hash. Anything that can't be had that way (offline, a deleted
/// or private repository, a picture larger than 8 MB, a redirect elsewhere, the wrong bytes) is
/// simply no picture.
actor PortImages {
    static let shared = PortImages()

    /// SHAR_TEST_OFFLINE-style test runs: every download fails as it would offline.
    var offline = false
    func setOffline(_ value: Bool) { offline = value }

    private static let largest = 8 * 1024 * 1024
    private let session = URLSession(configuration: .ephemeral, delegate: GitHubOnly(), delegateQueue: nil)
    private var downloads: [String: Task<Data?, Never>] = [:]
    /// Decoded pictures for the grid (heroes, icons), about 16 MB at most; the detail strip's larger
    /// ones decode again from disk each time, quickly enough.
    private let decoded: NSCache<NSString, Decoded> = {
        let cache = NSCache<NSString, Decoded>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private static let keptDecoded = 600

    private final class Decoded {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrevorbiltKit/ports-media", isDirectory: true)
    }

    /// Only GitHub's own hosts, over https: where the index's links point, and where its raw files
    /// and attachments redirect.
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "raw.githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// The picture, at most `pixels` on its longer side (first frame only), or nil.
    func image(_ picture: PortMedia.Picture, pixels: Int) async -> CGImage? {
        let key = "\(picture.sha256)@\(pixels)" as NSString
        if let hit = decoded.object(forKey: key) { return hit.image }
        guard let data = await data(picture), !Task.isCancelled else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if pixels <= Self.keptDecoded { decoded.setObject(Decoded(image), forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    /// The picture's bytes, from the cache or GitHub, only if they hash to what the index says.
    private func data(_ picture: PortMedia.Picture) async -> Data? {
        let hash = picture.sha256.lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit), (picture.bytes ?? 0) <= Self.largest,
              let url = URL(string: picture.url), Self.allowed(url) else { return nil }
        let file = folder.appendingPathComponent(hash)
        if let cached = try? Data(contentsOf: file) {
            if Self.hash(cached) == hash { return cached }
            try? FileManager.default.removeItem(at: file)
        }
        if let running = downloads[hash] { return await running.value }
        // No more than the index says it is (or 8 MB), however much the server would send.
        let limit = min(picture.bytes ?? Self.largest, Self.largest)
        let task = Task<Data?, Never> { [session, offline] in
            guard !offline, let (bytes, response) = try? await session.bytes(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, Self.allowed(response.url),
                  response.expectedContentLength <= Int64(limit) else { return nil }
            var data = Data()
            data.reserveCapacity(Int(max(response.expectedContentLength, 0)))
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < limit else { return nil }
                    data.append(byte)
                }
            } catch {
                return nil
            }
            return Self.hash(data) == hash ? data : nil
        }
        downloads[hash] = task
        let data = await task.value
        // (Only its own: letGo may have dropped it, and another may have started since.)
        if downloads[hash] == task { downloads[hash] = nil }
        if let data {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return data
    }

    /// Lets go of every decoded picture and stops every download (the pictures are switched off
    /// while a game is loaded). What's on disk stays, for later.
    func letGo() {
        decoded.removeAllObjects()
        for download in downloads.values { download.cancel() }
        downloads.removeAll()
    }

    /// Drops every cached picture the current list no longer has.
    func prune(keeping hashes: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where !hashes.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lets a download follow a redirect only to GitHub's own hosts; any other is cancelled (and
    /// then fails as a non-200 answer).
    private final class GitHubOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            PortImages.allowed(request.url) ? request : nil
        }
    }
}

extension PortImages {
    /// Every layer of an icon, back to front, with its name (back, middle, front), or nil if any
    /// can't be had (half an icon is no icon).
    func icon(_ icon: PortMedia.Icon, pixels: Int) async -> [PortIconView.Layer]? {
        var layers: [PortIconView.Layer] = []
        for layer in icon.layers {
            guard let image = await image(layer, pixels: pixels) else { return nil }
            layers.append(PortIconView.Layer(name: layer.layer, image: image))
        }
        return layers
    }
}

/// A port's icon, round as visionOS draws them, with a thin glass ring: a layered one's layers
/// stacked, the front and middle drifting a little (3 and 1.5 pt) while `group` (its card) is
/// looked at.
struct PortIconView: View {
    struct Layer {
        let name: String?
        let image: CGImage
    }

    let layers: [Layer]
    var size: CGFloat = 52
    var group: HoverEffectGroup?

    var body: some View {
        ZStack {
            ForEach(layers.indices, id: \.self) { index in
                let drift: CGFloat = ["middle": 1.5, "front": 3][layers[index].name ?? ""] ?? 0
                Image(decorative: layers[index].image, scale: 1)
                    .resizable()
                    .hoverEffect(in: group, isEnabled: drift > 0) { effect, active, _ in
                        effect.offset(x: 0, y: active ? -drift : 0)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .accessibilityHidden(true)
    }
}
