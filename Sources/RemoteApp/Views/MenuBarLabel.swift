import AppKit
import AppleTVKit
import SwiftUI

/// The menu bar item. Shows the artwork and the title of what plays.
struct MenuBarLabel: View {
    let store: DeviceStore

    var body: some View {
        if let info = store.nowPlaying {
            HStack(spacing: 9) {
                if let thumbnail = thumbnail(info.artwork) {
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

    /// A 16 point rounded thumbnail for the menu bar.
    /// The status item sets its own gap between image and title and ignores view spacing,
    /// so the gap lives inside the image as a clear margin on the right.
    private func thumbnail(_ data: Data?) -> NSImage? {
        guard let data, let source = NSImage(data: data) else { return nil }
        let side: CGFloat = 16
        let margin: CGFloat = 6
        let image = NSImage(size: NSSize(width: side + margin, height: side), flipped: false) { canvas in
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            let aspect = source.size.width / max(source.size.height, 1)
            var drawRect = rect
            if aspect > 1 {
                drawRect.size.width = rect.height * aspect
                drawRect.origin.x = (rect.width - drawRect.width) / 2
            } else if aspect < 1 {
                drawRect.size.height = rect.width / aspect
                drawRect.origin.y = (rect.height - drawRect.height) / 2
            }
            source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func truncated(_ title: String) -> String {
        let limit = 26
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
