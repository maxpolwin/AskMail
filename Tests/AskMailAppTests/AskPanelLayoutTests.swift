import AppKit
import SwiftUI
import XCTest
@testable import AskMailApp
@testable import AskMailCore

/// Layout checks for the Ask panel that need a real NSHostingView in a window.
@MainActor
final class AskPanelLayoutTests: XCTestCase {

    /// Hosts `AskView` at the panel's default size and lays it out.
    private func hostedPanel(_ model: AskViewModel,
                             size: NSSize = NSSize(width: 640, height: 500)) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: AskView(model: model))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func answeredModel() -> AskViewModel {
        let model = AskViewModel()
        model.question = "when is the contract due?"
        model.answer = String(repeating: "The contract is due Friday, Legal flagged a review window. ", count: 60)
        model.sources = (1...3).map { number in
            (number, SourceRef(messageID: "m\(number)@x", subject: "Subject \(number)",
                               sender: "sender@example.com", dateUnix: 1_772_439_240,
                               excerpt: "Excerpt \(number)"))
        }
        return model
    }

    /// The card's top-left margin (outside the question field) must hit the
    /// window-drag view, even with a long answer filling the card — the case
    /// where `isMovableByWindowBackground` alone let the user grab nothing.
    func testCardMarginHitsWindowDragArea() throws {
        let (window, hosting) = hostedPanel(answeredModel())
        _ = window  // keep the window alive for the hit test
        // Outer padding is 24pt and the card's own padding 16pt, so (30, 30)
        // in the (flipped) hosting view is inside the card's top margin, left
        // of the hover-only close button.
        XCTAssertTrue(hosting.isFlipped)
        let hit = try XCTUnwrap(hosting.hitTest(hosting.convert(NSPoint(x: 30, y: 30), to: hosting.superview)))
        XCTAssertTrue(hit.mouseDownCanMoveWindow, "margin hit \(type(of: hit)), not the drag area")
        XCTAssertTrue(String(describing: type(of: hit)).contains("DragView"))
    }
}
