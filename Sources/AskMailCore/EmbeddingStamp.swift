import Foundation

/// Which embedding model (and dimension) built the vector index. Stamped into
/// `meta['embedding_model']` at each ingest run's start so vectors from two
/// models can never silently mix: cosine similarity across models is
/// meaningless even at equal dimensions, and worse, a dimension change makes
/// the search guard drop every stored vector without a word.
public struct EmbeddingStamp: Sendable, Equatable {
    public static let metaKey = "embedding_model"

    public let model: String
    /// Vector width, from `/api/show` when available (registry fallback);
    /// nil when neither source knew it.
    public let dimensions: Int?

    public init(model: String, dimensions: Int? = nil) {
        self.model = model
        self.dimensions = dimensions
    }

    /// "nomic-embed-text@768", or just the model when the dimension is unknown.
    public var encoded: String {
        dimensions.map { "\(model)@\($0)" } ?? model
    }

    public static func decode(_ raw: String) -> EmbeddingStamp {
        // Split on the last "@" so a hypothetical "@" in a model id survives.
        guard let separator = raw.lastIndex(of: "@"),
              let dimensions = Int(raw[raw.index(after: separator)...]) else {
            return EmbeddingStamp(model: raw)
        }
        return EmbeddingStamp(model: String(raw[..<separator]), dimensions: dimensions)
    }

    /// Whether an incremental run over an existing index must be refused for a
    /// full rebuild instead. Only a *different* model on a *non-empty* index
    /// blocks: an empty index has nothing to corrupt, and a missing stamp
    /// means a pre-stamp legacy index that the run adopts (stamping it with
    /// the configured model, which is what built it).
    public static func requiresRebuild(configuredModel: String,
                                       stamp: EmbeddingStamp?,
                                       chunkCount: Int) -> Bool {
        guard chunkCount > 0, let stamp else { return false }
        return !OllamaStatus.modelName(stamp.model, matches: configuredModel)
    }
}

extension SQLiteStore {
    public func embeddingStamp() throws -> EmbeddingStamp? {
        try meta(EmbeddingStamp.metaKey).map(EmbeddingStamp.decode)
    }

    public func setEmbeddingStamp(_ stamp: EmbeddingStamp) throws {
        try setMeta(EmbeddingStamp.metaKey, value: stamp.encoded)
    }
}
