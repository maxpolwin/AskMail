import Foundation

/// The fully assembled draft-generation request — mirrors `AssembledPrompt`
/// but for Draft-Modus (docs/draft-contract.md) rather than Q&A
/// (docs/prompt-contract.md).
public struct AssembledDraftPrompt: Sendable {
    public var system: String
    public var user: String
}

/// Composes a reply-draft prompt from the resolved thread, retrieval-grounded
/// context, and (a later phase's) learned style guidance. Implements
/// docs/draft-contract.md exactly.
public struct DraftAssembler: Sendable {
    public var systemPrompt: String
    public var groundingTopK: Int

    public init(systemPrompt: String = Defaults.defaultDraftSystemPrompt,
               groundingTopK: Int = Defaults.draftGroundingTopK) {
        self.systemPrompt = systemPrompt
        self.groundingTopK = groundingTopK
    }

    /// `thread` must arrive oldest-first (`SQLiteStore.threadMessages`) and
    /// include the message being replied to as its last element. `grounding`
    /// must arrive in fused-rank order, best first
    /// (`Retriever.hybridRetrieve`'s output, already excluding the thread's
    /// own messages) — trimmed here to `groundingTopK`, since draft grounding
    /// has no date-scoped-question concept to layer `topK` on top of the way
    /// `QueryService` does. `styleGuidance` is a later phase's learned-style
    /// hook (nil in Phase 1).
    public func assemble(thread: [ThreadMessage], grounding: [ContextChunk],
                        styleGuidance: String? = nil) -> AssembledDraftPrompt {
        let threadBlock = thread
            .map { "--- \($0.sender) | \(Self.ymd($0.dateUnix)) ---\n\($0.bodyText)" }
            .joined(separator: "\n\n")

        let groundingChunks = Array(grounding.prefix(groundingTopK))

        var system = systemPrompt
        if let styleGuidance, !styleGuidance.isEmpty {
            system += "\n\nSTYLE GUIDANCE (how this user writes; match their tone and register):\n\(styleGuidance)"
        }

        var bodyParts: [String] = []
        bodyParts.append("THREAD (oldest first):\n\(threadBlock)")
        if !groundingChunks.isEmpty {
            let groundingBlock = groundingChunks
                .map { "--- from: \($0.sender) | date: \(Self.ymd($0.dateUnix)) ---\n\($0.text)" }
                .joined(separator: "\n\n")
            bodyParts.append("CONTEXT:\n\(groundingBlock)")
        }
        bodyParts.append(replyInstruction(for: thread.last))

        return AssembledDraftPrompt(system: system, user: bodyParts.joined(separator: "\n\n"))
    }

    private func replyInstruction(for latest: ThreadMessage?) -> String {
        guard let latest else { return "Draft a reply to the message above." }
        return "Draft a reply to the most recent message above, from \(latest.sender), dated \(Self.ymd(latest.dateUnix))."
    }

    static func ymd(_ unix: Int64, timeZone: TimeZone = .current) -> String {
        PromptAssembler.ymd(unix, timeZone: timeZone)
    }
}
