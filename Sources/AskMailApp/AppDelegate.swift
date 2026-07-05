import AppKit
import AskMailCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyManager?
    private var panel: PanelController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RollingLog.shared.log("app launched")
        let panel = PanelController()
        self.panel = panel

        // Default Control+Option+Space (docs/defaults.md); user-configurable
        // via settings (FR-1 / FR-9).
        hotkey = HotkeyManager(
            keyCode: UInt32(SettingsStore.shared.hotkeyKeyCode),
            modifiers: UInt32(SettingsStore.shared.hotkeyModifiers)
        ) { [weak panel] in
            panel?.toggle()
        }

        setUpStatusItem()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.hairlineStatusIcon()
        item.button?.setAccessibilityLabel("AskMail")
        let menu = NSMenu()
        menu.addItem(withTitle: "Ask (\u{2303}\u{2325}Space)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AskMail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        menu.items.last?.target = nil  // terminate goes to NSApp
        item.menu = menu
        statusItem = item
    }

    /// Minimal menu-bar mark: a single centered hairline, matching the app's
    /// hairline design language. Rendered as a template image so macOS tints it
    /// automatically for light/dark menu bars.
    private static func hairlineStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset: CGFloat = 3
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + inset, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - inset, y: rect.midY))
            path.lineWidth = 1.25
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func togglePanel() {
        panel?.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AskMail Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
