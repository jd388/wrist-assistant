import Foundation

enum GatewayOriginNormalizer {
    static func normalize(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard candidate.utf8.count <= WatchRelayPolicy.maximumGatewayOriginBytes,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar)
                      && !CharacterSet.controlCharacters.contains(scalar)
              }),
              let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else {
            return nil
        }
        return origin(from: components)
    }

    static func origin(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return origin(from: components)
    }

    private static func origin(from components: URLComponents) -> URL? {
        guard let host = components.host else { return nil }
        if let port = components.port, !(1...65_535).contains(port) {
            return nil
        }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host.lowercased()
        if components.port != 443 {
            normalized.port = components.port
        }
        return normalized.url
    }
}

final class RejectingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destinationURL = request.url else {
            completionHandler(nil)
            return
        }
        let isAllowed = GatewayRedirectPolicy.allowsRedirect(
            from: task.currentRequest?.url,
            to: destinationURL
        )
        completionHandler(isAllowed ? request : nil)
    }
}

struct GatewayConfiguration: Equatable, Sendable {
    let baseURL: URL
    let token: String

    init(serverURL: String, token: String) throws {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw GatewayClientError.serverNotConfigured }

        guard let baseURL = GatewayOriginNormalizer.normalize(trimmedURL) else {
            throw GatewayClientError.invalidServerURL
        }

        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { throw GatewayClientError.tokenNotConfigured }
        self.baseURL = baseURL
        self.token = normalizedToken
    }
}

final class GatewayClient: @unchecked Sendable {
    private struct StreamAccumulator {
        var metadata: GatewayAskStreamMetadata?
        var answer = ""
        var reasoning = ""
        var result: GatewayAskResponse?
        var answerWasCapped = false
        var reasoningWasCapped = false

        mutating func apply(_ event: GatewayAskStreamEvent) throws -> [GatewayAskStreamEvent] {
            switch event {
            case .metadata(let value):
                metadata = value
                return [.metadata(value)]

            case .reasoningDelta(let text):
                let remaining = max(
                    0,
                    DeepSeekRequestPolicy.maximumReasoningCharacters - reasoning.count
                )
                let accepted = String(text.prefix(remaining))
                if accepted.count < text.count { reasoningWasCapped = true }
                reasoning += accepted
                return accepted.isEmpty ? [] : [.reasoningDelta(accepted)]

            case .delta(let text):
                let remaining = max(
                    0,
                    DeepSeekRequestPolicy.maximumAnswerCharacters - answer.count
                )
                let accepted = String(text.prefix(remaining))
                if accepted.count < text.count { answerWasCapped = true }
                answer += accepted
                return accepted.isEmpty ? [] : [.delta(accepted)]

            case .done(let finalAnswer, let finalReasoning, let truncated):
                guard let metadata else { throw GatewayClientError.invalidResponse }
                let normalizedAnswer = finalAnswer
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let streamedAnswer = answer
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let answerSource = normalizedAnswer.isEmpty ? streamedAnswer : normalizedAnswer
                let cappedAnswer = String(
                    answerSource.prefix(DeepSeekRequestPolicy.maximumAnswerCharacters)
                )
                guard !cappedAnswer.isEmpty else { throw GatewayClientError.invalidResponse }

                let normalizedReasoning = finalReasoning?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let streamedReasoning = reasoning
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reasoningSource = (normalizedReasoning?.isEmpty == false)
                    ? (normalizedReasoning ?? "")
                    : streamedReasoning
                let cappedReasoning = String(
                    reasoningSource.prefix(DeepSeekRequestPolicy.maximumReasoningCharacters)
                )
                let reasoningValue = cappedReasoning.isEmpty ? nil : cappedReasoning
                let wasCapped = answerWasCapped
                    || reasoningWasCapped
                    || answerSource.count > cappedAnswer.count
                    || reasoningSource.count > cappedReasoning.count
                let response = GatewayAskResponse(
                    answer: cappedAnswer,
                    reasoning: reasoningValue,
                    citations: metadata.citations,
                    model: metadata.model,
                    webSearchUsed: metadata.webSearchUsed,
                    webSearchProvider: metadata.webSearchProvider,
                    pageContextUsed: metadata.pageContextUsed,
                    truncated: truncated || wasCapped,
                    responseItems: metadata.responseItems
                )
                result = response
                return [
                    .done(
                        answer: response.answer,
                        reasoning: response.reasoning,
                        truncated: response.truncated ?? false
                    )
                ]

            case .failure(let error):
                throw GatewayClientError.stream(error)
            }
        }
    }

