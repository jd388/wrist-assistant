import Combine
import Foundation
import SwiftUI
import UIKit

enum WatchRemotePhase: Equatable {
    case idle
    case loading(String)
    case displaying
    case error(String)
}

enum BrowserServerDefaults {
    static var freeReaderBaseURL: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "BrowserRendererBaseURL") as? String ?? ""
        return value.contains("$(") ? "" : value
    }

    static var baseURL: String {
        freeReaderBaseURL
    }

    static var legacyAccessToken: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "BrowserRendererToken") as? String ?? ""
        return value.contains("$(") ? "" : value
    }
}

@MainActor
final class WatchRemoteBrowser: ObservableObject {
    @Published private(set) var phase: WatchRemotePhase = .idle
    @Published private(set) var pageImage: UIImage?
    @Published private(set) var pageTitle = "网页"
    @Published private(set) var currentURL = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var scrollProgress = 0.0
    @Published private(set) var focusedInputAvailable = false
    @Published private(set) var focusedInputLabel = "网页输入框"
    @Published private(set) var isServiceReady = false
    @Published private(set) var isGatewayReachable = false
    @Published private(set) var isReaderReady = false
    @Published private(set) var connectionMessage = "等待检测统一网关"

    var isBusy: Bool {
        if case .loading = phase { return true }
        return false
    }

