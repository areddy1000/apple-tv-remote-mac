import AppKit
import Carbon

/// A system-wide hotkey. Default: Control-Option-R opens the remote in the menu bar.
/// Carbon is the only public API for this without the Accessibility permission.
/// The app keeps one instance for its whole life, so there is no unregister path.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Virtual key code for R.
    static let defaultKeyCode: UInt32 = 15
    static let defaultModifiers = UInt32(controlKey | optionKey)
    /// Four-character tag "ATVR" that marks this app's hotkey events.
    private static let signature: OSType = 0x4154_5652

    init(keyCode: UInt32 = HotKey.defaultKeyCode, modifiers: UInt32 = HotKey.defaultModifiers, action: @escaping () -> Void) {
        self.action = action
        register(keyCode: keyCode, modifiers: modifiers)
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The handler receives `self` unretained. The instance outlives the handler, see above.
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, selfPointer, &handler)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }
}
