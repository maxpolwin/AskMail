import Foundation

public enum ProviderChoice: String, Sendable, CaseIterable, Codable {
    case ollamaLocal
    case ollamaCloud
    case mistral
}

/// Everything a single query needs from settings (FR-9: changes take effect
/// on the next query, so this is passed per call, never cached).
public struct QuerySettings: Sendable {
    public var provider: ProviderChoice
    public var systemPrompt: String
    public var contextTokenLimit: Int
    public var answerTokenLimit: Int
    public var temperature: Double
    public var topK: Int
    public var relevanceFloor: Double
    public var ollamaHost: URL
    public var localModel: String
    public var cloudModel: String
    public var mistralModel: String

    public init(provider: ProviderChoice = .ollamaLocal,
                systemPrompt: String = Defaults.defaultSystemPrompt,
                contextTokenLimit: Int = Defaults.contextTokenLimit,
                answerTokenLimit: Int = Defaults.answerTokenLimit,
                temperature: Double = Defaults.temperature,
                topK: Int = Defaults.finalTopK,
                relevanceFloor: Double = Defaults.relevanceFloor,
                ollamaHost: URL = Defaults.ollamaLocalHost,
                localModel: String = Defaults.localChatModel,
                cloudModel: String = Defaults.cloudChatModel,
                mistralModel: String = Defaults.mistralChatModel) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.contextTokenLimit = contextTokenLimit
        self.answerTokenLimit = answerTokenLimit
        self.temperature = temperature
        self.topK = topK
        self.relevanceFloor = relevanceFloor
        self.ollamaHost = ollamaHost
        self.localModel = localModel
        self.cloudModel = cloudModel
        self.mistralModel = mistralModel
    }
}

public struct QueryResult: Sendable {
    /// `N -> source email` for citation rendering; empty on the no-match path.
    public let sourceMap: [Int: SourceRef]
    public let events: AsyncThrowingStream<ChatEvent, Error>
}

/// Orchestrates one question: embed, hybrid search, RRF fusion, relevance
/// floor, prompt assembly per the contract, provider routing with local
/// fallback, and the ephemeral session buffer (B6/B8).
public final class QueryService: @unchecked Sendable {
    private let store: SQLiteStore
    private let embedder: EmbeddingProvider
    private let log: @Sendable (String, RollingLog.LogLevel) -> Void
    private let lock = NSLock()
    private var session: [SessionTurn] = []

    public init(store: SQLiteStore,
                embedder: EmbeddingProvider,
                log: @escaping @Sendable (String, RollingLog.LogLevel) -> Void = { RollingLog.shared.log($0, level: $1) }) {
        self.store = store
        self.embedder = embedder
        self.log = log
    }

    /// Clears the in-memory multi-turn buffer. Call when the panel closes
    /// (FR-3: a fresh session must not recall the prior question).
    public func clearSession() {
        lock.withLock { session.removeAll() }
    }

