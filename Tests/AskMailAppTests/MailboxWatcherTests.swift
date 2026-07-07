import XCTest
@testable import AskMailApp

/// Exercises the real `DispatchSource`/fd lifecycle against an actual
/// temporary directory — there is no existing FSEvents/DispatchSource
/// precedent anywhere else in this codebase, so this is the only thing
/// standing between "looks right" and "actually works."
final class MailboxWatcherTests: XCTestCase {

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailbox-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFiresAfterDebounceOnFileWriteInsideWatchedDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let expectation = expectation(description: "onChange fired")
        let watcher = MailboxWatcher(debounce: 0.2) { expectation.fulfill() }
        watcher.start(watching: dir.path)

        try Data("x".utf8).write(to: dir.appendingPathComponent("1.emlx"))

        wait(for: [expectation], timeout: 5)
        watcher.stop()
    }

    func testRapidWritesCoalesceIntoASingleCallbackViaDebounce() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CallCounter()
        let watcher = MailboxWatcher(debounce: 0.3) { counter.increment() }
        watcher.start(watching: dir.path)

        for index in 0..<5 {
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(index).emlx"))
            Thread.sleep(forTimeInterval: 0.02)  // well inside the 0.3s debounce window
        }

        // Wait comfortably past the debounce window from the last write.
        let deadline = Date().addingTimeInterval(2)
        while counter.value == 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(counter.value, 1, "a burst of writes inside the debounce window must coalesce into one callback")
        watcher.stop()
    }

    func testStopPreventsFurtherCallbacks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CallCounter()
        let watcher = MailboxWatcher(debounce: 0.1) { counter.increment() }
        watcher.start(watching: dir.path)
        watcher.stop()

        try Data("x".utf8).write(to: dir.appendingPathComponent("1.emlx"))
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))

        XCTAssertEqual(counter.value, 0, "no callback should fire after stop()")
    }

    func testStartOnNonexistentPathDoesNotCrash() {
        // The floor Timer covers detection until the directory appears; this
        // must degrade silently, not throw/crash.
        let watcher = MailboxWatcher(debounce: 0.1) { XCTFail("must never fire for a path that never existed") }
        watcher.start(watching: "/nonexistent/\(UUID().uuidString)/INBOX.mbox")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        watcher.stop()
    }

    // Regression test for a review-confirmed bug: an earlier version
    // scheduled the reopen-after-delete/rename as a bare, uncancelable
    // `asyncAfter` closure, so calling stop() during that ~1s window didn't
    // actually prevent the watcher from silently re-arming itself afterward.
    func testStopDuringPendingReopenPreventsTheReopen() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CallCounter()
        let watcher = MailboxWatcher(debounce: 0.05) { counter.increment() }
        watcher.start(watching: dir.path)

        // Delete + recreate the watched directory to drive reopenAfterDirectoryChange.
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Give the delete/rename event a moment to be delivered and schedule
        // its 1s reopen, then stop() well inside that window.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        watcher.stop()

        // Wait past the reopen's 1s deadline, then write into the
        // recreated directory -- if the reopen wasn't actually cancelled,
        // the watcher would have silently re-armed and this write would
        // still trigger a callback.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.5))
        try Data("x".utf8).write(to: dir.appendingPathComponent("1.emlx"))
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))

        XCTAssertEqual(counter.value, 0, "stop() during a pending reopen must actually prevent the reopen")
    }
}

/// Thread-safe counter, mirroring the pattern already used in
/// `QueryFlowTests.swift` (kept file-local here since that one is
/// file-`private` and lives in a different test target).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
