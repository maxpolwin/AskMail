import XCTest
@testable import AskMailCore

/// Phase 3: the embedding-model stamp and the guarantees around swapping
/// models — a stale stamp blocks incremental runs, the stamp round-trips, and
/// zero-chunk messages don't inflate the "new" count.
final class EmbeddingSwapTests: XCTestCase {

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func entries(_ names: [String], fingerprint: String = "v1") -> [EmlxFile] {
        names.enumerated().map { index, name in
            EmlxFile(sourceID: Int64(index + 1),
                     url: Self.fixturesDirectory.appendingPathComponent(name),
                     fingerprint: fingerprint)
        }
    }

    // MARK: Stamp encoding

    func testStampEncodesAndDecodesWithAndWithoutDimension() {
        let full = EmbeddingStamp(model: "nomic-embed-text", dimensions: 768)
        XCTAssertEqual(full.encoded, "nomic-embed-text@768")
        XCTAssertEqual(EmbeddingStamp.decode("nomic-embed-text@768"), full)

        let bare = EmbeddingStamp(model: "mxbai-embed-large")
        XCTAssertEqual(bare.encoded, "mxbai-embed-large")
        XCTAssertEqual(EmbeddingStamp.decode("mxbai-embed-large"), bare)
    }

    func testRequiresRebuildDecisionTable() {
        let stamp = EmbeddingStamp(model: "nomic-embed-text", dimensions: 768)
        // Empty index: nothing to corrupt, any model may proceed.
        XCTAssertFalse(EmbeddingStamp.requiresRebuild(configuredModel: "other",
                                                      stamp: stamp, chunkCount: 0))
        // No stamp: pre-stamp legacy index, adopted rather than blocked.
        XCTAssertFalse(EmbeddingStamp.requiresRebuild(configuredModel: "other",
                                                      stamp: nil, chunkCount: 10))
        // Same model (incl. :latest normalization): fine.
        XCTAssertFalse(EmbeddingStamp.requiresRebuild(configuredModel: "nomic-embed-text",
                                                      stamp: stamp, chunkCount: 10))
        XCTAssertFalse(EmbeddingStamp.requiresRebuild(
            configuredModel: "nomic-embed-text:latest", stamp: stamp, chunkCount: 10))
        // Different model on a non-empty index: rebuild required.
        XCTAssertTrue(EmbeddingStamp.requiresRebuild(configuredModel: "mxbai-embed-large",
                                                     stamp: stamp, chunkCount: 10))
    }

    // MARK: Stamping during ingest

    func testIngestStampsTheStoreAndDeleteAllClearsIt() async throws {
        let store = try SQLiteStore.inMemory()
        let stamp = EmbeddingStamp(model: "nomic-embed-text", dimensions: 768)
        let ingestor = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                       account: "test", embeddingStamp: stamp,
                                       log: { _, _ in })
        _ = try await ingestor.ingestNew(entries(["msg-0001-plain.emlx"]))
        XCTAssertEqual(try store.embeddingStamp(), stamp)

