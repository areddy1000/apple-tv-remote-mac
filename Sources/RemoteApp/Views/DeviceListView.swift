import AppKit
import AppleTVKit
import SwiftUI

/// The Apple TVs on the network now. It shows when no link is up.
/// A click opens one Apple TV. Nothing connects or pairs until the user asks on that screen.
struct DeviceListView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    @State private var openedID: String?

    var body: some View {
        Group {
            if let id = openedID, let device = store.knownDevices.first(where: { $0.id == id }) {
                DeviceDetailView(device: device) { openedID = nil }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.panelOpen, value: openedID)
        .padding(Tokens.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await coordinator.refreshKnown() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apple TVs")
                    .font(Tokens.deviceName)
                Spacer()
                Menu {
                    OpenAtLoginToggle()
                    Button("Quit Apple TV Remote") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Tokens.inkSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
            if let error = store.lastError {
                Text(error)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.knownDevices.isEmpty {
                // Bonjour keeps looking in the background. An Apple TV shows here when it appears.
                Text("No devices found")
                    .font(Tokens.body)
                    .foregroundStyle(Tokens.inkSecondary)
                    .padding(.top, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.knownDevices) { device in
                        Button { openedID = device.id } label: { DeviceRow(device: device) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// One Apple TV in the list.
private struct DeviceRow: View {
    let device: KnownDevice
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(Tokens.body)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text(device.state.label)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.inkTertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.inkTertiary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Tokens.surfaceHover : Tokens.surfaceRaised)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), \(device.state.label)")
        .accessibilityHint("Opens this Apple TV")
    }
}

/// One Apple TV with the actions its state allows. The back arrow does nothing else.
private struct DeviceDetailView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(AppCoordinator.self) private var coordinator
    let device: KnownDevice
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                Label("Apple TVs", systemImage: "chevron.left")
                    .font(Tokens.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.accent)
            .keyboardShortcut(.cancelAction)

            VStack(spacing: 10) {
                DeviceIcon(size: 64)
                Text(device.name)
                    .font(Tokens.deviceName)
                Text("\(device.model) · \(device.state.label)")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)

            VStack(spacing: 8) {
                switch device.state {
                case .paired:
                    Button("Connect") { coordinator.connect(id: device.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                case .notPaired:
                    Button("Pair") { coordinator.pair(id: device.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Text("Your TV will show a code.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }
}

/// The Apple TV symbol on a rounded tile.
private struct DeviceIcon: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Tokens.surfaceHover)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "appletv.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Tokens.inkSecondary)
            )
            .accessibilityHidden(true)
    }
}

extension KnownDevice.State {
    var label: String {
        switch self {
        case .paired: "Paired"
        case .notPaired: "Not paired"
        }
    }
}
