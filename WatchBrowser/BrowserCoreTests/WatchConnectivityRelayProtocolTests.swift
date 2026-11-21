import XCTest
@testable import BrowserCore

final class WatchConnectivityRelayProtocolTests: XCTestCase {
    private let requestID = UUID(uuidString: "B83BE3DF-58FA-4A03-92DE-6B36ADBB19C5")!
    private let createdAt: Int64 = 1_800_000_000_000
    private let gatewayOrigin = "https://gateway.example"

    func testReadAskAndBrowserRunRequestsRoundTrip() throws {
        let cases: [(String, Data)] = [
            (
                "/v1/read",
                Data("{\"url\":\"https://example.com\",\"prefer_dynamic\":false}".utf8)
            ),
            (
                "/v1/ask",
                Data("{\"question\":\"今天有什么新闻？\",\"web_search\":true}".utf8)
            ),
            (
                "/v1/sessions/open",
                Data("{\"url\":\"https://example.com\",\"viewport_width\":396}".utf8)
            ),
            (
                "/v1/sessions/session_123/tap",
                Data("{\"x\":0.5,\"y\":0.4}".utf8)
            )
        ]

        for (path, body) in cases {
            let request = try WatchRelayRequest(
                id: requestID,
                createdAtMillisecondsSince1970: createdAt,
                gatewayOrigin: gatewayOrigin,
                method: .post,
                path: path,
                headers: ["Accept-Language": "zh-CN"],
                body: body
            )
            let encoded = try WatchRelayCodec.encode(.request(request))
            let decoded = try WatchRelayCodec.decode(
                encoded,
                nowMillisecondsSince1970: createdAt + 1
            )

            XCTAssertLessThanOrEqual(encoded.count, WatchRelayPolicy.maximumWireBytes)
            XCTAssertEqual(decoded, .request(request))
            XCTAssertEqual(request.headers["accept"], "application/json")
            XCTAssertEqual(request.headers["content-type"], "application/json")
            XCTAssertEqual(request.headers["accept-language"], "zh-CN")
        }

        let deletion = try WatchRelayRequest(
            id: requestID,
            createdAtMillisecondsSince1970: createdAt,
            gatewayOrigin: gatewayOrigin,
            method: .delete,
            path: "/v1/sessions/session-123"
        )
        XCTAssertEqual(
            try WatchRelayCodec.decode(
                WatchRelayCodec.encode(.request(deletion)),
                nowMillisecondsSince1970: createdAt + 1
            ),
            .request(deletion)
        )
    }

