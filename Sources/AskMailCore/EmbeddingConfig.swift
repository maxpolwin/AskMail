import Foundation

/// Which runtime serves the embedding model. The index is independent of this:
/// any backend that produces compatible vectors (see `EmbeddingCanary`) can
/// serve an existing index, so switching runtime needs no re-index.
public enum EmbeddingBackend: String, Sendable, CaseIterable, Codable {
    case ollama
    /// A loopback OpenAI-compatible server (LM Studio, llama.cpp, vLLM, …).
    case localServer
}

/// Everything needed to construct the embedder, kept apart from the chat
/// provider settings so chat and embeddings can run on different runtimes.
public struct EmbeddingConfig: Sendable, Equatable {
    public var backend: EmbeddingBackend
    public var model: String
    /// Raw user-entered base URL for `.localServer`; validated (loopback only)
    /// in `EmbedderFactory`, never trusted as entered.
    public var serverURL: String

    public init(backend: EmbeddingBackend = .ollama,
                model: String = Defaults.embeddingModel,
                serverURL: String = LocalServerEndpoint.defaultBase) {
        self.backend = backend
        self.model = model
        self.serverURL = serverURL
    }

    /// For status lines and dialogs.
    public var label: String {
        switch backend {
        case .ollama: return "\(model) (Ollama)"
        case .localServer: return "\(model.isEmpty ? "no model chosen" : model) (local server)"
        }
    }
}

/// Stand-in for a configuration that can't produce a real embedder (bad URL,
/// no model chosen). The error surfaces at embed time with its actionable
/// message instead of silently falling back to another backend.
public struct FailingEmbedder: EmbeddingProvider {
    public let error: ProviderError

    public init(error: ProviderError) {
        self.error = error
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        throw error
    }
}

/// The one place an `EmbeddingProvider` is constructed from settings, so Ask,
/// ingestion and Draft-Modus can never disagree about which embedder is in use.
/// Every embedder it returns is loopback-only.
public enum EmbedderFactory {
    public static func make(_ config: EmbeddingConfig) -> EmbeddingProvider {
        switch config.backend {
        case .ollama:
            return OllamaEmbedder(model: config.model)
        case .localServer:
            let base: URL
            do {
                base = try LocalServerEndpoint.validate(config.serverURL)
            } catch let error as ProviderError {
                return FailingEmbedder(error: error)
            } catch {
                return FailingEmbedder(error: .invalidEndpoint("\(error)"))
            }
            let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                return FailingEmbedder(error: .invalidEndpoint(
                    "Choose an embedding model for the local server in Settings \u{2192} Models."))
            }
            return OpenAIEmbedder(baseURL: base, model: model)
        }
    }
}
