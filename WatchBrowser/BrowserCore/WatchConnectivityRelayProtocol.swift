import Foundation

/// A versioned, credential-free wire contract for forwarding the app's gateway requests
/// over WatchConnectivity. The iPhone relay is responsible for attaching its own bearer
/// immediately before the upstream request; authorization and cookie headers are never
/// accepted by this protocol.
public enum WatchRelayPolicy {
    public static let currentVersion = 1
    public static let defaultTimeoutMilliseconds = 30_000
    public static let minimumTimeoutMilliseconds = 1_000
    public static let maximumTimeoutMilliseconds = 60_000
    public static let maximumClockSkewMilliseconds = 5_000
    public static let maximumWireBytes = 64 * 1_024
    public static let maximumBodyBytes = 60 * 1_024
    public static let maximumGatewayOriginBytes = 512
    public static let maximumPathBytes = 512
    public static let maximumHeaderCount = 8
    public static let maximumHeaderNameBytes = 64
    public static let maximumHeaderValueBytes = 512
    public static let maximumErrorMessageBytes = 512

    public static func millisecondsSince1970(for date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

/// Separates failures known to happen before dispatch from failures where the iPhone
/// may already have performed the upstream operation. Only explicitly replay-safe
/// routes may fall back to a direct watch request after an uncertain outcome.
public enum WatchRelayFallbackPhase: Equatable, Sendable {
    case preDispatchUnavailable
    case outcomeUncertain
    case definitiveFailure
}

public enum WatchRelayDirectFallbackPolicy {
    public static func failurePhase(
        forRemoteErrorCode code: WatchRelayErrorCode
    ) -> WatchRelayFallbackPhase {
        switch code {
        case .transportUnavailable:
            return .preDispatchUnavailable
        case .notReachable,
             .timedOut,
             .cancelled,
             .upstreamNetwork,
             .responseTooLarge:
            return .outcomeUncertain
        default:
            return .definitiveFailure
        }
    }

    public static func shouldUseDirectNetwork(
        after phase: WatchRelayFallbackPhase,
        for request: URLRequest
    ) -> Bool {
        if let url = request.url,
           PhoneLocalBrowserRoute.requiresReachablePhone(
               method: request.httpMethod ?? "GET",
               path: url.path
           ) {
            return false
        }
        switch phase {
        case .preDispatchUnavailable:
            return true
        case .outcomeUncertain:
            return isReplaySafe(request)
        case .definitiveFailure:
            return false
        }
    }

    public static func isReplaySafe(_ request: URLRequest) -> Bool {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else {
            return false
        }
        return isReplaySafe(
            method: (request.httpMethod ?? "GET").uppercased(),
            path: components.path
        )
    }

    public static func isReplaySafe(method: String, path: String) -> Bool {
        switch (method.uppercased(), path) {
        case ("GET", "/health"),
             ("POST", "/v1/read"),
             ("POST", "/v1/ask"):
            return true
        default:
            break
        }

        guard method.uppercased() == "DELETE" else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.count == 4
            && segments[0].isEmpty
            && segments[1] == "v1"
            && segments[2] == "sessions"
            && isSafeSessionID(segments[3])
    }

    private static func isSafeSessionID(_ segment: Substring) -> Bool {
        guard !segment.isEmpty, segment.utf8.count <= 128 else { return false }
        return segment.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
        }
    }
}

public enum WatchRelayTimingPolicy {
    // Browser navigation may legitimately spend 20 seconds loading, then a few
    // seconds settling and up to 8 seconds capturing/compressing a frame. Leave
    // headroom for WatchConnectivity while remaining below the 60-second wire cap.
    public static let browserMaximumRelayTimeout: TimeInterval = 40

    public static func relayTimeout(for request: URLRequest) -> TimeInterval {
        let path = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path
        } ?? ""
        return relayTimeout(
            requestTimeout: request.timeoutInterval,
            path: path
        )
    }

