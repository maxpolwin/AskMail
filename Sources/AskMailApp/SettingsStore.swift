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

    private init() {
        provider = ProviderChoice(rawValue: defaults.string(forKey: "provider") ?? "") ?? .ollamaLocal
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? Defaults.defaultSystemPrompt
        let contextLimit = defaults.integer(forKey: "contextTokenLimit")
        contextTokenLimit = contextLimit > 0 ? contextLimit : Defaults.contextTokenLimit
        let answerLimit = defaults.integer(forKey: "answerTokenLimit")
        answerTokenLimit = answerLimit > 0 ? answerLimit : Defaults.answerTokenLimit
        accountID = defaults.string(forKey: "accountID") ?? ""
        accountEmail = defaults.string(forKey: "accountEmail") ?? ""
        lastVectorized = defaults.object(forKey: "lastVectorized") as? Date
        let storedLogLevel = defaults.object(forKey: "logLevel") as? Int
        logLevel = storedLogLevel.flatMap(RollingLog.LogLevel.init(rawValue:)) ?? .debug
        let keyCode = defaults.object(forKey: "hotkeyKeyCode") as? Int
        hotkeyKeyCode = keyCode ?? kVK_Space
        let modifiers = defaults.object(forKey: "hotkeyModifiers") as? Int
        hotkeyModifiers = modifiers ?? (controlKey | optionKey)
        hotkeyKeyLabel = defaults.string(forKey: "hotkeyKeyLabel") ?? "Space"

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
                      answerTokenLimit: answerTokenLimit)
    }

    static var databasePath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("AskMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("askmail.db").path
    }
}
