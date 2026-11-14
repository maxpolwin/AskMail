import Foundation

// MARK: - Bounded SSE parsing

/// Parses an OpenAI-style server-sent-event chat stream from raw bytes with
/// hard caps. The peer is another process on this machine, i.e. untrusted
/// input: an endless line with no newline (which `AsyncBytes.lines` would
/// buffer without bound) or an endless stream must fail closed, not exhaust
/// memory.
enum OpenAIStreamParser {
    struct Limits: Sendable {
        /// One SSE line. Real deltas are a few hundred bytes.
        var maxLineBytes = 64 * 1024
        /// Whole response. An answer is at most a few thousand tokens.
        var maxTotalBytes = 4 * 1024 * 1024
    }

    /// Calls `yield` with each non-empty content delta, in order, until
    /// `[DONE]` or end of stream. Lines that aren't `data:` events and
    /// payloads that don't decode are skipped, as with the Mistral client.
    static func consume<S: AsyncSequence>(_ bytes: S,
                                          limits: Limits = Limits(),
                                          yield: (String) -> Void) async throws
    where S.Element == UInt8 {
        var line: [UInt8] = []
        var total = 0
        for try await byte in bytes {
            total += 1
            guard total <= limits.maxTotalBytes else {
                throw ProviderError.malformedResponse("response exceeded \(limits.maxTotalBytes) bytes")
            }
            if byte == UInt8(ascii: "\n") {
                if try handle(line: line, yield: yield) { return }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < limits.maxLineBytes else {
                    throw ProviderError.malformedResponse("line exceeded \(limits.maxLineBytes) bytes")
                }
                line.append(byte)
            }
        }
        _ = try handle(line: line, yield: yield)   // final line without a newline
    }

    /// Returns true when the stream is finished (`[DONE]`).
    private static func handle(line rawLine: [UInt8], yield: (String) -> Void) throws -> Bool {
        var bytes = rawLine[...]
        if bytes.last == UInt8(ascii: "\r") { bytes = bytes.dropLast() }
        guard let text = String(bytes: bytes, encoding: .utf8), text.hasPrefix("data:") else {
            return false
        }
        let payload = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return true }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else {
            return false
        }
        yield(content)
        return false
    }

    /// Reads at most `limit` bytes of an error body.
    static func boundedBody<S: AsyncSequence>(_ bytes: S, limit: Int = 4096) async -> String
    where S.Element == UInt8 {
        var collected: [UInt8] = []
        do {
            for try await byte in bytes {
                collected.append(byte)
                if collected.count >= limit { break }
            }
        } catch {}
        return String(decoding: collected, as: UTF8.self)
    }
}

// MARK: - Chat client

/// Chat against a local OpenAI-compatible server (LM Studio, llama.cpp,
/// `mlx_lm.server`, vLLM, Jan, …) via `POST <base>/chat/completions`.
///
/// Local-only by construction: `egressHost` is nil (nothing leaves the
/// device, so no egress event), every request passes
/// `EgressPolicy.checkLoopbackOnly`, and the default session refuses
/// redirects and system proxies. Context size is the server's setting — the
/// OpenAI API has no `num_ctx` — so an overflow is mapped to an actionable
/// error instead of a raw 400.
public struct OpenAIChatClient: ChatProvider {
    public var baseURL: URL
    public var model: String
    var session: URLSession

    public var name: String { "local-server" }

    public init(baseURL: URL, model: String) {
        self.init(baseURL: baseURL, model: model, session: LocalServerSession.shared)
    }

    init(baseURL: URL, model: String, session: URLSession) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    func buildRequest(_ request: ChatRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("chat/completions")
        try EgressPolicy.checkLoopbackOnly(url)
        var urlRequest = URLRequest(url: url, timeoutInterval: Defaults.chatRequestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
                    // Connect-phase-only retry, as the other clients: safe
                    // before the first token, never once streaming started.
                    let bytes = try await Retry.run(attempts: 2, shouldRetry: Self.shouldRetry) {
                        () async throws -> URLSession.AsyncBytes in
                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        try await Self.ensureOK(response: response, bytes: bytes)
                        return bytes
                    }
                    var filter = ThinkTagFilter()
                    try await OpenAIStreamParser.consume(bytes) { delta in
                        let visible = filter.process(delta)
                        if !visible.isEmpty { continuation.yield(visible) }
                    }
                    let tail = filter.finish()
                    if !tail.isEmpty { continuation.yield(tail) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Transient failures only. A context overflow is deterministic (the same
    /// prompt overflows again), so retrying it just doubles the wait.
    static let shouldRetry: @Sendable (Error) -> Bool = { error in
        if case ProviderError.localContextExceeded = error { return false }
        return OllamaEmbedder.isTransient(error)
    }

    static func ensureOK(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse,
              !(200...299).contains(http.statusCode) else { return }
        let body = await OpenAIStreamParser.boundedBody(bytes)
        if ProviderError.isContextOverflow(status: http.statusCode, body: body) {
            throw ProviderError.localContextExceeded
        }
        throw ProviderError.http(status: http.statusCode, body: body)
    }
}
