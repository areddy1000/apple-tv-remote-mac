import AppKit
import AppleTVKit
import SwiftUI

/// The menu bar item. Shows the artwork and the title of what plays.
struct MenuBarLabel: View {
    let store: DeviceStore

    var body: some View {
        if let info = store.nowPlaying {
            HStack(spacing: 9) {
                if let thumbnail = store.artworkThumbnail {
                    Image(nsImage: thumbnail)
                } else {
                    Image(systemName: "appletv.fill")
                }
                Text(truncated(info.title))
                    // The same font the system clock uses in the menu bar.
                    .font(Font(NSFont.menuBarFont(ofSize: 0)))
            }
            .accessibilityLabel("Apple TV Remote, now playing \(info.title)")
        } else {
            Image(systemName: "appletv")
                .accessibilityLabel("Apple TV Remote")
        }
    }

    private func truncated(_ title: String) -> String {
        let limit = 26
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
