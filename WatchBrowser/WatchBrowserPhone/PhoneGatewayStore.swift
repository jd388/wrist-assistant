import Foundation
import Security

#if DEBUG
import Darwin
#endif

struct PhoneGatewayConfiguration: Equatable, Sendable {
    let baseURL: URL
    let bearerToken: String
}

enum PhoneGatewayStoreError: LocalizedError, Sendable {
    case invalidServerURL
    case missingToken
    case invalidToken
    case persistenceVerificationFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "服务器地址必须是没有账号、查询参数或额外路径的 HTTPS 地址。"
        case .missingToken:
            return "请输入部署令牌。已保存令牌时可留空以继续使用原令牌。"
        case .invalidToken:
            return "部署令牌格式无效，请检查后重新输入。"
        case .persistenceVerificationFailed:
            return "无法验证网关设置已安全保存。"
        case .keychainReadFailed:
            return "无法读取 iPhone Keychain，请解锁手机后重试。"
        case .keychainWriteFailed:
            return "无法写入 iPhone Keychain，请稍后重试。"
        case .keychainDeleteFailed:
            return "无法删除 iPhone Keychain 中的部署令牌。"
        }
    }
}

enum PhoneGatewayStore {
    private static let defaultsKey = "phoneGatewayServerURL"
    private static let keychainService = "com.example.wristassistant.phone.gateway"
    private static let keychainAccount = "deployment-token"

