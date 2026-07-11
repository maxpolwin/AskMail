import SQLite3
import XCTest
@testable import AskMailCore

/// Builds a synthetic Apple Mail envelope index (the real on-disk schema
/// `EnvelopeIndexReader` queries: `messages`/`subjects`/`addresses`) so
/// `detectAndEnqueue` can be exercised without a live Mail account. Mirrors
/// the schema documented in `EnvelopeIndex.swift`'s own NOTE (spike B11 #1).
private func makeSyntheticEnvelopeIndex(
    at path: String,
    messages: [(rowID: Int64, subject: String, senderAddress: String, dateReceivedRaw: Int64)]
) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
        throw StoreError.openFailed("could not create synthetic envelope index")
    }
    defer { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }
    // DROP first so a test can call this more than once against the same
    // path (simulating successive polls of a changing index) without
    // hitting "table already exists".
    try exec("DROP TABLE IF EXISTS messages")
    try exec("DROP TABLE IF EXISTS subjects")
    try exec("DROP TABLE IF EXISTS addresses")
    try exec("CREATE TABLE messages(subject INTEGER, sender INTEGER, date_received INTEGER)")
    try exec("CREATE TABLE subjects(subject TEXT)")
    try exec("CREATE TABLE addresses(address TEXT, comment TEXT)")

    for message in messages {
        // subjects/addresses ROWIDs are made to equal the message's own
        // rowID for simplicity (one subject/address per message; real Mail
        // dedupes these, irrelevant to this join's correctness).
        try run(db, "INSERT INTO subjects(ROWID, subject) VALUES (?, ?)", message.rowID, message.subject)
        try run(db, "INSERT INTO addresses(ROWID, address, comment) VALUES (?, ?, '')",
               message.rowID, message.senderAddress)
        try run(db, "INSERT INTO messages(ROWID, subject, sender, date_received) VALUES (?, ?, ?, ?)",
               message.rowID, message.rowID, message.rowID, message.dateReceivedRaw)
    }
}

private func run(_ db: OpaquePointer, _ sql: String, _ rowID: Int64, _ text: String) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, rowID)
    sqlite3_bind_text(statement, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
    }
}

private func run(_ db: OpaquePointer, _ sql: String, _ rowID: Int64, _ rowID2: Int64,
                 _ rowID3: Int64, _ dateReceived: Int64) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, rowID)
    sqlite3_bind_int64(statement, 2, rowID2)
    sqlite3_bind_int64(statement, 3, rowID3)
    sqlite3_bind_int64(statement, 4, dateReceived)
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
    }
}

final class DraftJobProcessorTests: XCTestCase {

    // MARK: backoffSeconds

    func testBackoffSecondsGrowsExponentiallyAndCaps() {
        XCTAssertEqual(DraftJobProcessor.backoffSeconds(forAttempt: 1), 120)
        XCTAssertEqual(DraftJobProcessor.backoffSeconds(forAttempt: 2), 240)
        XCTAssertEqual(DraftJobProcessor.backoffSeconds(forAttempt: 3), 480)
        XCTAssertEqual(DraftJobProcessor.backoffSeconds(forAttempt: 10), 3600, "must cap at one hour")
    }

    // MARK: detectAndEnqueue

