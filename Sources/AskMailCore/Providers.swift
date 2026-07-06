import Foundation

// MARK: - Protocols

public struct ChatRequest: Sendable {
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var temperature: Double

    public init(system: String, user: String,
                maxTokens: Int = Defaults.answerTokenLimit,
                temperature: Double = Defaults.temperature) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public protocol ChatProvider: Sendable {
    var name: String { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error>
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

    public var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .malformedResponse(let detail):
            return "malformed provider response: \(detail)"
        case .missingAPIKey(let service):
            return "no API key in Keychain for service \(service)"
        case .ollamaModelMissing(let model):
            return "Ollama model \u{201C}\(model)\u{201D} isn\u{2019}t installed. "
                + "Download it in Settings \u{2192} Local engine, then try again."
        }
    }

    /// Whether an error is Ollama's missing-model 404 — which retrying won't
    /// fix and which has an exact remedy, as opposed to any other client error.
    /// The body wording varies by endpoint and version (verified on 0.31.1):
    /// /api/embed says "model … not found, try pulling it first" while
    /// /api/chat says just "model '…' not found".
    public static func isOllamaModelMissing(status: Int, body: String) -> Bool {
        status == 404 && body.contains("not found")
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

    public init(host: URL = Defaults.ollamaLocalHost,
                model: String = Defaults.localChatModel,
                apiKey: String? = nil) {
        self.host = host
        self.model = model
        self.apiKey = apiKey
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: host.appendingPathComponent("api/chat"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey {
                        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": request.system],
                            ["role": "user", "content": request.user],
                        ],
                        "options": [
                            "temperature": request.temperature,
                            "num_predict": request.maxTokens,
                        ],
                    ]
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    try await Self.ensureOK(response: response, bytes: bytes)

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
        var request = URLRequest(url: host.appendingPathComponent("api/embed"),
                                 timeoutInterval: timeout)
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

    public init(apiKey: String,
                model: String = Defaults.mistralChatModel,
                endpoint: URL = URL(string: "https://api.mistral.ai/v1/chat/completions")!) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: endpoint)
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

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    try await OllamaClient.ensureOK(response: response, bytes: bytes)

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
                                       endpoint: URL = URL(string: "https://api.mistral.ai/v1/models")!) async throws -> [String] {
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
    /// The primary (cloud) provider failed; answer restarts from the named
    /// fallback provider. The UI shows a non-blocking warning and clears any
    /// partial text. The full error body is already in the rolling log.
    case fallback(provider: String, error: String)
    case done
}

/// Routes to the selected provider and falls back to local Ollama on any
/// cloud failure, whether before the first token or mid-stream.
public struct ProviderRouter: Sendable {
    public var primary: ChatProvider
    public var fallback: ChatProvider?
    public var log: @Sendable (String, RollingLog.LogLevel) -> Void

    public init(primary: ChatProvider, fallback: ChatProvider?,
                log: @escaping @Sendable (String, RollingLog.LogLevel) -> Void = { RollingLog.shared.log($0, level: $1) }) {
        self.primary = primary
        self.fallback = fallback
        self.log = log
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        log("provider=\(primary.name) start", .debug)
                        for try await token in primary.stream(request) {
                            continuation.yield(.token(token))
                        }
                        log("provider=\(primary.name) done", .debug)
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    } catch {
                        guard let fallback, fallback.name != primary.name else { throw error }
                        // Full error body goes to the log; the UI gets a short warning.
                        log("provider=\(primary.name) FAILED, falling back to \(fallback.name). error=\(error)", .error)
                        continuation.yield(.fallback(provider: fallback.name,
                                                     error: String(describing: error)))
                        for try await token in fallback.stream(request) {
                            continuation.yield(.token(token))
                        }
                        log("provider=\(fallback.name) done (fallback)", .info)
                        continuation.yield(.done)
                        continuation.finish()
                    }
                } catch {
                    log("provider stream failed terminally: \(error)", .error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
