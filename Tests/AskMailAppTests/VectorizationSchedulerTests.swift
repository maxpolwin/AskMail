import XCTest
@testable import AskMailApp

/// Exercises the two pieces of `VectorizationScheduler`'s watcher-driven
/// trigger that are pulled out into pure/injectable form specifically so they
/// don't need real FSEvents or a real 60s wait: `topLevelMailboxDirectories`
/// (which mailbox folders to watch) and `IncrementalIndexWatchTrigger` (what
/// to do with a debounced signal). `VectorizationScheduler` itself, like
/// `Vectorizer` and `DraftEngine`, is deliberately not unit-tested end-to-end.
final class VectorizationSchedulerTests: XCTestCase {

    // MARK: - topLevelMailboxDirectories

    func tempAccountDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorizer-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFindsInboxAndSentMboxDirectoriesCaseInsensitively() throws {
        let account = try tempAccountDirectory()
        defer { try? FileManager.default.removeItem(at: account) }

        for name in ["INBOX.mbox", "Sent Messages.mbox", "Archive.mbox", "Junk.mbox", "Trash.mbox"] {
            try FileManager.default.createDirectory(at: account.appendingPathComponent(name, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
        // A non-mailbox file sitting alongside the mailboxes must be ignored.
        try Data("x".utf8).write(to: account.appendingPathComponent("Envelope Index"))

        let found = Set(VectorizationScheduler.topLevelMailboxDirectories(in: account).map(\.lastPathComponent))
        XCTAssertEqual(found, ["INBOX.mbox", "Sent Messages.mbox"],
                       "only Inbox/Sent are indexed, so only those should be watched — Archive/Junk/Trash and the plain file must be excluded")
    }

    func testReturnsEmptyForAnAccountDirectoryThatDoesNotExistYet() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(VectorizationScheduler.topLevelMailboxDirectories(in: missing), [],
                       "must degrade silently for a not-yet-synced account, matching MailboxWatcher's own no-crash-on-missing-path contract")
    }

    // MARK: - IncrementalIndexWatchTrigger

    @MainActor
    func testRunsImmediatelyWhenIdleAndOnACPower() {
        var ran = false
        let trigger = IncrementalIndexWatchTrigger(
            debounce: 60,
            isOnACPower: { true },
            isRunning: { false },
            run: { ran = true },
            scheduleRetry: { _, _ in XCTFail("must not reschedule when it can run immediately") })

        trigger.fire()

        XCTAssertTrue(ran)
    }

    @MainActor
    func testDropsOnBatteryWithoutRunningOrReArming() {
        var ran = false
        var rescheduled = false
        let trigger = IncrementalIndexWatchTrigger(
            debounce: 60,
            isOnACPower: { false },
            isRunning: { false },
            run: { ran = true },
            scheduleRetry: { _, _ in rescheduled = true })

        trigger.fire()

        XCTAssertFalse(ran, "FR-5: a watcher event on battery must never start a run")
        XCTAssertFalse(rescheduled,
                       "a battery-gated signal must be dropped outright, not re-armed — the hourly tick or a plug-in catch-up covers it later")
    }

    @MainActor
    func testReArmsInsteadOfDroppingWhenARunIsAlreadyInProgressThenRunsOnceItFinishes() {
        var runCount = 0
        var stillRunning = true
        var capturedDelay: TimeInterval?
        var capturedRetry: (@MainActor () -> Void)?

        let trigger = IncrementalIndexWatchTrigger(
            debounce: 60,
            isOnACPower: { true },
            isRunning: { stillRunning },
            run: { runCount += 1 },
            scheduleRetry: { delay, block in
                capturedDelay = delay
                capturedRetry = block
            })

        trigger.fire()
        XCTAssertEqual(runCount, 0, "must reuse the existing no-overlap guard and never start an overlapping run")
        XCTAssertEqual(capturedDelay, 60, "the re-arm must wait the same debounce window, not fire immediately")

        // The in-flight run finishes; simulate the re-armed retry firing.
        stillRunning = false
        capturedRetry?()

        XCTAssertEqual(runCount, 1, "once free, the re-armed retry must run the normal incremental vectorization")
    }

    @MainActor
    func testKeepsReArmingAcrossMultipleStillRunningRetriesUntilFinallyFree() {
        var runCount = 0
        var retryCount = 0
        var stillRunning = true
        var latestRetry: (@MainActor () -> Void)?

        let trigger = IncrementalIndexWatchTrigger(
            debounce: 60,
            isOnACPower: { true },
            isRunning: { stillRunning },
            run: { runCount += 1 },
            scheduleRetry: { _, block in
                retryCount += 1
                latestRetry = block
            })

        trigger.fire()          // 1st signal: still running -> re-arm #1
        latestRetry?()          // retry #1 fires: still running -> re-arm #2
        latestRetry?()          // retry #2 fires: still running -> re-arm #3
        XCTAssertEqual(retryCount, 3, "each retry that still finds a run in progress must re-arm again, not give up")
        XCTAssertEqual(runCount, 0)

        stillRunning = false
        latestRetry?()          // retry #3 fires: finally free -> runs

        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(retryCount, 3, "no further re-arm once it actually ran")
    }

    func testPureOutcomeFunctionMatchesFireBehavior() {
        XCTAssertEqual(IncrementalIndexWatchTrigger.outcome(isRunning: false, isOnACPower: true), .ran)
        XCTAssertEqual(IncrementalIndexWatchTrigger.outcome(isRunning: true, isOnACPower: true), .reArmed)
        XCTAssertEqual(IncrementalIndexWatchTrigger.outcome(isRunning: false, isOnACPower: false), .droppedOnBattery)
        XCTAssertEqual(IncrementalIndexWatchTrigger.outcome(isRunning: true, isOnACPower: false), .droppedOnBattery,
                       "the battery gate must win even when a run also happens to be in progress")
    }
}
