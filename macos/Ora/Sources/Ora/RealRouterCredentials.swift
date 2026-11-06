import Foundation
import Security

/// API keys never enter UserDefaults, source files, transcripts, or diagnostic logs.
struct RealRouterCredentials {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.wangzhangwu.ora") + ".realrouter",
         kSecAttrAccount as String: "api-key"]
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not access the RealRouter key in Keychain (\(status))." }
    }

    static func load() throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { throw RealRouterError.missingKey }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw KeychainError(status: status)
        }
        return value
    }

    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RealRouterError.missingKey }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if updated != errSecSuccess { throw KeychainError(status: updated) }
    }
}
