#if DEBUG
import Foundation
import ImageIO

/// DEBUG-only, opt-in acceptance coverage for the complete iPhone-local browser
/// path. Every operation is encoded exactly like a Watch request and enters via
/// `PhoneRelayService.handle`; the probe never calls WebKit directly.
enum PhoneBrowserAcceptanceProbe {
    typealias Relay = @Sendable (Data) async -> Data

    private static let identifierEnvironmentKey = "WRIST_PHONE_BROWSER_PROBE_ID"
    private static let urlEnvironmentKey = "WRIST_PHONE_BROWSER_PROBE_URL"
    private static let defaultFixtureURL =
        "https://example.com/"
    private static let fixturePath = "/support/browser-fixture"
    private static let isolatedProbeOrigin = "https://local-probe.invalid"

    static var isRequested: Bool {
        guard let raw = ProcessInfo.processInfo.environment[identifierEnvironmentKey] else {
            return false
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func runIfRequested(relay: @escaping Relay) async {
        let environment = ProcessInfo.processInfo.environment
        guard let rawIdentifier = environment[identifierEnvironmentKey],
              !rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let safeIdentifier = safeFileIdentifier(rawIdentifier)

        let acknowledgement: PhoneBrowserProbeAcknowledgement
        do {
            let configuration = try configuration(
                rawURL: environment[urlEnvironmentKey] ?? defaultFixtureURL
            )
            let runner = PhoneBrowserProbeRunner(
                configuration: configuration,
                relay: relay
            )
            acknowledgement = await runner.execute()
        } catch {
            acknowledgement = PhoneBrowserProbeMetrics().acknowledgement(
                status: "failed",
                failureStep: .configuration,
                failureCode: .invalidConfiguration
            )
        }
        writeAcknowledgement(acknowledgement, safeIdentifier: safeIdentifier)
    }

    private static func configuration(rawURL: String) throws -> PhoneBrowserProbeConfiguration {
        let validated = try PhoneLocalBrowserURLPolicy.validateStructure(rawURL)
        guard validated.url.path == fixturePath,
              validated.url.query == nil,
              validated.url.fragment == nil else {
            throw PhoneBrowserProbeFailure(
                step: .configuration,
                code: .invalidConfiguration
            )
        }
        return PhoneBrowserProbeConfiguration(
            fixtureURL: validated.url,
            // This deliberate origin mismatch makes cloud fallback impossible
            // even when the simulator/device already has a real gateway token.
            gatewayOrigin: isolatedProbeOrigin
        )
    }

    private static func safeFileIdentifier(_ rawValue: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        let value = rawValue.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        let limited = String(value.prefix(64))
        return limited.isEmpty ? "probe" : limited
    }

    private static func writeAcknowledgement(
        _ acknowledgement: PhoneBrowserProbeAcknowledgement,
        safeIdentifier: String
    ) {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return
        }
        let destination = caches.appendingPathComponent(
            "phone-browser-probe-ack-\(safeIdentifier).json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(acknowledgement) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}

private struct PhoneBrowserProbeConfiguration: Sendable {
    let fixtureURL: URL
    let gatewayOrigin: String
}

private enum PhoneBrowserProbeStep: String, Encodable, Sendable {
    case configuration
    case open
    case scrollDown = "scroll_down"
    case scrollUp = "scroll_up"
    case tapInput = "tap_input"
    case fillSubmit = "fill_submit"
    case backAfterSubmit = "back_after_submit"
    case tapLink = "tap_link"
    case backAfterLink = "back_after_link"
    case refresh
    case close
}

private enum PhoneBrowserProbeFailureCode: String, Encodable, Sendable {
    case invalidConfiguration = "invalid_configuration"
    case requestProtocol = "request_protocol"
    case responseProtocol = "response_protocol"
    case relayFailure = "relay_failure"
    case unexpectedHTTPStatus = "unexpected_http_status"
    case foregroundTimeout = "foreground_timeout"
    case invalidJSONShape = "invalid_json_shape"
    case invalidSession = "invalid_session"
    case invalidSequence = "invalid_sequence"
    case invalidURL = "invalid_url"
    case invalidTitle = "invalid_title"
    case invalidNavigationState = "invalid_navigation_state"
    case invalidJPEG = "invalid_jpeg"
    case invalidScroll = "invalid_scroll"
    case invalidFocus = "invalid_focus"
    case invalidClose = "invalid_close"
}

private struct PhoneBrowserProbeFailure: Error, Sendable {
    let step: PhoneBrowserProbeStep
    let code: PhoneBrowserProbeFailureCode
}

private struct PhoneBrowserProbeFrame: Decodable, Sendable {
    let sessionID: String
    let sequence: UInt64
    let url: String
    let title: String
    let canGoBack: Bool
    let scrollProgress: Double
    let imageBase64: String
    let message: String
    let focusedInput: Bool
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

private struct PhoneBrowserProbeAcknowledgement: Encodable, Sendable {
    let schemaVersion: Int
    let status: String
    let completedAtMillisecondsSince1970: Int64
    let requestCount: Int
    let frameCount: Int
    let firstSequence: UInt64?
    let lastSequence: UInt64?
    let maximumBodyBytes: Int
    let maximumWireBytes: Int
    let jpegFrameCount: Int
    let minimumJPEGWidthPixels: Int
    let minimumJPEGHeightPixels: Int
    let urlValidationCount: Int
    let titleValidationCount: Int
    let scrollRoundTripObserved: Bool
    let focusedInputObserved: Bool
    let failureHTTPStatus: Int?
    let failureBackendCode: String?
    let failureURLComponent: String?
    let failureStep: PhoneBrowserProbeStep?
    let failureCode: PhoneBrowserProbeFailureCode?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case completedAtMillisecondsSince1970 = "completed_at_ms"
        case requestCount = "request_count"
        case frameCount = "frame_count"
        case firstSequence = "first_sequence"
        case lastSequence = "last_sequence"
        case maximumBodyBytes = "maximum_body_bytes"
        case maximumWireBytes = "maximum_wire_bytes"
        case jpegFrameCount = "jpeg_frame_count"
        case minimumJPEGWidthPixels = "minimum_jpeg_width_pixels"
        case minimumJPEGHeightPixels = "minimum_jpeg_height_pixels"
        case urlValidationCount = "url_validation_count"
        case titleValidationCount = "title_validation_count"
        case scrollRoundTripObserved = "scroll_round_trip_observed"
        case focusedInputObserved = "focused_input_observed"
        case failureHTTPStatus = "failure_http_status"
        case failureBackendCode = "failure_backend_code"
        case failureURLComponent = "failure_url_component"
        case failureStep = "failure_step"
        case failureCode = "failure_code"
    }
}

private struct PhoneBrowserProbeMetrics: Sendable {
    var requestCount = 0
    var frameCount = 0
    var firstSequence: UInt64?
    var lastSequence: UInt64?
    var maximumBodyBytes = 0
    var maximumWireBytes = 0
    var jpegFrameCount = 0
    var minimumJPEGWidthPixels = Int.max
    var minimumJPEGHeightPixels = Int.max
    var urlValidationCount = 0
    var titleValidationCount = 0
    var scrollRoundTripObserved = false
    var focusedInputObserved = false
    var failureHTTPStatus: Int?
    var failureBackendCode: String?
    var failureURLComponent: String?

    func acknowledgement(
        status: String,
        failureStep: PhoneBrowserProbeStep? = nil,
        failureCode: PhoneBrowserProbeFailureCode? = nil
    ) -> PhoneBrowserProbeAcknowledgement {
        PhoneBrowserProbeAcknowledgement(
            schemaVersion: 1,
            status: status,
            completedAtMillisecondsSince1970: WatchRelayPolicy.millisecondsSince1970(),
            requestCount: requestCount,
            frameCount: frameCount,
            firstSequence: firstSequence,
            lastSequence: lastSequence,
            maximumBodyBytes: maximumBodyBytes,
            maximumWireBytes: maximumWireBytes,
            jpegFrameCount: jpegFrameCount,
            minimumJPEGWidthPixels: minimumJPEGWidthPixels == Int.max
                ? 0 : minimumJPEGWidthPixels,
            minimumJPEGHeightPixels: minimumJPEGHeightPixels == Int.max
                ? 0 : minimumJPEGHeightPixels,
            urlValidationCount: urlValidationCount,
            titleValidationCount: titleValidationCount,
            scrollRoundTripObserved: scrollRoundTripObserved,
            focusedInputObserved: focusedInputObserved,
            failureHTTPStatus: failureHTTPStatus,
            failureBackendCode: failureBackendCode,
            failureURLComponent: failureURLComponent,
            failureStep: failureStep,
            failureCode: failureCode
        )
    }
}

private enum PhoneBrowserProbePageState: Sendable {
    case base
    case submitted
    case pageTwo
}

private actor PhoneBrowserProbeRunner {
    private static let viewportWidth = 320
    private static let viewportHeight = 480
    private static let submittedValue = "probe-ok"
    private static let frameKeys: Set<String> = [
        "session_id", "sequence", "url", "title", "can_go_back",
        "scroll_progress", "image_base64", "message", "focused_input",
        "focused_input_label"
    ]
    private static let requiredFrameKeys = frameKeys.subtracting(["focused_input_label"])

    private let configuration: PhoneBrowserProbeConfiguration
    private let relay: PhoneBrowserAcceptanceProbe.Relay
    private var metrics = PhoneBrowserProbeMetrics()
    private var sessionID: String?

    init(
        configuration: PhoneBrowserProbeConfiguration,
        relay: @escaping PhoneBrowserAcceptanceProbe.Relay
    ) {
        self.configuration = configuration
        self.relay = relay
    }

    func execute() async -> PhoneBrowserProbeAcknowledgement {
        do {
            try await runActions()
            return metrics.acknowledgement(status: "passed")
        } catch let failure as PhoneBrowserProbeFailure {
            await closeAfterFailureIfNeeded()
            return metrics.acknowledgement(
                status: "failed",
                failureStep: failure.step,
                failureCode: failure.code
            )
        } catch {
            await closeAfterFailureIfNeeded()
            return metrics.acknowledgement(
                status: "failed",
                failureStep: .open,
                failureCode: .responseProtocol
            )
        }
    }

    private func runActions() async throws {
        let openFrame = try await openWhenForegroundReady()

        let downFrame = try await actionFrame(
            .scrollDown,
            action: .scroll,
            body: ["amount": 1.0],
            pageState: .base,
            canGoBack: false
        )
        let upFrame = try await actionFrame(
            .scrollUp,
            action: .scroll,
            body: ["amount": -1.0],
            pageState: .base,
            canGoBack: false
        )
        guard downFrame.scrollProgress > openFrame.scrollProgress + 0.05,
              upFrame.scrollProgress < downFrame.scrollProgress - 0.05,
              abs(upFrame.scrollProgress - openFrame.scrollProgress) <= 0.03 else {
            throw PhoneBrowserProbeFailure(step: .scrollUp, code: .invalidScroll)
        }
        metrics.scrollRoundTripObserved = true

        let focusedFrame = try await actionFrame(
            .tapInput,
            action: .tap,
            body: ["x": 0.25, "y": 0.22],
            pageState: .base,
            canGoBack: false
        )
        guard focusedFrame.focusedInput,
              focusedFrame.focusedInputLabel == "验收输入框" else {
            throw PhoneBrowserProbeFailure(step: .tapInput, code: .invalidFocus)
        }
        metrics.focusedInputObserved = true

        _ = try await actionFrame(
            .fillSubmit,
            action: .fill,
            body: ["text": Self.submittedValue, "submit": true],
            pageState: .submitted,
            canGoBack: true
        )
        _ = try await actionFrame(
            .backAfterSubmit,
            action: .back,
            body: [:],
            pageState: .base,
            canGoBack: false
        )
        _ = try await actionFrame(
            .tapLink,
            action: .tap,
            body: ["x": 0.5, "y": 0.325],
            pageState: .pageTwo,
            canGoBack: true
        )
        _ = try await actionFrame(
            .backAfterLink,
            action: .back,
            body: [:],
            pageState: .base,
            canGoBack: false
        )
        _ = try await actionFrame(
            .refresh,
            action: .refresh,
            body: [:],
            pageState: .base,
            canGoBack: false
        )
        try await close()
    }

    private func openWhenForegroundReady() async throws -> PhoneBrowserProbeFrame {
        let body: [String: Any] = [
            "url": configuration.fixtureURL.absoluteString,
            "viewport_width": Self.viewportWidth,
            "viewport_height": Self.viewportHeight
        ]
        for attempt in 0..<50 {
            let response = try await exchange(
                step: .open,
                method: .post,
                path: "/v1/sessions/open",
                body: try jsonBody(body, step: .open)
            )
            if response.statusCode == 200 {
                return try validateFrame(
                    response,
                    step: .open,
                    pageState: .base,
                    canGoBack: false
                )
            }
            if response.statusCode == 503,
               localErrorCode(response) == "local_foreground_required",
               attempt < 49 {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            metrics.failureHTTPStatus = response.statusCode
            metrics.failureBackendCode = localErrorCode(response)
            throw PhoneBrowserProbeFailure(
                step: .open,
                code: attempt == 49 ? .foregroundTimeout : .unexpectedHTTPStatus
            )
        }
        throw PhoneBrowserProbeFailure(step: .open, code: .foregroundTimeout)
    }

    private func actionFrame(
        _ step: PhoneBrowserProbeStep,
        action: PhoneLocalBrowserAction,
        body: [String: Any],
        pageState: PhoneBrowserProbePageState,
        canGoBack: Bool
    ) async throws -> PhoneBrowserProbeFrame {
        guard let sessionID else {
            throw PhoneBrowserProbeFailure(step: step, code: .invalidSession)
        }
        let response = try await exchange(
            step: step,
            method: .post,
            path: "/v1/sessions/\(sessionID)/\(action.rawValue)",
            body: try jsonBody(body, step: step)
        )
        guard response.statusCode == 200 else {
            metrics.failureHTTPStatus = response.statusCode
            metrics.failureBackendCode = localErrorCode(response)
            throw PhoneBrowserProbeFailure(step: step, code: .unexpectedHTTPStatus)
        }
        return try validateFrame(
            response,
            step: step,
            pageState: pageState,
            canGoBack: canGoBack
        )
    }

    private func close() async throws {
        guard let sessionID else {
            throw PhoneBrowserProbeFailure(step: .close, code: .invalidSession)
        }
        let response = try await exchange(
            step: .close,
            method: .delete,
            path: "/v1/sessions/\(sessionID)",
            body: nil
        )
        guard response.statusCode == 204, response.body == nil else {
            metrics.failureHTTPStatus = response.statusCode
            metrics.failureBackendCode = localErrorCode(response)
            throw PhoneBrowserProbeFailure(step: .close, code: .invalidClose)
        }
        self.sessionID = nil
    }

    private func closeAfterFailureIfNeeded() async {
        guard let sessionID else { return }
        _ = try? await exchange(
            step: .close,
            method: .delete,
            path: "/v1/sessions/\(sessionID)",
            body: nil
        )
        self.sessionID = nil
    }

    private func exchange(
        step: PhoneBrowserProbeStep,
        method: WatchRelayHTTPMethod,
        path: String,
        body: Data?
    ) async throws -> WatchRelayHTTPResponse {
        let request: WatchRelayRequest
        do {
            request = try WatchRelayRequest(
                timeoutMilliseconds: 40_000,
                gatewayOrigin: configuration.gatewayOrigin,
                method: method,
                path: path,
                body: body
            )
        } catch {
            throw PhoneBrowserProbeFailure(step: step, code: .requestProtocol)
        }
        guard (body?.count ?? 0) <= WatchRelayPolicy.maximumBodyBytes else {
            throw PhoneBrowserProbeFailure(step: step, code: .requestProtocol)
        }

        let encodedRequest: Data
        do {
            encodedRequest = try WatchRelayCodec.encode(.request(request))
        } catch {
            throw PhoneBrowserProbeFailure(step: step, code: .requestProtocol)
        }
        guard encodedRequest.count <= WatchRelayPolicy.maximumWireBytes else {
            throw PhoneBrowserProbeFailure(step: step, code: .requestProtocol)
        }
        metrics.requestCount += 1
        metrics.maximumBodyBytes = max(metrics.maximumBodyBytes, body?.count ?? 0)
        metrics.maximumWireBytes = max(metrics.maximumWireBytes, encodedRequest.count)

        let encodedResponse = await relay(encodedRequest)
        guard !encodedResponse.isEmpty,
              encodedResponse.count <= WatchRelayPolicy.maximumWireBytes else {
            throw PhoneBrowserProbeFailure(step: step, code: .responseProtocol)
        }
        metrics.maximumWireBytes = max(metrics.maximumWireBytes, encodedResponse.count)

        let message: WatchRelayMessage
        do {
            message = try WatchRelayCodec.decodeWithoutFreshnessValidation(encodedResponse)
        } catch {
            throw PhoneBrowserProbeFailure(step: step, code: .responseProtocol)
        }
        guard case .response(let relayResponse) = message,
              relayResponse.requestID == request.id else {
            throw PhoneBrowserProbeFailure(step: step, code: .responseProtocol)
        }
        switch relayResponse.payload {
        case .failure:
            throw PhoneBrowserProbeFailure(step: step, code: .relayFailure)
        case .http(let response):
            let responseBodyBytes = response.body?.count ?? 0
            guard responseBodyBytes <= WatchRelayPolicy.maximumBodyBytes else {
                throw PhoneBrowserProbeFailure(step: step, code: .responseProtocol)
            }
            metrics.maximumBodyBytes = max(metrics.maximumBodyBytes, responseBodyBytes)
            return response
        }
    }

    private func validateFrame(
        _ response: WatchRelayHTTPResponse,
        step: PhoneBrowserProbeStep,
        pageState: PhoneBrowserProbePageState,
        canGoBack: Bool
    ) throws -> PhoneBrowserProbeFrame {
        guard response.statusCode == 200,
              response.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let body = response.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw PhoneBrowserProbeFailure(step: step, code: .invalidJSONShape)
        }
        let keys = Set(object.keys)
        guard keys.isSubset(of: Self.frameKeys),
              Self.requiredFrameKeys.isSubset(of: keys),
              let frame = try? JSONDecoder().decode(PhoneBrowserProbeFrame.self, from: body),
              frame.scrollProgress.isFinite,
              (0...1).contains(frame.scrollProgress),
              !frame.message.isEmpty else {
            throw PhoneBrowserProbeFailure(step: step, code: .invalidJSONShape)
        }

        if let sessionID {
            guard frame.sessionID == sessionID else {
                throw PhoneBrowserProbeFailure(step: step, code: .invalidSession)
            }
        } else {
            guard PhoneLocalBrowserRoute.isLocalSessionID(frame.sessionID) else {
                throw PhoneBrowserProbeFailure(step: step, code: .invalidSession)
            }
            sessionID = frame.sessionID
        }

        let expectedSequence = (metrics.lastSequence ?? 0) + 1
        guard frame.sequence == expectedSequence else {
            throw PhoneBrowserProbeFailure(step: step, code: .invalidSequence)
        }
        guard frame.canGoBack == canGoBack else {
            throw PhoneBrowserProbeFailure(step: step, code: .invalidNavigationState)
        }
        try validateURL(frame.url, step: step, pageState: pageState)
        try validateTitle(frame.title, step: step, pageState: pageState)
        let pixels = try validateJPEG(frame.imageBase64, step: step)

        metrics.firstSequence = metrics.firstSequence ?? frame.sequence
        metrics.lastSequence = frame.sequence
        metrics.frameCount += 1
        metrics.jpegFrameCount += 1
        metrics.minimumJPEGWidthPixels = min(metrics.minimumJPEGWidthPixels, pixels.width)
        metrics.minimumJPEGHeightPixels = min(metrics.minimumJPEGHeightPixels, pixels.height)
        metrics.urlValidationCount += 1
        metrics.titleValidationCount += 1
        return frame
    }

    private func validateURL(
        _ rawURL: String,
        step: PhoneBrowserProbeStep,
        pageState: PhoneBrowserProbePageState
    ) throws {
        guard let actual = URLComponents(string: rawURL),
              let expected = URLComponents(
                url: configuration.fixtureURL,
                resolvingAgainstBaseURL: false
              ) else {
            metrics.failureURLComponent = "parse"
            throw PhoneBrowserProbeFailure(step: step, code: .invalidURL)
        }
        guard actual.scheme?.lowercased() == expected.scheme?.lowercased(),
              actual.host?.lowercased() == expected.host?.lowercased(),
              (actual.port ?? 443) == (expected.port ?? 443) else {
            metrics.failureURLComponent = "origin"
            throw PhoneBrowserProbeFailure(step: step, code: .invalidURL)
        }
        guard actual.path == expected.path else {
            metrics.failureURLComponent = "path"
            throw PhoneBrowserProbeFailure(step: step, code: .invalidURL)
        }
        guard actual.user == nil,
              actual.password == nil,
              actual.fragment == nil else {
            metrics.failureURLComponent = "credentials_or_fragment"
            throw PhoneBrowserProbeFailure(step: step, code: .invalidURL)
        }
        let expectedQuery: [URLQueryItem]
        switch pageState {
        case .base:
            expectedQuery = []
        case .submitted:
            expectedQuery = [URLQueryItem(name: "q", value: Self.submittedValue)]
        case .pageTwo:
            expectedQuery = [URLQueryItem(name: "page", value: "2")]
        }
        let actualQuery = actual.queryItems ?? []
        guard actualQuery.count == expectedQuery.count else {
            metrics.failureURLComponent = "query_count_\(min(actualQuery.count, 9))"
            throw PhoneBrowserProbeFailure(step: step, code: .invalidURL)
        }
        guard actualQuery.map(\.name) == expectedQuery.map(\.name) else {
            metrics.failureURLComponent = "query_name"
            throw PhoneBrowserProbeFailure(step: step, code: .invalidURL)
        }
        guard actualQuery == expectedQuery else {
            metrics.failureURLComponent = "query_value"
            throw PhoneBrowserProbeFailure(step: step, code: .invalidURL)
        }
    }

    private func validateTitle(
        _ title: String,
        step: PhoneBrowserProbeStep,
        pageState: PhoneBrowserProbePageState
    ) throws {
        let expected: String
        switch pageState {
        case .base:
            expected = "WatchBrowser 验收页 1"
        case .submitted:
            expected = "WatchBrowser 查询 \(Self.submittedValue)"
        case .pageTwo:
            expected = "WatchBrowser 验收页 2"
        }
        guard title == expected else {
            throw PhoneBrowserProbeFailure(step: step, code: .invalidTitle)
        }
    }

    private func validateJPEG(
        _ base64: String,
        step: PhoneBrowserProbeStep
    ) throws -> (width: Int, height: Int) {
        guard let data = Data(base64Encoded: base64),
              data.count >= 5,
              data.starts(with: [0xff, 0xd8, 0xff]),
              data.suffix(2).elementsEqual([0xff, 0xd9]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0 else {
            throw PhoneBrowserProbeFailure(step: step, code: .invalidJPEG)
        }
        return (image.width, image.height)
    }

    private func localErrorCode(_ response: WatchRelayHTTPResponse) -> String? {
        guard let body = response.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys).isSubset(of: ["code", "message", "retryable"]),
              let code = object["code"] as? String else {
            return nil
        }
        return code
    }

    private func jsonBody(
        _ object: [String: Any],
        step: PhoneBrowserProbeStep
    ) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw PhoneBrowserProbeFailure(step: step, code: .requestProtocol)
        }
    }
}
#endif
