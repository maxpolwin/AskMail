import AppKit
import AskMailCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyManager?
    private var panel: PanelController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var draftsWindow: NSWindow?
    private var askMenuItem: NSMenuItem?
    private var draftsMenuItem: NSMenuItem?
    private var scheduler: VectorizationScheduler?
    private var draftScheduler: DraftScheduler?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        RollingLog.shared.log("app launched", level: .info)

        // macOS 26 (Tahoe) auto-adds system icons to menu items (Settings,
        // Quit, ...). Opt out before any menu is built. `set` (app domain), not
        // `register` (lowest-priority registration domain, which the system's
        // global default overrides) — the per-app `NSMenuEnableActionImages NO`.
        UserDefaults.standard.set(false, forKey: "NSMenuEnableActionImages")

        let panel = PanelController()
        self.panel = panel

        // Default Control+Shift+Space (docs/defaults.md); user-configurable
        // via settings (FR-1 / FR-9).
        hotkey = HotkeyManager(
            keyCode: UInt32(SettingsStore.shared.hotkeyKeyCode),
            modifiers: UInt32(SettingsStore.shared.hotkeyModifiers)
        ) { [weak panel] in
            panel?.toggle()
        }

        installMainMenu()
        setUpStatusItem()
        observeHotkeyChanges()
        observeDraftCounts()

        // Hourly incremental vectorization while on AC power (FR-5), plus a
        // catch-up at launch. Manual runs stay available in Settings (FR-6).
        let scheduler = VectorizationScheduler()
        scheduler.start()
        self.scheduler = scheduler

        // Draft-Modus's background scheduler. start() is unconditional, same
        // as VectorizationScheduler's — it stays fully inert until
        // SettingsStore.draftModeEnabled is switched on in Settings.
        let draftScheduler = DraftScheduler()
        draftScheduler.start()
        self.draftScheduler = draftScheduler

        // Phase 4 macOS Services menu (docs/draft-modus-plan.md): "Insert"/
        // "Regenerate" draft, registered via Packaging/Info.plist's
        // NSServices array. See DraftServiceProvider.swift.
        NSApp.servicesProvider = DraftServiceProvider()
        NSUpdateDynamicServices()
    }

    /// Installs a minimal main menu carrying the standard Edit commands.
    ///
    /// AppKit only turns ⌘X/⌘C/⌘V/⌘A/⌘Z into cut:/copy:/paste:/selectAll:/undo:
    /// when a menu item with that key equivalent exists in the main menu. This
    /// is a menu-bar (`.accessory`/`LSUIElement`) app with no menu bar, so
    /// without this the text fields in Settings only paste via the right-click
    /// menu (which AppKit's field editor supplies on its own). The menu isn't
    /// displayed for an accessory app — it exists purely so the key equivalents
    /// resolve to the focused text field through the responder chain.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // A conventional (hidden) app menu in the first slot.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit AskMail",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu: nil-target items dispatch to the first responder (the field
        // editor), so ⌘C/⌘V/… act on whatever text field is focused.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.hairlineStatusIcon()
        item.button?.setAccessibilityLabel("AskMail")
        let menu = NSMenu()
        let ask = NSMenuItem(title: askMenuTitle(), action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(ask)
        askMenuItem = ask
        // Draft-Modus surfacing (Task 2): always present, even before the
        // feature is ever turned on -- the count is simply 0 until it is.
        let drafts = NSMenuItem(title: draftsMenuTitle(), action: #selector(openDraftsWindow), keyEquivalent: "")
        menu.addItem(drafts)
        draftsMenuItem = drafts
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AskMail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        menu.items.last?.target = nil  // terminate goes to NSApp
        item.menu = menu
        statusItem = item
    }

    private func askMenuTitle() -> String {
        let settings = SettingsStore.shared
        let combo = ShortcutSymbols.display(carbonModifiers: settings.hotkeyModifiers,
                                            keyLabel: settings.hotkeyKeyLabel)
        return "Ask (\(combo))"
    }

    private func draftsMenuTitle() -> String {
        "Drafts (\(DraftEngine.shared.readyCount))"
    }

    /// Keeps the "Drafts (n)" menu title in sync with `DraftEngine`'s own
    /// count-refresh mechanism (after every tick, and whenever the Drafts or
    /// Settings window appears) instead of polling on a separate timer.
    private func observeDraftCounts() {
        DraftEngine.shared.$readyCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.draftsMenuItem?.title = "Drafts (\(count))"
            }
            .store(in: &cancellables)
    }

    /// Re-register the global hotkey (and refresh the menu label) whenever the
    /// shortcut changes in Settings — no restart needed (FR-9).
    private func observeHotkeyChanges() {
        let settings = SettingsStore.shared
        settings.$hotkeyKeyCode
            .combineLatest(settings.$hotkeyModifiers)
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] code, mods in
                MainActor.assumeIsolated {
                    self?.hotkey?.register(keyCode: UInt32(code), modifiers: UInt32(mods))
                    self?.askMenuItem?.title = self?.askMenuTitle() ?? "Ask"
                }
            }
            .store(in: &cancellables)
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
        // Reused window: SwiftUI's .onAppear does not reliably re-fire on
        // reorder-front, so refresh on every open the same way
        // openDraftsWindow already does -- otherwise Draft-Modus's status
        // line and learned-style section can show stale state after the
        // first open.
        DraftEngine.shared.refreshCounts()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDraftsWindow() {
        if draftsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AskMail Drafts"
            window.contentView = NSHostingView(rootView: DraftsView())
            window.isReleasedWhenClosed = false
            window.center()
            draftsWindow = window
        }
        DraftEngine.shared.refreshCounts()
        draftsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
