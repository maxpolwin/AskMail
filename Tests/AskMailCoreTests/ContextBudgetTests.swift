import XCTest
@testable import AskMailCore

/// The arithmetic behind the Settings budget panel, the clamps that bound the
/// user's choices, and the sampled chunk size that feeds the per-excerpt figure.
final class ContextBudgetTests: XCTestCase {

    private func budget(excerpts: Int = 8, context: Int = 16384, answer: Int = 1000,
                        perExcerpt: Int = 550, memory: Double? = nil, server: Int? = nil) -> ContextBudget {
        ContextBudget(excerpts: excerpts, contextTokens: context, answerTokens: answer,
                      tokensPerExcerpt: perExcerpt, availableMemoryGB: memory,
                      serverWindowTokens: server)
    }

    func testSegmentsAddUpToTheWindow() {
        let b = budget()
        XCTAssertEqual(b.promptTokens, Defaults.promptScaffoldTokens)
        XCTAssertEqual(b.emailUsedTokens, 8 * 550)
        XCTAssertEqual(b.emailUnusedTokens, 16384 - 8 * 550)
        XCTAssertEqual(b.answerTokens, 1000)
        XCTAssertEqual(b.windowTokens, 2048 + 16384 + 1000)
        XCTAssertEqual(b.emailUsedPercent, 27)
    }

    func testExcerptsBeyondTheBudgetAreDroppedNotCounted() {
        let b = budget(excerpts: 40, context: 4096)
        XCTAssertEqual(b.emailUsedTokens, 4096, "used is capped at the budget")
        XCTAssertEqual(b.emailUnusedTokens, 0)
        XCTAssertEqual(b.emailNeededTokens, 22000)
        XCTAssertEqual(b.status, .needsMoreBudget(neededTokens: 22000))
    }

    func testStatusDecisionTable() {
        XCTAssertEqual(budget(excerpts: 8, context: 5000).status, .fits)
        XCTAssertEqual(budget(excerpts: 8, context: 16384).status, .mostlyUnused(percentUsed: 27))
        // Memory outranks a loose budget: 19.4k tokens ~ 19.4 GB against 10 GB free.
        guard case .aboveMemory = budget(memory: 10).status else { return XCTFail("expected aboveMemory") }
        XCTAssertEqual(budget(excerpts: 8, context: 5000, memory: 19).status, .fits)
        // A server window smaller than the request outranks everything.
        XCTAssertEqual(budget(memory: 100, server: 8192).status, .aboveServerWindow(serverTokens: 8192))
        XCTAssertEqual(budget(excerpts: 8, context: 5000, server: 32768).status, .fits)
    }

    func testMemoryEstimateOnlyWhenAFigureApplies() {
        XCTAssertNil(budget().estimatedMemoryGB, "cloud/server providers have no memory figure")
        XCTAssertEqual(try XCTUnwrap(budget(memory: 19).estimatedMemoryGB), 19.432, accuracy: 0.001)
    }

    func testNegativeInputsNeverProduceNegativeSegments() {
        let b = budget(excerpts: -3, context: -5, answer: -1)
        XCTAssertEqual(b.emailUsedTokens, 0)
        XCTAssertEqual(b.emailUnusedTokens, 0)
        XCTAssertEqual(b.answerTokens, 0)
    }

