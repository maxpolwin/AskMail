import XCTest
@testable import AskMailCore

/// Recommendations are grounded in the benchmark in docs/model-tuning.md: the
/// excerpt count follows model size, the context follows the excerpts, and the
/// memory cap follows the model's real architecture.
final class TokenAdvisorTests: XCTestCase {

    private let gb: Int64 = 1_000_000_000
    private let llama3b = ModelArchitecture(layers: 28, kvHeads: 8, keyLength: 128, valueLength: 128,
                                            maxContextTokens: 131_072)
    private let qwen14b = ModelArchitecture(layers: 48, kvHeads: 8, keyLength: 128, valueLength: 128,
                                            maxContextTokens: 32_768)

    func testSmallModelsGetFewerExcerptsAndRegularModelsMore() {
        let small = TokenAdvisor.recommendLocal(parameterBillions: 3.2, memory: nil)
        let regular = TokenAdvisor.recommendLocal(parameterBillions: 7.6, memory: nil)
        XCTAssertEqual(small.excerpts, 8)
        XCTAssertEqual(regular.excerpts, 13)
        XCTAssertGreaterThan(regular.contextTokens, small.contextTokens)
        XCTAssertTrue(small.rationale.contains("Small models"))
    }

    func testContextFollowsTheExcerptsWithHeadroomOnAStepperTick() {
        let r = TokenAdvisor.recommendLocal(parameterBillions: 7.6, memory: nil, tokensPerExcerpt: 500)
        // 13 x 500 x 1.25 = 8125, rounded up to the next 512.
        XCTAssertEqual(r.contextTokens, 8192)
        XCTAssertEqual(r.contextTokens % 512, 0)
        XCTAssertEqual(r.answerTokens, 1000)
    }

    func testUnknownModelSizeUsesTheDefaultExcerpts() {
        let r = TokenAdvisor.recommendLocal(parameterBillions: nil, memory: nil)
        XCTAssertEqual(r.excerpts, Defaults.finalTopK)
        XCTAssertEqual(TokenAdvisor.firstRun(), r)
    }

    func testMemoryCapLowersTheContextOnlyWhenTheModelWouldNotFit() {
        // 14B weights (9 GB) on a Mac that lets the GPU use 12 GB: little room for a window.
        let tight = ModelMemory(weightsBytes: 9 * gb, architecture: qwen14b, gpuLimitBytes: 12 * gb)
        let capped = TokenAdvisor.recommendLocal(parameterBillions: 14.8, memory: tight)
        XCTAssertLessThan(capped.contextTokens, 8192)
        XCTAssertTrue(capped.rationale.contains("what this Mac can hold"))
        // The capped recommendation itself never triggers the memory warning.
        let budget = ContextBudget(excerpts: capped.excerpts, contextTokens: capped.contextTokens,
                                   answerTokens: capped.answerTokens, memory: tight)
        if case .aboveMemory = budget.status { XCTFail("the recommendation must fit its own memory") }

        // The same model on the user's 24 GB M2 (17.76 GiB for the GPU) is not capped.
        let roomy = ModelMemory(weightsBytes: 9 * gb, architecture: qwen14b, gpuLimitBytes: 19_070_000_000)
        let free = TokenAdvisor.recommendLocal(parameterBillions: 14.8, memory: roomy)
        XCTAssertFalse(free.rationale.contains("what this Mac can hold"))
    }

    func testRecommendationNeverExceedsTheModelsOwnWindow() {
        let shortWindow = ModelArchitecture(layers: 28, kvHeads: 8, keyLength: 128, valueLength: 128,
                                            maxContextTokens: 4096)
        let memory = ModelMemory(weightsBytes: 2 * gb, architecture: shortWindow, gpuLimitBytes: 19 * gb)
        let r = TokenAdvisor.recommendLocal(parameterBillions: 3.2, memory: memory)
        XCTAssertLessThanOrEqual(r.contextTokens + r.answerTokens + Defaults.promptScaffoldTokens, 4096)
    }

    func testCloudRecommendationIgnoresMemory() {
        let r = TokenAdvisor.recommendCloud()
        XCTAssertEqual(r.excerpts, 13)
        XCTAssertEqual(r.contextTokens, 9216, "13 x 550 x 1.25 = 8937, rounded up to 512")
    }

    func testEveryRecommendationStaysInsideTheSelectableRanges() {
        for billions in [0.5, 3.2, 7.6, 14.8, 70, nil] {
            for memory in [nil, ModelMemory(weightsBytes: 2 * gb, architecture: llama3b, gpuLimitBytes: 19 * gb)] {
                let r = TokenAdvisor.recommendLocal(parameterBillions: billions, memory: memory)
                XCTAssertTrue(Defaults.contextTokenRange.contains(r.contextTokens))
                XCTAssertTrue(Defaults.answerTokenRange.contains(r.answerTokens))
                XCTAssertTrue(Defaults.excerptRange.contains(r.excerpts))
            }
        }
    }
}