    public static func relayTimeout(
        requestTimeout: TimeInterval,
        path: String
    ) -> TimeInterval {
        let routeLimit: TimeInterval
        switch path {
        case "/v1/read", "/v1/ask":
            routeLimit = TimeInterval(WatchRelayPolicy.maximumTimeoutMilliseconds) / 1_000
        default:
            routeLimit = browserMaximumRelayTimeout
        }
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            return routeLimit
        }
        return min(max(requestTimeout, 1), routeLimit)
    }

    public static func remainingDirectTimeout(
        originalTimeout: TimeInterval,
        elapsed: TimeInterval
    ) -> TimeInterval? {
        guard originalTimeout.isFinite,
              elapsed.isFinite,
              originalTimeout > 0,
              elapsed >= 0 else {
            return nil
        }
        let remaining = originalTimeout - elapsed
        return remaining > 0 ? remaining : nil
    }
}

public enum WatchRelayHTTPMethod: String, Codable, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

/// Stable error codes that either peer may return without exposing transport or
/// upstream implementation details.
public enum WatchRelayErrorCode: String, Codable, Equatable, Sendable {
    case malformedMessage = "malformed_message"
    case unsupportedVersion = "unsupported_version"
    case requestRejected = "request_rejected"
    case requestExpired = "request_expired"
    case requestTooLarge = "request_too_large"
    case responseTooLarge = "response_too_large"
    case transportUnavailable = "transport_unavailable"
    case notReachable = "not_reachable"
    case timedOut = "timed_out"
    case cancelled
    case upstreamNetwork = "upstream_network"
    case upstreamInvalidResponse = "upstream_invalid_response"
    case internalError = "internal_error"
}

public enum WatchRelayProtocolError: LocalizedError, Equatable, Sendable {
    case malformedMessage
    case unsupportedVersion(Int)
    case messageTooLarge(maximum: Int)
    case responseTooLarge(maximum: Int)
    case invalidTimestamp
    case invalidTimeout(minimum: Int, maximum: Int)
    case requestExpired
    case invalidGatewayOrigin
    case gatewayOriginTooLong(maximum: Int)
    case methodNotAllowed(String)
    case pathNotAllowed(String)
    case tooManyHeaders(maximum: Int)
    case headerNotAllowed(String)
    case duplicateHeader(String)
    case headerNameTooLong(maximum: Int)
    case headerValueTooLong(maximum: Int)
    case invalidHeaderValue(String)
    case invalidContentType
    case bodyRequired
    case bodyNotAllowed
    case bodyTooLarge(maximum: Int)
    case invalidJSONBody
    case invalidStatusCode(Int)
    case invalidErrorMessage

    public var errorCode: WatchRelayErrorCode {
        switch self {
        case .malformedMessage:
            return .malformedMessage
        case .unsupportedVersion:
            return .unsupportedVersion
        case .messageTooLarge, .bodyTooLarge:
            return .requestTooLarge
        case .responseTooLarge:
            return .responseTooLarge
        case .requestExpired:
            return .requestExpired
        case .invalidStatusCode, .invalidErrorMessage:
            return .upstreamInvalidResponse
        default:
            return .requestRejected
        }
    }

    public var errorDescription: String? {
        switch self {
        case .malformedMessage:
            return "中继消息格式无效。"
        case .unsupportedVersion(let version):
            return "不支持中继协议版本 \(version)。"
        case .messageTooLarge(let maximum):
            return "中继消息超过 \(maximum) 字节上限。"
        case .responseTooLarge(let maximum):
            return "中继响应超过 \(maximum) 字节上限。"
        case .invalidTimestamp:
            return "中继请求时间无效。"
        case .invalidTimeout(let minimum, let maximum):
            return "中继超时必须在 \(minimum)...\(maximum) 毫秒之间。"
        case .requestExpired:
            return "中继请求已超时。"
        case .invalidGatewayOrigin:
            return "中继网关来源必须是安全的 HTTPS origin。"
        case .gatewayOriginTooLong(let maximum):
            return "中继网关来源超过 \(maximum) 字节。"
        case .methodNotAllowed(let method):
            return "中继不允许 HTTP 方法 \(method)。"
        case .pathNotAllowed:
            return "中继不允许该网关路径。"
        case .tooManyHeaders(let maximum):
            return "中继请求头不能超过 \(maximum) 个。"
        case .headerNotAllowed(let name):
            return "中继不允许请求头 \(name)。"
        case .duplicateHeader(let name):
            return "中继请求头 \(name) 重复。"
        case .headerNameTooLong(let maximum):
            return "中继请求头名称超过 \(maximum) 字节。"
        case .headerValueTooLong(let maximum):
            return "中继请求头值超过 \(maximum) 字节。"
        case .invalidHeaderValue:
            return "中继请求头值包含不安全字符。"
        case .invalidContentType:
            return "中继 JSON 请求必须使用 application/json。"
        case .bodyRequired:
            return "该中继请求必须包含 JSON 正文。"
        case .bodyNotAllowed:
            return "该中继请求不能包含正文。"
        case .bodyTooLarge(let maximum):
            return "中继正文超过 \(maximum) 字节上限。"
        case .invalidJSONBody:
            return "中继正文必须是 JSON 对象。"
        case .invalidStatusCode(let statusCode):
            return "中继返回了无效 HTTP 状态码 \(statusCode)。"
        case .invalidErrorMessage:
            return "中继错误消息无效。"
        }
    }
}

