import AppleTVKit
import SwiftUI

/// The remote itself. The window and the menu bar panel both show it.
struct RemoteBody: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var compact = false

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                if let info = store.nowPlaying {
                    NowPlayingView(info: info, compact: compact)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                }
                // The window bounds the clickpad. The menu bar panel does not, so it gets a fixed height.
                TouchSurfaceView()
                    .frame(height: compact ? 220 : nil)
                    .frame(minHeight: compact ? nil : 230)
                TransportBar(compact: compact)
                if store.keyboardVisible {
                    KeyboardBar()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
                if let error = store.lastError {
                    HStack(spacing: 6) {
                        Text(error)
                            .font(Tokens.caption)
                            .foregroundStyle(Tokens.danger)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Image(systemName: "xmark.circle.fill")
                            .font(Tokens.caption)
                            .foregroundStyle(Tokens.inkTertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.lastError = nil }
                    .help("Click to dismiss")
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Click to dismiss")
                    .transition(.opacity)
                }
            }
            .padding(Tokens.inset)
            .animation(reduceMotion ? Motion.reduced : Motion.panelOpen, value: store.keyboardVisible)
            .animation(reduceMotion ? Motion.reduced : Motion.panelOpen, value: store.nowPlaying == nil)
            .animation(Motion.crossfade, value: store.lastError)

            if store.paletteVisible {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(reduceMotion ? Motion.reduced : Motion.panelClose) { store.paletteVisible = false }
                    }
                AppLauncherPalette()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(reduceMotion ? Motion.reduced : (store.paletteVisible ? Motion.panelOpen : Motion.panelClose), value: store.paletteVisible)
        .frame(width: compact ? Tokens.compactWidth : Tokens.windowWidth)
    }
}
