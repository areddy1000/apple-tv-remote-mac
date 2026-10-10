import SwiftUI

/// The progress bar. Drag anywhere on it to seek, the same as a video player.
/// The bar tracks the pointer 1:1 while you drag and seeks when you let go.
struct Scrubber: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The filled share of the bar, 0...1.
    let fraction: Double
    /// Non-nil while a drag is in progress. The parent shows this value.
    @Binding var scrubbing: Double?
    /// Called once on release with the final fraction.
    let onSeek: (Double) -> Void

    @State private var hovering = false

    private var active: Bool { scrubbing != nil || hovering }
    private var trackHeight: CGFloat { active ? 6 : 3 }
    private let knob: CGFloat = 12
    private let hitHeight: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = width * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.surfaceHover)
                    .frame(height: trackHeight)
                Capsule().fill(Tokens.ink.opacity(active ? 0.9 : 0.7))
                    .frame(width: max(trackHeight, x), height: trackHeight)
                Circle()
                    .fill(Tokens.ink)
                    .frame(width: knob, height: knob)
                    .scaleEffect(scrubbing != nil ? 1.3 : (hovering ? 1 : 0.01))
                    .opacity(active ? 1 : 0)
                    .position(x: min(max(x, knob / 2), max(width - knob / 2, knob / 2)), y: proxy.size.height / 2)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbing = Double(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { value in
                        let final = Double(min(1, max(0, value.location.x / width)))
                        scrubbing = nil
                        onSeek(final)
                    }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: hitHeight)
        .animation(reduceMotion ? Motion.reduced : Motion.press, value: active)
        .animation(reduceMotion ? Motion.reduced : Motion.press, value: scrubbing != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityHint("Drag to seek")
    }
}
