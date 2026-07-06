import Foundation

/// The fully assembled request for a chat provider, plus the citation map.
public struct AssembledPrompt: Sendable {
    /// Verbatim system prompt from settings.
    public var system: String
    /// Session block + CONTEXT + QUESTION per docs/prompt-contract.md §5.
    public var user: String
    /// `N -> source email`, one number per distinct email (contract §3).
    /// Used for both inline superscript links and the numbered source list.
    public var sourceMap: [Int: SourceRef]
}

/// Implements docs/prompt-contract.md exactly: context block format (§3),
/// session block (§4), final assembly (§5), and the per-distinct-email
/// citation numbering. Change control (§8): retrieval parameters and this
/// assembler must move together.
public struct PromptAssembler: Sendable {
    public var systemPrompt: String
    public var contextTokenLimit: Int
    public var sessionTurnCap: Int

    public init(systemPrompt: String = Defaults.defaultSystemPrompt,
                contextTokenLimit: Int = Defaults.contextTokenLimit,
                sessionTurnCap: Int = Defaults.sessionTurnCap) {
        self.systemPrompt = systemPrompt
        self.contextTokenLimit = contextTokenLimit
        self.sessionTurnCap = sessionTurnCap
    }

    /// `chunks` must arrive in fused-rank order (best first) and are never
    /// re-sorted here (contract §3). Budget trimming drops lowest-ranked
    /// chunks first; numbers are assigned after the trim so numbering has
    /// no holes.
    public func assemble(question: String,
                         chunks: [ContextChunk],
                         session: [SessionTurn]) -> AssembledPrompt {
        let budgeted = trimToBudget(chunks)

        // One number per distinct email, in fused-rank order of first appearance.
        var numberFor: [String: Int] = [:]
        var sourceMap: [Int: SourceRef] = [:]
        var nextNumber = 1
        // Chunks are in fused-rank order, so the first chunk seen for an email
        // is its best-scoring one — use that as the email's relevance.
        for chunk in budgeted where numberFor[chunk.messageID] == nil {
            numberFor[chunk.messageID] = nextNumber
            sourceMap[nextNumber] = SourceRef(messageID: chunk.messageID,
                                              subject: chunk.subject,
                                              sender: chunk.sender,
                                              dateUnix: chunk.dateUnix,
                                              relevance: chunk.score > 0 ? chunk.score : nil)
            nextNumber += 1
        }

        let contextBlock = budgeted
            .map { renderChunk($0, number: numberFor[$0.messageID]!) }
            .joined(separator: "\n\n")

        var bodyParts: [String] = []
        if let sessionBlock = renderSession(session) {
            bodyParts.append(sessionBlock)
        }
        bodyParts.append("CONTEXT:\n\(contextBlock)")
        bodyParts.append("QUESTION:\n\(question)")

        return AssembledPrompt(system: systemPrompt,
                               user: bodyParts.joined(separator: "\n\n"),
                               sourceMap: sourceMap)
    }

    // MARK: Context block (§3)

    func renderChunk(_ chunk: ContextChunk, number: Int) -> String {
        "--- [\(number)] from: \(chunk.sender) | date: \(Self.ymd(chunk.dateUnix)) | source: \(chunk.source.rawValue) ---\n\(chunk.text)"
    }

    /// Drops lowest-ranked chunks first while over `contextTokenLimit`.
    /// Always keeps at least the top-ranked chunk.
    private func trimToBudget(_ chunks: [ContextChunk]) -> [ContextChunk] {
        var kept: [ContextChunk] = []
        var total = 0
        for chunk in chunks {
            let cost = TokenEstimator.tokens(renderChunk(chunk, number: 99))
            if !kept.isEmpty, total + cost > contextTokenLimit { break }
            kept.append(chunk)
            total += cost
        }
        return kept
    }

    // MARK: Session block (§4)

    /// Nil when the buffer is empty. Caps at the most recent turns, oldest first.
    func renderSession(_ session: [SessionTurn]) -> String? {
        guard !session.isEmpty else { return nil }
        let recent = session.suffix(sessionTurnCap)
        var lines = ["Earlier in this conversation:"]
        for turn in recent {
            lines.append("Q: \(turn.question)")
            lines.append("A: \(turn.answer)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Date rendering

    /// Renders in the given time zone (default the device's own, matching
    /// DateFilter's day/week/month boundaries) so a source's displayed date
    /// agrees with the day the user would call "today"/"yesterday" when
    /// asking about it. Built fresh per call rather than cached, since the
    /// zone can vary between calls (production default vs. a fixed zone in
    /// tests); DateFormatter construction is cheap at this call frequency
    /// (once per rendered source, not per token).
    public static func ymd(_ unix: Int64, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
