import AskMailCore
import Carbon.HIToolbox
import Foundation

/// UserDefaults-backed settings. Read fresh on every query so changes take
/// effect with no app restart (FR-9). API keys are NOT here; they live in
/// the Keychain.
///
/// @MainActor: every consumer (views, @MainActor engines/schedulers) already
/// reads it from the main actor; background work snapshots plain values
/// before detaching (see `DraftEngine.runTick`).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

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
    /// Base URL of the local OpenAI-compatible server (loopback only;
    /// validated by `LocalServerEndpoint` before every use).
    @Published var localServerURL: String {
        didSet { defaults.set(localServerURL, forKey: "localServerURL") }
    }
    @Published var localServerModel: String {
        didSet { defaults.set(localServerModel, forKey: "localServerModel") }
    }
    /// Embedding model id on the selected backend. Changing it only
    /// invalidates the vector index if the new embedder's vectors aren't
    /// compatible with it (`EmbeddingCanary`) — the swap flow checks that.
    @Published var embeddingModel: String {
        didSet { defaults.set(embeddingModel, forKey: "embeddingModel") }
    }
    /// Which runtime serves embeddings, independent of the chat provider.
    @Published var embeddingBackend: EmbeddingBackend {
        didSet { defaults.set(embeddingBackend.rawValue, forKey: "embeddingBackend") }
    }
    /// Base URL of the embedding server for `.localServer` (loopback only;
    /// validated by `LocalServerEndpoint` before every use).
    @Published var embeddingServerURL: String {
        didSet { defaults.set(embeddingServerURL, forKey: "embeddingServerURL") }
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
    /// Retrieved excerpts (chunks) put into each answer's context.
    @Published var excerptsPerAnswer: Int {
        didSet { defaults.set(excerptsPerAnswer, forKey: "excerptsPerAnswer") }
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
    /// Draft-Modus master switch. Off by default — when off, `DraftScheduler`
    /// runs nothing at all (no detection, no purge, no anything).
    @Published var draftModeEnabled: Bool {
        didSet { defaults.set(draftModeEnabled, forKey: "draftModeEnabled") }
    }
    /// Off by default (FR-5 parity): a scheduled draft tick on battery is
    /// skipped, not queued, unless the user explicitly opts in here.
    @Published var draftAllowOnBattery: Bool {
        didSet { defaults.set(draftAllowOnBattery, forKey: "draftAllowOnBattery") }
    }
    /// Senders/domains Draft-Modus should never draft for (Phase 6,
    /// docs/draft-modus-plan.md) -- checked by `SenderExclusion.isExcluded`
    /// in `DraftJobProcessor.classifyPendingJobs`. Each entry is a bare
    /// email address or domain; empty by default.
    @Published var draftExcludedSenders: [String] {
        didSet { defaults.set(draftExcludedSenders, forKey: "draftExcludedSenders") }
    }

    /// Production uses `.shared` (backed by `UserDefaults.standard`); tests
    /// construct their own instance against an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = ProviderChoice(rawValue: defaults.string(forKey: "provider") ?? "") ?? .ollamaLocal
        localChatModel = defaults.string(forKey: "localChatModel") ?? Defaults.localChatModel
        cloudChatModel = defaults.string(forKey: "cloudChatModel") ?? Defaults.cloudChatModel
        mistralModel = defaults.string(forKey: "mistralModel") ?? Defaults.mistralChatModel
        localServerURL = defaults.string(forKey: "localServerURL") ?? LocalServerEndpoint.defaultBase
        localServerModel = defaults.string(forKey: "localServerModel") ?? ""
        embeddingModel = defaults.string(forKey: "embeddingModel") ?? Defaults.embeddingModel
        embeddingBackend = EmbeddingBackend(rawValue: defaults.string(forKey: "embeddingBackend") ?? "") ?? .ollama
        embeddingServerURL = defaults.string(forKey: "embeddingServerURL") ?? LocalServerEndpoint.defaultBase
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? Defaults.defaultSystemPrompt
        // First run has no stored token budgets: seed them from the advisor's
        // defaults (model facts aren't known yet). Users can retune in Settings,
        // where "Use recommended" re-derives them from the chosen model.
        let recommended = TokenAdvisor.firstRun()
        let contextLimit = defaults.integer(forKey: "contextTokenLimit")
        // Stored values are clamped: a hand-edited defaults file must not make
        // QueryService ask a model for an absurd window.
        contextTokenLimit = contextLimit > 0
            ? Defaults.clamp(contextLimit, to: Defaults.contextTokenRange) : recommended.contextTokens
        let answerLimit = defaults.integer(forKey: "answerTokenLimit")
        answerTokenLimit = answerLimit > 0
            ? Defaults.clamp(answerLimit, to: Defaults.answerTokenRange) : recommended.answerTokens
        let excerpts = defaults.integer(forKey: "excerptsPerAnswer")
        excerptsPerAnswer = excerpts > 0
            ? Defaults.clamp(excerpts, to: Defaults.excerptRange) : Defaults.finalTopK
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
        draftModeEnabled = defaults.bool(forKey: "draftModeEnabled")
        draftAllowOnBattery = defaults.bool(forKey: "draftAllowOnBattery")
        draftExcludedSenders = defaults.stringArray(forKey: "draftExcludedSenders") ?? []

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

    /// The embedding configuration as one value, for the factory and for
    /// change detection. Read on the main actor, then passed to background work.
    var embeddingConfig: EmbeddingConfig {
        get {
            EmbeddingConfig(backend: embeddingBackend, model: embeddingModel,
                            serverURL: embeddingServerURL)
        }
        set {
            embeddingBackend = newValue.backend
            embeddingModel = newValue.model
            embeddingServerURL = newValue.serverURL
        }
    }

    /// Snapshot for one query (FR-9: settings changes apply on the next query).
    func querySettings() -> QuerySettings {
        QuerySettings(provider: provider,
                      systemPrompt: systemPrompt,
                      contextTokenLimit: contextTokenLimit,
                      answerTokenLimit: answerTokenLimit,
                      topK: excerptsPerAnswer,
                      localModel: localChatModel,
                      cloudModel: cloudChatModel,
                      mistralModel: mistralModel,
                      localServerURL: localServerURL,
                      localServerModel: localServerModel)
    }

    // nonisolated: pure FileManager path derivation, no isolated state —
    // read from detached background work (DraftEngine tick, Services).
    nonisolated static var databasePath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("AskMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("askmail.db").path
    }

    /// The separate Draft-Modus database — physically decoupled from
    /// `databasePath`'s `askmail.db` (same directory, different file).
    nonisolated static var draftsDatabasePath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("AskMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("drafts.db").path
    }
}
