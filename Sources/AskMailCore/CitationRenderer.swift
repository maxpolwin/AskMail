import Foundation

/// Post-processing of a completed answer per docs/prompt-contract.md §6.
/// Runs on the completed answer, not mid-stream, to avoid partial-marker
/// flicker while tokens arrive.
public enum CitationRenderer {

    public struct Rendered: Sendable, Equatable {
        /// Answer text with `[N]` markers replaced by superscript digits.
        public var text: String
        /// Sources actually cited, renumbered 1…M in order of first appearance
        /// in the answer; the numbers match the in-text superscripts exactly.
        /// Order is reading order, independent of each source's relevance.
        public var sources: [(number: Int, ref: SourceRef)]
        /// Markers the model emitted with no matching source (dropped, log them).
        public var droppedMarkers: [Int]

        public static func == (lhs: Rendered, rhs: Rendered) -> Bool {
            lhs.text == rhs.text
                && lhs.droppedMarkers == rhs.droppedMarkers
                && lhs.sources.map(\.number) == rhs.sources.map(\.number)
                && lhs.sources.map(\.ref) == rhs.sources.map(\.ref)
        }
    }

    public static func render(answer: String, sourceMap: [Int: SourceRef]) -> Rendered {
        // A single bracket may cite several sources: [1], [4,6], [4, 6].
        let regex = try! NSRegularExpression(pattern: "\\[\\s*(\\d+(?:\\s*,\\s*\\d+)*)\\s*\\]")
        let matches = regex.matches(in: answer, range: NSRange(answer.startIndex..., in: answer))

        // The numbers inside one marker, parsed from the original answer.
        func markerNumbers(_ match: NSTextCheckingResult) -> [Int] {
            guard let group = Range(match.range(at: 1), in: answer) else { return [] }
            return answer[group].split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }

        // Pass 1 (forward): renumber cited sources 1…M by first appearance in
        // the answer — reading order, not retrieval rank — so the list has no
        // gaps. The model's original numbers (fused-rank) map to these.
        var renumbered: [Int: Int] = [:]
        var sources: [(number: Int, ref: SourceRef)] = []
        var dropped: [Int] = []
        for match in matches {
            for original in markerNumbers(match) {
                guard let ref = sourceMap[original] else { dropped.append(original); continue }
                if renumbered[original] == nil {
                    renumbered[original] = sources.count + 1
                    sources.append((number: sources.count + 1, ref: ref))
                }
            }
        }

        // Pass 2 (reverse): swap each marker for its renumbered superscripts.
        // Reverse keeps earlier match ranges valid as later text is replaced.
        var text = answer
        for match in matches.reversed() {
            guard let full = Range(match.range, in: text) else { continue }
            var seen = Set<Int>()
            let newNumbers = markerNumbers(match)
                .compactMap { renumbered[$0] }
                .filter { seen.insert($0).inserted }
            // Absorb one preceding space so the citation hugs the word, and a
            // fully-dropped marker leaves no hanging space.
            var lower = full.lowerBound
            if lower > text.startIndex, text[text.index(before: lower)] == " " {
                lower = text.index(before: lower)
            }
            if newNumbers.isEmpty {
                text.replaceSubrange(lower..<full.upperBound, with: "")
            } else {
                // Multiple numbers render as a thin-spaced cluster: ¹ ².
                let cluster = newNumbers.map(superscript).joined(separator: "\u{2009}")
                text.replaceSubrange(lower..<full.upperBound, with: cluster)
            }
        }

        return Rendered(text: text, sources: sources, droppedMarkers: dropped)
    }

    // MARK: Superscripts

    private static let superscriptDigits: [Character] = ["\u{2070}", "\u{00b9}", "\u{00b2}", "\u{00b3}", "\u{2074}", "\u{2075}", "\u{2076}", "\u{2077}", "\u{2078}", "\u{2079}"]

    public static func superscript(_ number: Int) -> String {
        String(String(number).compactMap { digit in
            digit.wholeNumberValue.map { superscriptDigits[$0] }
        })
    }

    // MARK: message:// links

    /// Deep link opening the source email in Apple Mail. Angle brackets are
    /// URL-encoded (%3C / %3E); `messageID` is the header value without them.
    public static func messageURL(messageID: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@+!$&'()*,;=")
        guard let encoded = messageID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "message://%3C\(encoded)%3E")
    }
}
