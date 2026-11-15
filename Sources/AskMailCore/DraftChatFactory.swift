import Foundation

/// The chat provider for every Draft-Modus generation path (drafting,
/// classification fallback, style learning). Hardening H-25: drafts run
/// unattended, with no per-request consent moment, so they only ever use a
/// runtime on this Mac — never a cloud provider, whatever Ask is set to.
///
/// When Ask uses a local OpenAI-compatible server (LM Studio, llama.cpp, …),
/// drafts use it too: it is loopback-only by construction
/// (`LocalServerEndpoint.validate`), so nothing leaves the device. Every other
/// choice, cloud ones included, drafts with local Ollama as before.
public enum DraftChatFactory {
    public static func make(settings: QuerySettings) -> ChatProvider {
        if usesLocalServer(settings.provider) {
            return QueryService.localServerProvider(settings: settings)
        }
        return OllamaClient(host: Defaults.ollamaLocalHost, model: settings.localModel)
    }

    /// Whether drafting goes to the local server rather than Ollama — lets
    /// callers skip starting Ollama when nothing else needs it.
    public static func usesLocalServer(_ provider: ProviderChoice) -> Bool {
        switch provider {
        case .localServer: return true
        case .ollamaLocal, .ollamaCloud, .mistral: return false
        }
    }
}
