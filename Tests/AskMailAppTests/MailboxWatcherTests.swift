import XCTest
@testable import AskMailApp

/// Exercises the real FSEvents stream lifecycle against an actual temporary
/// directory — there is no other FSEvents precedent anywhere in this
/// codebase, so this is the only thing standing between "looks right" and
/// "actually works." The nested-subdirectory test is the load-bearing one:
/// it pins the reason FSEvents replaced the old single-directory kqueue
/// source (which never fired for Mail's deep `.emlx` writes).
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

    // Under the old kqueue implementation this guarded a cancelable-reopen
    // regression; under FSEvents there is no reopen mechanism at all, and the
    // invariant it pins is broader: after stop(), NOTHING — not even a
    // delete + recreate of the watched directory — may produce a callback.
    func testStopAfterDirectoryDeleteAndRecreateStaysSilent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CallCounter()
        let watcher = MailboxWatcher(debounce: 0.05) { counter.increment() }
        watcher.start(watching: dir.path)

        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        watcher.stop()

        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.5))
        try Data("x".utf8).write(to: dir.appendingPathComponent("1.emlx"))
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))

        XCTAssertEqual(counter.value, 0, "no callback may fire after stop(), even across delete/recreate")
    }

    // The reason MailboxWatcher is FSEvents-based at all: Apple Mail writes
    // new .emlx files several directory levels below the watched .mbox root
    // (INBOX.mbox/<UUID>/Data/…/Messages/*.emlx). The old kqueue
    // DispatchSource watched only the root's own entries and never saw
    // those, so the "fast trigger" never actually fired on real mail.
    func testFiresForWriteInNestedSubdirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("uuid/Data/1/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let expectation = expectation(description: "onChange fired for nested write")
        let watcher = MailboxWatcher(debounce: 0.2) { expectation.fulfill() }
        watcher.start(watching: dir.path)
        // FSEvents stream startup is asynchronous; give it a beat before writing.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))

        try Data("x".utf8).write(to: nested.appendingPathComponent("1.emlx"))

        wait(for: [expectation], timeout: 5)
        watcher.stop()
    }

    // Path-based FSEvents keeps reporting after the watched directory is
    // deleted and recreated (a re-syncing account) — the old fd-based
    // implementation needed an explicit reopen dance for this.
    func testKeepsWatchingAfterDirectoryDeleteAndRecreate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CallCounter()
        let watcher = MailboxWatcher(debounce: 0.1) { counter.increment() }
        watcher.start(watching: dir.path)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))

        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))

        counter.resetToZero()
        try Data("x".utf8).write(to: dir.appendingPathComponent("1.emlx"))

        let deadline = Date().addingTimeInterval(3)
        while counter.value == 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(counter.value, 0,
                             "a write after delete/recreate must still trigger a callback")
        watcher.stop()
    }
}

/// Thread-safe counter, mirroring the pattern already used in
/// `QueryFlowTests.swift` (kept file-local here since that one is
/// file-`private` and lives in a different test target).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func resetToZero() { lock.lock(); value = 0; lock.unlock() }
}
