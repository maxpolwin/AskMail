import AppKit
import AskMailCore
import SwiftUI

/// Floating, non-activating panel: hotkey toggles it; closing clears the
/// ephemeral session (FR-3).
@MainActor
final class PanelController {
    private let panel: NSPanel
    private let viewModel = AskViewModel()

    init() {
        // Tall, clear window: AskView floats a content-hugging card at the top,
        // so the extra height below is invisible and lets answers grow downward.
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        // User-resizable: drag any edge to change the card's format. The size
        // (but not position, which stays pinned top-center) persists across
        // relaunches under this autosave name.
        panel.minSize = NSSize(width: 420, height: 220)
        panel.setFrameAutosaveName("AskPanel")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Follow the system Light/Dark setting; AskView draws its own frosted,
        // rounded card (with its own shadow), so the window stays clear,
        // shadowless, and chrome-less — no close / minimize / zoom controls.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = NSHostingView(
            rootView: AskView(model: viewModel) { [weak self] in self?.close() }
        )
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    private func open() {
        viewModel.endSession()  // clean slate: every open starts empty (FR-3)
        positionTopCenter()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        panel.orderOut(nil)
        viewModel.endSession()  // ephemeral: buffer cleared when panel closes
    }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2,
                             y: frame.maxY - size.height - frame.height * 0.18)
        panel.setFrameOrigin(origin)
    }
}
