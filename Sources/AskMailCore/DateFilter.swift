import Foundation

/// Date-range preprocessing for queries (B6 step 5): detects an explicit
/// day, week-of-month, month (and optional year) mentioned in the question,
/// in English or German, and returns the Unix range to scope retrieval.
/// Recency is handled here, not by re-sorting context
/// (docs/prompt-contract.md §3).
///
/// Heuristic, most specific match wins: explicit calendar date ("2026-06-10",
/// "10.06.2026"), "yesterday"/"today", a weekday name ("last Tuesday", bare
/// "Tuesday" = most recent past occurrence), ordinal week-of-month ("first
/// week of June", "2nd week of June 2026"), a trailing window ("past 4
/// months", "the last 2 years"), explicit "<month> <year>", bare "<month>"
/// (most recent past occurrence), or bare "<year>". A question naming more
/// than one distinct day ("yesterday or last Tuesday") scopes to the span
/// from the earliest to the latest rather than picking just one.
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

    /// Ordinal words (English and German) that pick out one of the four/five
    /// 7-day slices of a month, keyed to the 1-based slice index. "Last" is
    /// resolved relative to the month's actual length, not a fixed index.
    private static let ordinalWeeks: [String: Int] = [
        "first": 1, "1st": 1, "erste": 1, "ersten": 1,
        "second": 2, "2nd": 2, "zweite": 2, "zweiten": 2,
        "third": 3, "3rd": 3, "dritte": 3, "dritten": 3,
        "fourth": 4, "4th": 4, "vierte": 4, "vierten": 4,
    ]
    private static let lastWeekWords: Set<String> = ["last", "letzte", "letzten"]

    /// Foundation `Calendar` weekday convention: Sunday = 1 ... Saturday = 7.
    private static let weekdayNumbers: [String: Int] = {
        var map: [String: Int] = [:]
        let english = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                       "thursday": 5, "friday": 6, "saturday": 7]
        let german = ["sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4,
                      "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7]
        for (name, number) in english { map[name] = number }
        for (name, number) in german { map[name] = number }
        return map
    }()

    private enum RelativeUnit { case day, week, month, year }

    private static let relativeUnitWords: [String: RelativeUnit] = [
        "day": .day, "days": .day, "tag": .day, "tage": .day, "tagen": .day,
        "week": .week, "weeks": .week, "woche": .week, "wochen": .week,
        "month": .month, "months": .month, "monat": .month, "monate": .month, "monaten": .month,
        "year": .year, "years": .year, "jahr": .year, "jahre": .year, "jahren": .year,
    ]

    private static let pastTriggerWords: Set<String> = ["past", "last", "letzten", "letzte", "vergangenen", "vergangene"]
    /// Bare singular fallback ("last month" -> 1 month) is restricted to
    /// "past"/"vergangenen": "last" already has established, tested meanings
    /// elsewhere (bare "last year" = the previous calendar year; "last week
    /// of <month>" = a specific week slice), and a bare rolling-window
    /// reading would silently override those.
    private static let bareSingularTriggerWords: Set<String> = ["past", "vergangenen", "vergangene"]

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "ein": 1, "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "fuenf": 5, "f\u{00fc}nf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11,
        "zwoelf": 12, "zw\u{00f6}lf": 12,
    ]

    /// True if `first` is immediately followed by `second` anywhere in `words`.
    private static func containsPhrase(_ words: [String], _ first: String, _ second: String) -> Bool {
        zip(words, words.dropFirst()).contains { $0 == first && $1 == second }
    }

    private static func number(from word: String) -> Int? {
        Int(word) ?? numberWords[word]
    }

    /// A trailing window ending today: "the past N <unit>s" / "the last N
    /// <unit>s" ("over the past four months", "past 15 months", "past 2
    /// years", "letzten 3 wochen"). Also matches the bare singular form
    /// ("last month", "past year") as N=1, but only when no month name
    /// appears elsewhere in the question, so "last week of June" still
    /// resolves to that specific week rather than the trailing 7 days.
    private static func relativePastRange(words: [String], calendar: Calendar, now: Date) -> ClosedRange<Int64>? {
        for (i, word) in words.enumerated() where pastTriggerWords.contains(word) {
            if words.indices.contains(i + 2),
               let n = number(from: words[i + 1]), n > 0,
               let unit = relativeUnitWords[words[i + 2]],
               let range = trailingRange(n: n, unit: unit, calendar: calendar, now: now) {
                return range
            }
            if bareSingularTriggerWords.contains(word),
               words.indices.contains(i + 1), let unit = relativeUnitWords[words[i + 1]],
               !words.contains(where: { monthNames[$0] != nil }),
               let range = trailingRange(n: 1, unit: unit, calendar: calendar, now: now) {
                return range
            }
        }
        return nil
    }

    private static func trailingRange(n: Int, unit: RelativeUnit, calendar: Calendar, now: Date) -> ClosedRange<Int64>? {
        let todayStart = calendar.startOfDay(for: now)
        guard let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return nil }
        let delta: DateComponents
        switch unit {
        case .day: delta = DateComponents(day: -n)
        case .week: delta = DateComponents(day: -n * 7)
        case .month: delta = DateComponents(month: -n)
        case .year: delta = DateComponents(year: -n)
        }
        guard let start = calendar.date(byAdding: delta, to: todayStart) else { return nil }
        return Int64(start.timeIntervalSince1970)...Int64(dayAfterToday.timeIntervalSince1970 - 1)
    }

    public static func unixRange(question: String, now: Date = Date()) -> ClosedRange<Int64>? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let nowComponents = calendar.dateComponents([.year, .month], from: now)

        let lowered = question.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // 1. Single-day mentions, the most specific match: explicit calendar
        //    dates ("2026-06-10", "10.06.2026"), "yesterday"/"today", and
        //    weekday names ("last Tuesday", bare "Tuesday" = most recent past
        //    occurrence). A question can name more than one distinct day
        //    ("yesterday or last Tuesday"); when it does, union the spans so
        //    retrieval doesn't drop either day — the per-source dates already
        //    in context (prompt-contract.md §3) let the model attribute each
        //    email to the day the user actually meant.
        let singleDayMatches = allNumericDateRanges(question: question, calendar: calendar)
            + wordBasedSingleDayMatches(words: words, calendar: calendar, now: now)
        if singleDayMatches.count > 1 {
            let start = singleDayMatches.map(\.lowerBound).min()!
            let end = singleDayMatches.map(\.upperBound).max()!
            return start...end
        }
        if let only = singleDayMatches.first {
            return only
        }

        // 2. Trailing relative window: "past 4 months", "the last 15 months",
        //    "past 2 years". Spans multiple calendar years natively since it
        //    is computed by calendar subtraction from today, not by month/year
        //    lookup.
        if let range = relativePastRange(words: words, calendar: calendar, now: now) {
            return range
        }

        var month: Int? = nil
        var year: Int? = nil
        for word in words {
            if month == nil, let m = monthNames[word] { month = m }
            if year == nil, let y = Int(word), (1990...2100).contains(y) { year = y }
        }
        // "this year" / "last year" (and German equivalents) pin an explicit
        // calendar year, taking priority over the most-recent-past-occurrence
        // heuristic below — asking about "June this year" in January should
        // resolve to a June that hasn't happened yet, not last June; "June
        // last year" should resolve to last year's June even if this year's
        // June hasn't happened yet either.
        if year == nil, let currentYear = nowComponents.year {
            if containsPhrase(words, "this", "year") || containsPhrase(words, "dieses", "jahr")
                || containsPhrase(words, "diesem", "jahr") {
                year = currentYear
            } else if containsPhrase(words, "last", "year") || containsPhrase(words, "letztes", "jahr")
                || containsPhrase(words, "letztem", "jahr") || containsPhrase(words, "letzten", "jahr")
                || containsPhrase(words, "vergangenen", "jahr")
                || containsPhrase(words, "vergangenes", "jahr") {
                year = currentYear - 1
            }
        }

        func resolvedYear(for month: Int) -> Int? {
            if let year { return year }
            guard let currentYear = nowComponents.year, let currentMonth = nowComponents.month else { return nil }
            // Bare month means its most recent occurrence, this year or last.
            return month <= currentMonth ? currentYear : currentYear - 1
        }

        // 3. Ordinal week-of-month: "first week of June", "letzte Woche im Juni 2026".
        if let month, let resolvedYear = resolvedYear(for: month) {
            let hasWeekWord = words.contains("week") || words.contains("woche")
            if hasWeekWord {
                if let last = words.first(where: lastWeekWords.contains) {
                    _ = last
                    return lastWeekRange(year: resolvedYear, month: month, calendar: calendar)
                }
                if let ordinalWord = words.first(where: { ordinalWeeks[$0] != nil }),
                   let slice = ordinalWeeks[ordinalWord] {
                    return weekSliceRange(year: resolvedYear, month: month, slice: slice, calendar: calendar)
                }
            }
        }

        // 4. Explicit/bare month, optionally with year.
        if let month {
            guard let resolvedYear = resolvedYear(for: month) else { return nil }
            return monthRange(year: resolvedYear, month: month, calendar: calendar)
        }

        // 5. Bare year.
        if let year {
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
            let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
            return Int64(start.timeIntervalSince1970)...Int64(end.timeIntervalSince1970 - 1)
        }

        return nil
    }

    /// Matches every ISO (`YYYY-MM-DD`), German/EU dotted (`DD.MM.YYYY`), and
    /// slashed (`MM/DD/YYYY`) single-date occurrence in the question (there
    /// can be more than one, e.g. a range spelled out as two explicit dates).
    private static func allNumericDateRanges(question: String, calendar: Calendar) -> [ClosedRange<Int64>] {
        let pattern = #"(\d{4})-(\d{1,2})-(\d{1,2})|(\d{1,2})\.(\d{1,2})\.(\d{4})|(\d{1,2})/(\d{1,2})/(\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(question.startIndex..., in: question)

        return regex.matches(in: question, range: fullRange).compactMap { match -> ClosedRange<Int64>? in
            func int(_ groupIndex: Int) -> Int? {
                guard let range = Range(match.range(at: groupIndex), in: question) else { return nil }
                return Int(question[range])
            }

            let year: Int, month: Int, day: Int
            if let y = int(1), let m = int(2), let d = int(3) {
                (year, month, day) = (y, m, d)               // YYYY-MM-DD
            } else if let d = int(4), let m = int(5), let y = int(6) {
                (year, month, day) = (y, m, d)               // DD.MM.YYYY
            } else if let m = int(7), let d = int(8), let y = int(9) {
                (year, month, day) = (y, m, d)               // MM/DD/YYYY
            } else {
                return nil
            }
            guard (1...12).contains(month), (1...31).contains(day) else { return nil }
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            return dayRange(start, calendar: calendar)
        }
    }

    /// "yesterday"/"today" (English and German), and weekday names — bare
    /// ("Tuesday") or with "last" ("last Tuesday") both mean the most recent
    /// past occurrence, strictly before today.
    private static func wordBasedSingleDayMatches(words: [String], calendar: Calendar, now: Date) -> [ClosedRange<Int64>] {
        var matches: [ClosedRange<Int64>] = []
        let todayStart = calendar.startOfDay(for: now)

        if words.contains("today") || words.contains("heute") {
            matches.append(dayRange(todayStart, calendar: calendar))
        }
        if words.contains("yesterday") || words.contains("gestern"),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) {
            matches.append(dayRange(yesterday, calendar: calendar))
        }
        for word in words {
            if let weekday = weekdayNumbers[word],
               let date = mostRecentPastWeekday(weekday, calendar: calendar, now: now) {
                matches.append(dayRange(date, calendar: calendar))
            }
        }
        return matches
    }

    private static func mostRecentPastWeekday(_ target: Int, calendar: Calendar, now: Date) -> Date? {
        let todayStart = calendar.startOfDay(for: now)
        for daysBack in 1...7 {
            guard let candidate = calendar.date(byAdding: .day, value: -daysBack, to: todayStart) else { continue }
            if calendar.component(.weekday, from: candidate) == target { return candidate }
        }
        return nil
    }

    private static func dayRange(_ dayStart: Date, calendar: Calendar) -> ClosedRange<Int64> {
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return Int64(dayStart.timeIntervalSince1970)...Int64(dayAfter.timeIntervalSince1970 - 1)
    }

    private static func monthRange(year: Int, month: Int, calendar: Calendar) -> ClosedRange<Int64>? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: DateComponents(month: 1), to: start) else {
            return nil
        }
        return Int64(start.timeIntervalSince1970)...Int64(end.timeIntervalSince1970 - 1)
    }

    /// The 7-day slice `slice` (1-based) of the given month, e.g. slice 1 is
    /// days 1-7. The final slice of a request that runs past month-end is
    /// clamped to the last day of the month.
    private static func weekSliceRange(year: Int, month: Int, slice: Int, calendar: Calendar) -> ClosedRange<Int64>? {
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart),
              let sliceStart = calendar.date(byAdding: .day, value: (slice - 1) * 7, to: monthStart) else {
            return nil
        }
        guard sliceStart <= monthEnd else { return nil }
        let uncappedEnd = calendar.date(byAdding: .day, value: 6, to: sliceStart)!
        let sliceEnd = min(uncappedEnd, monthEnd)
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: sliceEnd)!
        return Int64(sliceStart.timeIntervalSince1970)...Int64(dayAfterEnd.timeIntervalSince1970 - 1)
    }

    /// The last 7 days of the given month (may overlap the 4th slice for
    /// short months, which is fine: "last week" is meant loosely).
    private static func lastWeekRange(year: Int, month: Int, calendar: Calendar) -> ClosedRange<Int64>? {
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart),
              let sliceStart = calendar.date(byAdding: .day, value: -6, to: monthEnd) else {
            return nil
        }
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: monthEnd)!
        return Int64(sliceStart.timeIntervalSince1970)...Int64(dayAfterEnd.timeIntervalSince1970 - 1)
    }
}
