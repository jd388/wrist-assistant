import Foundation

public enum GatewayRequestPolicy {
    public static let minimumPageCharacters = 500
    public static let maximumQuestionCharacters = 2_000
    public static let maximumQuestionBytes = 8_000
    public static let maximumConversationMessages = 24
    public static let maximumConversationCharacters = 24_000
    public static let maximumConversationBytes = 96_000
    public static let maximumConversationMessageCharacters = 8_000
    public static let maximumConversationMessageBytes = 32_000
    public static let maximumResponseItemsPerMessage = 24
    public static let maximumResponseItemBytes = 48 * 1_024
    public static let maximumResponseItemsBytesPerMessage = 64 * 1_024
    public static let maximumConversationResponseItemsBytes = 128 * 1_024
    public static let maximumAskRequestBytes = 256 * 1_024
    public static let maximumPageCharacters = 12_000
    public static let maximumPageBlocks = 40
    public static let maximumPageLinks = 30
}

public enum AIRequestPath: Equatable, Sendable {
    case directDeepSeek
    case cloudflareDeepSeekProxy
    case unconfigured
}

public enum AIRequestPathPolicy {
    /// A Watch-local DeepSeek credential always wins. The Cloudflare path is a
    /// compatibility route only when the Watch has no direct credential and a
    /// complete gateway configuration is available.
    public static func select(
        hasDeepSeekCredential: Bool,
        hasValidCloudflareConfiguration: Bool
    ) -> AIRequestPath {
        if hasDeepSeekCredential { return .directDeepSeek }
        if hasValidCloudflareConfiguration { return .cloudflareDeepSeekProxy }
        return .unconfigured
    }
}

public struct GatewayReadRequest: Codable, Equatable, Sendable {
    public let url: String
    public let preferDynamic: Bool
    public let maxBlocks: Int
    public let maxCharacters: Int
    public let maxLinks: Int

    enum CodingKeys: String, CodingKey {
        case url
        case preferDynamic = "prefer_dynamic"
        case maxBlocks = "max_blocks"
        case maxCharacters = "max_characters"
        case maxLinks = "max_links"
    }

    public init(
        url: URL,
        preferDynamic: Bool = false,
        maxBlocks: Int = GatewayRequestPolicy.maximumPageBlocks,
        maxCharacters: Int = GatewayRequestPolicy.maximumPageCharacters,
        maxLinks: Int = GatewayRequestPolicy.maximumPageLinks
    ) {
        self.url = url.absoluteString
        self.preferDynamic = preferDynamic
        self.maxBlocks = max(1, min(maxBlocks, GatewayRequestPolicy.maximumPageBlocks))
        self.maxCharacters = max(
            GatewayRequestPolicy.minimumPageCharacters,
            min(maxCharacters, GatewayRequestPolicy.maximumPageCharacters)
        )
        self.maxLinks = max(0, min(maxLinks, GatewayRequestPolicy.maximumPageLinks))
    }
}

public enum GatewayRetryPolicy {
    public static let retryableHTTPStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    public static func shouldRetry(
        attempt: Int,
        statusCode: Int,
        serverMarkedRetryable: Bool
    ) -> Bool {
        attempt == 0
            && (serverMarkedRetryable || retryableHTTPStatusCodes.contains(statusCode))
    }
}

public enum GatewayRedirectPolicy {
    public static func allowsRedirect(from originalURL: URL?, to destinationURL: URL) -> Bool {
        false
    }
}

public enum GatewayPersonalFallbackPolicy {
    private static let unavailableAICodes: Set<String> = [
        "ai_not_configured",
        "ai_unavailable",
        "ai_missing_key",
        "missing_ai_key"
    ]
    private static let unavailableHTTPStatusCodes: Set<Int> = [500, 502, 503, 504]

