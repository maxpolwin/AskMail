import XCTest
@testable import AskMailApp
@testable import AskMailCore

/// `SettingsStore` against an isolated `UserDefaults` suite: defaults on
/// first run, persistence via didSet, the legacy account-path migration, and
/// the derived account values.
@MainActor
final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "settings-store-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFirstRunDefaults() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.provider, .ollamaLocal)
        XCTAssertEqual(store.localChatModel, Defaults.localChatModel)
        XCTAssertEqual(store.embeddingModel, Defaults.embeddingModel)
        XCTAssertEqual(store.logLevel, .info, "H-23: .debug must never be the shipped default")
        XCTAssertFalse(store.draftModeEnabled, "Draft-Modus is opt-in")
        XCTAssertFalse(store.draftAllowOnBattery)
        XCTAssertGreaterThan(store.contextTokenLimit, 0, "seeded from TokenAdvisor, never zero")
        XCTAssertGreaterThan(store.answerTokenLimit, 0)
        XCTAssertNil(store.accountDirectoryURL, "no account chosen yet")
    }

    func testChangesPersistAcrossInstances() {
        let store = SettingsStore(defaults: defaults)
        store.provider = .mistral
        store.embeddingModel = "custom-embed"
        store.draftModeEnabled = true
        store.draftExcludedSenders = ["boss@example.com", "example.org"]

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.provider, .mistral)
        XCTAssertEqual(reloaded.embeddingModel, "custom-embed")
        XCTAssertTrue(reloaded.draftModeEnabled)
        XCTAssertEqual(reloaded.draftExcludedSenders, ["boss@example.com", "example.org"])
    }

    func testLegacyAccountDirectoryMigratesToAccountID() {
        defaults.set("/Users/x/Library/Mail/V10/ABC-DEF-123", forKey: "accountDirectory")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.accountID, "ABC-DEF-123")
        XCTAssertNil(defaults.string(forKey: "accountDirectory"), "legacy key is removed after migration")
        XCTAssertEqual(defaults.string(forKey: "accountID"), "ABC-DEF-123", "migrated id is persisted")
    }

    func testAccountStorageKeyPrefersEmailOverID() {
        let store = SettingsStore(defaults: defaults)
        store.accountID = "ABC-DEF-123"
        XCTAssertEqual(store.accountStorageKey, "ABC-DEF-123")
        store.accountEmail = "max@example.com"
        XCTAssertEqual(store.accountStorageKey, "max@example.com")
    }

    func testQuerySettingsSnapshotsCurrentValues() {
        let store = SettingsStore(defaults: defaults)
        store.provider = .ollamaCloud
        store.cloudChatModel = "some-cloud-model"
        store.contextTokenLimit = 1234

        let snapshot = store.querySettings()
        XCTAssertEqual(snapshot.provider, .ollamaCloud)
        XCTAssertEqual(snapshot.cloudModel, "some-cloud-model")
        XCTAssertEqual(snapshot.contextTokenLimit, 1234)

        // A later change must not retroactively alter the snapshot (FR-9:
        // settings apply on the NEXT query).
        store.contextTokenLimit = 9999
        XCTAssertEqual(snapshot.contextTokenLimit, 1234)
    }

    func testStoredTokenBudgetsWinOverRecommendation() {
        defaults.set(4321, forKey: "contextTokenLimit")
        defaults.set(321, forKey: "answerTokenLimit")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.contextTokenLimit, 4321)
        XCTAssertEqual(store.answerTokenLimit, 321)
    }
}
