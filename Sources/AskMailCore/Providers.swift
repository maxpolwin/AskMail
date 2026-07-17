import Foundation

// MARK: - Protocols

public struct ChatRequest: Sendable {
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var temperature: Double
    /// Ollama context window (`num_ctx`) to request so the prompt isn't
    /// silently truncated to the model's default; 0 leaves the default. Ignored
    /// by providers that manage their own context (Mistral).
    public var contextWindow: Int

    public init(system: String, user: String,
                maxTokens: Int = Defaults.answerTokenLimit,
                temperature: Double = Defaults.temperature,
                contextWindow: Int = 0) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.contextWindow = contextWindow
    }
}

public protocol ChatProvider: Sendable {
    var name: String { get }
    /// Cloud host this provider's `stream(_:)` sends the prompt to over the
    /// network, or nil when it never leaves the device. This is both the
    /// H-10 allowlist target and the H-11 egress-transparency signal:
    /// `ProviderRouter` records + surfaces a `ChatEvent.egress` the instant
    /// a provider with a non-nil host starts streaming, regardless of which
    /// provider's answer is ultimately used (see `ProviderRouter.startPump`).
    var egressHost: String? { get }
    /// The exact model id sent alongside `egressHost`, for the egress log's
    /// audit record. Meaningless when `egressHost` is nil.
    var egressModel: String { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error>
}

public extension ChatProvider {
    var egressHost: String? { nil }
    var egressModel: String { "" }
}

public protocol EmbeddingProvider: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum ProviderError: Error, CustomStringConvertible {
    case http(status: Int, body: String)
    case malformedResponse(String)
    case missingAPIKey(service: String)
    /// A local Ollama model isn't pulled yet. Carries the model name so callers
    /// can show the exact `ollama pull <model>` remedy instead of a raw 404.
    case ollamaModelMissing(model: String)
    /// Hardening H-10: `host` isn't on `EgressPolicy`'s compiled-in
    /// allowlist. Thrown before any request is sent.
    case egressBlocked(host: String)

    /// Hardening H-13: cloud 4xx bodies often echo the submitted prompt
    /// (i.e. mail content, via the assembled prompt in QueryService), and
    /// both the rolling log and the panel's error message are built with
    /// `"\(error)"` string interpolation, which reads this property. The
    /// `.http` case therefore caps and single-lines its body here; the full,
    /// unredacted body still lives in the case's associated value for any
    /// caller that genuinely needs it (e.g. `isOllamaModelMissing`).
    public var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(Self.redacted(body))"
        case .malformedResponse(let detail):
            return "malformed provider response: \(detail)"
        case .missingAPIKey(let service):
            return "no API key in Keychain for service \(service)"
        case .ollamaModelMissing(let model):
            return "Ollama model \u{201C}\(model)\u{201D} isn\u{2019}t installed. "
                + "Download it in Settings \u{2192} Local engine, then try again."
        case .egressBlocked(let host):
            return "blocked outbound request to \u{201C}\(host)\u{201D}: not on the egress allowlist"
        }
    }

    /// Collapses newlines (so one log line stays one line) and caps at 300
    /// chars, appending a truncation marker when cut — bounded well under
    /// the 4096-char raw body `ensureOK` collects.
    private static func redacted(_ body: String) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let limit = 300
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "\u{2026} [truncated]"
    }

    /// Whether an error is Ollama's missing-model 404 — which retrying won't
    /// fix and which has an exact remedy, as opposed to any other client error.
    /// The body wording varies by endpoint and version (verified on 0.31.1):
    /// /api/embed says "model … not found, try pulling it first" while
    /// /api/chat says just "model '…' not found".
    public static func isOllamaModelMissing(status: Int, body: String) -> Bool {
        status == 404 && body.contains("not found")
    }

    /// Whether `error` means the Ollama daemon itself is unreachable (not
    /// installed, not running, or the connection dropped) as opposed to an
    /// application-level error like a missing model. `MailboxIngestor` uses
    /// this to abort a run early instead of logging thousands of identical
    /// failures; `AskViewModel` uses it to show "Ollama isn't running" rather
    /// than a raw `URLError` description.
    public static func isConnectionFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Retry

