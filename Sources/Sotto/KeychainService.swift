import Foundation
import Security

enum KeychainService {
    private static let service = "com.sotto.dictation"
    private static let account = "openrouter-api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    static func readAPIKey() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SottoError.message("The stored API key could not be read. Remove it and save it again.")
        }
        return value
    }

    static func saveAPIKey(_ key: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw SottoError.message("Enter an API key before saving.") }
        let data = Data(cleaned.utf8)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw error(addStatus) }
        } else if status != errSecSuccess { throw error(status) }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    private static func error(_ status: OSStatus) -> SottoError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "macOS error \(status)"
        return .message("Keychain could not complete the request: \(detail)")
    }
}
