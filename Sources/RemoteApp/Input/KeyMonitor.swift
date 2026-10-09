import AppKit
import AppleTVKit

/// Maps Mac keys to remote buttons with true down and up events.
/// Keyboard actions never animate. The pressed state shows at once.
@MainActor
final class KeyMonitor {
    private var monitor: Any?
    private let store: DeviceStore

    init(store: DeviceStore) {
        self.store = store
    }

    private var observers: [Any] = []

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

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
        // Menus own the Command shortcuts.
        if event.modifierFlags.contains(.command) { return handleCommand(event) }
        guard let button = button(for: event) else { return event }
        if event.type == .keyDown {
            if event.isARepeat { return nil }
            store.buttonDown(button)
        } else {
            store.buttonUp(button)
        }
        return nil
    }

    private func button(for event: NSEvent) -> RemoteButton? {
        switch event.keyCode {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 36, 76: .select      // Return, keypad Enter
        case 53: .menu            // Escape
        case 49: .playPause       // Space
        case 51: .menu            // Delete acts as Back
        case 116: .pageUp
        case 121: .pageDown
        default: nil
        }
    }

    private func commandButton(for event: NSEvent) -> RemoteButton? {
        guard event.modifierFlags.contains(.command) else { return nil }
        switch event.keyCode {
        case 126: return .volumeUp
        case 125: return .volumeDown
        default: return nil
        }
    }

    /// Volume on Command-Up and Command-Down. Everything else passes to the menu.
    private func handleCommand(_ event: NSEvent) -> NSEvent? {
        guard let button = commandButton(for: event) else { return event }
        if event.type == .keyDown {
            if event.isARepeat { return nil }
            store.buttonDown(button)
        } else {
            store.buttonUp(button)
        }
        return nil
    }
}
