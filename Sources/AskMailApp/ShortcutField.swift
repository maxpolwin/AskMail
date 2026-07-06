import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click-to-record global-shortcut field. Shows the current combo; while
/// recording it swallows the next key press and stores its keyCode, modifiers,
/// and a layout-correct label. Requires at least one modifier so the global
/// hotkey can't be a bare key.
struct ShortcutField: View {
    @Binding var keyCode: Int
    @Binding var carbonModifiers: Int
    @Binding var label: String

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording.toggle()
        } label: {
            Text(recording
                 ? "Press shortcut\u{2026}"
                 : ShortcutSymbols.display(carbonModifiers: carbonModifiers, keyLabel: label))
                .font(.body.monospaced())
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .help("Click, then press a new key combination. Esc cancels.")
        .accessibilityLabel(recording
            ? "Recording new keyboard shortcut"
            : "Keyboard shortcut: \(ShortcutSymbols.spokenDescription(carbonModifiers: carbonModifiers, keyLabel: label))")
        .accessibilityHint("Click, then press a new key combination. Escape cancels.")
        .onChange(of: recording) { _, now in
            now ? startCapture() : stopCapture()
        }
        .onDisappear(perform: stopCapture)
    }

    private func startCapture() {
        stopCapture()  // guard against a stray existing monitor
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil  // swallow the keystroke while recording
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            recording = false      // cancel, keep the existing shortcut
            return
        }
        let carbon = ShortcutSymbols.carbonModifiers(from: event.modifierFlags)
        guard carbon != 0 else {   // demand at least one modifier
            NSSound.beep()
            return
        }
        keyCode = Int(event.keyCode)
        carbonModifiers = Int(carbon)
        label = ShortcutSymbols.keyLabel(keyCode: Int(event.keyCode), event: event)
        recording = false
    }
}

/// Formatting + modifier conversion shared by the recorder and any display.
enum ShortcutSymbols {
    /// Shipped default: Control+Shift+Space. Deliberately NOT Control+Option
    /// (or Caps Lock alone) — that's VoiceOver's own "VO keys" modifier
    /// prefix, and Control+Option+Space is literally VoiceOver's built-in
    /// "click the current item" command, so the previous default silently
    /// broke (or double-fired) for VoiceOver users. Also not Cmd+B (Bold
    /// conflict). Still user-configurable via the recorder above.
    static let defaultKeyCode = kVK_Space
    static let defaultModifiers = Int(controlKey | shiftKey)
    static let defaultKeyLabel = "Space"

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    static func display(carbonModifiers: Int, keyLabel: String) -> String {
        var symbols = ""
        if carbonModifiers & controlKey != 0 { symbols += "\u{2303}" }  // ⌃
        if carbonModifiers & optionKey  != 0 { symbols += "\u{2325}" }  // ⌥
        if carbonModifiers & shiftKey   != 0 { symbols += "\u{21E7}" }  // ⇧
        if carbonModifiers & cmdKey     != 0 { symbols += "\u{2318}" }  // ⌘
        return symbols + keyLabel
    }

    /// Stable, speakable name for Voice Control / VoiceOver. The on-screen
    /// combo is glyphs (e.g. "⌃⇧Space"), which don't reliably match what a
    /// user says or hears; this spells modifiers out as words instead, and
    /// stays the same regardless of the recorder's current visual state.
    static func spokenDescription(carbonModifiers: Int, keyLabel: String) -> String {
        var words: [String] = []
        if carbonModifiers & controlKey != 0 { words.append("Control") }
        if carbonModifiers & optionKey  != 0 { words.append("Option") }
        if carbonModifiers & shiftKey   != 0 { words.append("Shift") }
        if carbonModifiers & cmdKey     != 0 { words.append("Command") }
        words.append(keyLabel)
        return words.joined(separator: " ")
    }

    /// Special keys by name, otherwise the base character the physical key
    /// produces (`charactersIgnoringModifiers`) so it stays layout-correct.
    static func keyLabel(keyCode: Int, event: NSEvent) -> String {
        if let special = specialKeyName(keyCode) { return special }
        if let chars = event.charactersIgnoringModifiers, let first = chars.first,
           !first.isWhitespace {
            return chars.uppercased()
        }
        return "Key \(keyCode)"
    }

    static func specialKeyName(_ keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Del"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "\u{2190}"   // ←
        case kVK_RightArrow: return "\u{2192}"  // →
        case kVK_UpArrow: return "\u{2191}"     // ↑
        case kVK_DownArrow: return "\u{2193}"   // ↓
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return nil
        }
    }
}
