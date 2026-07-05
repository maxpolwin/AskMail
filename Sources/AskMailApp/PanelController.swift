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
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Follow the system Light/Dark setting; AskView's .ultraThinMaterial is
        // the frosted surface, so keep the window itself clear and non-opaque.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: AskView(model: viewModel))
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    private func open() {
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
