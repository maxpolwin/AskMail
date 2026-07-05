import Foundation
import Security

/// API keys live in the macOS Keychain, read at runtime via the Security
/// framework. Never in code, config, or logs (SECURITY.md). Services:
/// "askmail.ollama-cloud" and "askmail.mistral", account "api-key".
public enum Keychain {

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

    @discardableResult
    public static func setAPIKey(_ value: String, service: String) -> Bool {
        deleteAPIKey(service: service)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Defaults.keychainAccount,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
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
