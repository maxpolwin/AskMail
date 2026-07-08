import Foundation
import Security

/// API keys live in the macOS Keychain, read at runtime via the Security
/// framework. Never in code, config, or logs (SECURITY.md). Services:
/// "askmail.ollama-cloud" and "askmail.mistral", account "api-key".
///
/// Hardening H-16: items are created **device-bound** in the **data-protection
/// keychain** (`kSecUseDataProtectionKeychain=true`,
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) so a synced iCloud Keychain
/// copy never carries the key to another device. The data-protection keychain
/// requires an application identifier that a dev-signed/`swift test` process
/// typically lacks, surfacing as `errSecMissingEntitlement` (-34018) — so every
/// write/read attempts the data-protection path first and falls back to the
/// legacy file keychain transparently on that specific status, logging the
/// fallback once (`.info`) rather than failing the operation. Reads check the
/// data-protection keychain first, then legacy; finding a legacy-only item
/// triggers a best-effort migration (write + verified readback in the
/// data-protection keychain, only then delete the legacy copy) so the key is
/// never lost mid-migration.
public enum Keychain {

    /// A failed Keychain write, carrying the raw `OSStatus` so the UI and log
    /// can name the real reason (e.g. "The specified item already exists.")
    /// instead of a bare "failed".
    public struct WriteError: Error, CustomStringConvertible {
        public let status: OSStatus
        public init(status: OSStatus) { self.status = status }
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String?
                ?? "unknown Keychain error"
            return "\(message) (OSStatus \(status))"
        }
    }

    /// Injectable probe for whether the data-protection keychain should be
    /// attempted at all. Production always starts `true` — real availability
    /// is then discovered per-process via a live `errSecMissingEntitlement`
    /// (see `entitlementState` below) and cached so we don't retry-and-fail
    /// on every call. Tests override this to force the legacy fallback path
    /// deterministically, instead of depending on the ambient entitlement
    /// state of whatever machine/CI runs `swift test` (H-16).
    static var dataProtectionProbe: () -> Bool = { true }

    /// Tracks whether this process has already observed
    /// `errSecMissingEntitlement` from a live data-protection Keychain call,
    /// so subsequent calls skip straight to the legacy path and the
    /// "falling back" line is logged at most once per process.
    private final class EntitlementState: @unchecked Sendable {
        private let lock = NSLock()
        private var missingEntitlementObserved = false
        private var hasLogged = false

        var isMissing: Bool {
            lock.lock(); defer { lock.unlock() }
            return missingEntitlementObserved
        }

        /// Records the observation and returns whether this call is the
        /// first (i.e. the caller should log).
        func markMissingEntitlement() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            missingEntitlementObserved = true
            guard !hasLogged else { return false }
            hasLogged = true
            return true
        }

        func reset() {
            lock.lock()
            missingEntitlementObserved = false
            hasLogged = false
            lock.unlock()
        }
    }

    private static let entitlementState = EntitlementState()

    /// Whether a data-protection Keychain attempt is worth making right now.
    private static var dataProtectionUsable: Bool {
        dataProtectionProbe() && !entitlementState.isMissing
    }

    /// Records a live `errSecMissingEntitlement`, logging the fallback once.
    private static func noteMissingEntitlement() {
        guard entitlementState.markMissingEntitlement() else { return }
        RollingLog.shared.log(
            "data-protection Keychain unavailable in this process " +
            "(errSecMissingEntitlement); using the legacy Keychain (H-16)",
            level: .info)
    }

    public static func apiKey(service: String) -> String? {
        if let value = read(service: service, dataProtection: true) {
            return value
        }
        guard let legacyValue = read(service: service, dataProtection: false) else {
            return nil
        }
        migrateToDataProtection(value: legacyValue, service: service)
        return legacyValue
    }

    /// Whether a key is stored for the service, without returning its value —
    /// lets the UI show a "saved" indicator without pulling the secret into
    /// memory (and without a decrypt prompt, since no data is requested).
    public static func hasAPIKey(service: String) -> Bool {
        hasDataProtectionItem(service: service) || hasLegacyItem(service: service)
    }

    /// Upserts the key: updates an existing item in place, otherwise adds a new
    /// one. Throws `WriteError` (with the raw status) on failure.
    ///
    /// Deliberately update-then-add rather than the old delete-then-add: a
    /// `SecItemDelete` that can't remove a stale item — e.g. one whose access
    /// control is bound to a previous build's code signature — used to fail
    /// silently and leave a duplicate that `SecItemAdd` then rejected with
    /// `errSecDuplicateItem`, surfacing only as an opaque "failed".
    ///
    /// H-16: tries the data-protection keychain first (device-bound,
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); on
    /// `errSecMissingEntitlement` it falls back to the legacy keychain
    /// transparently. A successful data-protection write removes any stale
    /// legacy copy so a later read can't see two versions.
    public static func setAPIKey(_ value: String, service: String) throws {
        let data = Data(value.utf8)

        if dataProtectionUsable {
            let status = write(data: data, service: service, dataProtection: true)
            if status == errSecSuccess {
                deleteLegacy(service: service)
                return
            }
            if status == errSecMissingEntitlement {
                noteMissingEntitlement()
            } else {
                throw WriteError(status: status)
            }
        }

        let status = write(data: data, service: service, dataProtection: false)
        guard status == errSecSuccess else { throw WriteError(status: status) }
    }

    @discardableResult
    public static func deleteAPIKey(service: String) -> Bool {
        var query = baseQuery(service: service)
        query[kSecUseDataProtectionKeychain as String] = true
        let deletedDataProtection = SecItemDelete(query as CFDictionary) == errSecSuccess
        let deletedLegacy = deleteLegacy(service: service)
        return deletedDataProtection || deletedLegacy
    }

    // MARK: - Internals

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Defaults.keychainAccount,
        ]
    }

    /// Update-then-add against either the data-protection or legacy
    /// keychain, returning the raw `OSStatus` so callers can distinguish
    /// `errSecMissingEntitlement` (fall back) from a real failure (throw).
    private static func write(data: Data, service: String, dataProtection: Bool) -> OSStatus {
        var query = baseQuery(service: service)
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return errSecSuccess
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = dataProtection
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                : kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(attributes as CFDictionary, nil)
        default:
            return updateStatus
        }
    }

    private static func read(service: String, dataProtection: Bool) -> String? {
        if dataProtection && !dataProtectionUsable { return nil }

        var query = baseQuery(service: service)
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if dataProtection && status == errSecMissingEntitlement {
            noteMissingEntitlement()
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func deleteLegacy(service: String) -> Bool {
        SecItemDelete(baseQuery(service: service) as CFDictionary) == errSecSuccess
    }

    private static func hasDataProtectionItem(service: String) -> Bool {
        guard dataProtectionUsable else { return false }
        var query = baseQuery(service: service)
        query[kSecUseDataProtectionKeychain as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            noteMissingEntitlement()
            return false
        }
        return status == errSecSuccess
    }

    private static func hasLegacyItem(service: String) -> Bool {
        SecItemCopyMatching(baseQuery(service: service) as CFDictionary, nil) == errSecSuccess
    }

    /// Best-effort migration of a legacy-only item into the data-protection
    /// keychain (H-16). Never destructive: the legacy copy is deleted only
    /// after a verified readback of the freshly-written data-protection
    /// item, so a mid-migration failure (including a fresh
    /// `errSecMissingEntitlement`) simply leaves the legacy copy in place —
    /// the key is never lost.
    private static func migrateToDataProtection(value: String, service: String) {
        guard dataProtectionUsable else { return }
        let status = write(data: Data(value.utf8), service: service, dataProtection: true)
        guard status == errSecSuccess else {
            if status == errSecMissingEntitlement { noteMissingEntitlement() }
            return
        }
        guard read(service: service, dataProtection: true) == value else { return }
        deleteLegacy(service: service)
        RollingLog.shared.log(
            "migrated Keychain item (\(service)) to the data-protection keychain (H-16)",
            level: .info)
    }
}

#if DEBUG
extension Keychain {
    /// Test-only introspection so `KeychainTests` can assert *which*
    /// keychain actually holds an item after a migration attempt — whether
    /// the data-protection keychain is usable at all depends on the ambient
    /// entitlement state of the process running the tests, which these
    /// helpers let a test observe rather than assume.
    static func testHasLegacyItem(service: String) -> Bool {
        hasLegacyItem(service: service)
    }

    static func testHasDataProtectionItem(service: String) -> Bool {
        hasDataProtectionItem(service: service)
    }

    static func testResetEntitlementState() {
        entitlementState.reset()
    }
}
#endif
