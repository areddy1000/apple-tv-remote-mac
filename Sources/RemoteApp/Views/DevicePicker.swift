import AppleTVKit
import SwiftUI

/// Toolbar menu that lists the Apple TVs on the network.
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
                Button {
                    coordinator.select(device)
                } label: {
                    if device.id == store.selectedDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(min(index + 1, 9)))), modifiers: .command)
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
                Text(store.selectedName)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .menuIndicator(.visible)
        .help("Choose an Apple TV")
    }
}
