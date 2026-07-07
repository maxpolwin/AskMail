import XCTest
@testable import AskMailApp

/// `DraftEngine` itself is deliberately not unit-tested (matches
/// `Vectorizer`'s own precedent — see `DraftEngine.swift`'s doc comment).
/// `concurrency(for:isOnACPower:allowOnBattery:)` is the one piece of its
/// logic pulled out into a pure, testable function, specifically because a
/// review found a real bug in it (the battery throttle silently applying to
/// `.manual` too, contradicting the documented bypass intent).
final class DraftEngineTests: XCTestCase {

    func testManualTriggerAlwaysGetsFullConcurrencyRegardlessOfBattery() {
        XCTAssertEqual(DraftEngine.concurrency(for: .manual, isOnACPower: true, allowOnBattery: false), 2)
        XCTAssertEqual(DraftEngine.concurrency(for: .manual, isOnACPower: false, allowOnBattery: false), 2,
                       "manual must bypass the battery throttle the same way it bypasses the battery skip")
        XCTAssertEqual(DraftEngine.concurrency(for: .manual, isOnACPower: false, allowOnBattery: true), 2)
    }

    func testScheduledTriggersGetFullConcurrencyOnACPower() {
        for trigger: DraftEngine.Trigger in [.timer, .fsevents, .launch, .wake] {
            XCTAssertEqual(DraftEngine.concurrency(for: trigger, isOnACPower: true, allowOnBattery: false), 2)
        }
    }

    func testScheduledTriggersOnBatteryRespectDraftAllowOnBattery() {
        XCTAssertEqual(DraftEngine.concurrency(for: .timer, isOnACPower: false, allowOnBattery: false), 0)
        XCTAssertEqual(DraftEngine.concurrency(for: .timer, isOnACPower: false, allowOnBattery: true), 1)
    }
}
