import Foundation

final class DeepSeekService: @unchecked Sendable {
    private static let responsesEndpoint = URL(string: "https://api.deepseek.com/responses")!
    private static let modelsEndpoint = URL(string: "https://api.deepseek.com/models")!

    private struct StreamAccumulator {
        var answer = ""
        var reasoning = ""
        var result: GatewayAskResponse?
        var answerWasCapped = false
        var reasoningWasCapped = false

        mutating func apply(
            _ event: DeepSeekResponsesStreamEvent,
            payload: GatewayAskRequest,
            requestedModel: DeepSeekModel?
        ) throws -> [GatewayAskStreamEvent] {
            switch event {
            case .reasoningDelta(let text):
                let remaining = max(
                    0,
                    DeepSeekRequestPolicy.maximumReasoningCharacters - reasoning.count
                )
                let accepted = String(text.prefix(remaining))
                if accepted.count < text.count { reasoningWasCapped = true }
                reasoning += accepted
                return accepted.isEmpty ? [] : [.reasoningDelta(accepted)]

            case .answerDelta(let text):
                let remaining = max(
                    0,
                    DeepSeekRequestPolicy.maximumAnswerCharacters - answer.count
                )
                let accepted = String(text.prefix(remaining))
                if accepted.count < text.count { answerWasCapped = true }
                answer += accepted
                return accepted.isEmpty ? [] : [.delta(accepted)]

            case .completed(let response), .incomplete(let response):
                let final = try response.gatewayResponse(
                    for: payload,
                    requestedModel: requestedModel,
                    accumulatedAnswer: answer,
                    accumulatedReasoning: reasoning,
                    streamWasCapped: answerWasCapped || reasoningWasCapped
                )
                result = final
                return [
                    .metadata(
                        GatewayAskStreamMetadata(
                            citations: final.citations,
                            model: final.model,
                            webSearchUsed: final.webSearchUsed,
                            webSearchProvider: final.webSearchProvider,
                            pageContextUsed: final.pageContextUsed,
                            responseItems: final.responseItems,
                            conversationTitle: final.conversationTitle
                        )
                    ),
                    .done(
                        answer: final.answer,
                        reasoning: final.reasoning,
                        truncated: final.truncated ?? false
                    )
                ]

            case .failed(let response):
                _ = try response.gatewayResponse(
                    for: payload,
                    accumulatedAnswer: answer,
                    accumulatedReasoning: reasoning
                )
                throw DeepSeekProtocolError.failed(response.error?.code)

            case .ignored:
                return []
            }
        }
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
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
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

    static func requestBody(for request: DeepSeekResponsesRequest) throws -> Data {
        let body = try JSONEncoder().encode(request)
        guard body.count <= GatewayRequestPolicy.maximumAskRequestBytes else {
            throw DeepSeekServiceError.requestTooLarge
        }
        return body
    }

    func answerStreaming(
        _ payload: GatewayAskRequest,
        apiKey: String,
        requestedModel: DeepSeekModel? = nil,
        generateTitle: Bool = false,
        onEvent: @escaping @Sendable (GatewayAskStreamEvent) async -> Void
    ) async throws -> GatewayAskResponse {
        let credential = try normalizedCredential(apiKey)
        let deepSeekPayload = DeepSeekResponsesRequest(
            payload: payload, requestedModel: requestedModel, generateTitle: generateTitle
        )
        let requestBody = try Self.requestBody(for: deepSeekPayload)

        var request = URLRequest(url: Self.responsesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("WatchBrowser/1.0 watchOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = requestBody

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw DeepSeekServiceError.network(error.code)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            try await discardErrorBody(bytes)
            throw error(forHTTPStatus: http.statusCode)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains("text/event-stream") == true else {
            throw DeepSeekServiceError.invalidResponse
        }

        await onEvent(
            .metadata(
                GatewayAskStreamMetadata(
                    citations: [],
                    model: deepSeekPayload.model,
                    webSearchUsed: false,
                    webSearchProvider: nil,
                    pageContextUsed: payload.page != nil
                )
            )
        )

        var parser = DeepSeekSSEByteParser()
        var accumulator = StreamAccumulator()
        var receivedBytes = 0

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                receivedBytes += 1
                guard receivedBytes <= DeepSeekRequestPolicy.maximumResponseBytes else {
                    throw DeepSeekServiceError.responseTooLarge
                }
                guard let event = try parser.consume(byte: byte) else { continue }
                for watchEvent in try accumulator.apply(event, payload: payload, requestedModel: requestedModel) {
                    await onEvent(watchEvent)
                }
                if let result = accumulator.result { return result }
            }

            if let event = try parser.finish() {
                for watchEvent in try accumulator.apply(event, payload: payload, requestedModel: requestedModel) {
                    await onEvent(watchEvent)
                }
            }
            if let result = accumulator.result { return result }
            throw DeepSeekServiceError.missingFinalResponse
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw DeepSeekServiceError.network(error.code)
        }
    }

