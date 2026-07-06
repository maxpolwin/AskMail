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

    let reference = Date(timeIntervalSince1970: 1_780_000_000)  // 2026-05-28 ~20:26 UTC (a Thursday)

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

    func testISODate() {
        let range = DateFilter.unixRange(question: "what emails did i get during on 2026-06-10?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_781_049_600...1_781_136_000 - 1)
    }

    func testDottedGermanDate() {
        let range = DateFilter.unixRange(question: "was bekam ich am 10.06.2026?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_781_049_600...1_781_136_000 - 1)
    }

    func testFirstWeekOfMonth() {
        let range = DateFilter.unixRange(question: "what emails did i get during the first week of June this year?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_780_272_000...1_780_876_800 - 1)  // June 1 - June 7 (exclusive end)
    }

    func testLastWeekOfMonth() {
        let range = DateFilter.unixRange(question: "what did I get the last week of June 2026?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_782_259_200...1_782_864_000 - 1)  // June 24 - June 30 (exclusive end)
    }

    // Reference is 2026-05-28. March has already happened this year: the
    // bare-month heuristic alone would already say "March 2026". "last year"
    // must override that to March 2025.
    func testMonthWithExplicitLastYear() {
        let range = DateFilter.unixRange(question: "the March newsletter last year", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_741_996_800))   // 2025-03-15
        XCTAssertFalse(range!.contains(1_773_532_800))  // 2026-03-15
    }

    // December hasn't happened yet this year: the bare-month heuristic alone
    // would say "December 2025". "this year" must override that to December 2026.
    func testMonthWithExplicitThisYear() {
        let range = DateFilter.unixRange(question: "the December summary this year", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_797_292_800))   // 2026-12-15
        XCTAssertFalse(range!.contains(1_765_756_800))  // 2025-12-15
    }

    func testBareThisYear() {
        let range = DateFilter.unixRange(question: "what emails did I get this year?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_767_225_600))    // 2026-01-01
        XCTAssertFalse(range!.contains(1_735_689_600))   // 2025-01-01
    }

    func testBareLastYear() {
        let range = DateFilter.unixRange(question: "what emails did I get last year?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_735_689_600))    // 2025-01-01
        XCTAssertFalse(range!.contains(1_767_225_600))   // 2026-01-01
    }

    func testGermanLastYearPhrase() {
        let range = DateFilter.unixRange(question: "was bekam ich im letzten Jahr?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_735_689_600))    // 2025-01-01
    }

    // Reference is 2026-05-28.
    func testPastFourMonths() {
        let range = DateFilter.unixRange(question: "what did I get over the past four months?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_773_532_800))    // 2026-03-15, inside the window
        XCTAssertFalse(range!.contains(1_761_955_200))   // 2025-11-01, before it
    }

    func testPast15Months() {
        let range = DateFilter.unixRange(question: "what did I get in the past 15 months?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_752_537_600))    // 2025-07-15, inside the window
        XCTAssertFalse(range!.contains(1_725_148_800))   // 2024-09-01, before it
    }

    // Multi-year window: must span across calendar-year boundaries, not just
    // scope to a single year.
    func testPastTwoYears() {
        let range = DateFilter.unixRange(question: "what emails came in over the past 2 years?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_719_792_000))    // 2024-07-01
        XCTAssertTrue(range!.contains(1_751_328_000))    // 2025-07-01
        XCTAssertFalse(range!.contains(1_685_577_600))   // 2023-06-01, before it
    }

    func testLastNMonthsAlsoWorks() {
        // "last" (not just "past") is accepted when a count is present.
        let range = DateFilter.unixRange(question: "the last 3 months", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_773_532_800))    // 2026-03-15
    }

    func testBareLastYearStillMeansCalendarYearNotRollingWindow() {
        // Regression guard: adding "past N units" parsing must not change the
        // already-shipped meaning of bare "last year" (the previous calendar
        // year), which is a distinct feature from a rolling 12-month window.
        let range = DateFilter.unixRange(question: "what emails did I get last year?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_735_689_600))    // 2025-01-01, would be excluded by a rolling window
    }

    // Reference is 2026-05-28, a Thursday.
    func testYesterday() {
        let range = DateFilter.unixRange(question: "what emails did I get yesterday?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_779_840_000...1_779_926_400 - 1)  // 2026-05-27
    }

    func testLastWeekday() {
        let range = DateFilter.unixRange(question: "what did I get last Tuesday?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_779_753_600...1_779_840_000 - 1)  // 2026-05-26
    }

    func testBareWeekdayMeansMostRecentPastOccurrence() {
        let range = DateFilter.unixRange(question: "anything from Tuesday?", now: reference)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_779_753_600...1_779_840_000 - 1)  // 2026-05-26
    }

    // Reproduces the reported bug: a question naming two distinct days must
    // scope to their combined span, not silently pick (or hallucinate) one.
    func testMultipleDistinctDaysUnionTheirSpan() {
        let range = DateFilter.unixRange(question: "emails i got yesterday? or last tuesday?",
                                         now: reference)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_779_753_600))     // last Tuesday 2026-05-26
        XCTAssertTrue(range!.contains(1_779_840_000))     // yesterday 2026-05-27
        XCTAssertFalse(range!.contains(1_779_667_200))    // Monday 2026-05-25, outside both
        XCTAssertFalse(range!.contains(1_779_926_400))    // today 2026-05-28, outside both
    }
}