    static func askRequestBody(for payload: GatewayAskRequest) throws -> Data {
        let body = try JSONEncoder().encode(payload)
        guard body.count <= GatewayRequestPolicy.maximumAskRequestBytes else {
            throw GatewayClientError.requestTooLarge
        }
        return body
    }

    private let session: URLSession
    private let redirectDelegate: RejectingRedirectDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 150
        configuration.httpMaximumConnectionsPerHost = 2
        let redirectDelegate = RejectingRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func health(serverURL: String, token: String) async throws -> GatewayHealthResponse {
        let configuration = try GatewayConfiguration(serverURL: serverURL, token: token)
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("WatchBrowser/1.0 watchOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetchDirectData(for: request, maximumBytes: 16_384)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(GatewayErrorResponse.self, from: data)
            throw GatewayClientError.http(http.statusCode, serverError)
        }
        guard let health = try? JSONDecoder().decode(GatewayHealthResponse.self, from: data),
              health.isAccepted(httpStatusCode: http.statusCode) else {
            throw GatewayClientError.invalidResponse
        }
        return health
    }

    func read(
        url: URL,
        serverURL: String,
        token: String,
        preferDynamic: Bool = false
    ) async throws -> GatewayReadResponse {
        let payload = GatewayReadRequest(url: url, preferDynamic: preferDynamic)
        return try await post(
            path: ["v1", "read"],
            payload: payload,
            serverURL: serverURL,
            token: token,
            maximumBytes: 350_000,
            directOnly: true
        )
    }

    func ask(
        _ payload: GatewayAskRequest,
        serverURL: String,
        token: String
    ) async throws -> GatewayAskResponse {
        let response: GatewayAskResponse = try await post(
            path: ["v1", "ask"],
            payload: payload,
            serverURL: serverURL,
            token: token,
            maximumBytes: DeepSeekRequestPolicy.maximumResponseBytes,
            directOnly: true,
            maximumRetries: 0
        )
        _ = try response.validatedAnswer()
        return response
    }

