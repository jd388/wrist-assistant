import Foundation
import Security

enum DeepSeekKeyStore {
    private static let service = "com.example.wristassistant.deepseek"
    private static let account = "api-key"

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw DeepSeekKeyStoreError.readFailed(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw DeepSeekKeyStoreError.invalidStoredValue
        }
        return value
    }

    static func save(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 8, value.count <= 512 else {
            throw DeepSeekKeyStoreError.invalidNewValue
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw DeepSeekKeyStoreError.writeFailed(updateStatus)
        }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DeepSeekKeyStoreError.writeFailed(addStatus)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekKeyStoreError.deleteFailed(status)
        }
    }
}

enum DeepSeekKeyStoreError: LocalizedError, Sendable {
    case invalidNewValue
    case invalidStoredValue
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidNewValue:
            return "API 密钥长度不正确，请重新粘贴。"
        case .invalidStoredValue:
            return "已保存的 API 密钥无法读取，请删除后重新保存。"
        case .readFailed:
            return "无法读取手表中的 API 密钥。"
        case .writeFailed:
            return "无法把 API 密钥安全保存到手表。"
        case .deleteFailed:
            return "无法删除手表中的 API 密钥。"
        }
    }
}
