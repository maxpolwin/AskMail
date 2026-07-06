import XCTest
@testable import AskMailCore

/// Only live Inbox and Sent mail is vectorized; Trash, Junk, Archive, and
/// Drafts are excluded so deleted/spam/archived/unsent messages never enter the
/// searchable index (user decision 2026-07-06).
final class EmlxLocatorTests: XCTestCase {

    private func msg(_ mailboxPath: String, _ rowID: Int) -> URL {
        URL(fileURLWithPath:
            "/Users/x/Library/Mail/V10/ACCT/\(mailboxPath)/UUID/Data/0/0/Messages/\(rowID).emlx")
    }

    func testTopLevelMailboxIsFirstMboxComponent() {
        XCTAssertEqual(EmlxLocator.topLevelMailbox(of: msg("INBOX.mbox", 1)), "INBOX")
        XCTAssertEqual(EmlxLocator.topLevelMailbox(of: msg("Sent.mbox", 2)), "Sent")
        // A nested submailbox keys off the top-level parent, not the child.
        XCTAssertEqual(
            EmlxLocator.topLevelMailbox(of: msg("Archive.mbox/2023.mbox", 3)), "Archive")
        // A file under no .mbox folder has no mailbox.
        XCTAssertNil(EmlxLocator.topLevelMailbox(
            of: URL(fileURLWithPath: "/tmp/loose/5.emlx")))
    }

    func testOnlyInboxAndSentAreIndexed() {
        XCTAssertTrue(EmlxLocator.isIndexed(msg("INBOX.mbox", 1)))
        XCTAssertTrue(EmlxLocator.isIndexed(msg("Sent.mbox", 2)))
        // Common provider spellings of Sent, matched case-insensitively.
        XCTAssertTrue(EmlxLocator.isIndexed(msg("Sent Messages.mbox", 3)))
        XCTAssertTrue(EmlxLocator.isIndexed(msg("inbox.mbox", 4)))

        XCTAssertFalse(EmlxLocator.isIndexed(msg("Trash.mbox", 5)))
        XCTAssertFalse(EmlxLocator.isIndexed(msg("Junk.mbox", 6)))
        XCTAssertFalse(EmlxLocator.isIndexed(msg("Archive.mbox", 7)))
        XCTAssertFalse(EmlxLocator.isIndexed(msg("Archive.mbox/2023.mbox", 8)))
        XCTAssertFalse(EmlxLocator.isIndexed(msg("Drafts.mbox", 9)))
    }

    /// End-to-end over a real Apple-Mail-shaped directory tree: `scan` must
    /// return only the Inbox and Sent ROWIDs and drop everything else.
    func testScanReturnsOnlyInboxAndSentFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emlx-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // (mailbox path relative to the account root, ROWID, should-be-indexed)
        let layout: [(String, Int, Bool)] = [
            ("INBOX.mbox/A/Data/0/0/Messages", 1001, true),
            ("INBOX.mbox/A/Data/0/1/Messages", 1002, true),
            ("Sent.mbox/B/Data/0/0/Messages", 2001, true),
            ("Trash.mbox/C/Data/0/0/Messages", 3001, false),
            ("Junk.mbox/D/Data/0/0/Messages", 4001, false),
            ("Archive.mbox/E/Data/0/0/Messages", 5001, false),
            ("Archive.mbox/2023.mbox/F/Data/0/0/Messages", 5002, false),
            ("Drafts.mbox/G/Data/0/0/Messages", 6001, false),
        ]
        for (dir, rowID, _) in layout {
            let messagesDir = root.appendingPathComponent(dir, isDirectory: true)
            try FileManager.default.createDirectory(
                at: messagesDir, withIntermediateDirectories: true)
            try Data("x".utf8).write(
                to: messagesDir.appendingPathComponent("\(rowID).emlx"))
        }

        let found = Set(EmlxLocator.scan(accountDirectory: root).map(\.sourceID))
        let expected = Set(layout.filter(\.2).map { Int64($0.1) })
        XCTAssertEqual(found, expected,
                       "scan must return only Inbox and Sent ROWIDs")
    }
}
