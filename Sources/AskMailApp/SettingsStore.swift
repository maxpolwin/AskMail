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
    @Published var accountDirectory: String {
        didSet { defaults.set(accountDirectory, forKey: "accountDirectory") }
    }
    @Published var lastVectorized: Date? {
        didSet { defaults.set(lastVectorized, forKey: "lastVectorized") }
    }
    @Published var hotkeyKeyCode: Int {
        didSet { defaults.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }
    @Published var hotkeyModifiers: Int {
        didSet { defaults.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }

    private init() {
        provider = ProviderChoice(rawValue: defaults.string(forKey: "provider") ?? "") ?? .ollamaLocal
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? Defaults.defaultSystemPrompt
        let contextLimit = defaults.integer(forKey: "contextTokenLimit")
        contextTokenLimit = contextLimit > 0 ? contextLimit : Defaults.contextTokenLimit
        let answerLimit = defaults.integer(forKey: "answerTokenLimit")
        answerTokenLimit = answerLimit > 0 ? answerLimit : Defaults.answerTokenLimit
        accountDirectory = defaults.string(forKey: "accountDirectory") ?? ""
        lastVectorized = defaults.object(forKey: "lastVectorized") as? Date
        let keyCode = defaults.object(forKey: "hotkeyKeyCode") as? Int
        hotkeyKeyCode = keyCode ?? kVK_Space
        let modifiers = defaults.object(forKey: "hotkeyModifiers") as? Int
        hotkeyModifiers = modifiers ?? (controlKey | optionKey)
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
