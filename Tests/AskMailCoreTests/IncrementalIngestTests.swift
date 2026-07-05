import XCTest
@testable import AskMailCore

/// FR-5: scheduled/manual runs ingest only new or changed messages and survive
/// re-runs and crashes via per-file fingerprints.
final class IncrementalIngestTests: XCTestCase {

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func entries(fingerprint: String) -> [EmlxFile] {
        ["msg-0001-plain.emlx", "msg-0002-html-de.emlx", "msg-0003-pdf.emlx"]
            .enumerated()
            .map { index, name in
                EmlxFile(sourceID: Int64(index + 1),
                         url: Self.fixturesDirectory.appendingPathComponent(name),
                         fingerprint: fingerprint)
            }
    }

    func testFirstRunIngestsAllThenSkipsUnchanged() async throws {
        let store = try SQLiteStore.inMemory()
        let ingestor = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                       account: "test", log: { _, _ in })

        let first = try await ingestor.ingestNew(entries(fingerprint: "v1"))
        XCTAssertEqual(first.ingested, 3)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.failed, 0)
        XCTAssertEqual(try store.messageCount(), 3)

        let chunksAfterFirst = try store.chunkCount()

        // Same fingerprints: nothing re-embedded, no duplicate chunks.
        let second = try await ingestor.ingestNew(entries(fingerprint: "v1"))
        XCTAssertEqual(second.ingested, 0)
        XCTAssertEqual(second.skipped, 3)
        XCTAssertEqual(try store.chunkCount(), chunksAfterFirst)
    }

    func testChangedFingerprintReingestsOnlyThatFile() async throws {
        let store = try SQLiteStore.inMemory()
        let ingestor = MailboxIngestor(store: store, embedder: StubEmbedder(),
                                       account: "test", log: { _, _ in })
        _ = try await ingestor.ingestNew(entries(fingerprint: "v1"))
        let chunksBefore = try store.chunkCount()

        // One file changed on disk (e.g. .partial became fully downloaded).
        var changed = entries(fingerprint: "v1")
        changed[2].fingerprint = "v2"
        let summary = try await ingestor.ingestNew(changed)

        XCTAssertEqual(summary.ingested, 1, "only the changed file is re-ingested")
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(try store.messageCount(), 3, "no new message rows")
        XCTAssertEqual(try store.chunkCount(), chunksBefore, "idempotent replace, no dupes")
    }

    func testAbortsEarlyWhenEmbedderUnreachable() async throws {
        let store = try SQLiteStore.inMemory()
        let embedder = UnreachableEmbedder()
        let ingestor = MailboxIngestor(store: store, embedder: embedder,
                                       account: "test", log: { _, _ in })

        // 10 files, but the backend refuses every connection: the run must abort
        // after the threshold rather than trying all 10.
        let many = (1...10).map { id in
            EmlxFile(sourceID: Int64(id),
                     url: Self.fixturesDirectory.appendingPathComponent("msg-0001-plain.emlx"),
                     fingerprint: "v\(id)")
        }
        do {
            _ = try await ingestor.ingestNew(many)
            XCTFail("expected the run to abort")
        } catch let error as IngestError {
            guard case .embedderUnreachable = error else { return XCTFail("wrong error") }
        }
        XCTAssertEqual(embedder.calls, MailboxIngestor.unreachableAbortThreshold,
                       "aborts at the threshold, not after every file")
        XCTAssertEqual(try store.messageCount(), 0, "nothing embedded while the backend is down")
    }

    func testFingerprintRoundTripsAndDeleteAllClearsIt() async throws {
        let store = try SQLiteStore.inMemory()
        XCTAssertNil(try store.ingestedFingerprint(sourceID: 42))

        try store.recordIngested(sourceID: 42, fingerprint: "abc")
        XCTAssertEqual(try store.ingestedFingerprint(sourceID: 42), "abc")

        try store.recordIngested(sourceID: 42, fingerprint: "def")
        XCTAssertEqual(try store.ingestedFingerprint(sourceID: 42), "def",
                       "upsert overwrites the fingerprint")

        try store.deleteAll()
        XCTAssertNil(try store.ingestedFingerprint(sourceID: 42),
                     "delete & rebuild resets ingest state so the next run rebuilds")
    }
}

/// Simulates a down Ollama: every embed refuses the connection, like the
/// observed -1004 cascade.
final class UnreachableEmbedder: EmbeddingProvider, @unchecked Sendable {
    private(set) var calls = 0
    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls += 1
        throw URLError(.cannotConnectToHost)
    }
}

final class RetryTests: XCTestCase {

    func testSucceedsAfterTransientFailures() async throws {
        var calls = 0
        let result = try await Retry.run(attempts: 3, backoff: { _ in 0 }) { () -> String in
            calls += 1
            if calls < 3 { throw ProviderError.http(status: 503, body: "busy") }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(calls, 3)
    }

    func testStopsImmediatelyWhenNotRetryable() async {
        var calls = 0
        do {
            _ = try await Retry.run(attempts: 5, backoff: { _ in 0 },
                                    shouldRetry: { _ in false }) { () -> String in
                calls += 1
                throw ProviderError.http(status: 400, body: "bad request")
            }
            XCTFail("expected the operation to throw")
        } catch {
            XCTAssertEqual(calls, 1, "a non-retryable error fails fast")
        }
    }

    func testGivesUpAfterMaxAttempts() async {
        var calls = 0
        do {
            _ = try await Retry.run(attempts: 3, backoff: { _ in 0 }) { () -> String in
                calls += 1
                throw ProviderError.http(status: 500, body: "down")
            }
            XCTFail("expected the operation to throw")
        } catch {
            XCTAssertEqual(calls, 3)
            XCTAssertTrue("\(error)".contains("500"))
        }
    }

    // The embedder retries 5xx/transport errors but not client errors.
    func testEmbedderTransientClassification() {
        XCTAssertTrue(OllamaEmbedder.isTransient(ProviderError.http(status: 503, body: "")))
        XCTAssertFalse(OllamaEmbedder.isTransient(ProviderError.http(status: 404, body: "")))
        XCTAssertTrue(OllamaEmbedder.isTransient(URLError(.timedOut)))
    }
}
