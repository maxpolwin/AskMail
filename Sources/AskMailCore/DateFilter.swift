import Foundation

/// Date-range preprocessing for queries (B6 step 5): detects an explicit
/// month (and optional year) mentioned in the question, in English or
/// German, and returns the Unix range to scope retrieval. Recency is handled
/// here, not by re-sorting context (docs/prompt-contract.md §3).
///
/// v1 heuristic: explicit "<month> <year>", bare "<month>" (most recent past
/// occurrence), or bare "<year>". Relative phrases ("last month") are a
/// v1.1 refinement.
public enum DateFilter {

    private static let monthNames: [String: Int] = {
        var map: [String: Int] = [:]
        let english = ["january", "february", "march", "april", "may", "june",
                       "july", "august", "september", "october", "november", "december"]
        let german = ["januar", "februar", "m\u{00e4}rz", "april", "mai", "juni",
                      "juli", "august", "september", "oktober", "november", "dezember"]
        for (index, name) in english.enumerated() { map[name] = index + 1 }
        for (index, name) in german.enumerated() { map[name] = index + 1 }
        map["maerz"] = 3  // common ASCII spelling of März
        return map
    }()

    public static func unixRange(question: String, now: Date = Date()) -> ClosedRange<Int64>? {
        let lowered = question.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)

        var month: Int? = nil
        var year: Int? = nil
        for word in words {
            if month == nil, let m = monthNames[word] { month = m }
            if year == nil, let y = Int(word), (1990...2100).contains(y) { year = y }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let nowComponents = calendar.dateComponents([.year, .month], from: now)

        if let month {
            let resolvedYear: Int
            if let year {
                resolvedYear = year
            } else if let currentYear = nowComponents.year, let currentMonth = nowComponents.month {
                // Bare month means its most recent occurrence, this year or last.
                resolvedYear = month <= currentMonth ? currentYear : currentYear - 1
            } else {
                return nil
            }
            return monthRange(year: resolvedYear, month: month, calendar: calendar)
        }

        if let year {
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
            return Int64(start.timeIntervalSince1970)...Int64(end.timeIntervalSince1970 - 1)
        }

        return nil
    }

    private static func monthRange(year: Int, month: Int, calendar: Calendar) -> ClosedRange<Int64>? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: DateComponents(month: 1), to: start) else {
            return nil
        }
        return Int64(start.timeIntervalSince1970)...Int64(end.timeIntervalSince1970 - 1)
    }
}
