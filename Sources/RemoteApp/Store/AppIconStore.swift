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
    private var inFlight: Set<String> = []
    private var missing: Set<String> = []
    private let directory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("AppleTVRemote/icons", isDirectory: true)
    }

    /// The icon when it is known. Starts a fetch the first time an id is asked for.
    func icon(for bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        if let icon = loadFromDisk(bundleID) {
            icons[bundleID] = icon
            return icon
        }
        if !inFlight.contains(bundleID), !missing.contains(bundleID) {
            inFlight.insert(bundleID)
            Task { await fetch(bundleID) }
        }
        return nil
    }

    private func fileURL(_ bundleID: String) -> URL {
        directory.appendingPathComponent(bundleID + ".png")
    }

    private func loadFromDisk(_ bundleID: String) -> NSImage? {
        guard let data = try? Data(contentsOf: fileURL(bundleID)) else { return nil }
        return NSImage(data: data)
    }

    private func fetch(_ bundleID: String) async {
        defer { inFlight.remove(bundleID) }
        guard let artworkURL = await Self.artworkURL(for: bundleID) else {
            missing.insert(bundleID)
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: artworkURL),
              let image = NSImage(data: data)
        else {
            missing.insert(bundleID)
            return
        }
        icons[bundleID] = image
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(bundleID), options: .atomic)
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
