import AppKit
import AppleTVKit
import SwiftUI

/// The icon of one Apple TV app. Artwork when known, a symbol tile for Apple's own apps,
/// and a letter tile for the rest.
struct AppIconView: View {
    @Environment(AppIconStore.self) private var icons

    let app: LaunchableApp
    var size: CGFloat = 22

    private var radius: CGFloat { size * 0.22 }

    var body: some View {
        Group {
            if let image = icons.icon(for: app.bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if let tile = Self.appleTiles[app.bundleID] {
                ZStack {
                    tile.color
                    Image(systemName: tile.symbol)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                ZStack {
                    Tokens.surfaceHover
                    Text(String(app.name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Tokens.inkSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Tokens.edge, lineWidth: 0.5))
        .animation(Motion.crossfade, value: icons.icon(for: app.bundleID) != nil)
        .accessibilityHidden(true)
    }

    /// Apple's built-in apps are not in the App Store, so they get a symbol tile.
    private static let appleTiles: [String: (symbol: String, color: Color)] = [
        "com.apple.TVWatchList": ("play.tv.fill", .black),
        "com.apple.TVMusic": ("music.note", Color(red: 0.98, green: 0.22, blue: 0.35)),
        "com.apple.TVPhotos": ("photo.on.rectangle", Color(red: 0.98, green: 0.6, blue: 0.2)),
        "com.apple.TVSettings": ("gearshape.fill", Color(white: 0.45)),
        "com.apple.TVSearch": ("magnifyingglass", Color(white: 0.35)),
        "com.apple.TVAppStore": ("square.stack.3d.up.fill", Color(red: 0.1, green: 0.55, blue: 1.0)),
        "com.apple.Arcade": ("arcade.stick", Color(red: 0.95, green: 0.3, blue: 0.3)),
        "com.apple.Fitness": ("figure.run", Color(red: 0.85, green: 0.95, blue: 0.3)),
        "com.apple.podcasts": ("mic.fill", Color(red: 0.6, green: 0.3, blue: 0.9)),
        "com.apple.facetime": ("video.fill", Color(red: 0.2, green: 0.75, blue: 0.35)),
        "com.apple.TVHomeSharing": ("desktopcomputer", Color(white: 0.4)),
        "com.apple.Sing": ("music.mic", Color(red: 0.9, green: 0.3, blue: 0.6)),
    ]
}