    public static func shouldOffer(
        forPageBoundTask: Bool,
        isNetworkFailure: Bool,
        httpStatusCode: Int? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> Bool {
        guard !forPageBoundTask else { return false }
        if isNetworkFailure { return true }
        if let httpStatusCode {
            let issue = GatewayServiceIssuePolicy.classify(
               statusCode: httpStatusCode,
               errorCode: errorCode,
               errorMessage: errorMessage
            )
            if issue == .aiDailyQuotaExhausted || issue == .aiCapacityUnavailable {
                return false
            }
        }
        if let errorCode, unavailableAICodes.contains(errorCode) { return true }
        if let httpStatusCode, unavailableHTTPStatusCodes.contains(httpStatusCode) { return true }
        return false
    }
}

public enum GatewayServiceIssue: Equatable, Sendable {
    case aiNotConfigured
    case aiDailyQuotaExhausted
    case aiCapacityUnavailable
    case dynamicDailyQuotaExhausted
    case rateLimited
    case dynamicServiceUnavailable
    case serviceUnavailable
    case sessionExpired
    case other
}

public enum GatewayServiceIssuePolicy {
    public static func classify(
        statusCode: Int,
        errorCode: String?,
        errorMessage: String? = nil
    ) -> GatewayServiceIssue {
        let code = errorCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") ?? ""
        let message = errorMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if ["ai_not_configured", "ai_unavailable", "ai_missing_key", "missing_ai_key"]
            .contains(code) {
            return .aiNotConfigured
        }
        let explicitAIDailyLimitCodes: Set<String> = [
            "ai_daily_limit",
            "workers_ai_daily_limit",
            "workers_ai_daily_quota",
            "workers_ai_quota_exhausted"
        ]
        let workersAIDailyLimit = code.contains("workers_ai")
            && (code.contains("daily") || code.contains("quota"))
            && (code.contains("limit") || code.contains("exhausted") || code.contains("quota"))
        let workersAIAccountLimited3036 = statusCode == 429
            && ((code.contains("3036") || message.contains("3036"))
                || code.contains("account_limited")
                || message.contains("account limited"))
        if explicitAIDailyLimitCodes.contains(code)
            || workersAIDailyLimit
            || workersAIAccountLimited3036 {
            return .aiDailyQuotaExhausted
        }

        let explicitAICapacityCodes: Set<String> = [
            "ai_capacity_unavailable",
            "workers_ai_capacity_unavailable"
        ]
        let workersAICapacity3040 = (code.contains("3040") || message.contains("3040"))
            && (code.contains("capacity") || message.contains("capacity"))
        if explicitAICapacityCodes.contains(code) || workersAICapacity3040 {
            return .aiCapacityUnavailable
        }
        if statusCode == 410 || code == "session_expired" || code == "session_unavailable" {
            return .sessionExpired
        }

        let refersToDynamicBrowser = code.contains("browser")
            || code.contains("renderer")
            || code.contains("dynamic")
        let refersToDailyLimit = code.contains("daily")
            && (code.contains("quota") || code.contains("limit"))
        let exhaustedBrowserQuota = refersToDynamicBrowser
            && code.contains("quota")
            && (code.contains("exhausted") || code.contains("exceeded"))
        if refersToDailyLimit || exhaustedBrowserQuota {
            return .dynamicDailyQuotaExhausted
        }

        if statusCode == 429 { return .rateLimited }
        if refersToDynamicBrowser && (statusCode == 503 || code.contains("unavailable")) {
            return .dynamicServiceUnavailable
        }
        if statusCode == 503 { return .serviceUnavailable }
        return .other
    }
}

public struct GatewayHealthResponse: Decodable, Equatable, Sendable {
    public let status: String
    public let browserReady: Bool
    public let readerReady: Bool?
    public let aiConfigured: Bool?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case status
        case browserReady = "browser_ready"
        case readerReady = "reader_ready"
        case aiConfigured = "ai_configured"
        case detail
    }

    public var isAcceptedServiceStatus: Bool {
        status == "ok" || status == "degraded"
    }

    public func isAccepted(httpStatusCode: Int) -> Bool {
        (200..<300).contains(httpStatusCode) && isAcceptedServiceStatus
    }

