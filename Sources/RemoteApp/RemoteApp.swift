import AppKit
import AppleTVKit
import SwiftUI

@main
struct RemoteApp: App {
    @State private var store: DeviceStore
    @State private var coordinator: AppCoordinator
    @State private var keyMonitor: KeyMonitor
    @State private var hotKey: HotKey?

    init() {
        let store = DeviceStore()
        _store = State(initialValue: store)
        _coordinator = State(initialValue: AppCoordinator(store: store))
        _keyMonitor = State(initialValue: KeyMonitor(store: store))
    }

    /// Brings the remote window to the front from any app.
    private func summon() {
        NSApp.activate(ignoringOtherApps: true)
        // A closed SwiftUI window stays in the list as hidden. Ordering it front reopens it.
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Apple TV Remote" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        Window("Apple TV Remote", id: "main") {
            RemoteWindow()
                .environment(store)
                .environment(coordinator)
                .containerBackground(.ultraThinMaterial, for: .window)
                .onAppear {
                    keyMonitor.start()
                    coordinator.start()
                    if hotKey == nil { hotKey = HotKey { summon() } }
                }
                .onOpenURL { url in coordinator.handle(url) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .defaultSize(width: Tokens.windowWidth, height: Tokens.windowMinHeight)
        .commands { RemoteCommands(store: store, coordinator: coordinator) }

        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
                .environment(coordinator)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Remote menu. Every item maps to one command.
struct RemoteCommands: Commands {
    let store: DeviceStore
    let coordinator: AppCoordinator

    var body: some Commands {
        CommandMenu("Remote") {
            Button("Open App…") { store.paletteVisible.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Type Text") { store.keyboardVisible.toggle() }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Back") { store.click(.menu) }
            Button("TV") { store.click(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Play/Pause") { store.click(.playPause) }
            Divider()
            Button("Volume Up") { store.click(.volumeUp) }
            Button("Volume Down") { store.click(.volumeDown) }
            Divider()
            Button("Sleep") { store.click(.sleep) }
            Button("Wake") { coordinator.wakeSelected() }
            Button("Screensaver") { store.click(.screensaver) }
            Divider()
            Text("Summon from anywhere: ⌃⌥R")
        }
    }
}
