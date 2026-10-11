import AppleTVKit
import SwiftUI

/// The menu at the top of the remote. It names the connected Apple TV.
/// The app has no menu bar of its own, so this menu also holds the power actions and Quit.
/// Switching Apple TVs goes through the device list, which Disconnect shows.
struct DevicePicker: View {
    @Environment(DeviceStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Menu {
            Text(store.statusText)
            Divider()
            Button("Disconnect") { coordinator.disconnect() }
            Button("Forget This Apple TV…") { coordinator.forgetSelected() }
                .disabled(store.selectedDeviceID == nil)
            Divider()
            Button("Wake") { coordinator.wakeSelected() }
            Button("Sleep") { store.click(.sleep) }
            Button("Screensaver") { store.click(.screensaver) }
            Divider()
            OpenAtLoginToggle()
            Button("Quit Apple TV Remote") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(store.statusColor)
                    .frame(width: 7, height: 7)
                    .animation(Motion.hover, value: store.connection)
                    .accessibilityHidden(true)
                Text(store.selectedName)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .menuIndicator(.visible)
        .help("Apple TV actions")
        .accessibilityLabel("Apple TV: \(store.selectedName), \(store.statusText)")
    }
}
