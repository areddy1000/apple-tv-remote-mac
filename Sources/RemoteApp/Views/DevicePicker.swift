import AppleTVKit
import SwiftUI

/// Toolbar menu that lists the Apple TVs on the network.
/// The first nine get Command-1 to Command-9.
struct DevicePicker: View {
    @Environment(DeviceStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Menu {
            Text(store.statusText)
            Divider()
            if store.devices.isEmpty {
                Text("Looking for Apple TVs…")
            }
            ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                deviceButton(device, shortcut: index < 9 ? Character(String(index + 1)) : nil)
            }
            Divider()
            Button("Forget This Apple TV…") { coordinator.forgetSelected() }
                .disabled(store.selectedDeviceID == nil)
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
        .help("Choose an Apple TV")
        .accessibilityLabel("Apple TV: \(store.selectedName), \(store.statusText)")
    }

    @ViewBuilder
    private func deviceButton(_ device: DiscoveredDevice, shortcut: Character?) -> some View {
        let button = Button {
            coordinator.select(device)
        } label: {
            if device.id == store.selectedDeviceID {
                Label(device.name, systemImage: "checkmark")
            } else {
                Text(device.name)
            }
        }
        if let shortcut {
            button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        } else {
            button
        }
    }
}
