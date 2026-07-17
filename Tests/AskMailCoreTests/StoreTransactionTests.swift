import SQLite3
import XCTest
@testable import AskMailCore

/// The `transaction {}` helper (bulk-ingest write batching) and the
/// `message_refs` reverse index that replaced the per-message full-table scan
/// in `candidateReferencers`.
final class StoreTransactionTests: XCTestCase {

    // MARK: transaction {}

    func testTransactionCommitsOnSuccess() throws {
        let store = try SQLiteStore.inMemory()
        try store.transaction {
            _ = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "s",
                                        sender: "s@x", dateUnix: 1)
        }
        XCTAssertEqual(try store.messageCount(), 1)
    }

    func testTransactionRollsBackOnThrow() throws {
        let store = try SQLiteStore.inMemory()
        struct Boom: Error {}
        XCTAssertThrowsError(try store.transaction {
            _ = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "s",
                                        sender: "s@x", dateUnix: 1)
            throw Boom()
        })
        XCTAssertEqual(try store.messageCount(), 0, "a thrown body must roll the whole transaction back")
    }

    func testNestedTransactionsMergeIntoOne() throws {
        let store = try SQLiteStore.inMemory()
        struct Boom: Error {}
        XCTAssertThrowsError(try store.transaction {
            // upsertMessage and replaceChunks open their own (nested)
            // transactions — the outer rollback must undo them too.
            let pk = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "s",
                                             sender: "s@x", dateUnix: 1)
            try store.replaceChunks(messagePk: pk, chunks: [(.body, "text", nil)])
            throw Boom()
        })
        XCTAssertEqual(try store.messageCount(), 0)
        XCTAssertEqual(try store.chunkCount(), 0)
    }

    // MARK: message_refs upkeep

    func testReUpsertReplacesStaleRefs() throws {
        let store = try SQLiteStore.inMemory()
        _ = try store.upsertMessage(messageID: "child@x", account: "acc", subject: "s", sender: "s@x",
                                    inReplyTo: "old-parent@x", threadID: "t", dateUnix: 1)
        // Mail rewrote the file and the reference changed; the reverse index
        // must follow the columns, not accumulate stale rows.
        _ = try store.upsertMessage(messageID: "child@x", account: "acc", subject: "s", sender: "s@x",
                                    inReplyTo: "new-parent@x", threadID: "t", dateUnix: 1)

        XCTAssertTrue(try store.candidateReferencers(referencingMessageID: "old-parent@x").isEmpty)
        XCTAssertEqual(try store.candidateReferencers(referencingMessageID: "new-parent@x").count, 1)
    }

    func testDeleteAllClearsRefs() throws {
        let store = try SQLiteStore.inMemory()
        _ = try store.upsertMessage(messageID: "child@x", account: "acc", subject: "s", sender: "s@x",
                                    inReplyTo: "parent@x", threadID: "t", dateUnix: 1)
        try store.deleteAll()
        XCTAssertTrue(try store.candidateReferencers(referencingMessageID: "parent@x").isEmpty)
    }

    // MARK: message_refs backfill (one-time migration)

    // Simulates upgrading a pre-message_refs database: build a store with
    // referencing messages, drop the refs table out from under it (as if it
    // never existed), and reopen — migrate must recreate AND backfill it so
    // candidateReferencers keeps seeing pre-upgrade messages.
    func testReopeningLegacyStoreBackfillsRefs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askmail-refs-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.db").path

        try autoreleasepool {
            let store = try SQLiteStore(path: path)
            _ = try store.upsertMessage(messageID: "reply@x", account: "acc", subject: "s", sender: "s@x",
                                        inReplyTo: "root@x", referencesIDs: ["grand@x", "root@x"],
                                        threadID: "root@x", dateUnix: 1)
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE message_refs", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try SQLiteStore(path: path)
        let byParent = try reopened.candidateReferencers(referencingMessageID: "root@x")
        XCTAssertEqual(byParent.count, 1)
        XCTAssertEqual(byParent.first?.inReplyTo, "root@x")
        let byAncestor = try reopened.candidateReferencers(referencingMessageID: "grand@x")
        XCTAssertEqual(byAncestor.count, 1)
    }
}