    func testTokensPerExcerptFromTheIndex() {
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: nil),
                       Defaults.fallbackTokensPerExcerpt)
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: 0),
                       Defaults.fallbackTokensPerExcerpt)
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: 2048), 512 + 40)
        XCTAssertEqual(ContextBudget.tokensPerExcerpt(averageChunkChars: 400), 100 + 40)
    }

    func testFallbackMatchesAFullChunk() {
        XCTAssertEqual(Defaults.fallbackTokensPerExcerpt,
                       (Defaults.chunkChars + 3) / 4 + Defaults.excerptOverheadTokens - 2,
                       "the fallback is a full chunk plus overhead, rounded")
    }

    // MARK: Clamps and ranges

    func testClampBoundsEveryBudgetValue() {
        XCTAssertEqual(Defaults.clamp(-5, to: Defaults.contextTokenRange), 512)
        XCTAssertEqual(Defaults.clamp(10_000_000, to: Defaults.contextTokenRange), 131_072)
        XCTAssertEqual(Defaults.clamp(0, to: Defaults.excerptRange), 1)
        XCTAssertEqual(Defaults.clamp(500, to: Defaults.excerptRange), 40)
        XCTAssertEqual(Defaults.clamp(2000, to: Defaults.answerTokenRange), 2000)
    }

    func testRequestedWindowIsCappedEvenForOutOfRangeSettings() {
        var settings = QuerySettings()
        settings.contextTokenLimit = 16384
        settings.answerTokenLimit = 2000
        XCTAssertEqual(QueryService.contextWindow(for: settings), 16384 + 2000 + 2048)

        settings.contextTokenLimit = Int.max / 4
        settings.answerTokenLimit = Int.max / 4
        XCTAssertEqual(QueryService.contextWindow(for: settings), Defaults.maxContextWindow)

        settings.contextTokenLimit = -100
        settings.answerTokenLimit = -100
        XCTAssertEqual(QueryService.contextWindow(for: settings), Defaults.promptScaffoldTokens)
    }

    func testMaxWindowIsTheSumOfTheMaximums() {
        XCTAssertEqual(Defaults.maxContextWindow,
                       Defaults.contextTokenRange.upperBound + Defaults.answerTokenRange.upperBound
                           + Defaults.promptScaffoldTokens)
        XCTAssertLessThanOrEqual(Defaults.excerptRange.upperBound,
                                 Defaults.vectorTopN + Defaults.keywordTopN)
    }

    // MARK: Advisor

    func testAdvisorSharesTheMemoryFigureAndLiftsTheServerCap() {
        let gb: UInt64 = 1_073_741_824
        XCTAssertEqual(TokenAdvisor.availableMemoryGB(modelSizeMB: 2000, physicalMemoryBytes: 24 * gb),
                       19, accuracy: 0.001)
        XCTAssertEqual(TokenAdvisor.availableMemoryGB(modelSizeMB: 9000, physicalMemoryBytes: 8 * gb), 0)
        let big = TokenAdvisor.recommendLocalServer(serverContextTokens: 65_536)
        XCTAssertGreaterThan(big.contextTokens, 16384, "a large server window is no longer capped at 16k")
        XCTAssertLessThanOrEqual(big.contextTokens, Defaults.contextTokenRange.upperBound)
    }

    func testTheRecommendationNeverTriggersItsOwnMemoryWarning() {
        let gb: UInt64 = 1_073_741_824
        for (ram, modelMB) in [(UInt64(16), 4700), (24, 2000), (24, 9000), (32, 4700), (64, 4700)] {
            let physical = ram * gb
            let advice = TokenAdvisor.recommend(isLocal: true, modelSizeMB: modelMB,
                                                physicalMemoryBytes: physical)
            let b = ContextBudget(
                excerpts: Defaults.finalTopK, contextTokens: advice.contextTokens,
                answerTokens: advice.answerTokens,
                availableMemoryGB: TokenAdvisor.availableMemoryGB(modelSizeMB: modelMB,
                                                                  physicalMemoryBytes: physical))
            if case .aboveMemory = b.status {
                XCTFail("\(ram) GB / \(modelMB) MB: the recommended window must fit the memory it was derived from")
            }
        }
    }

    // MARK: Sampled chunk size

    func testAverageChunkCharsIsSampledAndNilWhenEmpty() throws {
        let store = try SQLiteStore.inMemory()
        XCTAssertNil(try store.averageChunkChars())
        let pk = try store.upsertMessage(messageID: "m@x", account: "a", subject: "s", sender: "x@y", dateUnix: 1)
        try store.replaceChunks(messagePk: pk, chunks: [
            (.body, String(repeating: "a", count: 100), nil),
            (.body, String(repeating: "b", count: 300), nil),
        ])
        XCTAssertEqual(try store.averageChunkChars(), 200)
        XCTAssertEqual(try store.averageChunkChars(sample: 1), 100, "only the sampled rows count")
    }
}