    private let session: URLSession
    private let redirectDelegate: RejectingRedirectDelegate
    private var rendererBaseURL: URL?
    private var accessToken = ""
    private var browserSessionID: String?
    private var latestSequence: UInt64 = 0
    private var operationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var healthCheckID: UUID?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 40
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
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
        operationTask?.cancel()
        healthTask?.cancel()
        session.invalidateAndCancel()
    }

    func configure(serverURL: String, token: String) {
        do {
            let normalized = try normalizeServerURL(serverURL)
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { throw CloudBrowserError.tokenNotConfigured }
            if rendererBaseURL != normalized || accessToken != normalizedToken {
                rendererBaseURL = normalized
                accessToken = normalizedToken
                browserSessionID = nil
                latestSequence = 0
                isServiceReady = false
                isGatewayReachable = false
                isReaderReady = false
                connectionMessage = "统一网关地址已保存，等待检测"
            }
        } catch {
            rendererBaseURL = nil
            isServiceReady = false
            isGatewayReachable = false
            isReaderReady = false
            connectionMessage = error.localizedDescription
        }
    }

    func checkService(serverURL: String, token: String) {
        healthTask?.cancel()
        healthCheckID = nil
        configure(serverURL: serverURL, token: token)
        guard let rendererBaseURL else {
            phase = .error(connectionMessage)
            return
        }

        let currentHealthCheckID = UUID()
        healthCheckID = currentHealthCheckID
        connectionMessage = "正在检测统一网关…"
        healthTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = self.request(
                    url: rendererBaseURL.appendingPathComponent("health"),
                    method: "GET"
                )
                request.timeoutInterval = 12
                let (data, response) = try await self.fetchData(for: request, maximumBytes: 16_384)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudBrowserError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw CloudBrowserError.httpStatus(http.statusCode, nil, nil)
                }
                let health = try JSONDecoder().decode(GatewayHealthResponse.self, from: data)
                guard health.isAccepted(httpStatusCode: http.statusCode) else {
                    throw CloudBrowserError.browserUnavailable(health.detail)
                }
                guard !Task.isCancelled, self.healthCheckID == currentHealthCheckID else { return }
                self.isGatewayReachable = true
                self.isServiceReady = health.browserReady
                self.isReaderReady = health.effectiveReaderReady
                let readyServices = [
                    self.isReaderReady ? "正文" : nil,
                    health.browserReady ? "截图" : nil
                ].compactMap { $0 }
                if !readyServices.isEmpty {
                    let prefix = health.status == "degraded" ? "降级可用" : "可用"
                    self.connectionMessage = "\(prefix)：\(readyServices.joined(separator: "、"))"
                } else {
                    self.connectionMessage = health.detail ?? "HTTPS 网关在线，但各功能尚未就绪"
                }
                if self.operationID == nil, self.pageImage == nil, case .error = self.phase {
                    self.phase = .idle
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.healthCheckID == currentHealthCheckID else { return }
                self.isServiceReady = false
                self.isGatewayReachable = false
                self.isReaderReady = false
                self.connectionMessage = self.message(for: error)
                if self.operationID == nil, self.pageImage == nil {
                    self.phase = .error(self.connectionMessage)
                }
            }
        }
    }

    func markConfigurationDirty() {
        healthTask?.cancel()
        healthCheckID = nil
        isServiceReady = false
        isGatewayReachable = false
        isReaderReady = false
        connectionMessage = "设置已更改，请重新检测统一网关"
    }

    func open(rawValue: String, serverURL: String, token: String) {
        guard !isBusy else { return }
        let address: WebDestination
        do {
            address = try WebDestination(rawValue: rawValue)
            configure(serverURL: serverURL, token: token)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }
        guard rendererBaseURL != nil else {
            phase = .error(connectionMessage)
            return
        }

        healthTask?.cancel()
        healthCheckID = nil
        operationID = nil
        if let existingSessionID = browserSessionID {
            closeSession(existingSessionID)
        }
        browserSessionID = nil
        latestSequence = 0
        pageImage = nil
        currentURL = address.url.absoluteString
        start(
            path: ["v1", "sessions", "open"],
            body: OpenFrameRequest(
                url: address.url.absoluteString,
                viewportWidth: 396,
                viewportHeight: 484
            ),
            loadingMessage: "交互浏览正在载入网页（iPhone优先）…"
        )
    }

    func scroll(_ direction: Double) {
        guard let browserSessionID else {
            phase = .error(missingSessionMessage)
            return
        }
        start(
            path: ["v1", "sessions", browserSessionID, "scroll"],
            body: ScrollFrameRequest(amount: direction),
            loadingMessage: "正在滚动网页…"
        )
    }

    func refresh() {
        if browserSessionID == nil, !currentURL.isEmpty {
            reopenCurrentURL()
            return
        }
        control(pathComponent: "refresh", message: "正在刷新网页…")
    }

    func goBack() {
        guard canGoBack else {
            phase = .error("当前网页没有可返回的上一页。")
            return
        }
        control(pathComponent: "back", message: "正在返回上一页…")
    }

    func tap(normalizedX: Double, normalizedY: Double) {
        guard let browserSessionID else {
            phase = .error(missingSessionMessage)
            return
        }
        start(
            path: ["v1", "sessions", browserSessionID, "tap"],
            body: TapFrameRequest(
                x: min(max(normalizedX, 0), 1),
                y: min(max(normalizedY, 0), 1)
            ),
            loadingMessage: "正在处理网页点按…"
        )
    }

    func fillFocusedInput(text: String, submit: Bool = true) {
        guard let browserSessionID else {
            phase = .error(missingSessionMessage)
            return
        }
        guard focusedInputAvailable else {
            phase = .error("请先在网页画面上点按一个输入框。")
            return
        }
        let limited = String(text.prefix(500))
        start(
            path: ["v1", "sessions", browserSessionID, "fill"],
            body: FillFrameRequest(text: limited, submit: submit),
            loadingMessage: submit ? "正在填写并提交…" : "正在填写网页输入框…"
        )
    }

    func dismissPage() {
        operationTask?.cancel()
        operationID = nil
        if let existingSessionID = browserSessionID {
            closeSession(existingSessionID)
        }
        browserSessionID = nil
        latestSequence = 0
        pageImage = nil
        phase = .idle
    }

    private func control(pathComponent: String, message: String) {
        guard let browserSessionID else {
            phase = .error(missingSessionMessage)
            return
        }
        start(
            path: ["v1", "sessions", browserSessionID, pathComponent],
            body: EmptyFrameRequest(),
            loadingMessage: message
        )
    }

    private func start<Body: Encodable & Sendable>(
        path: [String],
        body: Body,
        loadingMessage: String
    ) {
        guard !isBusy else { return }
        guard let rendererBaseURL else {
            phase = .error("尚未设置交互浏览所需的统一网关地址。")
            return
        }

        operationTask?.cancel()
        healthTask?.cancel()
        healthCheckID = nil
        let currentOperationID = UUID()
        operationID = currentOperationID
        phase = .loading(loadingMessage)

        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == currentOperationID {
                    self.operationID = nil
                }
            }
            do {
                let url = path.reduce(rendererBaseURL) { partial, component in
                    partial.appendingPathComponent(component)
                }
                var request = self.request(url: url, method: "POST")
                request.httpBody = try JSONEncoder().encode(body)
                let (data, response) = try await self.fetchData(
                    for: request,
                    maximumBytes: 250_000
                )
                guard !Task.isCancelled, self.operationID == currentOperationID else { return }
                try self.validateResponse(data: data, response: response)
                let frame = try JSONDecoder().decode(CloudFrameResponse.self, from: data)
                try self.apply(frame)
            } catch is CancellationError {
                return
            } catch {
                guard self.operationID == currentOperationID else { return }
                if let browserError = error as? CloudBrowserError,
                   browserError.isSessionExpired {
                    self.browserSessionID = nil
                    self.latestSequence = 0
                    self.canGoBack = false
                    self.focusedInputAvailable = false
                    self.focusedInputLabel = "网页输入框"
                }
                self.phase = .error(self.message(for: error))
            }
        }
    }

    private func reopenCurrentURL() {
        guard let url = URL(string: currentURL),
              url.scheme == "https" || url.scheme == "http" else {
            phase = .error("当前网址无法恢复，请返回后重新输入。")
            return
        }
        latestSequence = 0
        start(
            path: ["v1", "sessions", "open"],
            body: OpenFrameRequest(
                url: url.absoluteString,
                viewportWidth: 396,
                viewportHeight: 484
            ),
            loadingMessage: "正在重新建立浏览会话…"
        )
    }

    private var missingSessionMessage: String {
        currentURL.isEmpty
            ? "浏览会话已失效，请重新输入网址。"
            : "浏览会话已失效；上一画面仍保留，请点刷新重新打开当前网址。"
    }

    private func request(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("WatchBrowser/1.0 watchOS", forHTTPHeaderField: "User-Agent")
        return request
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
                throw CloudBrowserError.invalidResponse
            }
            return (
                relayed.body ?? Data(),
                try relayed.urlResponse(for: requestURL)
            )
        } catch let error as CloudBrowserError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let relayError as WatchConnectivityRelayError {
            guard WatchRelayFallbackPolicy.shouldUseDirectNetwork(
                after: relayError,
                for: request
            ) else {
                if PhoneLocalBrowserRoute.requiresReachablePhone(
                    method: request.httpMethod ?? "GET",
                    path: request.url?.path ?? ""
                ) {
                    browserSessionID = nil
                    throw CloudBrowserError.phoneLocalUnavailable
                }
                if WatchRelayFallbackPolicy.failurePhase(for: relayError) == .outcomeUncertain {
                    throw CloudBrowserError.relayOutcomeUnknown
                }
                throw CloudBrowserError.invalidResponse
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
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if response.expectedContentLength > Int64(maximumBytes) {
                throw CloudBrowserError.responseTooLarge
            }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 65_536))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else {
                    throw CloudBrowserError.responseTooLarge
                }
                data.append(byte)
            }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where Task.isCancelled || error.code == .cancelled {
            throw CancellationError()
        }
    }

    private func closeSession(_ sessionID: String) {
        guard let rendererBaseURL else { return }
        let url = ["v1", "sessions", sessionID].reduce(rendererBaseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        var closeRequest = request(url: url, method: "DELETE")
        closeRequest.timeoutInterval = 8
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.fetchData(for: closeRequest, maximumBytes: 4_096)
        }
    }

    private func validateResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudBrowserError.invalidResponse
        }
        guard data.count <= 250_000 else {
            throw CloudBrowserError.responseTooLarge
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(CloudErrorResponse.self, from: data)
            throw CloudBrowserError.httpStatus(
                http.statusCode,
                serverError?.code,
                serverError?.message
            )
        }
    }

    private func apply(_ frame: CloudFrameResponse) throws {
        guard frame.sequence > latestSequence else {
            phase = pageImage == nil ? .error("返回了过期画面，请重新打开网址。") : .displaying
            return
        }
        guard let imageData = Data(base64Encoded: frame.imageBase64),
              imageData.count <= 80_000,
              let image = UIImage(data: imageData) else {
            throw CloudBrowserError.invalidImage
        }

        latestSequence = frame.sequence
        browserSessionID = frame.sessionID
        pageImage = image
        currentURL = frame.url
        pageTitle = frame.title.isEmpty ? (URL(string: frame.url)?.host ?? "网页") : frame.title
        canGoBack = frame.canGoBack
        scrollProgress = min(max(frame.scrollProgress, 0), 1)
        focusedInputAvailable = frame.focusedInput ?? false
        focusedInputLabel = frame.focusedInputLabel?.isEmpty == false
            ? frame.focusedInputLabel!
            : "网页输入框"
        isServiceReady = true
        isGatewayReachable = true
        connectionMessage = PhoneLocalBrowserRoute.isLocalSessionID(frame.sessionID)
            ? "iPhone 本地 WebKit 已连接"
            : "云端兼容浏览已连接"
        phase = .displaying
    }

    private func normalizeServerURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudBrowserError.serverNotConfigured }
        guard let url = GatewayOriginNormalizer.normalize(trimmed) else {
            throw CloudBrowserError.invalidServerURL
        }
        return url
    }

    private func message(for error: Error) -> String {
        if let browserError = error as? CloudBrowserError {
            return browserError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "手表当前没有蜂窝或 Wi‑Fi 网络。请检查控制中心信号后重试。"
            case .timedOut:
                return "交互浏览连接超时。首次载入和截图时请保持 iPhone 中继前台，或检查手表网络后重试。"
            case .cannotFindHost, .dnsLookupFailed:
                return "找不到统一网关。请检查服务地址。"
            case .secureConnectionFailed,
                 .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot:
                return "云端服务的 HTTPS 证书无效，已停止连接。"
            case .cancelled:
                return "操作已取消。"
            default:
                return "网络请求失败：\(urlError.localizedDescription)"
            }
        }
        return "浏览失败：\(error.localizedDescription)"
    }
}

