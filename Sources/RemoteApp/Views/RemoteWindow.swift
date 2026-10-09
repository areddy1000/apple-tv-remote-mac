import AppleTVKit
import SwiftUI

/// The main window. A translucent sheet of glass with the remote on it.
struct RemoteWindow: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        RemoteBody()
            .frame(minHeight: Tokens.windowMinHeight)
            .background(windowBackground)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    DevicePicker()
                }
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .sheet(isPresented: pairingPresented) {
                PairingSheet()
            }
    }

    @ViewBuilder
    private var windowBackground: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Color.clear
        }
    }

    private var pairingPresented: Binding<Bool> {
        Binding(
            get: { store.connection == .awaitingPIN },
            set: { _ in }
        )
    }
}
