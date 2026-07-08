import Foundation

/// HTML-to-text conversion plus newsletter boilerplate stripping.
/// Hand-rolled (no WebKit / NSAttributedString) so it runs headless in tests
/// and background ingestion without main-thread requirements.
public enum HtmlText {

    // MARK: HTML to plain text

    public static func plainText(html: String) -> String {
        // Hardening H-9: truncate BEFORE any regex pass runs, so the total
        // regex work is bounded regardless of how large the underlying
        // message claims to be. Truncation, not rejection: a legitimate
        // giant newsletter should still index its head rather than fail
        // ingestion outright, while a hostile payload crafted to blow up
        // the passes below is capped to a fixed amount of work.
        var text = truncated(html)

        // Drop script/style/head/title blocks entirely.
        for regex in scriptStyleHeadTitleRegexes {
            text = replace(text, regex: regex, with: " ")
        }
        // Comments.
        text = replace(text, regex: commentRegex, with: " ")

        // Block-level closers become paragraph breaks; <br> and <hr> line breaks.
        text = replace(text, regex: blockCloserRegex, with: "\n\n")
        text = replace(text, regex: brHrRegex, with: "\n\n")

        // Strip every remaining tag.
        text = replace(text, regex: anyTagRegex, with: "")

        text = decodeEntities(text)

        // Normalize whitespace: collapse runs of spaces/tabs, cap blank lines.
        text = replace(text, regex: whitespaceRunRegex, with: " ")
        text = replace(text, regex: spaceAroundNewlineRegex, with: "\n")
        text = replace(text, regex: blankLineRunRegex, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates to at most `maxBytes` UTF-8 bytes. Backs the cut point off
    /// to a scalar boundary (a byte that isn't a UTF-8 continuation byte,
    /// i.e. doesn't match `10xxxxxx`) and drops the interrupted trailing
    /// scalar entirely, rather than cutting mid-scalar: `String(decoding:
    /// as:)` doesn't trap on a split sequence, but it *substitutes* U+FFFD
    /// (3 bytes) for the truncated remainder, which can push the result
    /// back over `maxBytes` — defeating the point of a hard cap.
    static func truncated(_ html: String, maxBytes: Int = Defaults.maxHtmlBytes) -> String {
        let utf8 = html.utf8
        guard utf8.count > maxBytes else { return html }
        var cutoff = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while cutoff > utf8.startIndex, utf8[cutoff] & 0b1100_0000 == 0b1000_0000 {
            cutoff = utf8.index(before: cutoff)
        }
        return String(decoding: utf8[..<cutoff], as: UTF8.self)
    }

    // MARK: Boilerplate stripping

    /// Drops footer paragraphs (unsubscribe blocks, tracking notices) so they
    /// never pollute chunks or retrieval. Heuristic, tuned on newsletters;
    /// operates per paragraph so real content is preserved.
    public static func stripBoilerplate(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        let kept = paragraphs.filter { paragraph in
            let range = NSRange(paragraph.startIndex..., in: paragraph)
            return boilerplateRegex.firstMatch(in: paragraph, range: range) == nil
        }
        return kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Precompiled regexes (hardening H-9)
    //
    // All patterns below were previously compiled fresh on every call, in a
    // hot ingest loop over attacker-controlled HTML. `static let` compiles
    // each pattern exactly once per process. While consolidating, every
    // pattern was scanned for catastrophic-backtracking shapes and two were
    // found and fixed (measured with the standalone perf harness described
    // below, not just inspected):
    //
    // 1. The tag-open patterns used `[^>]+`/`[^>]*`. Against adversarial
    //    input with many `<` and no matching `>` (e.g. `<<<<<<...`), each
    //    `<` scans all the way to the end of the input before failing — an
    //    O(n^2) blowup. Fixed by restricting the class to `[^<>]` (a tag's
    //    contents never legitimately contain another `<`), so a run of
    //    unmatched `<` fails each attempt immediately instead of
    //    rescanning to the end.
    // 2. The block-stripping patterns (script/style/head/title, HTML
    //    comments) used a lazy dot-all interior, e.g.
    //    `<script\b[^<>]*>[\s\S]*?</script>`. Against many *unclosed*
    //    occurrences of the same opening marker (e.g. `<script><script>...`
    //    repeated), every occurrence restarts a fresh scan to the end of
    //    the input hunting for a `</script>` that never comes — O(n * k)
    //    for k occurrences, confirmed experimentally to blow past a 5s
    //    budget at a few thousand repeats (2s at just 5,000 x 4 chars).
    //    Fixed by excluding another occurrence of the same opening/closing
    //    marker from the interior class via a negative lookahead
    //    (`(?:(?!</?script)[\s\S])*`), so a run of unclosed openers fails
    //    fast at the very next occurrence instead of scanning to the end
    //    each time — confirmed back under budget by the same harness
    //    (0.13s at 262,144 repeats, ~2 MB).

    private static let scriptStyleHeadTitleRegexes: [NSRegularExpression] =
        ["script", "style", "head", "title"].map { tag in
            try! NSRegularExpression(
                pattern: "<\(tag)\\b[^<>]*>(?:(?!</?\(tag)\\b)[\\s\\S])*</\(tag)>",
                options: [.caseInsensitive])
        }

    private static let commentRegex = try! NSRegularExpression(
        pattern: "<!--(?:(?!<!--|-->)[\\s\\S])*-->", options: [.caseInsensitive])

    private static let blockCloserRegex = try! NSRegularExpression(
        pattern: "</(p|div|tr|table|ul|ol|li|h[1-6]|blockquote)>",
        options: [.caseInsensitive])

    private static let brHrRegex = try! NSRegularExpression(
        pattern: "<(br|hr)\\s*/?>", options: [.caseInsensitive])

    /// Catch-all tag stripper. `[^<>]+` (not `[^>]+`) so a run of unmatched
    /// `<` characters fails fast instead of scanning to end-of-string on
    /// every attempt (see the note above).
    private static let anyTagRegex =
        try! NSRegularExpression(pattern: "<[^<>]+>", options: [.caseInsensitive])

    private static let whitespaceRunRegex =
        try! NSRegularExpression(pattern: "[ \\t]+", options: [.caseInsensitive])
    private static let spaceAroundNewlineRegex =
        try! NSRegularExpression(pattern: " ?\\n ?", options: [.caseInsensitive])
    private static let blankLineRunRegex =
        try! NSRegularExpression(pattern: "\\n{3,}", options: [.caseInsensitive])

    private static let numericEntityRegex =
        try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")

    private static let boilerplateRegex = try! NSRegularExpression(pattern: [
        "unsubscribe",
        "abmelden",
        "abbestellen",
        "sie erhalten diese e-?mail",
        "you (are receiving|received) this",
        "view (this email )?in (your )?browser",
        "im browser (ansehen|anzeigen|\u{00f6}ffnen)",
        "manage (your )?(email )?preferences",
        "update your preferences",
    ].joined(separator: "|"), options: [.caseInsensitive])

    // MARK: Helpers

    private static func replace(_ text: String, regex: NSRegularExpression, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
            "&auml;": "\u{00e4}", "&ouml;": "\u{00f6}", "&uuml;": "\u{00fc}",
            "&Auml;": "\u{00c4}", "&Ouml;": "\u{00d6}", "&Uuml;": "\u{00dc}",
            "&szlig;": "\u{00df}", "&euro;": "\u{20ac}",
        ]
        for (entity, value) in named {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities, decimal and hex.
        let matches = numericEntityRegex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
        for match in matches {
            guard let full = Range(match.range, in: out),
                  let hexFlag = Range(match.range(at: 1), in: out),
                  let digits = Range(match.range(at: 2), in: out) else { continue }
            let radix = out[hexFlag].isEmpty ? 10 : 16
            if let value = UInt32(out[digits], radix: radix),
               let scalar = Unicode.Scalar(value) {
                out.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return out
    }
}
