import AppKit
import AppleTVKit
import SwiftUI

@main
struct RemoteApp: App {
    static let mainWindowID = "main"
    static let windowTitle = "Apple TV Remote"

    @State private var store: DeviceStore
    @State private var icons = AppIconStore()
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
    @MainActor
    static func summon() {
        NSApp.activate(ignoringOtherApps: true)
        // A closed SwiftUI window stays in the list as hidden. Ordering it front reopens it.
        let window = NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix(mainWindowID) == true || $0.title == windowTitle
        }
        window?.makeKeyAndOrderFront(nil)
    }

    var body: some Scene {
        Window(Self.windowTitle, id: Self.mainWindowID) {
            RemoteWindow()
                .environment(store)
                .environment(coordinator)
                .environment(icons)
                .containerBackground(.ultraThinMaterial, for: .window)
                .onAppear {
                    keyMonitor.start()
                    coordinator.start()
                    if hotKey == nil { hotKey = HotKey { Self.summon() } }
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
                .environment(icons)
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
            // The system-wide hotkey is Control-Option-R. Menus cannot show a Carbon hotkey.
            Button("Show Remote") { RemoteApp.summon() }
        }
    }
}
