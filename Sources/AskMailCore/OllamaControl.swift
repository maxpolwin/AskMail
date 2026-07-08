import Foundation

// MARK: - Ollama runtime control (health, installed models, in-app pulls)

/// A model reported by `GET /api/tags` — the source of truth for what's
/// installed locally. `capabilities`/`embeddingLength` are present on recent
/// Ollama versions (verified on 0.31.1) and optional in the decoder so an
/// older daemon still lists its models.
public struct InstalledModel: Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64
    /// e.g. ["embedding"] vs ["completion", "tools"]; empty when the daemon
    /// doesn't report capabilities.
    public let capabilities: [String]
    public let embeddingLength: Int?

    public init(name: String, sizeBytes: Int64,
                capabilities: [String] = [], embeddingLength: Int? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.capabilities = capabilities
        self.embeddingLength = embeddingLength
    }
}

/// Details for one model from `POST /api/show`, reduced to what AskMail needs:
/// the embedding dimension (for the Phase-3 index stamp) and whether the model
/// embeds or chats.
public struct OllamaModelInfo: Sendable, Equatable {
    public let capabilities: [String]
    public let embeddingLength: Int?

    public init(capabilities: [String] = [], embeddingLength: Int? = nil) {
        self.capabilities = capabilities
        self.embeddingLength = embeddingLength
    }
}

/// One NDJSON line of `POST /api/pull` progress. `completed`/`total` are only
/// present while a layer downloads; `fraction` is nil otherwise.
public struct PullProgress: Sendable, Equatable {
    public let status: String
    public let completed: Int64?
    public let total: Int64?

    public init(status: String, completed: Int64? = nil, total: Int64? = nil) {
        self.status = status
        self.completed = completed
        self.total = total
    }

    public var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    public var isSuccess: Bool { status == "success" }
}

/// Everything the app needs from the local Ollama daemon besides chat/embed:
/// health, the installed-model list, per-model details, and pulls. A protocol
/// so tests drive the status/download logic with a stub, never a socket.
public protocol OllamaControlling: Sendable {
    /// Whether the daemon answers `GET /api/version` (short timeout).
    func reachable() async -> Bool
    func installedModels() async throws -> [InstalledModel]
    func showModel(_ id: String) async throws -> OllamaModelInfo
    /// Streams `POST /api/pull` progress; finishes after the `success` line.
    func pull(_ id: String) -> AsyncThrowingStream<PullProgress, Error>
}

/// Concrete client over the local daemon. Model *management* (start, pull)
/// is local-only; the same /api/tags shape is also served by ollama.com, so
/// with the cloud host this client lists available cloud models — model
/// metadata only, never mail content (SECURITY.md).
public struct OllamaControl: OllamaControlling {
    public var host: URL
    /// Bearer token for the cloud host; nil for the local daemon.
    public var apiKey: String?

    public init(host: URL = Defaults.ollamaLocalHost, apiKey: String? = nil) {
        self.host = host
        self.apiKey = apiKey
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        guard let apiKey else { return request }
        var request = request
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func reachable() async -> Bool {
        let url = host.appendingPathComponent("api/version")
        // H-10: an egress-blocked host isn't "unreachable" in the retryable
        // sense, but reachable() has no throwing signature, so fold it into
        // the same false result callers already treat as "not up".
        guard (try? EgressPolicy.check(url)) != nil else { return false }
        let request = URLRequest(url: url, timeoutInterval: 2)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    public func installedModels() async throws -> [InstalledModel] {
        let url = host.appendingPathComponent("api/tags")
        try EgressPolicy.check(url)
        let request = authorized(URLRequest(url: url, timeoutInterval: 5))
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.ensureOK(response: response, data: data)
        return try Self.parseTags(data)
    }

    public func showModel(_ id: String) async throws -> OllamaModelInfo {
        let url = host.appendingPathComponent("api/show")
        try EgressPolicy.check(url)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": id])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.ensureOK(response: response, data: data)
        return try Self.parseShow(data)
    }

    public func pull(_ id: String) -> AsyncThrowingStream<PullProgress, Error> {
        let host = host
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = host.appendingPathComponent("api/pull")
                    try EgressPolicy.check(url)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // A multi-GB pull can take a long time between bytes on a
                    // slow connection; don't let the default 60 s cut it off.
                    request.timeoutInterval = 3600
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": id,
                        "stream": true,
                    ] as [String: Any])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await OllamaClient.ensureOK(response: response, bytes: bytes)

                    for try await line in bytes.lines {
                        guard let progress = try Self.parsePullLine(line) else { continue }
                        continuation.yield(progress)
                        if progress.isSuccess { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func ensureOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200...299).contains(http.statusCode) else { return }
        throw ProviderError.http(status: http.statusCode,
                                 body: String(data: data.prefix(4096), encoding: .utf8) ?? "")
    }

    // MARK: Pure decoders (unit-tested without a socket)

    /// `GET /api/tags` → installed models. Tolerates older daemons that omit
    /// `capabilities` / `details.embedding_length`.
    public static func parseTags(_ data: Data) throws -> [InstalledModel] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw ProviderError.malformedResponse("no models array in /api/tags")
        }
        return models.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let details = entry["details"] as? [String: Any]
            return InstalledModel(
                name: name,
                sizeBytes: (entry["size"] as? NSNumber)?.int64Value ?? 0,
                capabilities: entry["capabilities"] as? [String] ?? [],
                embeddingLength: (details?["embedding_length"] as? NSNumber)?.intValue)
        }
    }

    /// `POST /api/show` → capabilities + embedding dimension. The dimension
    /// lives in `model_info` under an architecture-prefixed key
    /// (e.g. `nomic-bert.embedding_length`), so match by suffix.
    public static func parseShow(_ data: Data) throws -> OllamaModelInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("non-object /api/show response")
        }
        let modelInfo = json["model_info"] as? [String: Any] ?? [:]
        let embeddingLength = modelInfo
            .first { $0.key.hasSuffix(".embedding_length") }
            .flatMap { ($0.value as? NSNumber)?.intValue }
        return OllamaModelInfo(capabilities: json["capabilities"] as? [String] ?? [],
                               embeddingLength: embeddingLength)
    }

    /// One NDJSON line of `/api/pull` output, or nil for blank/non-JSON lines.
    /// A mid-stream `{"error": …}` line (e.g. unknown model) throws so the pull
    /// fails loudly instead of ending as a silent no-op.
    public static func parsePullLine(_ line: String) throws -> PullProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? String {
            throw ProviderError.malformedResponse("pull failed: \(error)")
        }
        guard let status = json["status"] as? String else { return nil }
        return PullProgress(status: status,
                            completed: (json["completed"] as? NSNumber)?.int64Value,
                            total: (json["total"] as? NSNumber)?.int64Value)
    }
}

