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
    /// hook (nil in Phase 1). `accountEmail` (empty when unknown) names whose
    /// voice the draft is written in -- see `replyInstruction`'s doc comment
    /// for why this matters.
    public func assemble(thread: [ThreadMessage], grounding: [ContextChunk],
                        styleGuidance: String? = nil, accountEmail: String = "") -> AssembledDraftPrompt {
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
        bodyParts.append(replyInstruction(for: thread.last, accountEmail: accountEmail))

        return AssembledDraftPrompt(system: system, user: bodyParts.joined(separator: "\n\n"))
    }

    /// Nothing else in the assembled prompt identifies *who the user is* --
    /// `THREAD` carries only each message's `sender`, never a recipient, and
    /// the system prompt's "on behalf of the user" is a role description,
    /// not a name. Observed failure mode on a small local model: a message
    /// whose body itself opens with a greeting (e.g. "Hi Alex,") gets
    /// misread as identifying who the reply should address, producing a
    /// draft that greets the account owner instead of the correspondent.
    /// Naming both parties explicitly here, with an explicit negative
    /// constraint, is the fix -- `accountEmail` empty (unknown) falls back
    /// to the original, unqualified instruction.
    private func replyInstruction(for latest: ThreadMessage?, accountEmail: String) -> String {
        guard let latest else { return "Draft a reply to the message above." }
        guard !accountEmail.isEmpty else {
            return "Draft a reply to the most recent message above, from \(latest.sender), dated \(Self.ymd(latest.dateUnix))."
        }
        return """
        You are drafting this reply as \(accountEmail) \u{2014} the person who RECEIVED the message below, not its \
        sender, regardless of any name or greeting used inside the message body. Draft a reply to the most recent \
        message above, sent by \(latest.sender) on \(Self.ymd(latest.dateUnix)). Address the reply to \(latest.sender); \
        never address it to \(accountEmail).
        """
    }

    static func ymd(_ unix: Int64, timeZone: TimeZone = .current) -> String {
        PromptAssembler.ymd(unix, timeZone: timeZone)
    }
}
