import Foundation

/// Embeddings from a local OpenAI-compatible server (LM Studio, llama.cpp
/// `llama-server --embeddings`, vLLM, Jan, …) via `POST <base>/embeddings`.
///
/// Local-only by construction, like `OllamaEmbedder`: every request passes
/// `EgressPolicy.checkLoopbackOnly` (embeddings of the whole mailbox must
/// never leave the device), and the default session refuses redirects and
/// system proxies. The peer is another process on this machine, i.e. untrusted
/// input: the response is size-capped and strictly validated (count, indices,
/// one consistent dimension, finite numbers) before any vector reaches the
/// index, because a malformed vector stored once poisons search silently.
public struct OpenAIEmbedder: EmbeddingProvider {
    public var baseURL: URL
    public var model: String
    /// Total attempts per batch (transport errors and 5xx only).
    public var maxAttempts: Int
    public var timeout: TimeInterval
    var session: URLSession

    /// A batch of 16 chunks at 1024 dims is ~200 KB of JSON; this is ~80x that.
    static let maxResponseBytes = 16 * 1024 * 1024
    /// Widest embedding any current model produces is a few thousand.
    static let maxDimensions = 8192

    public init(baseURL: URL, model: String, maxAttempts: Int = 3, timeout: TimeInterval = 120) {
        self.init(baseURL: baseURL, model: model, maxAttempts: maxAttempts,
                  timeout: timeout, session: LocalServerSession.shared)
    }

    init(baseURL: URL, model: String, maxAttempts: Int = 3, timeout: TimeInterval = 120,
         session: URLSession) {
        self.baseURL = baseURL
        self.model = model
        self.maxAttempts = maxAttempts
        self.timeout = timeout
        self.session = session
    }

    func buildRequest(_ texts: [String]) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("embeddings")
        try EgressPolicy.checkLoopbackOnly(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts,
            "encoding_format": "float",
        ] as [String: Any])
        return request
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let request = try buildRequest(texts)
        // Same policy as OllamaEmbedder: retry transport errors and 5xx, never
        // 4xx or a malformed answer (deterministic — retrying repeats it).
        return try await Retry.run(attempts: maxAttempts, shouldRetry: Self.shouldRetry) {
            () async throws -> [[Float]] in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.malformedResponse("not an HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                let body = await OpenAIStreamParser.boundedBody(bytes)
                if ProviderError.isServerModelMissing(status: http.statusCode, body: body) {
                    throw ProviderError.serverModelMissing(model: model)
                }
                throw ProviderError.http(status: http.statusCode, body: body)
            }
            let data = try await Self.boundedData(bytes, limit: Self.maxResponseBytes)
            return try Self.parse(data, expected: texts.count)
        }
    }

    static let shouldRetry: @Sendable (Error) -> Bool = { error in
        switch error {
        case ProviderError.malformedResponse, ProviderError.serverModelMissing,
             ProviderError.egressBlocked:
            return false
        default:
            return OllamaEmbedder.isTransient(error)
        }
    }

    /// Reads at most `limit` bytes; more is a malformed (or hostile) response.
    static func boundedData<S: AsyncSequence>(_ bytes: S, limit: Int) async throws -> Data
    where S.Element == UInt8 {
        var collected = Data()
        for try await byte in bytes {
            guard collected.count < limit else {
                throw ProviderError.malformedResponse("embedding response exceeded \(limit) bytes")
            }
            collected.append(byte)
        }
        return collected
    }

    /// Decodes `{"data":[{"index":0,"embedding":[…]}, …]}` into vectors in
    /// input order. Fails closed on anything off: wrong count, duplicate or
    /// out-of-range index, an empty or over-wide vector, differing widths
    /// within one response, or a non-finite number.
    static func parse(_ data: Data, expected: Int) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw ProviderError.malformedResponse("no data array in /v1/embeddings")
        }
        guard list.count == expected else {
            throw ProviderError.malformedResponse(
                "expected \(expected) embeddings, got \(list.count)")
        }
        var slots = [[Float]?](repeating: nil, count: expected)
        for (position, item) in list.enumerated() {
            guard let raw = item["embedding"] as? [Any] else {
                throw ProviderError.malformedResponse("embedding \(position) is not a number array")
            }
            // Some servers omit `index`; array order is the contract then.
            let index = (item["index"] as? Int) ?? position
            guard slots.indices.contains(index), slots[index] == nil else {
                throw ProviderError.malformedResponse("bad or duplicate embedding index \(index)")
            }
            guard !raw.isEmpty, raw.count <= maxDimensions else {
                throw ProviderError.malformedResponse("embedding width \(raw.count) out of range")
            }
            var vector: [Float] = []
            vector.reserveCapacity(raw.count)
            for value in raw {
                guard let number = value as? NSNumber, number.floatValue.isFinite else {
                    throw ProviderError.malformedResponse("non-finite or non-numeric embedding value")
                }
                vector.append(number.floatValue)
            }
            slots[index] = vector
        }
        let vectors = slots.compactMap { $0 }
        guard vectors.count == expected, let width = vectors.first?.count,
              vectors.allSatisfy({ $0.count == width }) else {
            throw ProviderError.malformedResponse("embeddings differ in width")
        }
        return vectors
    }
}
