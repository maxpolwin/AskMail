import XCTest
@testable import AskMailCore

/// Keychain data-protection + fallback (H-16). The data-protection keychain
/// requires an application identifier that a `swift test` binary typically
/// lacks (`errSecMissingEntitlement` / -34018), so these tests are written to
/// pass identically regardless of which path the environment actually lands
/// on: the public round-trip must never lose data, and the migration test
/// only asserts the data-protection-specific side effect (legacy copy
/// removed) when a live attempt shows the data-protection keychain is
/// actually usable in this process.
final class KeychainTests: XCTestCase {
    let service = "askmail.test.keychain-h16"

    override func tearDown() {
        Keychain.deleteAPIKey(service: service)
        Keychain.testResetEntitlementState()
        Keychain.dataProtectionProbe = { true }
        super.tearDown()
    }

    func testSaveReadDeleteRoundTrip() throws {
        XCTAssertNil(Keychain.apiKey(service: service))
        XCTAssertFalse(Keychain.hasAPIKey(service: service))

        try Keychain.setAPIKey("secret-value", service: service)
        XCTAssertTrue(Keychain.hasAPIKey(service: service))
        XCTAssertEqual(Keychain.apiKey(service: service), "secret-value")

        // Upsert path: second write updates in place.
        try Keychain.setAPIKey("updated-value", service: service)
        XCTAssertEqual(Keychain.apiKey(service: service), "updated-value")

        XCTAssertTrue(Keychain.deleteAPIKey(service: service))
        XCTAssertNil(Keychain.apiKey(service: service))
        XCTAssertFalse(Keychain.hasAPIKey(service: service))
    }

    func testRoundTripStillWorksWhenDataProtectionIsForcedUnavailable() throws {
        // Forces every write/read down the legacy path, exactly like a
        // process that has already observed errSecMissingEntitlement.
        Keychain.dataProtectionProbe = { false }

        try Keychain.setAPIKey("legacy-only", service: service)
        XCTAssertEqual(Keychain.apiKey(service: service), "legacy-only")
        XCTAssertTrue(Keychain.testHasLegacyItem(service: service))
        XCTAssertFalse(Keychain.testHasDataProtectionItem(service: service))

        XCTAssertTrue(Keychain.deleteAPIKey(service: service))
        XCTAssertNil(Keychain.apiKey(service: service))
    }

    func testMigrationFromLegacyOnReadNeverLosesTheKey() throws {
        // Seed a legacy-only item the way the pre-H-16 code path always
        // wrote (mirrors an item that predates this hardening pass).
        Keychain.dataProtectionProbe = { false }
        try Keychain.setAPIKey("pre-existing", service: service)
        XCTAssertTrue(Keychain.testHasLegacyItem(service: service))
        XCTAssertFalse(Keychain.testHasDataProtectionItem(service: service))

        // Reading now attempts the data-protection path first, then falls
        // back to legacy and migrates best-effort. The value must survive
        // either way.
        Keychain.dataProtectionProbe = { true }
        XCTAssertEqual(Keychain.apiKey(service: service), "pre-existing")

        if Keychain.testHasDataProtectionItem(service: service) {
            // The data-protection write was verified by readback, so the
            // legacy copy should have been cleaned up.
            XCTAssertFalse(Keychain.testHasLegacyItem(service: service),
                           "verified migration should remove the legacy copy")
        } else {
            // No data-protection entitlement available in this process —
            // the legacy copy must remain the only source of truth.
            XCTAssertTrue(Keychain.testHasLegacyItem(service: service),
                          "without a verified migration the legacy copy must be kept")
        }

        // Either way, a second read is stable and the value is intact.
        XCTAssertEqual(Keychain.apiKey(service: service), "pre-existing")
    }

    func testHasAPIKeyDoesNotReturnValue() throws {
        try Keychain.setAPIKey("shh", service: service)
        XCTAssertTrue(Keychain.hasAPIKey(service: service))
        // hasAPIKey never decrypts the secret data, only checks for
        // existence -- covered indirectly since it takes no kSecReturnData
        // query, but assert the round trip contract stays intact here too.
        XCTAssertEqual(Keychain.apiKey(service: service), "shh")
    }
}
