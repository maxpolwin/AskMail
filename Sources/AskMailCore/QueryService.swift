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
    private let log: (String, RollingLog.LogLevel) -> Void
    private let lock = NSLock()
    private var session: [SessionTurn] = []

    public init(store: SQLiteStore,
                embedder: EmbeddingProvider,
                log: @escaping (String, RollingLog.LogLevel) -> Void = { RollingLog.shared.log($0, level: $1) }) {
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
            log("retrieval EMPTY question=\"\(question)\"", .info)
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

        // 4. Route and stream, buffering the answer into the session on completion.
        let router = makeRouter(settings: settings)
        let request = ChatRequest(system: prompt.system,
                                  user: prompt.user,
                                  maxTokens: settings.answerTokenLimit,
                                  temperature: settings.temperature)
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

        let vectorIDs = embedding.isEmpty ? [] : try store.vectorSearch(embedding, topN: Defaults.vectorTopN)
        let keywordIDs = try store.keywordSearch(question, topN: Defaults.keywordTopN)

        let fused = Fusion.reciprocalRankFusion([vectorIDs, keywordIDs])
        let aboveFloor = fused.filter { $0.score > settings.relevanceFloor }
        log("retrieval vector=\(vectorIDs.count) keyword=\(keywordIDs.count) fused=\(fused.count) aboveFloor=\(aboveFloor.count) top=\(aboveFloor.prefix(3).map { "\($0.id):\(String(format: "%.4f", $0.score))" }.joined(separator: ","))", .debug)

        var candidates = try store.chunks(ids: aboveFloor.map(\.id))

        // Date-scoped questions filter candidates to the mentioned range
        // (B6 step 5). If the filter empties the set, keep the unfiltered
        // candidates: a wrong-month answer with sources beats a false no-match.
        if let range = DateFilter.unixRange(question: question) {
            let scoped = candidates.filter { range.contains($0.dateUnix) }
            log("retrieval dateFilter=\(range) kept=\(scoped.count)/\(candidates.count)", .debug)
            if !scoped.isEmpty { candidates = scoped }
        }

        return Array(candidates.prefix(settings.topK))
    }

    // MARK: Provider wiring (FR-4)

    func makeRouter(settings: QuerySettings) -> ProviderRouter {
        let local = OllamaClient(host: settings.ollamaHost, model: settings.localModel)
        switch settings.provider {
        case .ollamaLocal:
            return ProviderRouter(primary: local, fallback: nil, log: logSendable)
        case .ollamaCloud:
            let key = Keychain.apiKey(service: Defaults.keychainServiceOllamaCloud) ?? ""
            let cloud = OllamaClient(host: Defaults.ollamaCloudHost,
                                     model: settings.cloudModel,
                                     apiKey: key)
            return ProviderRouter(primary: cloud, fallback: local, log: logSendable)
        case .mistral:
            let key = Keychain.apiKey(service: Defaults.keychainServiceMistral) ?? ""
            let mistral = MistralClient(apiKey: key, model: settings.mistralModel)
            return ProviderRouter(primary: mistral, fallback: local, log: logSendable)
        }
    }

    private var logSendable: @Sendable (String, RollingLog.LogLevel) -> Void {
        let log = self.log
        return { line, level in log(line, level) }
    }
}
