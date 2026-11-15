import Foundation

/// The few architecture numbers that decide how much memory a model's context
/// window costs, read from Ollama's `/api/show` (`model_info`). The KV cache
/// grows by `kvBytesPerToken` for every token of window, so this — not a flat
/// rule of thumb — is what the Settings memory gauge is built on.
public struct ModelArchitecture: Sendable, Equatable {
    public let layers: Int
    public let kvHeads: Int
    public let keyLength: Int
    public let valueLength: Int
    /// Longest window the model was trained for; nil when not reported.
    public let maxContextTokens: Int?

    public init(layers: Int, kvHeads: Int, keyLength: Int, valueLength: Int, maxContextTokens: Int? = nil) {
        self.layers = layers
        self.kvHeads = kvHeads
        self.keyLength = keyLength
        self.valueLength = valueLength
        self.maxContextTokens = maxContextTokens
    }

    /// Bytes of KV cache one token adds, at Ollama's default f16 cache
    /// precision (2 bytes per value; keys and values both cached). A quantized
    /// cache would cost less, so this errs on the high side.
    public var kvBytesPerToken: Int {
        layers * kvHeads * (keyLength + valueLength) * 2
    }

    /// Reads `model_info`. Nil — never a guess — when anything needed is
    /// missing or implausible (an unfamiliar architecture, per-layer arrays,
    /// zero or absurd values): the UI then shows no memory figure.
    static func parse(modelInfo: [String: Any]) -> ModelArchitecture? {
        guard let name = modelInfo["general.architecture"] as? String, !name.isEmpty else { return nil }
        func integer(_ key: String) -> Int? { (modelInfo["\(name).\(key)"] as? NSNumber)?.intValue }

        guard let layers = integer("block_count"), let heads = integer("attention.head_count"),
              let embedding = integer("embedding_length") else { return nil }
        // A present-but-not-a-number value (per-layer arrays on some models)
        // means the real cost is unknown: refuse rather than fall back.
        if let rawKvHeads = modelInfo["\(name).attention.head_count_kv"], !(rawKvHeads is NSNumber) { return nil }
        let kvHeads = integer("attention.head_count_kv") ?? heads
        let keyLength = integer("attention.key_length") ?? (heads > 0 ? embedding / heads : 0)
        let valueLength = integer("attention.value_length") ?? keyLength

        guard (1...1000).contains(layers), (1...512).contains(kvHeads),
              (1...1024).contains(keyLength), (1...1024).contains(valueLength) else { return nil }
        return ModelArchitecture(layers: layers, kvHeads: kvHeads, keyLength: keyLength,
                                 valueLength: valueLength,
                                 maxContextTokens: integer("context_length").flatMap { $0 > 0 ? $0 : nil })
    }
}

/// What a loaded model plus a window costs in GPU-addressable memory, and how
/// that compares with what this Mac lets the GPU use.
///
/// Calibrated against Ollama 0.40.16 on an Apple M2 (24 GB): across
/// `llama3.2:3b` (2 to 65k tokens), `qwen2.5:7b` (2 to 32k) and
/// `qwen2.5:14b`, Ollama's reported size was weights + KV cache plus a fixed
/// ~0.25 GB and a few percent growing with the window. The margins below sit
/// just above every measurement.
public struct ModelMemory: Sendable, Equatable {
    public let weightsBytes: Int64
    public let architecture: ModelArchitecture
    /// What the GPU may address (`MTLDevice.recommendedMaxWorkingSetSize`).
    public let gpuLimitBytes: Int64

    /// Scale and fixed margin over weights + KV cache; see the type comment.
    public static let overheadFactor = 1.05
    public static let overheadBytes = 300_000_000.0
    /// Warn only once the estimate passes this share of the GPU limit, leaving
    /// room for the rest of the system and for estimate error.
    public static let warnFraction = 0.9

    public init(weightsBytes: Int64, architecture: ModelArchitecture, gpuLimitBytes: Int64) {
        self.weightsBytes = weightsBytes
        self.architecture = architecture
        self.gpuLimitBytes = gpuLimitBytes
    }

    /// Estimated memory for the model with a window of `windowTokens`.
    public func estimatedBytes(windowTokens: Int) -> Double {
        let kv = Double(max(0, windowTokens)) * Double(architecture.kvBytesPerToken)
        return (Double(weightsBytes) + kv) * Self.overheadFactor + Self.overheadBytes
    }

    /// Largest window whose estimate stays within `fraction` of the GPU limit
    /// (0 when the model alone doesn't fit).
    public func maxWindowTokens(fraction: Double = warnFraction) -> Int {
        let budget = (Double(gpuLimitBytes) * fraction - Self.overheadBytes) / Self.overheadFactor
            - Double(weightsBytes)
        guard budget > 0, architecture.kvBytesPerToken > 0 else { return 0 }
        return Int(budget / Double(architecture.kvBytesPerToken))
    }
}

/// Decimal gigabytes, as Ollama and Activity Monitor report them.
public func gigabytes(_ bytes: Double) -> Double { bytes / 1_000_000_000 }