    func answerStreaming(
        _ payload: GatewayAskRequest,
        serverURL: String,
        token: String,
        onEvent: @escaping @Sendable (GatewayAskStreamEvent) async -> Void
    ) async throws -> GatewayAskResponse {
        do {
            return try await streamAnswer(
                payload,
                serverURL: serverURL,
                token: token,
                onEvent: onEvent
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GatewayClientError where error.isStreamingEndpointUnavailable {
            // Older free Worker deployments may only expose the JSON endpoint.
            // Keep the feature usable without replaying any other failure.
            let response = try await ask(payload, serverURL: serverURL, token: token)
            await onEvent(
                .metadata(
                    GatewayAskStreamMetadata(
                        citations: response.citations,
                        model: response.model,
                        webSearchUsed: response.webSearchUsed,
                        webSearchProvider: response.webSearchProvider,
                        pageContextUsed: response.pageContextUsed,
                        responseItems: response.responseItems
                    )
                )
            )
            await onEvent(
                .done(
                    answer: response.answer,
                    reasoning: response.reasoning,
                    truncated: response.truncated ?? false
                )
            )
            return response
        }
    }

    private func streamAnswer(
        _ payload: GatewayAskRequest,
        serverURL: String,
        token: String,
        onEvent: @escaping @Sendable (GatewayAskStreamEvent) async -> Void
    ) async throws -> GatewayAskResponse {
        let configuration = try GatewayConfiguration(serverURL: serverURL, token: token)
        let endpoint = configuration.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("ask")
            .appendingPathComponent("stream")
        let body = try Self.askRequestBody(for: payload)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("WatchBrowser/1.0 watchOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            // The Watch talks to the free Worker itself. WatchConnectivity is
            // deliberately not used because it would add an iPhone runtime path
            // and cannot preserve incremental SSE delivery.
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw GatewayClientError.network(error.code)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GatewayClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let data = try await collect(
                bytes,
                maximumBytes: 64 * 1_024
            )
            let serverError = try? JSONDecoder().decode(GatewayErrorResponse.self, from: data)
            throw GatewayClientError.http(http.statusCode, serverError)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true else {
            throw GatewayClientError.invalidResponse
        }

        var parser = GatewaySSEByteParser()
        var accumulator = StreamAccumulator()
        var receivedBytes = 0
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                receivedBytes += 1
                guard receivedBytes <= DeepSeekRequestPolicy.maximumResponseBytes else {
                    throw GatewayClientError.responseTooLarge
                }
                guard let event = try parser.consume(byte: byte) else { continue }
                for acceptedEvent in try accumulator.apply(event) {
                    await onEvent(acceptedEvent)
                }
                if let result = accumulator.result { return result }
            }
            if let event = try parser.finish() {
                for acceptedEvent in try accumulator.apply(event) {
                    await onEvent(acceptedEvent)
                }
            }
            if let result = accumulator.result { return result }
            throw GatewayClientError.invalidResponse
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw GatewayClientError.network(error.code)
        }
    }

    private func collect(
        _ bytes: URLSession.AsyncBytes,
        maximumBytes: Int
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 16_384))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw GatewayClientError.responseTooLarge
            }
            data.append(byte)
        }
        return data
    }

    private func post<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        path: [String],
        payload: Payload,
        serverURL: String,
        token: String,
        maximumBytes: Int,
        directOnly: Bool = false,
        maximumRetries: Int = 1
    ) async throws -> Response {
        let configuration = try GatewayConfiguration(serverURL: serverURL, token: token)
        let endpoint = path.reduce(configuration.baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        let body = try JSONEncoder().encode(payload)
        guard body.count <= GatewayRequestPolicy.maximumAskRequestBytes else {
            throw GatewayClientError.requestTooLarge
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("WatchBrowser/1.0 watchOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        var lastStructuredError: GatewayClientError?
        for attempt in 0...maximumRetries {
            let data: Data
            let response: URLResponse
            do {
                if directOnly {
                    (data, response) = try await fetchDirectData(
                        for: request,
                        maximumBytes: maximumBytes
                    )
                } else {
                    (data, response) = try await fetchData(
                        for: request,
                        maximumBytes: maximumBytes
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled {
                    throw CancellationError()
                }
                throw GatewayClientError.network(error.code)
            }

            guard let http = response as? HTTPURLResponse else {
                throw GatewayClientError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let serverError = try? JSONDecoder().decode(GatewayErrorResponse.self, from: data)
                let structuredError = GatewayClientError.http(http.statusCode, serverError)
                if attempt < maximumRetries && GatewayRetryPolicy.shouldRetry(
                    attempt: attempt,
                    statusCode: http.statusCode,
                    serverMarkedRetryable: serverError?.retryable == true
                ) {
                    lastStructuredError = structuredError
                    try await Task.sleep(for: .seconds(1.2))
                    continue
                }
                throw structuredError
            }

            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw GatewayClientError.invalidResponse
            }
        }

        throw lastStructuredError ?? GatewayClientError.invalidResponse
    }

    private func fetchData(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let deadline = WatchRelayRequestDeadline(request: request)
        do {
            let relayed = try await WatchConnectivityRelayClient.shared.send(
                request,
                maximumResponseBytes: maximumBytes,
                timeout: WatchRelayFallbackPolicy.relayTimeout(for: request)
            )
            guard let requestURL = request.url else {
                throw GatewayClientError.invalidResponse
            }
            return (relayed.body ?? Data(), try relayed.urlResponse(for: requestURL))
        } catch is CancellationError {
            throw CancellationError()
        } catch let relayError as WatchConnectivityRelayError {
            guard WatchRelayFallbackPolicy.shouldUseDirectNetwork(
                after: relayError,
                for: request
            ) else {
                switch relayError {
                case .responseTooLarge:
                    throw GatewayClientError.responseTooLarge
                default:
                    throw GatewayClientError.invalidResponse
                }
            }
            let directRequest = try deadline.directFallbackRequest(from: request)
            return try await fetchDirectData(
                for: directRequest,
                maximumBytes: maximumBytes
            )
        }
    }

    private func fetchDirectData(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw GatewayClientError.responseTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, 65_536))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw GatewayClientError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

enum GatewayClientError: LocalizedError, Sendable {
    case serverNotConfigured
    case tokenNotConfigured
    case invalidServerURL
    case invalidResponse
    case responseTooLarge
    case requestTooLarge
    case network(URLError.Code)
    case http(Int, GatewayErrorResponse?)
    case stream(GatewayErrorResponse)

    var isStreamingEndpointUnavailable: Bool {
        switch self {
        case .http(let status, _) where status == 404 || status == 405:
            return true
        default:
            return false
        }
    }

    var isConfigurationError: Bool {
        switch self {
        case .serverNotConfigured, .tokenNotConfigured, .invalidServerURL:
            return true
        case .http(let status, _) where status == 401 || status == 403:
            return true
        default:
            return false
        }
    }

    var isInputError: Bool {
        switch self {
        case .http(let status, _) where status == 400 || status == 422:
            return true
        default:
            return false
        }
    }

    func supportsPersonalFallback(forPageBoundTask: Bool) -> Bool {
        switch self {
        case .network:
            return GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: forPageBoundTask,
                isNetworkFailure: true
            )
        case .http(let status, let error):
            return GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: forPageBoundTask,
                isNetworkFailure: false,
                httpStatusCode: status,
                errorCode: error?.code,
                errorMessage: error?.message
            )
        case .stream(let error):
            return GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: forPageBoundTask,
                isNetworkFailure: false,
                httpStatusCode: 503,
                errorCode: error.code,
                errorMessage: error.message
            )
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .serverNotConfigured:
            return "请先设置统一 HTTPS 网关地址。"
        case .tokenNotConfigured:
            return "请先设置网关部署访问令牌。"
        case .invalidServerURL:
            return "网关地址无效，必须填写公网 HTTPS 地址。"
        case .invalidResponse:
            return "网关返回了无法识别的数据，请检查服务版本后重试。"
        case .responseTooLarge:
            return "网关返回的数据过大，手表已停止下载。"
        case .requestTooLarge:
            return "当前对话内容过长，请新建对话后继续。"
        case .network(let code):
            switch code {
            case .notConnectedToInternet:
                return "手表没有可用网络；当前输入已保留，请检查蜂窝或 Wi-Fi 后重试。"
            case .timedOut:
                return "网关响应超时，内容已保留，可以直接重试。"
            case .cannotFindHost, .dnsLookupFailed:
                return "找不到网关服务器，请检查服务地址。"
            case .cannotConnectToHost:
                return "无法连接网关服务器，请确认服务正在运行。"
            case .networkConnectionLost:
                return "蜂窝连接中断，内容已保留，可以直接重试。"
            case .secureConnectionFailed,
                 .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot:
                return "网关 HTTPS 证书无效，为保护安全已停止连接。"
            default:
                return "网关网络请求失败，请检查手表网络后重试。"
            }
        case .http(let status, let error):
            if status == 401 || status == 403 {
                return "网关部署令牌无效或已过期，请在设置中更换。"
            }
            if error?.code == "url_blocked" {
                return "该网址指向本地、内网或受保护地址，网关已安全拦截。"
            }
            switch GatewayServiceIssuePolicy.classify(
                statusCode: status,
                errorCode: error?.code,
                errorMessage: error?.message
            ) {
            case .aiNotConfigured:
                return "免费 Cloudflare 转发尚未配置 DeepSeek。问题已保留，请检查 Worker 密钥后重试。"
            case .aiDailyQuotaExhausted:
                return "DeepSeek 上游额度或余额不足。问题已保留，请检查 DeepSeek 账户后重试。"
            case .aiCapacityUnavailable:
                return "DeepSeek 上游当前容量不足。问题已保留，请稍后重试。"
            case .dynamicDailyQuotaExhausted:
                return "Browser Run 今日免费动态浏览额度已用完。手表直读和云端静态正文仍可用，动态截图请明日再试。"
            case .rateLimited:
                return "免费网关达到当前请求或并发限制；输入已保留，请稍后重试。"
            case .dynamicServiceUnavailable:
                return "免费动态浏览服务暂时不可用或正在唤醒。手表直读和云端静态正文仍可使用。"
            case .serviceUnavailable:
                return "免费网关暂时不可用或正在唤醒；输入已保留，请稍后重试。"
            case .sessionExpired:
                return "云端浏览会话已过期，请重新打开当前网址。"
            case .other:
                break
            }
            if status == 408 || status == 504 {
                return error?.message ?? "网关处理超时，请重试。"
            }
            return error?.message ?? "网关请求失败（HTTP \(status)）。"
        case .stream(let error):
            switch GatewayServiceIssuePolicy.classify(
                statusCode: error.code.contains("limit") || error.code.contains("busy") ? 429 : 503,
                errorCode: error.code,
                errorMessage: error.message
            ) {
            case .aiDailyQuotaExhausted:
                return "DeepSeek 上游额度或余额不足。对话已保留，请检查 DeepSeek 账户。"
            case .aiCapacityUnavailable:
                return "DeepSeek 上游当前容量不足。对话已保留，请稍后重试。"
            case .rateLimited:
                return "DeepSeek 上游请求过多。对话已保留，请稍后重试。"
            default:
                return error.message.isEmpty
                    ? "DeepSeek 转发回答中断。对话已保留，可以直接重试。"
                    : error.message
            }
        }
    }
}
