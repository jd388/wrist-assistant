import Foundation

enum DictionaryResourceIssue: Error, Equatable, Sendable {
    case coreMissing
    case coreUnreadable
    case coreInvalid
    case coreEmpty
    case extendedMissing
    case extendedInvalidSchema
    case extendedOpenFailed

    var title: String {
        switch self {
        case .coreMissing, .coreUnreadable, .coreInvalid, .coreEmpty:
            "核心词典不可用"
        case .extendedMissing, .extendedInvalidSchema, .extendedOpenFailed:
            "扩展词典不可用"
        }
    }

    var detail: String {
        switch self {
        case .coreMissing:
            "应用中缺少核心词典资源，已停止自动查词与翻译。"
        case .coreUnreadable:
            "核心词典暂时无法读取，已停止自动查词与翻译。"
        case .coreInvalid:
            "核心词典内容已损坏或版本不兼容，已停止自动查词与翻译。"
        case .coreEmpty:
            "核心词典没有可用词条，已停止自动查词与翻译。"
        case .extendedMissing:
            "应用中缺少扩展词典。为避免把资源故障误判成未收词，本次没有自动转入模型翻译。"
        case .extendedInvalidSchema:
            "扩展词典版本与应用不兼容。为避免误判，本次没有自动转入模型翻译。"
        case .extendedOpenFailed:
            "扩展词典无法打开，可能已经损坏。为避免误判，本次没有自动转入模型翻译。"
        }
    }

    var recovery: String {
        "请重新安装应用后再试；原输入会保留。也可以明确选择仅使用本地模型翻译。"
    }

    static func extended(_ availability: ExtendedDictionaryAvailability) -> Self? {
        switch availability {
        case .available:
            nil
        case .missing:
            .extendedMissing
        case .invalidSchema:
            .extendedInvalidSchema
        case .openFailed:
            .extendedOpenFailed
        }
    }

    static func extended(_ error: ExtendedDictionaryStoreError) -> Self {
        switch error {
        case let .unavailable(availability):
            extended(availability) ?? .extendedOpenFailed
        case .queryFailed, .invalidPayload:
            .extendedOpenFailed
        }
    }
}

enum DictionaryRepository {
    static func loadBundledEntries(bundle: Bundle = .main) throws -> [DictionaryEntry] {
        guard let url = bundle.url(
            forResource: "offline_dictionary",
            withExtension: "json"
        ) else {
            throw DictionaryResourceIssue.coreMissing
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DictionaryResourceIssue.coreUnreadable
        }

        let entries: [DictionaryEntry]
        do {
            entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        } catch {
            throw DictionaryResourceIssue.coreInvalid
        }
        guard !entries.isEmpty else {
            throw DictionaryResourceIssue.coreEmpty
        }
        return entries
    }

    static func extendedDatabaseURL(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: "offline_dictionary_extended",
            withExtension: "sqlite"
        )
    }

}
