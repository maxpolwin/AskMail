import AskMailCore
import Foundation

/// Fetches the model lists for the two remote chat providers so their pickers
/// reflect what's actually available right now, mirroring how the local picker
/// follows /api/tags. Model *metadata* only — mail content never touches these
/// endpoints. Failures keep the last good list and surface an honest note.
@MainActor
final class RemoteModelDirectory: ObservableObject {
    static let shared = RemoteModelDirectory()

    @Published private(set) var cloudModels: [InstalledModel] = []
    @Published private(set) var cloudNote: String = ""
    @Published private(set) var mistralModels: [String] = []
    @Published private(set) var mistralNote: String = ""

    private var isRefreshing = false

    /// Refreshes the list backing the given provider's picker; local Ollama is
    /// the engine's job. Call when Settings opens with a remote provider
    /// selected, when the user switches to one, and after keys are saved.
    func refresh(for provider: ProviderChoice) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        switch provider {
        case .ollamaLocal:
            break
        case .ollamaCloud:
            // ollama.com serves /api/tags publicly; the key (when saved)
            // scopes the list to the account.
            let control = OllamaControl(host: Defaults.ollamaCloudHost,
                                        apiKey: Keychain.apiKey(service: Defaults.keychainServiceOllamaCloud))
            do {
                cloudModels = try await control.installedModels()
                cloudNote = ""
            } catch {
                cloudNote = "Couldn\u{2019}t load Ollama Cloud models: \(error)"
                RollingLog.shared.log("ollama cloud model list FAILED: \(error)", level: .error)
            }
        case .mistral:
            guard let key = Keychain.apiKey(service: Defaults.keychainServiceMistral), !key.isEmpty else {
                mistralModels = []
                mistralNote = "Save your Mistral API key below to list available models."
                return
            }
            do {
                mistralModels = try await MistralClient.availableModels(apiKey: key)
                mistralNote = ""
            } catch {
                mistralNote = "Couldn\u{2019}t load Mistral models: \(error)"
                RollingLog.shared.log("mistral model list FAILED: \(error)", level: .error)
            }
        }
    }
}