/// Small async retry helper with backoff. Used to keep transient failures
/// (network timeouts, a briefly-unavailable local Ollama, wake-from-sleep) from
/// failing a whole email during ingestion (FR-5 robustness).
public enum Retry {
    public static func run<T>(attempts: Int,
                              backoff: @Sendable (Int) -> UInt64 = { UInt64($0) * 500_000_000 },
                              shouldRetry: @Sendable (Error) -> Bool = { _ in true },
                              operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        let total = max(1, attempts)
        for attempt in 1...total {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard attempt < total, shouldRetry(error) else { throw error }
                try? await Task.sleep(nanoseconds: backoff(attempt))
            }
        }
        throw lastError!  // unreachable: the loop returns or throws
    }
}

// MARK: - Ollama (local and cloud)

/// Chat via the Ollama /api/chat NDJSON streaming API. With `apiKey` set it
/// targets Ollama Cloud; without, the local daemon.
public struct OllamaClient: ChatProvider {
    public var host: URL
    public var model: String
    public var apiKey: String?

    public var name: String { apiKey == nil ? "ollama-local" : "ollama-cloud" }
    /// Cloud egress only when an API key is configured — the local daemon
    /// (apiKey nil) never leaves the device.
    public var egressHost: String? { apiKey == nil ? nil : host.host }
    public var egressModel: String { model }

    public init(host: URL = Defaults.ollamaLocalHost,
                model: String = Defaults.localChatModel,
                apiKey: String? = nil) {
        self.host = host
        self.model = model
        self.apiKey = apiKey
    }