    public var effectiveReaderReady: Bool {
        readerReady ?? (status == "ok")
    }
}

public struct ReaderNavigationIntent: Equatable, Sendable {
    public let remembersCurrentPage: Bool
    public let isBackNavigation: Bool

    public init(remembersCurrentPage: Bool, isBackNavigation: Bool) {
        self.remembersCurrentPage = remembersCurrentPage
        self.isBackNavigation = isBackNavigation
    }

    public static let none = ReaderNavigationIntent(
        remembersCurrentPage: false,
        isBackNavigation: false
    )

    public func shouldPushCurrentPage(
        hasCurrentDocument: Bool,
        currentURL: URL?,
        resolvedURL: URL
    ) -> Bool {
        remembersCurrentPage
            && !isBackNavigation
            && hasCurrentDocument
            && currentURL != nil
            && currentURL != resolvedURL
    }
}

public enum GatewayCredentialMigrationPolicy {
    public static func preferredLegacyToken(
        defaultsToken: String?,
        bundleToken: String?
    ) -> String? {
        [defaultsToken, bundleToken]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.contains("$(") }
    }
}

public struct GatewayContentBlock: Codable, Equatable, Sendable {
    public let kind: String
    public let text: String

    public init(kind: String, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct GatewayPageLink: Codable, Equatable, Sendable {
    public let text: String
    public let url: String

    public init(text: String, url: String) {
        self.text = text
        self.url = url
    }
}

public struct GatewayPageContext: Codable, Equatable, Sendable {
    public let url: String?
    public let title: String?
    public let blocks: [GatewayContentBlock]

    public init(url: String?, title: String?, blocks: [GatewayContentBlock]) {
        self.url = url
        self.title = title
        self.blocks = blocks
    }

    public init(document: DirectWebDocument, url: URL?) {
        self.url = url?.absoluteString
        title = document.title

        var remainingCharacters = GatewayRequestPolicy.maximumPageCharacters
        var result: [GatewayContentBlock] = []
        let paragraphs = document.text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for paragraph in paragraphs.prefix(GatewayRequestPolicy.maximumPageBlocks) {
            guard remainingCharacters > 0 else { break }
            let text = String(paragraph.prefix(remainingCharacters))
            result.append(GatewayContentBlock(kind: "paragraph", text: text))
            remainingCharacters -= text.count
        }
        blocks = result
    }
}

public struct GatewayReadResponse: Decodable, Equatable, Sendable {
    public let url: String
    public let finalURL: String
    public let title: String
    public let blocks: [GatewayContentBlock]
    public let links: [GatewayPageLink]
    public let truncated: Bool
    public let source: String
    public let characterCount: Int
    public let blockedSubresources: Int

    enum CodingKeys: String, CodingKey {
        case url
        case finalURL = "final_url"
        case title
        case blocks
        case links
        case truncated
        case source
        case characterCount = "character_count"
        case totalCharacterCount = "total_character_count"
        case blockedSubresources = "blocked_subresources"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        finalURL = try values.decode(String.self, forKey: .finalURL)
        title = try values.decode(String.self, forKey: .title)
        blocks = try values.decode([GatewayContentBlock].self, forKey: .blocks)
        links = try values.decode([GatewayPageLink].self, forKey: .links)
        truncated = try values.decode(Bool.self, forKey: .truncated)
        source = try values.decode(String.self, forKey: .source)
        characterCount = try values.decodeIfPresent(Int.self, forKey: .characterCount)
            ?? values.decodeIfPresent(Int.self, forKey: .totalCharacterCount)
            ?? blocks.reduce(0) { $0 + $1.text.count }
        blockedSubresources = try values.decodeIfPresent(Int.self, forKey: .blockedSubresources) ?? 0
    }

    public func directDocument() throws -> DirectWebDocument {
        guard let resolvedURL = URL(string: finalURL) ?? URL(string: url) else {
            throw GatewayProtocolError.invalidPageURL
        }

        let normalizedText = blocks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !normalizedText.isEmpty else {
            throw GatewayProtocolError.emptyPage
        }

        let resolvedLinks = links.compactMap { link -> DirectWebLink? in
            guard let candidate = URL(string: link.url, relativeTo: resolvedURL)?.absoluteURL,
                  candidate.scheme == "https" || candidate.scheme == "http" else {
                return nil
            }
            let label = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return DirectWebLink(
                title: label.isEmpty ? (candidate.host ?? "打开链接") : label,
                url: candidate
            )
        }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return DirectWebDocument(
            title: normalizedTitle.isEmpty ? (resolvedURL.host ?? "网页") : normalizedTitle,
            text: normalizedText,
            links: resolvedLinks,
            isLikelyDynamic: false,
            wasTruncated: truncated
        )
    }

    public var pageContext: GatewayPageContext {
        GatewayPageContext(url: finalURL, title: title, blocks: blocks)
    }
}

public enum GatewayAskMode: String, Codable, Equatable, Sendable {
    case answer
    case summarize
}

public enum GatewayChatRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

/// A lossless JSON value used to preserve DeepSeek Responses output items for
/// stateless multi-turn requests. Response items are validated separately so
/// arbitrary JSON can never be replayed as a top-level API input item.
public indirect enum GatewayJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([GatewayJSONValue])
    case object([String: GatewayJSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let decoded = try? value.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? value.decode(Int64.self) {
            self = .integer(decoded)
        } else if let decoded = try? value.decode(Double.self), decoded.isFinite {
            self = .number(decoded)
        } else if let decoded = try? value.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? value.decode([GatewayJSONValue].self) {
            self = .array(decoded)
        } else if let decoded = try? value.decode([String: GatewayJSONValue].self) {
            self = .object(decoded)
        } else {
            throw DecodingError.dataCorruptedError(
                in: value,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null:
            try value.encodeNil()
        case .bool(let decoded):
            try value.encode(decoded)
        case .integer(let decoded):
            try value.encode(decoded)
        case .number(let decoded):
            guard decoded.isFinite else {
                throw EncodingError.invalidValue(
                    decoded,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON numbers must be finite"
                    )
                )
            }
            try value.encode(decoded)
        case .string(let decoded):
            try value.encode(decoded)
        case .array(let decoded):
            try value.encode(decoded)
        case .object(let decoded):
            try value.encode(decoded)
        }
    }

    fileprivate func validate(depth: Int = 0) throws -> Int {
        guard depth <= 16 else { throw GatewayProtocolError.invalidResponseItems }
        switch self {
        case .null, .bool, .integer, .number:
            return 1
        case .string(let value):
            guard value.utf8.count <= GatewayRequestPolicy.maximumResponseItemBytes else {
                throw GatewayProtocolError.responseItemsTooLong
            }
            return 1
        case .array(let values):
            var nodes = 1
            for value in values {
                nodes += try value.validate(depth: depth + 1)
                guard nodes <= 4_096 else {
                    throw GatewayProtocolError.invalidResponseItems
                }
            }
            return nodes
        case .object(let values):
            var nodes = 1
            for (key, value) in values {
                guard key.utf8.count <= 1_024 else {
                    throw GatewayProtocolError.invalidResponseItems
                }
                nodes += try value.validate(depth: depth + 1)
                guard nodes <= 4_096 else {
                    throw GatewayProtocolError.invalidResponseItems
                }
            }
            return nodes
        }
    }
}

public struct GatewayResponseItem: Codable, Equatable, Sendable {
    public let rawValue: GatewayJSONValue

    var type: String {
        guard case .object(let object) = rawValue,
              case .string(let type)? = object["type"] else {
            return ""
        }
        return type
    }

    public init(rawValue: GatewayJSONValue) throws {
        guard case .object(let object) = rawValue,
              case .string(let type)? = object["type"],
              ["reasoning", "message", "web_search_call"].contains(type) else {
            throw GatewayProtocolError.invalidResponseItems
        }
        if type == "message" {
            guard case .string("assistant")? = object["role"] else {
                throw GatewayProtocolError.invalidResponseItems
            }
        }
        _ = try rawValue.validate()
        let bytes = try JSONEncoder().encode(rawValue).count
        guard bytes <= GatewayRequestPolicy.maximumResponseItemBytes else {
            throw GatewayProtocolError.responseItemsTooLong
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        do {
            try self.init(rawValue: GatewayJSONValue(from: decoder))
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid or oversized DeepSeek response item",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

enum GatewayResponseItemsPolicy {
    static func validated(_ items: [GatewayResponseItem]) throws -> [GatewayResponseItem] {
        guard !items.isEmpty,
              items.count <= GatewayRequestPolicy.maximumResponseItemsPerMessage,
              items.contains(where: { $0.type == "message" }) else {
            throw GatewayProtocolError.invalidResponseItems
        }
        guard try byteCount(of: items)
            <= GatewayRequestPolicy.maximumResponseItemsBytesPerMessage else {
            throw GatewayProtocolError.responseItemsTooLong
        }
        return items
    }

    static func byteCount(of items: [GatewayResponseItem]) throws -> Int {
        try JSONEncoder().encode(items).count
    }
}

public struct GatewayChatMessage: Codable, Equatable, Sendable {
    public let role: GatewayChatRole
    public let content: String
    public let responseItems: [GatewayResponseItem]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case responseItems = "response_items"
    }

    public init(
        role: GatewayChatRole,
        content: String,
        responseItems: [GatewayResponseItem]? = nil
    ) throws {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GatewayProtocolError.emptyConversationMessage }
        guard normalized.count <= GatewayRequestPolicy.maximumConversationMessageCharacters else {
            throw GatewayProtocolError.conversationMessageTooLong
        }
        guard normalized.utf8.count <= GatewayRequestPolicy.maximumConversationMessageBytes else {
            throw GatewayProtocolError.conversationMessageTooLong
        }
        if responseItems != nil, role != .assistant {
            throw GatewayProtocolError.invalidResponseItems
        }
        self.role = role
        self.content = normalized
        self.responseItems = try responseItems.map(GatewayResponseItemsPolicy.validated)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            role: values.decode(GatewayChatRole.self, forKey: .role),
            content: values.decode(String.self, forKey: .content),
            responseItems: values.decodeIfPresent(
                [GatewayResponseItem].self,
                forKey: .responseItems
            )
        )
    }
}

public struct GatewayAskRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let question: String
    public let mode: GatewayAskMode
    public let webSearch: Bool
    public let deepThinking: Bool
    public let history: [GatewayChatMessage]
    public let page: GatewayPageContext?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case question
        case mode
        case webSearch = "web_search"
        case deepThinking = "deep_thinking"
        case history
        case page
    }

    public init(
        requestID: String = UUID().uuidString.lowercased(),
        question: String,
        mode: GatewayAskMode = .answer,
        webSearch: Bool,
        deepThinking: Bool = false,
        history: [GatewayChatMessage] = [],
        page: GatewayPageContext? = nil
    ) throws {
        let normalizedRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: normalizedRequestID) != nil else {
            throw GatewayProtocolError.invalidRequestID
        }
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GatewayProtocolError.emptyQuestion }
        guard normalized.count <= GatewayRequestPolicy.maximumQuestionCharacters else {
            throw GatewayProtocolError.questionTooLong(
                maximum: GatewayRequestPolicy.maximumQuestionCharacters
            )
        }
        guard normalized.utf8.count <= GatewayRequestPolicy.maximumQuestionBytes else {
            throw GatewayProtocolError.questionTooLong(
                maximum: GatewayRequestPolicy.maximumQuestionCharacters
            )
        }
        if mode == .summarize, page == nil {
            throw GatewayProtocolError.pageRequired
        }
        guard history.count <= GatewayRequestPolicy.maximumConversationMessages else {
            throw GatewayProtocolError.conversationTooLong
        }
        guard history.count.isMultiple(of: 2),
              history.enumerated().allSatisfy({ index, message in
                  message.role == (index.isMultiple(of: 2) ? .user : .assistant)
              }) else {
            throw GatewayProtocolError.invalidConversationSequence
        }
        let historyCharacters = history.reduce(0) { $0 + $1.content.count }
        guard historyCharacters <= GatewayRequestPolicy.maximumConversationCharacters else {
            throw GatewayProtocolError.conversationTooLong
        }
        let historyBytes = history.reduce(0) { $0 + $1.content.utf8.count }
        guard historyBytes <= GatewayRequestPolicy.maximumConversationBytes else {
            throw GatewayProtocolError.conversationTooLong
        }
        let responseItemsBytes = try history.reduce(into: 0) { total, message in
            if let items = message.responseItems {
                total += try GatewayResponseItemsPolicy.byteCount(of: items)
            }
        }
        guard responseItemsBytes
            <= GatewayRequestPolicy.maximumConversationResponseItemsBytes else {
            throw GatewayProtocolError.conversationTooLong
        }

