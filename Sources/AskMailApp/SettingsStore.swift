import AskMailCore
import Carbon.HIToolbox
import Foundation

/// UserDefaults-backed settings. Read fresh on every query so changes take
/// effect with no app restart (FR-9). API keys are NOT here; they live in
/// the Keychain.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var provider: ProviderChoice {
        didSet { defaults.set(provider.rawValue, forKey: "provider") }
    }
    /// Local Ollama chat model, both as the primary (local provider) and the
    /// fallback when a cloud provider fails.
    @Published var localChatModel: String {
        didSet { defaults.set(localChatModel, forKey: "localChatModel") }
    }
    /// Ollama Cloud chat model, picked from the live ollama.com list.
    @Published var cloudChatModel: String {
        didSet { defaults.set(cloudChatModel, forKey: "cloudChatModel") }
    }
    /// Mistral chat model, picked from the account's /v1/models list.
    @Published var mistralModel: String {
        didSet { defaults.set(mistralModel, forKey: "mistralModel") }
    }
    /// Local Ollama embedding model. Changing it invalidates the vector index
    /// (vectors from different models don't mix) — the swap flow handles that.
    @Published var embeddingModel: String {
        didSet { defaults.set(embeddingModel, forKey: "embeddingModel") }
    }
    @Published var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: "systemPrompt") }
    }
    @Published var contextTokenLimit: Int {
        didSet { defaults.set(contextTokenLimit, forKey: "contextTokenLimit") }
    }
    @Published var answerTokenLimit: Int {
        didSet { defaults.set(answerTokenLimit, forKey: "answerTokenLimit") }
    }
    /// On-disk id (UUID directory name) of the selected Apple Mail account.
    @Published var accountID: String {
        didSet { defaults.set(accountID, forKey: "accountID") }
    }
    /// Resolved email for the selected account; written to the store's `account`
    /// column and used to label the current selection.
    @Published var accountEmail: String {
        didSet { defaults.set(accountEmail, forKey: "accountEmail") }
    }
    @Published var lastVectorized: Date? {
        didSet { defaults.set(lastVectorized, forKey: "lastVectorized") }
    }
    /// Verbosity of `RollingLog`. Changing it takes effect immediately, no
    /// restart needed (FR-9), by also updating the shared log's threshold.
    @Published var logLevel: RollingLog.LogLevel {
        didSet {
            defaults.set(logLevel.rawValue, forKey: "logLevel")
            RollingLog.shared.currentMinLevel = logLevel
        }
    }
    @Published var hotkeyKeyCode: Int {
        didSet { defaults.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }
    @Published var hotkeyModifiers: Int {
        didSet { defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }
    /// Human-readable label for the hotkey's key (e.g. "Space", "K", "\u{2192}"),
    /// captured in the shortcut recorder so display stays layout-correct.
    @Published var hotkeyKeyLabel: String {
        didSet { defaults.set(hotkeyKeyLabel, forKey: "hotkeyKeyLabel") }
    }
    /// Settings ▸ Accessibility ▸ "Speak answer aloud". Off by default. Also
    /// gates whether the ask panel's Close button and citation links stay
    /// reachable without a mouse (see AskView) — opting in to speech doubles
    /// as opting in to that broader keyboard/VoiceOver-reachable mode.
    @Published var speakAnswerEnabled: Bool {
        didSet { defaults.set(speakAnswerEnabled, forKey: "speakAnswerEnabled") }
    }
    /// Settings ▸ Accessibility ▸ "Higher-contrast panel". Off by default;
    /// strengthens Theme.hairline in both light and dark appearance.
    @Published var highContrastEnabled: Bool {
        didSet { defaults.set(highContrastEnabled, forKey: "highContrastEnabled") }
    }

    private init() {
        provider = ProviderChoice(rawValue: defaults.string(forKey: "provider") ?? "") ?? .ollamaLocal
        localChatModel = defaults.string(forKey: "localChatModel") ?? Defaults.localChatModel
        cloudChatModel = defaults.string(forKey: "cloudChatModel") ?? Defaults.cloudChatModel
        mistralModel = defaults.string(forKey: "mistralModel") ?? Defaults.mistralChatModel
        embeddingModel = defaults.string(forKey: "embeddingModel") ?? Defaults.embeddingModel
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? Defaults.defaultSystemPrompt
        // First run has no stored token budgets: seed them from the machine +
        // default local model rather than a flat constant. Users can retune in
        // Settings (the "Use recommended" affordance stays available there).
        let firstRunModelMB = ModelCatalog.chat
            .first { $0.id == Defaults.localChatModel }?.approxSizeMB ?? 4700
        let recommended = TokenAdvisor.recommend(
            isLocal: true, modelSizeMB: firstRunModelMB,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        let contextLimit = defaults.integer(forKey: "contextTokenLimit")
        contextTokenLimit = contextLimit > 0 ? contextLimit : recommended.contextTokens
        let answerLimit = defaults.integer(forKey: "answerTokenLimit")
        answerTokenLimit = answerLimit > 0 ? answerLimit : recommended.answerTokens
        accountID = defaults.string(forKey: "accountID") ?? ""
        accountEmail = defaults.string(forKey: "accountEmail") ?? ""
        lastVectorized = defaults.object(forKey: "lastVectorized") as? Date
        // Default to .info, not .debug (hardening H-23): .debug logs the full
        // assembled prompt (retrieved mail text) and full answer text
        // (QueryService), so shipping it as the default would retain mail
        // excerpts in the 12h rolling log without the user ever opting in.
        let storedLogLevel = defaults.object(forKey: "logLevel") as? Int
        logLevel = storedLogLevel.flatMap(RollingLog.LogLevel.init(rawValue:)) ?? .info
        let keyCode = defaults.object(forKey: "hotkeyKeyCode") as? Int
        hotkeyKeyCode = keyCode ?? ShortcutSymbols.defaultKeyCode
        let modifiers = defaults.object(forKey: "hotkeyModifiers") as? Int
        hotkeyModifiers = modifiers ?? ShortcutSymbols.defaultModifiers
        hotkeyKeyLabel = defaults.string(forKey: "hotkeyKeyLabel") ?? ShortcutSymbols.defaultKeyLabel
        speakAnswerEnabled = defaults.bool(forKey: "speakAnswerEnabled")
        highContrastEnabled = defaults.bool(forKey: "highContrastEnabled")

        // Migrate the pre-picker path setting: an account directory's last path
        // component is its id. (didSet doesn't fire during init, so persist here.)
        if accountID.isEmpty,
           let legacyPath = defaults.string(forKey: "accountDirectory"), !legacyPath.isEmpty {
            accountID = URL(fileURLWithPath: legacyPath).lastPathComponent
            defaults.set(accountID, forKey: "accountID")
            defaults.removeObject(forKey: "accountDirectory")
        }

        RollingLog.shared.currentMinLevel = logLevel
    }

    /// Filesystem directory of the selected account, or nil if none is chosen.
    var accountDirectoryURL: URL? {
        accountID.isEmpty ? nil : Defaults.mailRoot.appendingPathComponent(accountID, isDirectory: true)
    }

    /// Value written to each ingested message's `account` column: the email when
    /// known, else the on-disk id.
    var accountStorageKey: String {
        accountEmail.isEmpty ? accountID : accountEmail
    }

    /// Snapshot for one query (FR-9: settings changes apply on the next query).
    func querySettings() -> QuerySettings {
        QuerySettings(provider: provider,
                      systemPrompt: systemPrompt,
                      contextTokenLimit: contextTokenLimit,
                      answerTokenLimit: answerTokenLimit,
                      localModel: localChatModel,
                      cloudModel: cloudChatModel,
                      mistralModel: mistralModel)
    }

    static var databasePath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("AskMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("askmail.db").path
    }
}
