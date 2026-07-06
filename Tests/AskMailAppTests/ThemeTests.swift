import XCTest
@testable import AskMailApp

final class ThemeTests: XCTestCase {
    func testDefaultHairlineOpacityUnchanged() {
        XCTAssertEqual(Theme.hairlineOpacity(highContrast: false), 0.14)
    }

    func testHighContrastOpacityIsStrongerThanDefault() {
        let normal = Theme.hairlineOpacity(highContrast: false)
        let high = Theme.hairlineOpacity(highContrast: true)
        XCTAssertGreaterThan(high, normal)
        // Increase Contrast should be a clear, not marginal, difference —
        // guards against a future "fix" that nudges this by a hair and
        // silently stops helping anyone.
        XCTAssertGreaterThanOrEqual(high, normal * 2)
    }
}