        self.requestID = normalizedRequestID.lowercased()
        self.question = normalized
        self.mode = mode
        self.webSearch = webSearch
        self.deepThinking = deepThinking
        self.history = history
        self.page = page
    }
}

public struct GatewayCitation: Codable, Equatable, Sendable, Identifiable {
    public let title: String
    public let url: String

    public var id: String { url }

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public enum GatewayWebSearchProvider: Codable, Equatable, Sendable {
    case cloudflare
    case wikimedia
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "cloudflare":
            self = .cloudflare
        case "wikimedia":
            self = .wikimedia
        default:
            self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .cloudflare:
            try container.encode("cloudflare")
        case .wikimedia:
            try container.encode("wikimedia")
        case .other(let value):
            try container.encode(value)
        }
    }
}

public struct GatewayAskResponse: Codable, Equatable, Sendable {
    public let answer: String
    public let reasoning: String?
    public let citations: [GatewayCitation]
    public let model: String
    public let webSearchUsed: Bool
    public let webSearchProvider: GatewayWebSearchProvider?
    public let pageContextUsed: Bool
    public let truncated: Bool?
    public let responseItems: [GatewayResponseItem]?

    enum CodingKeys: String, CodingKey {
        case answer
        case reasoning
        case citations
        case model
        case webSearchUsed = "web_search_used"
        case webSearchProvider = "web_search_provider"
        case pageContextUsed = "page_context_used"
        case truncated
        case responseItems = "response_items"
    }

