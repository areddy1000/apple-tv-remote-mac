import AppleTVKit
import SwiftUI

/// The clickpad. Scroll to swipe, click to select, click an edge for a direction.
struct TouchSurfaceView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var feedback = SurfaceFeedback(pointer: nil, pressed: false, edge: nil, swipeOffset: .zero)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.touchCornerRadius, style: .continuous)
                    .fill(feedback.pressed ? Tokens.touchSurfaceActive : Tokens.touchSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.touchCornerRadius, style: .continuous)
                            .strokeBorder(Tokens.edge, lineWidth: 0.5)
                    )

                edgeHints(in: size)

                if let pointer = feedback.pointer {
                    Circle()
                        .fill(Tokens.ink.opacity(feedback.pressed ? 0.14 : 0.07))
                        .frame(width: feedback.pressed ? 44 : 36, height: feedback.pressed ? 44 : 36)
                        .blur(radius: 6)
                        .position(pointer)
                        .offset(feedback.swipeOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.touchCornerRadius, style: .continuous))
            .overlay {
                TrackpadBridge(
                    onTouch: { store.touch($0) },
                    onButton: { button, down in
                        if down { store.buttonDown(button) } else { store.buttonUp(button) }
                    },
                    onFeedback: { feedback = $0 }
                )
            }
            .animation(reduceMotion ? Motion.reduced : Motion.surface, value: feedback.pointer)
            .animation(reduceMotion ? Motion.reduced : Motion.press, value: feedback.pressed)
            .animation(reduceMotion ? nil : Motion.swipe, value: feedback.swipeOffset)
        }
        .accessibilityLabel("Touch surface")
        .accessibilityHint("Scroll to swipe. Click to select. Click an edge to move.")
    }

    /// Faint chevrons that light up when a direction is pressed.
    @ViewBuilder
    private func edgeHints(in size: CGSize) -> some View {
        let inset: CGFloat = 14
        ForEach([RemoteButton.up, .down, .left, .right], id: \.self) { button in
            let active = store.pressedButtons.contains(button) || feedback.edge == button
            Image(systemName: button.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Tokens.ink : Tokens.inkTertiary)
                .scaleEffect(active ? 1.15 : 1)
                .position(hintPosition(for: button, in: size, inset: inset))
                .animation(reduceMotion ? Motion.reduced : (active ? Motion.press : Motion.release), value: active)
                .allowsHitTesting(false)
        }
    }

    private func hintPosition(for button: RemoteButton, in size: CGSize, inset: CGFloat) -> CGPoint {
        switch button {
        case .up: CGPoint(x: size.width / 2, y: inset)
        case .down: CGPoint(x: size.width / 2, y: size.height - inset)
        case .left: CGPoint(x: inset, y: size.height / 2)
        default: CGPoint(x: size.width - inset, y: size.height / 2)
        }
    }
}
