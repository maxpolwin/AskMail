import Foundation

/// Recommends excerpt, context and answer budgets for the current provider
/// and model. Grounded in measurements (docs/model-tuning.md): memory follows
/// the model's real architecture (`ModelMemory`), and the number of excerpts
/// follows how many a model of that size can use well, not how many fit.
public enum TokenAdvisor {
    public struct Recommendation: Equatable, Sendable {
        public let contextTokens: Int
        public let answerTokens: Int
        public let excerpts: Int
        /// One-line, user-facing explanation of how these were derived.
        public let rationale: String

        public init(contextTokens: Int, answerTokens: Int,
                    excerpts: Int = Defaults.finalTopK, rationale: String) {
            self.contextTokens = contextTokens
            self.answerTokens = answerTokens
            self.excerpts = excerpts
            self.rationale = rationale
        }
    }

    /// Models below this many billion parameters lost accuracy once the prompt
    /// passed roughly 8k tokens and rarely cited sources in the benchmark, so
    /// they get fewer excerpts.
    public static let smallModelBillions = 4.5
    static let smallModelExcerpts = 8
    static let regularModelExcerpts = 13
    static let defaultAnswerTokens = 1000

    /// Headroom over the excerpts' own tokens, so a few long chunks don't push
    /// the lowest-ranked excerpt out of the budget.
    static let budgetHeadroom = 1.25

    /// Budgets for a local Ollama model. `memory` nil (architecture unknown)
    /// skips the memory cap rather than guessing one.
    public static func recommendLocal(parameterBillions: Double?, memory: ModelMemory?,
                                      tokensPerExcerpt: Int = Defaults.fallbackTokensPerExcerpt) -> Recommendation {
        let small = (parameterBillions ?? .infinity) < smallModelBillions
        let excerpts = parameterBillions == nil ? Defaults.finalTopK
            : (small ? smallModelExcerpts : regularModelExcerpts)
        var context = roundUp(Int(Double(excerpts * tokensPerExcerpt) * budgetHeadroom), to: 512)
        var notes: [String] = []

        if let memory {
            // Never recommend a window the Mac can't hold on the GPU.
            let fit = memory.maxWindowTokens() - Defaults.promptScaffoldTokens - defaultAnswerTokens
            if fit < context {
                context = max(Defaults.contextTokenRange.lowerBound, fit / 512 * 512)
                notes.append("Lowered to what this Mac can hold with this model.")
            }
            if let modelMax = memory.architecture.maxContextTokens {
                let limit = modelMax - Defaults.promptScaffoldTokens - defaultAnswerTokens
                if limit < context { context = max(Defaults.contextTokenRange.lowerBound, limit / 512 * 512) }
            }
        }
        context = Defaults.clamp(context, to: Defaults.contextTokenRange)

        var rationale = small
            ? "Small models (under about 4B parameters) lose accuracy as the prompt grows and often skip source citations, so fewer excerpts work better. A 7B model such as qwen2.5:7b cited reliably in testing, at about three times the waiting time."
            : "\(excerpts) excerpts balanced source coverage against waiting time in testing; each extra excerpt adds waiting time."
        if parameterBillions == nil {
            rationale = "The model\u{2019}s size isn\u{2019}t known, so this uses the default number of excerpts."
        }
        if !notes.isEmpty { rationale += " " + notes.joined(separator: " ") }
        return Recommendation(contextTokens: context, answerTokens: defaultAnswerTokens,
                              excerpts: excerpts, rationale: rationale)
    }

    /// Cloud providers: the model and memory are remote, so memory isn't the
    /// limit and the regular excerpt count applies.
    public static func recommendCloud(tokensPerExcerpt: Int = Defaults.fallbackTokensPerExcerpt) -> Recommendation {
        let excerpts = regularModelExcerpts
        return Recommendation(
            contextTokens: Defaults.clamp(roundUp(Int(Double(excerpts * tokensPerExcerpt) * budgetHeadroom), to: 512),
                                          to: Defaults.contextTokenRange),
            answerTokens: defaultAnswerTokens,
            excerpts: excerpts,
            rationale: "Runs in the cloud, so your Mac\u{2019}s memory isn\u{2019}t the limit.")
    }

    /// Budgets for a local OpenAI-compatible server. Its context window is the
    /// server's own setting (the API can't request one), so the email budget is
    /// what fits beside the answer and ~1k tokens of system prompt + question.
    /// Unknown context → the conservative defaults.
    public static func recommendLocalServer(serverContextTokens: Int?,
                                            tokensPerExcerpt: Int = Defaults.fallbackTokensPerExcerpt) -> Recommendation {
        let answer = 800
        let wanted = roundUp(Int(Double(Defaults.finalTopK * tokensPerExcerpt) * budgetHeadroom), to: 512)
        guard let server = serverContextTokens, server > 0 else {
            return Recommendation(
                contextTokens: Defaults.contextTokenLimit,
                answerTokens: answer,
                rationale: "Your server\u{2019}s context length isn\u{2019}t known. "
                    + "Set it to at least \(minimumServerContext(context: Defaults.contextTokenLimit, answer: answer)) "
                    + "tokens in the server app, or lower the context budget here.")
        }
        let fits = max(1024, (server - answer - 1000) / 512 * 512)
        return Recommendation(
            contextTokens: Defaults.clamp(min(wanted, fits), to: Defaults.contextTokenRange),
            answerTokens: answer,
            rationale: "Fits your server\u{2019}s reported \(server)-token context window.")
    }

    /// Smallest server context that holds `context` email tokens, the answer
    /// and ~1k tokens of system prompt + question.
    public static func minimumServerContext(context: Int, answer: Int) -> Int {
        context + answer + 1000
    }

    /// Seeds a first-run install before any model facts are known.
    public static func firstRun() -> Recommendation {
        recommendLocal(parameterBillions: nil, memory: nil)
    }

    private static func roundUp(_ value: Int, to step: Int) -> Int {
        (value + step - 1) / step * step
    }
}
