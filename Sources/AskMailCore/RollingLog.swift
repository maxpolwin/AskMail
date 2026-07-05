import Foundation

/// Rolling 12-hour debug log (SECURITY.md). Holds retrieval scores, chunk
/// ids, provider decisions, and full error bodies. Never secrets, never raw
/// Message-ID headers in clear text where avoidable. Log content includes
/// question/answer text, which is why exporting logs shows a content warning
/// first (FR-11).
public final class RollingLog: @unchecked Sendable {
    public static let shared = RollingLog()

    /// Verbosity of a log line, ordered least- to most-verbose. `minLevel`
    /// is a threshold: a line is kept only when its level is at or below it,
    /// so raising verbosity (toward `.debug`) keeps everything coarser too.
    public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
        case error = 0
        case info = 1
        case debug = 2

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var displayName: String {
            switch self {
            case .error: return "Errors only"
            case .info: return "Info"
            case .debug: return "Debug (verbose)"
            }
        }

        public var tag: String {
            switch self {
            case .error: return "ERROR"
            case .info: return "INFO"
            case .debug: return "DEBUG"
            }
        }
    }

    private let lock = NSLock()
    private var entries: [(date: Date, level: LogLevel, line: String)] = []
    private let retention: TimeInterval
    private var minLevel: LogLevel

    public init(retentionHours: Double = Defaults.logRetentionHours,
                minLevel: LogLevel = .debug) {
        self.retention = retentionHours * 3600
        self.minLevel = minLevel
    }

    /// The configured verbosity threshold; lines more verbose than this are
    /// dropped at write time rather than merely hidden at read time, so
    /// choosing "Errors only" also keeps memory use down.
    public var currentMinLevel: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return minLevel }
        set { lock.lock(); minLevel = newValue; lock.unlock() }
    }

    public func log(_ line: String, level: LogLevel = .info) {
        let now = Date()
        lock.lock()
        guard level <= minLevel else { lock.unlock(); return }
        entries.append((now, level, line))
        prune(now: now)
        lock.unlock()
    }

    /// The full retained window as clipboard-ready text (FR-11).
    public func recentText() -> String {
        lock.lock(); defer { lock.unlock() }
        prune(now: Date())
        let formatter = ISO8601DateFormatter()
        return entries
            .map { "\(formatter.string(from: $0.date)) [\($0.level.tag)] \($0.line)" }
            .joined(separator: "\n")
    }

    /// The retained window formatted as a standalone Markdown document,
    /// ready to write straight to a `.md` file (FR-11).
    public func markdownDocument() -> String {
        lock.lock(); defer { lock.unlock() }
        prune(now: Date())
        let formatter = ISO8601DateFormatter()
        var doc = "# AskMail Debug Log\n\n"
        doc += "Generated \(formatter.string(from: Date())) \u{2014} covers the last \(Int(retention / 3600)) hours.\n\n"
        if entries.isEmpty {
            doc += "_No log entries in this window._\n"
        } else {
            doc += "```\n"
            doc += entries
                .map { "\(formatter.string(from: $0.date)) [\($0.level.tag)] \($0.line)" }
                .joined(separator: "\n")
            doc += "\n```\n"
        }
        return doc
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
