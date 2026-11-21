import Combine
import Foundation

@preconcurrency import WatchConnectivity

enum PhoneRelayOutcome: Sendable, Equatable {
    case httpStatus(Int)
    case failure(WatchRelayErrorCode)

    var summary: String {
        switch self {
        case .httpStatus(let statusCode):
            return "已完成 · HTTP \(statusCode)"
        case .failure(let code):
            return "未完成 · \(code.rawValue)"
        }
    }
}

private struct PhoneRelayHandlingResult: Sendable {
    let encodedPayload: Data
    let outcome: PhoneRelayOutcome
}

private enum PhoneRelayServiceError: Error, Sendable {
    case configurationUnavailable
    case requestExpired
    case requestRejected
    case responseTooLarge
    case invalidResponse
    case timedOut
    case cancelled
    case upstreamNetwork
}

private final class PhoneRelayRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor PhoneRelayService {
    private static let unknownRequestID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
    private let session: URLSession
    private let redirectDelegate: PhoneRelayRedirectDelegate
    private let localBrowserService: PhoneLocalBrowserService

    init(localBrowserService: PhoneLocalBrowserService) {
        self.localBrowserService = localBrowserService
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 2
        let redirectDelegate = PhoneRelayRedirectDelegate()
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

    func handle(_ encodedPayload: Data) async -> PhoneRelayHandlingResult {
        let message: WatchRelayMessage
        do {
            message = try WatchRelayCodec.decodeWithoutFreshnessValidation(encodedPayload)
        } catch let error as WatchRelayProtocolError {
            return failure(
                requestID: Self.unknownRequestID,
                code: error.errorCode,
                message: "中继请求未通过协议校验。",
                retryable: false
            )
        } catch {
            return failure(
                requestID: Self.unknownRequestID,
                code: .malformedMessage,
                message: "中继请求格式无效。",
                retryable: false
            )
        }

        guard case .request(let relayRequest) = message else {
            let requestID: UUID
            if case .response(let response) = message {
                requestID = response.requestID
            } else {
                requestID = Self.unknownRequestID
            }
            return failure(
                requestID: requestID,
                code: .requestRejected,
                message: "iPhone 仅接受手表发出的中继请求。",
                retryable: false
            )
        }

        let now = WatchRelayPolicy.millisecondsSince1970()
        do {
            try relayRequest.validateFreshness(atMillisecondsSince1970: now)
        } catch let error as WatchRelayProtocolError {
            if error == .requestExpired {
                return failure(
                    requestID: relayRequest.id,
                    code: .requestExpired,
                    message: "中继请求已过期，请重新发起。",
                    retryable: true
                )
            }
            return failure(
                requestID: relayRequest.id,
                code: error.errorCode,
                message: "中继请求时间未通过安全校验。",
                retryable: false
            )
        } catch {
            return failure(
                requestID: relayRequest.id,
                code: .requestRejected,
                message: "中继请求时间未通过安全校验。",
                retryable: false
            )
        }

        do {
            guard relayRequest.headers["authorization"] == nil,
                  relayRequest.headers["cookie"] == nil else {
                throw PhoneRelayServiceError.requestRejected
            }
            let localRoute = PhoneLocalBrowserRoute.classify(
                method: relayRequest.method.rawValue,
                path: relayRequest.path
            )
            if localRoute != .upstream {
                let localResponse = await localBrowserService.handle(relayRequest)
                if case .open = localRoute,
                   Self.isSafeLocalBrowserFallback(localResponse),
                   let configuration = try? PhoneGatewayStore.loadConfiguration(),
                   Self.originsMatch(
                       assertedOrigin: relayRequest.gatewayOrigin,
                       configuredURL: configuration.baseURL
                   ),
                   let cloudResponse = try? await perform(
                       relayRequest,
                       configuration: configuration
                   ) {
                    return httpResponse(
                        requestID: relayRequest.id,
                        response: cloudResponse
                    )
                }
                return httpResponse(
                    requestID: relayRequest.id,
                    response: localResponse
                )
            }
            guard let configuration = try PhoneGatewayStore.loadConfiguration() else {
                throw PhoneRelayServiceError.configurationUnavailable
            }
            let response = try await perform(
                relayRequest,
                configuration: configuration
            )
            return httpResponse(requestID: relayRequest.id, response: response)
        } catch is CancellationError {
            return failure(
                requestID: relayRequest.id,
                code: .cancelled,
                message: "中继请求已取消。",
                retryable: true
            )
        } catch let error as PhoneRelayServiceError {
            return mappedFailure(requestID: relayRequest.id, error: error)
        } catch is PhoneGatewayStoreError {
            return failure(
                requestID: relayRequest.id,
                code: .transportUnavailable,
                message: "iPhone 网关设置不可用，请在手机上重新保存。",
                retryable: false
            )
        } catch let error as URLError {
            if error.code == .cancelled {
                return failure(
                    requestID: relayRequest.id,
                    code: .cancelled,
                    message: "中继请求已取消。",
                    retryable: true
                )
            }
            if error.code == .timedOut {
                return failure(
                    requestID: relayRequest.id,
                    code: .timedOut,
                    message: "iPhone 请求网关超时。",
                    retryable: true
                )
            }
            return failure(
                requestID: relayRequest.id,
                code: .upstreamNetwork,
                message: "iPhone 暂时无法连接网关。",
                retryable: true
            )
        } catch {
            return failure(
                requestID: relayRequest.id,
                code: .internalError,
                message: "iPhone 中继暂时不可用。",
                retryable: true
            )
        }
    }

    private static func isSafeLocalBrowserFallback(
        _ response: WatchRelayHTTPResponse
    ) -> Bool {
        guard response.statusCode == 503,
              let body = response.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = object["code"] as? String else {
            return false
        }
        return code == "local_https_required" || code == "local_renderer_unavailable"
    }

    private func perform(
        _ relayRequest: WatchRelayRequest,
        configuration: PhoneGatewayConfiguration
    ) async throws -> WatchRelayHTTPResponse {
        guard Self.originsMatch(
            assertedOrigin: relayRequest.gatewayOrigin,
            configuredURL: configuration.baseURL
        ) else {
            throw PhoneRelayServiceError.requestRejected
        }

        let nowMillisecondsSince1970 = WatchRelayPolicy.millisecondsSince1970()
        let timeoutMilliseconds = relayRequest.remainingTimeoutMilliseconds(
            atMillisecondsSince1970: nowMillisecondsSince1970
        )
        guard timeoutMilliseconds > 0 else {
            throw PhoneRelayServiceError.requestExpired
        }

        let pathComponents = relayRequest.path.split(separator: "/")
        let endpoint = pathComponents.reduce(configuration.baseURL) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
        guard let endpointComponents = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ),
        let configuredComponents = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ),
        endpointComponents.scheme?.lowercased() == "https",
        endpointComponents.host?.lowercased() == configuredComponents.host?.lowercased(),
        (endpointComponents.port ?? 443) == (configuredComponents.port ?? 443),
        endpointComponents.user == nil,
        endpointComponents.password == nil,
        endpointComponents.query == nil,
        endpointComponents.fragment == nil else {
            throw PhoneRelayServiceError.requestRejected
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = relayRequest.method.rawValue
        request.timeoutInterval = TimeInterval(timeoutMilliseconds) / 1_000
        for (name, value) in relayRequest.headers {
            guard name != "authorization", name != "cookie" else {
                throw PhoneRelayServiceError.requestRejected
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(
            "Bearer \(configuration.bearerToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("WatchBrowser/1.0 iOSRelay", forHTTPHeaderField: "User-Agent")
        request.httpBody = relayRequest.body

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw Self.serviceError(for: error)
        } catch is CancellationError {
            throw PhoneRelayServiceError.cancelled
        } catch {
            throw PhoneRelayServiceError.upstreamNetwork
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PhoneRelayServiceError.invalidResponse
        }
        guard !(300..<400).contains(httpResponse.statusCode) else {
            throw PhoneRelayServiceError.invalidResponse
        }
        if response.expectedContentLength > Int64(WatchRelayPolicy.maximumBodyBytes) {
            throw PhoneRelayServiceError.responseTooLarge
        }

        var body = Data()
        body.reserveCapacity(
            min(
                max(Int(response.expectedContentLength), 0),
                WatchRelayPolicy.maximumBodyBytes
            )
        )
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < WatchRelayPolicy.maximumBodyBytes else {
                    throw PhoneRelayServiceError.responseTooLarge
                }
                body.append(byte)
            }
        } catch let error as PhoneRelayServiceError {
            throw error
        } catch is CancellationError {
            throw PhoneRelayServiceError.cancelled
        } catch let error as URLError {
            throw Self.serviceError(for: error)
        } catch {
            throw PhoneRelayServiceError.upstreamNetwork
        }

        var responseHeaders: [String: String] = [:]
        for name in ["Content-Type", "Content-Language", "Retry-After"] {
            guard let value = httpResponse.value(forHTTPHeaderField: name),
                  value.utf8.count <= WatchRelayPolicy.maximumHeaderValueBytes,
                  value.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                continue
            }
            responseHeaders[name.lowercased()] = value
        }

