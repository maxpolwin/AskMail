import XCTest
@testable import AskMailCore

/// Thread-safe boolean latch, mirroring `DraftPipelineIntegrationTests.swift`'s
/// file-local helper of the same shape (the one in QueryFlowTests.swift is
/// `private` to that file).
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
}

/// Thread-safe counter, mirroring `QueryFlowTests.swift`'s file-local helper
/// of the same shape.
private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

/// Succeeds on its first `succeedForCalls` calls, then throws on every call
/// after -- used to prove `StyleLearner.learn`'s all-or-nothing persistence:
/// a failure partway through the per-scope merge loop must not leave any
/// earlier scope's profile update actually applied.
private final class FailAfterNChatProvider: ChatProvider, @unchecked Sendable {
    let name = "flaky-stub"
    private let lock = NSLock()
    private var callCount = 0
    let succeedForCalls: Int
    let successTokens: [String]

    init(succeedForCalls: Int, successTokens: [String] = ["profile text"]) {
        self.succeedForCalls = succeedForCalls
        self.successTokens = successTokens
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock(); callCount += 1; let thisCall = callCount; lock.unlock()
        return AsyncThrowingStream { continuation in
            if thisCall > succeedForCalls {
                continuation.finish(throwing: ProviderError.http(status: 500, body: "boom"))
            } else {
                for token in successTokens { continuation.yield(token) }
                continuation.finish()
            }
        }
    }
}

/// Simulates a concurrent Settings "Reset learned style" happening *during*
/// `learn`'s LLM merge calls: triggers the reset (bumping
/// `styleProfilesEpoch`) on the first `stream` call, before yielding any
/// tokens, then completes normally -- proving the epoch check in `learn`
/// discards the resulting stale write instead of persisting it.
private final class ResetMidMergeChatProvider: ChatProvider, @unchecked Sendable {
    let name = "reset-mid-merge-stub"
    private let draftStore: DraftStore
    private let lock = NSLock()
    private var triggered = false

    init(draftStore: DraftStore) { self.draftStore = draftStore }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        let shouldTrigger = !triggered
        triggered = true
        lock.unlock()
        if shouldTrigger {
            _ = try? draftStore.deleteStyleProfiles()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("merged profile text")
            continuation.finish()
        }
    }
}

final class StyleLearnerTests: XCTestCase {

    // MARK: StyleScope

    func testStyleScopeKeyFormats() {
        XCTAssertEqual(StyleScope.global, "global")
        XCTAssertEqual(StyleScope.domain("Bob <bob@newsletter.acme.com>"), "domain:acme")
        XCTAssertEqual(StyleScope.address("Bob <Bob@ACME.com>"), "address:bob@acme.com")
        XCTAssertNil(StyleScope.address("Internal Memo"), "a display-name-only sender has no address scope")
    }

    // MARK: buildMergePrompt (pure)

    func testBuildMergePromptUsesNoneYetPlaceholderWhenNilOrEmpty() {
        let withNil = StyleLearner.buildMergePrompt(existingProfile: nil, draftText: "d", actualText: "a")
        XCTAssertTrue(withNil.contains("CURRENT PROFILE:\n(none yet)"))

        let withEmpty = StyleLearner.buildMergePrompt(existingProfile: "", draftText: "d", actualText: "a")
        XCTAssertTrue(withEmpty.contains("CURRENT PROFILE:\n(none yet)"))

        let withExisting = StyleLearner.buildMergePrompt(existingProfile: "Terse, no greeting.", draftText: "d", actualText: "a")
        XCTAssertTrue(withExisting.contains("CURRENT PROFILE:\nTerse, no greeting."))
        XCTAssertTrue(withExisting.contains("DRAFT (what was auto-drafted):\nd"))
        XCTAssertTrue(withExisting.contains("ACTUAL (what the person actually sent):\na"))
    }

    // MARK: Helpers

