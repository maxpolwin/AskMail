import Carbon.HIToolbox
import XCTest
@testable import AskMailApp

final class ShortcutSymbolsTests: XCTestCase {
    /// Regression guard for the VoiceOver-collision fix: the shipped default
    /// must NOT be Control+Option (VoiceOver's own modifier prefix) or Caps
    /// Lock alone. If this ever fails, someone reverted the default hotkey
    /// back onto VoiceOver's command space.
    func testDefaultModifiersAvoidVoiceOverPrefix() {
        XCTAssertNotEqual(ShortcutSymbols.defaultModifiers, Int(controlKey | optionKey))
        XCTAssertEqual(ShortcutSymbols.defaultModifiers, Int(controlKey | shiftKey))
    }

    func testDefaultKeyUnchanged() {
        XCTAssertEqual(ShortcutSymbols.defaultKeyCode, kVK_Space)
        XCTAssertEqual(ShortcutSymbols.defaultKeyLabel, "Space")
    }

    func testDisplayRendersDefaultAsSymbols() {
        let combo = ShortcutSymbols.display(carbonModifiers: ShortcutSymbols.defaultModifiers,
                                            keyLabel: ShortcutSymbols.defaultKeyLabel)
        XCTAssertEqual(combo, "\u{2303}\u{21E7}Space")  // ⌃⇧Space
    }

    func testSpokenDescriptionSpellsOutModifiers() {
        let spoken = ShortcutSymbols.spokenDescription(carbonModifiers: ShortcutSymbols.defaultModifiers,
                                                       keyLabel: ShortcutSymbols.defaultKeyLabel)
        XCTAssertEqual(spoken, "Control Shift Space")
    }

    func testSpokenDescriptionCoversAllModifiersInOrder() {
        let allMods = Int(controlKey | optionKey | shiftKey | cmdKey)
        let spoken = ShortcutSymbols.spokenDescription(carbonModifiers: allMods, keyLabel: "K")
        XCTAssertEqual(spoken, "Control Option Shift Command K")
    }

    func testSpokenDescriptionWithNoModifiers() {
        // Not a reachable app state (the recorder requires >=1 modifier), but
        // the formatter itself should still degrade to just the key name.
        let spoken = ShortcutSymbols.spokenDescription(carbonModifiers: 0, keyLabel: "Space")
        XCTAssertEqual(spoken, "Space")
    }
}
