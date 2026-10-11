import AppKit
import AppleTVKit
import SwiftUI

@main
struct RemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var icons = AppIconStore()

    var body: some Scene {
        // The menu bar item shows only while an Apple TV is on the network.
        MenuBarExtra(isInserted: Binding(get: { !appDelegate.store.devices.isEmpty }, set: { _ in })) {
            MenuBarPanel()
                .environment(appDelegate.store)
                .environment(appDelegate.coordinator)
                .environment(icons)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the app state and starts it at launch. The app lives only in the menu bar, so no
/// window can start it, and URLs arrive here instead of at a window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: DeviceStore
    let coordinator: AppCoordinator
    private let keyMonitor: KeyMonitor
    private var hotKey: HotKey?

    override init() {
        let store = DeviceStore()
        self.store = store
        coordinator = AppCoordinator(store: store)
        keyMonitor = KeyMonitor(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.configureOnFirstLaunch()
        keyMonitor.start()
        coordinator.start()
        hotKey = HotKey { MenuBarPanelOpener.open() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(coordinator.handle)
    }
}

/// Opens the menu bar panel from code, for the hotkey and for pairing.
/// SwiftUI has no call for this, so it clicks the status item button.
@MainActor
enum MenuBarPanelOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        // The panel window is already open: bring it to the front.
        if let panel = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtra") }) {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let button = NSApp.windows
            .filter { String(describing: type(of: $0)).contains("StatusBar") }
            .compactMap { $0.contentView.flatMap(statusButton(in:)) }
            .first
        button?.performClick(nil)
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }
}
