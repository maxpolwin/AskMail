import XCTest
@testable import AskMailCore

/// HTTP-level tests for the concrete providers (`OllamaClient`,
/// `OllamaEmbedder`, `MistralClient`): response parsing, error mapping, and
/// retry discrimination — run against the real URL loading machinery via a
/// stub `URLProtocol`, with no network and no Ollama daemon.
final class ProvidersHTTPTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: OllamaEmbedder

    func testEmbedderParsesEmbeddingsResponse() async throws {
        StubURLProtocol.enqueue(status: 200, body: #"{"embeddings":[[0.1,0.2],[0.3,0.4]]}"#)
        let vectors = try await OllamaEmbedder().embed(["a", "b"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], [0.1, 0.2])
        XCTAssertEqual(vectors[1], [0.3, 0.4])
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testEmbedderMapsMissingModel404ToActionableError() async {
        StubURLProtocol.enqueue(status: 404,
                                body: #"{"error":"model \"mxbai-embed-large\" not found, try pulling it first"}"#)
        do {
            _ = try await OllamaEmbedder(model: "mxbai-embed-large").embed(["a"])
            XCTFail("expected ollamaModelMissing")
        } catch ProviderError.ollamaModelMissing(let model) {
            XCTAssertEqual(model, "mxbai-embed-large")
        } catch {
            XCTFail("expected ollamaModelMissing, got \(error)")
        }
        // A 4xx must fail fast: no retry may have consumed a second request.
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testEmbedderRetriesTransient5xxThenSucceeds() async throws {
        StubURLProtocol.enqueue(status: 503, body: "busy")
        StubURLProtocol.enqueue(status: 200, body: #"{"embeddings":[[1.0]]}"#)
        let vectors = try await OllamaEmbedder(maxAttempts: 2).embed(["a"])
        XCTAssertEqual(vectors, [[1.0]])
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testEmbedderRejectsMalformedResponse() async {
        StubURLProtocol.enqueue(status: 200, body: #"{"unexpected":true}"#)
        do {
            // maxAttempts 1: malformed JSON is retried as "transient" by
            // design (isTransient only exempts 4xx and cancellation), so a
            // single attempt keeps this test to one request.
            _ = try await OllamaEmbedder(maxAttempts: 1).embed(["a"])
            XCTFail("expected malformedResponse")
        } catch ProviderError.malformedResponse {
        } catch {
            XCTFail("expected malformedResponse, got \(error)")
        }
    }

    // MARK: OllamaClient chat streaming

    func testOllamaChatYieldsTokensFromNDJSONStream() async throws {
        StubURLProtocol.enqueue(status: 200, body: """
        {"message":{"content":"Hel"}}
        {"message":{"content":"lo"}}
        {"not-a-message":true}
        {"message":{"content":"!"},"done":true}
        """)
        var answer = ""
        for try await token in OllamaClient().stream(ChatRequest(system: "s", user: "u")) {
            answer += token
        }
        XCTAssertEqual(answer, "Hello!")
    }

    func testOllamaChatMapsLocalMissingModel404() async {
        // Two responses: the connect-phase retry treats a 404 as non-transient,
        // but enqueue a spare to prove it wasn't consumed.
        StubURLProtocol.enqueue(status: 404, body: #"{"error":"model \"qwen3\" not found"}"#)
        StubURLProtocol.enqueue(status: 404, body: "spare")
        do {
            for try await _ in OllamaClient(model: "qwen3").stream(ChatRequest(system: "s", user: "u")) {}
            XCTFail("expected ollamaModelMissing")
        } catch ProviderError.ollamaModelMissing(let model) {
            XCTAssertEqual(model, "qwen3")
        } catch {
            XCTFail("expected ollamaModelMissing, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "a 404 must not burn the connect-phase retry")
    }

    func testOllamaCloudKeeps404Verbatim() async {
        // Cloud (apiKey set): the missing-model rewrite is local-only.
        StubURLProtocol.enqueue(status: 404, body: #"{"error":"model not found"}"#)
        let cloud = OllamaClient(host: Defaults.ollamaCloudHost, model: "m", apiKey: "k")
        do {
            for try await _ in cloud.stream(ChatRequest(system: "s", user: "u")) {}
            XCTFail("expected http error")
        } catch ProviderError.http(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("expected .http, got \(error)")
        }
    }

    // MARK: MistralClient SSE streaming

    func testMistralYieldsTokensFromSSEStream() async throws {
        StubURLProtocol.enqueue(status: 200, body: """
        data: {"choices":[{"delta":{"content":"Bon"}}]}
        ignored-non-data-line
        data: {"choices":[{"delta":{"content":"jour"}}]}
        data: [DONE]
        data: {"choices":[{"delta":{"content":"never reached"}}]}
        """)
        var answer = ""
        let mistral = MistralClient(apiKey: "k")
        for try await token in mistral.stream(ChatRequest(system: "s", user: "u")) {
            answer += token
        }
        XCTAssertEqual(answer, "Bonjour")
    }

    func testMistralModelListParsesAndDedupes() throws {
        let data = Data(#"{"data":[{"id":"mistral-large"},{"id":"mistral-small"},{"id":"mistral-large"}]}"#.utf8)
        XCTAssertEqual(try MistralClient.parseModels(data), ["mistral-large", "mistral-small"])
        XCTAssertThrowsError(try MistralClient.parseModels(Data(#"{"nope":1}"#.utf8)))
    }
}

/// Serves queued canned responses to any request made through the shared
/// URLSession while registered. FIFO; every served request is counted so
/// tests can assert retry behavior.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Stub] = []
    nonisolated(unsafe) private static var served = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    static func enqueue(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        queue.append(Stub(status: status, body: Data(body.utf8)))
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
        served = 0
    }

    private static func next() -> Stub? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        served += 1
        return queue.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.next() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