    public init(
        answer: String,
        reasoning: String? = nil,
        citations: [GatewayCitation],
        model: String,
        webSearchUsed: Bool,
        webSearchProvider: GatewayWebSearchProvider?,
        pageContextUsed: Bool,
        truncated: Bool?,
        responseItems: [GatewayResponseItem]? = nil
    ) {
        self.answer = answer
        self.reasoning = reasoning
        self.citations = citations
        self.model = model
        self.webSearchUsed = webSearchUsed
        self.webSearchProvider = webSearchProvider
        self.pageContextUsed = pageContextUsed
        self.truncated = truncated
        self.responseItems = responseItems.flatMap {
            try? GatewayResponseItemsPolicy.validated($0)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            answer: try values.decode(String.self, forKey: .answer),
            reasoning: try values.decodeIfPresent(String.self, forKey: .reasoning),
            citations: try values.decode([GatewayCitation].self, forKey: .citations),
            model: try values.decode(String.self, forKey: .model),
            webSearchUsed: try values.decode(Bool.self, forKey: .webSearchUsed),
            webSearchProvider: try values.decodeIfPresent(
                GatewayWebSearchProvider.self,
                forKey: .webSearchProvider
            ),
            pageContextUsed: try values.decode(Bool.self, forKey: .pageContextUsed),
            truncated: try values.decodeIfPresent(Bool.self, forKey: .truncated),
            responseItems: try values.decodeIfPresent(
                [GatewayResponseItem].self,
                forKey: .responseItems
            )
        )
    }