    /// Builds the `/api/chat` request, including the H-10 egress check.
    /// Not private, so tests can assert its shape (e.g. the timeout) without
    /// a real network round trip.
    func buildRequest(_ request: ChatRequest) throws -> URLRequest {
        let url = host.appendingPathComponent("api/chat")
        try EgressPolicy.check(url)
        var urlRequest = URLRequest(url: url, timeoutInterval: Defaults.chatRequestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var options: [String: Any] = [
            "temperature": request.temperature,
            "num_predict": request.maxTokens,
        ]
        // Size the context window to the prompt so Ollama doesn't
        // truncate it to the model's (smaller) default.
        if request.contextWindow > 0 {
            options["num_ctx"] = request.contextWindow
        }
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
            "options": options,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request)

                    // Retry only the connect-through-headers phase (attempts:
                    // 2): a cold model load, or a daemon reload triggered by
                    // a changed num_ctx, plus prompt evaluation, can blow
                    // past a single attempt's idle timeout before the first
                    // byte arrives. Safe because no tokens have been yielded
                    // yet; once the loop below starts consuming `bytes`,
                    // never retry again.
                    let bytes = try await Retry.run(attempts: 2, shouldRetry: OllamaEmbedder.isTransient) {
                        () async throws -> URLSession.AsyncBytes in
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        try await Self.ensureOK(response: response, bytes: bytes)
                        return bytes
                    }

                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let message = json["message"] as? [String: Any],
                           let content = message["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }
                        if json["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch ProviderError.http(let status, let body)
                            where apiKey == nil
                            && ProviderError.isOllamaModelMissing(status: status, body: body) {
                    // A missing *local* chat model has the same pull-it remedy as
                    // a missing embedding model; cloud 404s stay verbatim.
                    continuation.finish(throwing: ProviderError.ollamaModelMissing(model: model))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func ensureOK(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        var body = ""
        for try await line in bytes.lines {
            body += line
            if body.count > 4096 { break }  // full error body, bounded
        }
        throw ProviderError.http(status: http.statusCode, body: body)
    }
}

/// Embeddings via the local Ollama /api/embed endpoint. Local only, never
/// cloud: embeddings of the full mailbox must stay on-device (SECURITY.md).
public struct OllamaEmbedder: EmbeddingProvider {
    public var host: URL
    public var model: String
    /// Total attempts per batch before giving up on that email (FR-5 robustness).
    public var maxAttempts: Int
    /// Per-request timeout; generous because a large batch of chunks can take a
    /// while on first load, and the default 60 s truncates otherwise.
    public var timeout: TimeInterval

    public init(host: URL = Defaults.ollamaLocalHost,
                model: String = Defaults.embeddingModel,
                maxAttempts: Int = 3,
                timeout: TimeInterval = 120) {
        self.host = host
        self.model = model
        self.maxAttempts = maxAttempts
        self.timeout = timeout
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let url = host.appendingPathComponent("api/embed")
        // Stricter than the general H-10 allowlist: loopback only, even
        // though ollama.com would otherwise pass — mailbox embeddings must
        // never leave the device (SECURITY.md, struct doc comment above).
        try EgressPolicy.checkLoopbackOnly(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts,
            // Size the context to our chunk length; oversizing spikes memory
            // and can OOM the daemon (docs/defaults.md).
            "options": ["num_ctx": Defaults.embedNumCtx],
        ] as [String: Any])

        // Retry transport errors and 5xx (transient), but not 4xx (won't fix by
        // retrying — e.g. model not pulled), so a real misconfiguration fails fast.
        do {
            return try await Retry.run(attempts: maxAttempts, shouldRetry: Self.isTransient) {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw ProviderError.http(status: http.statusCode,
                                             body: String(data: data, encoding: .utf8) ?? "")
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = json["embeddings"] as? [[Any]] else {
                    throw ProviderError.malformedResponse("no embeddings array")
                }
                return raw.map { vector in
                    vector.compactMap { ($0 as? NSNumber)?.floatValue }
                }
            }
        } catch ProviderError.http(let status, let body)
                    where ProviderError.isOllamaModelMissing(status: status, body: body) {
            // Surface the "pull the model" remedy instead of a raw 404, so the
            // caller can abort the run / query with an actionable message.
            throw ProviderError.ollamaModelMissing(model: model)
        }
    }

    @Sendable
    static func isTransient(_ error: Error) -> Bool {
        if case ProviderError.http(let status, _) = error { return (500...599).contains(status) }
        // A cancelled request (panel closed, task torn down) must not burn a
        // retry attempt on a request that will only be cancelled again.
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true  // URLError timeouts / connection drops are worth retrying
    }
}

// MARK: - Mistral

/// Chat via the Mistral OpenAI-style SSE streaming API.
public struct MistralClient: ChatProvider {
    public var apiKey: String
    public var model: String
    public var endpoint: URL

    public var name: String { "mistral" }
    /// Mistral has no local variant — always a cloud egress.
    public var egressHost: String? { endpoint.host }
    public var egressModel: String { model }

    public init(apiKey: String,
                model: String = Defaults.mistralChatModel,
                endpoint: URL = Defaults.mistralChatEndpoint) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    /// Builds the chat-completions request, including the H-10 egress
    /// check. Not private, so tests can assert its shape without a real
    /// network round trip.
    func buildRequest(_ request: ChatRequest) throws -> URLRequest {
        try EgressPolicy.check(endpoint)
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: Defaults.chatRequestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
        ] as [String: Any])
        return urlRequest
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request)

                    // Same connect-phase-only retry as OllamaClient.stream
                    // (Task 1): safe pre-first-token, never once streaming
                    // has begun.
                    let bytes = try await Retry.run(attempts: 2, shouldRetry: OllamaEmbedder.isTransient) {
                        () async throws -> URLSession.AsyncBytes in
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        try await OllamaClient.ensureOK(response: response, bytes: bytes)
                        return bytes
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty else {
                            continue
                        }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension MistralClient {
    /// Model ids available to the account, for the Settings picker
    /// (`GET /v1/models`; requires the API key).
    public static func availableModels(apiKey: String,
                                       endpoint: URL = Defaults.mistralModelsEndpoint) async throws -> [String] {
        try EgressPolicy.check(endpoint)
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try OllamaControl.ensureOK(response: response, data: data)
        return try parseModels(data)
    }

    /// Pure decoder for the OpenAI-style `{"data":[{"id":…}]}` list. The list
    /// repeats models under alias ids, so dedupe; sorted for a stable picker.
    public static func parseModels(_ data: Data) throws -> [String] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw ProviderError.malformedResponse("no data array in /v1/models")
        }
        return Array(Set(list.compactMap { $0["id"] as? String })).sorted()
    }
}

// MARK: - Router with local fallback (FR-4)

/// Events surfaced to the panel while an answer streams.
public enum ChatEvent: Sendable, Equatable {
    case token(String)
    /// The answer is (or restarts) from the named fallback provider instead
    /// of the configured primary — either the primary failed outright, or it
    /// lost the raceTimeout race to local. The UI shows a non-blocking
    /// warning and clears any partial text. The full reason is already in
    /// the rolling log.
    case fallback(provider: String, error: String)
    /// Hardening H-11: yielded the instant a cloud provider's request is
    /// *initiated* — before any answer is chosen, since the raceTimeout race
    /// can send content to the cloud even when local ends up winning and
    /// being displayed. `host` matches the provider's `egressHost`; the
    /// corresponding `EgressEvent` has already been recorded in `EgressLog`
    /// by the time this is yielded (see `ProviderRouter.startPump`).
    case egress(host: String)
    case done
}

/// Pulls tokens from a `ChatProvider`'s stream one at a time through a
/// reference type, so a pull started inside a `Task` closure (for racing)
/// can be continued afterward from the router's main flow without Swift's
/// "capture of var in concurrently executing code" complaint that a
/// captured local `var` iterator would trigger.
private final class TokenPump: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator
    init(_ stream: AsyncThrowingStream<String, Error>) {
        iterator = stream.makeAsyncIterator()
    }
    /// The router never overlaps calls to this on the same pump — it always
    /// awaits one pull's result before issuing the next — which is what
    /// makes the `@unchecked Sendable` above safe.
    func next() async throws -> String? {
        try await iterator.next()
    }
}

