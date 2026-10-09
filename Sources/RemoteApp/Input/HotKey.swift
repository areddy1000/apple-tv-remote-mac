import AppKit
import Carbon

/// A system-wide hotkey. Default: Control-Option-R summons the remote.
/// Carbon is the only public API for this without the Accessibility permission.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Key code for R.
    static let defaultKeyCode: UInt32 = 15
    static let defaultModifiers: UInt32 = UInt32(controlKey | optionKey)

    init(keyCode: UInt32 = HotKey.defaultKeyCode, modifiers: UInt32 = HotKey.defaultModifiers, action: @escaping () -> Void) {
        self.action = action
        register(keyCode: keyCode, modifiers: modifiers)
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, selfPointer, &handler)

        let id = EventHotKeyID(signature: OSType(0x4154_5652), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }

    /// Removes the hotkey. The app keeps one instance for its whole life, so this is rare.
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