    func testSafeHeadersAreNormalizedAndCredentialHeadersAreRejected() throws {
        let request = try WatchRelayRequest(
            createdAtMillisecondsSince1970: createdAt,
            gatewayOrigin: gatewayOrigin,
            method: .post,
            path: "/v1/read",
            headers: [
                "ACCEPT": "application/json",
                "Content-Type": "application/json; charset=utf-8"
            ],
            body: Data("{\"url\":\"https://example.com\"}".utf8)
        )
        XCTAssertEqual(Set(request.headers.keys), ["accept", "content-type"])

        XCTAssertThrowsError(
            try WatchRelayRequest(
                createdAtMillisecondsSince1970: createdAt,
                gatewayOrigin: gatewayOrigin,
                method: .post,
                path: "/v1/read",
                headers: ["aUtHoRiZaTiOn": "Bearer must-not-cross"],
                body: Data("{\"url\":\"https://example.com\"}".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .headerNotAllowed("authorization")
            )
        }

        XCTAssertThrowsError(
            try WatchRelayRequest(
                createdAtMillisecondsSince1970: createdAt,
                gatewayOrigin: gatewayOrigin,
                method: .post,
                path: "/v1/ask",
                headers: ["Cookie": "session=secret"],
                body: Data("{\"question\":\"test\"}".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .headerNotAllowed("cookie"))
        }
    }

    func testGatewayOriginIsNormalizedAndRejectsNonOrigins() throws {
        let request = try WatchRelayRequest(
            createdAtMillisecondsSince1970: createdAt,
            gatewayOrigin: "HTTPS://Gateway.Example:443",
            method: .get,
            path: "/health"
        )
        XCTAssertEqual(request.gatewayOrigin, "https://gateway.example")
        XCTAssertTrue(request.description.contains("https://gateway.example"))

        let customPort = try WatchRelayRequest(
            createdAtMillisecondsSince1970: createdAt,
            gatewayOrigin: "https://Gateway.Example:8443",
            method: .get,
            path: "/health"
        )
        XCTAssertEqual(customPort.gatewayOrigin, "https://gateway.example:8443")

        let invalidOrigins = [
            "http://gateway.example",
            "https://user:password@gateway.example",
            "https://gateway.example/",
            "https://gateway.example/path",
            "https://gateway.example?query=1",
            "https://gateway.example#fragment",
            "https://gateway.example:0",
            " https://gateway.example"
        ]
        for origin in invalidOrigins {
            XCTAssertThrowsError(
                try WatchRelayRequest(
                    createdAtMillisecondsSince1970: createdAt,
                    gatewayOrigin: origin,
                    method: .get,
                    path: "/health"
                )
            ) { error in
                XCTAssertEqual(error as? WatchRelayProtocolError, .invalidGatewayOrigin)
            }
        }

        let oversized = "https://" + String(
            repeating: "a",
            count: WatchRelayPolicy.maximumGatewayOriginBytes
        )
        XCTAssertThrowsError(
            try WatchRelayRequest(
                createdAtMillisecondsSince1970: createdAt,
                gatewayOrigin: oversized,
                method: .get,
                path: "/health"
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .gatewayOriginTooLong(maximum: WatchRelayPolicy.maximumGatewayOriginBytes)
            )
        }
    }

    func testDecodedMessageCannotBypassGatewayOriginPolicy() throws {
        struct UnsafeRequest: Encodable {
            let id: UUID
            let created_at_ms: Int64
            let timeout_ms: Int
            let gateway_origin: String
            let method: String
            let path: String
            let headers: [String: String]
        }
        struct UnsafeEnvelope: Encodable {
            let version: Int
            let kind: String
            let request: UnsafeRequest
        }

        let unsafe = UnsafeEnvelope(
            version: WatchRelayPolicy.currentVersion,
            kind: "request",
            request: UnsafeRequest(
                id: requestID,
                created_at_ms: createdAt,
                timeout_ms: 30_000,
                gateway_origin: "https://gateway.example/hidden-path",
                method: "GET",
                path: "/health",
                headers: [:]
            )
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(unsafe)

        XCTAssertThrowsError(try WatchRelayCodec.decode(encoded)) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .invalidGatewayOrigin)
        }
        XCTAssertThrowsError(
            try WatchRelayCodec.decodeWithoutFreshnessValidation(encoded)
        ) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .invalidGatewayOrigin)
        }
    }

    func testDecodedMessageCannotBypassCredentialHeaderPolicy() throws {
        struct UnsafeRequest: Encodable {
            let id: UUID
            let created_at_ms: Int64
            let timeout_ms: Int
            let gateway_origin: String
            let method: String
            let path: String
            let headers: [String: String]
            let body: Data
        }
        struct UnsafeEnvelope: Encodable {
            let version: Int
            let kind: String
            let request: UnsafeRequest
        }

        let unsafe = UnsafeEnvelope(
            version: WatchRelayPolicy.currentVersion,
            kind: "request",
            request: UnsafeRequest(
                id: requestID,
                created_at_ms: createdAt,
                timeout_ms: 30_000,
                gateway_origin: gatewayOrigin,
                method: "POST",
                path: "/v1/read",
                headers: ["Authorization": "Bearer must-not-cross"],
                body: Data("{\"url\":\"https://example.com\"}".utf8)
            )
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(unsafe)

        XCTAssertThrowsError(try WatchRelayCodec.decode(encoded)) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .headerNotAllowed("authorization")
            )
        }
        XCTAssertThrowsError(
            try WatchRelayCodec.decodeWithoutFreshnessValidation(encoded)
        ) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .headerNotAllowed("authorization")
            )
        }
    }

    func testRequestDescriptionDoesNotExposeHeaderValuesOrBody() throws {
        let marker = "private-marker-that-must-not-be-logged"
        let request = try WatchRelayRequest(
            createdAtMillisecondsSince1970: createdAt,
            gatewayOrigin: gatewayOrigin,
            method: .post,
            path: "/v1/ask",
            headers: ["Accept-Language": marker],
            body: Data("{\"question\":\"\(marker)\"}".utf8)
        )

        XCTAssertFalse(request.description.contains(marker))
        XCTAssertTrue(request.description.contains("accept-language"))
        XCTAssertTrue(request.description.contains("bodyBytes"))
    }

    func testRouteAndJSONPoliciesRejectAnOpenProxyContract() throws {
        let body = Data("{}".utf8)
        let rejected: [(WatchRelayHTTPMethod, String)] = [
            (.post, "/v1/admin"),
            (.post, "https://example.com/v1/read"),
            (.post, "/v1/read?next=https://attacker.example"),
            (.post, "/v1/sessions/../open"),
            (.get, "/v1/read"),
            (.delete, "/v1/sessions/session-1/refresh")
        ]

        for (method, path) in rejected {
            XCTAssertThrowsError(
                try WatchRelayRequest(
                    createdAtMillisecondsSince1970: createdAt,
                    gatewayOrigin: gatewayOrigin,
                    method: method,
                    path: path,
                    body: method == .post ? body : nil
                )
            ) { error in
                guard case .pathNotAllowed = error as? WatchRelayProtocolError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        XCTAssertThrowsError(
            try WatchRelayRequest(
                createdAtMillisecondsSince1970: createdAt,
                gatewayOrigin: gatewayOrigin,
                method: .post,
                path: "/v1/read",
                body: Data("[1,2,3]".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .invalidJSONBody)
        }
    }

    func testTimeoutBoundaryAndExpiredDecode() throws {
        let request = try WatchRelayRequest(
            id: requestID,
            createdAtMillisecondsSince1970: createdAt,
            timeoutMilliseconds: 1_000,
            gatewayOrigin: gatewayOrigin,
            method: .get,
            path: "/health"
        )
        XCTAssertFalse(request.isExpired(atMillisecondsSince1970: createdAt + 999))
        XCTAssertEqual(
            request.remainingTimeoutMilliseconds(atMillisecondsSince1970: createdAt + 999),
            1
        )
        XCTAssertTrue(request.isExpired(atMillisecondsSince1970: createdAt + 1_000))
        XCTAssertEqual(
            request.remainingTimeoutMilliseconds(atMillisecondsSince1970: createdAt + 1_000),
            0
        )

        let data = try WatchRelayCodec.encode(.request(request))
        XCTAssertEqual(
            try WatchRelayCodec.decodeWithoutFreshnessValidation(data),
            .request(request)
        )
        XCTAssertNoThrow(
            try request.validateFreshness(atMillisecondsSince1970: createdAt + 999)
        )
        XCTAssertThrowsError(
            try request.validateFreshness(atMillisecondsSince1970: createdAt + 1_000)
        ) { error in
            let protocolError = error as? WatchRelayProtocolError
            XCTAssertEqual(protocolError, .requestExpired)
            XCTAssertEqual(protocolError?.errorCode, .requestExpired)
        }
        XCTAssertThrowsError(
            try WatchRelayCodec.decode(
                data,
                nowMillisecondsSince1970: createdAt + 1_000
            )
        ) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .requestExpired)
        }

        let futureRelativeNow = createdAt
            - Int64(WatchRelayPolicy.maximumClockSkewMilliseconds) - 1
        XCTAssertThrowsError(
            try request.validateFreshness(
                atMillisecondsSince1970: futureRelativeNow
            )
        ) { error in
            let protocolError = error as? WatchRelayProtocolError
            XCTAssertEqual(protocolError, .invalidTimestamp)
            XCTAssertEqual(protocolError?.errorCode, .requestRejected)
        }
        XCTAssertThrowsError(
            try WatchRelayCodec.decode(
                data,
                nowMillisecondsSince1970: futureRelativeNow
            )
        ) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .invalidTimestamp)
        }

        XCTAssertThrowsError(
            try WatchRelayRequest(
                createdAtMillisecondsSince1970: createdAt,
                timeoutMilliseconds: WatchRelayPolicy.maximumTimeoutMilliseconds + 1,
                gatewayOrigin: gatewayOrigin,
                method: .get,
                path: "/health"
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .invalidTimeout(
                    minimum: WatchRelayPolicy.minimumTimeoutMilliseconds,
                    maximum: WatchRelayPolicy.maximumTimeoutMilliseconds
                )
            )
        }
    }

    func testBodyAndWireSizeLimitsAreEnforcedBeforeTransport() throws {
        let oversizedBody = Data(repeating: 0x20, count: WatchRelayPolicy.maximumBodyBytes + 1)
        XCTAssertThrowsError(
            try WatchRelayRequest(
                createdAtMillisecondsSince1970: createdAt,
                gatewayOrigin: gatewayOrigin,
                method: .post,
                path: "/v1/ask",
                body: oversizedBody
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .bodyTooLarge(maximum: WatchRelayPolicy.maximumBodyBytes)
            )
        }

        let oversizedWire = Data(
            repeating: 0,
            count: WatchRelayPolicy.maximumWireBytes + 1
        )
        XCTAssertThrowsError(try WatchRelayCodec.decode(oversizedWire)) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .messageTooLarge(maximum: WatchRelayPolicy.maximumWireBytes)
            )
        }


        XCTAssertThrowsError(
            try WatchRelayHTTPResponse(statusCode: 200, body: oversizedBody)
        ) { error in
            XCTAssertEqual(
                error as? WatchRelayProtocolError,
                .responseTooLarge(maximum: WatchRelayPolicy.maximumBodyBytes)
            )
            XCTAssertEqual(
                (error as? WatchRelayProtocolError)?.errorCode,
                .responseTooLarge
            )
        }
    }

    func testHTTPAndFailureResponsesKeepRequestIDAndStableErrorCode() throws {
        let request = try WatchRelayRequest(
            id: requestID,
            createdAtMillisecondsSince1970: createdAt,
            gatewayOrigin: gatewayOrigin,
            method: .get,
            path: "/health"
        )
        let http = try WatchRelayHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"status\":\"ok\"}".utf8)
        )
        let response = WatchRelayResponse(requestID: requestID, payload: .http(http))
        XCTAssertTrue(response.matches(request))
        XCTAssertEqual(
            try WatchRelayCodec.decode(WatchRelayCodec.encode(.response(response))),
            .response(response)
        )

        let failure = try WatchRelayFailure(
            code: .timedOut,
            message: "iPhone 中继请求超时。",
            retryable: true
        )
        let failedResponse = WatchRelayResponse(
            requestID: requestID,
            payload: .failure(failure)
        )
        XCTAssertEqual(
            try WatchRelayCodec.decode(WatchRelayCodec.encode(.response(failedResponse))),
            .response(failedResponse)
        )
        XCTAssertFalse(failure.description.contains(failure.message))
        XCTAssertEqual(failure.code.rawValue, "timed_out")
    }

    func testMalformedAndUnsupportedVersionsReturnProtocolErrors() throws {
        XCTAssertThrowsError(try WatchRelayCodec.decode(Data("not a plist".utf8))) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .malformedMessage)
        }

        struct UnsupportedEnvelope: Encodable {
            let version: Int
            let kind: String
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let unsupported = try encoder.encode(
            UnsupportedEnvelope(version: 99, kind: "request")
        )
        XCTAssertThrowsError(try WatchRelayCodec.decode(unsupported)) { error in
            XCTAssertEqual(error as? WatchRelayProtocolError, .unsupportedVersion(99))
        }
    }
}
