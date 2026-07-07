import Foundation

public enum IngestError: Error, CustomStringConvertible {
    /// The embedding backend (local Ollama) became unreachable, so the run was
    /// stopped rather than logging a failure for every remaining message.
    case embedderUnreachable
    /// The embedding model isn't installed in Ollama. This fails every message
    /// identically, so the run aborts immediately with the exact pull command
    /// rather than logging thousands of identical 404s.
    case embeddingModelMissing(model: String)
    /// The configured embedding model differs from the one that built the
    /// (non-empty) index. An incremental run would mix incomparable vectors,
    /// so it is refused; only a full rebuild may proceed.
    case embeddingModelMismatch(configured: String, indexed: String)

    public var description: String {
        switch self {
        case .embedderUnreachable:
            return "embedding backend unreachable (is Ollama running at localhost:11434?)"
        case .embeddingModelMissing(let model):
            return "embedding model \u{201C}\(model)\u{201D} not installed (run: ollama pull \(model))"
        case .embeddingModelMismatch(let configured, let indexed):
            return "index built with \u{201C}\(indexed)\u{201D} but \u{201C}\(configured)\u{201D} is configured \u{2014} rebuild required"
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
    /// Messages processed but yielding zero chunks (empty body, no extractable
    /// attachments). Reported apart from `ingested` so the status never implies
    /// searchable content that isn't there.
    public var empty: Int
    public var newWatermark: Int64?

    public init(ingested: Int, failed: Int, skipped: Int = 0, empty: Int = 0,
                newWatermark: Int64?) {
        self.ingested = ingested
        self.failed = failed
        self.skipped = skipped
        self.empty = empty
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
    /// Model (+dimension) the caller configured this run's embedder with;
    /// stamped into the store and checked against the previous run's stamp so
    /// vectors from two models never mix. nil skips the stamp (legacy path).
    private let embeddingStamp: EmbeddingStamp?
    private let log: (String, RollingLog.LogLevel) -> Void
    /// Turns a raw .emlx file into an `IngestableEmail`. Production
    /// (AskMailApp) injects `XPCEmailParser`, running all untrusted
    /// MIME/HTML/PDF parsing in a sandboxed child process (hardening H-6);
    /// the default here is the in-process parser, correct for tests, whose
    /// synthetic fixtures don't need that isolation.
    private let parser: EmailParsing

    public init(store: SQLiteStore,
                embedder: EmbeddingProvider,
                account: String,
                chunker: Chunker = Chunker(),
                embeddingStamp: EmbeddingStamp? = nil,
                parser: EmailParsing = InProcessEmailParser(),
                log: @escaping (String, RollingLog.LogLevel) -> Void = { RollingLog.shared.log($0, level: $1) }) {
        self.store = store
        self.embedder = embedder
        self.account = account
        self.chunker = chunker
        self.embeddingStamp = embeddingStamp
        self.parser = parser
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
                let email = try await parser.parse(fileURL: file)
                try await ingest(email: email)
                ingested += 1
                maxDate = max(maxDate, email.dateUnix)
            } catch {
                failed += 1
                log("ingest FAILED file=\(file.lastPathComponent) error=\(error)", .error)
            }
            progress?(IngestProgress(processed: index + 1, total: files.count))
        }

        var newWatermark: Int64? = nil
        if maxDate > 0 {
            try store.setWatermark(maxDate)
            newWatermark = maxDate
        }
        log("ingest done: \(ingested) ok, \(failed) failed, watermark=\(String(describing: newWatermark))", .info)
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
    /// file failures are logged, recorded for a later retry
    /// (`SQLiteStore.failedIngestSourceIDs`), and skipped; but if the embedding
    /// backend goes unreachable, the run aborts with
    /// `IngestError.embedderUnreachable` rather than logging a failure for all
    /// remaining messages.
    @discardableResult
    public func ingestNew(_ files: [EmlxFile],
                          progress: (@Sendable (IngestProgress) -> Void)? = nil) async throws -> IngestSummary {
        // Refuse to mix models before touching anything: an incremental run
        // over an index built by a different embedding model would interleave
        // incomparable vectors (Phase 3 invariant). A matching or fresh index
        // is (re-)stamped so the check holds for the next run too.
        if let embeddingStamp {
            let existing = try store.embeddingStamp()
            if EmbeddingStamp.requiresRebuild(configuredModel: embeddingStamp.model,
                                              stamp: existing,
                                              chunkCount: try store.chunkCount()) {
                log("ingest refused: index stamped \(existing!.encoded), configured \(embeddingStamp.encoded)", .error)
                throw IngestError.embeddingModelMismatch(configured: embeddingStamp.model,
                                                         indexed: existing!.model)
            }
            try store.setEmbeddingStamp(embeddingStamp)
        }

        var ingested = 0
        var failed = 0
        var skipped = 0
        var empty = 0
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
                let email = try await parser.parse(fileURL: file.url)
                let chunkCount = try await ingest(email: email)
                try store.recordIngested(sourceID: file.sourceID, fingerprint: file.fingerprint)
                try? store.clearIngestFailure(sourceID: file.sourceID)
                // A zero-chunk message (empty body, nothing extractable) is
                // done — but it added no searchable content, so it doesn't
                // count as "new" (adjacent cleanup #1).
                if chunkCount == 0 { empty += 1 } else { ingested += 1 }
                consecutiveUnreachable = 0
                maxDate = max(maxDate, email.dateUnix)
            } catch {
                // A missing embedding model is a setup error, not a per-file
                // fault: it will fail every remaining message identically, so
                // abort now with an actionable message instead of recording
                // thousands of identical failures.
                if let model = Self.missingEmbeddingModel(error) {
                    log("ingest aborted: embedding model \(model) not installed; \(ingested) done this run", .error)
                    throw IngestError.embeddingModelMissing(model: model)
                }
                failed += 1
                log("ingest FAILED file=\(file.url.lastPathComponent) error=\(error)", .error)
                try? store.recordIngestFailure(sourceID: file.sourceID, path: file.url.path,
                                               error: String(describing: error))
                if Self.isConnectionError(error) {
                    consecutiveUnreachable += 1
                    if consecutiveUnreachable >= Self.unreachableAbortThreshold {
                        log("ingest aborted after \(consecutiveUnreachable) consecutive connection failures; \(ingested) done this run", .error)
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
        log("ingest done (incremental): \(ingested) new, \(empty) empty, \(skipped) unchanged, \(failed) failed", .info)
        return IngestSummary(ingested: ingested, failed: failed, skipped: skipped,
                             empty: empty, newWatermark: newWatermark)
    }

    /// The model name if this error is Ollama's "model not installed" 404 — a
    /// global misconfiguration that dooms every message, distinct from a
    /// per-message parse/embed failure.
    static func missingEmbeddingModel(_ error: Error) -> String? {
        if case ProviderError.ollamaModelMissing(let model) = error { return model }
        return nil
    }

    /// Whether an error means the embedding backend is unreachable (daemon down,
    /// connection refused/lost) as opposed to a per-message problem. Matches the
    /// observed -1004 "could not connect" cascade.
    static func isConnectionError(_ error: Error) -> Bool {
        ProviderError.isConnectionFailure(error)
    }

    /// Returns the number of chunks stored, so callers can tell an ingested
    /// message from an empty one (zero chunks = nothing searchable).
    ///
    /// Takes `IngestableEmail`, not `ParsedEmail`: PDF text is already
    /// extracted by the time it reaches here (either in-process for tests,
    /// or inside the sandboxed parser XPC service in production), so this
    /// method never calls PDFKit itself (hardening H-6).
    @discardableResult
    public func ingest(email: IngestableEmail) async throws -> Int {
        var pieces: [(source: ChunkSource, text: String)] = []
        for text in chunker.chunk(email.bodyText) {
            pieces.append((.body, text))
        }
        for attachment in email.pdfAttachments {
            guard let pdfText = attachment.text else {
                log("ingest skip pdf=\(attachment.filename) (no extractable text)", .debug)
                continue
            }
            for text in chunker.chunk(pdfText) {
                pieces.append((.pdf, text))
            }
        }
        for skippedName in email.skippedAttachments {
            log("ingest skip attachment=\(skippedName) (over size cap)", .debug)
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

        // Draft-Modus §3: resolved for every ingested message (not just a
        // future opt-in path) since thread reconstruction needs full history
        // to work, and this is the one ingest call site both the hourly
        // Vectorizer and any future draft-triggered ingest share.
        let threadID = try ThreadResolver.resolveThread(messageID: email.messageID,
                                                        inReplyTo: email.inReplyTo,
                                                        references: email.references,
                                                        store: store)
        let pk = try store.upsertMessage(messageID: email.messageID,
                                         account: account,
                                         subject: email.subject,
                                         sender: email.sender,
                                         originalSender: email.originalSender,
                                         inReplyTo: email.inReplyTo,
                                         referencesIDs: email.references,
                                         threadID: threadID,
                                         bodyText: email.bodyText,
                                         dateUnix: email.dateUnix)
        let rows = pieces.enumerated().map { index, piece in
            (source: piece.source,
             text: piece.text,
             embedding: index < embeddings.count ? embeddings[index] : nil)
        }
        try store.replaceChunks(messagePk: pk, chunks: rows)
        return rows.count
    }
}