    func makeAccountTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func writeEmlxStub(in accountDirectory: URL, mailbox: String, rowID: Int64) throws {
        let dir = accountDirectory.appendingPathComponent("\(mailbox).mbox/UUID/Data/0/0/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("\(rowID).emlx"))
    }

    func testDetectAndEnqueueOnlyEnqueuesInboxCandidatesAndAdvancesWatermarkOverAll() throws {
        let accountDirectory = try makeAccountTree()
        defer { try? FileManager.default.removeItem(at: accountDirectory) }
        try writeEmlxStub(in: accountDirectory, mailbox: "INBOX", rowID: 1001)
        try writeEmlxStub(in: accountDirectory, mailbox: "Sent", rowID: 2001)
        try writeEmlxStub(in: accountDirectory, mailbox: "Trash", rowID: 3001)

        let indexPath = accountDirectory.appendingPathComponent("envelope-index.sqlite").path
        // date_received is Cocoa-epoch seconds; dateReceivedUnix = raw + cocoaEpochOffset.
        try makeSyntheticEnvelopeIndex(at: indexPath, messages: [
            (rowID: 1001, subject: "Inbox message", senderAddress: "alice@example.com",
             dateReceivedRaw: 100 - Defaults.cocoaEpochOffset),
            (rowID: 2001, subject: "Sent message", senderAddress: "me@example.com",
             dateReceivedRaw: 200 - Defaults.cocoaEpochOffset),
            (rowID: 3001, subject: "Trashed message", senderAddress: "spam@example.com",
             dateReceivedRaw: 300 - Defaults.cocoaEpochOffset),
        ])

        let draftStore = try DraftStore.inMemory()
        let reader = try EnvelopeIndexReader(path: indexPath)
        let toIngest = try DraftJobProcessor.detectAndEnqueue(
            envelopeReader: reader, draftStore: draftStore, accountDirectory: accountDirectory)

        XCTAssertEqual(toIngest.map(\.sourceID), [1001], "only the Inbox candidate should be queued for ingest")
        let pending = try draftStore.jobs(in: [.pending])
        XCTAssertEqual(pending.map(\.sourceID), [1001], "Sent/Trash must never be enqueued as draft candidates")

        // Watermark must advance over the newest row seen (300), not just the
        // newest Inbox row (100), so a window with only Sent/Trash mail can't stall it.
        XCTAssertEqual(try draftStore.meta("draft_watermark_date_unix"), "300")
    }

    func testDetectAndEnqueueIsIncrementalAgainstThePersistedWatermark() throws {
        let accountDirectory = try makeAccountTree()
        defer { try? FileManager.default.removeItem(at: accountDirectory) }
        try writeEmlxStub(in: accountDirectory, mailbox: "INBOX", rowID: 1001)
        try writeEmlxStub(in: accountDirectory, mailbox: "INBOX", rowID: 1002)

        // Spaced well beyond watermarkGraceSeconds (300s) so this test
        // exercises plain incremental filtering, distinct from the grace
        // window's re-examination behavior (covered separately below).
        let indexPath = accountDirectory.appendingPathComponent("envelope-index.sqlite").path
        try makeSyntheticEnvelopeIndex(at: indexPath, messages: [
            (rowID: 1001, subject: "First", senderAddress: "a@x", dateReceivedRaw: 1_000 - Defaults.cocoaEpochOffset),
            (rowID: 1002, subject: "Second", senderAddress: "b@x", dateReceivedRaw: 3_000 - Defaults.cocoaEpochOffset),
        ])

        let draftStore = try DraftStore.inMemory()
        try draftStore.setMeta("draft_watermark_date_unix", value: "2000")

        let reader = try EnvelopeIndexReader(path: indexPath)
        let toIngest = try DraftJobProcessor.detectAndEnqueue(
            envelopeReader: reader, draftStore: draftStore, accountDirectory: accountDirectory)

        XCTAssertEqual(toIngest.map(\.sourceID), [1002], "only messages newer than the watermark are candidates")
    }

    // The watermark only ever advances forward, but the *query* re-examines
    // a trailing grace window so a message tied with (or trailing) a
    // previously-advanced watermark still gets picked up in a later poll
    // instead of being silently, permanently skipped.
    func testDetectAndEnqueueGraceWindowRecoversATiedOrTrailingCandidate() throws {
        let accountDirectory = try makeAccountTree()
        defer { try? FileManager.default.removeItem(at: accountDirectory) }
        try writeEmlxStub(in: accountDirectory, mailbox: "Sent", rowID: 2001)
        try writeEmlxStub(in: accountDirectory, mailbox: "INBOX", rowID: 1001)

        let indexPath = accountDirectory.appendingPathComponent("envelope-index.sqlite").path
        let draftStore = try DraftStore.inMemory()

        // Poll 1: only a Sent message is visible, dated T=10_000. It fails
        // the Inbox filter, so nothing is enqueued, but the watermark still
        // advances to 10_000 (so a window with only Sent/Trash mail can't stall it).
        try makeSyntheticEnvelopeIndex(at: indexPath, messages: [
            (rowID: 2001, subject: "Sent", senderAddress: "me@x", dateReceivedRaw: 10_000 - Defaults.cocoaEpochOffset),
        ])
        let reader = try EnvelopeIndexReader(path: indexPath)
        _ = try DraftJobProcessor.detectAndEnqueue(envelopeReader: reader, draftStore: draftStore,
                                                   accountDirectory: accountDirectory)
        XCTAssertEqual(try draftStore.meta("draft_watermark_date_unix"), "10000")
        XCTAssertTrue(try draftStore.jobs(in: [.pending]).isEmpty)

        // Poll 2: a genuinely new Inbox message finishes syncing into the
        // envelope index, dated T=9_900 -- *earlier* than the watermark a
        // strict `date > watermark` comparison would otherwise have
        // advanced past forever. Recreate the index with both rows present
        // (a fresh EnvelopeIndexReader since the file changed underneath it).
        try makeSyntheticEnvelopeIndex(at: indexPath, messages: [
            (rowID: 2001, subject: "Sent", senderAddress: "me@x", dateReceivedRaw: 10_000 - Defaults.cocoaEpochOffset),
            (rowID: 1001, subject: "Inbox", senderAddress: "a@x", dateReceivedRaw: 9_900 - Defaults.cocoaEpochOffset),
        ])
        let reader2 = try EnvelopeIndexReader(path: indexPath)
        let toIngest = try DraftJobProcessor.detectAndEnqueue(envelopeReader: reader2, draftStore: draftStore,
                                                              accountDirectory: accountDirectory)

        XCTAssertEqual(toIngest.map(\.sourceID), [1001],
                       "the grace window must still surface an Inbox message trailing the already-advanced watermark")
    }

    func testDetectAndEnqueueIsANoOpWhenNothingIsNewerThanTheWatermark() throws {
        let accountDirectory = try makeAccountTree()
        defer { try? FileManager.default.removeItem(at: accountDirectory) }
        let indexPath = accountDirectory.appendingPathComponent("envelope-index.sqlite").path
        try makeSyntheticEnvelopeIndex(at: indexPath, messages: [])

        let draftStore = try DraftStore.inMemory()
        let reader = try EnvelopeIndexReader(path: indexPath)
        let toIngest = try DraftJobProcessor.detectAndEnqueue(
            envelopeReader: reader, draftStore: draftStore, accountDirectory: accountDirectory)
        XCTAssertTrue(toIngest.isEmpty)
        XCTAssertTrue(try draftStore.jobs(in: [.pending]).isEmpty)
    }

    // Perf fix (docs/draft-modus-plan.md Phase 4): a caller (DraftEngine)
    // that already walked the account tree once should be able to hand that
    // result straight to detectAndEnqueue instead of it doing a second,
    // independent walk -- these two tests pin that the passed `fileIndex`
    // is what actually drives resolution, not a silent fallback to disk.
    func testDetectAndEnqueueDoesNotFallBackToADiskWalkWhenAnExplicitFileIndexMisses() throws {
        let accountDirectory = try makeAccountTree()
        defer { try? FileManager.default.removeItem(at: accountDirectory) }
        // A real Inbox file exists on disk at the path a fresh
        // EmlxLocator.index() walk would find...
        try writeEmlxStub(in: accountDirectory, mailbox: "INBOX", rowID: 1001)

        let indexPath = accountDirectory.appendingPathComponent("envelope-index.sqlite").path
        try makeSyntheticEnvelopeIndex(at: indexPath, messages: [
            (rowID: 1001, subject: "Inbox message", senderAddress: "alice@example.com",
             dateReceivedRaw: 100 - Defaults.cocoaEpochOffset),
        ])

        let draftStore = try DraftStore.inMemory()
        let reader = try EnvelopeIndexReader(path: indexPath)
        // ...but an explicitly empty fileIndex is passed instead.
        let toIngest = try DraftJobProcessor.detectAndEnqueue(
            envelopeReader: reader, draftStore: draftStore, accountDirectory: accountDirectory, fileIndex: [:])

        XCTAssertTrue(toIngest.isEmpty, "an explicitly passed fileIndex must be authoritative, never silently re-walked")
        XCTAssertTrue(try draftStore.jobs(in: [.pending]).isEmpty)
        // Watermark bookkeeping is independent of file resolution either way.
        XCTAssertEqual(try draftStore.meta("draft_watermark_date_unix"), "100")
    }

    func testDetectAndEnqueueBuildsEmlxFilesFromThePassedFileIndex() throws {
        let accountDirectory = try makeAccountTree()
        defer { try? FileManager.default.removeItem(at: accountDirectory) }
        let indexPath = accountDirectory.appendingPathComponent("envelope-index.sqlite").path
        try makeSyntheticEnvelopeIndex(at: indexPath, messages: [
            (rowID: 1001, subject: "Inbox message", senderAddress: "alice@example.com",
             dateReceivedRaw: 100 - Defaults.cocoaEpochOffset),
        ])

        let draftStore = try DraftStore.inMemory()
        let reader = try EnvelopeIndexReader(path: indexPath)
        // No file is written on disk at all -- the passed fileIndex is the
        // only source of truth for where 1001 lives.
        let claimedURL = accountDirectory
            .appendingPathComponent("INBOX.mbox/UUID/Data/0/0/Messages/1001.emlx")
        let toIngest = try DraftJobProcessor.detectAndEnqueue(
            envelopeReader: reader, draftStore: draftStore, accountDirectory: accountDirectory,
            fileIndex: [1001: claimedURL])

        XCTAssertEqual(toIngest.map(\.sourceID), [1001])
        XCTAssertEqual(toIngest.first?.url, claimedURL,
                       "the EmlxFile's url must come from the passed fileIndex, not a fresh scan()")
    }

    // MARK: classifyPendingJobs

    func makeIngestedMessage(store: SQLiteStore, messageID: String, sender: String, bodyText: String,
                            dateUnix: Int64 = 1) throws {
        let threadID = try ThreadResolver.resolveThread(messageID: messageID, inReplyTo: nil, references: [],
                                                        store: store)
        try store.upsertMessage(messageID: messageID, account: "acc", subject: "s", sender: sender,
                                threadID: threadID, bodyText: bodyText, dateUnix: dateUnix)
    }

    func writeRealEmlxFile(in directory: URL, rowID: Int64, raw: String) throws {
        let messageData = Data(raw.utf8)
        let emlxData = Data("\(messageData.count)\n".utf8) + messageData
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try emlxData.write(to: directory.appendingPathComponent("\(rowID).emlx"))
    }

    func testClassifyPendingJobsMarksPersonalMailEligible() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeRealEmlxFile(in: tempDir, rowID: 1, raw: """
        From: Alice <alice@example.com>
        To: Max <max@example.com>
        Subject: Quick question
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <personal-1@example.com>
        Content-Type: text/plain; charset=utf-8

        Are we still on for lunch tomorrow?
        """)

        try draftStore.enqueueJob(sourceID: 1, messageID: nil, detectedAt: 1)

        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [1: tempDir.appendingPathComponent("1.emlx")],
            llmFallback: nil, accountEmail: "max@example.com")

