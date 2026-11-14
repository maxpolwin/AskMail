import XCTest
@testable import AskMailCore

/// Backend-neutral embeddings: the loopback OpenAI-compatible embedder, the
/// factory, and the canary check that lets an index outlive a runtime switch
/// (and refuses to mix vectors that don't match) — all without a network or a
/// real model server.
final class EmbeddingBackendTests: XCTestCase {

    private let base = URL(string: "http://localhost:1234/v1")!

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func stubbedEmbedder(model: String = "m", maxAttempts: Int = 3) -> OpenAIEmbedder {
        OpenAIEmbedder(baseURL: base, model: model, maxAttempts: maxAttempts, timeout: 5,
                       session: LocalServerSession.make(protocolClasses: [StubURLProtocol.self]))
    }

    private func entries(_ names: [String], fingerprint: String = "v1") -> [EmlxFile] {
        names.enumerated().map { index, name in
            EmlxFile(sourceID: Int64(index + 1),
                     url: Self.fixturesDirectory.appendingPathComponent(name),
                     fingerprint: fingerprint)
        }
    }

    // MARK: OpenAIEmbedder

    func testEmbedderReturnsVectorsInInputOrderEvenIfServerReorders() async throws {
        StubURLProtocol.enqueue(status: 200, body: """
        {"data":[{"index":1,"embedding":[0.3,0.4]},{"index":0,"embedding":[0.1,0.2]}]}
        """)
        let vectors = try await stubbedEmbedder().embed(["a", "b"])
        XCTAssertEqual(vectors, [[0.1, 0.2], [0.3, 0.4]])
    }

