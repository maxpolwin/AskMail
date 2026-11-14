import XCTest
@testable import AskMailCore

/// The loopback-only OpenAI-compatible provider: endpoint validation, request
/// shape + egress refusal, redirect refusal, bounded SSE parsing, context
/// overflow mapping, think-tag filtering, and the discovery parsers — all
/// without a network or a real model server.
final class LocalServerTests: XCTestCase {

    private let base = URL(string: "http://localhost:1234/v1")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        RedirectingURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        RedirectingURLProtocol.reset()
        super.tearDown()
    }

    private func stubbedClient(model: String = "m") -> OpenAIChatClient {
        OpenAIChatClient(baseURL: base, model: model,
                         session: LocalServerSession.make(protocolClasses: [StubURLProtocol.self]))
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await token in stream { text += token }
        return text
    }

    // MARK: Endpoint validation

    func testValidationAcceptsLoopbackAndNormalizes() throws {
        XCTAssertEqual(try LocalServerEndpoint.validate("http://localhost:1234/v1").absoluteString,
                       "http://localhost:1234/v1")
        XCTAssertEqual(try LocalServerEndpoint.validate("  http://127.0.0.1:8080  ").absoluteString,
                       "http://127.0.0.1:8080/v1")
        XCTAssertEqual(try LocalServerEndpoint.validate("http://localhost:8000/v1/").absoluteString,
                       "http://localhost:8000/v1")
        XCTAssertEqual(try LocalServerEndpoint.validate("http://[::1]:1234").host, "::1")
        XCTAssertEqual(try LocalServerEndpoint.validate("HTTP://LOCALHOST:1234").scheme, "http")
    }

    func testValidationRejectsNonLoopbackHosts() {
        for raw in ["http://192.168.1.20:1234/v1",
                    "http://example.com/v1",
                    "https://ollama.com/v1",            // allowlisted cloud host, still not local
                    "https://api.mistral.ai/v1",
                    "http://localhost.evil.com:1234/v1",
                    "http://127.0.0.1.evil.com/v1",
                    "http://0.0.0.0:1234/v1"] {
            XCTAssertThrowsError(try LocalServerEndpoint.validate(raw), raw) { error in
                guard case ProviderError.egressBlocked = error else {
                    return XCTFail("\(raw): expected egressBlocked, got \(error)")
                }
            }
        }
    }

    func testValidationRejectsMalformedAndRiskyShapes() {
        for raw in ["", "   ", "localhost:1234", "ftp://localhost/v1", "file:///etc/passwd",
                    "http://user:pw@localhost:1234/v1",
                    "http://localhost@evil.com/v1",
                    "http://localhost:1234/v1?key=1",
                    "http://localhost:1234/v1#frag",
                    "http://localhost:1234/admin",
                    "http://localhost:1234/v1/../x",
                    "http://localhost:0/v1",
                    "http://localhost:70000/v1",
                    "http://" + String(repeating: "a", count: 300)] {
            XCTAssertThrowsError(try LocalServerEndpoint.validate(raw), raw)
        }
    }

    // MARK: Request shape + egress

    func testRequestShapeHasNoCredentialsAndTargetsChatCompletions() throws {
        let client = OpenAIChatClient(baseURL: base, model: "qwen")
        let request = try client.buildRequest(ChatRequest(system: "sys", user: "usr",
                                                          maxTokens: 123, temperature: 0.5))
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 123)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] },
                       ["system", "user"])
    }

    func testClientRefusesNonLoopbackBeforeAnyIO() async {
        // Even if a bad URL got past validation, the transport check refuses.
        let client = OpenAIChatClient(baseURL: URL(string: "https://api.mistral.ai/v1")!, model: "m",
                                      session: LocalServerSession.make(protocolClasses: [StubURLProtocol.self]))
        do {
            _ = try await collect(client.stream(ChatRequest(system: "s", user: "u")))
            XCTFail("expected egressBlocked")
        } catch ProviderError.egressBlocked {
        } catch {
            XCTFail("expected egressBlocked, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "no request may reach the wire")
    }

    func testLocalServerNeverReportsEgress() {
        XCTAssertNil(OpenAIChatClient(baseURL: base, model: "m").egressHost,
                     "local-only: no egress event may be recorded for it")
    }

    // MARK: Streaming

    func testStreamsTokensAndStopsAtDone() async throws {
        StubURLProtocol.enqueue(status: 200, body: """
        data: {"choices":[{"delta":{"role":"assistant"}}]}
        data: {"choices":[{"delta":{"content":"Hel"}}]}

        : keep-alive comment
        data: {"choices":[{"delta":{"content":"lo"}}]}
        data: [DONE]
        data: {"choices":[{"delta":{"content":"never"}}]}
        """)
        let answer = try await collect(stubbedClient().stream(ChatRequest(system: "s", user: "u")))
        XCTAssertEqual(answer, "Hello")
    }

    func testStreamStripsThinkBlocks() async throws {
        StubURLProtocol.enqueue(status: 200, body: """
        data: {"choices":[{"delta":{"content":"<thi"}}]}
        data: {"choices":[{"delta":{"content":"nk>secret plan"}}]}
        data: {"choices":[{"delta":{"content":"</think>\\n\\nThe answer [1]."}}]}
        data: [DONE]
        """)
        let answer = try await collect(stubbedClient().stream(ChatRequest(system: "s", user: "u")))
        XCTAssertEqual(answer, "The answer [1].")
    }

    func testRedirectsAreRefusedAndNeverFollowed() async {
        let client = OpenAIChatClient(
            baseURL: base, model: "m",
            session: LocalServerSession.make(protocolClasses: [RedirectingURLProtocol.self]))
        do {
            _ = try await collect(client.stream(ChatRequest(system: "mail excerpts", user: "u")))
            XCTFail("a 3xx must surface as an error")
        } catch ProviderError.http(let status, _) {
            XCTAssertEqual(status, 307)
        } catch {
            XCTFail("expected http(307), got \(error)")
        }
        XCTAssertEqual(RedirectingURLProtocol.hostsRequested, ["localhost"],
                       "the redirect target must never be contacted")
    }

    func testContextOverflowMapsToActionableError() async {
        StubURLProtocol.enqueue(status: 400, body: #"{"error":{"type":"exceed_context_size_error","n_ctx":4096}}"#)
        do {
            _ = try await collect(stubbedClient().stream(ChatRequest(system: "s", user: "u")))
            XCTFail("expected localContextExceeded")
        } catch ProviderError.localContextExceeded {
        } catch {
            XCTFail("expected localContextExceeded, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "a 4xx must not be retried")
    }

    func testOtherHTTPErrorsStayHTTPErrors() async {
        StubURLProtocol.enqueue(status: 404, body: "model not loaded")
        do {
            _ = try await collect(stubbedClient().stream(ChatRequest(system: "s", user: "u")))
            XCTFail("expected http error")
        } catch ProviderError.http(let status, _) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("expected http, got \(error)")
        }
    }

    func testContextOverflowDetection() {
        XCTAssertTrue(ProviderError.isContextOverflow(status: 400, body: "exceed_context_size_error"))
        XCTAssertTrue(ProviderError.isContextOverflow(status: 400, body: "Context length exceeded"))
        XCTAssertTrue(ProviderError.isContextOverflow(status: 400, body: "context_length_exceeded"))
        XCTAssertFalse(ProviderError.isContextOverflow(status: 500, body: "context length"))
        XCTAssertFalse(ProviderError.isContextOverflow(status: 400, body: "invalid model"))
    }

    // MARK: Bounded parser

    private func byteStream(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            text.utf8.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func testParserHandlesCRLFAndFinalLineWithoutNewline() async throws {
        var out = ""
        try await OpenAIStreamParser.consume(byteStream(
            "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\r\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}")) { out += $0 }
        XCTAssertEqual(out, "ab")
    }

    func testParserFailsClosedOnEndlessLine() async {
        let limits = OpenAIStreamParser.Limits(maxLineBytes: 64, maxTotalBytes: 10_000)
        do {
            try await OpenAIStreamParser.consume(byteStream("data: " + String(repeating: "x", count: 500)),
                                                 limits: limits) { _ in }
            XCTFail("expected malformedResponse")
        } catch ProviderError.malformedResponse {
        } catch {
            XCTFail("expected malformedResponse, got \(error)")
        }
    }

    func testParserFailsClosedOnOversizedStream() async {
        let limits = OpenAIStreamParser.Limits(maxLineBytes: 1024, maxTotalBytes: 100)
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n"
        do {
            try await OpenAIStreamParser.consume(byteStream(String(repeating: line, count: 10)),
                                                 limits: limits) { _ in }
            XCTFail("expected malformedResponse")
        } catch ProviderError.malformedResponse {
        } catch {
            XCTFail("expected malformedResponse, got \(error)")
        }
    }

    // MARK: Provider wiring

    func testBadURLOrMissingModelSurfacesAsErrorNotFallback() async {
        let badURL = QueryService.localServerProvider(
            settings: QuerySettings(provider: .localServer,
                                    localServerURL: "http://192.168.1.9:1234/v1",
                                    localServerModel: "m"))
        do {
            _ = try await collect(badURL.stream(ChatRequest(system: "s", user: "u")))
            XCTFail("expected an error")
        } catch ProviderError.egressBlocked {
        } catch {
            XCTFail("expected egressBlocked, got \(error)")
        }

        let noModel = QueryService.localServerProvider(
            settings: QuerySettings(provider: .localServer, localServerModel: "  "))
        do {
            _ = try await collect(noModel.stream(ChatRequest(system: "s", user: "u")))
            XCTFail("expected an error")
        } catch ProviderError.invalidEndpoint {
        } catch {
            XCTFail("expected invalidEndpoint, got \(error)")
        }
    }

    func testValidSettingsBuildTheLocalClient() {
        let provider = QueryService.localServerProvider(
            settings: QuerySettings(provider: .localServer,
                                    localServerURL: "http://localhost:8080",
                                    localServerModel: "llama"))
        let client = provider as? OpenAIChatClient
        XCTAssertEqual(client?.baseURL.absoluteString, "http://localhost:8080/v1")
        XCTAssertEqual(client?.model, "llama")
    }

    func testProviderChoiceRawValueIsStable() {
        XCTAssertEqual(ProviderChoice.localServer.rawValue, "localServer")
        XCTAssertEqual(ProviderChoice(rawValue: "ollamaLocal"), .ollamaLocal, "old values still decode")
        XCTAssertNil(ProviderChoice(rawValue: "garbage"))
    }

    // MARK: Discovery

    func testModelListViaStubbedSession() async throws {
        StubURLProtocol.enqueue(status: 200, body: #"{"data":[{"id":"b"},{"id":"a"}]}"#)
        let models = try await LocalServerProbe.availableModels(
            base: base, session: LocalServerSession.make(protocolClasses: [StubURLProtocol.self]))
        XCTAssertEqual(models, ["a", "b"])
    }

    func testModelListRefusesNonLoopback() async {
        do {
            _ = try await LocalServerProbe.availableModels(
                base: URL(string: "https://api.mistral.ai/v1")!,
                session: LocalServerSession.make(protocolClasses: [StubURLProtocol.self]))
            XCTFail("expected egressBlocked")
        } catch ProviderError.egressBlocked {
        } catch {
            XCTFail("expected egressBlocked, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testContextLengthParsers() {
        XCTAssertEqual(LocalServerProbe.parseLlamaServerProps(
            Data(#"{"default_generation_settings":{"n_ctx":8192}}"#.utf8)), 8192)
        XCTAssertNil(LocalServerProbe.parseLlamaServerProps(Data(#"{"x":1}"#.utf8)))
        XCTAssertEqual(LocalServerProbe.parseLMStudioModels(
            Data(#"{"data":[{"loaded_context_length":16384},{"loaded_context_length":4096}]}"#.utf8)), 4096)
        XCTAssertEqual(LocalServerProbe.parseLMStudioModels(
            Data(#"{"data":[{"max_context_length":32768},{"max_context_length":131072}]}"#.utf8)), 32768)
        XCTAssertNil(LocalServerProbe.parseLMStudioModels(Data("not json".utf8)))
    }

    func testTokenAdvisorForLocalServer() {
        let unknown = TokenAdvisor.recommendLocalServer(serverContextTokens: nil)
        XCTAssertEqual(unknown.contextTokens, Defaults.contextTokenLimit)
        let known = TokenAdvisor.recommendLocalServer(serverContextTokens: 8192)
        XCTAssertEqual(known.contextTokens, 6144)   // 8192 - 800 - 1000 = 6392, snapped to 512
        let tiny = TokenAdvisor.recommendLocalServer(serverContextTokens: 2048)
        XCTAssertEqual(tiny.contextTokens, 1024, "clamped to the floor")
        XCTAssertEqual(TokenAdvisor.minimumServerContext(context: 4096, answer: 800), 5896)
    }
}

// MARK: - Think-tag filter

final class ThinkTagFilterTests: XCTestCase {

    private func run(_ chunks: [String]) -> String {
        var filter = ThinkTagFilter()
        return chunks.map { filter.process($0) }.joined() + filter.finish()
    }

    func testPlainTextPassesThrough() {
        XCTAssertEqual(run(["Hello ", "world"]), "Hello world")
    }

    func testRemovesBlockInOneChunk() {
        XCTAssertEqual(run(["<think>plan</think>\n\nAnswer"]), "Answer")
    }

    func testRemovesBlockSplitAcrossEveryBoundary() {
        let full = "A<think>hidden</think>\nB"
        for cut in 1..<full.count {
            let index = full.index(full.startIndex, offsetBy: cut)
            XCTAssertEqual(run([String(full[..<index]), String(full[index...])]), "AB",
                           "split at \(cut)")
        }
    }

    func testOneCharacterAtATime() {
        XCTAssertEqual(run("x<think>a</think> y".map(String.init)), "xy")
    }

    func testPartialTagThatNeverCompletesIsKept() {
        XCTAssertEqual(run(["a < b and <thi"]), "a < b and <thi")
    }

    func testUnclosedBlockIsDropped() {
        XCTAssertEqual(run(["Answer<think>never closed"]), "Answer")
    }

    func testBareClosingTagPassesThrough() {
        XCTAssertEqual(run(["no opener </think> here"]), "no opener </think> here")
    }

    func testMultipleBlocks() {
        XCTAssertEqual(run(["<think>1</think>A<think>2</think>B"]), "AB")
    }
}

// MARK: - Redirecting stub

/// Answers every request with a 307 to a remote host and records each host it
/// is asked for, so a test can prove the redirect target was never contacted.
final class RedirectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []

    static var hostsRequested: [String] {
        lock.lock(); defer { lock.unlock() }
        return hosts
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        hosts.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.hosts.append(url.host ?? "")
        Self.lock.unlock()

        let target = URL(string: "https://evil.example/steal")!
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": target.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        // A real server also sends the 3xx response itself. If the session
        // refuses the redirect (as it must) this becomes the final response;
        // if it wrongly followed, `evil.example` would show up in `hosts`.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
