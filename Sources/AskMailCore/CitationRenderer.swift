import Foundation

/// Post-processing of a completed answer per docs/prompt-contract.md §6.
/// Runs on the completed answer, not mid-stream, to avoid partial-marker
/// flicker while tokens arrive.
public enum CitationRenderer {

    public struct Rendered: Sendable, Equatable {
        /// Answer text with `[N]` markers replaced by superscript digits.
        public var text: String
        /// Sources actually cited, ascending by number; the numbers match the
        /// in-text superscripts exactly (numbering is per distinct email).
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
        let regex = try! NSRegularExpression(pattern: "\\[(\\d+)\\]")
        var text = answer
        var used = Set<Int>()
        var dropped: [Int] = []

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: text),
                  let digits = Range(match.range(at: 1), in: text),
                  let number = Int(text[digits]) else { continue }
            // Absorb one preceding space so the superscript sits immediately
            // after the word it follows (§6), and dropped markers leave no
            // hanging space.
            var lower = full.lowerBound
            if lower > text.startIndex, text[text.index(before: lower)] == " " {
                lower = text.index(before: lower)
            }
            if sourceMap[number] != nil {
                used.insert(number)
                text.replaceSubrange(lower..<full.upperBound, with: superscript(number))
            } else {
                dropped.append(number)
                text.replaceSubrange(lower..<full.upperBound, with: "")
            }
        }

        let sources = used.sorted().map { (number: $0, ref: sourceMap[$0]!) }
        return Rendered(text: text, sources: sources, droppedMarkers: dropped.reversed())
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
