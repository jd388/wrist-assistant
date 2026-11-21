import Foundation
import Security

enum GatewayTokenStore {
    private static let service = "com.example.wristassistant.gateway"
    private static let account = "deployment-token"
    private static let legacyDefaultsKey = "rendererAccessToken"
    private static let legacyBundleMigrationKey = "gatewayLegacyBundleTokenMigrated"

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
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GatewayTokenStoreError.readFailed(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw GatewayTokenStoreError.invalidStoredValue
        }
        return value
    }

    static func save(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_048 else {
            throw GatewayTokenStoreError.invalidNewValue
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
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GatewayTokenStoreError.writeFailed(updateStatus)
        }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GatewayTokenStoreError.writeFailed(addStatus)
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
            throw GatewayTokenStoreError.deleteFailed(status)
        }
        finalizeLegacyCleanup()
    }

    static func migrateLegacyTokenIfNeeded() throws -> String? {
        let defaults = UserDefaults.standard
        if let existing = try load() {
            finalizeLegacyCleanup(defaults: defaults)
            return existing
        }

        let legacyBundleToken = defaults.bool(forKey: legacyBundleMigrationKey)
            ? nil
            : BrowserServerDefaults.legacyAccessToken
        guard let candidate = GatewayCredentialMigrationPolicy.preferredLegacyToken(
            defaultsToken: defaults.string(forKey: legacyDefaultsKey),
            bundleToken: legacyBundleToken
        ) else {
            defaults.set(true, forKey: legacyBundleMigrationKey)
            return nil
        }

        do {
            try save(candidate)
            guard try load() == candidate else {
                throw GatewayTokenStoreError.migrationVerificationFailed
            }
        } catch {
            throw GatewayTokenStoreError.legacyMigrationFailed
        }
        finalizeLegacyCleanup(defaults: defaults)
        return candidate
    }

    static func finalizeLegacyCleanup(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyDefaultsKey)
        defaults.set(true, forKey: legacyBundleMigrationKey)
    }
}

enum GatewayTokenStoreError: LocalizedError, Sendable {
    case invalidNewValue
    case invalidStoredValue
    case legacyMigrationFailed
    case migrationVerificationFailed
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidNewValue:
            return "部署令牌为空或过长，请重新输入。"
        case .invalidStoredValue:
            return "Keychain 中的部署令牌无法读取，请删除后重新设置。"
        case .legacyMigrationFailed:
            return "旧部署令牌仍保留在原配置中。请解锁手表后进入云端设置重试迁移。"
        case .migrationVerificationFailed:
            return "旧部署令牌未能安全迁移；原配置仍保留，请重试。"
        case .readFailed:
            return "无法从手表 Keychain 读取部署令牌。"
        case .writeFailed:
            return "无法把部署令牌写入手表 Keychain。"
        case .deleteFailed:
            return "无法从手表 Keychain 删除部署令牌。"
        }
    }
}
