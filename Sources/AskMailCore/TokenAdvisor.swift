import Foundation

/// Recommends context- and answer-token budgets for the current provider and
/// machine. A local model's context is bounded by free RAM — Ollama's KV cache
/// grows with the context window — so the recommendation leaves room for the
/// model weights and the OS. A cloud provider runs remotely, so RAM doesn't
/// bind and the context can be more generous.
public enum TokenAdvisor {
    public struct Recommendation: Equatable, Sendable {
        public let contextTokens: Int
        public let answerTokens: Int
        /// One-line, user-facing explanation of how these were derived.
        public let rationale: String
    }

    public static func recommend(isLocal: Bool, modelSizeMB: Int,
                                 physicalMemoryBytes: UInt64) -> Recommendation {
        let ramGB = Double(physicalMemoryBytes) / 1_073_741_824

        guard isLocal else {
            return Recommendation(
                contextTokens: 8192,
                answerTokens: 1000,
                rationale: "Runs in the cloud, so your Mac's memory isn't the limit. "
                    + "A larger context lets more sources inform each answer.")
        }

        let modelGB = Double(modelSizeMB) / 1000
        // The free memory is the KV-cache budget, at roughly a thousand
        // tokens of window per gigabyte. The window holds the email context
        // plus the answer plus the prompt scaffold, so the context gets what
        // is left after those (the Settings gauge uses the same arithmetic,
        // so the recommendation never lands in its own warning).
        let freeGB = availableMemoryGB(modelSizeMB: modelSizeMB, physicalMemoryBytes: physicalMemoryBytes)
        let windowTokens = Int(freeGB * Double(Defaults.contextTokensPerGB))
        let context = step(windowTokens - Defaults.promptScaffoldTokens - 1000,
                           min: 2048, max: 16384, step: 512)
        let answer = context >= 8192 ? 1000 : 800
        return Recommendation(
            contextTokens: context,
            answerTokens: answer,
            rationale: "Tuned to \(Int(ramGB.rounded())) GB of memory and a "
                + "\(String(format: "%.1f", modelGB)) GB model. More context means more "
                + "email per answer, but uses more memory and slows replies.")
    }

    /// Memory left for the context window after the model weights and ~3 GB
    /// for the OS and app. The recommendation and the budget gauge share it.
    public static func availableMemoryGB(modelSizeMB: Int, physicalMemoryBytes: UInt64) -> Double {
        let ramGB = Double(physicalMemoryBytes) / 1_073_741_824
        return max(0, ramGB - Double(modelSizeMB) / 1000 - 3)
    }

    /// Budgets for a local OpenAI-compatible server. Its context window is the
    /// server's own setting (the API can't request one), so the email budget is
    /// what fits beside the answer and ~1k tokens of system prompt + question.
    /// Unknown context → the conservative 4096/800 defaults.
    public static func recommendLocalServer(serverContextTokens: Int?) -> Recommendation {
        let answer = 800
        guard let server = serverContextTokens, server > 0 else {
            return Recommendation(
                contextTokens: Defaults.contextTokenLimit,
                answerTokens: answer,
                rationale: "Your server\u{2019}s context length isn\u{2019}t known. "
                    + "Set it to at least \(minimumServerContext(context: Defaults.contextTokenLimit, answer: answer)) "
                    + "tokens in the server app, or lower the context budget here.")
        }
        let context = step(server - answer - 1000, min: 1024,
                           max: Defaults.contextTokenRange.upperBound, step: 512)
        return Recommendation(
            contextTokens: context,
            answerTokens: answer,
            rationale: "Fits your server\u{2019}s reported \(server)-token context window.")
    }

    /// Smallest server context that holds `context` email tokens, the answer
    /// and ~1k tokens of system prompt + question.
    public static func minimumServerContext(context: Int, answer: Int) -> Int {
        context + answer + 1000
    }

    /// Rounds to the nearest `step` (so it lands on a stepper tick) and clamps.
    private static func step(_ value: Int, min lo: Int, max hi: Int, step: Int) -> Int {
        let rounded = Int((Double(value) / Double(step)).rounded()) * step
        return Swift.max(lo, Swift.min(hi, rounded))
    }
}
