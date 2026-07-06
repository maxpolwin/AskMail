import XCTest
@testable import AskMailCore

struct StubChatProvider: ChatProvider {
    var name: String
    var tokens: [String] = []
    var error: Error? = nil
    /// Simulates a slow provider for race-timing tests.
    var delay: Duration = .zero
    /// Fires the instant `stream()` is called, so a test can prove whether
    /// (and when) the router actually started this provider.
    var onStart: (@Sendable () -> Void)? = nil
    /// Fires if this provider was mid-`delay` when the router cancelled it,
    /// proving cancellation really propagates and doesn't just get ignored.
    var onCancelled: (@Sendable () -> Void)? = nil

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        onStart?()
        return AsyncThrowingStream { continuation in
            let task = Task {
                if delay > .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        onCancelled?()
                        continuation.finish(throwing: error)
                        return
                    }
                }
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for token in tokens { continuation.yield(token) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Thread-safe boolean latch for verifying whether an async callback fired.
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = false
    func mark() { lock.lock(); value = true; lock.unlock() }
}

/// Thread-safe counter for verifying how many times an async callback fired.
private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
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

    // MARK: raceTimeout (primary silent past the deadline races local)

    // Primary answers well within raceTimeout: local must never even be
    // started, so the common (working-cloud) case pays no extra local
    // compute cost.
    func testLocalNeverStartsWhenPrimaryAnswersInTime() async throws {
        let localStarted = TestFlag()
        let primary = StubChatProvider(name: "cloud", tokens: ["fast", " answer"])
        let local = StubChatProvider(name: "ollama-local", tokens: ["local"],
                                     onStart: { localStarted.mark() })
        let router = ProviderRouter(primary: primary, fallback: local,
                                   raceTimeout: .milliseconds(200)) { _, _ in }

        var events: [ChatEvent] = []
        for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
            events.append(event)
        }

