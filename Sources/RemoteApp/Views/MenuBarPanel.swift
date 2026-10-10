import AppleTVKit
import SwiftUI

/// The compact remote in the menu bar panel.
struct MenuBarPanel: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DevicePicker()
                Spacer()
                StatusBadge()
                Button {
                    openWindow(id: RemoteApp.mainWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                    // One remote at a time. The panel folds back into the menu bar.
                    dismiss()
                } label: {
                    Label("Open Window", systemImage: "macwindow")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.inkSecondary)
                .help("Open the window")
            }
            .padding(.horizontal, Tokens.inset)
            .padding(.top, 14)
            RemoteBody(compact: true)
        }
        .frame(width: Tokens.compactWidth)
    }
}
