import Foundation
import SQLite3

/// Where a drafted reply currently stands.
public enum DraftStatus: String, Sendable, Codable {
    case pending
    case drafting
    case ready
    case failed
    case skippedNewsletter = "skipped_newsletter"
}

public struct DraftRecord: Sendable, Equatable {
    public var pk: Int64
    public var threadID: String
    public var latestMessageID: String
    public var sender: String
    public var subject: String
    public var draftText: String
    public var generatedAt: Int64
    public var status: DraftStatus

    public init(pk: Int64, threadID: String, latestMessageID: String, sender: String, subject: String,
               draftText: String, generatedAt: Int64, status: DraftStatus) {
        self.pk = pk
        self.threadID = threadID
        self.latestMessageID = latestMessageID
        self.sender = sender
        self.subject = subject
        self.draftText = draftText
        self.generatedAt = generatedAt
        self.status = status
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The local database for Draft-Modus (`drafts.db`), physically decoupled
/// from `askmail.db` (`SQLiteStore`): deleting or rebuilding one never
/// touches the other, and drafted content is never commingled with the
/// read-only mail index. Locked down the same way (`FileHardening`).
///
/// `draft_jobs` and `style_profiles` are schema-only in Phase 1 — a later
/// phase's `DraftEngine`/`StyleLearner` are their only writers.
public final class DraftStore {
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
        try execute("PRAGMA busy_timeout=5000")
        try migrate()
        if path != ":memory:" {
            FileHardening.lockDown(fileURL: URL(fileURLWithPath: path))
        }
    }

    public static func inMemory() throws -> DraftStore {
        try DraftStore(path: ":memory:")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Schema

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS drafts(
          pk INTEGER PRIMARY KEY,
          thread_id TEXT NOT NULL,
          latest_message_id TEXT NOT NULL,
          sender TEXT NOT NULL,
          subject TEXT NOT NULL,
          draft_text TEXT NOT NULL,
          generated_at INTEGER NOT NULL,
          status TEXT NOT NULL
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_drafts_thread ON drafts(thread_id);")
        try execute("""
        CREATE TABLE IF NOT EXISTS draft_jobs(
          source_id INTEGER PRIMARY KEY,
          message_id TEXT,
          state TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          detected_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS style_profiles(
          scope TEXT PRIMARY KEY,
          profile_text TEXT NOT NULL,
          sample_count INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS meta(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
    }

    // MARK: Drafts

    @discardableResult
    public func insertDraft(threadID: String, latestMessageID: String, sender: String, subject: String,
                            draftText: String, generatedAt: Int64, status: DraftStatus) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try run("""
        INSERT INTO drafts(thread_id, latest_message_id, sender, subject, draft_text, generated_at, status)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            bind(statement, 1, threadID)
            bind(statement, 2, latestMessageID)
            bind(statement, 3, sender)
            bind(statement, 4, subject)
            bind(statement, 5, draftText)
            sqlite3_bind_int64(statement, 6, generatedAt)
            bind(statement, 7, status.rawValue)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// The most recently generated draft for a thread, if any (a thread may
    /// have several rows if the user regenerated — a later phase's concern).
    public func latestDraft(threadID: String) throws -> DraftRecord? {
        lock.lock(); defer { lock.unlock() }
        var result: DraftRecord?
        try query("""
        SELECT pk, thread_id, latest_message_id, sender, subject, draft_text, generated_at, status
        FROM drafts WHERE thread_id = ? ORDER BY generated_at DESC LIMIT 1
        """) { statement in
            bind(statement, 1, threadID)
        } row: { statement in
            result = DraftRecord(
                pk: sqlite3_column_int64(statement, 0),
                threadID: column(statement, 1),
                latestMessageID: column(statement, 2),
                sender: column(statement, 3),
                subject: column(statement, 4),
                draftText: column(statement, 5),
                generatedAt: sqlite3_column_int64(statement, 6),
                status: DraftStatus(rawValue: column(statement, 7)) ?? .pending
            )
        }
        return result
    }

    // MARK: SQLite plumbing (mirrors SQLiteStore.swift)

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