        XCTAssertEqual(events, [.token("fast"), .token(" answer"), .done])
        XCTAssertFalse(localStarted.value, "local must not be started when primary answers in time")
    }

    // Primary is silent past raceTimeout; once local is started too, primary
    // still answers first (just slowly). Primary's answer wins, no .fallback
    // event fires (the user still gets the configured provider's answer),
    // and local gets cancelled — proven via onCancelled, not just absent tokens.
    func testPrimaryWinsRaceAfterSlowStart() async throws {
        let localCancelled = TestFlag()
        let primary = StubChatProvider(name: "cloud", tokens: ["slow", " but first"],
                                       delay: .milliseconds(60))
        let local = StubChatProvider(name: "ollama-local", tokens: ["local"],
                                     delay: .milliseconds(300),
                                     onCancelled: { localCancelled.mark() })
        let router = ProviderRouter(primary: primary, fallback: local,
                                   raceTimeout: .milliseconds(20)) { _, _ in }

        var events: [ChatEvent] = []
        for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
            events.append(event)
        }

        XCTAssertEqual(events, [.token("slow"), .token(" but first"), .done])
        // Cancellation delivery isn't synchronous with stream completion;
        // give it a moment to actually propagate before checking the flag.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(localCancelled.value, "local must be cancelled once primary wins the race")
    }

    // Primary is silent past raceTimeout; local answers first. Local's
    // answer wins with a .fallback event, and primary gets cancelled —
    // its tokens must never reach the caller even though it was configured
    // to eventually produce some.
    func testLocalWinsRaceWhenPrimaryExceedsTimeout() async throws {
        let primaryCancelled = TestFlag()
        let primary = StubChatProvider(name: "cloud", tokens: ["never", " seen"],
                                       delay: .milliseconds(300),
                                       onCancelled: { primaryCancelled.mark() })
        let local = StubChatProvider(name: "ollama-local", tokens: ["local ", "answer"],
                                     delay: .milliseconds(60))
        let router = ProviderRouter(primary: primary, fallback: local,
                                   raceTimeout: .milliseconds(20)) { _, _ in }

        var events: [ChatEvent] = []
        for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .fallback(provider: "ollama-local", error: "no response from cloud within 0.02 seconds"),
            .token("local "), .token("answer"), .done,
        ])
        // Cancellation delivery isn't synchronous with stream completion;
        // give it a moment to actually propagate before checking the flag.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(primaryCancelled.value, "primary must be cancelled once local wins the race")
    }

    // Primary fails outright (not just slow) after raceTimeout, while local
    // is already racing alongside it: the router must use local's in-flight
    // result rather than starting a second, redundant local request.
    func testPrimaryFailsDuringRaceUsesAlreadyRacingLocal() async throws {
        let localStartCount = TestCounter()
        let primary = StubChatProvider(name: "cloud",
                                       error: ProviderError.http(status: 500, body: "late failure"),
                                       delay: .milliseconds(60))
        let local = StubChatProvider(name: "ollama-local", tokens: ["local ", "answer"],
                                     delay: .milliseconds(90),
                                     onStart: { localStartCount.increment() })
        let router = ProviderRouter(primary: primary, fallback: local,
                                   raceTimeout: .milliseconds(20)) { _, _ in }

        var events: [ChatEvent] = []
        for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .fallback(provider: "ollama-local", error: "HTTP 500: late failure"),
            .token("local "), .token("answer"), .done,
        ])
        XCTAssertEqual(localStartCount.value, 1, "local must only be started once, not restarted fresh")
    }

    // If in doubt, use the API response: when primary and local finish at
    // essentially the same instant, task-scheduling order alone must not
    // decide the winner — ties resolve to primary. Run several times since
    // a single pass could pass by luck even with a broken (unbiased) race.
    func testTiesResolveToPrimary() async throws {
        for _ in 0..<20 {
            let primary = StubChatProvider(name: "cloud", tokens: ["primary answer"],
                                           delay: .milliseconds(30))
            let local = StubChatProvider(name: "ollama-local", tokens: ["local answer"],
                                         delay: .milliseconds(30))
            let router = ProviderRouter(primary: primary, fallback: local,
                                       raceTimeout: .milliseconds(10)) { _, _ in }

            var events: [ChatEvent] = []
            for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
                events.append(event)
            }

            XCTAssertEqual(events, [.token("primary answer"), .done],
                          "a tie must resolve to primary, not local")
        }
    }

    // Both primary and local fail while actively racing (primary was silent
    // past raceTimeout, then both error out): must propagate a terminal
    // error rather than hang or silently swallow the failure.
    func testBothFailDuringRaceThrowsTerminally() async throws {
        let primary = StubChatProvider(name: "cloud",
                                       error: ProviderError.http(status: 500, body: "cloud down"),
                                       delay: .milliseconds(40))
        let local = StubChatProvider(name: "ollama-local",
                                     error: ProviderError.http(status: 503, body: "local down"),
                                     delay: .milliseconds(60))
        let router = ProviderRouter(primary: primary, fallback: local,
                                   raceTimeout: .milliseconds(10)) { _, _ in }

        var events: [ChatEvent] = []
        do {
            for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
                events.append(event)
            }
            XCTFail("expected the stream to throw when both providers fail")
        } catch {
            XCTAssertTrue("\(error)".contains("503"), "the last (local) error must surface: \(error)")
        }
        XCTAssertEqual(events, [.fallback(provider: "ollama-local", error: "HTTP 500: cloud down")],
                      "the primary failure must still be reported before the terminal local failure")
    }

    // Both primary and local fail immediately, before raceTimeout even
    // matters (the original pre-race fast-fail path): still terminal.
    func testBothFailFastThrowsTerminally() async {
        let primary = StubChatProvider(name: "cloud",
                                       error: ProviderError.http(status: 401, body: "bad key"))
        let local = StubChatProvider(name: "ollama-local",
                                     error: ProviderError.http(status: 500, body: "also down"))
        let router = ProviderRouter(primary: primary, fallback: local) { _, _ in }
        do {
            for try await _ in router.stream(ChatRequest(system: "s", user: "u")) {}
            XCTFail("expected the stream to throw when both providers fail")
        } catch {
            XCTAssertTrue("\(error)".contains("500"))
        }
    }

    // Local drops out (fails) while racing, before primary has answered:
    // primary is the only path left and must still be waited out and used,
    // rather than the router giving up just because local lost early.
    func testLocalFailsDuringRaceFallsThroughToPrimary() async throws {
        let primary = StubChatProvider(name: "cloud", tokens: ["primary ", "wins"],
                                       delay: .milliseconds(80))
        let local = StubChatProvider(name: "ollama-local",
                                     error: ProviderError.http(status: 503, body: "local unavailable"),
                                     delay: .milliseconds(30))
        let router = ProviderRouter(primary: primary, fallback: local,
                                   raceTimeout: .milliseconds(10)) { _, _ in }

        var events: [ChatEvent] = []
        for try await event in router.stream(ChatRequest(system: "s", user: "u")) {
            events.append(event)
        }

        // No .fallback event: the user still gets primary's own answer, and
        // local's failure while merely racing (not yet the active answer) is
        // not something the panel needs to warn about.
        XCTAssertEqual(events, [.token("primary "), .token("wins"), .done])
    }

    // Cancelling the outer stream mid-race (e.g. the query panel closes or
    // the question is resubmitted) must stop BOTH sides, not just the one
    // whose tokens the caller happened to already see. A plain `Task {}` is
    // not a structured child, so this specifically exercises CancelBag.
    func testCancellingStreamMidRaceCancelsBothSides() async throws {
        let primaryCancelled = TestFlag()
        let localCancelled = TestFlag()
        let primary = StubChatProvider(name: "cloud", tokens: ["never seen"],
                                       delay: .milliseconds(200),
                                       onCancelled: { primaryCancelled.mark() })
        let local = StubChatProvider(name: "ollama-local", tokens: ["never seen either"],
                                     delay: .milliseconds(200),
                                     onCancelled: { localCancelled.mark() })
        let router = ProviderRouter(primary: primary, fallback: local,
                                   raceTimeout: .milliseconds(10)) { _, _ in }

        let collectorTask = Task {
            for try await _ in router.stream(ChatRequest(system: "s", user: "u")) {}
        }
        // Give both sides time to actually start racing (past raceTimeout),
        // then cancel the consumer — mirroring how the app itself cancels a
        // resubmitted or abandoned query — without either side having answered.
        try await Task.sleep(for: .milliseconds(40))
        collectorTask.cancel()
        _ = try? await collectorTask.value

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(primaryCancelled.value, "primary must be cancelled when the stream is torn down mid-race")
        XCTAssertTrue(localCancelled.value, "local must be cancelled when the stream is torn down mid-race")
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

    // When Ollama isn't installed/running, the embed call throws a raw
    // URLError; AskViewModel relies on ProviderError.isConnectionFailure to
    // turn that into "Ollama isn't running" instead of showing it verbatim.
    func testRetrievalFailureIsClassifiableAsConnectionFailure() async throws {
        let store = try SQLiteStore.inMemory()
        let service = QueryService(store: store, embedder: UnreachableEmbedder(), log: { _, _ in })
        do {
            _ = try await service.retrieve(question: "anything", settings: QuerySettings())
            XCTFail("expected retrieval to throw when the embedder is unreachable")
        } catch {
            XCTAssertTrue(ProviderError.isConnectionFailure(error))
        }
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
