import Accelerate
import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case sql(String)

    public var description: String {
        switch self {
        case .openFailed(let message): return "sqlite open failed: \(message)"
        case .sql(let message): return "sqlite error: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The app's local vector + keyword database. All mailbox content stays in
/// this on-device file (SECURITY.md).
///
/// Vector search is currently a brute-force cosine scan over embedding blobs.
/// The spec calls for sqlite-vec; swap it in behind `vectorSearch` during
/// spike B11 once the C extension is vendored. The brute-force scan is exact
/// (recall-equivalent) and adequate for tens of thousands of chunks.
/// `@unchecked Sendable`: every public method serializes on `lock`
/// (recursive, see `transaction`); the raw `db` handle is never exposed.
public final class SQLiteStore: @unchecked Sendable {
    private let db: OpaquePointer
    /// Recursive so `transaction {}` can hold it across a body that calls the
    /// store's own public methods (each of which takes the lock itself).
    private let lock = NSRecursiveLock()
    /// Nesting depth of `transaction {}` on this connection — only the
    /// outermost call emits BEGIN/COMMIT. Guarded by `lock`.
    private var transactionDepth = 0
    /// Unit-normalized copies of every stored embedding, so `vectorSearch`
    /// scores in memory instead of re-reading and re-decoding the whole
    /// `chunks` table per query. nil = rebuild on next search; invalidated by
    /// every chunk write. Guarded by `lock`; the array itself is
    /// copy-on-write, so a snapshot reference is safe to score outside it.
    private var normalizedEmbeddingCache: [(id: Int64, vector: [Float])]?

    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close(h) }
            throw StoreError.openFailed(message)
        }
        db = opened
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=5000")
        try migrate()
        if path != ":memory:" {
            FileHardening.lockDown(fileURL: URL(fileURLWithPath: path))
        }
    }

    public static func inMemory() throws -> SQLiteStore {
        try SQLiteStore(path: ":memory:")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Schema

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS messages(
          pk INTEGER PRIMARY KEY,
          message_id TEXT NOT NULL UNIQUE,
          account TEXT NOT NULL,
          subject TEXT NOT NULL,
          sender TEXT NOT NULL,
          original_sender TEXT,
          date_unix INTEGER NOT NULL
        );
        """)
        // Added after the initial release; existing DBs need the column added
        // explicitly since CREATE TABLE IF NOT EXISTS is a no-op for them.
        if !(try columnExists("messages", "original_sender")) {
            try execute("ALTER TABLE messages ADD COLUMN original_sender TEXT")
        }
        // Draft-Modus thread linking (Phase 1). in_reply_to/references_ids are
        // space-joined, bracket-stripped Message-ID tokens (same normalization
        // as message_id itself, so they're directly comparable). body_text is
        // the verbatim cleaned body — not reconstructed from `chunks`, which
        // are overlapping retrieval fragments unsuitable for "the full exchange".
        if !(try columnExists("messages", "in_reply_to")) {
            try execute("ALTER TABLE messages ADD COLUMN in_reply_to TEXT")
        }
        if !(try columnExists("messages", "references_ids")) {
            try execute("ALTER TABLE messages ADD COLUMN references_ids TEXT")
        }
        if !(try columnExists("messages", "thread_id")) {
            try execute("ALTER TABLE messages ADD COLUMN thread_id TEXT")
        }
        if !(try columnExists("messages", "body_text")) {
            try execute("ALTER TABLE messages ADD COLUMN body_text TEXT")
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id)")
        // Date-scoped retrieval (`chunks(dateRange:)`) and latest-thread
        // lookups order/filter on date_unix; without this they scan+sort.
        try execute("CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(date_unix)")
        // Reverse thread-linking index: one row per (referenced Message-ID,
        // referencing message), so `candidateReferencers` is an indexed
        // lookup instead of a full messages scan per ingested message —
        // which made full rebuilds O(n²). Backfilled once from the existing
        // in_reply_to/references_ids columns when the table first appears.
        let hadRefsTable = try tableExists("message_refs")
        try execute("""
        CREATE TABLE IF NOT EXISTS message_refs(
          referenced_message_id TEXT NOT NULL,
          message_pk INTEGER NOT NULL REFERENCES messages(pk) ON DELETE CASCADE,
          PRIMARY KEY(referenced_message_id, message_pk)
        ) WITHOUT ROWID
        """)
        // Covers the cascade and the per-message refs rewrite in upsertMessage.
        try execute("CREATE INDEX IF NOT EXISTS idx_message_refs_pk ON message_refs(message_pk)")
        if !hadRefsTable {
            try backfillMessageRefs()
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS chunks(
          id INTEGER PRIMARY KEY,
          message_pk INTEGER NOT NULL REFERENCES messages(pk) ON DELETE CASCADE,
          source TEXT NOT NULL,
          text TEXT NOT NULL,
          embedding BLOB
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_chunks_message ON chunks(message_pk);")
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts
        USING fts5(text, content='chunks', content_rowid='id');
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
          INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
          INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS meta(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
        // Per-source-file fingerprint so incremental runs skip unchanged
        // messages and resume after a crash (FR-5). Keyed by the envelope-index
        // ROWID parsed from the .emlx filename; the fingerprint changes whenever
        // Mail rewrites the file (e.g. a .partial becomes fully downloaded).
        try execute("""
        CREATE TABLE IF NOT EXISTS ingest_state(
          source_id INTEGER PRIMARY KEY,
          fingerprint TEXT NOT NULL
        );
        """)
        // Keyed by the same source_id as ingest_state, so a retry can re-scan
        // the account directory for just these ROWIDs and feed them through
        // the normal fingerprint-recording path (FR-5 retry).
        try execute("""
        CREATE TABLE IF NOT EXISTS ingest_failures(
          source_id INTEGER PRIMARY KEY,
          path TEXT NOT NULL,
          error TEXT NOT NULL,
          failed_at INTEGER NOT NULL
        );
        """)
    }

    // MARK: Transactions

    /// Runs `body` as one atomic SQLite transaction (`BEGIN IMMEDIATE` …
    /// `COMMIT`, rolled back if `body` throws), holding the store's lock
    /// throughout so no other thread's statements can join it. Nested calls
    /// merge into the outermost transaction. Without this, every statement
    /// commits (and fsyncs) individually — the dominant cost of bulk ingest.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard transactionDepth == 0 else {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        defer { transactionDepth = 0 }
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Messages & chunks

    /// Inserts or updates a message row; returns its primary key.
    /// `originalSender` is the forwarded message's embedded original author
    /// (`ForwardedEmail.detectOriginalSender`), nil for non-forwarded mail.
    /// `inReplyTo`/`referencesIDs` are bracket-stripped Message-ID tokens (see
    /// `ThreadResolver`); `threadID` is the resolved thread root's message id;
    /// `bodyText` is the verbatim cleaned body for thread reconstruction.
    @discardableResult
    public func upsertMessage(messageID: String, account: String, subject: String,
                              sender: String, originalSender: String? = nil,
                              inReplyTo: String? = nil, referencesIDs: [String] = [],
                              threadID: String? = nil, bodyText: String? = nil,
                              dateUnix: Int64) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let referencesJoined = referencesIDs.isEmpty ? nil : referencesIDs.joined(separator: " ")
        return try transaction {
            var pk: Int64 = 0
            // RETURNING avoids a second pk-lookup round trip per message.
            try query("""
            INSERT INTO messages(message_id, account, subject, sender, original_sender,
                                 in_reply_to, references_ids, thread_id, body_text, date_unix)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
              account = excluded.account,
              subject = excluded.subject,
              sender = excluded.sender,
              original_sender = excluded.original_sender,
              in_reply_to = excluded.in_reply_to,
              references_ids = excluded.references_ids,
              thread_id = excluded.thread_id,
              body_text = excluded.body_text,
              date_unix = excluded.date_unix
            RETURNING pk
            """) { statement in
                bind(statement, 1, messageID)
                bind(statement, 2, account)
                bind(statement, 3, subject)
                bind(statement, 4, sender)
                bindOptional(statement, 5, originalSender)
                bindOptional(statement, 6, inReplyTo)
                bindOptional(statement, 7, referencesJoined)
                bindOptional(statement, 8, threadID)
                bindOptional(statement, 9, bodyText)
                sqlite3_bind_int64(statement, 10, dateUnix)
            } row: { statement in
                pk = sqlite3_column_int64(statement, 0)
            }
            // Keep the reverse index in step with the columns it mirrors.
            try run("DELETE FROM message_refs WHERE message_pk = ?") { statement in
                sqlite3_bind_int64(statement, 1, pk)
            }
            try insertMessageRefs(pk: pk, inReplyTo: inReplyTo, referencesIDs: referencesIDs)
            return pk
        }
    }

    /// One `message_refs` row per distinct referenced Message-ID (the same id
    /// may appear in both In-Reply-To and References). Caller holds the lock.
    private func insertMessageRefs(pk: Int64, inReplyTo: String?, referencesIDs: [String]) throws {
        var referenced = Set<String>()
        if let inReplyTo, !inReplyTo.isEmpty { referenced.insert(inReplyTo) }
        for id in referencesIDs where !id.isEmpty { referenced.insert(id) }
        for id in referenced {
            try run("INSERT OR IGNORE INTO message_refs(referenced_message_id, message_pk) VALUES (?, ?)") { statement in
                bind(statement, 1, id)
                sqlite3_bind_int64(statement, 2, pk)
            }
        }
    }

    /// Populates `message_refs` from the pre-existing space-joined columns the
    /// first time the table is created (one-time migration step).
    private func backfillMessageRefs() throws {
        var rows: [(pk: Int64, inReplyTo: String?, references: String?)] = []
        try query("""
        SELECT pk, in_reply_to, references_ids FROM messages
        WHERE in_reply_to IS NOT NULL OR references_ids IS NOT NULL
        """) { _ in
        } row: { statement in
            rows.append((sqlite3_column_int64(statement, 0),
                         nullableColumn(statement, 1),
                         nullableColumn(statement, 2)))
        }
        guard !rows.isEmpty else { return }
        try transaction {
            for row in rows {
                let references = row.references?.split(separator: " ").map(String.init) ?? []
                try insertMessageRefs(pk: row.pk, inReplyTo: row.inReplyTo, referencesIDs: references)
            }
        }
    }

    // MARK: Thread linking (Draft-Modus §3)

    /// A message's primary key and resolved thread id (nil if never resolved
    /// — shouldn't happen post-ingest, but `ThreadResolver` treats it
    /// defensively as "no thread info yet").
    public func messageByMessageID(_ id: String) throws -> (pk: Int64, threadID: String?)? {
        lock.lock(); defer { lock.unlock() }
        var result: (Int64, String?)?
        try query("SELECT pk, thread_id FROM messages WHERE message_id = ?") { statement in
            bind(statement, 1, id)
        } row: { statement in
            result = (sqlite3_column_int64(statement, 0), nullableColumn(statement, 1))
        }
        return result
    }

    /// Messages that already point at `referencingMessageID` via their own
    /// `in_reply_to`/`references_ids` — used to detect out-of-order arrival
    /// (a reply ingested before its parent). An indexed lookup against the
    /// `message_refs` reverse table (one row per referenced Message-ID), so
    /// resolving a thread costs O(matches) instead of a full messages scan —
    /// the scan made full-mailbox rebuilds quadratic.
    public func candidateReferencers(referencingMessageID: String) throws -> [(pk: Int64, threadID: String, inReplyTo: String?, referencesIDs: [String])] {
        lock.lock(); defer { lock.unlock() }
        var results: [(Int64, String, String?, [String])] = []
        try query("""
        SELECT m.pk, m.thread_id, m.in_reply_to, m.references_ids
        FROM message_refs r JOIN messages m ON m.pk = r.message_pk
        WHERE r.referenced_message_id = ? AND m.thread_id IS NOT NULL
        """) { statement in
            bind(statement, 1, referencingMessageID)
        } row: { statement in
            guard let threadID = nullableColumn(statement, 1) else { return }
            let inReplyTo = nullableColumn(statement, 2)
            let references = nullableColumn(statement, 3)?.split(separator: " ").map(String.init) ?? []
            results.append((sqlite3_column_int64(statement, 0), threadID, inReplyTo, references))
        }
        return results
    }

    /// Resolves the most recent thread involving `address` directly from the
    /// mailbox, independent of `drafts.db` entirely -- the manual-trigger
    /// bypass (Insert/Regenerate) needs this because a thread that was never
    /// enqueued, or was skipped by a classification rule (newsletter,
    /// no-reply, exclusion list), has no row in `drafts.db` to match against
    /// at all, yet the user explicitly asked for a draft anyway. SQL `LIKE`
    /// is a coarse, index-free pre-filter over the most recent `scanLimit`
    /// senders matching the substring; exact equality is re-checked in Swift
    /// via `MailHeader.address(fromSender:)` since `sender` stores the raw
    /// "Name <addr>" header, not a bare address.
    public func latestThreadID(fromSenderAddress address: String, scanLimit: Int = 500) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        var result: String?
        try query("""
        SELECT sender, thread_id FROM messages
        WHERE thread_id IS NOT NULL AND sender LIKE ?
        ORDER BY date_unix DESC LIMIT ?
        """) { statement in
            bind(statement, 1, "%\(address)%")
            sqlite3_bind_int(statement, 2, Int32(scanLimit))
        } row: { statement in
            guard result == nil else { return }
            let sender = column(statement, 0)
            guard MailHeader.address(fromSender: sender)?.lowercased() == address.lowercased() else { return }
            result = nullableColumn(statement, 1)
        }
        return result
    }

    /// Reassigns every message in one thread group to another — the
    /// out-of-order-arrival merge (`ThreadResolver`).
    public func mergeThreads(from: String, to: String) throws {
        guard from != to else { return }
        lock.lock(); defer { lock.unlock() }
        try run("UPDATE messages SET thread_id = ? WHERE thread_id = ?") { statement in
            bind(statement, 1, to)
            bind(statement, 2, from)
        }
    }

    /// A thread's messages oldest-first, capped at `limit` — takes the most
    /// recent `limit` by date (so the newest message is always included) and
    /// reverses to chronological order, bounding prompt size for `DraftAssembler`.
    /// Default wired to `Defaults.draftThreadMessageLimit` (draft-contract §2)
    /// so the mandated cap has a single source of truth.
    public func threadMessages(threadID: String, limit: Int = Defaults.draftThreadMessageLimit) throws -> [ThreadMessage] {
        lock.lock(); defer { lock.unlock() }
        var results: [ThreadMessage] = []
        try query("""
        SELECT message_id, sender, date_unix, subject, body_text FROM messages
        WHERE thread_id = ? ORDER BY date_unix DESC LIMIT ?
        """) { statement in
            bind(statement, 1, threadID)
            sqlite3_bind_int(statement, 2, Int32(limit))
        } row: { statement in
            results.append(ThreadMessage(
                messageID: column(statement, 0),
                sender: column(statement, 1),
                dateUnix: sqlite3_column_int64(statement, 2),
                subject: column(statement, 3),
                bodyText: nullableColumn(statement, 4) ?? ""
            ))
        }
        return results.reversed()
    }

    /// Replaces all chunks of a message, keeping re-vectorization idempotent
    /// (FR-5: upsert without duplicates).
    public func replaceChunks(messagePk: Int64,
                              chunks: [(source: ChunkSource, text: String, embedding: [Float]?)]) throws {
        lock.lock(); defer { lock.unlock() }
        normalizedEmbeddingCache = nil
        // One transaction for the delete + all inserts: a single commit
        // instead of one per chunk, and no crash window with partial chunks.
        try transaction {
            try run("DELETE FROM chunks WHERE message_pk = ?") { statement in
                sqlite3_bind_int64(statement, 1, messagePk)
            }
            for chunk in chunks {
                try run("INSERT INTO chunks(message_pk, source, text, embedding) VALUES (?, ?, ?, ?)") { statement in
                    sqlite3_bind_int64(statement, 1, messagePk)
                    bind(statement, 2, chunk.source.rawValue)
                    bind(statement, 3, chunk.text)
                    if let embedding = chunk.embedding {
                        let data = Self.blob(from: embedding)
                        data.withUnsafeBytes { buffer in
                            _ = sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                        }
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                }
            }
        }
    }

    // MARK: Search

    /// FTS5 keyword search, best first (bm25). Terms are quoted and OR-joined
    /// so user text can never inject FTS query syntax.
    public func keywordSearch(_ queryText: String, topN: Int = Defaults.keywordTopN) throws -> [Int64] {
        let terms = queryText
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")

        lock.lock(); defer { lock.unlock() }
        var ids: [Int64] = []
        try query("""
        SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?
        ORDER BY bm25(chunks_fts) LIMIT ?
        """) { statement in
            bind(statement, 1, match)
            sqlite3_bind_int(statement, 2, Int32(topN))
        } row: { statement in
            ids.append(sqlite3_column_int64(statement, 0))
        }
        return ids
    }

    /// Vector search, best first. Brute-force exact cosine over all stored
    /// embeddings; see the class note about the sqlite-vec swap-in point.
    ///
    /// Scores against `normalizedEmbeddingCache` — unit vectors decoded once
    /// per index change, not re-read from SQLite per query — so cosine
    /// collapses to an Accelerate dot product. The cache holds the same bytes
    /// the old per-query scan allocated transiently (~4 bytes × dims per
    /// chunk, ~28 MB at 6.8k × 1024-dim), traded deliberately for resident
    /// memory to make every ask/draft retrieval fast.
    public func vectorSearch(_ embedding: [Float], topN: Int = Defaults.vectorTopN) throws -> [Int64] {
        let queryVector = Self.normalized(embedding)
        guard !queryVector.isEmpty else { return [] }

        // Build or snapshot the cache under the lock; score outside it so the
        // scan doesn't serialize concurrent ingest (lock-hold reduction).
        let cache: [(id: Int64, vector: [Float])] = try {
            lock.lock(); defer { lock.unlock() }
            if let cached = normalizedEmbeddingCache { return cached }
            var rows: [(id: Int64, vector: [Float])] = []
            try query("SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL") { _ in
            } row: { statement in
                let byteCount = Int(sqlite3_column_bytes(statement, 1))
                guard byteCount > 0, let pointer = sqlite3_column_blob(statement, 1) else { return }
                let data = Data(bytes: pointer, count: byteCount)
                rows.append((sqlite3_column_int64(statement, 0), Self.normalized(Self.floats(from: data))))
            }
            normalizedEmbeddingCache = rows
            return rows
        }()

        var scored: [(id: Int64, score: Float)] = []
        scored.reserveCapacity(cache.count)
        var mismatched = 0
        for entry in cache {
            guard entry.vector.count == queryVector.count else {
                mismatched += 1
                continue
            }
            scored.append((entry.id, vDSP.dot(entry.vector, queryVector)))
        }
        if mismatched > 0 {
            // With the single-model stamp enforced at ingest, this guard is an
            // invariant: tripping it means a bug or a pre-stamp index, and
            // staying silent would just look like bad retrieval.
            RollingLog.shared.log(
                "vectorSearch DROPPED \(mismatched) chunks with mismatched dimensions \u{2014} index needs a rebuild",
                level: .error)
        }
        return scored.sorted { $0.score > $1.score }.prefix(topN).map(\.id)
    }

    /// The vector scaled to unit length, so cosine similarity against another
    /// unit vector is a plain dot product. A zero vector is returned as-is
    /// (its dot with anything is 0, matching `cosine`'s zero-denominator case).
    static func normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        let norm = vDSP.sumOfSquares(vector).squareRoot()
        guard norm > 0 else { return vector }
        return vDSP.divide(vector, norm)
    }

    /// Loads chunks with their email metadata, preserving the input id order
    /// (fused rank must survive the round trip; contract §3).
    public func chunks(ids: [Int64]) throws -> [ContextChunk] {
        guard !ids.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var byID: [Int64: ContextChunk] = [:]
        try query("""
        SELECT c.id, m.message_id, m.subject, m.sender, m.original_sender, m.date_unix, c.source, c.text
        FROM chunks c JOIN messages m ON m.pk = c.message_pk
        WHERE c.id IN (\(placeholders))
        """) { statement in
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }
        } row: { statement in
            let chunk = ContextChunk(
                chunkID: sqlite3_column_int64(statement, 0),
                messageID: column(statement, 1),
                subject: column(statement, 2),
                sender: column(statement, 3),
                originalSender: nullableColumn(statement, 4),
                dateUnix: sqlite3_column_int64(statement, 5),
                source: ChunkSource(rawValue: column(statement, 6)) ?? .body,
                text: column(statement, 7)
            )
            byID[chunk.chunkID] = chunk
        }
        return ids.compactMap { byID[$0] }
    }

    /// Loads chunks whose message falls inside `range`, oldest first,
    /// bypassing semantic/keyword ranking entirely. Used when a question is
    /// date-scoped (DateFilter) so that "what did I get on <date>" surfaces
    /// every matching email regardless of how it scores against the raw
    /// question text (contract B6 step 5).
    public func chunks(dateRange range: ClosedRange<Int64>, limit: Int) throws -> [ContextChunk] {
        lock.lock(); defer { lock.unlock() }
        var results: [ContextChunk] = []
        try query("""
        SELECT c.id, m.message_id, m.subject, m.sender, m.original_sender, m.date_unix, c.source, c.text
        FROM chunks c JOIN messages m ON m.pk = c.message_pk
        WHERE m.date_unix BETWEEN ? AND ?
        ORDER BY m.date_unix ASC
        LIMIT ?
        """) { statement in
            sqlite3_bind_int64(statement, 1, range.lowerBound)
            sqlite3_bind_int64(statement, 2, range.upperBound)
            sqlite3_bind_int(statement, 3, Int32(limit))
        } row: { statement in
            results.append(ContextChunk(
                chunkID: sqlite3_column_int64(statement, 0),
                messageID: column(statement, 1),
                subject: column(statement, 2),
                sender: column(statement, 3),
                originalSender: nullableColumn(statement, 4),
                dateUnix: sqlite3_column_int64(statement, 5),
                source: ChunkSource(rawValue: column(statement, 6)) ?? .body,
                text: column(statement, 7)
            ))
        }
        return results
    }

    // MARK: Watermark & meta

    private static let watermarkKey = "watermark_date_unix"

    public func watermark() throws -> Int64? {
        try meta(Self.watermarkKey).flatMap { Int64($0) }
    }

    public func setWatermark(_ value: Int64) throws {
        try setMeta(Self.watermarkKey, value: String(value))
    }

    // MARK: Ingest state (FR-5 incremental)

    /// Fingerprint recorded for a source file's ROWID, or nil if never ingested.
    public func ingestedFingerprint(sourceID: Int64) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        var result: String? = nil
        try query("SELECT fingerprint FROM ingest_state WHERE source_id = ?") { statement in
            sqlite3_bind_int64(statement, 1, sourceID)
        } row: { statement in
            result = column(statement, 0)
        }
        return result
    }

    /// Marks a source file as ingested at the given fingerprint. Written last in
    /// a message's ingest so a crash before this point simply re-ingests it next
    /// run (upserts are idempotent).
    public func recordIngested(sourceID: Int64, fingerprint: String) throws {
        lock.lock(); defer { lock.unlock() }
        try run("""
        INSERT INTO ingest_state(source_id, fingerprint) VALUES (?, ?)
        ON CONFLICT(source_id) DO UPDATE SET fingerprint = excluded.fingerprint
        """) { statement in
            sqlite3_bind_int64(statement, 1, sourceID)
            bind(statement, 2, fingerprint)
        }
    }

    public func meta(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        var value: String?
        try query("SELECT value FROM meta WHERE key = ?") { statement in
            bind(statement, 1, key)
        } row: { statement in
            value = column(statement, 0)
        }
        return value
    }

    public func setMeta(_ key: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        try run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") { statement in
            bind(statement, 1, key)
            bind(statement, 2, value)
        }
    }

    // MARK: Ingest failures (retry)

    /// Records (or updates) a file that failed to ingest, so a later retry
    /// can target just the files that need it instead of the whole mailbox.
    public func recordIngestFailure(sourceID: Int64, path: String, error: String,
                                    at date: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try run("""
        INSERT INTO ingest_failures(source_id, path, error, failed_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(source_id) DO UPDATE SET
          path = excluded.path, error = excluded.error, failed_at = excluded.failed_at
        """) { statement in
            sqlite3_bind_int64(statement, 1, sourceID)
            bind(statement, 2, path)
            bind(statement, 3, error)
            sqlite3_bind_int64(statement, 4, Int64(date.timeIntervalSince1970))
        }
    }

    /// Clears a file's failure record once it ingests successfully.
    public func clearIngestFailure(sourceID: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try run("DELETE FROM ingest_failures WHERE source_id = ?") { statement in
            sqlite3_bind_int64(statement, 1, sourceID)
        }
    }

    /// Source IDs of files that failed on their most recent ingest attempt,
    /// oldest failure first.
    public func failedIngestSourceIDs() throws -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        var ids: [Int64] = []
        try query("SELECT source_id FROM ingest_failures ORDER BY failed_at") { _ in
        } row: { statement in
            ids.append(sqlite3_column_int64(statement, 0))
        }
        return ids
    }

    public func failedIngestCount() throws -> Int {
        try count("SELECT COUNT(*) FROM ingest_failures")
    }

    /// Drops failure rows whose source no longer appears in the current scan —
    /// files in since-excluded mailboxes (Trash/Junk after the allowlist) or
    /// deleted from disk. Without this, "Retry N failed…" stays inflated
    /// forever with rows a retry can never reach. Returns the pruned count.
    @discardableResult
    public func pruneIngestFailures(keeping validSourceIDs: Set<Int64>) throws -> Int {
        let stale = try failedIngestSourceIDs().filter { !validSourceIDs.contains($0) }
        guard !stale.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        // Chunked so the placeholder count stays under SQLite's variable limit.
        for batch in stride(from: 0, to: stale.count, by: 500).map({ Array(stale[$0..<min($0 + 500, stale.count)]) }) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try run("DELETE FROM ingest_failures WHERE source_id IN (\(placeholders))") { statement in
                for (index, id) in batch.enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 1), id)
                }
            }
        }
        return stale.count
    }

    // MARK: Maintenance (FR-8 delete & rebuild)

    /// Wipes all content and resets the watermark. The next scheduled or
    /// manual run rebuilds from scratch.
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        normalizedEmbeddingCache = nil
        try run("DELETE FROM messages") { _ in }   // chunks + message_refs cascade, FTS via trigger
        try run("DELETE FROM ingest_failures") { _ in }
        try run("DELETE FROM meta") { _ in }
        try run("DELETE FROM ingest_state") { _ in }
    }

    public func messageCount() throws -> Int {
        try count("SELECT COUNT(*) FROM messages")
    }

    public func chunkCount() throws -> Int {
        try count("SELECT COUNT(*) FROM chunks")
    }

    private func count(_ sql: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var result = 0
        try query(sql) { _ in } row: { statement in
            result = Int(sqlite3_column_int64(statement, 0))
        }
        return result
    }

    // MARK: Embedding blobs

    static func blob(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        // Defensive: callers already guard equal lengths, but don't index blindly.
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in 0..<a.count {
            let x = Double(a[index]), y = Double(b[index])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        let denominator = (normA.squareRoot() * normB.squareRoot())
        return denominator > 0 ? dot / denominator : 0
    }

    // MARK: SQLite plumbing

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw StoreError.sql(message)
        }
    }

    private func run(_ sql: String, bind bindings: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        bindings(prepared)
        guard sqlite3_step(prepared) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String,
                       bind bindings: (OpaquePointer) -> Void,
                       row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        bindings(prepared)
        while true {
            let status = sqlite3_step(prepared)
            if status == SQLITE_ROW {
                row(prepared)
            } else if status == SQLITE_DONE {
                break
            } else {
                throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptional(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bind(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func nullableColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func tableExists(_ name: String) throws -> Bool {
        var exists = false
        try query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?") { statement in
            bind(statement, 1, name)
        } row: { _ in
            exists = true
        }
        return exists
    }

    private func columnExists(_ table: String, _ column: String) throws -> Bool {
        var exists = false
        try query("PRAGMA table_info(\(table))") { _ in } row: { statement in
            if String(cString: sqlite3_column_text(statement, 1)) == column {
                exists = true
            }
        }
        return exists
    }
}
