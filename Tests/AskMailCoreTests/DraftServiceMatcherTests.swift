import XCTest
@testable import AskMailCore

final class DraftServiceMatcherTests: XCTestCase {

    // MARK: quotedSenderEmail

    func testQuotedSenderEmailExtractsAddressFromMailsStandardQuoteHeader() {
        let text = "On 9. Jul 2026, at 18:57, Max Polwin <max.polwin@protonmail.com> wrote:\n\nHi Max,\n\nBody text."
        XCTAssertEqual(DraftServiceMatcher.quotedSenderEmail(in: text), "max.polwin@protonmail.com")
    }

    func testQuotedSenderEmailReturnsNilWhenNoAddressPresent() {
        XCTAssertNil(DraftServiceMatcher.quotedSenderEmail(in: "just some plain selected text, no email here"))
    }

    func testQuotedSenderEmailOnlyScansThePrefixNotTheWholeSelection() {
        let farAwayEmail = "<buried@example.com>"
        let text = String(repeating: "x", count: 600) + " \(farAwayEmail)"
        XCTAssertNil(DraftServiceMatcher.quotedSenderEmail(in: text))
    }

    /// The "On … wrote:" header's address is always angle-bracket-wrapped;
    /// a bare address with no brackets must not match (this is what makes
    /// the check meaningfully tighter than "an email exists somewhere").
    func testQuotedSenderEmailRejectsABareAddressWithNoAngleBrackets() {
        XCTAssertNil(DraftServiceMatcher.quotedSenderEmail(
            in: "On 9 Jul 2026, at 18:57, alice@example.com wrote:\n\nHi there."))
    }

    /// NSSendTypes are generic, so this can be invoked on a selection made
    /// in any app -- a signature block or contact card that merely contains
    /// a bracketed email is not Mail's quote header just because an email
    /// happens to be present somewhere in the selection.
    func testQuotedSenderEmailRejectsAnEmailNotOnTheFirstLine() {
        let text = "Some unrelated first line of selected text.\nOn 9 Jul 2026, Alice <alice@example.com> wrote:"
        XCTAssertNil(DraftServiceMatcher.quotedSenderEmail(in: text))
    }

    func testQuotedSenderEmailRejectsMalformedBracketContent() {
        XCTAssertNil(DraftServiceMatcher.quotedSenderEmail(in: "On 9 Jul 2026, Alice <not an email> wrote:"))
    }

    // MARK: match

