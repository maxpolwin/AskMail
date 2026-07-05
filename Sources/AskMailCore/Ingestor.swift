import Foundation

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
    public var newWatermark: Int64?

    public init(ingested: Int, failed: Int, newWatermark: Int64?) {
        self.ingested = ingested
        self.failed = failed
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