    public func validatedAnswer() throws -> String {
        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GatewayProtocolError.emptyAnswer }
        return normalized
    }
}

public struct GatewayAskStreamMetadata: Codable, Equatable, Sendable {
    public let citations: [GatewayCitation]
    public let model: String
    public let webSearchUsed: Bool
    public let webSearchProvider: GatewayWebSearchProvider?
    public let pageContextUsed: Bool
    public let responseItems: [GatewayResponseItem]?

    enum CodingKeys: String, CodingKey {
        case citations
        case model
        case webSearchUsed = "web_search_used"
        case webSearchProvider = "web_search_provider"
        case pageContextUsed = "page_context_used"
        case responseItems = "response_items"
    }

    public init(
        citations: [GatewayCitation],
        model: String,
        webSearchUsed: Bool,
        webSearchProvider: GatewayWebSearchProvider?,
        pageContextUsed: Bool,
        responseItems: [GatewayResponseItem]? = nil
    ) {
        self.citations = citations
        self.model = model
        self.webSearchUsed = webSearchUsed
        self.webSearchProvider = webSearchProvider
        self.pageContextUsed = pageContextUsed
        self.responseItems = responseItems.flatMap {
            try? GatewayResponseItemsPolicy.validated($0)
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            citations: try values.decode([GatewayCitation].self, forKey: .citations),
            model: try values.decode(String.self, forKey: .model),
            webSearchUsed: try values.decode(Bool.self, forKey: .webSearchUsed),
            webSearchProvider: try values.decodeIfPresent(
                GatewayWebSearchProvider.self,
                forKey: .webSearchProvider
            ),
            pageContextUsed: try values.decode(Bool.self, forKey: .pageContextUsed),
            responseItems: try values.decodeIfPresent(
                [GatewayResponseItem].self,
                forKey: .responseItems
            )
        )
    }
}

