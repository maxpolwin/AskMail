import XCTest
@testable import AskMailApp
@testable import AskMailCore

/// Covers two pieces carved out of `AskViewModel.submit`'s event loop so they
/// don't need a real `QueryService`/network stream to exercise: the
/// `StreamThrottle` publish gate (Task 1) and `AskViewModel.apply`'s
/// egress-state transitions (Task 2, H-11).
final class StreamThrottleTests: XCTestCase {

    // MARK: - StreamThrottle (pure)

    func testFirstCallAlwaysPublishes() {
        var throttle = StreamThrottle()
        XCTAssertTrue(throttle.shouldPublish(now: .now))
    }

    func testWithholdsWithinInterval() {
        var throttle = StreamThrottle()
        let t0 = ContinuousClock.now
        XCTAssertTrue(throttle.shouldPublish(now: t0))
        // Well inside the 100ms gate — every rapid token should be withheld.
        XCTAssertFalse(throttle.shouldPublish(now: t0.advanced(by: .milliseconds(10))))
        XCTAssertFalse(throttle.shouldPublish(now: t0.advanced(by: .milliseconds(99))))
    }

    func testPublishesAgainOnceIntervalElapses() {
        var throttle = StreamThrottle()
        let t0 = ContinuousClock.now
        XCTAssertTrue(throttle.shouldPublish(now: t0))
        XCTAssertTrue(throttle.shouldPublish(now: t0.advanced(by: .milliseconds(150))))
    }

    func testMarkPublishedMovesTheGateWithoutCheckingInterval() {
        var throttle = StreamThrottle()
        let t0 = ContinuousClock.now
        throttle.markPublished(now: t0)
        // The gate now measures from t0, exactly as if shouldPublish had
        // returned true at t0 — a token 10ms later is still withheld...
        XCTAssertFalse(throttle.shouldPublish(now: t0.advanced(by: .milliseconds(10))))
        // ...but one past the interval publishes again.
        XCTAssertTrue(throttle.shouldPublish(now: t0.advanced(by: .milliseconds(200))))
    }

    func testResetMakesTheNextCallPublishImmediately() {
        var throttle = StreamThrottle()
        let t0 = ContinuousClock.now
        XCTAssertTrue(throttle.shouldPublish(now: t0))
        throttle.reset()
        // Without reset this would be withheld (well inside the interval).
        XCTAssertTrue(throttle.shouldPublish(now: t0.advanced(by: .milliseconds(5))))
    }

    // MARK: - AskViewModel.apply: throttled token publishing

    @MainActor
    func testApplyWithholdsRapidTokenPublishesButAlwaysAccumulatesRaw() {
        let model = AskViewModel()
        var raw = ""
        model.apply(.token("Hel"), raw: &raw)
        XCTAssertEqual(raw, "Hel")
        XCTAssertEqual(model.answer, "Hel")  // first token always publishes

        model.apply(.token("lo"), raw: &raw)
        XCTAssertEqual(raw, "Hello")               // raw always accumulates
        XCTAssertEqual(model.answer, "Hel")        // but the second publish is withheld
    }

    @MainActor
    func testApplyDoneAlwaysFlushesRawEvenIfThrottleWithheldIt() {
        let model = AskViewModel()
        var raw = ""
        model.apply(.token("Hel"), raw: &raw)
        model.apply(.token("lo"), raw: &raw)       // withheld per the test above
        XCTAssertEqual(model.answer, "Hel")

        model.apply(.done, raw: &raw)
        XCTAssertEqual(model.answer, "Hello")      // unconditional final flush
    }

    @MainActor
    func testApplyFallbackClearsRawAnswerAndSetsWarning() {
        let model = AskViewModel()
        var raw = "partial"
        model.answer = "partial"
        model.apply(.fallback(provider: "ollama", error: "timed out"), raw: &raw)
        XCTAssertEqual(raw, "")
        XCTAssertEqual(model.answer, "")
        XCTAssertEqual(model.warning, "Cloud provider failed; answered by ollama instead.")
    }

    // MARK: - AskViewModel.apply: H-11 egress indicator

    @MainActor
    func testApplyEgressSetsHostWithoutTouchingAnswer() {
        let model = AskViewModel()
        var raw = "so far"
        XCTAssertNil(model.egressHost)
        model.apply(.egress(host: "api.anthropic.com"), raw: &raw)
        XCTAssertEqual(model.egressHost, "api.anthropic.com")
        XCTAssertEqual(raw, "so far")  // egress doesn't touch the streamed text
    }

    @MainActor
    func testEgressHostClearsOnNewSubmit() {
        let model = AskViewModel()
        model.egressHost = "api.anthropic.com"
        // Exercises the synchronous per-submission reset `submit()` runs
        // before kicking off its async query task — calling `submit()`
        // itself here would spin up that task, which opens the real
        // on-disk database and can reach out to Ollama, so it's exercised
        // through the extracted, side-effect-free `beginNewGeneration()`.
        _ = model.beginNewGeneration()
        XCTAssertNil(model.egressHost)
    }

    @MainActor
    func testEgressHostClearsOnEndSession() {
        let model = AskViewModel()
        model.egressHost = "api.anthropic.com"
        model.endSession()
        XCTAssertNil(model.egressHost)
    }
}
