import Foundation

#if canImport(WatchConnectivity) && os(watchOS)
@preconcurrency import WatchConnectivity
#endif

enum WatchRelayFallbackPolicy {
    static func relayTimeout(for request: URLRequest) -> TimeInterval {
        WatchRelayTimingPolicy.relayTimeout(for: request)
    }

    static func shouldUseDirectNetwork(
        after error: WatchConnectivityRelayError,
        for request: URLRequest
    ) -> Bool {
        WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
            after: failurePhase(for: error),
            for: request
        )
    }

    static func failurePhase(
        for error: WatchConnectivityRelayError
    ) -> WatchRelayFallbackPhase {
        switch error {
        case .unsupported,
             .companionUnavailable,
             .notActivated,
             .notReachable:
            return .preDispatchUnavailable
        case .timedOut,
             .transportFailed,
             .mismatchedResponse,
             .invalidResponse,
             .responseTooLarge:
            return .outcomeUncertain
        case .remoteFailure(let code):
            return WatchRelayDirectFallbackPolicy.failurePhase(
                forRemoteErrorCode: code
            )
        case .invalidRequest,
             .requestTooLarge:
            return .definitiveFailure
        }
    }
}

struct WatchRelayRequestDeadline: Sendable {
    private let originalTimeout: TimeInterval
    private let startedAt: ContinuousClock.Instant

    init(request: URLRequest) {
        originalTimeout = request.timeoutInterval
        startedAt = ContinuousClock.now
    }

    func directFallbackRequest(from request: URLRequest) throws -> URLRequest {
        try Task.checkCancellation()
        let elapsedComponents = startedAt.duration(to: ContinuousClock.now).components
        let elapsed = max(
            0,
            TimeInterval(elapsedComponents.seconds)
                + TimeInterval(elapsedComponents.attoseconds) / 1_000_000_000_000_000_000
        )
        guard let remaining = WatchRelayTimingPolicy.remainingDirectTimeout(
            originalTimeout: originalTimeout,
            elapsed: elapsed
        ) else {
            throw URLError(.timedOut)
        }
        var directRequest = request
        directRequest.timeoutInterval = remaining
        return directRequest
    }
}

extension WatchRelayHTTPResponse {
    func urlResponse(for requestURL: URL) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            throw WatchConnectivityRelayError.invalidResponse
        }
        return response
    }
}

enum WatchConnectivityRelayError: Error, Sendable {
    case unsupported
    case companionUnavailable
    case notActivated
    case notReachable
    case invalidRequest
    case requestTooLarge
    case timedOut
    case transportFailed
    case mismatchedResponse
    case invalidResponse
    case responseTooLarge
    case remoteFailure(WatchRelayErrorCode)
}

