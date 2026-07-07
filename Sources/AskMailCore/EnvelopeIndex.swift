import Foundation
import SQLite3

/// One message row from the Apple Mail envelope index, dates already
/// converted from Cocoa epoch to Unix.
public struct EnvelopeMessage: Sendable {
    public var rowID: Int64
    public var subject: String
    public var sender: String
    public var dateReceivedUnix: Int64
}

/// Reads the Apple Mail SQLite envelope index. Opened strictly READ-ONLY:
/// writing (or even creating WAL files) risks forcing a multi-hour Mail
/// rebuild (SECURITY.md).
///
/// NOTE (spike B11 #1): the join below matches the commonly documented V10
/// schema (messages / subjects / addresses). Column names MUST be validated
/// against the real index on the target macOS version before first live run;
/// tests use a synthetic index with this schema.
public final class EnvelopeIndexReader {
    private let db: OpaquePointer

    public init(path: String = Defaults.envelopeIndexPath) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close(h) }
            throw StoreError.openFailed("envelope index at \(path): \(message)")
        }
        db = opened
    }

    deinit {
        sqlite3_close(db)
    }

    /// Messages received strictly after the watermark (Unix seconds), oldest
    /// first so the watermark can advance monotonically during ingestion.
    public func messages(newerThanUnix watermark: Int64) throws -> [EnvelopeMessage] {
        let sql = """
        SELECT m.ROWID,
               COALESCE(s.subject, ''),
               COALESCE(a.address, ''),
               COALESCE(a.comment, ''),
               m.date_received
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        WHERE m.date_received + \(Defaults.cocoaEpochOffset) > ?
        ORDER BY m.date_received ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_int64(prepared, 1, watermark)

        var results: [EnvelopeMessage] = []
        while true {
            let status = sqlite3_step(prepared)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
            let address = text(prepared, 2)
            let comment = text(prepared, 3)
            let sender = comment.isEmpty ? address : "\(comment) <\(address)>"
            results.append(EnvelopeMessage(
                rowID: sqlite3_column_int64(prepared, 0),
                subject: text(prepared, 1),
                sender: sender,
                dateReceivedUnix: sqlite3_column_int64(prepared, 4) + Defaults.cocoaEpochOffset
            ))
        }
        return results
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }
}

/// One .emlx file on disk with the identity and change-fingerprint used to
/// decide whether it still needs (re-)ingesting.
public struct EmlxFile: Sendable {
    /// Envelope-index ROWID parsed from the filename; stable across re-syncs.
    public var sourceID: Int64
    public var url: URL
    /// Cheap change signal (modification time + size). When Mail rewrites the
    /// file — e.g. a `.partial` becomes fully downloaded — this changes, so the
    /// message is re-ingested; otherwise it is skipped.
    public var fingerprint: String

    public init(sourceID: Int64, url: URL, fingerprint: String) {
        self.sourceID = sourceID
        self.url = url
        self.fingerprint = fingerprint
    }
}

/// Locates .emlx files for envelope-index row ids under an account directory.
/// Apple Mail stores them as `<ROWID>.emlx` or `<ROWID>.partial.emlx` in
/// nested `Messages` directories.
public enum EmlxLocator {

    /// Apple Mail mailbox folders whose messages are vectorized. Deliberately
    /// limited to live Inbox and Sent: Trash, Junk/Spam, Archive, and Drafts are
    /// excluded so deleted, spam, archived, and unsent mail never enter the
    /// searchable index (user decision 2026-07-06 — on one account Trash alone
    /// held ~90% of the on-disk .emlx files). Compared case-insensitively against
    /// the top-level `.mbox` folder name; common provider spellings of "Sent" are
    /// included for non-Posteo IMAP/Exchange accounts.
    static let indexedMailboxNames: Set<String> = [
        "inbox", "sent", "sent messages", "sent items",
    ]

    /// The top-level Apple Mail mailbox for a message file: the first path
    /// component ending in `.mbox`, e.g. "INBOX" for
    /// `…/<account>/INBOX.mbox/<uuid>/Data/…/Messages/1.emlx`. Submailboxes nest
    /// (`Archive.mbox/2023.mbox/…`), so the first `.mbox` component is always the
    /// account's top-level folder. Returns nil for a file under no `.mbox` folder.
    /// `public` (unlike `isIndexed`/`indexedMailboxNames`): Draft-Modus
    /// (`Sources/AskMailApp`) needs a *stricter* inbox-only filter than
    /// `indexedMailboxNames` (which also allows Sent) — a reply is never
    /// drafted for the user's own outgoing mail.
    public static func topLevelMailbox(of file: URL) -> String? {
        for component in file.pathComponents where component.hasSuffix(".mbox") {
            return String(component.dropLast(5))  // drop ".mbox"
        }
        return nil
    }

    /// Whether a message file lives in a mailbox we vectorize (Inbox or Sent).
    /// Files under Trash, Junk, Archive, or Drafts are skipped.
    static func isIndexed(_ file: URL) -> Bool {
        guard let mailbox = topLevelMailbox(of: file) else { return false }
        return indexedMailboxNames.contains(mailbox.lowercased())
    }

    /// Scans the account tree once, returning one entry per message ROWID with a
    /// change fingerprint. Prefers a fully-downloaded file over its `.partial`
    /// sibling when both are present for the same ROWID.
    public static func scan(accountDirectory: URL) -> [EmlxFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var byID: [Int64: EmlxFile] = [:]
        let enumerator = FileManager.default.enumerator(
            at: accountDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            guard name.hasSuffix(".emlx") else { continue }
            // Only Inbox and Sent are vectorized; skip Trash/Junk/Archive/Drafts.
            guard isIndexed(item) else { continue }
            let isPartial = name.hasSuffix(".partial.emlx")
            let stem = name
                .replacingOccurrences(of: ".partial.emlx", with: "")
                .replacingOccurrences(of: ".emlx", with: "")
            guard let sourceID = Int64(stem) else { continue }
            // A full file wins over an already-recorded partial for the same id.
            if isPartial, byID[sourceID] != nil { continue }
            let values = try? item.resourceValues(forKeys: Set(keys))
            let modTime = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let size = values?.fileSize ?? 0
            byID[sourceID] = EmlxFile(sourceID: sourceID, url: item,
                                      fingerprint: "\(modTime)-\(size)")
        }
        return Array(byID.values)
    }

    /// Scans once and returns a map ROWID -> file URL.
    /// A full file always wins over its `.partial` sibling for the same
    /// ROWID, regardless of enumeration order — mirrors `scan`'s dedup rule.
    /// (Draft-Modus's classification path reads whatever this returns
    /// directly, so a still-downloading partial file winning here — as an
    /// earlier version allowed — could mean classifying against a truncated
    /// body/missing headers.)
    public static func index(accountDirectory: URL) -> [Int64: URL] {
        var map: [Int64: URL] = [:]
        var isPartialByID: [Int64: Bool] = [:]
        let enumerator = FileManager.default.enumerator(
            at: accountDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            guard name.hasSuffix(".emlx") else { continue }
            let isPartial = name.hasSuffix(".partial.emlx")
            let stem = name
                .replacingOccurrences(of: ".partial.emlx", with: "")
                .replacingOccurrences(of: ".emlx", with: "")
            guard let rowID = Int64(stem) else { continue }
            // Already have a full file recorded for this ROWID: never let a
            // partial overwrite it, whichever order the enumerator visits them.
            if isPartial, isPartialByID[rowID] == false { continue }
            map[rowID] = item
            isPartialByID[rowID] = isPartial
        }
        return map
    }

    /// Whether `accountDirectory` holds at least one message, short-circuiting
    /// on the first match rather than walking the whole tree like `index`.
    /// Used to hide empty pseudo-accounts (e.g. "On My Mac") from the account
    /// picker without excluding a real account that simply hasn't synced yet.
    public static func hasAnyMessages(in accountDirectory: URL) -> Bool {
        let enumerator = FileManager.default.enumerator(
            at: accountDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent.hasSuffix(".emlx") { return true }
        }
        return false
    }
}
