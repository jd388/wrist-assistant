import Foundation

struct AIConversationStore: Sendable {
    enum StoreError: LocalizedError {
        case unavailableDirectory
        case unsupportedArchive

        var errorDescription: String? {
            switch self {
            case .unavailableDirectory:
                return "无法打开本机对话存储目录。"
            case .unsupportedArchive:
                return "本机对话记录来自不兼容版本，已安全忽略。"
            }
        }
    }

    private let fileURL: URL

    init(fileManager: FileManager = .default) throws {
        guard let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.unavailableDirectory
        }
        let directory = baseURL.appendingPathComponent("WristAI", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("conversations.json")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    func load() throws -> AIConversationArchive? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive = try decoder.decode(AIConversationArchive.self, from: data)
        guard archive.version == AIConversationPolicy.archiveVersion else {
            throw StoreError.unsupportedArchive
        }
        return archive.compacted()
    }

    func save(_ archive: AIConversationArchive) throws {
        let compacted = archive.compacted()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(compacted)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }

    func deleteArchive() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