    func checkCredential(apiKey: String) async throws {
        let credential = try normalizedCredential(apiKey)
        var request = URLRequest(url: Self.modelsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("WatchBrowser/1.0 watchOS", forHTTPHeaderField: "User-Agent")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw DeepSeekServiceError.network(error.code)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekServiceError.invalidResponse
        }
        var byteCount = 0
        for try await _ in bytes {
            try Task.checkCancellation()
            byteCount += 1
            guard byteCount <= 256 * 1_024 else {
                throw DeepSeekServiceError.responseTooLarge
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw error(forHTTPStatus: http.statusCode)
        }
    }

    private func normalizedCredential(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DeepSeekServiceError.missingCredential }
        guard (8...512).contains(value.count),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DeepSeekServiceError.invalidCredential
        }
        return value
    }

    private func discardErrorBody(_ bytes: URLSession.AsyncBytes) async throws {
        var count = 0
        for try await _ in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= 64 * 1_024 else {
                throw DeepSeekServiceError.responseTooLarge
            }
        }
    }

    private func error(forHTTPStatus status: Int) -> DeepSeekServiceError {
        switch status {
        case 400, 422:
            return .invalidRequest
        case 401, 403:
            return .invalidCredential
        case 402:
            return .insufficientBalance
        case 429:
            return .rateLimited
        case 500...599:
            return .serviceUnavailable
        default:
            return .http(status)
        }
    }
}

enum DeepSeekServiceError: LocalizedError, Sendable {
    case missingCredential
    case invalidCredential
    case insufficientBalance
    case invalidRequest
    case invalidResponse
    case missingFinalResponse
    case responseTooLarge
    case requestTooLarge
    case rateLimited
    case serviceUnavailable
    case network(URLError.Code)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "手表中还没有 DeepSeek API Key。"
        case .invalidCredential:
            return "DeepSeek API Key 无效或已失效，请在 Mac 上重新运行密钥配置工具。"
        case .insufficientBalance:
            return "DeepSeek API 余额不足，请在 DeepSeek 账户中检查余额。"
        case .invalidRequest:
            return "DeepSeek 暂时无法处理这个请求，请缩短内容后重试。"
        case .invalidResponse, .missingFinalResponse:
            return "DeepSeek 返回的数据不完整，请重试。"
        case .responseTooLarge:
            return "DeepSeek 回答过大，手表已停止载入。"
        case .requestTooLarge:
            return "当前问题或对话太长，请新建对话后继续。"
        case .rateLimited:
            return "DeepSeek 请求较多，请稍后重试。"
        case .serviceUnavailable:
            return "DeepSeek 服务暂时不可用，请稍后重试。"
        case .network(let code):
            switch code {
            case .notConnectedToInternet:
                return "手表没有网络，请检查蜂窝或 Wi‑Fi。"
            case .timedOut:
                return "连接 DeepSeek 超时，请稍后重试。"
            default:
                return "手表无法连接 DeepSeek。"
            }
        case .http(let status):
            return "DeepSeek 请求失败（\(status)）。"
        }
    }
}