public struct WatchRelayRequest: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let createdAtMillisecondsSince1970: Int64
    public let timeoutMilliseconds: Int
    public let gatewayOrigin: String
    public let method: WatchRelayHTTPMethod
    public let path: String
    public let headers: [String: String]
    public let body: Data?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAtMillisecondsSince1970 = "created_at_ms"
        case timeoutMilliseconds = "timeout_ms"
        case gatewayOrigin = "gateway_origin"
        case method
        case path
        case headers
        case body
    }

    public init(
        id: UUID = UUID(),
        createdAtMillisecondsSince1970: Int64 = WatchRelayPolicy.millisecondsSince1970(),
        timeoutMilliseconds: Int = WatchRelayPolicy.defaultTimeoutMilliseconds,
        gatewayOrigin: String,
        method: WatchRelayHTTPMethod,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws {
        guard createdAtMillisecondsSince1970 > 0,
              createdAtMillisecondsSince1970
                <= Int64.max - Int64(WatchRelayPolicy.maximumTimeoutMilliseconds) else {
            throw WatchRelayProtocolError.invalidTimestamp
        }
        guard timeoutMilliseconds >= WatchRelayPolicy.minimumTimeoutMilliseconds,
              timeoutMilliseconds <= WatchRelayPolicy.maximumTimeoutMilliseconds else {
            throw WatchRelayProtocolError.invalidTimeout(
                minimum: WatchRelayPolicy.minimumTimeoutMilliseconds,
                maximum: WatchRelayPolicy.maximumTimeoutMilliseconds
            )
        }

        let safeGatewayOrigin = try WatchRelayValidation.normalizedGatewayOrigin(gatewayOrigin)
        try WatchRelayValidation.validate(method: method, path: path)
        var safeHeaders = try WatchRelayValidation.headers(headers, direction: .request)
        if safeHeaders["accept"] == nil {
            safeHeaders["accept"] = "application/json"
        }

        switch method {
        case .post:
            guard let body, !body.isEmpty else {
                throw WatchRelayProtocolError.bodyRequired
            }
            try WatchRelayValidation.validateJSONBody(body)
            if let contentType = safeHeaders["content-type"] {
                let mediaType = contentType
                    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard mediaType == "application/json" else {
                    throw WatchRelayProtocolError.invalidContentType
                }
            } else {
                safeHeaders["content-type"] = "application/json"
            }
        case .get, .delete:
            guard body == nil || body?.isEmpty == true else {
                throw WatchRelayProtocolError.bodyNotAllowed
            }
        }

        self.id = id
        self.createdAtMillisecondsSince1970 = createdAtMillisecondsSince1970
        self.timeoutMilliseconds = timeoutMilliseconds
        self.gatewayOrigin = safeGatewayOrigin
        self.method = method
        self.path = path
        self.headers = safeHeaders
        self.body = body?.isEmpty == true ? nil : body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let methodValue = try container.decode(String.self, forKey: .method)
        guard let method = WatchRelayHTTPMethod(rawValue: methodValue) else {
            throw WatchRelayProtocolError.methodNotAllowed(methodValue)
        }
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            createdAtMillisecondsSince1970: container.decode(
                Int64.self,
                forKey: .createdAtMillisecondsSince1970
            ),
            timeoutMilliseconds: container.decode(Int.self, forKey: .timeoutMilliseconds),
            gatewayOrigin: container.decode(String.self, forKey: .gatewayOrigin),
            method: method,
            path: container.decode(String.self, forKey: .path),
            headers: container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
            body: container.decodeIfPresent(Data.self, forKey: .body)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAtMillisecondsSince1970, forKey: .createdAtMillisecondsSince1970)
        try container.encode(timeoutMilliseconds, forKey: .timeoutMilliseconds)
        try container.encode(gatewayOrigin, forKey: .gatewayOrigin)
        try container.encode(method.rawValue, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encode(headers, forKey: .headers)
        try container.encodeIfPresent(body, forKey: .body)
    }

    public var deadlineMillisecondsSince1970: Int64 {
        createdAtMillisecondsSince1970 + Int64(timeoutMilliseconds)
    }

    public func isExpired(atMillisecondsSince1970 now: Int64) -> Bool {
        now >= deadlineMillisecondsSince1970
    }

    /// Validates only the time-dependent part of an otherwise fully constructed request.
    /// Receivers that decode without freshness validation must call this before dispatch.
    public func validateFreshness(atMillisecondsSince1970 now: Int64) throws {
        guard now > 0,
              now <= Int64.max - Int64(WatchRelayPolicy.maximumClockSkewMilliseconds),
              createdAtMillisecondsSince1970
                <= now + Int64(WatchRelayPolicy.maximumClockSkewMilliseconds) else {
            throw WatchRelayProtocolError.invalidTimestamp
        }
        if isExpired(atMillisecondsSince1970: now) {
            throw WatchRelayProtocolError.requestExpired
        }
    }

    public func remainingTimeoutMilliseconds(atMillisecondsSince1970 now: Int64) -> Int {
        let remaining = max(0, deadlineMillisecondsSince1970 - now)
        return Int(min(Int64(timeoutMilliseconds), remaining))
    }

    /// Deliberately omits header values and body bytes so routine diagnostics cannot
    /// become a credential or content log.
    public var description: String {
        "WatchRelayRequest(id: \(id.uuidString), method: \(method.rawValue), "
            + "gatewayOrigin: \(gatewayOrigin), path: \(path), "
            + "headerNames: \(headers.keys.sorted()), "
            + "bodyBytes: \(body?.count ?? 0), timeoutMilliseconds: \(timeoutMilliseconds))"
    }

    public var debugDescription: String { description }
}