    func testEmbedderAcceptsMissingIndexFieldsInArrayOrder() async throws {
        StubURLProtocol.enqueue(status: 200, body: #"{"data":[{"embedding":[1,0]},{"embedding":[0,1]}]}"#)
        let vectors = try await stubbedEmbedder().embed(["a", "b"])
        XCTAssertEqual(vectors, [[1, 0], [0, 1]])
    }

    func testRequestShapeAndLoopbackOnly() throws {
        let request = try stubbedEmbedder(model: "nomic").buildRequest(["x", "y"])
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:1234/v1/embeddings")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "nomic")
        XCTAssertEqual(body["input"] as? [String], ["x", "y"])
    }

    func testNonLoopbackHostIsRefusedBeforeAnyIO() async {
        let remote = OpenAIEmbedder(baseURL: URL(string: "http://192.168.1.20:1234/v1")!, model: "m",
                                    session: LocalServerSession.make(protocolClasses: [StubURLProtocol.self]))
        do {
            _ = try await remote.embed(["secret mail text"])
            XCTFail("expected egressBlocked")
        } catch ProviderError.egressBlocked {
        } catch {
            XCTFail("expected egressBlocked, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "nothing may be sent to a non-loopback host")
    }

    func testMalformedResponsesFailClosedWithoutRetry() async {
        let bodies = [
            #"{"unexpected":true}"#,                                         // no data array
            #"{"data":[{"index":0,"embedding":[1,2]}]}"#,                     // 1 vector for 2 inputs
            #"{"data":[{"index":0,"embedding":[1]},{"index":0,"embedding":[2]}]}"#,   // duplicate index
            #"{"data":[{"index":5,"embedding":[1]},{"index":0,"embedding":[2]}]}"#,   // out of range
            #"{"data":[{"index":0,"embedding":[1,2]},{"index":1,"embedding":[1]}]}"#, // differing widths
            #"{"data":[{"index":0,"embedding":[]},{"index":1,"embedding":[1]}]}"#,    // empty vector
            #"{"data":[{"index":0,"embedding":["x"]},{"index":1,"embedding":["y"]}]}"#, // not numbers
            #"{"data":[{"index":0,"embedding":[1e39]},{"index":1,"embedding":[1]}]}"#,  // overflows Float
        ]
        for body in bodies {
            StubURLProtocol.reset()
            StubURLProtocol.enqueue(status: 200, body: body)
            do {
                _ = try await stubbedEmbedder().embed(["a", "b"])
                XCTFail("expected malformedResponse for \(body)")
            } catch ProviderError.malformedResponse {
            } catch {
                XCTFail("expected malformedResponse for \(body), got \(error)")
            }
            XCTAssertEqual(StubURLProtocol.requestCount, 1, "a malformed answer must not be retried: \(body)")
        }
    }

    func testOverWideVectorIsRejected() throws {
        let wide = "[" + Array(repeating: "0.5", count: OpenAIEmbedder.maxDimensions + 1).joined(separator: ",") + "]"
        let data = Data(#"{"data":[{"index":0,"embedding":\#(wide)}]}"#.utf8)
        XCTAssertThrowsError(try OpenAIEmbedder.parse(data, expected: 1))
    }

    func testResponseBodyIsSizeCapped() async {
        let stream = AsyncStream<UInt8> { continuation in
            for _ in 0..<100 { continuation.yield(UInt8(ascii: "a")) }
            continuation.finish()
        }
        do {
            _ = try await OpenAIEmbedder.boundedData(stream, limit: 10)
            XCTFail("expected the cap to trip")
        } catch ProviderError.malformedResponse {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTransient5xxIsRetriedButClientErrorsAreNot() async throws {
        StubURLProtocol.enqueue(status: 503, body: "busy")
        StubURLProtocol.enqueue(status: 200, body: #"{"data":[{"index":0,"embedding":[1]}]}"#)
        let retried = try await stubbedEmbedder(maxAttempts: 2).embed(["a"])
        XCTAssertEqual(retried, [[1]])
        XCTAssertEqual(StubURLProtocol.requestCount, 2)

        StubURLProtocol.reset()
        StubURLProtocol.enqueue(status: 400, body: "bad request")
        do {
            _ = try await stubbedEmbedder(maxAttempts: 3).embed(["a"])
            XCTFail("expected http error")
        } catch ProviderError.http(let status, _) {
            XCTAssertEqual(status, 400)
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testMissingModelMapsToActionableErrorWithoutRetry() async {
        StubURLProtocol.enqueue(status: 404, body: #"{"error":{"message":"Model 'nomic' not found"}}"#)
        do {
            _ = try await stubbedEmbedder(model: "nomic").embed(["a"])
            XCTFail("expected serverModelMissing")
        } catch ProviderError.serverModelMissing(let model) {
            XCTAssertEqual(model, "nomic")
        } catch {
            XCTFail("expected serverModelMissing, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertFalse(ProviderError.isServerModelMissing(status: 404, body: "Not Found"),
                       "a bare 404 (wrong path) is not a missing model")
    }

    // MARK: Factory

    func testFactoryBuildsLoopbackOnlyEmbedders() async {
        XCTAssertTrue(EmbedderFactory.make(EmbeddingConfig()) is OllamaEmbedder)
        XCTAssertTrue(EmbedderFactory.make(
            EmbeddingConfig(backend: .localServer, model: "m", serverURL: "http://localhost:1234/v1"))
            is OpenAIEmbedder)

        let bad: [(EmbeddingConfig, String)] = [
            (EmbeddingConfig(backend: .localServer, model: "m", serverURL: "http://192.168.1.5:1234/v1"), "LAN host"),
            (EmbeddingConfig(backend: .localServer, model: "m", serverURL: "https://api.mistral.ai/v1"), "cloud host"),
            (EmbeddingConfig(backend: .localServer, model: "m", serverURL: "nonsense"), "not a URL"),
            (EmbeddingConfig(backend: .localServer, model: "  ", serverURL: "http://localhost:1234/v1"), "no model"),
        ]
        for (config, why) in bad {
            let embedder = EmbedderFactory.make(config)
            XCTAssertTrue(embedder is FailingEmbedder, why)
            do {
                _ = try await embedder.embed(["x"])
                XCTFail("\(why): expected an error")
            } catch is ProviderError {
            } catch {
                XCTFail("\(why): unexpected \(error)")
            }
        }
    }

    // MARK: Canary

    /// Same direction as `StubEmbedder`, different magnitude: cosine-identical,
    /// the stand-in for "same model, different runtime".
    private struct ScaledEmbedder: EmbeddingProvider {
        func embed(_ texts: [String]) async throws -> [[Float]] {
            try await StubEmbedder().embed(texts).map { $0.map { $0 * 3 } }
        }
    }

    /// Same width, scrambled coordinates: the stand-in for "a different model".
    private struct ShiftedEmbedder: EmbeddingProvider {
        func embed(_ texts: [String]) async throws -> [[Float]] {
            try await StubEmbedder().embed(texts).map { vector in
                (0..<vector.count).map { vector[($0 * 7 + 3) % vector.count] }
            }
        }
    }

    private struct WideEmbedder: EmbeddingProvider {
        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.1, count: 64) }
        }
    }

    private struct ThrowingEmbedder: EmbeddingProvider {
        let error: Error
        func embed(_ texts: [String]) async throws -> [[Float]] { throw error }
    }

    /// A store with one ingested message and a baseline recorded by `StubEmbedder`.
    private func indexedStore() async throws -> SQLiteStore {
        let store = try SQLiteStore.inMemory()
        let ingestor = MailboxIngestor(store: store, embedder: StubEmbedder(), account: "test",
                                       embeddingStamp: EmbeddingStamp(model: "stub"), log: { _, _ in })
        _ = try await ingestor.ingestNew(entries(["msg-0001-plain.emlx"]))
        XCTAssertGreaterThan(try store.chunkCount(), 0)
        return store
    }

    func testEmptyIndexNeedsNoCheck() async throws {
        let store = try SQLiteStore.inMemory()
        guard case .emptyIndex = await EmbeddingCanary.assess(store: store, embedder: StubEmbedder()) else {
            return XCTFail("expected .emptyIndex")
        }
    }

    func testSameModelThroughAnotherRuntimeIsCompatible() async throws {
        let store = try await indexedStore()
        guard case .compatible(let similarity) = await EmbeddingCanary.assess(store: store, embedder: ScaledEmbedder()) else {
            return XCTFail("expected .compatible")
        }
        XCTAssertGreaterThanOrEqual(similarity, EmbeddingCanary.threshold)
    }

    func testDifferentModelOrWidthIsIncompatible() async throws {
        let store = try await indexedStore()
        for embedder in [ShiftedEmbedder() as EmbeddingProvider, WideEmbedder()] {
            guard case .incompatible = await EmbeddingCanary.assess(store: store, embedder: embedder) else {
                return XCTFail("expected .incompatible for \(type(of: embedder))")
            }
        }
    }

    func testUnreachableBackendIsUnverifiableNotIncompatible() async throws {
        let store = try await indexedStore()
        let down = ThrowingEmbedder(error: URLError(.cannotConnectToHost))
        guard case .unverifiable = await EmbeddingCanary.assess(store: store, embedder: down) else {
            return XCTFail("expected .unverifiable — an outage must never look like a mismatch")
        }
    }

    func testIndexWithoutBaselineIsReportedAsLegacy() async throws {
        let store = try SQLiteStore.inMemory()
        let legacy = MailboxIngestor(store: store, embedder: StubEmbedder(), account: "test", log: { _, _ in })
        _ = try await legacy.ingestNew(entries(["msg-0001-plain.emlx"]))
        guard case .noBaseline = await EmbeddingCanary.assess(store: store, embedder: StubEmbedder()) else {
            return XCTFail("expected .noBaseline")
        }
    }

    func testCorruptStoredBaselineIsTreatedAsMissing() {
        let good = EmbeddingCanary.encode(dimensions: 2, vectors: Array(repeating: [1, 0], count: 3))
        XCTAssertNotNil(EmbeddingCanary.decode(good))
        for bad in ["", "v2:2:AAAA", "v1:0:AAAA", "v1:99999:AAAA", "v1:2:not-base64!",
                    "v1:2:" + Data(count: 5).base64EncodedString(),         // wrong length
                    "v1:2:" + Data(repeating: 0xFF, count: 24).base64EncodedString()] {  // NaN floats
            XCTAssertNil(EmbeddingCanary.decode(bad), bad)
        }
    }

    // MARK: Ingest gate

    func testIngestKeepsIndexWhenSameModelIsServedByAnotherRuntime() async throws {
        let store = try await indexedStore()
        let before = try store.chunkCount()
        // Different name, different runtime, cosine-identical vectors.
        let other = MailboxIngestor(store: store, embedder: ScaledEmbedder(), account: "test",
                                    embeddingStamp: EmbeddingStamp(model: "text-embedding-other-name"),
                                    log: { _, _ in })
        let summary = try await other.ingestNew(entries(["msg-0001-plain.emlx", "msg-0002-html-de.emlx"]))
        XCTAssertEqual(summary.ingested, 1)
        XCTAssertGreaterThan(try store.chunkCount(), before)
        XCTAssertEqual(try store.embeddingStamp()?.model, "text-embedding-other-name")
    }

    func testIngestRefusesIncompatibleVectorsUnderADifferentName() async throws {
        let store = try await indexedStore()
        let before = try store.chunkCount()
        let other = MailboxIngestor(store: store, embedder: ShiftedEmbedder(), account: "test",
                                    embeddingStamp: EmbeddingStamp(model: "another-model"),
                                    log: { _, _ in })
        do {
            _ = try await other.ingestNew(entries(["msg-0002-html-de.emlx"]))
            XCTFail("expected refusal")
        } catch IngestError.embeddingModelMismatch(let configured, let indexed) {
            XCTAssertEqual(configured, "another-model")
            XCTAssertEqual(indexed, "stub")
        }
        XCTAssertEqual(try store.chunkCount(), before, "nothing was mixed in")
        XCTAssertEqual(try store.embeddingStamp()?.model, "stub")
    }

    func testIngestRefusesASilentlySwappedModelUnderTheSameName() async throws {
        let store = try await indexedStore()
        let before = try store.chunkCount()
        // The name says "stub", but the server now answers with a different model.
        let swapped = MailboxIngestor(store: store, embedder: ShiftedEmbedder(), account: "test",
                                      embeddingStamp: EmbeddingStamp(model: "stub"), log: { _, _ in })
        do {
            _ = try await swapped.ingestNew(entries(["msg-0002-html-de.emlx"]))
            XCTFail("expected refusal")
        } catch IngestError.embeddingIncompatible {
        }
        XCTAssertEqual(try store.chunkCount(), before)
    }

    func testIngestRefusesDifferentNameWhenLegacyIndexCannotBeProvenCompatible() async throws {
        let store = try SQLiteStore.inMemory()
        let legacy = MailboxIngestor(store: store, embedder: StubEmbedder(), account: "test",
                                     embeddingStamp: nil, log: { _, _ in })
        _ = try await legacy.ingestNew(entries(["msg-0001-plain.emlx"]))
        try store.setEmbeddingStamp(EmbeddingStamp(model: "old-model"))   // stamped, but no canary baseline
        let other = MailboxIngestor(store: store, embedder: ScaledEmbedder(), account: "test",
                                    embeddingStamp: EmbeddingStamp(model: "new-model"), log: { _, _ in })
        do {
            _ = try await other.ingestNew(entries(["msg-0002-html-de.emlx"]))
            XCTFail("expected refusal")
        } catch IngestError.embeddingModelMismatch {
        }
    }

    func testIngestMapsSetupFailuresDuringTheCompatibilityCheck() async throws {
        let store = try await indexedStore()
        let cases: [(Error, (IngestError) -> Bool)] = [
            (URLError(.cannotConnectToHost), { if case .embedderUnreachable = $0 { return true } else { return false } }),
            (ProviderError.serverModelMissing(model: "m"), { if case .embeddingModelMissing = $0 { return true } else { return false } }),
        ]
        for (error, matches) in cases {
            let ingestor = MailboxIngestor(store: store, embedder: ThrowingEmbedder(error: error), account: "test",
                                           embeddingStamp: EmbeddingStamp(model: "stub"), log: { _, _ in })
            do {
                _ = try await ingestor.ingestNew(entries(["msg-0002-html-de.emlx"]))
                XCTFail("expected an IngestError for \(error)")
            } catch let ingestError as IngestError {
                XCTAssertTrue(matches(ingestError), "\(error) -> \(ingestError)")
            }
        }
    }

    func testDeleteAllClearsTheBaseline() async throws {
        let store = try await indexedStore()
        XCTAssertNotNil(try store.meta(EmbeddingCanary.metaKey))
        try store.deleteAll()
        XCTAssertNil(try store.meta(EmbeddingCanary.metaKey))
    }

    // MARK: Onboarding

    func testChecklistForALocalEmbeddingServer() {
        func derive(_ readiness: EmbeddingBackendReadiness) -> OnboardingChecklist {
            OnboardingChecklist.derive(fullDiskAccess: true, accountPicked: true,
                                       embeddingBackend: readiness, hasVectorized: true)
        }
        XCTAssertTrue(derive(.server(reachable: true, modelAvailable: true)).allDone)

        let noModel = derive(.server(reachable: true, modelAvailable: false))
        XCTAssertTrue(noModel.backendRunning)
        XCTAssertFalse(noModel.embeddingModelInstalled)

        let down = derive(.server(reachable: false, modelAvailable: true))
        XCTAssertFalse(down.backendRunning)
        XCTAssertFalse(down.embeddingModelInstalled, "an unreachable server can't have a usable model")

        XCTAssertFalse(derive(.checking).backendRunning, "unknown claims nothing")
    }
}