/// Resolves a race between two tasks to whichever finishes first, without
/// touching the loser — it may still be legitimately useful afterward (e.g.
/// the primary, still in flight after losing the raceTimeout race).
private actor RaceGate {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Tracks in-flight racer tasks so the outer stream's teardown (the query is
/// cancelled or resubmitted while a race is active) can force-cancel
/// whichever are still running. A plain `Task { }` is not a structured child
/// of the task that created it, so it is NOT cancelled automatically just
/// because that task was — without this, a cancelled query would leave a
/// race's loser (or even both sides, if torn down before either answers)
/// running to completion in the background instead of actually stopping.
private final class CancelBag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellers: [() -> Void] = []
    private var alreadyCancelled = false

    func track(_ cancel: @escaping () -> Void) {
        lock.lock()
        guard !alreadyCancelled else { lock.unlock(); cancel(); return }
        cancellers.append(cancel)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        alreadyCancelled = true
        let pending = cancellers
        cancellers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }
}

/// True if `primary` finishes first, false if `other` does. Task scheduling
/// order for two things that complete at essentially the same instant is
/// not deterministic, so `other` waits out a brief grace window before
/// claiming victory — long enough for `primary` to register a genuine tie
/// (or a scheduling-noise near-tie) first. "If in doubt, use the API
/// response": ties, and anything within the grace window, resolve to
/// `primary`. A real, non-tied win for `other` only pays this fixed ~1ms
/// once, not a wait for `primary` itself to finish.
private func firstToComplete<A: Sendable, B: Sendable>(
    primary a: Task<A, Error>, other b: Task<B, Error>
) async -> Bool {
    let gate = RaceGate()
    return await withCheckedContinuation { continuation in
        Task {
            _ = try? await a.value
            if await gate.claim() { continuation.resume(returning: true) }
        }
        Task {
            _ = try? await b.value
            try? await Task.sleep(for: .milliseconds(1))
            if await gate.claim() { continuation.resume(returning: false) }
        }
    }
}

