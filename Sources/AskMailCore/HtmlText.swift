import Foundation

/// HTML-to-text conversion plus newsletter boilerplate stripping.
/// Hand-rolled (no WebKit / NSAttributedString) so it runs headless in tests
/// and background ingestion without main-thread requirements.
public enum HtmlText {

    // MARK: HTML to plain text

    public static func plainText(html: String) -> String {
        var text = html

        // Drop script/style/head blocks entirely.
        for tag in ["script", "style", "head", "title"] {
            text = replace(text, pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ")
        }
        // Comments.
        text = replace(text, pattern: "<!--[\\s\\S]*?-->", with: " ")

        // Block-level closers become paragraph breaks; <br> and <hr> line breaks.
        text = replace(text, pattern: "(?i)</(p|div|tr|table|ul|ol|li|h[1-6]|blockquote)>", with: "\n\n")
        text = replace(text, pattern: "(?i)<(br|hr)\\s*/?>", with: "\n\n")

        // Strip every remaining tag.
        text = replace(text, pattern: "<[^>]+>", with: "")

        text = decodeEntities(text)

        // Normalize whitespace: collapse runs of spaces/tabs, cap blank lines.
        text = replace(text, pattern: "[ \\t]+", with: " ")
        text = replace(text, pattern: " ?\\n ?", with: "\n")
        text = replace(text, pattern: "\\n{3,}", with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Boilerplate stripping

    /// Drops footer paragraphs (unsubscribe blocks, tracking notices) so they
    /// never pollute chunks or retrieval. Heuristic, tuned on newsletters;
    /// operates per paragraph so real content is preserved.
    public static func stripBoilerplate(_ text: String) -> String {
        let boilerplate = try! NSRegularExpression(pattern: [
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

        let paragraphs = text.components(separatedBy: "\n\n")
        let kept = paragraphs.filter { paragraph in
            let range = NSRange(paragraph.startIndex..., in: paragraph)
            return boilerplate.firstMatch(in: paragraph, range: range) == nil
        }
        return kept.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
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
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
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
        }
        return out
    }
}