        do {
            return try WatchRelayHTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: responseHeaders,
                body: body.isEmpty ? nil : body
            )
        } catch let error as WatchRelayProtocolError {
            if case .bodyTooLarge = error {
                throw PhoneRelayServiceError.responseTooLarge
            }
            throw PhoneRelayServiceError.invalidResponse
        }
    }

    private static func originsMatch(assertedOrigin: String, configuredURL: URL) -> Bool {
        guard let asserted = URLComponents(string: assertedOrigin),
              let configured = URLComponents(
                  url: configuredURL,
                  resolvingAgainstBaseURL: false
              ),
              asserted.scheme?.lowercased() == "https",
              configured.scheme?.lowercased() == "https",
              let assertedHost = asserted.host?.lowercased(),
              let configuredHost = configured.host?.lowercased(),
              assertedHost == configuredHost,
              (asserted.port ?? 443) == (configured.port ?? 443),
              asserted.user == nil,
              asserted.password == nil,
              asserted.percentEncodedPath.isEmpty,
              asserted.percentEncodedQuery == nil,
              asserted.percentEncodedFragment == nil else {
            return false
        }
        return true
    }

    private static func serviceError(for error: URLError) -> PhoneRelayServiceError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .invalidResponse
        default:
            return .upstreamNetwork
        }
    }

    private func httpResponse(
        requestID: UUID,
        response: WatchRelayHTTPResponse
    ) -> PhoneRelayHandlingResult {
        let relayResponse = WatchRelayResponse(
            requestID: requestID,
            payload: .http(response)
        )
        do {
            let data = try WatchRelayCodec.encode(.response(relayResponse))
            return PhoneRelayHandlingResult(
                encodedPayload: data,
                outcome: .httpStatus(response.statusCode)
            )
        } catch {
            return failure(
                requestID: requestID,
                code: .responseTooLarge,
                message: "网关响应超过 WatchConnectivity 安全上限。",
                retryable: false
            )
        }
    }

    private func mappedFailure(
        requestID: UUID,
        error: PhoneRelayServiceError
    ) -> PhoneRelayHandlingResult {
        switch error {
        case .configurationUnavailable:
            return failure(
                requestID: requestID,
                code: .transportUnavailable,
                message: "请先在 iPhone 保存网关地址和部署令牌。",
                retryable: false
            )
        case .requestExpired:
            return failure(
                requestID: requestID,
                code: .requestExpired,
                message: "中继请求已过期，请重新发起。",
                retryable: true
            )
        case .requestRejected:
            return failure(
                requestID: requestID,
                code: .requestRejected,
                message: "中继请求未通过安全校验。",
                retryable: false
            )
        case .responseTooLarge:
            return failure(
                requestID: requestID,
                code: .responseTooLarge,
                message: "网关响应超过 WatchConnectivity 安全上限。",
                retryable: false
            )
        case .invalidResponse:
            return failure(
                requestID: requestID,
                code: .upstreamInvalidResponse,
                message: "网关返回了无法安全转发的响应。",
                retryable: false
            )
        case .timedOut:
            return failure(
                requestID: requestID,
                code: .timedOut,
                message: "iPhone 请求网关超时。",
                retryable: true
            )
        case .cancelled:
            return failure(
                requestID: requestID,
                code: .cancelled,
                message: "中继请求已取消。",
                retryable: true
            )
        case .upstreamNetwork:
            return failure(
                requestID: requestID,
                code: .upstreamNetwork,
                message: "iPhone 暂时无法连接网关。",
                retryable: true
            )
        }
    }

    private func failure(
        requestID: UUID,
        code: WatchRelayErrorCode,
        message: String,
        retryable: Bool
    ) -> PhoneRelayHandlingResult {
        let failure: WatchRelayFailure
        do {
            failure = try WatchRelayFailure(
                code: code,
                message: message,
                retryable: retryable
            )
        } catch {
            guard let fallback = try? WatchRelayFailure(
                code: .internalError,
                message: "iPhone 中继暂时不可用。",
                retryable: true
            ) else {
                return PhoneRelayHandlingResult(
                    encodedPayload: Data(),
                    outcome: .failure(.internalError)
                )
            }
            return encodedFailure(requestID: requestID, failure: fallback)
        }
        return encodedFailure(requestID: requestID, failure: failure)
    }

    private func encodedFailure(
        requestID: UUID,
        failure: WatchRelayFailure
    ) -> PhoneRelayHandlingResult {
        let response = WatchRelayResponse(
            requestID: requestID,
            payload: .failure(failure)
        )
        let encoded = (try? WatchRelayCodec.encode(.response(response))) ?? Data()
        return PhoneRelayHandlingResult(
            encodedPayload: encoded,
            outcome: .failure(failure.code)
        )
    }
}

