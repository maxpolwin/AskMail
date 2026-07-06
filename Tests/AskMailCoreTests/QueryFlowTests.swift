import XCTest
@testable import AskMailCore

struct StubChatProvider: ChatProvider {
    var name: String
    var tokens: [String] = []
    var error: Error? = nil

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for token in tokens { continuation.yield(token) }
            continuation.finish()
        }
    }
}

final class ProviderRouterTests: XCTestCase {

    // FR-4: cloud failure falls back to local with a warning event; the
    // answer still arrives.
    func testFallbackOnPrimaryFailure() async throws {
        let failing = StubChatProvider(name: "ollama-cloud",
                                       error: ProviderError.http(status: 401, body: "invalid key"))
        let local = StubChatProvider(name: "ollama-local", tokens: ["local ", "answer"])
        var logged: [String] = []
        let logLock = NSLock()
        let router = ProviderRouter(primary: failing, fallback: local) { line, _ in
            logLock.lock(); logged.append(line); logLock.unlock()
        }

        var events: [ChatEvent] = []
        for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .fallback(provider: "ollama-local", error: "HTTP 401: invalid key"),
            .token("local "), .token("answer"), .done,
        ])
        XCTAssertTrue(logged.contains { $0.contains("401") && $0.contains("invalid key") },
                      "full error body must reach the log (FR-4)")
    }

    func testNoFallbackWhenPrimarySucceeds() async throws {
        let primary = StubChatProvider(name: "ollama-local", tokens: ["ok"])
        let router = ProviderRouter(primary: primary, fallback: nil) { _, _ in }
        var events: [ChatEvent] = []
        for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
            events.append(event)
        }
        XCTAssertEqual(events, [.token("ok"), .done])
    }

    func testLocalFailureWithoutFallbackThrows() async {
        let failing = StubChatProvider(name: "ollama-local",
                                       error: ProviderError.http(status: 500, body: "down"))
        let router = ProviderRouter(primary: failing, fallback: nil) { _, _ in }
        do {
            for try await _ in router.stream(ChatRequest(system: "s", user: "u")) {}
            XCTFail("expected the stream to throw")
        } catch {
            XCTAssertTrue("\(error)".contains("500"))
        }
    }
}

final class QueryServiceTests: XCTestCase {

    // Contract §7: empty retrieval returns the fixed no-match message and
    // never calls the LLM.
    func testEmptyRetrievalReturnsNoMatchMessage() async throws {
        let store = try SQLiteStore.inMemory()
        let service = QueryService(store: store, embedder: StubEmbedder(), log: { _, _ in })
        let result = try await service.ask("What is my bank account balance?",
                                           settings: QuerySettings())
        XCTAssertTrue(result.sourceMap.isEmpty)
        var text = ""
        for try await event in result.events {
            if case .token(let token) = event { text += token }
        }
        XCTAssertEqual(text, Defaults.noMatchMessage)
    }

    // FR-3: clearing the session must forget prior turns.
    func testClearSessionForgetsBuffer() async throws {
        let store = try SQLiteStore.inMemory()
        let pk = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "S",
                                         sender: "s", dateUnix: 1_770_291_000)
        let embedding = try await StubEmbedder().embed(["webinar on April 9"])[0]
        try store.replaceChunks(messagePk: pk,
                                chunks: [(.body, "webinar on April 9", embedding)])

        let service = QueryService(store: store, embedder: StubEmbedder(), log: { _, _ in })
        let assembler = PromptAssembler()

        // Retrieval works and the assembler sees an empty session after clear.
        let chunks = try await service.retrieve(question: "webinar",
                                                settings: QuerySettings())
        XCTAssertFalse(chunks.isEmpty)
        service.clearSession()
        let prompt = assembler.assemble(question: "webinar", chunks: chunks, session: [])
        XCTAssertFalse(prompt.user.contains("Earlier in this conversation:"))
    }

    // Reproduces the reported bug: a date-only question ("what emails did I
    // get on <date>?") has no topical content for vector/keyword search to
    // match against, so semantic ranking alone can bury the right email
    // outside the top-N. Retrieval must also consult the store directly by
    // date_unix once DateFilter resolves a range.
    func testDateOnlyQuestionSurfacesEmailOutsideSemanticTopN() async throws {
        let store = try SQLiteStore.inMemory()
        let embedder = StubEmbedder()

        // Decoys echo the question's wording and dominate the semantic
        // top-N, but sit outside the date range asked about.
        for i in 0..<40 {
            let pk = try store.upsertMessage(messageID: "decoy\(i)@x", account: "acc",
                                             subject: "S", sender: "s", dateUnix: 1)
            let text = "emails emails did get during on emails decoy number \(i)"
            let embedding = try await embedder.embed([text])[0]
            try store.replaceChunks(messagePk: pk, chunks: [(.body, text, embedding)])
        }

        // The true target: dated 2026-06-10, with unrelated vocabulary.
        let targetPk = try store.upsertMessage(messageID: "target@x", account: "acc",
                                               subject: "Dentist", sender: "clinic",
                                               dateUnix: 1_781_100_000)  // 2026-06-10
        let targetText = "Your dentist appointment is confirmed for tomorrow at 3pm."
        let targetEmbedding = try await embedder.embed([targetText])[0]
        try store.replaceChunks(messagePk: targetPk, chunks: [(.body, targetText, targetEmbedding)])

        let service = QueryService(store: store, embedder: embedder, log: { _, _ in })
        let chunks = try await service.retrieve(question: "what emails did i get during on 2026-06-10?",
                                                settings: QuerySettings())

        XCTAssertTrue(chunks.contains { $0.messageID == "target@x" },
                     "date-scoped retrieval must surface the target email even though it doesn't rank in the semantic top-N")
    }
}