public enum GatewayAskStreamEvent: Equatable, Sendable {
    case metadata(GatewayAskStreamMetadata)
    case reasoningDelta(String)
    case delta(String)
    case done(answer: String, reasoning: String?, truncated: Bool)
    case failure(GatewayErrorResponse)
}

extension GatewayAskStreamEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case answer
        case reasoning
        case truncated
        case citations
        case model
        case webSearchUsed = "web_search_used"
        case webSearchProvider = "web_search_provider"
        case pageContextUsed = "page_context_used"
        case responseItems = "response_items"
        case code
        case message
        case retryable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "metadata":
            self = .metadata(
                GatewayAskStreamMetadata(
                    citations: try values.decode([GatewayCitation].self, forKey: .citations),
                    model: try values.decode(String.self, forKey: .model),
                    webSearchUsed: try values.decode(Bool.self, forKey: .webSearchUsed),
                    webSearchProvider: try values.decodeIfPresent(
                        GatewayWebSearchProvider.self,
                        forKey: .webSearchProvider
                    ),
                    pageContextUsed: try values.decode(Bool.self, forKey: .pageContextUsed),
                    responseItems: try values.decodeIfPresent(
                        [GatewayResponseItem].self,
                        forKey: .responseItems
                    )
                )
            )
        case "reasoning_delta":
            let text = try values.decode(String.self, forKey: .text)
            guard !text.isEmpty else { throw GatewayProtocolError.invalidStreamEvent }
            self = .reasoningDelta(text)
        case "delta":
            let text = try values.decode(String.self, forKey: .text)
            guard !text.isEmpty else { throw GatewayProtocolError.invalidStreamEvent }
            self = .delta(text)
        case "done":
            self = .done(
                answer: try values.decode(String.self, forKey: .answer),
                reasoning: try values.decodeIfPresent(String.self, forKey: .reasoning),
                truncated: try values.decode(Bool.self, forKey: .truncated)
            )
        case "error":
            self = .failure(
                GatewayErrorResponse(
                    code: try values.decode(String.self, forKey: .code),
                    message: try values.decode(String.self, forKey: .message),
                    retryable: try values.decode(Bool.self, forKey: .retryable)
                )
            )
        default:
            throw GatewayProtocolError.invalidStreamEvent
        }
    }
}

