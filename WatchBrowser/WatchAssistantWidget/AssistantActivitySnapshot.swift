import Foundation
import Security

struct AssistantActivitySnapshot: Codable, Equatable {
    static let widgetKind = "WatchAssistantActivity"

    var favorite: String?
    var lookup: String?
    var question: String?

    private static func item(account: String = "recent-activity") -> [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AssistantActivityAccessGroup") as? String,
              group.split(separator: ".").first?.count == 10 else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.example.wristassistant.widget-activity",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group
        ]
    }

    static func read() -> Self {
        guard let query = item(), let data = read(query),
              let cached = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return cached
    }

    func save() throws {
        guard let query = Self.item() else { throw CocoaError(.fileNoSuchFile) }
        try Self.write(JSONEncoder().encode(self), to: query)
    }

    private static func read(_ query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, to query: [String: Any]) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var new = query
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    #if DEBUG
    static func testSharedStorage() -> Bool {
        guard let query = item(account: UUID().uuidString) else { return false }
        let token = Data([0x57])
        defer { SecItemDelete(query as CFDictionary) }
        return (try? write(token, to: query)) != nil && read(query) == token
    }
    #endif

    static func preview(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 72 ? trimmed : String(trimmed.prefix(72)) + "…"
    }
}