private enum PhoneSessionActivation: String, Sendable {
    case unsupported = "此 iPhone 不支持 WatchConnectivity"
    case notActivated = "正在连接"
    case inactive = "暂时不可用"
    case activated = "已激活"
}

private struct PhoneSessionSnapshot: Sendable {
    let activation: PhoneSessionActivation
    let isPaired: Bool
    let isWatchAppInstalled: Bool
    let isReachable: Bool
}

private func snapshot(of session: WCSession) -> PhoneSessionSnapshot {
    let activation: PhoneSessionActivation
    switch session.activationState {
    case .notActivated:
        activation = .notActivated
    case .inactive:
        activation = .inactive
    case .activated:
        activation = .activated
    @unknown default:
        activation = .inactive
    }
    return PhoneSessionSnapshot(
        activation: activation,
        isPaired: session.isPaired,
        isWatchAppInstalled: session.isWatchAppInstalled,
        isReachable: session.isReachable
    )
}

@MainActor
final class PhoneSessionController: NSObject, ObservableObject, WCSessionDelegate,
    @unchecked Sendable {
    private let localBrowserService: PhoneLocalBrowserService
    nonisolated private let relayService: PhoneRelayService
    private let session: WCSession?
    private weak var browserRenderHost: PhoneBrowserRenderHostView?
#if DEBUG
    private var didStartBrowserAcceptanceProbe = false
#endif

    @Published private(set) var activationText = PhoneSessionActivation.notActivated.rawValue
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var isConfigured = false
    @Published private(set) var hasStoredToken = false
    @Published private(set) var configurationFeedback = "请保存免费网关设置。"
    @Published private(set) var lastRelayResult = "尚无中继请求"
    @Published private(set) var lastRelayDate: Date?
    @Published private(set) var isLocalBrowserPreviewReady = false
    @Published var serverURLDraft = ""
    @Published var tokenDraft = ""
    @Published var showsDeleteConfirmation = false

    override init() {
        let localBrowserService = PhoneLocalBrowserService()
        self.localBrowserService = localBrowserService
        relayService = PhoneRelayService(localBrowserService: localBrowserService)
        let debugImport = PhoneGatewayDebugImporter.importIfPresent()
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()

        refreshConfiguration(feedback: debugImport?.message)
        guard let session else {
            activationText = PhoneSessionActivation.unsupported.rawValue
            return
        }
        session.delegate = self
        session.activate()
        apply(snapshot(of: session))
    }

    func attachBrowserRenderHost(_ host: PhoneBrowserRenderHostView) {
        if let current = browserRenderHost, current !== host {
            localBrowserService.detachRenderHost(current)
        }
        browserRenderHost = host
        localBrowserService.attachRenderHost(host)
        refreshLocalBrowserPreviewState()
    }

    func detachBrowserRenderHost(_ host: PhoneBrowserRenderHostView) {
        guard browserRenderHost === host else { return }
        localBrowserService.detachRenderHost(host)
        browserRenderHost = nil
        refreshLocalBrowserPreviewState()
    }

    func browserRenderHostWindowDidChange(_ host: PhoneBrowserRenderHostView) {
        guard browserRenderHost === host else { return }
        localBrowserService.renderHostWindowDidChange(host)
        refreshLocalBrowserPreviewState()
    }

    func setApplicationSceneActive(_ isActive: Bool) {
        localBrowserService.setApplicationActive(isActive)
        refreshLocalBrowserPreviewState()
    }

#if DEBUG
    func startBrowserAcceptanceProbeIfRequested() {
        guard !didStartBrowserAcceptanceProbe,
              PhoneBrowserAcceptanceProbe.isRequested else {
            return
        }
        didStartBrowserAcceptanceProbe = true
        let relayService = relayService
        Task.detached(priority: .userInitiated) {
            await PhoneBrowserAcceptanceProbe.runIfRequested { encodedRequest in
                let result = await relayService.handle(encodedRequest)
                return result.encodedPayload
            }
        }
    }
#endif

    func saveConfiguration() {
        do {
            let normalizedURL = try PhoneGatewayStore.save(
                serverURL: serverURLDraft,
                replacementToken: tokenDraft
            )
            serverURLDraft = normalizedURL.absoluteString
            tokenDraft = ""
            refreshConfiguration(feedback: "设置已保存。令牌仅保存在 iPhone Keychain。")
        } catch {
            configurationFeedback = error.localizedDescription
            refreshConfigurationFlags()
        }
    }

    func deleteConfiguration() {
        do {
            try PhoneGatewayStore.deleteConfiguration()
            serverURLDraft = ""
            tokenDraft = ""
            refreshConfiguration(feedback: "网关地址和 iPhone Keychain 令牌已删除。")
        } catch {
            configurationFeedback = error.localizedDescription
            refreshConfigurationFlags()
        }
    }

    func refreshConnection() {
        guard let session else {
            activationText = PhoneSessionActivation.unsupported.rawValue
            return
        }
        if session.activationState != .activated {
            session.activate()
        }
        apply(snapshot(of: session))
        refreshConfiguration(feedback: nil)
    }

    private func refreshConfiguration(feedback: String?) {
        serverURLDraft = PhoneGatewayStore.savedServerURL ?? serverURLDraft
        refreshConfigurationFlags()
        if let feedback {
            configurationFeedback = feedback
        } else if isConfigured {
            configurationFeedback = "已就绪；手表网络失败时可通过 iPhone 中继。"
        } else if hasStoredToken {
            configurationFeedback = "令牌已保存，请补充有效的 HTTPS 服务器地址。"
        } else {
            configurationFeedback = "请保存服务器地址和部署令牌。"
        }
    }

    private func refreshConfigurationFlags() {
        do {
            hasStoredToken = try PhoneGatewayStore.hasSavedToken()
            isConfigured = try PhoneGatewayStore.loadConfiguration() != nil
        } catch {
            hasStoredToken = false
            isConfigured = false
        }
    }

    private func refreshLocalBrowserPreviewState() {
        isLocalBrowserPreviewReady = localBrowserService.isForegroundRendererReady
    }

    private func apply(_ state: PhoneSessionSnapshot) {
        activationText = state.activation.rawValue
        isPaired = state.isPaired
        isWatchAppInstalled = state.isWatchAppInstalled
        isReachable = state.isReachable
    }

    private func record(_ outcome: PhoneRelayOutcome) {
        lastRelayResult = outcome.summary
        lastRelayDate = Date()
        refreshConfigurationFlags()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let state = snapshot(of: session)
        Task { @MainActor [weak self] in
            self?.apply(state)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        let state = snapshot(of: session)
        Task { @MainActor [weak self] in
            self?.apply(state)
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        let state = snapshot(of: session)
        Task { @MainActor [weak self] in
            self?.apply(state)
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let state = snapshot(of: session)
        Task { @MainActor [weak self] in
            self?.apply(state)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let state = snapshot(of: session)
        Task { @MainActor [weak self] in
            self?.apply(state)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping @Sendable (Data) -> Void
    ) {
        let relayService = relayService

        Task { [weak self] in
            let result = await relayService.handle(messageData)
            replyHandler(result.encodedPayload)
            await self?.record(result.outcome)
        }
    }
}
