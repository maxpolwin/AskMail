import Foundation
import Security

/// API keys live in the macOS Keychain, read at runtime via the Security
/// framework. Never in code, config, or logs (SECURITY.md). Services:
/// "askmail.ollama-cloud" and "askmail.mistral", account "api-key".
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

    public static func apiKey(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Defaults.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Upserts the key: updates an existing item in place, otherwise adds a new
    /// one. Throws `WriteError` (with the raw status) on failure.
    ///
    /// Deliberately update-then-add rather than the old delete-then-add: a
    /// `SecItemDelete` that can't remove a stale item — e.g. one whose access
    /// control is bound to a previous build's code signature — used to fail
    /// silently and leave a duplicate that `SecItemAdd` then rejected with
    /// `errSecDuplicateItem`, surfacing only as an opaque "failed".
    public static func setAPIKey(_ value: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Defaults.keychainAccount,
        ]
        let data = Data(value.utf8)

        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw WriteError(status: addStatus) }
        default:
            throw WriteError(status: updateStatus)
        }
    }

    @discardableResult
    public static func deleteAPIKey(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Defaults.keychainAccount,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
