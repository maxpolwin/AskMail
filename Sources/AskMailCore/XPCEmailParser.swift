import Foundation

/// Production `EmailParsing` (hardening H-6): sends raw `.emlx` bytes to the
/// sandboxed parser XPC service (`Sources/AskMailParserXPC`, embedded at
/// `Contents/XPCServices/com.askmail.app.parser.xpc`) and gets back an
/// `IngestableEmail` with PDF text already extracted. No untrusted MIME,
/// HTML, or PDFKit parsing ever runs in this (FDA-holding) process.
///
/// A crash, hang, or exploit attempt in the child is contained there:
/// `NSXPCConnection` surfaces it to this client as a thrown Swift error —
/// it does not propagate into or take down the host app.
///
/// A class, not a struct: the `NSXPCConnection` is created lazily and reused
/// across files, so an ingest run pays connection setup once rather than per
/// message. A connection that times out, interrupts, or invalidates is
/// discarded and the next parse builds a fresh one. `@unchecked Sendable`:
/// the only mutable state is `connection`, guarded by `connectionLock`.
public final class XPCEmailParser: EmailParsing, @unchecked Sendable {
    /// Wall-clock budget for one file. A hung child (or an input crafted to
    /// spin the parser, belt-and-suspenders alongside the H-7/H-9 caps
    /// enforced inside the parser itself) fails that one file instead of
    /// stalling the whole ingestion run.
    private static let requestTimeout: Duration = .seconds(30)

    /// Hardening H-7: the same total-size cap `EmlxParser.parse(fileURL:)`
    /// enforces, applied here because THIS is the process holding Full Disk
    /// Access — an oversize file must be rejected from `FileManager`
    /// attributes before `Data(contentsOf:)` reads it into memory.
    /// Injectable so tests can exercise the cap without a 100 MB fixture.
    private let maxEmlxBytes: Int

    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?

    public init(maxEmlxBytes: Int = Defaults.maxEmlxBytes) {
        self.maxEmlxBytes = maxEmlxBytes
    }

    deinit {
        connection?.invalidate()
    }

    public func parse(fileURL: URL) async throws -> IngestableEmail {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard fileSize <= maxEmlxBytes else {
            throw EmlxParseError.malformed(
                "file \(fileURL.lastPathComponent) is \(fileSize) bytes, exceeds max \(maxEmlxBytes)")
        }

        let data = try Data(contentsOf: fileURL)
        // NSXPCConnection is documented thread-safe; the box just carries it
        // into the task-group closures past Sendable checking.
        let handle = ConnectionHandle(connection: currentConnection())

        do {
            return try await withThrowingTaskGroup(of: IngestableEmail.self) { group in
                group.addTask { try await Self.request(data: data, over: handle.connection) }
                group.addTask { [weak self] in
                    try await Task.sleep(for: Self.requestTimeout)
                    // Invalidation makes the in-flight proxy's error handler
                    // fire, unblocking `request`'s continuation instead of
                    // leaving it (and the child's mach port) hanging.
                    self?.discard(handle.connection)
                    throw ParserXPCError.timedOut
                }
                guard let result = try await group.next() else { throw ParserXPCError.timedOut }
                group.cancelAll()
                return result
            }
        } catch {
            // A remote parse error (malformed message) leaves the connection
            // healthy for the next file; a transport-level failure means it
            // must not be reused.
            if !(error is ParserXPCError) || Self.isTransportFailure(error) {
                discard(handle.connection)
            }
            throw error
        }
    }

    private struct ConnectionHandle: @unchecked Sendable {
        let connection: NSXPCConnection
    }

    /// The cached connection, or a fresh resumed one if none is alive.
    private func currentConnection() -> NSXPCConnection {
        connectionLock.lock(); defer { connectionLock.unlock() }
        if let connection { return connection }
        let created = NSXPCConnection(serviceName: ParserXPC.serviceName)
        created.remoteObjectInterface = NSXPCInterface(with: ParserXPCProtocol.self)
        // A crashed/killed child interrupts the connection; escalate to a
        // full invalidate so in-flight error handlers fire and the next
        // parse rebuilds from scratch instead of retrying a dead child.
        created.interruptionHandler = { [weak created] in created?.invalidate() }
        created.resume()
        connection = created
        return created
    }

    /// Drops (and invalidates) a connection that timed out or failed at the
    /// transport level, so the next parse starts clean.
    private func discard(_ stale: NSXPCConnection) {
        connectionLock.lock()
        if connection === stale { connection = nil }
        connectionLock.unlock()
        stale.invalidate()
    }

    /// Transport-level `ParserXPCError`s that mean the connection itself is
    /// unusable, as opposed to one message failing to parse remotely.
    private static func isTransportFailure(_ error: Error) -> Bool {
        switch error {
        case ParserXPCError.connectionInvalidated, ParserXPCError.timedOut, ParserXPCError.emptyReply:
            return true
        default:
            return false
        }
    }

    private static func request(data: Data, over connection: NSXPCConnection) async throws -> IngestableEmail {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)

            // XPC calls exactly one of the reply block or this error handler
            // per message — including when the connection is invalidated with
            // the request in flight — so no per-request invalidationHandler
            // is needed (which wouldn't be safe on a shared connection).
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.resume(throwing: error)
            }) as? ParserXPCProtocol else {
                box.resume(throwing: ParserXPCError.connectionInvalidated)
                return
            }

            proxy.parseEmlx(data) { encoded, errorDescription in
                if let errorDescription {
                    box.resume(throwing: ParserXPCError.remote(errorDescription))
                    return
                }
                guard let encoded else {
                    box.resume(throwing: ParserXPCError.emptyReply)
                    return
                }
                do {
                    box.resume(returning: try JSONDecoder().decode(IngestableEmail.self, from: encoded))
                } catch {
                    box.resume(throwing: ParserXPCError.decodeFailed(String(describing: error)))
                }
            }
        }
    }
}

public enum ParserXPCError: Error, CustomStringConvertible {
    case connectionInvalidated
    case emptyReply
    case remote(String)
    case decodeFailed(String)
    case timedOut

    public var description: String {
        switch self {
        case .connectionInvalidated: return "parser XPC service connection invalidated"
        case .emptyReply: return "parser XPC service returned no data and no error"
        case .remote(let message): return "parser XPC service error: \(message)"
        case .decodeFailed(let message): return "parser XPC reply decode failed: \(message)"
        case .timedOut: return "parser XPC service didn\u{2019}t reply in time"
        }
    }
}

/// `NSXPCConnection` can invoke the error handler, the invalidation handler,
/// AND the reply block for the same request (e.g. a normal reply followed by
/// this client's own `connection.invalidate()` cleanup) — Swift concurrency
/// traps if a `CheckedContinuation` resumes more than once, so every path
/// above goes through this instead of calling `continuation.resume` directly.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<IngestableEmail, Error>?

    init(_ continuation: CheckedContinuation<IngestableEmail, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: IngestableEmail) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