/// Uses immediate WatchConnectivity messages only. The shared relay protocol carries
/// a gateway path and JSON body, never a gateway URL, Authorization header, cookie,
/// or Keychain value. This type also deliberately does not log messages or errors.
actor WatchConnectivityRelayClient {
    static let shared = WatchConnectivityRelayClient()

    #if canImport(WatchConnectivity) && os(watchOS)
    private let session: WCSession?
    private let sessionDelegate: WatchConnectivityRelaySessionDelegate?
    #endif

    private init() {
        #if canImport(WatchConnectivity) && os(watchOS)
        guard WCSession.isSupported() else {
            session = nil
            sessionDelegate = nil
            return
        }
        let relayDelegate = WatchConnectivityRelaySessionDelegate()
        let relaySession = WCSession.default
        relaySession.delegate = relayDelegate
        relaySession.activate()
        sessionDelegate = relayDelegate
        session = relaySession
        #endif
    }

    nonisolated static func prepare() {
        _ = shared
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        timeout: TimeInterval
    ) async throws -> WatchRelayHTTPResponse {
        try Task.checkCancellation()

        #if canImport(WatchConnectivity) && os(watchOS)
        guard let session else {
            throw WatchConnectivityRelayError.unsupported
        }
        guard session.activationState == .activated else {
            throw WatchConnectivityRelayError.notActivated
        }
        guard session.isCompanionAppInstalled else {
            throw WatchConnectivityRelayError.companionUnavailable
        }
        guard session.isReachable else {
            throw WatchConnectivityRelayError.notReachable
        }

        let responseLimit = min(
            max(maximumResponseBytes, 1),
            WatchRelayPolicy.maximumBodyBytes
        )
        let safeTimeout = min(
            max(timeout, TimeInterval(WatchRelayPolicy.minimumTimeoutMilliseconds) / 1_000),
            TimeInterval(WatchRelayPolicy.maximumTimeoutMilliseconds) / 1_000
        )
        let relayRequest = try Self.relayRequest(from: request, timeout: safeTimeout)
        let encodedRequest: Data
        do {
            encodedRequest = try WatchRelayCodec.encode(.request(relayRequest))
        } catch let protocolError as WatchRelayProtocolError {
            throw Self.requestError(from: protocolError)
        } catch {
            throw WatchConnectivityRelayError.invalidRequest
        }

        return try await Self.exchange(
            encodedRequest,
            relayRequest: relayRequest,
            maximumResponseBytes: responseLimit,
            timeout: safeTimeout,
            session: session
        )
        #else
        throw WatchConnectivityRelayError.unsupported
        #endif
    }

    private static func relayRequest(
        from request: URLRequest,
        timeout: TimeInterval
    ) throws -> WatchRelayRequest {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              request.httpBodyStream == nil,
              let gatewayOrigin = GatewayOriginNormalizer.origin(for: url) else {
            throw WatchConnectivityRelayError.invalidRequest
        }
        guard let method = WatchRelayHTTPMethod(
            rawValue: (request.httpMethod ?? "GET").uppercased()
        ) else {
            throw WatchConnectivityRelayError.invalidRequest
        }

        var safeHeaders: [String: String] = [:]
        for headerName in ["Accept", "Accept-Language", "Content-Type"] {
            if let value = request.value(forHTTPHeaderField: headerName) {
                safeHeaders[headerName] = value
            }
        }

        do {
            return try WatchRelayRequest(
                timeoutMilliseconds: Int((timeout * 1_000).rounded(.down)),
                gatewayOrigin: gatewayOrigin.absoluteString,
                method: method,
                path: components.path,
                headers: safeHeaders,
                body: request.httpBody
            )
        } catch let protocolError as WatchRelayProtocolError {
            throw requestError(from: protocolError)
        } catch {
            throw WatchConnectivityRelayError.invalidRequest
        }
    }

    private static func requestError(
        from error: WatchRelayProtocolError
    ) -> WatchConnectivityRelayError {
        switch error {
        case .messageTooLarge, .bodyTooLarge:
            return .requestTooLarge
        default:
            return .invalidRequest
        }
    }

    #if canImport(WatchConnectivity) && os(watchOS)
    private static func exchange(
        _ encodedRequest: Data,
        relayRequest: WatchRelayRequest,
        maximumResponseBytes: Int,
        timeout: TimeInterval,
        session: WCSession
    ) async throws -> WatchRelayHTTPResponse {
        let state = WatchConnectivityRelayContinuationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard !Task.isCancelled else {
                    state.finish(.failure(CancellationError()))
                    return
                }
                let didDispatch = state.dispatchIfActive {
                    session.sendMessageData(
                        encodedRequest,
                        replyHandler: { encodedResponse in
                            do {
                                let response = try Self.response(
                                    from: encodedResponse,
                                    matching: relayRequest,
                                    maximumResponseBytes: maximumResponseBytes
                                )
                                state.finish(.success(response))
                            } catch {
                                state.finish(.failure(error))
                            }
                        },
                        errorHandler: { _ in
                            state.finish(
                                .failure(WatchConnectivityRelayError.transportFailed)
                            )
                        }
                    )
                }
                guard didDispatch else { return }

                let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
                Task.detached {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    state.finish(.failure(WatchConnectivityRelayError.timedOut))
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    private static func response(
        from encodedResponse: Data,
        matching request: WatchRelayRequest,
        maximumResponseBytes: Int
    ) throws -> WatchRelayHTTPResponse {
        let message: WatchRelayMessage
        do {
            message = try WatchRelayCodec.decode(encodedResponse)
        } catch let protocolError as WatchRelayProtocolError {
            if case .messageTooLarge = protocolError {
                throw WatchConnectivityRelayError.responseTooLarge
            }
            throw WatchConnectivityRelayError.invalidResponse
        } catch {
            throw WatchConnectivityRelayError.invalidResponse
        }

        guard case .response(let relayResponse) = message,
              relayResponse.matches(request) else {
            throw WatchConnectivityRelayError.mismatchedResponse
        }
        switch relayResponse.payload {
        case .http(let response):
            guard (response.body?.count ?? 0) <= maximumResponseBytes else {
                throw WatchConnectivityRelayError.responseTooLarge
            }
            return response
        case .failure(let failure):
            throw WatchConnectivityRelayError.remoteFailure(failure.code)
        }
    }
    #endif
}

#if canImport(WatchConnectivity) && os(watchOS)
private final class WatchConnectivityRelaySessionDelegate: NSObject,
    WCSessionDelegate,
    @unchecked Sendable {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}
}
#endif

private final class WatchConnectivityRelayContinuationState: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<WatchRelayHTTPResponse, Error>?
    private var earlyResult: Result<WatchRelayHTTPResponse, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<WatchRelayHTTPResponse, Error>) {
        let result: Result<WatchRelayHTTPResponse, Error>?
        lock.lock()
        if finished {
            result = earlyResult
            earlyResult = nil
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()

        if let result {
            continuation.resume(with: result)
        }
    }

    /// Linearizes cancellation against the irreversible WatchConnectivity dispatch.
    /// If cancellation wins the lock, the operation is never invoked. Once the
    /// operation starts, a later cancellation only stops the local wait.
    func dispatchIfActive(_ operation: () -> Void) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        let isAlreadyCancelled = withUnsafeCurrentTask { task in
            task?.isCancelled == true
        }
        guard !isAlreadyCancelled else {
            lock.unlock()
            finish(.failure(CancellationError()))
            return false
        }
        operation()
        lock.unlock()
        return true
    }

    func finish(_ result: Result<WatchRelayHTTPResponse, Error>) {
        let continuation: CheckedContinuation<WatchRelayHTTPResponse, Error>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            earlyResult = result
        }
        lock.unlock()

        continuation?.resume(with: result)
    }
}
