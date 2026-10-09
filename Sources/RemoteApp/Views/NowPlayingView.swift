import AppKit
import AppleTVKit
import SwiftUI

/// Title, artwork and a live progress bar for the current item.
struct NowPlayingView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let info: NowPlaying
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(Tokens.nowPlayingTitle)
                        .lineLimit(1)
                        .foregroundStyle(Tokens.ink)
                    Text(subtitle)
                        .font(Tokens.caption)
                        .lineLimit(1)
                        .foregroundStyle(Tokens.inkSecondary)
                }
                Spacer(minLength: 0)
                transport
            }
            if let duration = info.duration, duration > 0 {
                progress(duration: duration)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tokens.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Tokens.edge, lineWidth: 0.5))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing \(info.title)")
    }

    private var subtitle: String {
        [info.subtitle, info.appName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var artwork: some View {
        let side: CGFloat = compact ? 40 : 48
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Tokens.surfaceHover)
            if let data = info.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "play.tv")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Tokens.inkTertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(Motion.crossfade, value: info.artwork)
    }

    private var transport: some View {
        HStack(spacing: 2) {
            SmallIconButton(symbol: "gobackward.10", label: "Skip back") { store.media(.skipBackward) }
            SmallIconButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", label: info.isPlaying ? "Pause" : "Play") {
                store.media(.togglePlayPause)
            }
            SmallIconButton(symbol: "goforward.10", label: "Skip forward") { store.media(.skipForward) }
        }
    }

    private func progress(duration: Double) -> some View {
        TimelineView(.periodic(from: .now, by: info.isPlaying ? 0.5 : 60)) { context in
            let elapsed = info.elapsed(at: context.date)
            let fraction = max(0, min(1, elapsed / duration))
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.surfaceHover)
                        Capsule().fill(Tokens.ink.opacity(0.7))
                            .frame(width: max(3, proxy.size.width * fraction))
                    }
                }
                .frame(height: 3)
                HStack {
                    Text(timeString(elapsed))
                    Spacer()
                    Text("−" + timeString(duration - elapsed))
                }
                .font(Tokens.time)
                .foregroundStyle(Tokens.inkTertiary)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// A small borderless icon button with press feedback.
struct SmallIconButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Tokens.ink)
            .frame(width: 28, height: 28)
            .background(Circle().fill(pressed ? Tokens.surfacePressed : (hovering ? Tokens.surfaceHover : .clear)))
            .scaleEffect(pressed && !reduceMotion ? Motion.pressScale : 1)
            .animation(pressed ? Motion.press : Motion.release, value: pressed)
            .animation(Motion.hover, value: hovering)
            .overlay {
                PressTracker(
                    onHover: { hovering = $0 },
                    onPress: { down in
                        if down { pressed = true } else if pressed { pressed = false; action() }
                    }
                )
            }
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}
