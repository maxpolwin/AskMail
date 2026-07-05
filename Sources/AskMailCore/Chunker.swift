import Foundation

/// Splits text into overlapping chunks sized for the embedding window
/// (~512 tokens with ~64 tokens overlap at the ~4 chars/token approximation).
/// Prefers paragraph, then line, then sentence boundaries near the window end.
public struct Chunker: Sendable {
    public var chunkChars: Int
    public var overlapChars: Int

    public init(chunkChars: Int = Defaults.chunkChars,
                overlapChars: Int = Defaults.overlapChars) {
        self.chunkChars = max(chunkChars, 64)
        self.overlapChars = min(max(overlapChars, 0), self.chunkChars / 2)
    }

    public func chunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let characters = Array(trimmed)
        guard characters.count > chunkChars else { return [trimmed] }

        var chunks: [String] = []
        var start = 0
        while start < characters.count {
            let hardEnd = min(start + chunkChars, characters.count)
            var end = hardEnd
            if hardEnd < characters.count {
                end = preferredBreak(in: characters, start: start, hardEnd: hardEnd)
            }
            let piece = String(characters[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            if end >= characters.count { break }
            start = max(end - overlapChars, start + 1)
        }
        return chunks
    }

    /// Looks backwards from the hard window end for a natural boundary in the
    /// second half of the window: paragraph break, newline, then sentence end.
    private func preferredBreak(in characters: [Character], start: Int, hardEnd: Int) -> Int {
        let floor = start + chunkChars / 2
        var newlineAt: Int? = nil
        var sentenceAt: Int? = nil
        var index = hardEnd - 1
        while index > floor {
            let c = characters[index]
            if c == "\n" {
                if index > floor + 1, characters[index - 1] == "\n" {
                    return index + 1  // paragraph break, best option
                }
                if newlineAt == nil { newlineAt = index + 1 }
            } else if sentenceAt == nil, c == " ", index > 0,
                      ".!?".contains(characters[index - 1]) {
                sentenceAt = index + 1
            }
            index -= 1
        }
        return newlineAt ?? sentenceAt ?? hardEnd
    }
}
