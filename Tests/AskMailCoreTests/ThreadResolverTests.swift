import XCTest
@testable import AskMailCore

final class ThreadResolverTests: XCTestCase {

    /// Resolves and persists one message the same way `MailboxIngestor.ingest(email:)`
    /// does, returning the resolved thread id.
    @discardableResult
    func ingest(_ store: SQLiteStore, messageID: String, inReplyTo: String? = nil,
               references: [String] = [], dateUnix: Int64 = 1) throws -> String {
        let threadID = try ThreadResolver.resolveThread(messageID: messageID, inReplyTo: inReplyTo,
                                                         references: references, store: store)
        try store.upsertMessage(messageID: messageID, account: "acc", subject: "s", sender: "s@x",
                                inReplyTo: inReplyTo, referencesIDs: references, threadID: threadID,
                                bodyText: "body \(messageID)", dateUnix: dateUnix)
        return threadID
    }

    func testFreshMessageBecomesOwnRoot() throws {
        let store = try SQLiteStore.inMemory()
        let threadID = try ingest(store, messageID: "root@x")
        XCTAssertEqual(threadID, "root@x")
    }

    func testUnrelatedMessagesGetDistinctThreads() throws {
        let store = try SQLiteStore.inMemory()
        let a = try ingest(store, messageID: "a@x")
        let b = try ingest(store, messageID: "b@x")
        XCTAssertNotEqual(a, b)
    }

    func testReplyJoinsParentThreadViaInReplyTo() throws {
        let store = try SQLiteStore.inMemory()
        try ingest(store, messageID: "root@x")
        let childThread = try ingest(store, messageID: "child@x", inReplyTo: "root@x")
        XCTAssertEqual(childThread, "root@x")
    }

    func testReplyJoinsParentThreadViaReferencesWhenNoInReplyTo() throws {
        let store = try SQLiteStore.inMemory()
        try ingest(store, messageID: "root@x")
        let childThread = try ingest(store, messageID: "child@x", references: ["root@x"])
        XCTAssertEqual(childThread, "root@x")
    }

    // References are stored oldest-to-newest (RFC 5322 §3.6.4); the nearest
    // ancestor is checked first, but a message must still join the thread
    // when only an *older* reference resolves (the nearest one is unknown).
    func testFallsThroughToOlderReferenceWhenNearestIsUnknown() throws {
        let store = try SQLiteStore.inMemory()
        try ingest(store, messageID: "root@x")
        let leafThread = try ingest(store, messageID: "leaf@x",
                                   references: ["root@x", "missingParent@x"])
        XCTAssertEqual(leafThread, "root@x")
    }

    // Out-of-order arrival: a reply ingested before its own parent must still
    // end up in the same thread once the parent arrives (single-hop merge).
    func testOutOfOrderArrivalMerges() throws {
        let store = try SQLiteStore.inMemory()
        let childThread = try ingest(store, messageID: "child@x", inReplyTo: "root@x")
        XCTAssertEqual(childThread, "child@x", "no parent known yet: becomes its own root")

        let rootThread = try ingest(store, messageID: "root@x")
        XCTAssertEqual(rootThread, "root@x")

        let messages = try store.threadMessages(threadID: "root@x")
        XCTAssertEqual(Set(messages.map(\.messageID)), Set(["root@x", "child@x"]),
                      "child's thread must have been merged into root's once root arrived")
    }

    func testThreadMessagesOrderedOldestFirst() throws {
        let store = try SQLiteStore.inMemory()
        try ingest(store, messageID: "root@x", dateUnix: 1)
        try ingest(store, messageID: "mid@x", inReplyTo: "root@x", dateUnix: 2)
        try ingest(store, messageID: "leaf@x", inReplyTo: "mid@x", dateUnix: 3)

        let messages = try store.threadMessages(threadID: "root@x")
        XCTAssertEqual(messages.map(\.messageID), ["root@x", "mid@x", "leaf@x"])
    }

    func testThreadMessagesCapsAtLimitKeepingNewest() throws {
        let store = try SQLiteStore.inMemory()
        try ingest(store, messageID: "root@x", dateUnix: 0)
        var previous = "root@x"
        for index in 1...5 {
            let id = "m\(index)@x"
            try ingest(store, messageID: id, inReplyTo: previous, dateUnix: Int64(index))
            previous = id
        }
        let capped = try store.threadMessages(threadID: "root@x", limit: 3)
        XCTAssertEqual(capped.map(\.messageID), ["m3@x", "m4@x", "m5@x"])
    }
}
