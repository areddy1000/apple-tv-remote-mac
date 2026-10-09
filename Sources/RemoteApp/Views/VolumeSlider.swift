import SwiftUI

/// A thin volume slider. Tracks the pointer 1:1 and sends while you drag.
/// It shows only when the TV reports a volume level.
struct VolumeSlider: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        }
    }
}