    func testMatchThrowsNoSenderFoundWhenSelectionHasNoEmail() throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        XCTAssertThrowsError(try DraftServiceMatcher.match(selectionText: "no address here",
                                                            draftStore: draftStore, askStore: askStore)) { error in
            XCTAssertEqual(error as? DraftServiceMatcher.MatchError, .noSenderFound)
        }
    }

    func testMatchThrowsNoDraftForSenderWhenNoReadyDraftMatches() throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let selection = "On 9. Jul 2026, at 18:57, Alice <alice@example.com> wrote:\n\nHi there."
        XCTAssertThrowsError(try DraftServiceMatcher.match(selectionText: selection,
                                                            draftStore: draftStore, askStore: askStore)) { error in
            XCTAssertEqual(error as? DraftServiceMatcher.MatchError, .noDraftForSender)
        }
    }

    func testMatchFindsTheSingleReadyDraftForTheQuotedSender() throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        try draftStore.insertDraft(threadID: "t1", latestMessageID: "m1@x", sender: "Alice <alice@example.com>",
                                   subject: "Catch up", draftText: "Sure, Friday works!",
                                   generatedAt: 100, status: .ready)

        let selection = "On 9. Jul 2026, at 18:57, Alice <alice@example.com> wrote:\n\nAre you free Friday?"
        let match = try DraftServiceMatcher.match(selectionText: selection, draftStore: draftStore, askStore: askStore)
        XCTAssertEqual(match.draftText, "Sure, Friday works!")
        XCTAssertEqual(match.threadID, "t1")
    }

    func testMatchIgnoresNonReadyDraftsForTheSameSender() throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        try draftStore.insertDraft(threadID: "t1", latestMessageID: "m1@x", sender: "Alice <alice@example.com>",
                                   subject: "Old", draftText: "stale, still pending",
                                   generatedAt: 100, status: .pending)

        let selection = "On 9. Jul 2026, at 18:57, Alice <alice@example.com> wrote:\n\nAny update?"
        XCTAssertThrowsError(try DraftServiceMatcher.match(selectionText: selection,
                                                            draftStore: draftStore, askStore: askStore)) { error in
            XCTAssertEqual(error as? DraftServiceMatcher.MatchError, .noDraftForSender)
        }
    }

    /// Two open threads with the *same* correspondent, each with its own
    /// ready draft: the selection's quoted body should disambiguate by
    /// overlap with the original message body, not just fall back to
    /// most-recent when a stronger signal is available.
    func testMatchDisambiguatesSameSenderMultipleThreadsByBodyOverlap() throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()

        let threadA = try ThreadResolver.resolveThread(messageID: "a1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "a1@x", account: "acc", subject: "Berlin Summit",
                                   sender: "Alice <alice@example.com>", threadID: threadA,
                                   bodyText: "Would you be available in February to speak at the Berlin Summit?",
                                   dateUnix: 1)
        try draftStore.insertDraft(threadID: threadA, latestMessageID: "a1@x", sender: "Alice <alice@example.com>",
                                   subject: "Berlin Summit", draftText: "Happy to speak at the Berlin Summit!",
                                   generatedAt: 100, status: .ready)

        let threadB = try ThreadResolver.resolveThread(messageID: "a2@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "a2@x", account: "acc", subject: "Lunch next week",
                                   sender: "Alice <alice@example.com>", threadID: threadB,
                                   bodyText: "Are you free for lunch sometime next week to catch up?",
                                   dateUnix: 2)
        try draftStore.insertDraft(threadID: threadB, latestMessageID: "a2@x", sender: "Alice <alice@example.com>",
                                   subject: "Lunch next week", draftText: "Lunch sounds great, how's Tuesday?",
                                   generatedAt: 200, status: .ready)

        // Selects the *lunch* thread's quote, even though it's the older draft.
        let selection = "On 9. Jul 2026, at 18:57, Alice <alice@example.com> wrote:\n\n"
            + "Are you free for lunch sometime next week to catch up?"
        let match = try DraftServiceMatcher.match(selectionText: selection, draftStore: draftStore, askStore: askStore)
        XCTAssertEqual(match.threadID, threadB)
        XCTAssertEqual(match.draftText, "Lunch sounds great, how's Tuesday?")
    }

    func testMatchFallsBackToMostRecentWhenOverlapCannotDisambiguate() throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        // Two ready drafts for the same sender, but neither's original
        // message is resolvable from askStore (e.g. since pruned) -- the
        // overlap check can't run, so the most recently generated wins.
        try draftStore.insertDraft(threadID: "old", latestMessageID: "missing1@x", sender: "alice@example.com",
                                   subject: "Old thread", draftText: "old reply",
                                   generatedAt: 100, status: .ready)
        try draftStore.insertDraft(threadID: "new", latestMessageID: "missing2@x", sender: "alice@example.com",
                                   subject: "New thread", draftText: "new reply",
                                   generatedAt: 200, status: .ready)

        let selection = "On 9. Jul 2026, at 18:57, Alice <alice@example.com> wrote:\n\nsomething unrelated"
        let match = try DraftServiceMatcher.match(selectionText: selection, draftStore: draftStore, askStore: askStore)
        XCTAssertEqual(match.threadID, "new")
    }

    /// Regression for a real false-positive: "smith@corp.com" is a
    /// substring of "jblacksmith@corp.com", but they are different people.
    /// Only an exact address match may select a draft.
    func testMatchNeverFalsePositivesOnASubstringOfADifferentAddress() throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        try draftStore.insertDraft(threadID: "t1", latestMessageID: "m1@x",
                                   sender: "Jane Blacksmith <jblacksmith@corp.com>",
                                   subject: "Contract", draftText: "Blacksmith's private reply",
                                   generatedAt: 100, status: .ready)

        let selection = "On 9. Jul 2026, at 18:57, Smith <smith@corp.com> wrote:\n\nHi there."
        XCTAssertThrowsError(try DraftServiceMatcher.match(selectionText: selection,
                                                            draftStore: draftStore, askStore: askStore)) { error in
            XCTAssertEqual(error as? DraftServiceMatcher.MatchError, .noDraftForSender,
                           "smith@corp.com must never match a stored jblacksmith@corp.com draft")
        }
    }
}
