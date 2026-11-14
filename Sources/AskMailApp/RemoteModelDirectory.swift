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
    /// Local OpenAI-compatible server (loopback): its model list, a status
    /// note, and what Detect found. Metadata only — no mail content.
    @Published private(set) var localServerModels: [String] = []
    @Published private(set) var localServerNote: String = ""
    @Published private(set) var detectedServers: [LocalServerInfo] = []
    @Published private(set) var contextLength: Int?
    @Published private(set) var isDetecting = false
    /// Embedding server (loopback): what it lists, a status note, and whether
    /// it answered (nil until first checked). Metadata only.
    @Published private(set) var embeddingServerModels: [String] = []
    @Published private(set) var embeddingServerNote: String = ""
    @Published private(set) var embeddingServerReachable: Bool?

    private var isRefreshing = false
    private var isRefreshingEmbeddingServer = false

    /// Refreshes the list backing the given provider's picker; local Ollama is
    /// the engine's job. Call when Settings opens with a remote provider
    /// selected, when the user switches to one, and after keys are saved.
    func refresh(for provider: ProviderChoice,
                 localServerURL: String = LocalServerEndpoint.defaultBase) async {
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
        case .localServer:
            do {
                let base = try LocalServerEndpoint.validate(localServerURL)
                localServerModels = try await LocalServerProbe.availableModels(base: base)
                localServerNote = localServerModels.isEmpty
                    ? "The server answered but lists no models. Load one in the server app."
                    : ""
                contextLength = await LocalServerProbe.contextLength(
                    base: base, session: LocalServerSession.shared)
            } catch {
                localServerModels = []
                contextLength = nil
                localServerNote = Self.localServerNote(for: error)
                RollingLog.shared.log("local server model list FAILED: \(error)", level: .error)
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

    /// Lists the embedding server's models. Same loopback-only, redirect-free
    /// path as the chat server; a failure is a status, never a fallback.
    func refreshEmbeddingServer(url: String) async {
        guard !isRefreshingEmbeddingServer else { return }
        isRefreshingEmbeddingServer = true
        defer { isRefreshingEmbeddingServer = false }
        do {
            let base = try LocalServerEndpoint.validate(url)
            embeddingServerModels = try await LocalServerProbe.availableModels(base: base)
            embeddingServerReachable = true
            embeddingServerNote = embeddingServerModels.isEmpty
                ? "The server answered but lists no models. Load an embedding model in the server app."
                : ""
        } catch {
            embeddingServerModels = []
            embeddingServerReachable = false
            embeddingServerNote = Self.localServerNote(for: error)
            RollingLog.shared.log("embedding server model list FAILED: \(error)", level: .error)
        }
    }

    /// Probes the well-known local ports on user click only.
    func detectLocalServers() async {
        guard !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }
        detectedServers = await LocalServerProbe.detect()
        if detectedServers.isEmpty {
            localServerNote = "No local model server answered on ports 1234, 8080 or 8000. "
                + "Start LM Studio, llama-server or mlx_lm.server, then try again."
        }
    }

    private static func localServerNote(for error: Error) -> String {
        if ProviderError.isConnectionFailure(error) {
            return "No server is answering at that address. Start your model server and try again."
        }
        return "Couldn\u{2019}t load models from the local server: \(error)"
    }
}
