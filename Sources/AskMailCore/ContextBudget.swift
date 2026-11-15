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
        /// The model plus this window is estimated to exceed what the Mac lets
        /// the GPU use; Ollama then moves part of the model to the CPU.
        case aboveMemory(estimatedGB: Double, limitGB: Double)
        /// The window is larger than the model was trained for.
        case aboveModelWindow(maxTokens: Int)
        /// The window is larger than the local server reports it loaded.
        case aboveServerWindow(serverTokens: Int)
    }

    public let promptTokens: Int
    public let emailUsedTokens: Int
    public let emailUnusedTokens: Int
    public let answerTokens: Int
    /// Tokens the excerpts would take if none were dropped.
    public let emailNeededTokens: Int
    /// Estimated memory for the model and this window; nil when the model's
    /// architecture isn't known (cloud providers, local servers, unfamiliar
    /// models) — no figure is better than a guessed one.
    public let estimatedMemoryBytes: Double?
    public let gpuLimitBytes: Int64?
    public let status: Status

    public var windowTokens: Int { promptTokens + emailUsedTokens + emailUnusedTokens + answerTokens }
    public var estimatedMemoryGB: Double? { estimatedMemoryBytes.map(gigabytes) }
    public var gpuLimitGB: Double? { gpuLimitBytes.map { gigabytes(Double($0)) } }

    /// Share of the email budget the excerpts fill, 0...100.
    public var emailUsedPercent: Int {
        let budget = emailUsedTokens + emailUnusedTokens
        return budget > 0 ? Int((Double(emailUsedTokens) / Double(budget) * 100).rounded()) : 0
    }

    public init(excerpts: Int, contextTokens: Int, answerTokens: Int,
                tokensPerExcerpt: Int = Defaults.fallbackTokensPerExcerpt,
                promptTokens: Int = Defaults.promptScaffoldTokens,
                memory: ModelMemory? = nil,
                serverWindowTokens: Int? = nil) {
        let needed = max(0, excerpts) * max(0, tokensPerExcerpt)
        let budget = max(0, contextTokens)
        let used = min(needed, budget)
        self.promptTokens = max(0, promptTokens)
        self.emailUsedTokens = used
        self.emailUnusedTokens = budget - used
        self.answerTokens = max(0, answerTokens)
        self.emailNeededTokens = needed

        let window = self.promptTokens + budget + self.answerTokens
        let estimated = memory?.estimatedBytes(windowTokens: window)
        self.estimatedMemoryBytes = estimated
        self.gpuLimitBytes = memory?.gpuLimitBytes

        // Most serious first: a window the server or the model can't take, or
        // the Mac can't hold, beats a budget that is merely tight or loose.
        if let server = serverWindowTokens, server > 0, window > server {
            status = .aboveServerWindow(serverTokens: server)
        } else if let maxTokens = memory?.architecture.maxContextTokens, window > maxTokens {
            status = .aboveModelWindow(maxTokens: maxTokens)
        } else if let memory, let estimated,
                  estimated > Double(memory.gpuLimitBytes) * ModelMemory.warnFraction {
            status = .aboveMemory(estimatedGB: gigabytes(estimated),
                                  limitGB: gigabytes(Double(memory.gpuLimitBytes)))
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
