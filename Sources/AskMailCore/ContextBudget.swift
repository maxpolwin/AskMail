import Foundation

/// How one question's model window is shared: the reserved prompt, the email
/// excerpts actually used, the part of the email budget retrieval doesn't
/// fill, and the reserved answer. A pure value — the Settings panel draws it
/// and the tests pin its arithmetic.
///
/// "Excerpts" are retrieved chunks (~512 tokens each), not distinct emails:
/// two chunks of one email are two excerpts but one entry in the Sources list.
public struct ContextBudget: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Sources fill most of the email budget and the window fits.
        case fits
        /// The excerpts need more than the email budget; the lowest-ranked
        /// ones are dropped (`PromptAssembler.trimToBudget`).
        case needsMoreBudget(neededTokens: Int)
        /// At least half the email budget stays empty.
        case mostlyUnused(percentUsed: Int)
        /// The window's rough memory cost exceeds what's free for it.
        case aboveMemory(estimatedGB: Double, availableGB: Double)
        /// The window is larger than the local server reports it loaded.
        case aboveServerWindow(serverTokens: Int)
    }

    public let promptTokens: Int
    public let emailUsedTokens: Int
    public let emailUnusedTokens: Int
    public let answerTokens: Int
    /// Tokens the excerpts would take if none were dropped.
    public let emailNeededTokens: Int
    /// Rough memory for the window; nil when no memory figure applies (cloud
    /// providers, local servers).
    public let estimatedMemoryGB: Double?
    public let availableMemoryGB: Double?
    public let status: Status

    public var windowTokens: Int { promptTokens + emailUsedTokens + emailUnusedTokens + answerTokens }

    /// Share of the email budget the excerpts fill, 0...100.
    public var emailUsedPercent: Int {
        let budget = emailUsedTokens + emailUnusedTokens
        return budget > 0 ? Int((Double(emailUsedTokens) / Double(budget) * 100).rounded()) : 0
    }

    public init(excerpts: Int, contextTokens: Int, answerTokens: Int,
                tokensPerExcerpt: Int = Defaults.fallbackTokensPerExcerpt,
                promptTokens: Int = Defaults.promptScaffoldTokens,
                availableMemoryGB: Double? = nil,
                serverWindowTokens: Int? = nil) {
        let needed = max(0, excerpts) * max(0, tokensPerExcerpt)
        let budget = max(0, contextTokens)
        let used = min(needed, budget)
        self.promptTokens = max(0, promptTokens)
        self.emailUsedTokens = used
        self.emailUnusedTokens = budget - used
        self.answerTokens = max(0, answerTokens)
        self.emailNeededTokens = needed
        self.availableMemoryGB = availableMemoryGB

        let window = self.promptTokens + budget + self.answerTokens
        let estimated = availableMemoryGB.map { _ in Double(window) / Double(Defaults.contextTokensPerGB) }
        self.estimatedMemoryGB = estimated

        // Most serious first: a window the machine or server can't hold beats
        // a budget that is merely tight or loose.
        if let server = serverWindowTokens, server > 0, window > server {
            status = .aboveServerWindow(serverTokens: server)
        } else if let estimated, let available = availableMemoryGB, estimated > available {
            status = .aboveMemory(estimatedGB: estimated, availableGB: available)
        } else if needed > budget {
            status = .needsMoreBudget(neededTokens: needed)
        } else if budget > 0, used * 2 < budget {
            status = .mostlyUnused(percentUsed: Int((Double(used) / Double(budget) * 100).rounded()))
        } else {
            status = .fits
        }
    }

    /// Per-excerpt cost from the average chunk length in the index (nil when
    /// the index is empty): the chunk's tokens plus its wrapper and header.
    public static func tokensPerExcerpt(averageChunkChars: Int?) -> Int {
        guard let chars = averageChunkChars, chars > 0 else { return Defaults.fallbackTokensPerExcerpt }
        return (chars + 3) / 4 + Defaults.excerptOverheadTokens
    }
}
