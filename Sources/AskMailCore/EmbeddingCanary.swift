import Foundation

/// Decides by evidence, not by name, whether an embedder can serve an existing
/// index.
///
/// When an index is first built, three fixed probe strings are embedded and
/// their vectors stored in `meta`. Later — whenever the backend or model setting
/// changes, and at the start of every ingest run — the same strings are
/// embedded again and compared. The same model served by another runtime
/// (Ollama vs LM Studio, GGUF vs another quantization) lands within a hair of
/// the stored vectors, so the index stays valid and nothing is re-embedded; a
/// different model, or a server that silently loaded a different one, does
/// not. This replaces comparing model *names*, which can differ for identical
/// weights and say nothing about what a server actually loaded.
///
/// The probes are constants, never mail text, so nothing private is embedded
/// or stored here, and only similarity scores are ever logged.
public enum EmbeddingCanary {
    public static let metaKey = "embedding_canary"

    /// Each probe's cosine similarity to its stored vector must reach this.
    /// Identical weights through the same runtime give ~1.0; the margin allows
    /// quantization and runtime differences. Deliberately strict: a false
    /// "incompatible" costs a re-embed, a false "compatible" corrupts search.
    /// Not yet calibrated against a second real runtime.
    public static let threshold: Float = 0.98

    static let texts = [
        "The quarterly budget review is scheduled for Thursday at 3 pm in the main conference room.",
        "Please find the signed contract attached; let me know if legal needs any changes before Friday.",
        "Your flight to Berlin departs at 07:45. Check in online and bring your passport.",
    ]

    public enum Assessment {
        /// Nothing indexed yet: any backend may build the index.
        case emptyIndex
        /// A pre-canary index (built before this check existed).
        case noBaseline
        case compatible(minSimilarity: Float)
        case incompatible(String)
        /// The probes couldn't be embedded (backend down, model missing, …).
        /// Nothing is known about compatibility; callers must not destroy
        /// anything on this.
        case unverifiable(Error)
    }

    /// Compares `embedder` against the index's stored baseline.
    public static func assess(store: SQLiteStore, embedder: EmbeddingProvider) async -> Assessment {
        do {
            guard try store.chunkCount() > 0 else { return .emptyIndex }
            guard let stored = try store.meta(metaKey), let baseline = decode(stored) else {
                return .noBaseline
            }
            let fresh = try await embedder.embed(texts)
            guard fresh.count == texts.count else {
                return .incompatible("the backend returned \(fresh.count) vectors for \(texts.count) probes")
            }
            guard fresh.allSatisfy({ $0.count == baseline.dimensions }) else {
                return .incompatible(
                    "vector width \(fresh.first?.count ?? 0) differs from the index\u{2019}s \(baseline.dimensions)")
            }
            var lowest: Float = 1
            for (vector, reference) in zip(fresh, baseline.vectors) {
                lowest = min(lowest, cosine(vector, reference))
            }
            return lowest >= threshold
                ? .compatible(minSimilarity: lowest)
                : .incompatible("the same probe text embeds differently (similarity \(String(format: "%.3f", lowest)) < \(threshold))")
        } catch {
            return .unverifiable(error)
        }
    }

    /// Stores `embedder`'s vectors for the probes as the index's baseline.
    /// Call when the index is empty or adopted from before canaries existed,
    /// with the embedder that builds (or built) it.
    public static func recordBaseline(store: SQLiteStore, embedder: EmbeddingProvider) async throws {
        let vectors = try await embedder.embed(texts)
        guard vectors.count == texts.count, let width = vectors.first?.count,
              (1...OpenAIEmbedder.maxDimensions).contains(width),
              vectors.allSatisfy({ $0.count == width && $0.allSatisfy(\.isFinite) }) else {
            throw ProviderError.malformedResponse("canary vectors are inconsistent")
        }
        try store.setMeta(metaKey, value: encode(dimensions: width, vectors: vectors))
    }

    /// Vector width of the embedder, via one probe; nil when it can't answer.
    public static func probeDimensions(embedder: EmbeddingProvider) async -> Int? {
        guard let first = try? await embedder.embed([texts[0]]).first, !first.isEmpty else { return nil }
        return first.count
    }

    // MARK: Encoding

    struct Baseline {
        let dimensions: Int
        let vectors: [[Float]]
    }

    /// `v1:<dims>:<base64 of count*dims little-endian Float32>`.
    static func encode(dimensions: Int, vectors: [[Float]]) -> String {
        let data = SQLiteStore.blob(from: vectors.flatMap { $0 })
        return "v1:\(dimensions):\(data.base64EncodedString())"
    }

    /// Nil for anything that isn't a well-formed baseline — the stored value
    /// is treated as untrusted (it sits in a file other tools could edit).
    static func decode(_ raw: String) -> Baseline? {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
              let dimensions = Int(parts[1]), (1...OpenAIEmbedder.maxDimensions).contains(dimensions),
              let data = Data(base64Encoded: String(parts[2])),
              data.count == texts.count * dimensions * MemoryLayout<Float>.size else { return nil }
        let flat = SQLiteStore.floats(from: data)
        guard flat.allSatisfy(\.isFinite) else { return nil }
        let vectors = (0..<texts.count).map { Array(flat[($0 * dimensions)..<(($0 + 1) * dimensions)]) }
        return Baseline(dimensions: dimensions, vectors: vectors)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        let denominator = (normA * normB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }
}
