import AppleTVKit
import SwiftUI

/// Sleeps an awake TV. Wakes a sleeping one. Acts on release so a slip can cancel.
struct PowerButtonView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: CGFloat = Tokens.buttonSize

    @State private var hovering = false
    @State private var pressed = false

    private var asleep: Bool { store.power == .asleep }

    var body: some View {
        ZStack {
            Circle()
                .fill(pressed ? Tokens.surfacePressed : (hovering ? Tokens.surfaceHover : Tokens.surfaceRaised))
                .overlay(Circle().strokeBorder(Tokens.edge, lineWidth: 0.5))
            Image(systemName: "power")
                .font(size >= Tokens.buttonSize ? Tokens.symbol : Tokens.symbolSmall)
                .foregroundStyle(asleep ? Tokens.inkTertiary : Tokens.ink)
                .contentTransition(.opacity)
                .animation(Motion.crossfade, value: asleep)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .scaleEffect(pressed && !reduceMotion ? Motion.pressScale : 1)
        .animation(pressed ? Motion.press : Motion.release, value: pressed)
        .animation(Motion.hover, value: hovering)
        .overlay {
            PressTracker(
                onHover: { hovering = $0 },
                onPress: { down in
                    if down {
                        pressed = true
                    } else if pressed {
                        pressed = false
                        store.togglePower()
                    }
                }
            )
        }
        .help(asleep ? "Wake Apple TV" : "Sleep Apple TV")
        .accessibilityLabel(asleep ? "Wake" : "Sleep")
        .accessibilityAddTraits(.isButton)
    }
}
