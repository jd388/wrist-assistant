import Foundation

public enum AIConversationPolicy {
    public static let archiveVersion = 1
    public static let maximumConversations = 20
    public static let maximumMessagesPerConversation = 40
    public static let maximumStoredCharacters = 120_000
    public static let maximumStoredBytes = 512 * 1_024
    public static let maximumStoredResponseItemsBytes = 256 * 1_024
    public static let maximumTitleCharacters = 36
    public static let maximumTitleBytes = 256
}

public enum AIConversationMessageStatus: String, Codable, Equatable, Sendable {
    case pending
    case completed
    case interrupted
}

public struct AIConversationMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: GatewayChatRole
    public var text: String
    public let createdAt: Date
    public var reasoning: String?
    public var citations: [GatewayCitation]
    public var answerBasis: String
    public var wasTruncated: Bool
    public var status: AIConversationMessageStatus
    public var responseItems: [GatewayResponseItem]?

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case reasoning
        case citations
        case answerBasis
        case wasTruncated
        case status
        case responseItems
    }

    public init(
        id: UUID = UUID(),
        role: GatewayChatRole,
        text: String,
        createdAt: Date = Date(),
        reasoning: String? = nil,
        citations: [GatewayCitation] = [],
        answerBasis: String = "",
        wasTruncated: Bool = false,
        status: AIConversationMessageStatus = .completed,
        responseItems: [GatewayResponseItem]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.reasoning = reasoning
        self.citations = citations
        self.answerBasis = answerBasis
        self.wasTruncated = wasTruncated
        self.status = status
        self.responseItems = role == .assistant
            ? responseItems.flatMap { try? GatewayResponseItemsPolicy.validated($0) }
            : nil
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(GatewayChatRole.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        reasoning = try values.decodeIfPresent(String.self, forKey: .reasoning)
        citations = try values.decode([GatewayCitation].self, forKey: .citations)
        answerBasis = try values.decode(String.self, forKey: .answerBasis)
        wasTruncated = try values.decode(Bool.self, forKey: .wasTruncated)
        status = try values.decodeIfPresent(
            AIConversationMessageStatus.self,
            forKey: .status
        ) ?? .completed
        let decodedItems = try values.decodeIfPresent(
            [GatewayJSONValue].self,
            forKey: .responseItems
        )
        responseItems = role == .assistant
            ? decodedItems.flatMap { raw in
                guard let items = try? raw.map({ try GatewayResponseItem(rawValue: $0) }) else {
                    return nil
                }
                return try? GatewayResponseItemsPolicy.validated(items)
            }
            : nil
    }
}

