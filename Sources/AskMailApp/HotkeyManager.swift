import AskMailCore
import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey. Default is
/// Control+Shift+Space (see ShortcutSymbols.defaultModifiers for why it's not
/// Control+Option — that collides with VoiceOver's own modifier keys — nor
/// Cmd+B, the Bold conflict). Verified against FR-1 on a German layout by
/// using key codes, not characters. The binding can be changed at runtime
/// from Settings via `register`.
/// `@unchecked Sendable`: constructed and re-registered on the main thread
/// only (AppDelegate/Settings), and the Carbon application-target callback
/// below also fires on the main thread — the annotation exists so the
/// C-callback boundary, which the compiler can't see through, type-checks.
final class HotkeyManager: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: @MainActor () -> Void

    init(keyCode: UInt32 = UInt32(ShortcutSymbols.defaultKeyCode),
         modifiers: UInt32 = UInt32(ShortcutSymbols.defaultModifiers),
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application-target events on the main thread;
            // assumeIsolated documents that instead of hopping through a Task
            // (which would also need the non-Sendable manager to cross).
            MainActor.assumeIsolated { manager.handler() }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)

        register(keyCode: keyCode, modifiers: modifiers)
    }

    /// (Re)registers the global hotkey, replacing any previous binding. Safe to
    /// call whenever the user changes the shortcut in Settings.
    func register(keyCode: UInt32, modifiers: UInt32) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x41534B4D) /* 'ASKM' */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            RollingLog.shared.log("hotkey registration failed (status \(status)); the combo may already be in use", level: .error)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