        try store.deleteAll()
        XCTAssertNil(try store.embeddingStamp(), "a wiped index carries no stamp")
    }

    func testMismatchedStampRefusesIncrementalRunBeforeAnyWork() async throws {
        let store = try SQLiteStore.inMemory()
        let first = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                    account: "test",
                                    embeddingStamp: EmbeddingStamp(model: "nomic-embed-text",
                                                                   dimensions: 768),
                                    log: { _, _ in })
        _ = try await first.ingestNew(entries(["msg-0001-plain.emlx"]))
        let chunksBefore = try store.chunkCount()
        XCTAssertGreaterThan(chunksBefore, 0)

        // Same store, different configured model: the run must refuse before
        // ingesting anything, and must not restamp.
        let second = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                     account: "test",
                                     embeddingStamp: EmbeddingStamp(model: "mxbai-embed-large",
                                                                    dimensions: 1024),
                                     log: { _, _ in })
        do {
            _ = try await second.ingestNew(entries(["msg-0002-html-de.emlx"], fingerprint: "v9"))
            XCTFail("expected the run to refuse")
        } catch let error as IngestError {
            guard case .embeddingModelMismatch(let configured, let indexed) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(configured, "mxbai-embed-large")
            XCTAssertEqual(indexed, "nomic-embed-text")
        }
        XCTAssertEqual(try store.chunkCount(), chunksBefore, "nothing was mixed in")
        XCTAssertEqual(try store.embeddingStamp()?.model, "nomic-embed-text",
                       "the stamp still names the model that built the index")
    }

    func testLegacyUnstampedIndexIsAdoptedNotBlocked() async throws {
        // An index built before stamping existed: the next run adopts it by
        // writing the configured model's stamp instead of refusing.
        let store = try SQLiteStore.inMemory()
        let legacy = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                     account: "test", log: { _, _ in })
        _ = try await legacy.ingestNew(entries(["msg-0001-plain.emlx"]))
        XCTAssertNil(try store.embeddingStamp())

        let stamped = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                      account: "test",
                                      embeddingStamp: EmbeddingStamp(model: "nomic-embed-text",
                                                                     dimensions: 768),
                                      log: { _, _ in })
        let summary = try await stamped.ingestNew(entries(["msg-0001-plain.emlx"]))
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try store.embeddingStamp()?.model, "nomic-embed-text")
    }

    // MARK: Adjacent cleanup #1 — empty-body messages

    func testEmptyBodyMessageCountsAsEmptyNotNew() async throws {
        let store = try SQLiteStore.inMemory()
        let ingestor = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                       account: "test", log: { _, _ in })
        let summary = try await ingestor.ingestNew(
            entries(["msg-0001-plain.emlx", "msg-0004-empty.emlx"]))

        XCTAssertEqual(summary.ingested, 1, "only the message with content is new")
        XCTAssertEqual(summary.empty, 1, "the bodyless one is reported apart")
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(try store.messageCount(), 2, "both messages are recorded")

        // The empty file is done: a re-run skips it rather than re-parsing.
        let second = try await ingestor.ingestNew(
            entries(["msg-0001-plain.emlx", "msg-0004-empty.emlx"]))
        XCTAssertEqual(second.skipped, 2)
        XCTAssertEqual(second.empty, 0)
    }

    // MARK: Adjacent cleanup #2 — stale failure rows

    func testPruneDropsFailuresNoLongerInScan() throws {
        let store = try SQLiteStore.inMemory()
        // Three failures on record: one still scannable, two from a mailbox
        // that the allowlist has since excluded.
        try store.recordIngestFailure(sourceID: 1, path: "/a/INBOX.mbox/1.emlx", error: "x")
        try store.recordIngestFailure(sourceID: 2, path: "/a/Trash.mbox/2.emlx", error: "x")
        try store.recordIngestFailure(sourceID: 3, path: "/a/Junk.mbox/3.emlx", error: "x")

        let pruned = try store.pruneIngestFailures(keeping: [1])
        XCTAssertEqual(pruned, 2)
        XCTAssertEqual(try store.failedIngestSourceIDs(), [1])

        // Idempotent: nothing left to prune.
        XCTAssertEqual(try store.pruneIngestFailures(keeping: [1]), 0)
    }

    // MARK: Onboarding checklist derivation

    func testChecklistDerivationTable() {
        // Everything green.
        let done = OnboardingChecklist.derive(fullDiskAccess: true, accountPicked: true,
                                              ollamaStatus: .ready(modelCount: 2),
                                              hasVectorized: true)
        XCTAssertTrue(done.allDone)

        // Daemon up but model missing: running yes, model no.
        let modelMissing = OnboardingChecklist.derive(
            fullDiskAccess: true, accountPicked: true,
            ollamaStatus: .runningModelMissing(model: "nomic-embed-text"),
            hasVectorized: false)
        XCTAssertTrue(modelMissing.ollamaRunning)
        XCTAssertFalse(modelMissing.embeddingModelInstalled)
        XCTAssertFalse(modelMissing.allDone)

        // Unknown status (first check in flight) claims nothing.
        let checking = OnboardingChecklist.derive(fullDiskAccess: false, accountPicked: false,
                                                  ollamaStatus: nil, hasVectorized: false)
        XCTAssertFalse(checking.ollamaRunning)
        XCTAssertFalse(checking.allDone)

        for status in [OllamaStatus.notInstalled, .stopped] {
            let derived = OnboardingChecklist.derive(fullDiskAccess: true, accountPicked: true,
                                                     ollamaStatus: status, hasVectorized: true)
            XCTAssertFalse(derived.ollamaRunning)
            XCTAssertFalse(derived.embeddingModelInstalled)
        }
    }
}
