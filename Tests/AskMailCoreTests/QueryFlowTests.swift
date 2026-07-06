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

    // MARK: Per-candidate debug logging (retrieval final[...] / droppedByFloor)

    func testLoggingTagsSemanticOnlyCandidatesInRankOrder() async throws {
        let store = try SQLiteStore.inMemory()
        let embedder = StubEmbedder()

        let pk1 = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "Invoice",
                                          sender: "billing@x", dateUnix: 1)
        let text1 = "invoice payment due webinar pricing"
        try store.replaceChunks(messagePk: pk1, chunks: [(.body, text1, try await embedder.embed([text1])[0])])

        let pk2 = try store.upsertMessage(messageID: "b@x", account: "acc", subject: "Webinar",
                                          sender: "events@x", dateUnix: 2)
        let text2 = "webinar pricing"
        try store.replaceChunks(messagePk: pk2, chunks: [(.body, text2, try await embedder.embed([text2])[0])])

        var logged: [(line: String, level: RollingLog.LogLevel)] = []
        let lock = NSLock()
        let service = QueryService(store: store, embedder: embedder, log: { line, level in
            lock.lock(); logged.append((line, level)); lock.unlock()
        })
        _ = try await service.retrieve(question: "invoice payment due webinar pricing", settings: QuerySettings())

        let finalLines = logged.map(\.line).filter { $0.hasPrefix("retrieval final[") }
        XCTAssertEqual(finalLines.count, 2)
        XCTAssertTrue(finalLines[0].hasPrefix("retrieval final[1]"), finalLines[0])
        XCTAssertTrue(finalLines[0].contains("subject=\"Invoice\""), finalLines[0])
        XCTAssertTrue(finalLines[0].contains("via=semantic"), finalLines[0])
        XCTAssertTrue(finalLines[1].hasPrefix("retrieval final[2]"), finalLines[1])
        XCTAssertTrue(finalLines[1].contains("via=semantic"), finalLines[1])

        // Both candidates fit under the default topK=8, so nothing was
        // dropped: the summary line must stay at .debug, not escalate to
        // .error.
        let topKLine = logged.first { $0.line.hasPrefix("retrieval topK=") }
        XCTAssertEqual(topKLine?.line, "retrieval topK=8 candidates=2 kept=2 droppedByTopK=0")
        XCTAssertEqual(topKLine?.level, .debug)
    }

    func testLoggingTagsDirectDateOnlyCandidates() async throws {
        let store = try SQLiteStore.inMemory()
        let embedder = StubEmbedder()

        for i in 0..<40 {
            let pk = try store.upsertMessage(messageID: "decoy\(i)@x", account: "acc",
                                             subject: "S", sender: "s", dateUnix: 1)
            let text = "emails emails did get during on emails decoy number \(i)"
            try store.replaceChunks(messagePk: pk, chunks: [(.body, text, try await embedder.embed([text])[0])])
        }
        for i in 0..<3 {
            let pk = try store.upsertMessage(messageID: "target\(i)@x", account: "acc",
                                             subject: "Dentist\(i)", sender: "clinic\(i)@x",
                                             dateUnix: 1_781_100_000 + Int64(i) * 60)  // 2026-06-10
            let text = "your appointment number \(i) is confirmed"
            try store.replaceChunks(messagePk: pk, chunks: [(.body, text, try await embedder.embed([text])[0])])
        }

        var logged: [String] = []
        let lock = NSLock()
        let service = QueryService(store: store, embedder: embedder, log: { line, _ in
            lock.lock(); logged.append(line); lock.unlock()
        })
        _ = try await service.retrieve(question: "what emails did i get during on 2026-06-10?", settings: QuerySettings())

        let finalLines = logged.filter { $0.hasPrefix("retrieval final[") }
        XCTAssertEqual(finalLines.count, 3)
        XCTAssertTrue(finalLines.allSatisfy { $0.contains("via=date") })
        XCTAssertTrue(logged.contains { $0.contains("direct=3") && $0.contains("merged=3/") })
    }

    func testLoggingDroppedByFloorRollupWhenNothingSurvives() async throws {
        let store = try SQLiteStore.inMemory()
        let embedder = StubEmbedder()
        let pk = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "Invoice",
                                         sender: "billing@x", dateUnix: 1)
        let text = "invoice payment webinar pricing"
        try store.replaceChunks(messagePk: pk, chunks: [(.body, text, try await embedder.embed([text])[0])])

        var logged: [String] = []
        let lock = NSLock()
        let service = QueryService(store: store, embedder: embedder, log: { line, _ in
            lock.lock(); logged.append(line); lock.unlock()
        })
        var settings = QuerySettings()
        settings.relevanceFloor = 2.0  // above any possible RRF score, so everything is dropped
        let chunks = try await service.retrieve(question: "invoice payment webinar pricing", settings: settings)

        XCTAssertTrue(chunks.isEmpty)
        XCTAssertTrue(logged.contains { $0.hasPrefix("retrieval droppedByFloor=1 ") }, logged.joined(separator: "\n"))
        XCTAssertFalse(logged.contains { $0.hasPrefix("retrieval final[") })
    }

    // The finalTopK cap isn't user-facing, so it must be spottable in the log:
    // when there are more above-floor candidates than topK allows, the drop
    // count should show up explicitly rather than being inferred from
    // counting `retrieval final[...]` lines.
    func testLoggingReportsTopKLimitAndDrops() async throws {
        let store = try SQLiteStore.inMemory()
        let embedder = StubEmbedder()
        for i in 0..<5 {
            let pk = try store.upsertMessage(messageID: "m\(i)@x", account: "acc",
                                             subject: "Invoice \(i)", sender: "billing@x",
                                             dateUnix: Int64(i))
            let text = "invoice payment due webinar pricing"
            try store.replaceChunks(messagePk: pk, chunks: [(.body, text, try await embedder.embed([text])[0])])
        }

        var logged: [(line: String, level: RollingLog.LogLevel)] = []
        let lock = NSLock()
        let service = QueryService(store: store, embedder: embedder, log: { line, level in
            lock.lock(); logged.append((line, level)); lock.unlock()
        })
        var settings = QuerySettings()
        settings.topK = 3
        let chunks = try await service.retrieve(question: "invoice payment due webinar pricing", settings: settings)

        XCTAssertEqual(chunks.count, 3)
        let dump = logged.map { "[\($0.level.tag)] \($0.line)" }.joined(separator: "\n")

        // The summary escalates to .error precisely because something was
        // dropped — this is the part that must be visible without switching
        // log verbosity to Debug.
        let summary = logged.first { $0.line.hasPrefix("retrieval topK=") }
        XCTAssertEqual(summary?.line, "retrieval topK=3 candidates=5 kept=3 droppedByTopK=2", dump)
        XCTAssertEqual(summary?.level, .error, dump)

        // The two excluded emails' identities are the contextual follow-up
        // for analysis, kept at .debug since they're detail, not the alert.
        let dropLines = logged.filter { $0.line.hasPrefix("retrieval droppedByTopK ") }
        XCTAssertEqual(dropLines.count, 2, dump)
        XCTAssertTrue(dropLines.allSatisfy { $0.level == .debug }, dump)
        XCTAssertTrue(dropLines.allSatisfy { $0.line.contains("subject=\"Invoice") }, dump)
    }

    // The contextTokenLimit trim happens inside PromptAssembler, after
    // retrieval logging. Log it too, so a too-small budget is as visible as
    // a too-small topK, instead of only inferable by diffing chunk counts
    // between the retrieval log and the dumped prompt.user text.
    func testLoggingReportsContextTokenBudgetAndDrops() async throws {
        let store = try SQLiteStore.inMemory()
        let embedder = StubEmbedder()
        let bodies = ["alpha content ", "beta content ", "gamma content "]
        for (i, phrase) in bodies.enumerated() {
            let pk = try store.upsertMessage(messageID: "m\(i)@x", account: "acc",
                                             subject: "S\(i)", sender: "s\(i)@x", dateUnix: Int64(i))
            let body = String(repeating: phrase, count: 20)
            try store.replaceChunks(messagePk: pk, chunks: [(.body, body, try await embedder.embed([body])[0])])
        }

        var logged: [(line: String, level: RollingLog.LogLevel)] = []
        let lock = NSLock()
        let service = QueryService(store: store, embedder: embedder, log: { line, level in
            lock.lock(); logged.append((line, level)); lock.unlock()
        })
        var settings = QuerySettings()
        settings.contextTokenLimit = 60  // smaller than even one ~20-repetition chunk
        _ = try await service.ask("alpha content", settings: settings)
        let dump = logged.map { "[\($0.level.tag)] \($0.line)" }.joined(separator: "\n")

        // The summary escalates to .error precisely because the budget
        // actually cut chunks — visible without switching to Debug verbosity.
        let summary = logged.first { $0.line.hasPrefix("prompt contextTokenLimit=") }
        XCTAssertEqual(summary?.line, "prompt contextTokenLimit=60 chunksIn=3 chunksKept=1 droppedByBudget=2", dump)
        XCTAssertEqual(summary?.level, .error, dump)

        // The two trimmed emails' identities are the contextual follow-up
        // for analysis, kept at .debug since they're detail, not the alert.
        let dropLines = logged.filter { $0.line.hasPrefix("prompt droppedByBudget ") }
        XCTAssertEqual(dropLines.count, 2, dump)
        XCTAssertTrue(dropLines.allSatisfy { $0.level == .debug }, dump)
    }
}
