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

/// Locates .emlx files for envelope-index row ids under an account directory.
/// Apple Mail stores them as `<ROWID>.emlx` or `<ROWID>.partial.emlx` in
/// nested `Messages` directories.
public enum EmlxLocator {

    /// Scans once and returns a map ROWID -> file URL.
    public static func index(accountDirectory: URL) -> [Int64: URL] {
        var map: [Int64: URL] = [:]
        let enumerator = FileManager.default.enumerator(
            at: accountDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            guard name.hasSuffix(".emlx") else { continue }
            let stem = name
                .replacingOccurrences(of: ".partial.emlx", with: "")
                .replacingOccurrences(of: ".emlx", with: "")
            if let rowID = Int64(stem) {
                map[rowID] = item
            }
        }
        return map
    }
}