        let job = try XCTUnwrap(try draftStore.job(sourceID: 1))
        XCTAssertEqual(job.state, .eligible)
        XCTAssertEqual(job.messageID, "personal-1@example.com")
    }

    func testClassifyPendingJobsSkipsNewsletters() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeRealEmlxFile(in: tempDir, rowID: 2, raw: """
        From: Updates <updates@newsletter.example>
        To: Max <max@example.com>
        Subject: This week
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <newsletter-1@example.com>
        List-Unsubscribe: <mailto:unsub@newsletter.example>
        Content-Type: text/plain; charset=utf-8

        Here's this week's roundup.
        """)
        try draftStore.enqueueJob(sourceID: 2, messageID: nil, detectedAt: 1)

        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [2: tempDir.appendingPathComponent("2.emlx")],
            llmFallback: nil, accountEmail: "max@example.com")

        let job = try XCTUnwrap(try draftStore.job(sourceID: 2))
        XCTAssertEqual(job.state, .newsletterSkipped)
    }

    func testClassifyPendingJobsMarksAutoGeneratedSeparatelyFromNewsletter() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeRealEmlxFile(in: tempDir, rowID: 3, raw: """
        From: Mailer Daemon <mailer-daemon@example.com>
        To: Max <max@example.com>
        Subject: Auto-reply
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <auto-1@example.com>
        Auto-Submitted: auto-replied
        Content-Type: text/plain; charset=utf-8

        I am out of office.
        """)
        try draftStore.enqueueJob(sourceID: 3, messageID: nil, detectedAt: 1)

        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [3: tempDir.appendingPathComponent("3.emlx")],
            llmFallback: nil, accountEmail: "max@example.com")

        let job = try XCTUnwrap(try draftStore.job(sourceID: 3))
        XCTAssertEqual(job.state, .autoGenerated, "the RFC 3834 gate must be a distinct bucket from newsletterSkipped")
    }

    // Regression guard: NewsletterClassifier.isNoReplySender must be checked
    // as a hard gate, same shape as isAutoGenerated above -- a noreply@
    // sender with an otherwise entirely ordinary, personal-looking body
    // (no strong headers, no boilerplate) would previously reach classify's
    // weak-signal path, going ambiguous and consulting the LLM fallback
    // instead of being skipped outright.
    func testClassifyPendingJobsSkipsNoReplySenderWithoutInvokingLLMFallback() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeRealEmlxFile(in: tempDir, rowID: 9, raw: """
        From: Acme Notifications <noreply@example.com>
        To: Max <max@example.com>
        Subject: Your order shipped
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <noreply-1@example.com>
        Content-Type: text/plain; charset=utf-8

        Your order #1234 has shipped and will arrive Thursday.
        """)
        try draftStore.enqueueJob(sourceID: 9, messageID: nil, detectedAt: 1)

        let calledLLM = TestFlag()
        let neverRun = StubChatProvider(name: "stub", tokens: ["personal"], onStart: { calledLLM.mark() })

        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [9: tempDir.appendingPathComponent("9.emlx")],
            llmFallback: neverRun, accountEmail: "max@example.com")

        let job = try XCTUnwrap(try draftStore.job(sourceID: 9))
        XCTAssertEqual(job.state, .newsletterSkipped, "a noreply@ sender must never be drafted, regardless of body content")
        XCTAssertFalse(calledLLM.value, "the hard gate must bypass classify's weak-signal/LLM-fallback path entirely")
    }

    /// Phase 6's sender/domain exclusion list, wired through the same hard
    /// gate as `isAutoGenerated`/`isNoReplySender`.
    func testClassifyPendingJobsSkipsExcludedSenderWithoutInvokingLLMFallback() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeRealEmlxFile(in: tempDir, rowID: 10, raw: """
        From: Alice <alice@excluded-corp.com>
        To: Max <max@example.com>
        Subject: Hi
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <excluded-1@excluded-corp.com>
        Content-Type: text/plain; charset=utf-8

        Just checking in -- ordinary personal-looking mail.
        """)
        try draftStore.enqueueJob(sourceID: 10, messageID: nil, detectedAt: 1)

        let calledLLM = TestFlag()
        let neverRun = StubChatProvider(name: "stub", tokens: ["personal"], onStart: { calledLLM.mark() })

        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [10: tempDir.appendingPathComponent("10.emlx")],
            llmFallback: neverRun, accountEmail: "max@example.com", excludedSenders: ["excluded-corp.com"])

        let job = try XCTUnwrap(try draftStore.job(sourceID: 10))
        XCTAssertEqual(job.state, .newsletterSkipped, "an excluded sender must never be drafted")
        XCTAssertFalse(calledLLM.value, "the hard gate must bypass classify's weak-signal/LLM-fallback path entirely")
    }

    func testClassifyPendingJobsDraftsANonExcludedSenderNormally() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeRealEmlxFile(in: tempDir, rowID: 11, raw: """
        From: Bob <bob@ok-corp.com>
        To: Max <max@example.com>
        Subject: Hi
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <ok-1@ok-corp.com>
        Content-Type: text/plain; charset=utf-8

        Just checking in -- ordinary personal-looking mail.
        """)
        try draftStore.enqueueJob(sourceID: 11, messageID: nil, detectedAt: 1)

        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [11: tempDir.appendingPathComponent("11.emlx")],
            llmFallback: nil, accountEmail: "max@example.com", excludedSenders: ["excluded-corp.com"])

        let job = try XCTUnwrap(try draftStore.job(sourceID: 11))
        XCTAssertEqual(job.state, .eligible, "a sender not on the exclusion list must classify normally")
    }

    func testClassifyPendingJobsMissingFileFailsWithRetry() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        try draftStore.enqueueJob(sourceID: 4, messageID: nil, detectedAt: 1)

        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [:], llmFallback: nil, accountEmail: "max@example.com")

        let job = try XCTUnwrap(try draftStore.job(sourceID: 4))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.attempts, 1)
    }

    func testHasPriorSentCorrespondenceChecksThreadMembersNotWholeMailbox() throws {
        let askStore = try SQLiteStore.inMemory()
        try makeIngestedMessage(store: askStore, messageID: "root@x", sender: "alice@example.com", bodyText: "hi")
        let childThread = try ThreadResolver.resolveThread(messageID: "child@x", inReplyTo: "root@x",
                                                            references: [], store: askStore)
        try askStore.upsertMessage(messageID: "child@x", account: "acc", subject: "s", sender: "Max <max@example.com>",
                                   inReplyTo: "root@x", threadID: childThread, bodyText: "reply", dateUnix: 2)

        XCTAssertTrue(try DraftJobProcessor.hasPriorSentCorrespondence(
            messageID: "child@x", accountEmail: "max@example.com", store: askStore))
        XCTAssertFalse(try DraftJobProcessor.hasPriorSentCorrespondence(
            messageID: "child@x", accountEmail: "someone-else@example.com", store: askStore))
        XCTAssertFalse(try DraftJobProcessor.hasPriorSentCorrespondence(
            messageID: "child@x", accountEmail: "", store: askStore), "an unresolved account email must fail closed")
    }

    // MARK: draftEligibleJobs

    func testDraftEligibleJobsProducesAReadyDraftAndMarksJobDrafted() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m1@x", account: "acc", subject: "Catch up", sender: "alice@example.com",
                                   threadID: threadID, bodyText: "How's Friday looking?", dateUnix: 1)

        try draftStore.enqueueJob(sourceID: 1, messageID: "m1@x", detectedAt: 1)
        try draftStore.updateJobState(sourceID: 1, messageID: "m1@x", state: .eligible,
                                      attempts: 0, lastError: nil, updatedAt: 1)

        let stub = StubChatProvider(name: "stub-local", tokens: ["Friday works for me!"])
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                                  embedder: StubEmbedder(), concurrency: 2)

        let job = try XCTUnwrap(try draftStore.job(sourceID: 1))
        XCTAssertEqual(job.state, .drafted)
        let draft = try XCTUnwrap(try draftStore.latestDraft(threadID: threadID))
        XCTAssertEqual(draft.draftText, "Friday works for me!")
        XCTAssertEqual(draft.status, .ready)
    }

    func testDraftEligibleJobsMarksFailedOnEmptyDraftAndIncrementsAttempts() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m2@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m2@x", account: "acc", subject: "s", sender: "a@x",
                                   threadID: threadID, bodyText: "body", dateUnix: 1)
        try draftStore.enqueueJob(sourceID: 2, messageID: "m2@x", detectedAt: 1)
        try draftStore.updateJobState(sourceID: 2, messageID: "m2@x", state: .eligible,
                                      attempts: 0, lastError: nil, updatedAt: 1)

        let stub = StubChatProvider(name: "stub-local", tokens: [])  // empty stream -> empty draft
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                                  embedder: StubEmbedder(), concurrency: 2)

        let job = try XCTUnwrap(try draftStore.job(sourceID: 2))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertNil(try draftStore.latestDraft(threadID: threadID))
    }

    // Regression guard for the review fix: draftEligibleJobs must never
    // retry a `.failed` job directly (that's classifyPendingJobs's job now)
    // -- a `.failed` job sitting there, even backoff-eligible, must be
    // completely invisible to drafting.
    func testDraftEligibleJobsNeverTouchesFailedJobs() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m3@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m3@x", account: "acc", subject: "s", sender: "a@x",
                                   threadID: threadID, bodyText: "body", dateUnix: 1)
        try draftStore.enqueueJob(sourceID: 3, messageID: "m3@x", detectedAt: 1)
        let now = Date(timeIntervalSince1970: 10_000)
        try draftStore.updateJobState(sourceID: 3, messageID: "m3@x", state: .failed,
                                      attempts: 1, lastError: "x", updatedAt: Int64(now.timeIntervalSince1970))

        let stub = StubChatProvider(name: "stub-local", tokens: ["should never run"])
        // Comfortably past any backoff window.
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                                  embedder: StubEmbedder(), concurrency: 2,
                                                  now: now.addingTimeInterval(10_000))
        XCTAssertEqual(try draftStore.job(sourceID: 3)?.state, .failed,
                       "a .failed job must stay untouched by draftEligibleJobs regardless of backoff")
        XCTAssertNil(try draftStore.latestDraft(threadID: threadID))
    }

    func testClassifyPendingJobsRespectsBackoffBeforeRetryingAFailedJob() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try writeRealEmlxFile(in: tempDir, rowID: 5, raw: """
        From: Alice <alice@example.com>
        To: Max <max@example.com>
        Subject: Quick question
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <retry-classify@example.com>
        Content-Type: text/plain; charset=utf-8

        Are you free Thursday?
        """)
        try draftStore.enqueueJob(sourceID: 5, messageID: nil, detectedAt: 1)
        let now = Date(timeIntervalSince1970: 10_000)
        // attempt=1, backoff is 120s.
        try draftStore.updateJobState(sourceID: 5, state: .failed, attempts: 1, lastError: "transient",
                                      updatedAt: Int64(now.timeIntervalSince1970))

        // Too soon: backoff hasn't elapsed yet.
        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [5: tempDir.appendingPathComponent("5.emlx")], llmFallback: nil,
            accountEmail: "max@example.com", now: now.addingTimeInterval(10))
        XCTAssertEqual(try draftStore.job(sourceID: 5)?.state, .failed, "must not retry before backoff elapses")
        XCTAssertEqual(try draftStore.job(sourceID: 5)?.attempts, 1)

        // Backoff elapsed: now eligible for reclassification.
        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [5: tempDir.appendingPathComponent("5.emlx")], llmFallback: nil,
            accountEmail: "max@example.com", now: now.addingTimeInterval(200))
        XCTAssertEqual(try draftStore.job(sourceID: 5)?.state, .eligible, "must reclassify once backoff has elapsed")
    }

    // The core review fix: a job that failed with an .ambiguous verdict
    // (messageID already recorded) must be RE-CLASSIFIED on retry, not
    // handed straight to drafting -- otherwise a message with a real
    // newsletter signal that merely hit a transient LLM hiccup could get
    // drafted-and-stored with the newsletter gate never having reached a verdict.
    func testAmbiguousVerdictIsReclassifiedOnRetryNotDraftedDirectly() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Weak newsletter signal (sender local-part) with no boilerplate --
        // ambiguous with no llmFallback.
        try writeRealEmlxFile(in: tempDir, rowID: 6, raw: """
        From: Updates <updates@example.com>
        To: Max <max@example.com>
        Subject: Hello
        Date: Mon, 02 Mar 2026 09:00:00 +0100
        Message-ID: <ambiguous-retry@example.com>
        Content-Type: text/plain; charset=utf-8

        Just some ordinary-looking text, nothing conclusive either way.
        """)
        let fileIndex: [Int64: URL] = [6: tempDir.appendingPathComponent("6.emlx")]
        try draftStore.enqueueJob(sourceID: 6, messageID: nil, detectedAt: 1)

        // First pass: no llmFallback -> ambiguous -> failed, messageID recorded.
        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: fileIndex, llmFallback: nil, accountEmail: "max@example.com",
            now: Date(timeIntervalSince1970: 0))
        let afterFirstPass = try XCTUnwrap(try draftStore.job(sourceID: 6))
        XCTAssertEqual(afterFirstPass.state, .failed)
        XCTAssertEqual(afterFirstPass.messageID, "ambiguous-retry@example.com")

        // Between attempts, draftEligibleJobs must never touch it (it's .failed).
        let neverRun = StubChatProvider(name: "stub", tokens: ["should never run"])
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: neverRun,
                                                  embedder: StubEmbedder(), concurrency: 2,
                                                  now: Date(timeIntervalSince1970: 100_000))
        XCTAssertNil(try draftStore.latestDraft(threadID: "ambiguous-retry@example.com"),
                    "an ambiguous-verdict job must never reach drafting without being re-classified first")

        // Retry (backoff elapsed): this time an llmFallback resolves it
        // definitively as a newsletter.
        let newsletterLLM = StubChatProvider(name: "stub-local", tokens: ["newsletter"])
        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: fileIndex, llmFallback: newsletterLLM, accountEmail: "max@example.com",
            now: Date(timeIntervalSince1970: 100_000))
        XCTAssertEqual(try draftStore.job(sourceID: 6)?.state, .newsletterSkipped,
                       "retry must re-run classification, not skip straight to drafting")
    }

    // A job that failed before messageID was ever recorded (missing source
    // file, or any exception before parsing completed) must retry through
    // re-classification -- not be handed to draftOne, which is guaranteed to
    // fail every such retry on an unrelated, confusing error until pruned.
    func testMessageIDLessFailureRetriesViaReclassificationNotDrafting() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        try draftStore.enqueueJob(sourceID: 7, messageID: nil, detectedAt: 1)
        try draftStore.updateJobState(sourceID: 7, state: .failed, attempts: 1,
                                      lastError: "source file not found", updatedAt: 0)

        // Retry with the file still missing: same diagnostic error persists,
        // attempts increments -- not routed through draftOne at all.
        try await DraftJobProcessor.classifyPendingJobs(
            draftStore: draftStore, askStore: askStore, parser: InProcessEmailParser(),
            fileIndex: [:], llmFallback: nil, accountEmail: "max@example.com",
            now: Date(timeIntervalSince1970: 100_000))
        let retried = try XCTUnwrap(try draftStore.job(sourceID: 7))
        XCTAssertEqual(retried.state, .failed)
        XCTAssertEqual(retried.attempts, 2)
        XCTAssertEqual(retried.lastError, "source file not found",
                       "must surface the real diagnostic, not draftOne's unrelated missingThreadContext error")
    }

    func testDraftEligibleJobsSkipsEntirelyWhenConcurrencyIsZero() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m4@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m4@x", account: "acc", subject: "s", sender: "a@x",
                                   threadID: threadID, bodyText: "body", dateUnix: 1)
        try draftStore.enqueueJob(sourceID: 4, messageID: "m4@x", detectedAt: 1)
        try draftStore.updateJobState(sourceID: 4, messageID: "m4@x", state: .eligible,
                                      attempts: 0, lastError: nil, updatedAt: 1)

        let stub = StubChatProvider(name: "stub-local", tokens: ["should never run"])
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                                  embedder: StubEmbedder(), concurrency: 0)
        XCTAssertEqual(try draftStore.job(sourceID: 4)?.state, .eligible, "concurrency 0 (battery policy) must skip drafting entirely")
    }

    // MARK: purgeIfDue

    func testPurgeIfDueDeletesOldRowsOncePerDayAndRecordsTimestamp() throws {
        let draftStore = try DraftStore.inMemory()
        try draftStore.insertDraft(threadID: "t1", latestMessageID: "m1", sender: "a@x", subject: "s",
                                   draftText: "old", generatedAt: 1, status: .ready)

        let now = Date(timeIntervalSince1970: 20 * 86400)  // 20 days after epoch
        try DraftJobProcessor.purgeIfDue(draftStore: draftStore, now: now)

        XCTAssertNil(try draftStore.latestDraft(threadID: "t1"), "a 14-day-old draft must be purged")
        XCTAssertEqual(try draftStore.meta("draft_last_purge_unix"), String(Int64(now.timeIntervalSince1970)))
    }

    func testPurgeIfDueIsANoOpWithinTheSameDay() throws {
        let draftStore = try DraftStore.inMemory()
        let now = Date(timeIntervalSince1970: 20 * 86400)
        try DraftJobProcessor.purgeIfDue(draftStore: draftStore, now: now)
        try draftStore.insertDraft(threadID: "t2", latestMessageID: "m2", sender: "a@x", subject: "s",
                                   draftText: "still old", generatedAt: 1, status: .ready)

        // Only a few hours later: must not purge again (and so must not
        // touch the draft inserted just now, even though it's also "old" by
        // generatedAt).
        try DraftJobProcessor.purgeIfDue(draftStore: draftStore, now: now.addingTimeInterval(3600))
        XCTAssertNotNil(try draftStore.latestDraft(threadID: "t2"))
    }

    // MARK: recoverStuckJobs

    func testRecoverStuckJobsResetsOrphanedClassifyingAndDraftingRows() throws {
        let draftStore = try DraftStore.inMemory()
        try draftStore.enqueueJob(sourceID: 1, messageID: nil, detectedAt: 0)
        try draftStore.updateJobState(sourceID: 1, state: .classifying, attempts: 0, lastError: nil, updatedAt: 0)
        try draftStore.enqueueJob(sourceID: 2, messageID: "m2@x", detectedAt: 0)
        try draftStore.updateJobState(sourceID: 2, messageID: "m2@x", state: .drafting,
                                      attempts: 0, lastError: nil, updatedAt: 0)

        // Comfortably past stuckJobThresholdSeconds (600s).
        try DraftJobProcessor.recoverStuckJobs(draftStore: draftStore, now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(try draftStore.job(sourceID: 1)?.state, .pending,
                       "an orphaned classifying job must be recovered back to pending")
        XCTAssertEqual(try draftStore.job(sourceID: 2)?.state, .eligible,
                       "an orphaned drafting job must be recovered back to eligible")
    }

    func testRecoverStuckJobsLeavesRecentlyUpdatedJobsAlone() throws {
        let draftStore = try DraftStore.inMemory()
        try draftStore.enqueueJob(sourceID: 1, messageID: nil, detectedAt: 9_990)
        try draftStore.updateJobState(sourceID: 1, state: .classifying, attempts: 0, lastError: nil, updatedAt: 9_990)

        // Only 10s old -- genuinely still in progress, not orphaned.
        try DraftJobProcessor.recoverStuckJobs(draftStore: draftStore, now: Date(timeIntervalSince1970: 10_000))

        XCTAssertEqual(try draftStore.job(sourceID: 1)?.state, .classifying,
                       "a job updated moments ago must not be treated as stuck")
    }

    // MARK: draftOne targets job.messageID, not thread.last

    // Under out-of-order delivery, the thread's chronologically-newest
    // member (by the messages' own Date header) can be the account's own
    // already-sent reply to a LATER message than the one this job is about
    // -- draftOne must draft a reply to its own job's message, not silently
    // draft "a reply to yourself."
    func testDraftTargetsJobsOwnMessageNotChronologicallyLatestThreadMember() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()

        // root (day 1) -> reply from Max (day 3, a LATER message than "mid")
        //             -> mid (day 2, the message THIS job is about)
        let rootThread = try ThreadResolver.resolveThread(messageID: "root@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "root@x", account: "acc", subject: "s", sender: "alice@example.com",
                                   threadID: rootThread, bodyText: "Original message.", dateUnix: 1)
        let midThread = try ThreadResolver.resolveThread(messageID: "mid@x", inReplyTo: "root@x", references: ["root@x"], store: askStore)
        try askStore.upsertMessage(messageID: "mid@x", account: "acc", subject: "s", sender: "alice@example.com",
                                   inReplyTo: "root@x", threadID: midThread, bodyText: "A follow-up question.", dateUnix: 2)
        // Max's own later reply, to a message OTHER than "mid" but in the same thread lineage.
        let laterThread = try ThreadResolver.resolveThread(messageID: "later@x", inReplyTo: "root@x", references: ["root@x"], store: askStore)
        try askStore.upsertMessage(messageID: "later@x", account: "acc", subject: "s", sender: "Max <max@example.com>",
                                   inReplyTo: "root@x", threadID: laterThread, bodyText: "My own later reply.", dateUnix: 3)

        try draftStore.enqueueJob(sourceID: 1, messageID: "mid@x", detectedAt: 2)
        try draftStore.updateJobState(sourceID: 1, messageID: "mid@x", state: .eligible,
                                      attempts: 0, lastError: nil, updatedAt: 2)

        let stub = StubChatProvider(name: "stub-local", tokens: ["Sure, happy to help."])
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: stub,
                                                  embedder: StubEmbedder(), concurrency: 2)

        let draft = try XCTUnwrap(try draftStore.latestDraft(threadID: rootThread))
        XCTAssertEqual(draft.latestMessageID, "mid@x",
                       "must draft a reply to this job's own message, not the chronologically-latest thread member")
        XCTAssertNotEqual(draft.sender, "Max <max@example.com>",
                          "must never end up 'replying' to the account's own already-sent message")
    }

    // MARK: draftOne applies learned style guidance (Phase 3)

    func testDraftEligibleJobsAppliesLearnedStyleGuidanceWhenAvailable() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m5@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m5@x", account: "acc", subject: "s", sender: "Alice <alice@acme.com>",
                                   threadID: threadID, bodyText: "How's Friday looking?", dateUnix: 1)
        try draftStore.upsertStyleProfile(scope: "address:alice@acme.com",
                                          profileText: "Always signs off with just \u{201C}M\u{201D}.",
                                          sampleCount: 3, updatedAt: 1)

        try draftStore.enqueueJob(sourceID: 1, messageID: "m5@x", detectedAt: 1)
        try draftStore.updateJobState(sourceID: 1, messageID: "m5@x", state: .eligible,
                                      attempts: 0, lastError: nil, updatedAt: 1)

        let capturing = CapturingChatProvider()
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: capturing,
                                                  embedder: StubEmbedder(), concurrency: 2)

        let system = try XCTUnwrap(capturing.lastRequest?.system)
        XCTAssertTrue(system.contains("Always signs off with just \u{201C}M\u{201D}."),
                     "the learned address-scoped profile must be folded into the draft's system prompt")
        XCTAssertEqual(try draftStore.job(sourceID: 1)?.state, .drafted)
    }

    /// Regression: without the account's own email threaded through to
    /// `DraftAssembler`, the assembled prompt named only the correspondent
    /// -- nothing told the model who *it* was drafting on behalf of, which
    /// in practice let a weak local model latch onto a name mentioned
    /// inside the message body and address the reply to the account owner
    /// instead of the correspondent.
    func testDraftEligibleJobsThreadsAccountEmailIntoTheAssembledPrompt() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m7@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m7@x", account: "acc", subject: "s", sender: "Alice <alice@acme.com>",
                                   threadID: threadID, bodyText: "Hi Bob, how's Friday looking?", dateUnix: 1)
        try draftStore.enqueueJob(sourceID: 1, messageID: "m7@x", detectedAt: 1)
        try draftStore.updateJobState(sourceID: 1, messageID: "m7@x", state: .eligible,
                                      attempts: 0, lastError: nil, updatedAt: 1)

        let capturing = CapturingChatProvider()
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: capturing,
                                                  embedder: StubEmbedder(), concurrency: 2,
                                                  accountEmail: "bob@example.com")

        let user = try XCTUnwrap(capturing.lastRequest?.user)
        XCTAssertTrue(user.contains("You are drafting this reply as bob@example.com"))
        XCTAssertTrue(user.contains("Address the reply to Alice <alice@acme.com>"))
    }

    func testDraftEligibleJobsOmitsStyleGuidanceWhenNoneLearnedYet() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m6@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m6@x", account: "acc", subject: "s", sender: "bob@nobody.com",
                                   threadID: threadID, bodyText: "Quick one for you.", dateUnix: 1)

        try draftStore.enqueueJob(sourceID: 2, messageID: "m6@x", detectedAt: 1)
        try draftStore.updateJobState(sourceID: 2, messageID: "m6@x", state: .eligible,
                                      attempts: 0, lastError: nil, updatedAt: 1)

        let capturing = CapturingChatProvider()
        await DraftJobProcessor.draftEligibleJobs(draftStore: draftStore, askStore: askStore, chatProvider: capturing,
                                                  embedder: StubEmbedder(), concurrency: 2)

        let system = try XCTUnwrap(capturing.lastRequest?.system)
        // Rule 1's base text legitimately mentions "STYLE GUIDANCE" generically
        // regardless of whether any is supplied, so check for the appended
        // block's own distinguishing header line instead of the bare phrase.
        XCTAssertFalse(system.contains("STYLE GUIDANCE (how this user writes"),
                       "no style block must be appended when nothing has been learned yet")
    }

    // MARK: regenerateDraft (Phase 4, Services menu "Regenerate")

    func testRegenerateDraftInsertsANewReadyDraftGroundedOnTheThreadsCurrentLatestMessage() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m1@x", account: "acc", subject: "Catch up", sender: "alice@example.com",
                                   threadID: threadID, bodyText: "How's Friday looking?", dateUnix: 1)

        let stub = StubChatProvider(name: "stub-local", tokens: ["Friday works for me!"])
        let record = try await DraftJobProcessor.regenerateDraft(
            threadID: threadID, draftStore: draftStore, askStore: askStore,
            chatProvider: stub, embedder: StubEmbedder())

        XCTAssertEqual(record.draftText, "Friday works for me!")
        XCTAssertEqual(record.status, .ready)
        let stored = try XCTUnwrap(try draftStore.latestDraft(threadID: threadID))
        XCTAssertEqual(stored.pk, record.pk)
    }

    /// Same accountEmail regression as the job-queue path, for the
    /// Services-menu "Regenerate" entry point.
    func testRegenerateDraftThreadsAccountEmailIntoTheAssembledPrompt() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m1@x", account: "acc", subject: "Catch up",
                                   sender: "Alice <alice@example.com>", threadID: threadID,
                                   bodyText: "Hi Bob, how's Friday looking?", dateUnix: 1)

        let capturing = CapturingChatProvider()
        _ = try await DraftJobProcessor.regenerateDraft(
            threadID: threadID, draftStore: draftStore, askStore: askStore,
            chatProvider: capturing, embedder: StubEmbedder(), accountEmail: "bob@example.com")

        let user = try XCTUnwrap(capturing.lastRequest?.user)
        XCTAssertTrue(user.contains("You are drafting this reply as bob@example.com"))
        XCTAssertTrue(user.contains("Address the reply to Alice <alice@example.com>"))
    }

    /// Regenerate bypasses the job queue entirely -- no `draft_jobs` row
    /// should be touched or created by it (that's `draftOne`'s concern),
    /// distinguishing this on-demand path from the scheduled one.
    func testRegenerateDraftDoesNotTouchTheJobQueue() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m1@x", account: "acc", subject: "s", sender: "a@x",
                                   threadID: threadID, bodyText: "body", dateUnix: 1)

        _ = try await DraftJobProcessor.regenerateDraft(
            threadID: threadID, draftStore: draftStore, askStore: askStore,
            chatProvider: StubChatProvider(name: "stub-local", tokens: ["reply"]), embedder: StubEmbedder())

        let (pending, failed) = try draftStore.pendingAndFailedCounts()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(failed, 0)
    }

    func testRegenerateDraftThrowsOnEmptyThread() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        do {
            _ = try await DraftJobProcessor.regenerateDraft(
                threadID: "nonexistent-thread", draftStore: draftStore, askStore: askStore,
                chatProvider: StubChatProvider(name: "stub-local", tokens: ["reply"]), embedder: StubEmbedder())
            XCTFail("expected emptyThread to be thrown")
        } catch DraftJobError.emptyThread {
            // expected
        }
    }

    /// Regression: regenerating an already-drafted thread must replace the
    /// prior `ready` draft, not accumulate a second row for the same
    /// thread (Phase 1's `latestDraft` doc comment flagged this as "a later
    /// phase's concern" -- Phase 4 is that phase).
    func testRegenerateDraftReplacesTheThreadsExistingReadyDraftInsteadOfDuplicatingIt() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m1@x", account: "acc", subject: "Catch up", sender: "alice@example.com",
                                   threadID: threadID, bodyText: "How's Friday looking?", dateUnix: 1)
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "m1@x",
                                   sender: "alice@example.com", subject: "Catch up",
                                   draftText: "original draft", generatedAt: 1, status: .ready)

        let record = try await DraftJobProcessor.regenerateDraft(
            threadID: threadID, draftStore: draftStore, askStore: askStore,
            chatProvider: StubChatProvider(name: "stub-local", tokens: ["regenerated draft"]), embedder: StubEmbedder())

        let readyDrafts = try draftStore.readyDrafts(limit: 200).filter { $0.threadID == threadID }
        XCTAssertEqual(readyDrafts.count, 1, "only the freshly regenerated draft should remain ready for this thread")
        XCTAssertEqual(readyDrafts.first?.pk, record.pk)
        XCTAssertEqual(readyDrafts.first?.draftText, "regenerated draft",
                       "the surviving row must be the new content, not the original")
    }

    /// If generation itself fails, the thread's existing ready draft must
    /// survive untouched -- a failed regenerate must never leave the user
    /// with nothing.
    func testRegenerateDraftLeavesTheExistingDraftIntactWhenGenerationFails() async throws {
        let draftStore = try DraftStore.inMemory()
        let askStore = try SQLiteStore.inMemory()
        let threadID = try ThreadResolver.resolveThread(messageID: "m1@x", inReplyTo: nil, references: [], store: askStore)
        try askStore.upsertMessage(messageID: "m1@x", account: "acc", subject: "s", sender: "a@x",
                                   threadID: threadID, bodyText: "body", dateUnix: 1)
        try draftStore.insertDraft(threadID: threadID, latestMessageID: "m1@x", sender: "a@x", subject: "s",
                                   draftText: "original draft", generatedAt: 1, status: .ready)

        do {
            // empty stream -> emptyDraft thrown
            _ = try await DraftJobProcessor.regenerateDraft(
                threadID: threadID, draftStore: draftStore, askStore: askStore,
                chatProvider: StubChatProvider(name: "stub-local", tokens: []), embedder: StubEmbedder())
            XCTFail("expected emptyDraft to be thrown")
        } catch DraftJobError.emptyDraft {
            // expected
        }

        let readyDrafts = try draftStore.readyDrafts(limit: 200).filter { $0.threadID == threadID }
        XCTAssertEqual(readyDrafts.count, 1, "a failed regenerate must not delete the existing draft")
        XCTAssertEqual(readyDrafts.first?.draftText, "original draft")
    }
}

/// Thread-safe boolean latch, mirroring `DraftPipelineIntegrationTests.swift`'s
/// file-local helper of the same shape.
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
}

/// Captures the last `ChatRequest` it was asked to stream, so a test can
/// assert on the assembled system/user prompt without a live model.
private final class CapturingChatProvider: ChatProvider, @unchecked Sendable {
    let name = "capturing-stub"
    private let lock = NSLock()
    private var _lastRequest: ChatRequest?
    var lastRequest: ChatRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequest
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _lastRequest = request; lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield("stub response")
            continuation.finish()
        }
    }
}