public struct AIConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public private(set) var title: String
    public private(set) var titleIsAutomatic: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [AIConversationMessage]
    public var draft: String
    public var webSearchEnabled: Bool
    public var deepThinkingEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case titleIsAutomatic
        case createdAt
        case updatedAt
        case messages
        case draft
        case webSearchEnabled
        case deepThinkingEnabled
    }

    public init(
        id: UUID = UUID(),
        title: String = "新对话",
        titleIsAutomatic: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AIConversationMessage] = [],
        draft: String = "",
        webSearchEnabled: Bool = false,
        deepThinkingEnabled: Bool = false
    ) {
        self.id = id
        if let normalizedTitle = Self.normalizedTitle(from: title) {
            self.title = normalizedTitle
            self.titleIsAutomatic = titleIsAutomatic
        } else {
            self.title = "新对话"
            self.titleIsAutomatic = true
        }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.draft = draft
        self.webSearchEnabled = webSearchEnabled
        self.deepThinkingEnabled = deepThinkingEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        let decodedTitle = try values.decode(String.self, forKey: .title)
        // Archives written before manual rename existed contain only automatic
        // titles, so treating a missing flag as automatic preserves their behavior.
        let decodedTitleIsAutomatic = try values.decodeIfPresent(
            Bool.self,
            forKey: .titleIsAutomatic
        ) ?? true
        if let normalizedTitle = Self.normalizedTitle(from: decodedTitle) {
            title = normalizedTitle
            titleIsAutomatic = decodedTitleIsAutomatic
        } else {
            title = "新对话"
            titleIsAutomatic = true
        }
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        messages = try values.decode([AIConversationMessage].self, forKey: .messages)
        draft = try values.decodeIfPresent(String.self, forKey: .draft) ?? ""
        webSearchEnabled = try values.decode(Bool.self, forKey: .webSearchEnabled)
        deepThinkingEnabled = try values.decode(Bool.self, forKey: .deepThinkingEnabled)
    }

    public var preview: String {
        guard let message = messages.last else {
            return draft.isEmpty ? "还没有消息" : "草稿：\(draft)"
        }
        let normalized = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { return normalized }
        switch message.status {
        case .pending:
            return "正在回答…"
        case .interrupted:
            return "回答已中断"
        case .completed:
            return "还没有消息"
        }
    }

    public mutating func append(_ message: AIConversationMessage, now: Date = Date()) {
        let isFirstUserMessage = message.role == .user
            && !messages.contains(where: { $0.role == .user })
        messages.append(message)
        if messages.count > AIConversationPolicy.maximumMessagesPerConversation {
            messages.removeFirst(messages.count - AIConversationPolicy.maximumMessagesPerConversation)
        }
        if isFirstUserMessage || (titleIsAutomatic && message.role == .user) {
            refreshAutomaticTitle()
        }
        updatedAt = now
    }

    @discardableResult
    public mutating func rename(to rawTitle: String, now: Date = Date()) -> Bool {
        guard let normalized = Self.normalizedTitle(from: rawTitle) else { return false }
        title = normalized
        titleIsAutomatic = false
        updatedAt = now
        return true
    }

    /// Replaces a user question without mutating anything unless the target and
    /// replacement are valid. Messages after the question are discarded so a
    /// caller can safely generate a fresh answer from the retained prefix.
    @discardableResult
    public mutating func replaceUserMessageAndTruncate(
        id: UUID,
        with rawText: String,
        now: Date = Date()
    ) -> Bool {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= GatewayRequestPolicy.maximumQuestionCharacters,
              normalized.utf8.count <= GatewayRequestPolicy.maximumQuestionBytes,
              let index = messages.firstIndex(where: { $0.id == id && $0.role == .user }) else {
            return false
        }
        messages[index].text = normalized
        if messages.index(after: index) < messages.endIndex {
            messages.removeSubrange(messages.index(after: index)..<messages.endIndex)
        }
        refreshAutomaticTitle()
        updatedAt = now
        return true
    }

    public mutating func replaceMessage(
        id: UUID,
        text: String,
        reasoning: String? = nil,
        citations: [GatewayCitation] = [],
        answerBasis: String = "",
        wasTruncated: Bool = false,
        responseItems: [GatewayResponseItem]? = nil,
        now: Date = Date()
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        messages[index].reasoning = reasoning
        messages[index].citations = citations
        messages[index].answerBasis = answerBasis
        messages[index].wasTruncated = wasTruncated
        messages[index].responseItems = messages[index].role == .assistant
            ? responseItems.flatMap { try? GatewayResponseItemsPolicy.validated($0) }
            : nil
        updatedAt = now
    }

    public mutating func removeMessage(id: UUID, now: Date = Date()) {
        messages.removeAll { $0.id == id }
        updatedAt = now
    }

    public func requestHistory(excludingMessageID: UUID? = nil) -> [GatewayChatMessage] {
        var completedTurns: [(user: GatewayChatMessage, assistant: GatewayChatMessage)] = []
        var index = messages.startIndex
        while index < messages.endIndex {
            let assistantIndex = messages.index(after: index)
            guard assistantIndex < messages.endIndex else { break }
            let userMessage = messages[index]
            let assistantMessage = messages[assistantIndex]
            guard userMessage.id != excludingMessageID,
                  assistantMessage.id != excludingMessageID,
                  userMessage.role == .user,
                  assistantMessage.role == .assistant,
                  userMessage.status == .completed,
                  assistantMessage.status == .completed,
                  let user = try? GatewayChatMessage(
                      role: .user,
                      content: userMessage.text
                  ),
                  let assistant = try? GatewayChatMessage(
                      role: .assistant,
                      content: assistantMessage.text,
                      responseItems: assistantMessage.responseItems
                  ) else {
                index = assistantIndex
                continue
            }
            completedTurns.append((user, assistant))
            index = messages.index(after: assistantIndex)
        }

        var remainingCharacters = GatewayRequestPolicy.maximumConversationCharacters
        var remainingBytes = GatewayRequestPolicy.maximumConversationBytes
        var remainingResponseItemsBytes = GatewayRequestPolicy
            .maximumConversationResponseItemsBytes
        var reversedTurns: [(user: GatewayChatMessage, assistant: GatewayChatMessage)] = []
        for turn in completedTurns.reversed() {
            guard (reversedTurns.count + 1) * 2 <= GatewayRequestPolicy.maximumConversationMessages else {
                break
            }
            let characterCost = turn.user.content.count + turn.assistant.content.count
            let byteCost = turn.user.content.utf8.count + turn.assistant.content.utf8.count
            var assistant = turn.assistant
            var responseItemsByteCost = (try? turn.assistant.responseItems.map {
                try GatewayResponseItemsPolicy.byteCount(of: $0)
            }) ?? 0
            if responseItemsByteCost > remainingResponseItemsBytes {
                guard let visibleAssistant = try? GatewayChatMessage(
                    role: .assistant,
                    content: turn.assistant.content
                ) else { break }
                assistant = visibleAssistant
                responseItemsByteCost = 0
            }
            guard characterCost <= remainingCharacters,
                  byteCost <= remainingBytes else { break }
            reversedTurns.append((turn.user, assistant))
            remainingCharacters -= characterCost
            remainingBytes -= byteCost
            remainingResponseItemsBytes -= responseItemsByteCost
        }
        return reversedTurns.reversed().flatMap { [$0.user, $0.assistant] }
    }

    public static func makeTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        var topic = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-•> "))
        let prefixes = [
            "能不能帮我", "可以帮我", "能否帮我", "麻烦你帮我", "请你帮我", "请帮我",
            "我想了解一下", "我想了解", "我想知道", "我想问一下", "我想问",
            "请问", "请你", "帮我", "麻烦你", "介绍一下", "介绍", "解释一下", "解释",
            "总结一下", "总结", "制定一个", "制定一份", "制作一份", "关于",
            "could you ", "can you ", "please ", "tell me about ", "explain "
        ]
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            // A standalone polite 请 is removed, but technical words such as 请求 stay intact.
            if topic.hasPrefix("请 ") {
                topic = String(topic.dropFirst()).trimmingCharacters(in: .whitespaces)
                removedPrefix = true
            }
            for prefix in prefixes {
                if let range = topic.range(of: prefix, options: [.anchored, .caseInsensitive]),
                   topic[range.upperBound...].trimmingCharacters(in: .whitespaces).count >= 2 {
                    topic = String(topic[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    removedPrefix = true
                    break
                }
            }
        }
        if let end = topic.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？!?；;")) {
            let firstSentence = String(topic[..<end.lowerBound])
            if firstSentence.count >= 2 { topic = firstSentence }
        }
        for connector in ["并说明", "并且", "同时", "然后", "，要求", ", with "] {
            if let end = topic.range(of: connector), topic[..<end.lowerBound].count >= 4 {
                topic = String(topic[..<end.lowerBound])
            }
        }
        topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = ""
        var width = 0
        for character in topic {
            let cost = character.unicodeScalars.contains { $0.value > 0xFF } ? 2 : 1
            guard width + cost <= 32 else {
                title = title.trimmingCharacters(in: .whitespaces) + "…"
                break
            }
            title.append(character)
            width += cost
        }
        return normalizedTitle(from: title) ?? "新对话"
    }

    /// Local topic extraction; never overwrites a title explicitly chosen by the user.
    @discardableResult
    public mutating func refreshAutomaticTitle() -> Bool {
        guard titleIsAutomatic else { return false }
        let questions = messages.filter { $0.role == .user && !$0.text.isEmpty }
        let greetings: Set<String> = ["你好", "您好", "hi", "hello", "在吗", "早上好", "晚上好"]
        let question = questions.first {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters).lowercased()
            return !greetings.contains(text)
        } ?? questions.first
        guard let question else { return false }
        let updated = Self.makeTitle(from: question.text)
        guard title != updated else { return false }
        title = updated
        return true
    }

    public static func normalizedTitle(from text: String) -> String? {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        var bounded = ""
        var wasTruncated = false
        for character in normalized {
            let value = String(character)
            guard bounded.count < AIConversationPolicy.maximumTitleCharacters,
                  bounded.utf8.count + value.utf8.count
                    <= AIConversationPolicy.maximumTitleBytes else {
                wasTruncated = true
                break
            }
            bounded.append(character)
        }
        guard !bounded.isEmpty else { return nil }
        guard wasTruncated else { return bounded }

        let ellipsis = "…"
        while !bounded.isEmpty,
              bounded.count + 1 > AIConversationPolicy.maximumTitleCharacters
                || bounded.utf8.count + ellipsis.utf8.count
                    > AIConversationPolicy.maximumTitleBytes {
            bounded.removeLast()
        }
        guard !bounded.isEmpty else { return nil }
        return bounded + ellipsis
    }
}

