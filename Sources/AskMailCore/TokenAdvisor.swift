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
        // Leave ~3 GB for the OS and app; the rest is the KV-cache budget, at
        // roughly a thousand context tokens per free gigabyte.
        let freeGB = max(0, ramGB - modelGB - 3)
        let context = step(Int(freeGB * 1000), min: 2048, max: 16384, step: 512)
        let answer = context >= 8192 ? 1000 : 800
        return Recommendation(
            contextTokens: context,
            answerTokens: answer,
            rationale: "Tuned to \(Int(ramGB.rounded())) GB of memory and a "
                + "\(String(format: "%.1f", modelGB)) GB model. More context means more "
                + "email per answer, but uses more memory and slows replies.")
    }

    /// Rounds to the nearest `step` (so it lands on a stepper tick) and clamps.
    private static func step(_ value: Int, min lo: Int, max hi: Int, step: Int) -> Int {
        let rounded = Int((Double(value) / Double(step)).rounded()) * step
        return Swift.max(lo, Swift.min(hi, rounded))
    }
}