    @discardableResult
    private func ingest(store: SQLiteStore, messageID: String, sender: String, bodyText: String,
                        inReplyTo: String? = nil, dateUnix: Int64) throws -> String {
        let references = inReplyTo.map { [$0] } ?? []
        let threadID = try ThreadResolver.resolveThread(messageID: messageID, inReplyTo: inReplyTo,
                                                        references: references, store: store)
        try store.upsertMessage(messageID: messageID, account: "acc", subject: "s", sender: sender,
                                inReplyTo: inReplyTo, referencesIDs: references,
                                threadID: threadID, bodyText: bodyText, dateUnix: dateUnix)
        return threadID
    }

    private let threeDays: Int64 = 3 * 86400

    // MARK: learnIfDue — happy path

    func testLearnIfDueFoldsMatchedPairIntoAllThreeScopesAndMarksLearned() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "Alice <alice@acme.com>",
                                  bodyText: "Can we push the deadline?", dateUnix: 1000)
        // The account's real reply, dated after the draft was generated.
        try ingest(store: askStore, messageID: "reply@x", sender: "Max <max@example.com>",
                  bodyText: "Sure, Friday works.", inReplyTo: "root@x", dateUnix: 1000 + threeDays + 100)

        let draftGeneratedAt: Int64 = 1000 + 10
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x", sender: "Alice <alice@acme.com>",
                                   subject: "Re: deadline", draftText: "Happy to push it to Friday.",
                                   generatedAt: draftGeneratedAt, status: .ready)

        let started = TestFlag()
        let stub = StubChatProvider(name: "stub-local", tokens: ["Signs off with just a first name."],
                                    onStart: { started.mark() })
        let now = Date(timeIntervalSince1970: Double(draftGeneratedAt + threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", now: now)

        XCTAssertTrue(started.value, "the local LLM must have been invoked for the matched pair")
        for scope in ["global", "domain:acme", "address:alice@acme.com"] {
            let profile = try XCTUnwrap(try draftStore.styleProfile(scope: scope), "expected a profile at scope \(scope)")
            XCTAssertEqual(profile.profileText, "Signs off with just a first name.")
            XCTAssertEqual(profile.sampleCount, 1)
        }
        XCTAssertTrue(try draftStore.draftsAwaitingStyleLearning(olderThanGeneratedAt: now.timeIntervalSince1970Int64, limit: 10).isEmpty,
                     "a fully-learned draft must not remain a candidate")
    }

    // MARK: learnIfDue — no match yet

    func testLearnIfDueLeavesDraftUnmarkedWhenNoSentReplyYet() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "alice@acme.com",
                                  bodyText: "Can we push the deadline?", dateUnix: 1000)
        let draftGeneratedAt: Int64 = 1000
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "d", generatedAt: draftGeneratedAt, status: .ready)

        let started = TestFlag()
        let stub = StubChatProvider(name: "stub-local", tokens: ["should never be used"], onStart: { started.mark() })
        let now = Date(timeIntervalSince1970: Double(draftGeneratedAt + threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", now: now)

        XCTAssertFalse(started.value, "no real Sent reply exists yet, so no LLM call should ever be made")
        XCTAssertNil(try draftStore.styleProfile(scope: "global"))
        XCTAssertEqual(try draftStore.draftsAwaitingStyleLearning(olderThanGeneratedAt: now.timeIntervalSince1970Int64, limit: 10).count, 1,
                       "the draft must remain a candidate for a later pass")
    }

    // MARK: learnIfDue — min-age cutoff

    func testLearnIfDueSkipsDraftsYoungerThanMinAge() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "alice@acme.com",
                                  bodyText: "body", dateUnix: 1000)
        try ingest(store: askStore, messageID: "reply@x", sender: "max@example.com", bodyText: "reply",
                  inReplyTo: "root@x", dateUnix: 1000 + 50)
        // Generated only 1 day ago relative to `now` below -- younger than the 3-day floor.
        let now = Date(timeIntervalSince1970: Double(1000 + 86400))
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "d", generatedAt: 1000, status: .ready)

        let started = TestFlag()
        let stub = StubChatProvider(name: "stub-local", tokens: ["x"], onStart: { started.mark() })
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", now: now)

        XCTAssertFalse(started.value, "a draft younger than the 3-day floor must not be examined yet")
    }

    // MARK: learnIfDue — daily gate

    func testLearnIfDueGatesToOncePer24Hours() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "alice@acme.com",
                                  bodyText: "body", dateUnix: 0)
        try ingest(store: askStore, messageID: "reply@x", sender: "max@example.com", bodyText: "reply",
                  inReplyTo: "root@x", dateUnix: threeDays + 100)
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "d", generatedAt: 0, status: .ready)

        let counter = TestCounter()
        let stub = StubChatProvider(name: "stub-local", tokens: ["profile text"], onStart: { counter.increment() })

        let firstRun = Date(timeIntervalSince1970: Double(threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", now: firstRun)
        XCTAssertEqual(counter.value, 3, "first run learns the one matched pair across all 3 scopes")

        // A few hours later (same "day" by the 24h gate): even a fresh
        // eligible+matched candidate must not be processed.
        let threadID2 = try ingest(store: askStore, messageID: "root2@x", sender: "bob@other.com",
                                   bodyText: "body2", dateUnix: 0)
        try ingest(store: askStore, messageID: "reply2@x", sender: "max@example.com", bodyText: "reply2",
                  inReplyTo: "root2@x", dateUnix: threeDays + 100)
        try draftStore.insertDraft(threadID: threadID2, latestMessageID: "root2@x", sender: "bob@other.com",
                                   subject: "s", draftText: "d2", generatedAt: 0, status: .ready)

        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", now: firstRun.addingTimeInterval(3600))
        XCTAssertEqual(counter.value, 3, "a second pass within 24h of the first must be a complete no-op")
    }

    // MARK: learnIfDue — empty accountEmail fails closed without consuming the gate

    func testLearnIfDueSkipsEntirelyWhenAccountEmailIsEmptyAndDoesNotAdvanceTheGate() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "alice@acme.com",
                                  bodyText: "body", dateUnix: 0)
        try ingest(store: askStore, messageID: "reply@x", sender: "max@example.com", bodyText: "reply",
                  inReplyTo: "root@x", dateUnix: threeDays + 100)
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "d", generatedAt: 0, status: .ready)

        let started = TestFlag()
        let stub = StubChatProvider(name: "stub-local", tokens: ["x"], onStart: { started.mark() })
        let now = Date(timeIntervalSince1970: Double(threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "", now: now)
        XCTAssertFalse(started.value, "an unset account email must fail closed, never match against every sender")

        // A retry moments later, once the user has configured an account
        // email, must proceed immediately -- the gate must NOT have advanced
        // during the earlier config-incomplete skip (else the user would
        // wait up to 24h for learning to start after finally configuring
        // their account email).
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", now: now.addingTimeInterval(10))
        XCTAssertTrue(started.value, "learning must proceed as soon as a valid account email is available, "
                     + "not wait out a gate that never should have advanced")
    }

    // MARK: learnIfDue — sibling drafts in the same thread sharing one real reply

    func testLearnIfDueDoesNotDoubleCountWhenTwoDraftsInSameThreadMatchTheSameReply() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root1@x", sender: "alice@acme.com",
                                  bodyText: "first question", dateUnix: 0)
        try ingest(store: askStore, messageID: "root2@x", sender: "Alice <alice@acme.com>",
                  bodyText: "second question", inReplyTo: "root1@x", dateUnix: 10)
        // One real reply, sent after BOTH inbound messages (and both drafts).
        try ingest(store: askStore, messageID: "reply@x", sender: "max@example.com",
                  bodyText: "one reply covers both", inReplyTo: "root2@x", dateUnix: threeDays + 100)

        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root1@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "draft one", generatedAt: 0, status: .ready)
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root2@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "draft two", generatedAt: 10, status: .ready)

        let counter = TestCounter()
        let stub = StubChatProvider(name: "stub-local", tokens: ["profile text"], onStart: { counter.increment() })
        let now = Date(timeIntervalSince1970: Double(threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", maxPerTick: 10, now: now)

        let global = try XCTUnwrap(try draftStore.styleProfile(scope: "global"))
        XCTAssertEqual(global.sampleCount, 1, "a single real reply shared by two sibling drafts must count once, not twice")
        XCTAssertEqual(counter.value, 3, "the second (duplicate) draft must be marked examined without re-running the merge LLM call")
        XCTAssertTrue(try draftStore.draftsAwaitingStyleLearning(olderThanGeneratedAt: now.timeIntervalSince1970Int64, limit: 10).isEmpty,
                     "both drafts must end up marked learned")
    }

    // MARK: learnIfDue — all-or-nothing persistence across the scope loop

    func testLearnIfDueRollsBackAllScopesWhenAMidLoopMergeFails() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "alice@acme.com",
                                  bodyText: "body", dateUnix: 0)
        try ingest(store: askStore, messageID: "reply@x", sender: "max@example.com", bodyText: "reply",
                  inReplyTo: "root@x", dateUnix: threeDays + 100)
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "d", generatedAt: 0, status: .ready)

        // Global (the 1st scope processed) succeeds; domain (the 2nd) fails.
        let flaky = FailAfterNChatProvider(succeedForCalls: 1)
        let now = Date(timeIntervalSince1970: Double(threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: flaky,
                                          accountEmail: "max@example.com", now: now)

        XCTAssertNil(try draftStore.styleProfile(scope: "global"),
                    "a mid-loop failure must roll back even an earlier scope's already-computed update")
        XCTAssertNil(try draftStore.styleProfile(scope: "domain:acme"))
        XCTAssertEqual(try draftStore.draftsAwaitingStyleLearning(olderThanGeneratedAt: now.timeIntervalSince1970Int64, limit: 10).count, 1,
                       "the draft must remain eligible for a clean retry, not be left half-learned")
    }

    // MARK: learnIfDue — maxPerTick cap

    func testLearnIfDueRespectsMaxPerTickCap() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        for index in 1...3 {
            let threadID = try ingest(store: askStore, messageID: "root\(index)@x", sender: "alice\(index)@acme.com",
                                      bodyText: "body", dateUnix: Int64(index) * 10)
            try ingest(store: askStore, messageID: "reply\(index)@x", sender: "max@example.com", bodyText: "reply",
                      inReplyTo: "root\(index)@x", dateUnix: Int64(index) * 10 + threeDays + 100)
            try draftStore.insertDraft(threadID: threadID, latestMessageID: "root\(index)@x", sender: "alice\(index)@acme.com",
                                       subject: "s", draftText: "d\(index)", generatedAt: Int64(index) * 10, status: .ready)
        }

        let stub = StubChatProvider(name: "stub-local", tokens: ["profile text"])
        let now = Date(timeIntervalSince1970: Double(3 * 10 + threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                          accountEmail: "max@example.com", maxPerTick: 2, now: now)

        let remaining = try draftStore.draftsAwaitingStyleLearning(olderThanGeneratedAt: now.timeIntervalSince1970Int64, limit: 10)
        XCTAssertEqual(remaining.count, 1, "only maxPerTick candidates may be learned in one pass")
    }

    // MARK: learnIfDue — LLM failure leaves the candidate for retry

    func testLearnIfDueLeavesCandidateUnmarkedWhenLLMFails() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "alice@acme.com",
                                  bodyText: "body", dateUnix: 0)
        try ingest(store: askStore, messageID: "reply@x", sender: "max@example.com", bodyText: "reply",
                  inReplyTo: "root@x", dateUnix: threeDays + 100)
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x", sender: "alice@acme.com",
                                   subject: "s", draftText: "d", generatedAt: 0, status: .ready)

        let failing = StubChatProvider(name: "stub-local", error: ProviderError.http(status: 500, body: "boom"))
        let now = Date(timeIntervalSince1970: Double(threeDays + 200))
        // Must not throw out of learnIfDue itself -- a per-candidate failure
        // is caught and logged, never aborts the whole pass.
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: failing,
                                          accountEmail: "max@example.com", now: now)

        XCTAssertNil(try draftStore.styleProfile(scope: "global"))
        XCTAssertEqual(try draftStore.draftsAwaitingStyleLearning(olderThanGeneratedAt: now.timeIntervalSince1970Int64, limit: 10).count, 1,
                       "a candidate whose merge call failed must remain eligible for a later retry")
    }

    // MARK: guidance(forRecipient:) precedence

    func testGuidancePrefersAddressThenDomainThenGlobalThenNil() throws {
        let draftStore = try DraftStore.inMemory()
        XCTAssertNil(try StyleLearner.guidance(forRecipient: "alice@acme.com", draftStore: draftStore))

        try draftStore.upsertStyleProfile(scope: "global", profileText: "global style", sampleCount: 1, updatedAt: 1)
        XCTAssertEqual(try StyleLearner.guidance(forRecipient: "alice@acme.com", draftStore: draftStore), "global style")

        try draftStore.upsertStyleProfile(scope: "domain:acme", profileText: "domain style", sampleCount: 1, updatedAt: 1)
        XCTAssertEqual(try StyleLearner.guidance(forRecipient: "alice@acme.com", draftStore: draftStore), "domain style",
                       "a domain-scoped profile must win over global")

        try draftStore.upsertStyleProfile(scope: "address:alice@acme.com", profileText: "address style", sampleCount: 1, updatedAt: 1)
        XCTAssertEqual(try StyleLearner.guidance(forRecipient: "Alice <alice@acme.com>", draftStore: draftStore), "address style",
                       "an address-scoped profile must win over domain and global")

        // A different correspondent at the same domain still falls back to
        // domain (no address-specific profile exists for them yet).
        XCTAssertEqual(try StyleLearner.guidance(forRecipient: "bob@acme.com", draftStore: draftStore), "domain style")
    }

    func testGuidanceTreatsEmptyProfileTextAsAbsent() throws {
        let draftStore = try DraftStore.inMemory()
        try draftStore.upsertStyleProfile(scope: "address:alice@acme.com", profileText: "", sampleCount: 1, updatedAt: 1)
        try draftStore.upsertStyleProfile(scope: "global", profileText: "global style", sampleCount: 1, updatedAt: 1)
        XCTAssertEqual(try StyleLearner.guidance(forRecipient: "alice@acme.com", draftStore: draftStore), "global style")
    }

    // MARK: learnIfDue — concurrent reset mid-merge

    /// Regression: a Settings "Reset learned style" that lands *during*
    /// `learn`'s multi-call LLM merge must not have its effect silently
    /// undone by that in-flight call writing back profile text folded from
    /// the now-deleted (pre-reset) profile.
    func testLearnDiscardsItsWriteWhenProfilesAreResetMidMerge() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ingest(store: askStore, messageID: "root@x", sender: "Alice <alice@acme.com>",
                                  bodyText: "Can we push the deadline?", dateUnix: 1000)
        try ingest(store: askStore, messageID: "reply@x", sender: "Max <max@example.com>",
                  bodyText: "Sure, Friday works.", inReplyTo: "root@x", dateUnix: 1000 + threeDays + 100)

        let draftGeneratedAt: Int64 = 1000 + 10
        let draftPk = try draftStore.insertDraft(threadID: threadID, latestMessageID: "root@x",
                                                 sender: "Alice <alice@acme.com>", subject: "Re: deadline",
                                                 draftText: "Happy to push it to Friday.",
                                                 generatedAt: draftGeneratedAt, status: .ready)

        let provider = ResetMidMergeChatProvider(draftStore: draftStore)
        let now = Date(timeIntervalSince1970: Double(draftGeneratedAt + threeDays + 200))
        try await StyleLearner.learnIfDue(draftStore: draftStore, askStore: askStore, chatProvider: provider,
                                          accountEmail: "max@example.com", now: now)

        XCTAssertNil(try draftStore.styleProfile(scope: "global"),
                     "the write computed before the reset must be discarded, not resurrect the cleared profile")
        let stillPending = try draftStore.draftsAwaitingStyleLearning(
            olderThanGeneratedAt: now.timeIntervalSince1970Int64, limit: 10)
        XCTAssertTrue(stillPending.contains { $0.pk == draftPk },
                     "the draft must stay unmarked so the sample isn't lost -- it's re-examined on a later pass")
    }
}

private extension Date {
    var timeIntervalSince1970Int64: Int64 { Int64(timeIntervalSince1970) }
}
