import Foundation

/// Hardening H-10: a compiled-in egress allowlist, the single source of
/// truth for every outbound `URLSession` call in Providers.swift and
/// OllamaControl.swift. The Ollama host is user-configurable (Settings), so
/// without this a user pointing it at an arbitrary LAN/WAN address would
/// have AskMail silently talk to it; `check` refuses anything not on the
/// list before a single byte is sent. Adding a host here is a reviewable,
/// compiled-in event — never derived from user input or a config file.
public enum EgressPolicy {
    /// Loopback hostnames, always allowed — this is how the local Ollama
    /// daemon is reached regardless of which loopback form is configured.
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Exact cloud hosts AskMail is allowed to talk to (SECURITY.md).
    private static let cloudHosts: Set<String> = ["ollama.com", "api.mistral.ai"]

    public static func isLoopback(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }

    public static func isAllowedCloudHost(_ host: String) -> Bool {
        cloudHosts.contains(host.lowercased())
    }

    /// Throws `ProviderError.egressBlocked` unless `url`'s host is loopback
    /// or an allowlisted cloud host. Call this before any bytes are sent —
    /// every `URLSession` call site in Providers.swift / OllamaControl.swift
    /// goes through here (or `checkLoopbackOnly` below).
    public static func check(_ url: URL) throws {
        guard let host = url.host, isLoopback(host) || isAllowedCloudHost(host) else {
            throw ProviderError.egressBlocked(host: url.host ?? url.absoluteString)
        }
    }

    /// Stricter than `check`: loopback only, refusing even the otherwise-
    /// allowlisted cloud hosts. `OllamaEmbedder` uses this exclusively —
    /// embeddings of the mailbox must never leave the device (SECURITY.md,
    /// Providers.swift `OllamaEmbedder` doc comment).
    public static func checkLoopbackOnly(_ url: URL) throws {
        guard let host = url.host, isLoopback(host) else {
            throw ProviderError.egressBlocked(host: url.host ?? url.absoluteString)
        }
    }
}

// MARK: - Egress transparency (H-11)

/// One outbound send to a cloud provider: what left, when, to whom. Recorded
/// by `ProviderRouter` the instant a cloud provider's request is *initiated*
/// (Providers.swift `ProviderRouter.startPump`) — never when its answer is
/// chosen, since the provider race can send content to the cloud even when a
/// local answer ultimately wins and is displayed (docs/hardening.md H-11).
public struct EgressEvent: Sendable, Equatable {
    public let date: Date
    public let host: String
    public let model: String
    public let promptChars: Int

    public init(date: Date, host: String, model: String, promptChars: Int) {
        self.date = date
        self.host = host
        self.model = model
        self.promptChars = promptChars
    }
}

/// Thread-safe, in-memory-only ring buffer of the last `capacity` egress
/// events — never persisted to disk, mirroring `RollingLog`'s posture. The
/// App target renders `events()` (H-11's "auditable what left, when, to
/// whom" view); this type only records and holds them.
public final class EgressLog: @unchecked Sendable {
    public static let shared = EgressLog()

    private let lock = NSLock()
    private var buffer: [EgressEvent] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = capacity
    }

    public func record(_ event: EgressEvent) {
        lock.lock()
        buffer.append(event)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()
    }

    public func events() -> [EgressEvent] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}
