import Foundation

/// Date-range preprocessing for queries (B6 step 5): detects an explicit
/// day, week-of-month, month (and optional year) mentioned in the question,
/// in English or German, and returns the Unix range to scope retrieval.
/// Recency is handled here, not by re-sorting context
/// (docs/prompt-contract.md §3).
///
/// Heuristic, most specific match wins: an open-ended range ("since June 1",
/// "before 2026-06-01"), explicit calendar date ("2026-06-10", "10.06.2026"),
/// "yesterday"/"today", a weekday name ("last Tuesday", bare "Tuesday" = most
/// recent past occurrence), a day-of-month next to a month name ("June 5th",
/// "5. Juni"), ordinal week-of-month ("first week of June"), a trailing
/// window ("past 4 months", "the last 2 years"), explicit "<month> <year>"
/// (one or more months, unioned if more than one is named), bare "<month>"
/// (most recent past occurrence), or bare "<year>". A question naming more
/// than one distinct day, or more than one distinct month, scopes to the
/// span from the earliest to the latest rather than picking just one — see
/// the tier-1 comment inside `unixRange` for the accepted tradeoff this
/// implies for 3+ disjoint mentions.
///
/// Boundary arithmetic runs in an injectable `TimeZone` (default `.current`,
/// the device's own zone): "yesterday"/"today"/weekday/month boundaries are
/// inherently about the user's own wall-clock day, not a fixed zone. Tests
/// pin `timeZone: .gmt` to keep exact epoch-second assertions deterministic
/// regardless of the machine running them.
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
    private static let weekWords: Set<String> = ["week", "woche"]

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

    /// "since"/"after" open the lower bound at the anchor date, upper bound
    /// = now. "before"/"until" open the upper bound at the anchor date,
    /// lower bound = epoch 0 (this app's mailbox history is always finite
    /// and small; a store-queried floor isn't worth the coupling).
    private static let sinceTriggerWords: Set<String> = ["since", "after", "seit"]
    /// German "vor" is heavily overloaded (spatial, causal, and "vor 3
    /// Tagen" = "3 days ago", a relative offset, not "before a date"). It's
    /// safe to include here because `openEndedRange` only fires when a real
    /// date anchor is found nearby — a bare number ("vor 3 Tagen") never
    /// resolves as an anchor, so those phrasings simply produce no match
    /// here rather than misfiring.
    private static let beforeTriggerWords: Set<String> = ["before", "until", "bis", "vor"]

    /// True if `first` is immediately followed by `second` anywhere in `words`.
    private static func containsPhrase(_ words: [String], _ first: String, _ second: String) -> Bool {
        zip(words, words.dropFirst()).contains { $0 == first && $1 == second }
    }

    private static func number(from word: String) -> Int? {
        Int(word) ?? numberWords[word]
    }

    /// A bare or ordinal day-of-month number: "5", "5th", "21st", "3rd", or
    /// German "5." (the period is already stripped by the tokenizer, so "5."
    /// arrives here as bare "5").
    private static func dayNumber(from word: String) -> Int? {
        if let n = Int(word), (1...31).contains(n) { return n }
        for suffix in ["th", "st", "nd", "rd"] where word.hasSuffix(suffix) {
            if let n = Int(word.dropLast(suffix.count)), (1...31).contains(n) { return n }
        }
        return nil
    }

    /// Resolves an ambiguous `A/B` slash date into (month, day). A slash date
    /// is genuinely ambiguous between US (MM/DD) and EU/UK (DD/MM) reading
    /// whenever both numbers could be a month (both <= 12) — rather than
    /// silently guessing a locale, this returns nil so the match is dropped
    /// entirely (the user can disambiguate with the dotted or ISO form,
    /// both already unambiguous). When exactly one number can't be a month
    /// (> 12), the reading is forced and recovered correctly either way.
    private static func disambiguateSlashDate(_ a: Int, _ b: Int) -> (month: Int, day: Int)? {
        let aIsMonth = (1...12).contains(a)
        let bIsMonth = (1...12).contains(b)
        switch (aIsMonth, bIsMonth) {
        case (true, true): return nil                                   // ambiguous, don't guess
        case (true, false): return (1...31).contains(b) ? (a, b) : nil  // b > 12, must be the day
        case (false, true): return (1...31).contains(a) ? (b, a) : nil  // a > 12, must be the day
        case (false, false): return nil                                 // neither reading valid
        }
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

    /// Skips a day-number token that actually belongs to a different feature:
    /// a relative-window count ("past 4 months ... June") or a week-of-month
    /// ordinal ("the 1st week of June" — "1st" must not be read as day 1).
    private static func isGuardedDayToken(at j: Int, monthIndex i: Int, words: [String]) -> Bool {
        if j > 0 && pastTriggerWords.contains(words[j - 1]) { return true }
        let between = j < i ? (j + 1)..<i : (i + 1)..<j
        return between.contains { relativeUnitWords[words[$0]] != nil || weekWords.contains(words[$0]) }
    }

    /// "June 5th", "the 5th of June", "June 5", "5. Juni", "on the 5th ...
    /// June" — a day-of-month number within 3 tokens of a month-name word,
    /// combined with the year `resolvedYear` would give that month. Guarded
    /// against colliding with the relative-window and week-of-month tiers
    /// (see `isGuardedDayToken`).
    private static func dayOfMonthMatches(words: [String], resolvedYear: (Int) -> Int?,
                                          calendar: Calendar) -> [ClosedRange<Int64>] {
        var results: [ClosedRange<Int64>] = []
        let window = 3
        for (i, word) in words.enumerated() {
            guard let month = monthNames[word], let year = resolvedYear(month) else { continue }
            let behind = stride(from: max(0, i - window), to: i, by: 1)
            let ahead = stride(from: i + 1, to: min(words.count, i + window + 1), by: 1)
            for j in Array(behind) + Array(ahead) {
                guard !isGuardedDayToken(at: j, monthIndex: i, words: words),
                      let day = dayNumber(from: words[j]),
                      let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
                results.append(dayRange(start, calendar: calendar))
            }
        }
        return results
    }

    /// The date anchor a "since"/"before" trigger word refers to: an
    /// explicit numeric date anywhere in the question (only when there's
    /// exactly one, to avoid guessing which one the trigger refers to),
    /// otherwise the first resolvable form in the few tokens right after the
    /// trigger — today/yesterday, a weekday, a month+day pair, a bare month,
    /// or a bare year.
    private static func openEndedAnchor(tailWords: [String], wholeQuestionNumericMatches: [ClosedRange<Int64>],
                                        calendar: Calendar, now: Date, resolvedYear: (Int) -> Int?) -> ClosedRange<Int64>? {
        if wholeQuestionNumericMatches.count == 1 { return wholeQuestionNumericMatches[0] }

        if let first = tailWords.first {
            if first == "today" || first == "heute" {
                return dayRange(calendar.startOfDay(for: now), calendar: calendar)
            }
            if first == "yesterday" || first == "gestern",
               let y = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) {
                return dayRange(y, calendar: calendar)
            }
        }
        for word in tailWords {
            if let weekday = weekdayNumbers[word], let date = mostRecentPastWeekday(weekday, calendar: calendar, now: now) {
                return dayRange(date, calendar: calendar)
            }
        }
        for (j, word) in tailWords.enumerated() {
            guard let month = monthNames[word], let year = resolvedYear(month) else { continue }
            for k in tailWords.indices where k != j {
                if let day = dayNumber(from: tailWords[k]),
                   let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                    return dayRange(start, calendar: calendar)
                }
            }
            return monthRange(year: year, month: month, calendar: calendar)
        }
        for word in tailWords {
            if let y = Int(word), (1990...2100).contains(y) {
                let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1))!
                let end = calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1))!
                return Int64(start.timeIntervalSince1970)...Int64(end.timeIntervalSince1970 - 1)
            }
        }
        return nil
    }

    /// "since June 1", "before 2026-06-01", "seit letzten Dienstag" — an
    /// open-ended range anchored on a resolvable date. Runs before every
    /// other tier so the trigger word wins outright over e.g. tier 1 reading
    /// "June 1st" as just that one day.
    private static func openEndedRange(words: [String], question: String, calendar: Calendar,
                                       now: Date, resolvedYear: (Int) -> Int?) -> ClosedRange<Int64>? {
        let numericMatches = allNumericDateRanges(question: question, calendar: calendar)
        for (i, word) in words.enumerated() {
            let isSince = sinceTriggerWords.contains(word)
            let isBefore = beforeTriggerWords.contains(word)
            guard isSince || isBefore else { continue }

            let tail = Array(words[(i + 1)...].prefix(4))
            guard let anchor = openEndedAnchor(tailWords: tail, wholeQuestionNumericMatches: numericMatches,
                                               calendar: calendar, now: now, resolvedYear: resolvedYear) else { continue }

            if isSince {
                let todayEnd = dayRange(calendar.startOfDay(for: now), calendar: calendar).upperBound
                return anchor.lowerBound...max(anchor.lowerBound, todayEnd)
            } else {
                return 0...anchor.upperBound
            }
        }
        return nil
    }

    public static func unixRange(question: String, now: Date = Date(), timeZone: TimeZone = .current) -> ClosedRange<Int64>? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let nowComponents = calendar.dateComponents([.year, .month], from: now)

        let lowered = question.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // Month(s)/year resolution is shared by several tiers below (day-of-
        // month, week-of-month, month+year, and the open-ended anchor
        // search), so it's computed once, up front.
        var months: [Int] = []
        var year: Int? = nil
        for word in words {
            if let m = monthNames[word], !months.contains(m) { months.append(m) }
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

        // 0. Open-ended range: "since <date>" / "before <date>".
        if let range = openEndedRange(words: words, question: question, calendar: calendar,
                                      now: now, resolvedYear: resolvedYear) {
            return range
        }

        // 1. Single-day mentions, the most specific bounded match: explicit
        //    calendar dates ("2026-06-10", "10.06.2026"), "yesterday"/
        //    "today", weekday names ("last Tuesday", bare "Tuesday" = most
        //    recent past occurrence), and a day-of-month next to a month
        //    name ("June 5th"). A question can name more than one distinct
        //    day ("yesterday or last Tuesday"); when it does, union the
        //    spans so retrieval doesn't drop either day — the per-source
        //    dates already in context (prompt-contract.md §3) let the model
        //    attribute each email to the day the user actually meant.
        //
        //    Accepted tradeoff: this union is a min/max bounding span, not a
        //    disjoint set. For exactly 2 mentions that's indistinguishable
        //    from "a continuous range" (and is in fact how "between X and Y"
        //    resolves today, via two explicit dates unioning into the span
        //    between them). For 3+ genuinely disjoint mentions ("June 1,
        //    June 5, or June 10") it silently widens to cover every day in
        //    between, not just the three named days — a coarser net than the
        //    user asked for, but consistent with this file's existing
        //    philosophy elsewhere (comment below, B6 step 5) that a broader
        //    match with sources beats a false no-match. A disjoint-set
        //    result would require a different consumer contract in
        //    QueryService (which currently expects one ClosedRange), which
        //    isn't justified for a single-user mailbox tool without
        //    evidence this phrasing is common. See
        //    testThreeDisjointDaysWidenRatherThanStayDisjoint for the pinned
        //    current behavior.
        let singleDayMatches = allNumericDateRanges(question: question, calendar: calendar)
            + wordBasedSingleDayMatches(words: words, calendar: calendar, now: now)
            + dayOfMonthMatches(words: words, resolvedYear: resolvedYear, calendar: calendar)
        if singleDayMatches.count > 1 {
            let start = singleDayMatches.map(\.lowerBound).min()!
            let end = singleDayMatches.map(\.upperBound).max()!
            return start...end
        }
        if let only = singleDayMatches.first {
            return only
        }
        // A slash/dotted/ISO-shaped date attempt that failed to resolve
        // (e.g. "03/04/2026", ambiguous between US and EU/UK reading) means
        // the user was clearly trying to name one specific date, not a bare
        // year or month -- so its leftover digits (the "2026" in that same
        // token sequence) must not be silently picked up by tier 4/5's
        // bare-year/month scan below. That would silently answer a
        // different, broader question than the one the user actually asked,
        // unlike the other fallback tiers, which only ever fire from
        // context that was never part of a more specific, failed attempt.
        if hasDroppedNumericDateAttempt(question: question, calendar: calendar) {
            return nil
        }

        // 2. Trailing relative window: "past 4 months", "the last 15 months",
        //    "past 2 years". Spans multiple calendar years natively since it
        //    is computed by calendar subtraction from today, not by month/year
        //    lookup.
        if let range = relativePastRange(words: words, calendar: calendar, now: now) {
            return range
        }

        // 3. Ordinal week-of-month: "first week of June", "letzte Woche im Juni 2026".
        if let month = months.first, let resolvedYearValue = resolvedYear(for: month) {
            let hasWeekWord = words.contains("week") || words.contains("woche")
            if hasWeekWord {
                if let last = words.first(where: lastWeekWords.contains) {
                    _ = last
                    return lastWeekRange(year: resolvedYearValue, month: month, calendar: calendar)
                }
                if let ordinalWord = words.first(where: { ordinalWeeks[$0] != nil }),
                   let slice = ordinalWeeks[ordinalWord] {
                    return weekSliceRange(year: resolvedYearValue, month: month, slice: slice, calendar: calendar)
                }
            }
        }

        // 4. Explicit/bare month(s), optionally with year. More than one
        //    distinct month ("March or April") unions their ranges, same
        //    span-not-disjoint tradeoff as tier 1.
        if !months.isEmpty {
            let ranges = months.compactMap { m -> ClosedRange<Int64>? in
                guard let y = resolvedYear(for: m) else { return nil }
                return monthRange(year: y, month: m, calendar: calendar)
            }
            if ranges.count > 1 {
                return ranges.map(\.lowerBound).min()!...ranges.map(\.upperBound).max()!
            }
            if let only = ranges.first { return only }
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
    /// slashed (`MM/DD/YYYY` or `DD/MM/YYYY`) date-shaped token sequence.
    /// Shared by `hasDroppedNumericDateAttempt` and `allNumericDateRanges`;
    /// the pattern is a fixed literal, so it's compiled once rather than per
    /// call.
    private static let numericDateRegex = try! NSRegularExpression(
        pattern: #"(\d{4})-(\d{1,2})-(\d{1,2})|(\d{1,2})\.(\d{1,2})\.(\d{4})|(\d{1,2})/(\d{1,2})/(\d{4})"#)

    /// True if the question contains a numeric-date-shaped token sequence
    /// that failed to resolve into an actual date (dropped for ambiguity or
    /// invalidity by `allNumericDateRanges`). See the call site in
    /// `unixRange` for why this must short-circuit the broader fallback
    /// tiers rather than let their digits be reinterpreted more loosely.
    private static func hasDroppedNumericDateAttempt(question: String, calendar: Calendar) -> Bool {
        let fullRange = NSRange(question.startIndex..., in: question)
        let rawMatchCount = numericDateRegex.numberOfMatches(in: question, range: fullRange)
        guard rawMatchCount > 0 else { return false }
        return allNumericDateRanges(question: question, calendar: calendar).count < rawMatchCount
    }

    /// Matches every ISO (`YYYY-MM-DD`), German/EU dotted (`DD.MM.YYYY`), and
    /// unambiguous slashed (`MM/DD/YYYY` or `DD/MM/YYYY`) single-date
    /// occurrence in the question (there can be more than one, e.g. a range
    /// spelled out as two explicit dates). A slash date where both numbers
    /// could be a month (both <= 12) is genuinely ambiguous between US and
    /// EU/UK convention and is dropped rather than guessed — see
    /// `disambiguateSlashDate`.
    private static func allNumericDateRanges(question: String, calendar: Calendar) -> [ClosedRange<Int64>] {
        let fullRange = NSRange(question.startIndex..., in: question)

        return numericDateRegex.matches(in: question, range: fullRange).compactMap { match -> ClosedRange<Int64>? in
            func int(_ groupIndex: Int) -> Int? {
                guard let range = Range(match.range(at: groupIndex), in: question) else { return nil }
                return Int(question[range])
            }

            let year: Int, month: Int, day: Int
            if let y = int(1), let m = int(2), let d = int(3) {
                (year, month, day) = (y, m, d)               // YYYY-MM-DD
            } else if let d = int(4), let m = int(5), let y = int(6) {
                (year, month, day) = (y, m, d)               // DD.MM.YYYY
            } else if let a = int(7), let b = int(8), let y = int(9) {
                guard let resolved = disambiguateSlashDate(a, b) else { return nil }
                (year, month, day) = (y, resolved.month, resolved.day)
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
