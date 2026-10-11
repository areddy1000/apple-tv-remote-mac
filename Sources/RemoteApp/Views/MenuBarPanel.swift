import AppKit
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
        // The store polls the TV less while the panel is closed.
        // The menu bar window stays alive while closed, so onAppear and onDisappear do not
        // come on each open. The occlusion state of the window tells when the panel shows.
        .background(PanelVisibility { store.panelVisible = $0 })
    }
}

/// Reports when the menu bar panel window shows or hides, from its occlusion state.
struct PanelVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async {
            if let window = view.window { context.coordinator.watch(window) }
        }
    }

    /// A selector observer goes away with the coordinator, so it needs no remove step.
    @MainActor
    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void = { _ in }
        private weak var window: NSWindow?

        func watch(_ window: NSWindow) {
            guard self.window !== window else { return }
            if let old = self.window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: old)
            }
            self.window = window
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            onChange(window.occlusionState.contains(.visible))
        }

        @objc private func occlusionChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            onChange(window.occlusionState.contains(.visible))
        }
    }
}
