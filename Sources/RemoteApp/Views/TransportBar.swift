import AppleTVKit
import SwiftUI

/// The physical buttons below the clickpad, then the volume slider.
struct TransportBar: View {
    var compact = false

    private var size: CGFloat { compact ? Tokens.buttonSizeCompact : Tokens.buttonSize }

    var body: some View {
        VStack(spacing: Tokens.buttonSpacing) {
            HStack(spacing: Tokens.buttonSpacing) {
                RemoteButtonView(button: .menu, size: size)
                RemoteButtonView(button: .home, size: size)
                RemoteButtonView(button: .playPause, size: size)
            }
            HStack(spacing: Tokens.buttonSpacing) {
                RemoteButtonView(button: .volumeDown, size: size)
                RemoteButtonView(button: .volumeUp, size: size)
                RemoteButtonView(button: .siri, size: size)
                PowerButtonView(size: size)
            }
            VolumeSlider()
        }
    }
}
