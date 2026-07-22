import Foundation

/// Lock-guarded mutable box for collecting values inside `@Sendable` closures
/// (log capture, call counting) without data-race warnings under strict
/// concurrency checking.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value.
    @discardableResult
    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }

    /// A snapshot of the current value.
    var current: Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

extension Locked where Value: RangeReplaceableCollection {
    func append(_ element: Value.Element) {
        with { $0.append(element) }
    }
}

/// Polls `condition` until it's true or `timeout` elapses. Replaces the
/// fixed-sleep-then-assert pattern for asynchronous side effects (task
/// cancellation delivery, detached completion): a fixed grace period flakes
/// on loaded CI runners, while polling passes the moment the effect lands
/// and only costs the full timeout when the test would fail anyway.
func eventually(timeout: TimeInterval = 3.0, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