// MARK: - Runtime status

/// Health of the local Ollama runtime, from the app's point of view: what the
/// Settings engine section shows and which one-click fix applies.
public enum OllamaStatus: Sendable, Equatable {
    /// No daemon answering and no known install location — offer the download page.
    case notInstalled
    /// Installed but the daemon isn't answering — offer "Start Ollama".
    case stopped
    /// Daemon up but the required embedding model isn't pulled — offer the download.
    case runningModelMissing(model: String)
    case ready(modelCount: Int)

    /// Pure derivation so the table is unit-testable: (reachable, binary
    /// present, installed models) → status.
    public static func derive(reachable: Bool,
                              binaryPresent: Bool,
                              installed: [InstalledModel],
                              requiredEmbeddingModel: String = Defaults.embeddingModel) -> OllamaStatus {
        guard reachable else { return binaryPresent ? .stopped : .notInstalled }
        guard installed.contains(where: { modelName($0.name, matches: requiredEmbeddingModel) }) else {
            return .runningModelMissing(model: requiredEmbeddingModel)
        }
        return .ready(modelCount: installed.count)
    }

    /// `/api/tags` reports fully-tagged names ("nomic-embed-text:latest");
    /// AskMail configures untagged ones. An untagged reference means ":latest",
    /// matching Ollama's own resolution.
    public static func modelName(_ installed: String, matches wanted: String) -> Bool {
        let normalizedWanted = wanted.contains(":") ? wanted : wanted + ":latest"
        let normalizedInstalled = installed.contains(":") ? installed : installed + ":latest"
        return normalizedInstalled == normalizedWanted
    }
}

/// Composes daemon reachability + the installed-model list into one snapshot.
/// The network side comes through the `OllamaControlling` protocol so tests
/// stub it; the filesystem side is a plain bool computed by the caller. The
/// installed list rides along because the model pickers need it and it comes
/// from the same `/api/tags` call the status does.
public enum OllamaStatusReporter {
    public struct Snapshot: Sendable, Equatable {
        public let status: OllamaStatus
        public let installedModels: [InstalledModel]
    }

    public static func snapshot(control: some OllamaControlling,
                                binaryPresent: Bool,
                                requiredEmbeddingModel: String = Defaults.embeddingModel) async -> Snapshot {
        guard await control.reachable() else {
            return Snapshot(status: binaryPresent ? .stopped : .notInstalled,
                            installedModels: [])
        }
        // Reachable but /api/tags failing is transient (daemon restarting);
        // treat it as no models so the UI shows the actionable download state
        // rather than pretending readiness.
        let installed = (try? await control.installedModels()) ?? []
        return Snapshot(status: OllamaStatus.derive(reachable: true,
                                                    binaryPresent: binaryPresent,
                                                    installed: installed,
                                                    requiredEmbeddingModel: requiredEmbeddingModel),
                        installedModels: installed)
    }
}

/// Where an Ollama install shows up on disk — used to tell "not installed"
/// from "installed but stopped", and to find something to launch.
public enum OllamaInstallLocator {
    /// Candidate install locations, checked in launch-preference order:
    /// the app bundle (has its own menu-bar lifecycle), then Homebrew/manual
    /// CLI installs, then the per-user data dir a previous run leaves behind.
    public static var candidatePaths: [String] {
        [
            "/Applications/Ollama.app",
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            NSString(string: "~/.ollama").expandingTildeInPath,
        ]
    }

    /// Injectable existence check so the derivation table is testable.
    public static func binaryPresent(exists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) -> Bool {
        candidatePaths.contains(where: exists)
    }

    /// The app bundle to launch, if installed.
    public static func appURL(exists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) -> URL? {
        let path = "/Applications/Ollama.app"
        return exists(path) ? URL(fileURLWithPath: path) : nil
    }

    /// The CLI to `serve` with, if the app bundle isn't available.
    public static func cliURL(exists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) -> URL? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .first(where: exists)
            .map { URL(fileURLWithPath: $0) }
    }
}
