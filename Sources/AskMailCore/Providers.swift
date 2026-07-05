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

    public var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .malformedResponse(let detail):
            return "malformed provider response: \(detail)"
        case .missingAPIKey(let service):
            return "no API key in Keychain for service \(service)"
        }
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

    public init(host: URL = Defaults.ollamaLocalHost,
                model: String = Defaults.embeddingModel) {
        self.host = host
        self.model = model
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: host.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts,
            // Use the model's full context window (docs/defaults.md).
            "options": ["num_ctx": 8192],
        ] as [String: Any])

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
    public var log: @Sendable (String) -> Void

    public init(primary: ChatProvider, fallback: ChatProvider?,
                log: @escaping @Sendable (String) -> Void = { RollingLog.shared.log($0) }) {
        self.primary = primary
        self.fallback = fallback
        self.log = log
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        log("provider=\(primary.name) start")
                        for try await token in primary.stream(request) {
                            continuation.yield(.token(token))
                        }
                        log("provider=\(primary.name) done")
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    } catch {
                        guard let fallback, fallback.name != primary.name else { throw error }
                        // Full error body goes to the log; the UI gets a short warning.
                        log("provider=\(primary.name) FAILED, falling back to \(fallback.name). error=\(error)")
                        continuation.yield(.fallback(provider: fallback.name,
                                                     error: String(describing: error)))
                        for try await token in fallback.stream(request) {
                            continuation.yield(.token(token))
                        }
                        log("provider=\(fallback.name) done (fallback)")
                        continuation.yield(.done)
                        continuation.finish()
                    }
                } catch {
                    log("provider stream failed terminally: \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
