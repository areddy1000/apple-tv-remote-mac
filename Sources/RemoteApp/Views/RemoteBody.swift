import AppleTVKit
import SwiftUI

/// The remote itself, as the menu bar panel shows it.
struct RemoteBody: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The remote sets the size. The palette floats over it from the top edge.
        // Nothing here asks for more height, so the menu bar panel keeps its size.
        ZStack(alignment: .top) {
            VStack(spacing: 16) {
                if let info = store.nowPlaying {
                    // The card slides in from the top and pushes the remote down.
                    NowPlayingView(info: info)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                )
                        )
                } else {
                    // The panel keeps its height, so this slot never empties.
                    StatusCard()
                        .transition(.opacity)
                }
                // The menu bar panel does not bound the clickpad, so it gets a fixed height.
                TouchSurfaceView()
                    .frame(height: 220)
                TransportBar()
                if store.keyboardVisible {
                    KeyboardBar()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(Tokens.inset)
            .animation(reduceMotion ? Motion.reduced : Motion.panelOpen, value: store.nowPlaying == nil)

            if store.paletteVisible {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(reduceMotion ? Motion.reduced : Motion.panelClose) { store.paletteVisible = false }
                    }
                AppLauncherPalette()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    .padding(.top, 12)
            }
        }
        .animation(reduceMotion ? Motion.reduced : (store.paletteVisible ? Motion.panelOpen : Motion.panelClose), value: store.paletteVisible)
        .frame(width: Tokens.compactWidth)
    }
}