public struct WatchRelayHTTPResponse: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case headers
        case body
    }

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws {
        guard (100...599).contains(statusCode) else {
            throw WatchRelayProtocolError.invalidStatusCode(statusCode)
        }
        if let body, !body.isEmpty {
            guard body.count <= WatchRelayPolicy.maximumBodyBytes else {
                throw WatchRelayProtocolError.responseTooLarge(
                    maximum: WatchRelayPolicy.maximumBodyBytes
                )
            }
        }

        self.statusCode = statusCode
        self.headers = try WatchRelayValidation.headers(headers, direction: .response)
        self.body = body?.isEmpty == true ? nil : body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            statusCode: container.decode(Int.self, forKey: .statusCode),
            headers: container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
            body: container.decodeIfPresent(Data.self, forKey: .body)
        )
    }

    public var description: String {
        "WatchRelayHTTPResponse(statusCode: \(statusCode), "
            + "headerNames: \(headers.keys.sorted()), bodyBytes: \(body?.count ?? 0))"
    }

    public var debugDescription: String { description }
}

public struct WatchRelayFailure: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let code: WatchRelayErrorCode
    public let message: String
    public let retryable: Bool

    public init(code: WatchRelayErrorCode, message: String, retryable: Bool) throws {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= WatchRelayPolicy.maximumErrorMessageBytes,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw WatchRelayProtocolError.invalidErrorMessage
        }
        self.code = code
        self.message = normalized
        self.retryable = retryable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            code: container.decode(WatchRelayErrorCode.self, forKey: .code),
            message: container.decode(String.self, forKey: .message),
            retryable: container.decode(Bool.self, forKey: .retryable)
        )
    }

    public var description: String {
        "WatchRelayFailure(code: \(code.rawValue), retryable: \(retryable))"
    }

    public var debugDescription: String { description }
}

public enum WatchRelayResponsePayload: Codable, Equatable, Sendable {
    case http(WatchRelayHTTPResponse)
    case failure(WatchRelayFailure)

    private enum CodingKeys: String, CodingKey {
        case kind
        case http
        case failure
    }