private struct OpenFrameRequest: Encodable, Sendable {
    let url: String
    let viewportWidth: Int
    let viewportHeight: Int

    enum CodingKeys: String, CodingKey {
        case url
        case viewportWidth = "viewport_width"
        case viewportHeight = "viewport_height"
    }
}

private struct ScrollFrameRequest: Encodable, Sendable {
    let amount: Double
}

private struct TapFrameRequest: Encodable, Sendable {
    let x: Double
    let y: Double
}

private struct FillFrameRequest: Encodable, Sendable {
    let text: String
    let submit: Bool
}

private struct EmptyFrameRequest: Encodable, Sendable {}

private struct CloudFrameResponse: Decodable, Sendable {
    let sessionID: String
    let sequence: UInt64
    let url: String
    let title: String
    let canGoBack: Bool
    let scrollProgress: Double
    let imageBase64: String
    let message: String?
    let focusedInput: Bool?
    let focusedInputLabel: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sequence
        case url
        case title
        case canGoBack = "can_go_back"
        case scrollProgress = "scroll_progress"
        case imageBase64 = "image_base64"
        case message
        case focusedInput = "focused_input"
        case focusedInputLabel = "focused_input_label"
    }
}

private struct CloudErrorResponse: Decodable, Sendable {
    let code: String?
    let message: String
    let retryable: Bool?
}

