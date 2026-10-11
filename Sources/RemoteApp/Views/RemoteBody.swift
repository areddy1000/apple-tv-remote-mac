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
                if store.showsRemote, let info = store.nowPlaying {
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
                if store.showsRemote {
                    TouchSurfaceView()
                        .frame(height: 220)
                } else {
                    // The hidden remote keeps its size, but drops the trackpad tracking area.
                    Color.clear
                        .frame(height: 220)
                }
                TransportBar()
            }
            .padding(Tokens.inset)
            .animation(reduceMotion ? Motion.reduced : Motion.panelOpen, value: store.nowPlaying == nil)
            // The bar floats over the remote. In the layout it would change the height, and
            // the menu bar window grows for that but never shrinks back. The window then
            // centres the smaller remote and the desktop shows through the top and bottom.
            .overlay(alignment: .bottom) {
                if store.keyboardVisible {
                    KeyboardBar()
                        .padding(.horizontal, Tokens.inset)
                        .padding(.bottom, Tokens.inset)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(reduceMotion ? Motion.reduced : Motion.panelOpen, value: store.keyboardVisible)

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