    private enum Kind: String, Codable {
        case http
        case failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .http:
            self = .http(try container.decode(WatchRelayHTTPResponse.self, forKey: .http))
        case .failure:
            self = .failure(try container.decode(WatchRelayFailure.self, forKey: .failure))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .http(let response):
            try container.encode(Kind.http, forKey: .kind)
            try container.encode(response, forKey: .http)
        case .failure(let failure):
            try container.encode(Kind.failure, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        }
    }
}

public struct WatchRelayResponse: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let requestID: UUID
    public let payload: WatchRelayResponsePayload

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case payload
    }

    public init(requestID: UUID, payload: WatchRelayResponsePayload) {
        self.requestID = requestID
        self.payload = payload
    }

    public func matches(_ request: WatchRelayRequest) -> Bool {
        requestID == request.id
    }

    public var description: String {
        switch payload {
        case .http(let response):
            return "WatchRelayResponse(requestID: \(requestID.uuidString), \(response))"
        case .failure(let failure):
            return "WatchRelayResponse(requestID: \(requestID.uuidString), \(failure))"
        }
    }

    public var debugDescription: String { description }
}

public enum WatchRelayMessage: Codable, Equatable, Sendable {
    case request(WatchRelayRequest)
    case response(WatchRelayResponse)

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case request
        case response
    }

    private enum Kind: String, Codable {
        case request
        case response
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == WatchRelayPolicy.currentVersion else {
            throw WatchRelayProtocolError.unsupportedVersion(version)
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .request:
            self = .request(try container.decode(WatchRelayRequest.self, forKey: .request))
        case .response:
            self = .response(try container.decode(WatchRelayResponse.self, forKey: .response))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WatchRelayPolicy.currentVersion, forKey: .version)
        switch self {
        case .request(let request):
            try container.encode(Kind.request, forKey: .kind)
            try container.encode(request, forKey: .request)
        case .response(let response):
            try container.encode(Kind.response, forKey: .kind)
            try container.encode(response, forKey: .response)
        }
    }
}

public enum WatchRelayCodec {
    public static func encode(_ message: WatchRelayMessage) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch let error as WatchRelayProtocolError {
            throw error
        } catch {
            throw WatchRelayProtocolError.malformedMessage
        }
        guard data.count <= WatchRelayPolicy.maximumWireBytes else {
            switch message {
            case .request:
                throw WatchRelayProtocolError.messageTooLarge(
                    maximum: WatchRelayPolicy.maximumWireBytes
                )
            case .response:
                throw WatchRelayProtocolError.responseTooLarge(
                    maximum: WatchRelayPolicy.maximumWireBytes
                )
            }
        }
        return data
    }

    public static func decode(
        _ data: Data,
        nowMillisecondsSince1970: Int64 = WatchRelayPolicy.millisecondsSince1970()
    ) throws -> WatchRelayMessage {
        let message = try decodeWithoutFreshnessValidation(data)
        if case .request(let request) = message {
            try request.validateFreshness(
                atMillisecondsSince1970: nowMillisecondsSince1970
            )
        }
        return message
    }

    /// Performs all wire, version, route, origin, header and body validation while
    /// deliberately deferring only the clock-dependent check. A receiver using this
    /// entry point must call `WatchRelayRequest.validateFreshness` before dispatch.
    public static func decodeWithoutFreshnessValidation(
        _ data: Data
    ) throws -> WatchRelayMessage {
        guard !data.isEmpty else {
            throw WatchRelayProtocolError.malformedMessage
        }
        guard data.count <= WatchRelayPolicy.maximumWireBytes else {
            throw WatchRelayProtocolError.messageTooLarge(
                maximum: WatchRelayPolicy.maximumWireBytes
            )
        }

        let message: WatchRelayMessage
        do {
            message = try PropertyListDecoder().decode(WatchRelayMessage.self, from: data)
        } catch let error as WatchRelayProtocolError {
            throw error
        } catch {
            throw WatchRelayProtocolError.malformedMessage
        }

        return message
    }
}

private enum WatchRelayHeaderDirection {
    case request
    case response
}

private enum WatchRelayValidation {
    private static let allowedRequestHeaders: Set<String> = [
        "accept",
        "accept-language",
        "content-type"
    ]
    private static let allowedResponseHeaders: Set<String> = [
        "content-language",
        "content-type",
        "retry-after"
    ]
    private static let browserActions: Set<String> = [
        "back",
        "fill",
        "refresh",
        "scroll",
        "tap"
    ]

