import XCTest
@testable import AskMailCore

final class ForwardedEmailTests: XCTestCase {

    func testAppleMailMarker() {
        let body = """
        Fyi, see below.

        Begin forwarded message:

        From: Jane Doe <jane@example.com>
        Subject: Project Update
        Date: March 3, 2026 at 10:15:32 AM PST
        To: John Smith <john@example.com>

        Here's the update.
        """
        XCTAssertEqual(ForwardedEmail.detectOriginalSender(in: body), "Jane Doe <jane@example.com>")
    }

    func testGmailMarker() {
        let body = """
        ---------- Forwarded message ---------
        From: Jane Doe <jane@example.com>
        Date: Mon, Mar 3, 2026 at 10:15 AM
        Subject: Project Update
        To: John Smith <john@example.com>

        Here's the update.
        """
        XCTAssertEqual(ForwardedEmail.detectOriginalSender(in: body), "Jane Doe <jane@example.com>")
    }

    func testOutlookMarker() {
        let body = """
        -----Original Message-----
        From: Jane Doe <jane@example.com>
        Sent: Monday, March 3, 2026 10:15 AM
        To: John Smith <john@example.com>
        Subject: Project Update

        Here's the update.
        """
        XCTAssertEqual(ForwardedEmail.detectOriginalSender(in: body), "Jane Doe <jane@example.com>")
    }

    func testNoMarkerReturnsNil() {
        XCTAssertNil(ForwardedEmail.detectOriginalSender(in: "Just a regular email, no forwarding here."))
    }

    func testMarkerWithoutFromLineReturnsNil() {
        let body = """
        Begin forwarded message:

        (no headers survived the copy-paste)
        """
        XCTAssertNil(ForwardedEmail.detectOriginalSender(in: body))
    }

    // MARK: stripHeaderBlock — must run before chunking/embedding so raw
    // mail headers never pollute the vector index.

    func testStripRemovesAppleMailHeaderBlock() {
        let body = """
        Fyi, see below.

        Begin forwarded message:

        From: Jane Doe <jane@example.com>
        Subject: Project Update
        Date: March 3, 2026 at 10:15:32 AM PST
        To: John Smith <john@example.com>

        Here's the update.
        """
        let cleaned = ForwardedEmail.stripHeaderBlock(from: body)
        XCTAssertEqual(cleaned, "Fyi, see below.\n\nHere's the update.")
    }

    func testStripRemovesGmailHeaderBlock() {
        let body = """
        ---------- Forwarded message ---------
        From: Jane Doe <jane@example.com>
        Date: Mon, Mar 3, 2026 at 10:15 AM
        Subject: Project Update
        To: John Smith <john@example.com>

        Here's the update.
        """
        XCTAssertEqual(ForwardedEmail.stripHeaderBlock(from: body), "Here's the update.")
    }

    func testStripRemovesOutlookHeaderBlock() {
        let body = """
        -----Original Message-----
        From: Jane Doe <jane@example.com>
        Sent: Monday, March 3, 2026 10:15 AM
        To: John Smith <john@example.com>
        Subject: Project Update

        Here's the update.
        """
        XCTAssertEqual(ForwardedEmail.stripHeaderBlock(from: body), "Here's the update.")
    }

    func testStripIsNoOpWithoutMarker() {
        let body = "Just a regular email, no forwarding here."
        XCTAssertEqual(ForwardedEmail.stripHeaderBlock(from: body), body)
    }

    func testStripStopsAtFirstNonHeaderLine() {
        // A stray content line right after the marker (no header block at
        // all) must not be eaten.
        let body = """
        Begin forwarded message:

        Hi, just wanted to loop you in on this.
        """
        XCTAssertEqual(ForwardedEmail.stripHeaderBlock(from: body),
                       "Hi, just wanted to loop you in on this.")
    }
}
