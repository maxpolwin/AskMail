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
public final class SQLiteStore {
    private let db: OpaquePointer
    private let lock = NSLock()

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
        try migrate()
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
          date_unix INTEGER NOT NULL
        );
        """)
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

    // MARK: Messages & chunks

    /// Inserts or updates a message row; returns its primary key.
    @discardableResult
    public func upsertMessage(messageID: String, account: String, subject: String,
                              sender: String, dateUnix: Int64) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try run("""
        INSERT INTO messages(message_id, account, subject, sender, date_unix)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(message_id) DO UPDATE SET
          account = excluded.account,
          subject = excluded.subject,
          sender = excluded.sender,
          date_unix = excluded.date_unix
        """) { statement in
            bind(statement, 1, messageID)
            bind(statement, 2, account)
            bind(statement, 3, subject)
            bind(statement, 4, sender)
            sqlite3_bind_int64(statement, 5, dateUnix)
        }
        var pk: Int64 = 0
        try query("SELECT pk FROM messages WHERE message_id = ?") { statement in
            bind(statement, 1, messageID)
        } row: { statement in
            pk = sqlite3_column_int64(statement, 0)
        }
        return pk
    }

    /// Replaces all chunks of a message, keeping re-vectorization idempotent
    /// (FR-5: upsert without duplicates).
    public func replaceChunks(messagePk: Int64,
                              chunks: [(source: ChunkSource, text: String, embedding: [Float]?)]) throws {
        lock.lock(); defer { lock.unlock() }
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
    public func vectorSearch(_ embedding: [Float], topN: Int = Defaults.vectorTopN) throws -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        var scored: [(id: Int64, score: Double)] = []
        var mismatched = 0
        try query("SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL") { _ in
        } row: { statement in
            let id = sqlite3_column_int64(statement, 0)
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            guard byteCount > 0, let pointer = sqlite3_column_blob(statement, 1) else { return }
            let data = Data(bytes: pointer, count: byteCount)
            let stored = Self.floats(from: data)
            guard stored.count == embedding.count else {
                mismatched += 1
                return
            }
            scored.append((id, Self.cosine(embedding, stored)))
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

    /// Loads chunks with their email metadata, preserving the input id order
    /// (fused rank must survive the round trip; contract §3).
    public func chunks(ids: [Int64]) throws -> [ContextChunk] {
        guard !ids.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var byID: [Int64: ContextChunk] = [:]
        try query("""
        SELECT c.id, m.message_id, m.subject, m.sender, m.date_unix, c.source, c.text
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
                dateUnix: sqlite3_column_int64(statement, 4),
                source: ChunkSource(rawValue: column(statement, 5)) ?? .body,
                text: column(statement, 6)
            )
            byID[chunk.chunkID] = chunk
        }
        return ids.compactMap { byID[$0] }
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
        try run("DELETE FROM messages") { _ in }   // chunks cascade, FTS via trigger
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

    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}
