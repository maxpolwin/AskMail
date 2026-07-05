import Foundation

public enum IngestError: Error, CustomStringConvertible {
    /// The embedding backend (local Ollama) became unreachable, so the run was
    /// stopped rather than logging a failure for every remaining message.
    case embedderUnreachable

    public var description: String {
        switch self {
        case .embedderUnreachable:
            return "embedding backend unreachable (is Ollama running at localhost:11434?)"
        }
    }
}

public struct IngestProgress: Sendable {
    public var processed: Int
    public var total: Int

    public init(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }
}

public struct IngestSummary: Sendable {
    public var ingested: Int
    public var failed: Int
    /// Files unchanged since a prior run, skipped without re-embedding (FR-5).
    public var skipped: Int
    public var newWatermark: Int64?

    public init(ingested: Int, failed: Int, skipped: Int = 0, newWatermark: Int64?) {
        self.ingested = ingested
        self.failed = failed
        self.skipped = skipped
        self.newWatermark = newWatermark
    }
}

/// Parses .emlx files, chunks body and PDF text, embeds locally, and upserts
/// into the store. Re-running over the same files is idempotent (FR-5).
public final class MailboxIngestor {
    private let store: SQLiteStore
    private let embedder: EmbeddingProvider
    private let chunker: Chunker
    private let account: String
    private let log: (String) -> Void

    public init(store: SQLiteStore,
                embedder: EmbeddingProvider,
                account: String,
                chunker: Chunker = Chunker(),
                log: @escaping (String) -> Void = { RollingLog.shared.log($0) }) {
        self.store = store
        self.embedder = embedder
        self.account = account
        self.chunker = chunker
        self.log = log
    }

    /// Ingests the given .emlx files. Advances the store watermark to the
    /// newest message date seen. Individual file failures are logged and
    /// skipped (untrusted input fails closed), never abort the run.
    @discardableResult
    public func ingest(files: [URL],
                       progress: (@Sendable (IngestProgress) -> Void)? = nil) async throws -> IngestSummary {
        var ingested = 0
        var failed = 0
        var maxDate: Int64 = (try? store.watermark()) ?? 0

        for (index, file) in files.enumerated() {
            do {
                let email = try EmlxParser.parse(fileURL: file)
                try await ingest(email: email)
                ingested += 1
                maxDate = max(maxDate, email.dateUnix)
            } catch {
                failed += 1
                log("ingest FAILED file=\(file.lastPathComponent) error=\(error)")
            }
            progress?(IngestProgress(processed: index + 1, total: files.count))
        }

        var newWatermark: Int64? = nil
        if maxDate > 0 {
            try store.setWatermark(maxDate)
            newWatermark = maxDate
        }
        log("ingest done: \(ingested) ok, \(failed) failed, watermark=\(String(describing: newWatermark))")
        return IngestSummary(ingested: ingested, failed: failed, newWatermark: newWatermark)
    }

    /// Consecutive embed-connection failures that mean the backend is down (not
    /// a one-off), after which the run aborts instead of failing every remaining
    /// message. Small so a dead Ollama is reported within seconds.
    static let unreachableAbortThreshold = 3

    /// Incremental ingest (FR-5): processes only files new or changed since the
    /// last run, skipping any whose fingerprint the store already recorded.
    /// Each processed file's fingerprint is committed as it succeeds, so a crash
    /// mid-run resumes from where it stopped rather than restarting. Individual
    /// file failures are logged and skipped; but if the embedding backend goes
    /// unreachable, the run aborts with `IngestError.embedderUnreachable` rather
    /// than logging a failure for all remaining messages.
    @discardableResult
    public func ingestNew(_ files: [EmlxFile],
                          progress: (@Sendable (IngestProgress) -> Void)? = nil) async throws -> IngestSummary {
        var ingested = 0
        var failed = 0
        var skipped = 0
        var consecutiveUnreachable = 0
        var maxDate: Int64 = (try? store.watermark()) ?? 0

        for (index, file) in files.enumerated() {
            if let seen = try? store.ingestedFingerprint(sourceID: file.sourceID),
               seen == file.fingerprint {
                skipped += 1
                progress?(IngestProgress(processed: index + 1, total: files.count))
                continue
            }
            do {
                let email = try EmlxParser.parse(fileURL: file.url)
                try await ingest(email: email)
                try store.recordIngested(sourceID: file.sourceID, fingerprint: file.fingerprint)
                ingested += 1
                consecutiveUnreachable = 0
                maxDate = max(maxDate, email.dateUnix)
            } catch {
                failed += 1
                log("ingest FAILED file=\(file.url.lastPathComponent) error=\(error)")
                if Self.isConnectionError(error) {
                    consecutiveUnreachable += 1
                    if consecutiveUnreachable >= Self.unreachableAbortThreshold {
                        log("ingest aborted after \(consecutiveUnreachable) consecutive connection failures; \(ingested) done this run")
                        throw IngestError.embedderUnreachable
                    }
                } else {
                    consecutiveUnreachable = 0
                }
            }
            progress?(IngestProgress(processed: index + 1, total: files.count))
        }

        var newWatermark: Int64? = nil
        if maxDate > 0 {
            try store.setWatermark(maxDate)
            newWatermark = maxDate
        }
        log("ingest done (incremental): \(ingested) new, \(skipped) unchanged, \(failed) failed")
        return IngestSummary(ingested: ingested, failed: failed, skipped: skipped, newWatermark: newWatermark)
    }

    /// Whether an error means the embedding backend is unreachable (daemon down,
    /// connection refused/lost) as opposed to a per-message problem. Matches the
    /// observed -1004 "could not connect" cascade.
    static func isConnectionError(_ error: Error) -> Bool {
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

    public func ingest(email: ParsedEmail) async throws {
        var pieces: [(source: ChunkSource, text: String)] = []
        for text in chunker.chunk(email.bodyText) {
            pieces.append((.body, text))
        }
        for attachment in email.pdfAttachments {
            guard let pdfText = PdfText.extract(data: attachment.data) else {
                log("ingest skip pdf=\(attachment.filename) (no extractable text)")
                continue
            }
            for text in chunker.chunk(pdfText) {
                pieces.append((.pdf, text))
            }
        }
        for skippedName in email.skippedAttachments {
            log("ingest skip attachment=\(skippedName) (over size cap)")
        }

        // Embed in batches sized to memory pressure (docs/defaults.md).
        var embeddings: [[Float]] = []
        var cursor = 0
        while cursor < pieces.count {
            let end = min(cursor + Defaults.embedBatchSize, pieces.count)
            let batch = Array(pieces[cursor..<end]).map(\.text)
            embeddings.append(contentsOf: try await embedder.embed(batch))
            cursor = end
        }

        let pk = try store.upsertMessage(messageID: email.messageID,
                                         account: account,
                                         subject: email.subject,
                                         sender: email.sender,
                                         dateUnix: email.dateUnix)
        let rows = pieces.enumerated().map { index, piece in
            (source: piece.source,
             text: piece.text,
             embedding: index < embeddings.count ? embeddings[index] : nil)
        }
        try store.replaceChunks(messagePk: pk, chunks: rows)
    }
}