    static var savedServerURL: String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }

    static func hasSavedToken() throws -> Bool {
        try loadToken() != nil
    }

    static func loadConfiguration() throws -> PhoneGatewayConfiguration? {
        guard let rawServerURL = savedServerURL else { return nil }
        guard let token = try loadToken() else { return nil }
        return PhoneGatewayConfiguration(
            baseURL: try normalizedServerURL(rawServerURL),
            bearerToken: token
        )
    }

    @discardableResult
    static func save(serverURL rawServerURL: String, replacementToken: String?) throws -> URL {
        let serverURL = try normalizedServerURL(rawServerURL)
        let trimmedReplacement = replacementToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let token: String
        if let trimmedReplacement, !trimmedReplacement.isEmpty {
            token = try validatedToken(trimmedReplacement)
        } else if let existing = try loadToken() {
            token = existing
        } else {
            throw PhoneGatewayStoreError.missingToken
        }

        try saveToken(token)
        UserDefaults.standard.set(serverURL.absoluteString, forKey: defaultsKey)
        return serverURL
    }

    static func deleteConfiguration() throws {
        try deleteToken()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    @discardableResult
    static func importVerified(serverURL rawServerURL: String, token rawToken: String) throws -> URL {
        let serverURL = try normalizedServerURL(rawServerURL)
        let token = try validatedToken(
            rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let previousURL = savedServerURL
        let previousToken = try loadToken()

        do {
            try saveToken(token)
            UserDefaults.standard.set(serverURL.absoluteString, forKey: defaultsKey)
            guard try loadConfiguration() == PhoneGatewayConfiguration(
                baseURL: serverURL,
                bearerToken: token
            ) else {
                throw PhoneGatewayStoreError.persistenceVerificationFailed
            }
            return serverURL
        } catch {
            try? restore(serverURL: previousURL, token: previousToken)
            throw error
        }
    }

    static func normalizedServerURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else {
            throw PhoneGatewayStoreError.invalidServerURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw PhoneGatewayStoreError.invalidServerURL
        }

        components.scheme = "https"
        components.host = host.lowercased()
        components.port = components.port == 443 ? nil : components.port
        components.path = ""
        guard let normalizedURL = components.url else {
            throw PhoneGatewayStoreError.invalidServerURL
        }
        return normalizedURL
    }

    private static func validatedToken(_ value: String) throws -> String {
        guard value.utf8.count >= 8,
              value.utf8.count <= 2_048,
              value.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar)
                      && !CharacterSet.controlCharacters.contains(scalar)
              }) else {
            throw PhoneGatewayStoreError.invalidToken
        }
        return value
    }

    private static func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw PhoneGatewayStoreError.keychainReadFailed(status)
        }
        return try validatedToken(token)
    }

    private static func saveToken(_ token: String) throws {
        let value = try validatedToken(token)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PhoneGatewayStoreError.keychainWriteFailed(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PhoneGatewayStoreError.keychainWriteFailed(addStatus)
        }
    }

    private static func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PhoneGatewayStoreError.keychainDeleteFailed(status)
        }
    }

    private static func restore(serverURL: String?, token: String?) throws {
        if let token {
            try saveToken(token)
        } else {
            try deleteToken()
        }
        if let serverURL {
            UserDefaults.standard.set(serverURL, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}

struct PhoneGatewayDebugImportResult: Sendable {
    let succeeded: Bool
    let message: String
}

enum PhoneGatewayDebugImporter {
    static func importIfPresent() -> PhoneGatewayDebugImportResult? {
        #if DEBUG
        let variableNames = [
            "WRIST_GATEWAY_SETUP_URL",
            "WRIST_GATEWAY_SETUP_TOKEN",
            "WRIST_GATEWAY_SETUP_ATTEMPT_ID"
        ]
        let serverURL = environmentValue(variableNames[0])
            ?? environmentValue("DEVICECTL_CHILD_\(variableNames[0])")
        let token = environmentValue(variableNames[1])
            ?? environmentValue("DEVICECTL_CHILD_\(variableNames[1])")
        let attemptID = environmentValue(variableNames[2])
            ?? environmentValue("DEVICECTL_CHILD_\(variableNames[2])")

        guard serverURL != nil || token != nil || attemptID != nil else { return nil }

        for name in variableNames {
            unsetenv(name)
            unsetenv("DEVICECTL_CHILD_\(name)")
        }

        guard let serverURL,
              let token,
              let attemptID,
              UUID(uuidString: attemptID) != nil else {
            let receiptID = "invalid-attempt"
            let message = "本地导入缺少有效回执编号或完整配置。"
            writeReceipt(attemptID: receiptID, succeeded: false, message: message)
            let defaults = UserDefaults.standard
            defaults.set(receiptID, forKey: "phoneGatewayLocalImportAttemptID")
            defaults.set(false, forKey: "phoneGatewayLocalImportSucceeded")
            return PhoneGatewayDebugImportResult(
                succeeded: false,
                message: message
            )
        }

        let defaults = UserDefaults.standard
        defaults.set(attemptID, forKey: "phoneGatewayLocalImportAttemptID")
        do {
            try PhoneGatewayStore.importVerified(serverURL: serverURL, token: token)
            let message = "网关地址与部署令牌已安全保存。"
            defaults.set(true, forKey: "phoneGatewayLocalImportSucceeded")
            writeReceipt(attemptID: attemptID, succeeded: true, message: message)
            return PhoneGatewayDebugImportResult(
                succeeded: true,
                message: "已安全导入服务器地址，部署令牌已写入 iPhone Keychain。"
            )
        } catch {
            let message = "本地网关配置失败，原配置已保留。"
            defaults.set(false, forKey: "phoneGatewayLocalImportSucceeded")
            writeReceipt(attemptID: attemptID, succeeded: false, message: message)
            return PhoneGatewayDebugImportResult(
                succeeded: false,
                message: message
            )
        }
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func environmentValue(_ name: String) -> String? {
        guard let pointer = getenv(name) else { return nil }
        return String(validatingCString: pointer)
    }

    private static func writeReceipt(
        attemptID: String,
        succeeded: Bool,
        message: String
    ) {
        struct Receipt: Codable {
            let attemptID: String
            let succeeded: Bool
            let message: String

            enum CodingKeys: String, CodingKey {
                case attemptID = "attempt_id"
                case succeeded
                case message
            }
        }

        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first,
        let data = try? JSONEncoder().encode(
            Receipt(attemptID: attemptID, succeeded: succeeded, message: message)
        ) else {
            return
        }
        let receiptURL = cachesURL.appendingPathComponent(
            "gateway-import-ack.json",
            isDirectory: false
        )
        try? data.write(to: receiptURL, options: .atomic)
    }
    #endif
}