public struct GatewaySSEParser: Sendable {
    private var dataLines: [String] = []

    public init() {}

    public mutating func consume(line: String) throws -> GatewayAskStreamEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let data = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return try JSONDecoder().decode(GatewayAskStreamEvent.self, from: Data(data.utf8))
        }
        guard !line.hasPrefix(":"), line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        dataLines.append(value)
        return nil
    }

    public mutating func finish() throws -> GatewayAskStreamEvent? {
        guard !dataLines.isEmpty else { return nil }
        return try consume(line: "")
    }
}

/// Frames SSE lines from raw URLSession bytes without losing empty separator
/// lines. `URLSession.AsyncBytes.lines` omits those empty lines on Apple
/// platforms, which would otherwise merge adjacent JSON events together.
public struct GatewaySSEByteParser: Sendable {
    private var lineBytes: [UInt8] = []
    private var parser = GatewaySSEParser()
    private let maximumLineBytes: Int

    public init(maximumLineBytes: Int = 64 * 1_024) {
        self.maximumLineBytes = maximumLineBytes
    }

    public mutating func consume(byte: UInt8) throws -> GatewayAskStreamEvent? {
        guard byte == 0x0A else {
            guard lineBytes.count < maximumLineBytes else {
                throw GatewayProtocolError.invalidStreamEvent
            }
            lineBytes.append(byte)
            return nil
        }

        if lineBytes.last == 0x0D {
            lineBytes.removeLast()
        }
        guard let line = String(bytes: lineBytes, encoding: .utf8) else {
            throw GatewayProtocolError.invalidStreamEvent
        }
        lineBytes.removeAll(keepingCapacity: true)
        return try parser.consume(line: line)
    }

    public mutating func finish() throws -> GatewayAskStreamEvent? {
        if !lineBytes.isEmpty {
            if lineBytes.last == 0x0D {
                lineBytes.removeLast()
            }
            guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                throw GatewayProtocolError.invalidStreamEvent
            }
            lineBytes.removeAll(keepingCapacity: true)
            if let event = try parser.consume(line: line) {
                return event
            }
        }
        return try parser.finish()
    }
}

public struct GatewayErrorResponse: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public enum GatewayProtocolError: LocalizedError, Equatable, Sendable {
    case invalidRequestID
    case emptyQuestion
    case questionTooLong(maximum: Int)
    case emptyConversationMessage
    case conversationMessageTooLong
    case conversationTooLong
    case invalidConversationSequence
    case invalidResponseItems
    case responseItemsTooLong
    case pageRequired
    case invalidPageURL
    case emptyPage
    case emptyAnswer
    case invalidStreamEvent

    public var errorDescription: String? {
        switch self {
        case .invalidRequestID:
            return "AI 请求标识无效，请重新发送。"
        case .emptyQuestion:
            return "请输入问题。"
        case .questionTooLong(let maximum):
            return "问题太长，请缩短到 \(maximum) 字以内。"
        case .emptyConversationMessage:
            return "对话记录包含空消息。"
        case .conversationMessageTooLong:
            return "单条对话消息太长，请新建对话后继续。"
        case .conversationTooLong:
            return "当前对话太长，请新建对话后继续。"
        case .invalidConversationSequence:
            return "当前对话记录不完整，请重试或新建对话。"
        case .invalidResponseItems:
            return "AI 对话上下文格式无效，请重新发送。"
        case .responseItemsTooLong:
            return "AI 对话上下文太长，请新建对话后继续。"
        case .pageRequired:
            return "当前没有可用于 AI 的网页内容。"
        case .invalidPageURL:
            return "云端返回了无效的网页地址。"
        case .emptyPage:
            return "云端 reader 没有返回可显示的正文。"
        case .emptyAnswer:
            return "AI 没有返回可显示的答案，请重试。"
        case .invalidStreamEvent:
            return "AI 流式响应格式无效，请重试。"
        }
    }
}
