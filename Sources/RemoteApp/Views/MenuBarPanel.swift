import AppleTVKit
import SwiftUI

/// The menu bar panel. With a link it shows the remote. Without one it shows the device list.
struct MenuBarPanel: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The remote stays in the layout under the list, so the panel keeps one height.
        // The menu bar window does not follow a change in content height well.
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack {
                    DevicePicker()
                    Spacer()
                    StatusBadge()
                }
                .padding(.horizontal, Tokens.inset)
                .padding(.top, 14)
                RemoteBody()
            }
            .opacity(store.showsRemote ? 1 : 0)
            .allowsHitTesting(store.showsRemote)
            .accessibilityHidden(!store.showsRemote)

            if !store.showsRemote {
                DeviceListView()
                    .transition(.opacity)
            }
        }
        .frame(width: Tokens.compactWidth)
        .animation(reduceMotion ? Motion.reduced : Motion.crossfade, value: store.showsRemote)
        // The PIN entry covers the panel, so the panel keeps its height while you pair.
        .overlay {
            if store.connection == .awaitingPIN {
                PairingSheet()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    .transition(.opacity)
            }
        }
        .animation(Motion.crossfade, value: store.connection == .awaitingPIN)
    }
}
