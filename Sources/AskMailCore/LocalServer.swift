import Foundation

// MARK: - Endpoint validation

/// The user-editable base URL of a local OpenAI-compatible server (LM Studio,
/// llama.cpp `llama-server`, `mlx_lm.server`, vLLM, Jan, …).
///
/// Because the host is user-configurable, it is validated, not trusted: only
/// loopback hosts pass (the same rule `EgressPolicy.checkLoopbackOnly`
/// enforces again at request time), so this provider can never be pointed at a
/// LAN or WAN machine. The allowlist itself is unchanged.
public enum LocalServerEndpoint {
    public static let defaultBase = "http://localhost:1234/v1"

    /// Returns the normalized base URL (`scheme://host[:port]/v1`) or throws
    /// `ProviderError.invalidEndpoint` / `.egressBlocked` with an actionable
    /// reason. Rejected: non-http(s) schemes, credentials in the URL, queries,
    /// fragments, any path other than empty or `/v1`, ports outside 1…65535,
    /// and every non-loopback host.
    public static func validate(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw ProviderError.invalidEndpoint(
                "Enter a URL like \(defaultBase).")
        }
        guard components.user == nil, components.password == nil else {
            throw ProviderError.invalidEndpoint("The URL must not contain a username or password.")
        }
        guard components.query == nil, components.fragment == nil else {
            throw ProviderError.invalidEndpoint("The URL must not contain a query or fragment.")
        }
        let path = components.path
        guard ["", "/", "/v1", "/v1/"].contains(path) else {
            throw ProviderError.invalidEndpoint("The URL path must be empty or /v1.")
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw ProviderError.invalidEndpoint("The port must be between 1 and 65535.")
        }
        // Loopback only: a model server on another machine would receive the
        // question and email excerpts, which this provider promises never to do.
        // URLComponents keeps the brackets of an IPv6 literal ("[::1]"); the
        // egress policy compares the bare address, as `URL.host` returns it.
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard EgressPolicy.isLoopback(bareHost) else {
            throw ProviderError.egressBlocked(host: host)
        }

        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host
        normalized.port = components.port
        normalized.path = "/v1"
        guard let url = normalized.url else {
            throw ProviderError.invalidEndpoint("Enter a URL like \(defaultBase).")
        }
        return url
    }
}

// MARK: - Redirect-refusing, proxy-free session

/// Refuses every redirect. A local process answering `307 → https://elsewhere`
/// would otherwise make URLSession replay the request — prompt, mail excerpts
/// and all — to a host that never passed `EgressPolicy`. The 3xx response is
/// delivered as the final response instead and surfaces as an ordinary error.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum LocalServerSession {
    /// Ephemeral (no cookies/cache/credential storage), no system proxy (so
    /// loopback traffic can't be routed through one), and no redirects.
    public static let shared: URLSession = make(protocolClasses: nil)

    /// Test seam: the same hardening with extra `URLProtocol`s installed (an
    /// ephemeral configuration ignores globally registered protocols).
    static func make(protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration,
                          delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
}

/// Stand-in provider for a configuration that can't produce a real one (bad
/// URL, no model chosen): `makeRouter` isn't throwing, so the error surfaces
/// at stream time with its actionable message — never silently falling back.
public struct FailingChatProvider: ChatProvider {
    public let name: String
    public let error: ProviderError

    public init(name: String = "local-server", error: ProviderError) {
        self.name = name
        self.error = error
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

// MARK: - Model list + discovery

public struct LocalServerInfo: Sendable, Equatable, Identifiable {
    public var id: String { baseURL.absoluteString }
    public let label: String
    public let baseURL: URL
    public let models: [String]
    /// Context length the server reports (loaded, else maximum), when it
    /// reports one. Best effort; nil is common.
    public let contextLength: Int?

    public init(label: String, baseURL: URL, models: [String], contextLength: Int?) {
        self.label = label
        self.baseURL = baseURL
        self.models = models
        self.contextLength = contextLength
    }
}

public enum LocalServerProbe {
    /// Well-known default ports. Probed only when the user clicks Detect.
    static let candidates: [(port: Int, label: String)] = [
        (1234, "LM Studio"),
        (8080, "llama.cpp / MLX"),
        (8000, "vLLM"),
    ]

    /// Model ids from `GET <base>/models`. Loopback-only (validated by the
    /// caller; re-checked here), 2 s timeout, redirects refused.
    public static func availableModels(base: URL,
                                       session: URLSession = LocalServerSession.shared,
                                       timeout: TimeInterval = 2) async throws -> [String] {
        let url = base.appendingPathComponent("models")
        try EgressPolicy.checkLoopbackOnly(url)
        let (data, response) = try await session.data(
            for: URLRequest(url: url, timeoutInterval: timeout))
        try OllamaControl.ensureOK(response: response, data: data)
        return try MistralClient.parseModels(data)
    }

    /// Probes the well-known ports concurrently and returns what answered.
    public static func detect(session: URLSession = LocalServerSession.shared) async -> [LocalServerInfo] {
        await withTaskGroup(of: LocalServerInfo?.self) { group in
            for candidate in candidates {
                group.addTask {
                    guard let base = try? LocalServerEndpoint.validate("http://localhost:\(candidate.port)/v1"),
                          let models = try? await availableModels(base: base, session: session),
                          !models.isEmpty else { return nil }
                    let context = await contextLength(base: base, session: session)
                    return LocalServerInfo(label: candidate.label, baseURL: base,
                                           models: models, contextLength: context)
                }
            }
            var found: [LocalServerInfo] = []
            for await info in group { if let info { found.append(info) } }
            return found.sorted { $0.baseURL.absoluteString < $1.baseURL.absoluteString }
        }
    }

    /// Best-effort context length. Tries llama-server's `/props` and LM
    /// Studio's `/api/v0/models`; anything unexpected yields nil.
    public static func contextLength(base: URL,
                                     session: URLSession = LocalServerSession.shared) async -> Int? {
        guard var root = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        for (path, parse) in [("/props", parseLlamaServerProps),
                              ("/api/v0/models", parseLMStudioModels)]
        as [(String, (Data) -> Int?)] {
            root.path = path
            guard let url = root.url, (try? EgressPolicy.checkLoopbackOnly(url)) != nil,
                  let (data, response) = try? await session.data(
                    for: URLRequest(url: url, timeoutInterval: 2)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = parse(data) else { continue }
            return value
        }
        return nil
    }

    /// llama-server `GET /props` → `default_generation_settings.n_ctx`.
    static func parseLlamaServerProps(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = json["default_generation_settings"] as? [String: Any],
              let nCtx = settings["n_ctx"] as? Int, nCtx > 0 else { return nil }
        return nCtx
    }

    /// LM Studio `GET /api/v0/models` → the smallest `loaded_context_length`
    /// among loaded models, else the smallest `max_context_length`.
    static func parseLMStudioModels(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return nil }
        let loaded = models.compactMap { $0["loaded_context_length"] as? Int }.filter { $0 > 0 }
        if let value = loaded.min() { return value }
        return models.compactMap { $0["max_context_length"] as? Int }.filter { $0 > 0 }.min()
    }
}
