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
public struct XPCEmailParser: EmailParsing {
    /// Wall-clock budget for one file. A hung child (or an input crafted to
    /// spin the parser, belt-and-suspenders alongside the H-7/H-9 caps
    /// enforced inside the parser itself) fails that one file instead of
    /// stalling the whole ingestion run.
    private static let requestTimeout: Duration = .seconds(30)

    public init() {}

    public func parse(fileURL: URL) async throws -> IngestableEmail {
        let data = try Data(contentsOf: fileURL)

        let connection = NSXPCConnection(serviceName: ParserXPC.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ParserXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withThrowingTaskGroup(of: IngestableEmail.self) { group in
            group.addTask { try await Self.request(data: data, over: connection) }
            group.addTask {
                try await Task.sleep(for: Self.requestTimeout)
                // Unblocks `request`'s continuation via its invalidationHandler
                // instead of leaving it (and the child's mach port) hanging.
                connection.invalidate()
                throw ParserXPCError.timedOut
            }
            guard let result = try await group.next() else { throw ParserXPCError.timedOut }
            group.cancelAll()
            return result
        }
    }

    private static func request(data: Data, over connection: NSXPCConnection) async throws -> IngestableEmail {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce(continuation)
            connection.invalidationHandler = { box.resume(throwing: ParserXPCError.connectionInvalidated) }
            connection.interruptionHandler = { connection.invalidate() }

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
