import SwiftUI

/// A thin volume slider. Tracks the pointer 1:1 and sends while you drag.
/// It shows only when a volume level is known. In place of it, an Apple TV with no
/// volume route of its own gets a short notice.
struct VolumeSlider: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Holds the slot open when no level is known. The menu bar panel takes its height
    /// from what it holds, so it must not change when the output does.
    var reserveSpace = false

    @State private var dragging = false
    @State private var hovering = false

    private let trackHeight: CGFloat = 4
    private let knob: CGFloat = 14

    var body: some View {
        if let level = store.volume {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.inkTertiary)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let x = width * CGFloat(level)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.surfaceHover)
                            .frame(height: trackHeight)
                        Capsule().fill(dragging || hovering ? Tokens.ink.opacity(0.85) : Tokens.ink.opacity(0.6))
                            .frame(width: max(trackHeight, x), height: trackHeight)
                        Circle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .overlay(Circle().strokeBorder(Tokens.ink.opacity(0.35), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                            .frame(width: knob, height: knob)
                            .scaleEffect(dragging ? 1.25 : (hovering ? 1.1 : 1))
                            .position(x: min(max(x, knob / 2), width - knob / 2), y: proxy.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !dragging {
                                    dragging = true
                                    store.volumeDragging = true
                                }
                                let fraction = min(1, max(0, value.location.x / width))
                                store.setVolume(Double(fraction))
                            }
                            .onEnded { _ in
                                dragging = false
                                store.volumeDragging = false
                            }
                    )
                    .onHover { hovering = $0 }
                }
                .frame(height: knob + 6)
                .animation(reduceMotion ? Motion.reduced : Motion.press, value: dragging)
                .animation(Motion.hover, value: hovering)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.inkTertiary)
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(level * 100)) percent")
            .transition(.opacity)
        } else if store.volumeUnavailable {
            VolumeUnavailableNotice(height: knob + 6)
        } else if reserveSpace {
            // The slot keeps the panel's height, so it must still look like a volume row.
            // An empty band here shows the desktop through the panel.
            RestingVolumeRow(trackHeight: trackHeight, knob: knob)
        }
    }
}

/// The volume row at rest, for when no level is known yet.
///
/// It draws the same shapes as the slider, dimmed and inert, so the panel reads as a whole
/// app rather than one with a hole in it.
private struct RestingVolumeRow: View {
    var trackHeight: CGFloat
    var knob: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10, weight: .semibold))
            Capsule()
                .fill(Tokens.surfaceHover)
                .frame(height: trackHeight)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Tokens.inkTertiary)
        .opacity(0.6)
        .frame(height: knob + 6)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("Not available")
    }
}

/// Tells the user that this Apple TV gives the app no way to change the volume.
///
/// The Apple TV sends volume by infrared when the television offers no route of its own.
/// No network client can reach infrared, so the app must talk to the television itself.
/// The user sets that up with the volume hook.
///
/// It takes the height of the slider, so the menu bar panel keeps its size.
private struct VolumeUnavailableNotice: View {
    var height: CGFloat

    /// The full reason. The pointer and VoiceOver both read it.
    private static let detail = "This Apple TV has no volume route, so it sends volume by "
        + "infrared. No app can reach infrared. Give this app local access to your "
        + "television instead. The volume hook in the README tells you how."

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Volume needs local access to your TV")
                .font(Tokens.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(Tokens.inkSecondary)
        .frame(height: height)
        .help(Self.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.detail)
        .transition(.opacity)
    }
}