    public func ask(_ question: String, settings: QuerySettings) async throws -> QueryResult {
        // 1. Retrieve.
        let chunks = try await retrieve(question: question, settings: settings)

        // 2. Empty-retrieval case (contract §7): never call the LLM with an
        //    empty context.
        guard !chunks.isEmpty else {
            // Capped rather than verbatim: this is the only question/answer
            // content logged at a level shipped on by default (.info); the
            // full text stays reachable at .debug via the lines below.
            log("retrieval EMPTY question=\"\(Self.capped(question))\"", .info)
            let events = AsyncThrowingStream<ChatEvent, Error> { continuation in
                continuation.yield(.token(Defaults.noMatchMessage))
                continuation.yield(.done)
                continuation.finish()
            }
            return QueryResult(sourceMap: [:], events: events)
        }

        // 3. Assemble per the prompt contract.
        let assembler = PromptAssembler(systemPrompt: settings.systemPrompt,
                                        contextTokenLimit: settings.contextTokenLimit)
        let currentSession = lock.withLock { session }
        let prompt = assembler.assemble(question: question, chunks: chunks, session: currentSession)
        // A nonzero drop means contextTokenLimit is actually shaping the
        // answer, not just a configured ceiling — surface it at .error so it
        // reaches the log regardless of the user's chosen verbosity, the same
        // way the topK line does below.
        let droppedByBudget = chunks.count - prompt.chunksKept
        log("prompt contextTokenLimit=\(settings.contextTokenLimit) chunksIn=\(chunks.count) chunksKept=\(prompt.chunksKept) droppedByBudget=\(droppedByBudget)",
            droppedByBudget > 0 ? .error : .debug)
        // trimToBudget keeps a strict prefix of `chunks` (best-ranked first)
        // and drops the tail (contract §3), so the dropped set is exactly
        // the suffix beyond chunksKept. Detail kept at .debug: the .error
        // line above is the alert, this is the follow-up for "which emails".
        for chunk in chunks.suffix(droppedByBudget) {
            log("prompt droppedByBudget chunk=\(chunk.chunkID) subject=\"\(chunk.subject)\" from=\(chunk.sender) date=\(PromptAssembler.ymd(chunk.dateUnix)) score=\(String(format: "%.4f", chunk.score))", .debug)
        }
        log("prompt.system:\n\(prompt.system)", .debug)
        log("prompt.user:\n\(prompt.user)", .debug)

        // 4. Route and stream, buffering the answer into the session on completion.
        let router = makeRouter(settings: settings)
        // num_ctx must hold the context budget + the answer + the prompt
        // scaffold (system prompt, question, session recap); ~2k covers it.
        let request = ChatRequest(system: prompt.system,
                                  user: prompt.user,
                                  maxTokens: settings.answerTokenLimit,
                                  temperature: settings.temperature,
                                  contextWindow: settings.contextTokenLimit
                                      + settings.answerTokenLimit + 2048)
        let upstream = router.stream(request)

        let events = AsyncThrowingStream<ChatEvent, Error> { continuation in
            let task = Task { [weak self] in
                var answer = ""
                do {
                    for try await event in upstream {
                        if case .token(let token) = event { answer += token }
                        if case .fallback = event { answer = "" }  // restart from fallback
                        continuation.yield(event)
                    }
                    if let self, !answer.isEmpty {
                        self.log("llm answer:\n\(answer)", .debug)
                        self.lock.withLock {
                            self.session.append(SessionTurn(question: question, answer: answer))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return QueryResult(sourceMap: prompt.sourceMap, events: events)
    }

    // MARK: Retrieval (B6 steps 1-5)

    func retrieve(question: String, settings: QuerySettings) async throws -> [ContextChunk] {
        let embedding = try await embedder.embed([question]).first ?? []

        // Rollup only, not a per-item dump: enumerating every dropped chunk's
        // identity would require an extra store round trip for information
        // that's rarely needed, and would bloat RollingLog's bounded buffer.
        var candidates = try Retriever.hybridRetrieve(embedding: embedding, keywordQuery: question, store: store,
                                                       vectorTopN: Defaults.vectorTopN, keywordTopN: Defaults.keywordTopN,
                                                       relevanceFloor: settings.relevanceFloor, log: log)

        // Date-scoped questions filter candidates to the mentioned range
        // (B6 step 5). Semantic/keyword search alone can miss the answer
        // entirely when the question is date-only ("what did I get on
        // <date>") with no topical content to rank against, so a date match
        // also pulls candidates directly from the store by date_unix,
        // bypassing relevance ranking. If nothing at all falls in range,
        // keep the unfiltered candidates: a wrong-date answer with sources
        // beats a false no-match.
        var dateFilterActive = false
        var directOnlyIDs: Set<Int64> = []
        var semanticAndDateIDs: Set<Int64> = []
        if let range = DateFilter.unixRange(question: question) {
            dateFilterActive = true
            let scopedFromSemantic = candidates.filter { range.contains($0.dateUnix) }
            let direct = try store.chunks(dateRange: range, limit: settings.topK)
            let alreadyIncluded = Set(scopedFromSemantic.map(\.chunkID))
            let directOnly = direct.filter { !alreadyIncluded.contains($0.chunkID) }
            let merged = scopedFromSemantic + directOnly
            log("retrieval dateFilter=\(range) semanticMatch=\(scopedFromSemantic.count) direct=\(direct.count) merged=\(merged.count)/\(candidates.count)", .debug)
            if !merged.isEmpty {
                candidates = merged
                directOnlyIDs = Set(directOnly.map(\.chunkID))
                semanticAndDateIDs = alreadyIncluded
            }
        }

        // Per-candidate identity for post-hoc diagnosis: which emails
        // actually reached the LLM, why (semantic ranking, the direct date
        // lookup, or both), and their score — without this, reconstructing
        // "why was email X cited but not Y" from an exported log requires
        // manually joining chunk IDs against the database. Bounded by
        // settings.topK (a small user-controlled setting), so this cannot
        // become an unbounded dump the way logging every candidate would.
        let finalCandidates = Array(candidates.prefix(settings.topK))
        // A nonzero drop means topK is actually excluding relevant emails,
        // not just a configured ceiling — surface it at .error so it reaches
        // the log regardless of the user's chosen verbosity.
        let droppedByTopK = candidates.count - finalCandidates.count
        log("retrieval topK=\(settings.topK) candidates=\(candidates.count) kept=\(finalCandidates.count) droppedByTopK=\(droppedByTopK)",
            droppedByTopK > 0 ? .error : .debug)
        // Contextual detail on which emails topK actually excluded, at
        // .debug: the .error line above is the alert, this is the follow-up
        // for "which emails" (candidates is fused-rank order, so the tail
        // beyond topK is exactly the dropped, lowest-ranked set).
        for chunk in candidates.suffix(droppedByTopK) {
            log("retrieval droppedByTopK chunk=\(chunk.chunkID) subject=\"\(chunk.subject)\" from=\(chunk.sender) date=\(PromptAssembler.ymd(chunk.dateUnix)) score=\(String(format: "%.4f", chunk.score))", .debug)
        }
        for (index, chunk) in finalCandidates.enumerated() {
            let via: String
            if directOnlyIDs.contains(chunk.chunkID) {
                via = "date"
            } else if dateFilterActive && semanticAndDateIDs.contains(chunk.chunkID) {
                via = "semantic+date"
            } else {
                via = "semantic"
            }
            log("retrieval final[\(index + 1)] chunk=\(chunk.chunkID) subject=\"\(chunk.subject)\" from=\(chunk.sender) date=\(PromptAssembler.ymd(chunk.dateUnix)) score=\(String(format: "%.4f", chunk.score)) via=\(via)", .debug)
        }
        return finalCandidates
    }

    // MARK: Provider wiring (FR-4)

    func makeRouter(settings: QuerySettings) -> ProviderRouter {
        let local = OllamaClient(host: settings.ollamaHost, model: settings.localModel)
        switch settings.provider {
        case .ollamaLocal:
            return ProviderRouter(primary: local, fallback: nil, log: log)
        case .ollamaCloud:
            let key = Keychain.apiKey(service: Defaults.keychainServiceOllamaCloud) ?? ""
            let cloud = OllamaClient(host: Defaults.ollamaCloudHost,
                                     model: settings.cloudModel,
                                     apiKey: key)
            return ProviderRouter(primary: cloud, fallback: local, log: log)
        case .mistral:
            let key = Keychain.apiKey(service: Defaults.keychainServiceMistral) ?? ""
            let mistral = MistralClient(apiKey: key, model: settings.mistralModel)
            return ProviderRouter(primary: mistral, fallback: local, log: log)
        }
    }

    /// Caps text logged at a level shipped on by default, keeping the log
    /// useful for "did retrieval fire" diagnosis without retaining arbitrary
    /// user-typed content at a verbosity most users never raise.
    static func capped(_ text: String, limit: Int = 200) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\u{2026}" : text
    }
}
