import AppleTVKit
import SwiftUI

/// One circular remote button. Fires on mouse down. Shows keyboard presses too.
struct RemoteButtonView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let button: RemoteButton
    var size: CGFloat = Tokens.buttonSize
    var prominent = false

    @State private var hovering = false

    private var pressed: Bool { store.pressedButtons.contains(button) }

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(Tokens.edge, lineWidth: 0.5))
            Image(systemName: button.symbolName)
                .font(size >= Tokens.buttonSize ? Tokens.symbol : Tokens.symbolSmall)
                .foregroundStyle(prominent ? Tokens.accent : Tokens.ink)
                .opacity(pressed ? 0.85 : 1)
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
                    if down { store.buttonDown(button) } else { store.buttonUp(button) }
                }
            )
        }
        .help(button.title)
        .accessibilityLabel(button.title)
        .accessibilityAddTraits(.isButton)
    }

    private var fill: Color {
        if pressed { return Tokens.surfacePressed }
        if hovering { return Tokens.surfaceHover }
        return Tokens.surfaceRaised
    }
}
