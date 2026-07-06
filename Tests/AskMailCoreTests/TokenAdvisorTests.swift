import XCTest
@testable import AskMailCore

final class TokenAdvisorTests: XCTestCase {
    let gb: UInt64 = 1_073_741_824

    func testCloudIgnoresRAM() {
        let r = TokenAdvisor.recommend(isLocal: false, modelSizeMB: 4700,
                                       physicalMemoryBytes: 8 * gb)
        XCTAssertEqual(r.contextTokens, 8192)
        XCTAssertEqual(r.answerTokens, 1000)
    }

    func testLowRAMClampsToFloor() {
        // 8 GB with a 4.7 GB model leaves almost nothing for the KV cache.
        let r = TokenAdvisor.recommend(isLocal: true, modelSizeMB: 4700,
                                       physicalMemoryBytes: 8 * gb)
        XCTAssertEqual(r.contextTokens, 2048)
        XCTAssertEqual(r.answerTokens, 800)
    }

    func testMoreRAMGivesMoreContext() {
        let small = TokenAdvisor.recommend(isLocal: true, modelSizeMB: 4700,
                                           physicalMemoryBytes: 16 * gb)
        let big = TokenAdvisor.recommend(isLocal: true, modelSizeMB: 4700,
                                         physicalMemoryBytes: 64 * gb)
        XCTAssertGreaterThan(small.contextTokens, 2048)
        XCTAssertGreaterThan(big.contextTokens, small.contextTokens)
        XCTAssertEqual(big.contextTokens, 16384)  // clamps to the ceiling
    }

    func testLargerModelLeavesLessContext() {
        let light = TokenAdvisor.recommend(isLocal: true, modelSizeMB: 2000,
                                           physicalMemoryBytes: 16 * gb)
        let heavy = TokenAdvisor.recommend(isLocal: true, modelSizeMB: 9000,
                                           physicalMemoryBytes: 16 * gb)
        XCTAssertGreaterThan(light.contextTokens, heavy.contextTokens)
    }

    func testRecommendationsLandOnStepperTicks() {
        let r = TokenAdvisor.recommend(isLocal: true, modelSizeMB: 2000,
                                       physicalMemoryBytes: 24 * gb)
        XCTAssertEqual(r.contextTokens % 512, 0)
        XCTAssertEqual(r.answerTokens % 100, 0)
    }
}
