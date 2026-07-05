import Foundation

/// Rolling 12-hour debug log (SECURITY.md). Holds retrieval scores, chunk
/// ids, provider decisions, and full error bodies. Never secrets, never raw
/// Message-ID headers in clear text where avoidable. Log content includes
/// question/answer text, which is why "Copy logs" shows a content warning
/// first (FR-11).
public final class RollingLog: @unchecked Sendable {
    public static let shared = RollingLog()

    private let lock = NSLock()
    private var entries: [(date: Date, line: String)] = []
    private let retention: TimeInterval

    public init(retentionHours: Double = Defaults.logRetentionHours) {
        self.retention = retentionHours * 3600
    }

    public func log(_ line: String) {
        let now = Date()
        lock.lock()
        entries.append((now, line))
        prune(now: now)
        lock.unlock()
    }

    /// The full retained window as clipboard-ready text (FR-11).
    public func recentText() -> String {
        lock.lock(); defer { lock.unlock() }
        prune(now: Date())
        let formatter = ISO8601DateFormatter()
        return entries
            .map { "\(formatter.string(from: $0.date)) \($0.line)" }
            .joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        if let firstKept = entries.firstIndex(where: { $0.date >= cutoff }) {
            entries.removeFirst(firstKept)
        } else if !entries.isEmpty {
            entries.removeAll()
        }
    }
}
