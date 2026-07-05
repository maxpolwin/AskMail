import XCTest
@testable import AskMailCore

final class FusionTests: XCTestCase {

    func testRRFRewardsAgreement() {
        // Chunk 3 appears high in both lists and must win.
        let fused = Fusion.reciprocalRankFusion([[1, 3, 5], [3, 2, 1]])
        XCTAssertEqual(fused.first?.id, 3)
        let ids = fused.map(\.id)
        XCTAssertEqual(Set(ids), Set([1, 2, 3, 5]))
    }

    func testRRFScoresMatchDefinition() {
        let fused = Fusion.reciprocalRankFusion([[7], [7]], k: 60)
        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused[0].score, 2.0 / 61.0, accuracy: 1e-12)
    }

    func testEmptyRankings() {
        let fused = Fusion.reciprocalRankFusion([[], []] as [[Int]])
        XCTAssertTrue(fused.isEmpty)
    }
}

final class ChunkerTests: XCTestCase {

    func testShortTextSingleChunk() {
        let chunker = Chunker()
        XCTAssertEqual(chunker.chunk("Hello world."), ["Hello world."])
        XCTAssertEqual(chunker.chunk("   \n "), [])
    }

    func testLongTextOverlaps() {
        let chunker = Chunker(chunkChars: 200, overlapChars: 40)
        let paragraphs = (1...20).map { "Paragraph \($0) with some words in it." }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = chunker.chunk(text)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 200)
            XCTAssertFalse(chunk.isEmpty)
        }
        // Every paragraph must survive somewhere (overlap may duplicate; loss may not).
        for paragraph in paragraphs {
            XCTAssertTrue(chunks.contains { $0.contains(paragraph) },
                          "lost content: \(paragraph)")
        }
    }
}

final class StoreTests: XCTestCase {

    func makePopulatedStore() throws -> SQLiteStore {
        let store = try SQLiteStore.inMemory()
        let pk1 = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "Invoice",
                                          sender: "billing@acme.example", dateUnix: 1_770_291_000)
        try store.replaceChunks(messagePk: pk1, chunks: [
            (.body, "Please find attached invoice INV-2026-0473. Total due 1,340.00 EUR.", [1, 0, 0]),
            (.pdf, "Invoice total: 1,340.00 EUR. Payment due within 30 days.", [0.9, 0.1, 0]),
        ])
        let pk2 = try store.upsertMessage(messageID: "b@x", account: "acc", subject: "Webinar",
                                          sender: "events@acme.example", dateUnix: 1_772_439_240)
        try store.replaceChunks(messagePk: pk2, chunks: [
            (.body, "The pricing webinar moved to April 9 at 15:00 CET.", [0, 1, 0]),
        ])
        return store
    }

    func testKeywordSearchExactToken() throws {
        let store = try makePopulatedStore()
        let hits = try store.chunks(ids: store.keywordSearch("INV-2026-0473"))
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.messageID == "a@x" })
    }

    func testKeywordSearchSurvivesQuotesInQuery() throws {
        let store = try makePopulatedStore()
        // FTS5 syntax characters in user input must not break or inject.
        XCTAssertNoThrow(try store.keywordSearch("\"webinar\" AND (pricing OR *"))
        let hits = try store.keywordSearch("\"webinar\" AND (pricing OR *")
        XCTAssertFalse(hits.isEmpty)
    }

    func testVectorSearchRanksByCosine() throws {
        let store = try makePopulatedStore()
        let ids = try store.vectorSearch([1, 0, 0], topN: 2)
        let chunks = try store.chunks(ids: ids)
        XCTAssertEqual(chunks.first?.text.contains("INV-2026-0473"), true)
    }

    func testChunksPreservesInputOrder() throws {
        let store = try makePopulatedStore()
        let all = try store.keywordSearch("invoice webinar EUR pricing")
        let reversed = Array(all.reversed())
        XCTAssertEqual(try store.chunks(ids: reversed).map(\.chunkID), reversed)
    }

    func testWatermarkRoundTrip() throws {
        let store = try SQLiteStore.inMemory()
        XCTAssertNil(try store.watermark())
        try store.setWatermark(1_772_439_240)
        XCTAssertEqual(try store.watermark(), 1_772_439_240)
    }

    func testDeleteAllResetsEverything() throws {
        let store = try makePopulatedStore()
        try store.setWatermark(123)
        try store.deleteAll()
        XCTAssertEqual(try store.messageCount(), 0)
        XCTAssertEqual(try store.chunkCount(), 0)
        XCTAssertNil(try store.watermark(), "FR-8: watermark must reset")
        XCTAssertTrue(try store.keywordSearch("invoice").isEmpty, "FTS must be empty too")
    }

    func testUpsertUpdatesInsteadOfDuplicating() throws {
        let store = try SQLiteStore.inMemory()
        try store.upsertMessage(messageID: "a@x", account: "acc", subject: "Old",
                                sender: "s", dateUnix: 1)
        try store.upsertMessage(messageID: "a@x", account: "acc", subject: "New",
                                sender: "s", dateUnix: 2)
        XCTAssertEqual(try store.messageCount(), 1)
    }
}

final class DateFilterTests: XCTestCase {

    let reference = Date(timeIntervalSince1970: 1_780_000_000)  // 2026-05-29 UTC

    func testExplicitMonthAndYear() {
        let range = DateFilter.unixRange(question: "What was the February 2026 newsletter highlight?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_770_291_000))   // 2026-02-05
        XCTAssertFalse(range!.contains(1_772_439_240))  // 2026-03-02
    }

    func testGermanMonthName() {
        let range = DateFilter.unixRange(question: "Was war das Highlight im Februar 2026?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_770_291_000))
    }

    func testBareMonthResolvesToMostRecentPast() {
        // Asking in May 2026 about "February" means February 2026.
        let range = DateFilter.unixRange(question: "the February newsletter", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_770_291_000))
        // Asking about "December" means December 2025.
        let december = DateFilter.unixRange(question: "the December summary", now: reference)
        XCTAssertNotNil(december)
        XCTAssertTrue(december!.contains(1_765_000_000))  // 2025-12-06
    }

    func testNoDateMention() {
        XCTAssertNil(DateFilter.unixRange(question: "What did the vendor say about pricing?",
                                          now: reference))
    }
}