    static func normalizedGatewayOrigin(_ source: String) throws -> String {
        guard source.utf8.count <= WatchRelayPolicy.maximumGatewayOriginBytes else {
            throw WatchRelayProtocolError.gatewayOriginTooLong(
                maximum: WatchRelayPolicy.maximumGatewayOriginBytes
            )
        }
        guard !source.isEmpty,
              source == source.trimmingCharacters(in: .whitespacesAndNewlines),
              source.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar)
                      && !CharacterSet.controlCharacters.contains(scalar)
              }),
              var components = URLComponents(string: source),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.percentEncodedPath.isEmpty,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else {
            throw WatchRelayProtocolError.invalidGatewayOrigin
        }

        if let port = components.port, !(1...65_535).contains(port) {
            throw WatchRelayProtocolError.invalidGatewayOrigin
        }

        components.scheme = "https"
        components.host = host.lowercased()
        components.port = components.port == 443 ? nil : components.port
        guard let normalized = components.url?.absoluteString,
              !normalized.isEmpty,
              normalized.utf8.count <= WatchRelayPolicy.maximumGatewayOriginBytes else {
            throw WatchRelayProtocolError.invalidGatewayOrigin
        }
        return normalized
    }

    static func validate(method: WatchRelayHTTPMethod, path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= WatchRelayPolicy.maximumPathBytes,
              path.first == "/",
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("\\"),
              !path.contains("%"),
              path.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw WatchRelayProtocolError.pathNotAllowed(path)
        }

        switch (method, path) {
        case (.get, "/health"),
             (.post, "/v1/read"),
             (.post, "/v1/ask"),
             (.post, "/v1/sessions/open"):
            return
        default:
            break
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if method == .post,
           segments.count == 5,
           segments[0].isEmpty,
           segments[1] == "v1",
           segments[2] == "sessions",
           isSafeSessionID(segments[3]),
           browserActions.contains(String(segments[4])) {
            return
        }
        if method == .delete,
           segments.count == 4,
           segments[0].isEmpty,
           segments[1] == "v1",
           segments[2] == "sessions",
           isSafeSessionID(segments[3]) {
            return
        }
        throw WatchRelayProtocolError.pathNotAllowed(path)
    }

    static func headers(
        _ source: [String: String],
        direction: WatchRelayHeaderDirection
    ) throws -> [String: String] {
        guard source.count <= WatchRelayPolicy.maximumHeaderCount else {
            throw WatchRelayProtocolError.tooManyHeaders(
                maximum: WatchRelayPolicy.maximumHeaderCount
            )
        }
        let allowlist = direction == .request ? allowedRequestHeaders : allowedResponseHeaders
        var result: [String: String] = [:]
        for (rawName, rawValue) in source {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, name.utf8.count <= WatchRelayPolicy.maximumHeaderNameBytes else {
                throw WatchRelayProtocolError.headerNameTooLong(
                    maximum: WatchRelayPolicy.maximumHeaderNameBytes
                )
            }
            guard allowlist.contains(name) else {
                throw WatchRelayProtocolError.headerNotAllowed(name)
            }
            guard result[name] == nil else {
                throw WatchRelayProtocolError.duplicateHeader(name)
            }
            guard rawValue.utf8.count <= WatchRelayPolicy.maximumHeaderValueBytes else {
                throw WatchRelayProtocolError.headerValueTooLong(
                    maximum: WatchRelayPolicy.maximumHeaderValueBytes
                )
            }
            guard rawValue.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }) else {
                throw WatchRelayProtocolError.invalidHeaderValue(name)
            }
            result[name] = rawValue.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func validateJSONBody(_ body: Data) throws {
        try validateBodySize(body)
        guard let object = try? JSONSerialization.jsonObject(with: body),
              object is [String: Any] else {
            throw WatchRelayProtocolError.invalidJSONBody
        }
    }

    static func validateBodySize(_ body: Data) throws {
        guard body.count <= WatchRelayPolicy.maximumBodyBytes else {
            throw WatchRelayProtocolError.bodyTooLarge(
                maximum: WatchRelayPolicy.maximumBodyBytes
            )
        }
    }

    private static func isSafeSessionID(_ segment: Substring) -> Bool {
        guard !segment.isEmpty, segment.utf8.count <= 128 else { return false }
        return segment.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
        }
    }
}
