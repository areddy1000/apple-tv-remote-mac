import AppKit
import AppleTVKit
import Foundation
import Observation

/// Icons for the apps on the Apple TV.
///
/// The TV sends no icons over the control link. This store asks Apple's public app lookup
/// service for the artwork of each bundle identifier, once, and keeps the result on disk.
/// Only the bundle identifier leaves the Mac.
@MainActor
@Observable
final class AppIconStore {
    private(set) var icons: [String: NSImage] = [:]
    /// Identifiers with no artwork anywhere. They are not asked for again.
    private var missing: Set<String> = []
    private var loading: Set<String> = []
    private let directory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("AppleTVRemote/icons", isDirectory: true)
    }

    /// The icon when it is already known.
    /// This only reads, so a view may call it while it draws itself.
    func icon(for bundleID: String) -> NSImage? { icons[bundleID] }

    /// Looks on disk, then asks the lookup service. Call it from a view's `task`.
    /// A second call for the same identifier does nothing.
    func load(_ bundleID: String) async {
        guard icons[bundleID] == nil, !missing.contains(bundleID), !loading.contains(bundleID) else { return }
        loading.insert(bundleID)
        defer { loading.remove(bundleID) }

        let fileURL = directory.appendingPathComponent(bundleID + ".png")
        if let image = await Self.read(fileURL) {
            icons[bundleID] = image
            return
        }
        guard let artworkURL = await Self.artworkURL(for: bundleID),
              let (data, _) = try? await URLSession.shared.data(from: artworkURL),
              let image = NSImage(data: data)
        else {
            missing.insert(bundleID)
            return
        }
        icons[bundleID] = image
        await Self.write(data, to: fileURL, in: directory)
    }

    private static func read(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        }.value
    }

    private static func write(_ data: Data, to url: URL, in directory: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// Asks the lookup service for the artwork address. Nil when the app is not in the store.
    private static func artworkURL(for bundleID: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
        guard let url = components?.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let artwork = results.first?["artworkUrl100"] as? String
        else { return nil }
        // The service offers the same image at a larger size through the path.
        let larger = artwork.replacingOccurrences(of: "100x100bb", with: "128x128bb")
        return URL(string: larger)
    }
}
