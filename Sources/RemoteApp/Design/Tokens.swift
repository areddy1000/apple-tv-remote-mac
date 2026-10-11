import AppKit
import SwiftUI

/// Design tokens. Every color, size and radius in the app comes from here.
enum Tokens {
    // MARK: Surfaces

    /// A button at rest.
    static let surfaceRaised = Color.primary.opacity(0.07)
    /// A button under the pointer.
    static let surfaceHover = Color.primary.opacity(0.11)
    /// A button while pressed.
    static let surfacePressed = Color.primary.opacity(0.18)
    /// The touch surface at rest.
    static let touchSurface = Color.primary.opacity(0.045)
    /// The touch surface while a finger is down.
    static let touchSurfaceActive = Color.primary.opacity(0.07)
    /// A hairline edge on glass.
    static let edge = Color.primary.opacity(0.08)

    // MARK: Ink

    static let ink = Color.primary
    static let inkSecondary = Color.secondary
    static let inkTertiary = Color.primary.opacity(0.35)
    static let accent = Color.accentColor
    /// A muted red for errors. The system red is too bright for text in a small panel.
    static let danger = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xD9 / 255, green: 0x8C / 255, blue: 0x84 / 255, alpha: 1)
            : NSColor(srgbRed: 0xA8 / 255, green: 0x46 / 255, blue: 0x3F / 255, alpha: 1)
    })

    // MARK: Geometry

    static let compactWidth: CGFloat = 300
    static let buttonSize: CGFloat = 54
    static let buttonSizeCompact: CGFloat = 46
    static let buttonSpacing: CGFloat = 14
    static let touchCornerRadius: CGFloat = 28
    static let inset: CGFloat = 20
    /// The now-playing card keeps this height in the menu bar panel, which sizes
    /// itself to its content and must not change height as playback changes.
    static let compactCardHeight: CGFloat = 96

    // MARK: Type

    static let deviceName = Font.system(size: 17, weight: .semibold)
    static let nowPlayingTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium)
    static let time = Font.system(size: 12, weight: .regular, design: .default).monospacedDigit()
    static let symbol = Font.system(size: 18, weight: .medium)
    static let symbolSmall = Font.system(size: 15, weight: .medium)
}
