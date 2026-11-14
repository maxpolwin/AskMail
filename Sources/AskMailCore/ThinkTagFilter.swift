import Foundation

/// Streaming-safe remover of `<think>…</think>` reasoning blocks.
///
/// Some local reasoning models (and some servers' chat templates) emit their
/// chain of thought inline in `content`; shown verbatim it would pollute the
/// answer and, worse, its citation-looking fragments. Tags can arrive split
/// across chunks (`"<thi"` + `"nk>"`), so a possible partial tag at the end of
/// the buffer is held back until the next chunk decides what it is.
///
/// Limitation, by design: only an explicit opening tag starts a hidden block.
/// A response that contains a bare `</think>` with no opener (templates that
/// pre-fill the opener in the prompt) passes through unchanged rather than
/// guessing and risking dropping real answer text.
public struct ThinkTagFilter: Sendable {
    private static let open = "<think>"
    private static let close = "</think>"

    private var pending = ""
    private var inThink = false
    /// After a closing tag, swallow the blank line models put before the answer.
    private var trimLeading = false

    public init() {}

    /// Feeds one streamed chunk, returning the text that is safe to show now.
    public mutating func process(_ chunk: String) -> String {
        pending += chunk
        var output = ""
        while true {
            if inThink {
                if let range = pending.range(of: Self.close) {
                    pending.removeSubrange(pending.startIndex..<range.upperBound)
                    inThink = false
                    trimLeading = true
                    continue
                }
                // Still inside the block: drop everything except a possible
                // partial closing tag at the very end.
                let keep = Self.partialSuffixLength(of: pending, matching: Self.close)
                pending = String(pending.suffix(keep))
                return output
            }
            if let range = pending.range(of: Self.open) {
                output += emit(String(pending[pending.startIndex..<range.lowerBound]))
                pending.removeSubrange(pending.startIndex..<range.upperBound)
                inThink = true
                continue
            }
            let keep = Self.partialSuffixLength(of: pending, matching: Self.open)
            let splitIndex = pending.index(pending.endIndex, offsetBy: -keep)
            output += emit(String(pending[pending.startIndex..<splitIndex]))
            pending = String(pending[splitIndex...])
            return output
        }
    }

    /// Call once at end of stream: a held-back partial tag that never
    /// completed was ordinary text (outside a block) or is discarded (inside).
    public mutating func finish() -> String {
        defer { pending = "" }
        return inThink ? "" : emit(pending)
    }

    private mutating func emit(_ text: String) -> String {
        guard trimLeading else { return text }
        let trimmed = text.drop(while: { $0.isWhitespace })
        if !trimmed.isEmpty { trimLeading = false }
        return String(trimmed)
    }

    /// Length of the longest suffix of `text` that is a proper prefix of
    /// `tag` — i.e. how much might still turn into the tag.
    private static func partialSuffixLength(of text: String, matching tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1)
        where tag.hasPrefix(text.suffix(length)) {
            return length
        }
        return 0
    }
}