private enum CloudBrowserError: LocalizedError {
    case serverNotConfigured
    case tokenNotConfigured
    case invalidServerURL
    case invalidResponse
    case responseTooLarge
    case invalidImage
    case phoneLocalUnavailable
    case relayOutcomeUnknown
    case browserUnavailable(String?)
    case httpStatus(Int, String?, String?)

    var isSessionExpired: Bool {
        guard case .httpStatus(let status, let code, _) = self else { return false }
        return GatewayServiceIssuePolicy.classify(
            statusCode: status,
            errorCode: code
        ) == .sessionExpired
    }

    var errorDescription: String? {
        switch self {
        case .serverNotConfigured:
            return "请先在“云端设置”中填写浏览器服务地址。"
        case .tokenNotConfigured:
            return "请在“云端设置”中填写服务器访问码。"
        case .invalidServerURL:
            return "云端服务地址无效，必须填写公网 HTTPS 地址。"
        case .invalidResponse:
            return "云端服务返回了无法识别的响应。"
        case .responseTooLarge:
            return "返回的网页数据过大，已停止下载以保护手表。"
        case .invalidImage:
            return "返回的网页画面损坏或超过大小限制。"
        case .phoneLocalUnavailable:
            return "该网页会话在 iPhone 本地运行，但手机中继暂时不可达。上一画面已保留；请打开 iPhone 上的“腕上浏览中继”，再点刷新重新打开。"
        case .relayOutcomeUnknown:
            return "操作可能已由浏览器执行，但确认回复中断；已保留上一画面，请先点刷新确认，勿立即重复提交。"
        case .browserUnavailable(let detail):
            return detail ?? "云端兼容后备尚未准备好；配对 iPhone 可达时仍优先尝试本地浏览。"
        case .httpStatus(let status, let code, let serverMessage):
            if status == 401 || status == 403 {
                return "云端访问码无效，请打开设置重新填写。"
            }
            if status == 404 {
                return "云端接口不存在，请检查服务地址或服务器版本。"
            }
            switch code {
            case "url_blocked":
                return "网页试图访问本地、内网或受保护地址，已安全拦截；上一画面仍会保留。"
            case "dns_resolution_failed":
                return "目标网站域名解析失败，请检查网址或蜂窝网络后重试。"
            case "blank_frame":
                return "网页有内容，但连续截图仍为空白；已保留上一画面，请重试。"
            case "empty_page":
                return "目标网页没有可显示内容；已保留上一画面。"
            case "input_not_focused":
                return "尚未选中网页输入框，请重新点按输入框。"
            case "renderer_unavailable":
                return "云端兼容后备尚未准备好；请保持 iPhone 中继前台后重试。"
            case "local_foreground_required":
                return "请解锁 iPhone，并让“腕上浏览中继”的本地网页预览保持在前台后重试。"
            default:
                break
            }
            switch GatewayServiceIssuePolicy.classify(
                statusCode: status,
                errorCode: code,
                errorMessage: serverMessage
            ) {
            case .sessionExpired:
                return "交互浏览会话已过期；上一画面仍保留，请点刷新重新打开当前网址。"
            case .dynamicDailyQuotaExhausted:
                return "云端兼容后备今日免费动态额度已用完；请保持 iPhone 中继前台后点刷新，或继续使用正文阅读。"
            case .rateLimited:
                return "云端兼容后备达到当前请求或并发限制；请保持 iPhone 中继前台后点刷新。"
            case .dynamicServiceUnavailable, .serviceUnavailable:
                return "云端兼容后备暂时不可用或正在唤醒；请保持 iPhone 中继前台后点刷新。"
            case .aiDailyQuotaExhausted:
                return "DeepSeek 上游额度或余额不足，请检查 DeepSeek 账户后重试。"
            case .aiCapacityUnavailable:
                return "DeepSeek 上游当前容量不足，请稍后重试。"
            case .aiNotConfigured, .other:
                break
            }
            if status == 408 || status == 504 {
                return serverMessage ?? "目标网页载入超时，请重试。"
            }
            return serverMessage ?? "云端服务返回 HTTP \(status)。"
        }
    }
}
