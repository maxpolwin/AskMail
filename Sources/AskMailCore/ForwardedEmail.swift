import Foundation

/// Detects the original author of a forwarded email so citations can
/// attribute to them instead of to whoever forwarded the message.
///
/// Matches the well-known forward markers used by Apple Mail
/// ("Begin forwarded message:"), Gmail ("---------- Forwarded message
/// ---------"), and Outlook ("-----Original Message-----"), then reads the
/// "From:" line of the embedded header block that follows. Anything else
/// (a custom preamble, an HTML-mangled marker) falls through silently —
/// the caller keeps attributing to the raw `From` header, same as today.
public enum ForwardedEmail {

    /// Header lines that make up the embedded block under a forward marker
    /// (Apple Mail/Gmail use "From/Subject/Date/To/Cc"; Outlook uses
    /// "From/Sent/To/Cc/Subject"). Recognized regardless of order.
    private static let headerLinePrefixes = ["from:", "to:", "cc:", "bcc:", "date:", "sent:", "subject:"]

    /// Returns the embedded `From:` value from the first forwarded header
    /// block found in `bodyText`, or nil if no known marker appears.
    public static func detectOriginalSender(in bodyText: String) -> String? {
        let lines = bodyText.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where isForwardMarker(line) {
            for candidate in lines[(index + 1)...].prefix(10) {
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("from:") else { continue }
                let sender = trimmed.dropFirst("from:".count).trimmingCharacters(in: .whitespaces)
                return sender.isEmpty ? nil : sender
            }
        }
        return nil
    }

    /// Removes the marker line and the embedded header block that follows it
    /// (contiguous From/To/Cc/Date/Sent/Subject lines, up through the blank
    /// line separating them from the quoted content) so the text that gets
    /// chunked and embedded carries the forwarded message's actual content,
    /// not raw mail headers. A no-op when no known marker is present.
    ///
    /// Must run before `Chunker.chunk` — this is what keeps header noise out
    /// of the vector index, not just out of the citation's displayed sender.
    public static func stripHeaderBlock(from bodyText: String) -> String {
        var lines = bodyText.components(separatedBy: .newlines)
        guard let markerIndex = lines.firstIndex(where: isForwardMarker) else { return bodyText }

        var end = markerIndex + 1
        // Apple Mail puts a blank line between the marker and the header
        // block; Gmail/Outlook don't. Skip it either way before scanning
        // for headers, so it isn't mistaken for the header/content separator.
        while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        }
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                end += 1  // consume the blank line separating headers from content
                break
            }
            guard headerLinePrefixes.contains(where: { trimmed.lowercased().hasPrefix($0) }) else { break }
            end += 1
        }
        lines.removeSubrange(markerIndex..<end)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isForwardMarker(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized.contains("forwarded message") || normalized.contains("original message")
    }
}
