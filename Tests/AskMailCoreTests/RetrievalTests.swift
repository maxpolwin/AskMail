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

    // Regression guard for the lock-hold reduction: scoring now happens after
    // the store's row copy is released, so this pins exact ordering, ties,
    // and the limit behavior stay byte-identical to the old in-lock scan.
    func testVectorSearchExactOrderingTiesAndLimit() throws {
        let store = try SQLiteStore.inMemory()
        let pk = try store.upsertMessage(messageID: "v@x", account: "acc", subject: "S",
                                         sender: "s@x", dateUnix: 1)
        try store.replaceChunks(messagePk: pk, chunks: [
            (.body, "exact match", [1, 0, 0]),      // cosine 1.0
            (.body, "tie a", [1, 1, 0]),             // cosine ~0.7071
            (.body, "tie b", [2, 2, 0]),             // same direction as tie a -> same cosine
            (.body, "orthogonal", [0, 1, 0]),        // cosine 0.0
            (.body, "opposite", [-1, 0, 0]),         // cosine -1.0
        ])
        let ids = try store.vectorSearch([1, 0, 0], topN: 10)
        let chunks = try store.chunks(ids: ids)
        // Exact match first, opposite last; the two ties keep their relative
        // insertion order (Swift's sort is stable) and both outrank orthogonal.
        XCTAssertEqual(chunks.map(\.text),
                       ["exact match", "tie a", "tie b", "orthogonal", "opposite"])

        let limited = try store.vectorSearch([1, 0, 0], topN: 2)
        let limitedChunks = try store.chunks(ids: limited)
        XCTAssertEqual(limitedChunks.map(\.text), ["exact match", "tie a"])
    }

    func testVectorSearchSkipsMismatchedDimensionRows() throws {
        let store = try SQLiteStore.inMemory()
        let pk = try store.upsertMessage(messageID: "m@x", account: "acc", subject: "S",
                                         sender: "s@x", dateUnix: 1)
        try store.replaceChunks(messagePk: pk, chunks: [
            (.body, "right dims", [1, 0, 0]),
            (.body, "wrong dims", [1, 0, 0, 0]),
        ])
        let ids = try store.vectorSearch([1, 0, 0], topN: 10)
        let chunks = try store.chunks(ids: ids)
        XCTAssertEqual(chunks.map(\.text), ["right dims"])
    }

    func testCosineMismatchedLengthReturnsZeroWithoutCrashing() {
        XCTAssertEqual(SQLiteStore.cosine([1, 0, 0], [1, 0]), 0)
        XCTAssertEqual(SQLiteStore.cosine([], []), 0)
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

    func testLatestThreadIDFindsMostRecentMatchingSender() throws {
        let store = try SQLiteStore.inMemory()
        _ = try store.upsertMessage(messageID: "old@x", account: "acc", subject: "Older",
                                    sender: "Max <max.polwin@posteo.de>", threadID: "thread-old",
                                    dateUnix: 1_000)
        _ = try store.upsertMessage(messageID: "new@x", account: "acc", subject: "Newer",
                                    sender: "Max <max.polwin@posteo.de>", threadID: "thread-new",
                                    dateUnix: 2_000)
        XCTAssertEqual(try store.latestThreadID(fromSenderAddress: "max.polwin@posteo.de"), "thread-new")
    }

    func testLatestThreadIDNeverFalsePositivesOnASubstringOfADifferentAddress() throws {
        let store = try SQLiteStore.inMemory()
        _ = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "S",
                                    sender: "jblacksmith@corp.com", threadID: "thread-1", dateUnix: 1_000)
        XCTAssertNil(try store.latestThreadID(fromSenderAddress: "smith@corp.com"))
    }

    func testLatestThreadIDReturnsNilWhenNoMessageMatches() throws {
        let store = try SQLiteStore.inMemory()
        XCTAssertNil(try store.latestThreadID(fromSenderAddress: "nobody@example.com"))
    }

    func testLatestThreadIDIgnoresMessagesWithoutAThreadID() throws {
        let store = try SQLiteStore.inMemory()
        _ = try store.upsertMessage(messageID: "a@x", account: "acc", subject: "S",
                                    sender: "max@example.com", threadID: nil, dateUnix: 1_000)
        XCTAssertNil(try store.latestThreadID(fromSenderAddress: "max@example.com"))
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
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_770_291_000))   // 2026-02-05
        XCTAssertFalse(range!.contains(1_772_439_240))  // 2026-03-02
    }

    func testGermanMonthName() {
        let range = DateFilter.unixRange(question: "Was war das Highlight im Februar 2026?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_770_291_000))
    }

    func testBareMonthResolvesToMostRecentPast() {
        // Asking in May 2026 about "February" means February 2026.
        let range = DateFilter.unixRange(question: "the February newsletter", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_770_291_000))
        // Asking about "December" means December 2025.
        let december = DateFilter.unixRange(question: "the December summary", now: reference, timeZone: .gmt)
        XCTAssertNotNil(december)
        XCTAssertTrue(december!.contains(1_765_000_000))  // 2025-12-06
    }

    func testNoDateMention() {
        XCTAssertNil(DateFilter.unixRange(question: "What did the vendor say about pricing?",
                                          now: reference, timeZone: .gmt))
    }

    func testISODate() {
        let range = DateFilter.unixRange(question: "what emails did i get during on 2026-06-10?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_781_049_600...1_781_136_000 - 1)
    }

    func testDottedGermanDate() {
        let range = DateFilter.unixRange(question: "was bekam ich am 10.06.2026?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_781_049_600...1_781_136_000 - 1)
    }

    func testFirstWeekOfMonth() {
        let range = DateFilter.unixRange(question: "what emails did i get during the first week of June this year?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_780_272_000...1_780_876_800 - 1)  // June 1 - June 7 (exclusive end)
    }

    func testLastWeekOfMonth() {
        let range = DateFilter.unixRange(question: "what did I get the last week of June 2026?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_782_259_200...1_782_864_000 - 1)  // June 24 - June 30 (exclusive end)
    }

    // Reference is 2026-05-28. March has already happened this year: the
    // bare-month heuristic alone would already say "March 2026". "last year"
    // must override that to March 2025.
    func testMonthWithExplicitLastYear() {
        let range = DateFilter.unixRange(question: "the March newsletter last year", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_741_996_800))   // 2025-03-15
        XCTAssertFalse(range!.contains(1_773_532_800))  // 2026-03-15
    }

    // December hasn't happened yet this year: the bare-month heuristic alone
    // would say "December 2025". "this year" must override that to December 2026.
    func testMonthWithExplicitThisYear() {
        let range = DateFilter.unixRange(question: "the December summary this year", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_797_292_800))   // 2026-12-15
        XCTAssertFalse(range!.contains(1_765_756_800))  // 2025-12-15
    }

    func testBareThisYear() {
        let range = DateFilter.unixRange(question: "what emails did I get this year?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_767_225_600))    // 2026-01-01
        XCTAssertFalse(range!.contains(1_735_689_600))   // 2025-01-01
    }

    func testBareLastYear() {
        let range = DateFilter.unixRange(question: "what emails did I get last year?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_735_689_600))    // 2025-01-01
        XCTAssertFalse(range!.contains(1_767_225_600))   // 2026-01-01
    }

    func testGermanLastYearPhrase() {
        let range = DateFilter.unixRange(question: "was bekam ich im letzten Jahr?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_735_689_600))    // 2025-01-01
    }

    // Reference is 2026-05-28.
    func testPastFourMonths() {
        let range = DateFilter.unixRange(question: "what did I get over the past four months?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_773_532_800))    // 2026-03-15, inside the window
        XCTAssertFalse(range!.contains(1_761_955_200))   // 2025-11-01, before it
    }

    func testPast15Months() {
        let range = DateFilter.unixRange(question: "what did I get in the past 15 months?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_752_537_600))    // 2025-07-15, inside the window
        XCTAssertFalse(range!.contains(1_725_148_800))   // 2024-09-01, before it
    }

    // Multi-year window: must span across calendar-year boundaries, not just
    // scope to a single year.
    func testPastTwoYears() {
        let range = DateFilter.unixRange(question: "what emails came in over the past 2 years?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_719_792_000))    // 2024-07-01
        XCTAssertTrue(range!.contains(1_751_328_000))    // 2025-07-01
        XCTAssertFalse(range!.contains(1_685_577_600))   // 2023-06-01, before it
    }

    func testLastNMonthsAlsoWorks() {
        // "last" (not just "past") is accepted when a count is present.
        let range = DateFilter.unixRange(question: "the last 3 months", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_773_532_800))    // 2026-03-15
    }

    func testBareLastYearStillMeansCalendarYearNotRollingWindow() {
        // Regression guard: adding "past N units" parsing must not change the
        // already-shipped meaning of bare "last year" (the previous calendar
        // year), which is a distinct feature from a rolling 12-month window.
        let range = DateFilter.unixRange(question: "what emails did I get last year?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_735_689_600))    // 2025-01-01, would be excluded by a rolling window
    }

    // Reference is 2026-05-28, a Thursday.
    func testYesterday() {
        let range = DateFilter.unixRange(question: "what emails did I get yesterday?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_779_840_000...1_779_926_400 - 1)  // 2026-05-27
    }

    func testLastWeekday() {
        let range = DateFilter.unixRange(question: "what did I get last Tuesday?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_779_753_600...1_779_840_000 - 1)  // 2026-05-26
    }

    func testBareWeekdayMeansMostRecentPastOccurrence() {
        let range = DateFilter.unixRange(question: "anything from Tuesday?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range, 1_779_753_600...1_779_840_000 - 1)  // 2026-05-26
    }

    // Reproduces the reported bug: a question naming two distinct days must
    // scope to their combined span, not silently pick (or hallucinate) one.
    func testMultipleDistinctDaysUnionTheirSpan() {
        let range = DateFilter.unixRange(question: "emails i got yesterday? or last tuesday?",
                                         now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_779_753_600))     // last Tuesday 2026-05-26
        XCTAssertTrue(range!.contains(1_779_840_000))     // yesterday 2026-05-27
        XCTAssertFalse(range!.contains(1_779_667_200))    // Monday 2026-05-25, outside both
        XCTAssertFalse(range!.contains(1_779_926_400))    // today 2026-05-28, outside both
    }

    // MARK: Time zone injection

    func testTodayUsesInjectedTimeZoneNotHardcodedUTC() {
        // 2026-05-29T02:00:00Z has already rolled to the next UTC day, but
        // is still 2026-05-28 evening in US Pacific time (PDT, UTC-7) --
        // proving the day boundary follows the injected zone, not a
        // hardcoded UTC assumption.
        let crossedMidnightUTC = Date(timeIntervalSince1970: 1_780_020_000)
        let pacific = TimeZone(identifier: "America/Los_Angeles")!

        let utcRange = DateFilter.unixRange(question: "what did I get today?", now: crossedMidnightUTC, timeZone: .gmt)
        XCTAssertEqual(utcRange, 1_780_012_800...1_780_099_200 - 1)  // UTC day: 2026-05-29

        let pacificRange = DateFilter.unixRange(question: "what did I get today?", now: crossedMidnightUTC, timeZone: pacific)
        XCTAssertEqual(pacificRange, 1_779_951_600...1_780_038_000 - 1)  // Pacific day: 2026-05-28
    }

    func testDefaultTimeZoneIsCurrentNotHardcodedUTC() {
        // Omitting timeZone must follow the device's own zone (the
        // production default), matching an explicit .current, not silently
        // falling back to UTC.
        let implicit = DateFilter.unixRange(question: "what did I get today?", now: reference)
        let explicit = DateFilter.unixRange(question: "what did I get today?", now: reference, timeZone: .current)
        XCTAssertEqual(implicit, explicit)
    }

    // MARK: Ambiguous numeric date formats

    func testSlashDateUnambiguousDayFirstResolves() {
        // 13 can't be a month, so "13/05/2026" is unambiguously 13 May 2026
        // even though it arrives via the MM/DD-shaped slash pattern.
        let range = DateFilter.unixRange(question: "what did I get on 13/05/2026?", now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_778_630_400...1_778_716_800 - 1)
    }

    func testAmbiguousSlashDateDoesNotGuessLocale() {
        // Both 03 and 04 could be a month: genuinely ambiguous between US
        // (March 4) and EU/UK (April 3) readings. Must not silently pick one.
        XCTAssertNil(DateFilter.unixRange(question: "what did I get on 03/04/2026?", now: reference, timeZone: .gmt))
    }

    func testAmbiguousSlashDateSwappedAlsoDoesNotGuess() {
        // Same ambiguity, operands swapped -- confirms no directional bias.
        XCTAssertNil(DateFilter.unixRange(question: "what did I get on 04/03/2026?", now: reference, timeZone: .gmt))
    }

    // MARK: Day-of-month next to a month name

    func testDayOfMonthWithOrdinalSuffix() {
        let range = DateFilter.unixRange(question: "what emails did I get on June 5th this year?",
                                         now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_780_617_600...1_780_704_000 - 1)  // 2026-06-05
    }

    func testDayOfMonthGermanDottedOrdinal() {
        // Bare month: June(6) > current month(5) at the reference, so the
        // most-recent-past-occurrence heuristic resolves to 2025.
        let range = DateFilter.unixRange(question: "was bekam ich am 5. Juni?", now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_749_081_600...1_749_168_000 - 1)  // 2025-06-05
    }

    func testDayOfMonthSeparatedFromMonthWord() {
        // "5th" and "june" are 2 tokens apart ("of" between them), within
        // the day-of-month scan's window but not directly adjacent.
        let range = DateFilter.unixRange(question: "the 5th of June, did I get anything?",
                                         now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_749_081_600...1_749_168_000 - 1)  // 2025-06-05, same bare-month year rollback
    }

    func testDayOfMonthDoesNotHijackWeekOfMonth() {
        // Regression guard: "1st" is both a valid ordinal-week word and a
        // valid bare day number. Once day-of-month matching runs ahead of
        // the week-of-month tier, "1st" adjacent to "june" must still
        // resolve to the whole first week, not day 1 alone.
        let range = DateFilter.unixRange(question: "the 1st week of June 2026", now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_780_272_000...1_780_876_800 - 1)  // June 1 - June 7, not just June 1
    }

    // MARK: Month+year tier union

    func testMonthUnionAcrossTwoMentions() {
        // "March or April" -- today only March was returned and April
        // silently dropped; both must now be covered.
        let range = DateFilter.unixRange(question: "did I get anything in March or April?",
                                         now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_772_323_200...1_777_593_600 - 1)  // March 1 - April 30, 2026
    }

    func testMonthUnionWithLastYearOverride() {
        let range = DateFilter.unixRange(question: "emails from November or December last year",
                                         now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_761_955_200...1_767_225_600 - 1)  // Nov 1 - Dec 31, 2025
    }

    // MARK: Open-ended ranges

    func testSinceExplicitDate() {
        let range = DateFilter.unixRange(question: "emails since 2026-05-01", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 1_777_593_600)   // 2026-05-01 start
        XCTAssertEqual(range?.upperBound, 1_780_012_799)   // end of the reference's own day
    }

    func testBeforeExplicitDate() {
        let range = DateFilter.unixRange(question: "everything before 2026-06-01", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 0)
        XCTAssertEqual(range?.upperBound, 1_780_358_400 - 1)  // up through the end of 2026-06-01
    }

    func testGermanSeitYesterday() {
        let range = DateFilter.unixRange(question: "was bekam ich seit gestern?", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 1_779_840_000)   // 2026-05-27 (yesterday) start
        XCTAssertEqual(range?.upperBound, 1_780_012_799)   // end of the reference's own day
    }

    func testGermanVorWithRelativeOffsetDoesNotMisfire() {
        // "vor 3 Tagen" ("3 days ago") is a relative offset, not "before a
        // date" -- deliberately out of scope (see the doc comment on
        // beforeTriggerWords). A bare number never resolves as an anchor,
        // so this must safely produce no match rather than misfire.
        XCTAssertNil(DateFilter.unixRange(question: "vor 3 Tagen", now: reference, timeZone: .gmt))
    }

    func testGermanVorNonTemporalUsageDoesNotMisfire() {
        // "vor" used in its ordinary non-temporal sense, with no resolvable
        // date anywhere in the question, must not spuriously trigger.
        XCTAssertNil(DateFilter.unixRange(question: "Ich habe Angst vor Spinnen", now: reference, timeZone: .gmt))
    }

    // MARK: Accepted tradeoff -- 3+ disjoint day mentions widen, not disjoint

    func testThreeDisjointDaysWidenRatherThanStayDisjoint() {
        // Documented tradeoff (see unixRange's tier-1 comment): 3+ disjoint
        // single-day mentions widen to a bounding span rather than staying a
        // disjoint set, so days never asked about (June 2-4, 6-9) get
        // silently included too. Pinned here so a future refactor doesn't
        // change this in a worse direction without noticing.
        let range = DateFilter.unixRange(question: "emails on 2026-06-01, 2026-06-05, or 2026-06-10",
                                         now: reference, timeZone: .gmt)
        XCTAssertEqual(range, 1_780_272_000...1_781_136_000 - 1)  // June 1 00:00 - June 10 23:59:59
        XCTAssertTrue(range!.contains(1_780_617_600))   // June 5, one of the 3 asked-about days
        XCTAssertTrue(range!.contains(1_780_704_000))   // June 6, NOT asked about but included anyway
    }

    // MARK: Calendar arithmetic edge cases

    func testPastMonthsClampsAtMonthEndInsteadOfRollingOver() {
        let dayThirtyOneNow = Date(timeIntervalSince1970: 1_774_958_400)  // 2026-03-31T12:00:00Z
        let range = DateFilter.unixRange(question: "what did I get in the past month?", now: dayThirtyOneNow, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.lowerBound, 1_772_236_800)  // 2026-02-28, clamped down, not rolled to Mar 3
    }

    func testPastYearFromLeapDayClampsToFeb28NotMarch1() {
        let leapDayNow = Date(timeIntervalSince1970: 1_835_431_200)  // 2028-02-29T10:00:00Z
        let range = DateFilter.unixRange(question: "what did I get in the past 12 months?", now: leapDayNow, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.lowerBound, 1_803_772_800)  // 2027-02-28, clamped down, not rolled to Mar 1
    }

    func testLastTuesdayCrossesYearBoundary() {
        let newYearsDay = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01T00:00:00Z, a Thursday
        let range = DateFilter.unixRange(question: "what did I get last Tuesday?", now: newYearsDay, timeZone: .gmt)
        XCTAssertEqual(range, 1_767_052_800...1_767_139_200 - 1)  // 2025-12-30, crossing month AND year
    }

    func testBareMonthEqualsCurrentMonthResolvesToThisYear() {
        // reference is 2026-05-28: naming "May" while May is the current,
        // in-progress month must resolve to May 2026, not May 2025 -- the
        // `month <= currentMonth` boundary at exact equality.
        let range = DateFilter.unixRange(question: "the May newsletter", now: reference, timeZone: .gmt)
        XCTAssertNotNil(range)
        XCTAssertTrue(range!.contains(1_780_000_000))  // the reference instant itself falls within May 2026
    }
}