/// Routes to the selected provider and falls back to local Ollama on any
/// cloud failure, whether before the first token or mid-stream. If the
/// primary is still silent after `raceTimeout`, local is started alongside
/// it (not instead of it) and whichever answers first wins; the other is
/// cancelled outright rather than left running to waste resources on an
/// answer nobody will see.
public struct ProviderRouter: Sendable {
    public var primary: ChatProvider
    public var fallback: ChatProvider?
    public var raceTimeout: Duration
    public var log: @Sendable (String, RollingLog.LogLevel) -> Void

    public init(primary: ChatProvider, fallback: ChatProvider?,
                raceTimeout: Duration = Defaults.providerRaceTimeout,
                log: @escaping @Sendable (String, RollingLog.LogLevel) -> Void = { RollingLog.shared.log($0, level: $1) }) {
        self.primary = primary
        self.fallback = fallback
        self.raceTimeout = raceTimeout
        self.log = log
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let cancelBag = CancelBag()
            let task = Task { await run(request, continuation: continuation, cancelBag: cancelBag) }
            continuation.onTermination = { _ in
                task.cancel()
                cancelBag.cancelAll()
            }
        }
    }

    private enum Outcome {
        case token(String)
        case empty
        case failed(Error)
    }

    private func classify(_ task: Task<String?, Error>) async -> Outcome {
        do {
            if let token = try await task.value { return .token(token) }
            return .empty
        } catch {
            return .failed(error)
        }
    }

    /// Starts `provider`'s stream, first recording + surfacing the H-11
    /// egress signal if `provider.egressHost` is non-nil. Every call site
    /// that starts a provider stream goes through here, deliberately: the
    /// record/event must fire at the moment the stream *starts*, not when
    /// its answer is chosen — the raceTimeout race can send content to a
    /// cloud provider that later loses the race to local and is never
    /// displayed, but the send already happened.
    private func startPump(_ provider: ChatProvider, request: ChatRequest,
                           continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) -> TokenPump {
        if let host = provider.egressHost {
            EgressLog.shared.record(EgressEvent(date: Date(), host: host, model: provider.egressModel,
                                                promptChars: request.system.count + request.user.count))
            continuation.yield(.egress(host: host))
        }
        return TokenPump(provider.stream(request))
    }

    private func run(_ request: ChatRequest,
                     continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
                     cancelBag: CancelBag) async {
        log("provider=\(primary.name) start maxTokens=\(request.maxTokens) temperature=\(request.temperature) contextWindow=\(request.contextWindow)", .debug)

        guard let fallback, fallback.name != primary.name else {
            let pump = startPump(primary, request: request, continuation: continuation)
            await drainRemaining(pump, provider: primary, request: request,
                                isFallback: false, continuation: continuation)
            return
        }

        let primaryPump = startPump(primary, request: request, continuation: continuation)
        let primaryTask = Task<String?, Error> { try await primaryPump.next() }
        cancelBag.track { primaryTask.cancel() }
        let sleeper = Task<Void, Error> { try await Task.sleep(for: raceTimeout) }
        cancelBag.track { sleeper.cancel() }

        guard await firstToComplete(primary: primaryTask, other: sleeper) else {
            // raceTimeout elapsed with primary still silent: start local
            // alongside it (primary keeps running) and use whichever answers
            // first, discarding the other.
            log("provider=\(primary.name) exceeded \(raceTimeout) response window; racing \(fallback.name) alongside it", .error)
            let localPump = startPump(fallback, request: request, continuation: continuation)
            let localTask = Task<String?, Error> { try await localPump.next() }
            cancelBag.track { localTask.cancel() }

            if await firstToComplete(primary: primaryTask, other: localTask) {
                await settlePrimary(await classify(primaryTask), pump: primaryPump, request: request,
                                    fallback: fallback, continuation: continuation,
                                    racingLocal: (localTask, localPump))
            } else {
                switch await classify(localTask) {
                case .token(let token):
                    primaryTask.cancel()
                    log("provider=\(fallback.name) answered before \(primary.name); using it, discarding \(primary.name)", .error)
                    continuation.yield(.fallback(provider: fallback.name,
                                                 error: "no response from \(primary.name) within \(raceTimeout)"))
                    continuation.yield(.token(token))
                    await drainRemaining(localPump, provider: fallback, request: request,
                                        isFallback: true, continuation: continuation)
                case .empty, .failed:
                    // Local came up empty-handed while primary was still
                    // pending; primary is the only path left, so wait it out.
                    await settlePrimary(await classify(primaryTask), pump: primaryPump, request: request,
                                       fallback: fallback, continuation: continuation, racingLocal: nil)
                }
            }
            return
        }

        await settlePrimary(await classify(primaryTask), pump: primaryPump, request: request,
                            fallback: fallback, continuation: continuation, racingLocal: nil)
    }

    /// Handles whatever the primary ultimately did, whether it answered
    /// inside `raceTimeout` or (slowly) won the race against local anyway.
    private func settlePrimary(
        _ outcome: Outcome,
        pump: TokenPump,
        request: ChatRequest,
        fallback: ChatProvider,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
        racingLocal: (task: Task<String?, Error>, pump: TokenPump)?
    ) async {
        switch outcome {
        case .token(let token):
            racingLocal?.task.cancel()
            continuation.yield(.token(token))
            await drainRemaining(pump, provider: primary, request: request,
                                isFallback: false, continuation: continuation)
        case .empty:
            racingLocal?.task.cancel()
            log("provider=\(primary.name) done", .debug)
            continuation.yield(.done)
            continuation.finish()
        case .failed(let error):
            log("provider=\(primary.name) FAILED, falling back to \(fallback.name). error=\(error)", .error)
            continuation.yield(.fallback(provider: fallback.name, error: String(describing: error)))
            if let racingLocal {
                // Local is already in flight from the race; use its result
                // directly rather than starting a second, redundant request.
                switch await classify(racingLocal.task) {
                case .token(let token):
                    continuation.yield(.token(token))
                    await drainRemaining(racingLocal.pump, provider: fallback, request: request,
                                        isFallback: true, continuation: continuation)
                case .empty:
                    continuation.yield(.done)
                    continuation.finish()
                case .failed(let localError):
                    log("provider stream failed terminally: \(localError)", .error)
                    continuation.finish(throwing: localError)
                }
            } else {
                let freshPump = startPump(fallback, request: request, continuation: continuation)
                await drainRemaining(freshPump, provider: fallback, request: request,
                                    isFallback: true, continuation: continuation)
            }
        }
    }

    /// Streams whatever `pump` has left; a mid-stream primary failure
    /// restarts fresh on the fallback (matching the pre-race behavior), a
    /// mid-stream fallback failure is terminal (no further fallback exists).
    private func drainRemaining(
        _ pump: TokenPump,
        provider: ChatProvider,
        request: ChatRequest,
        isFallback: Bool,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        do {
            while let token = try await pump.next() {
                continuation.yield(.token(token))
            }
            log("provider=\(provider.name) done\(isFallback ? " (fallback)" : "")", isFallback ? .info : .debug)
            continuation.yield(.done)
            continuation.finish()
        } catch {
            guard !isFallback, let fallback, fallback.name != primary.name else {
                log("provider stream failed terminally: \(error)", .error)
                continuation.finish(throwing: error)
                return
            }
            log("provider=\(provider.name) FAILED, falling back to \(fallback.name). error=\(error)", .error)
            continuation.yield(.fallback(provider: fallback.name, error: String(describing: error)))
            let freshPump = startPump(fallback, request: request, continuation: continuation)
            await drainRemaining(freshPump, provider: fallback, request: request,
                                isFallback: true, continuation: continuation)
        }
    }
}
