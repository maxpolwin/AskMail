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
