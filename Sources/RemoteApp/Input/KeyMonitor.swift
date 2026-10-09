import AppKit
import AppleTVKit

/// Maps Mac keys to remote buttons with true down and up events.
/// Keyboard actions never animate. The pressed state shows at once.
/// The app keeps one instance for its whole life.
@MainActor
final class KeyMonitor {
    /// Virtual key codes from the ANSI keyboard layout.
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let pageUp: UInt16 = 116
        static let pageDown: UInt16 = 121
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private let store: DeviceStore

    init(store: DeviceStore) {
        self.store = store
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        // A key-up can go missing when focus moves. Release every button when that happens.
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.releaseAll() }
            })
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // A key-up for a button that is down always releases it, whatever has focus.
        if event.type == .keyUp, let button = button(for: event) ?? commandButton(for: event),
           store.pressedButtons.contains(button) {
            store.buttonUp(button)
            return nil
        }
        // A text field keeps its keys.
        if let responder = event.window?.firstResponder, responder is NSTextView { return event }
        // Menus own the Command shortcuts, except the volume keys.
        let button: RemoteButton?
        if event.modifierFlags.contains(.command) {
            button = commandButton(for: event)
        } else {
            button = self.button(for: event)
        }
        guard let button else { return event }
        if event.type == .keyDown {
            // The TV repeats a held button on its own.
            if event.isARepeat { return nil }
            store.buttonDown(button)
        } else {
            store.buttonUp(button)
        }
        return nil
    }

    private func button(for event: NSEvent) -> RemoteButton? {
        switch event.keyCode {
        case KeyCode.up: .up
        case KeyCode.down: .down
        case KeyCode.left: .left
        case KeyCode.right: .right
        case KeyCode.returnKey, KeyCode.keypadEnter: .select
        case KeyCode.escape, KeyCode.delete: .menu
        case KeyCode.space: .playPause
        case KeyCode.pageUp: .pageUp
        case KeyCode.pageDown: .pageDown
        default: nil
        }
    }

    /// Command-Up and Command-Down change the volume.
    private func commandButton(for event: NSEvent) -> RemoteButton? {
        guard event.modifierFlags.contains(.command) else { return nil }
        switch event.keyCode {
        case KeyCode.up: return .volumeUp
        case KeyCode.down: return .volumeDown
        default: return nil
        }
    }
}
