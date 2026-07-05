import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey. Default is
/// Control+Option+Space; deliberately not Cmd+B (Bold conflict). Verified
/// against FR-1 on a German layout by using key codes, not characters.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: @MainActor () -> Void

    init(keyCode: UInt32 = UInt32(kVK_Space),
         modifiers: UInt32 = UInt32(controlKey | optionKey),
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in manager.handler() }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x41534B4D) /* 'ASKM' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
