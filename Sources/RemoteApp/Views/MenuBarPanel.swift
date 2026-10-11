import AppleTVKit
import SwiftUI

/// The remote in the menu bar panel. The app has no other window.
struct MenuBarPanel: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
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
        .frame(width: Tokens.compactWidth)
        // The PIN entry covers the remote, so the panel keeps its height while you pair.
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
