import Foundation

/// Display helpers for RFC 5322 header values: RFC 2047 encoded-word decoding
/// (so `=?UTF-8?Q?Monthly_report?=` reads as "Monthly report") and pulling a
/// readable domain out of a `From` header. Operates on untrusted input; fails
/// open to the raw value rather than throwing (SECURITY.md).
public enum MailHeader {

    /// Decodes RFC 2047 encoded-words (`=?charset?B|Q?text?=`) anywhere in a
    /// header value. Non-encoded runs pass through unchanged. Adjacent
    /// encoded-words separated only by whitespace fold together — the
    /// whitespace is dropped (RFC 2047 §6.2).
    public static func decode(_ value: String) -> String {
        // Fold whitespace that only separates two encoded-words.
        var s = value
        let range = NSRange(s.startIndex..., in: s)
        s = whitespaceJoiner.stringByReplacingMatches(in: s, range: range, withTemplate: "?==?")

        var result = s
        let matches = encodedWord.matches(in: s, range: NSRange(s.startIndex..., in: s))
        // Replace in reverse so earlier match ranges stay valid as we mutate.
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                  let csR = Range(match.range(at: 1), in: result),
                  let encR = Range(match.range(at: 2), in: result),
                  let txtR = Range(match.range(at: 3), in: result) else { continue }
            let charset = String(result[csR])
            let encoding = result[encR].lowercased()
            let text = String(result[txtR])

            let data: Data
            if encoding == "b" {
                data = Data(base64Encoded: text.filter { !$0.isWhitespace }) ?? Data()
            } else {  // "q": quoted-printable with '_' standing in for space.
                data = Mime.decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " "))
            }
            let decoded = String(data: data, encoding: stringEncoding(for: charset))
                ?? String(data: data, encoding: .isoLatin1)
                ?? text
            result.replaceSubrange(full, with: decoded)
        }
        return result
    }

    /// The organisation name from a `From` header: the host after `@`, stripped
    /// of subdomains *and* the TLD — the label right before the public suffix
    /// (`newsletter.bundesbank.de` → `bundesbank`, `mailservice.oenb.at` →
    /// `oenb`). Assumes a single-label suffix (`.de`, `.at`, `.com`); a
    /// multi-part suffix like `.co.uk` would yield `co` — acceptable for the
    /// source list. Falls back to the decoded display name when the header
    /// carries no address.
    public static func domain(fromSender sender: String) -> String {
        // Prefer the address inside <...>; else the whole value.
        let address: Substring
        if let lt = sender.firstIndex(of: "<"),
           let gt = sender[sender.index(after: lt)...].firstIndex(of: ">") {
            address = sender[sender.index(after: lt)..<gt]
        } else {
            address = sender[...]
        }
        guard let at = address.lastIndex(of: "@") else {
            return decode(sender).trimmingCharacters(in: .whitespaces)
        }
        let host = address[address.index(after: at)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t>"))
            .lowercased()
        let labels = host.split(separator: ".")
        // Drop the TLD: take the label just before it, else the host as-is.
        return labels.count >= 2 ? String(labels[labels.count - 2]) : host
    }

    /// The bare, lowercased email address from a `From`-style header value
    /// (`Name <addr@host>` or a bare address) — nil when the value carries no
    /// `@` address at all (e.g. a display-name-only header). Used to key
    /// Draft-Modus style-profile scopes (`StyleLearner`) at the most specific
    /// (address) level.
    ///
    /// Unlike `domain(fromSender:)` — which only needs the text after `@` and
    /// so is naturally immune to leading display-name/bracket junk — this
    /// needs the local-part too, so a malformed header with an unmatched `<`
    /// (no closing `>`) can't just fall back to the whole raw string: doing
    /// so would return `"John <john@example.com"` instead of the bare
    /// address, producing a garbage scope key. Instead, when no clean
    /// `<...>` pair is found, this recovers just the contiguous run of
    /// non-whitespace/non-bracket characters immediately around `@`.
    public static func address(fromSender sender: String) -> String? {
        let inner: Substring
        if let lt = sender.firstIndex(of: "<"),
           let gt = sender[sender.index(after: lt)...].firstIndex(of: ">") {
            inner = sender[sender.index(after: lt)..<gt]
        } else {
            inner = sender[...]
        }
        guard let at = inner.firstIndex(of: "@") else { return nil }
        let isAddressChar: (Character) -> Bool = { !$0.isWhitespace && $0 != "<" && $0 != ">" }
        let localPart = inner[..<at].reversed().prefix(while: isAddressChar).reversed()
        let domainPart = inner[inner.index(after: at)...].prefix(while: isAddressChar)
        guard !localPart.isEmpty, !domainPart.isEmpty else { return nil }
        return (String(localPart) + "@" + String(domainPart)).lowercased()
    }

    // MARK: Internals

    private static let encodedWord =
        try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=")
    private static let whitespaceJoiner =
        try! NSRegularExpression(pattern: "\\?=\\s+=\\?")

    private static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii": return .utf8
        case "iso-8859-1", "iso8859-1", "latin1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return .utf8
        }
    }
}
