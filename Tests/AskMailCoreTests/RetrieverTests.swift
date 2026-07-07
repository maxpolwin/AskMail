import XCTest
@testable import AskMailCore

final class RetrieverTests: XCTestCase {

    func makeStore() throws -> SQLiteStore {
        let store = try SQLiteStore.inMemory()
        let pk1 = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "Invoice",
                                          sender: "billing@acme.example", dateUnix: 1)
        try store.replaceChunks(messagePk: pk1, chunks: [
            (.body, "Please find attached invoice INV-2026-0473.", [1, 0, 0]),
        ])
        let pk2 = try store.upsertMessage(messageID: "b@x", account: "acc", subject: "Webinar",
                                          sender: "events@acme.example", dateUnix: 2)
        try store.replaceChunks(messagePk: pk2, chunks: [
            (.body, "The pricing webinar moved to April 9.", [0, 1, 0]),
        ])
        return store
    }

    func testExcludingMessageIDsFiltersResults() throws {
        let store = try makeStore()
        let results = try Retriever.hybridRetrieve(embedding: [1, 0, 0], keywordQuery: "invoice webinar",
                                                   store: store, vectorTopN: 10, keywordTopN: 10,
                                                   relevanceFloor: -1, excludingMessageIDs: ["a@x"])
        XCTAssertFalse(results.contains { $0.messageID == "a@x" })
        XCTAssertTrue(results.contains { $0.messageID == "b@x" })
    }

    func testNoExclusionReturnsAllAboveFloor() throws {
        let store = try makeStore()
        let results = try Retriever.hybridRetrieve(embedding: [1, 0, 0], keywordQuery: "invoice webinar",
                                                   store: store, vectorTopN: 10, keywordTopN: 10,
                                                   relevanceFloor: -1)
        XCTAssertEqual(Set(results.map(\.messageID)), Set(["a@x", "b@x"]))
    }

    func testRelevanceFloorExcludesEverythingWhenSetTooHigh() throws {
        let store = try makeStore()
        let results = try Retriever.hybridRetrieve(embedding: [1, 0, 0], keywordQuery: "invoice webinar",
                                                   store: store, vectorTopN: 10, keywordTopN: 10,
                                                   relevanceFloor: 999)
        XCTAssertTrue(results.isEmpty)
    }

    func testScoresAttachedToReturnedChunks() throws {
        let store = try makeStore()
        let results = try Retriever.hybridRetrieve(embedding: [1, 0, 0], keywordQuery: "invoice",
                                                   store: store, vectorTopN: 10, keywordTopN: 10,
                                                   relevanceFloor: -1)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.score > 0 })
    }

    func testEmptyEmbeddingSkipsVectorSearchButKeywordStillWorks() throws {
        let store = try makeStore()
        let results = try Retriever.hybridRetrieve(embedding: [], keywordQuery: "invoice",
                                                   store: store, vectorTopN: 10, keywordTopN: 10,
                                                   relevanceFloor: -1)
        XCTAssertTrue(results.contains { $0.messageID == "a@x" })
    }
}