public struct AIConversationArchive: Codable, Equatable, Sendable {
    public let version: Int
    public var conversations: [AIConversation]
    public var selectedConversationID: UUID?

    public init(
        version: Int = AIConversationPolicy.archiveVersion,
        conversations: [AIConversation],
        selectedConversationID: UUID?
    ) {
        self.version = version
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
    }

    public func compacted() -> AIConversationArchive {
        var remainingCharacters = AIConversationPolicy.maximumStoredCharacters
        var remainingBytes = AIConversationPolicy.maximumStoredBytes
        var remainingResponseItemsBytes = AIConversationPolicy.maximumStoredResponseItemsBytes
        var retained: [AIConversation] = []
        let newestFirst = conversations.sorted { $0.updatedAt > $1.updatedAt }
        for var conversation in newestFirst.prefix(AIConversationPolicy.maximumConversations) {
            // Reserve the unsent input before trimming older message content.
            var retainedDraft = ""
            for character in conversation.draft {
                let byteCount = String(character).utf8.count
                guard remainingCharacters > 0, byteCount <= remainingBytes else { break }
                retainedDraft.append(character)
                remainingCharacters -= 1
                remainingBytes -= byteCount
            }
            conversation.draft = retainedDraft
            var messages: [AIConversationMessage] = []
            for message in conversation.messages.reversed() {
                var retainedMessage = message
                let cost = message.text.count + (message.reasoning?.count ?? 0)
                let textBytes = message.text.utf8.count + (message.reasoning?.utf8.count ?? 0)
                var responseItemsBytes = (try? message.responseItems.map {
                    try GatewayResponseItemsPolicy.byteCount(of: $0)
                }) ?? 0
                if responseItemsBytes > remainingResponseItemsBytes
                    || textBytes + responseItemsBytes > remainingBytes {
                    retainedMessage.responseItems = nil
                    responseItemsBytes = 0
                }
                let byteCost = textBytes + responseItemsBytes
                guard cost <= remainingCharacters,
                      byteCost <= remainingBytes else { break }
                messages.append(retainedMessage)
                remainingCharacters -= cost
                remainingBytes -= byteCost
                remainingResponseItemsBytes -= responseItemsBytes
            }
            conversation.messages = messages.reversed()
            retained.append(conversation)
            if remainingCharacters == 0 || remainingBytes == 0 { break }
        }
        let selected = retained.contains(where: { $0.id == selectedConversationID })
            ? selectedConversationID
            : retained.first?.id
        return AIConversationArchive(
            conversations: retained,
            selectedConversationID: selected
        )
    }
}
