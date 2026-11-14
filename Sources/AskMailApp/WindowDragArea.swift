import AppKit
import SwiftUI

/// A transparent strip that moves its window when dragged. Placed behind the
/// Ask card's content, it makes the card's margins and the gaps between its
/// sections a reliable grab area.
///
/// `NSWindow.isMovableByWindowBackground` alone isn't enough here: a
/// SwiftUI-hosted window only honours it on background the hosting view
/// reports as movable, and once an answer streams in nearly the whole card is
/// the question field or selectable answer text — so a drag selected text or
/// did nothing. Calling `performDrag(with:)` from our own `mouseDown` hands the
/// drag straight to the window server, independent of what SwiftUI is
/// re-rendering above it.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        // The panel is non-activating, so the first click must already drag
        // rather than only focus the window.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
