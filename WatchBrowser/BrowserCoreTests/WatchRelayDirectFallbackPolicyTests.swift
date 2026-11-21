import Foundation
import XCTest
@testable import BrowserCore

final class WatchRelayDirectFallbackPolicyTests: XCTestCase {
    func testRemoteTransportUnavailableIsKnownPreDispatch() {
        XCTAssertEqual(
            WatchRelayDirectFallbackPolicy.failurePhase(
                forRemoteErrorCode: .transportUnavailable
            ),
            .preDispatchUnavailable
        )
    }

    func testRemotePostDispatchFailuresRemainOutcomeUncertain() {
        for code in [
            WatchRelayErrorCode.notReachable,
            .timedOut,
            .cancelled,
            .upstreamNetwork,
            .responseTooLarge
        ] {
            XCTAssertEqual(
                WatchRelayDirectFallbackPolicy.failurePhase(
                    forRemoteErrorCode: code
                ),
                .outcomeUncertain,
                "Unexpected phase for \(code.rawValue)"
            )
        }
        XCTAssertEqual(
            WatchRelayDirectFallbackPolicy.failurePhase(
                forRemoteErrorCode: .upstreamInvalidResponse
            ),
            .definitiveFailure
        )
    }

    func testRelayTimeoutUsesRouteSpecificCap() {
        XCTAssertEqual(
            WatchRelayTimingPolicy.relayTimeout(
                requestTimeout: 75,
                path: "/v1/read"
            ),
            60
        )
        XCTAssertEqual(
            WatchRelayTimingPolicy.relayTimeout(
                requestTimeout: 75,
                path: "/v1/ask"
            ),
            60
        )
        XCTAssertEqual(
            WatchRelayTimingPolicy.relayTimeout(
                requestTimeout: 75,
                path: "/v1/sessions/session-1/tap"
            ),
            40
        )
        XCTAssertEqual(
            WatchRelayTimingPolicy.relayTimeout(
                requestTimeout: 12,
                path: "/health"
            ),
            12
        )
    }

    func testDirectFallbackReceivesOnlyRemainingEndToEndBudget() {
        XCTAssertEqual(
            WatchRelayTimingPolicy.remainingDirectTimeout(
                originalTimeout: 75,
                elapsed: 60
            ),
            15
        )
        XCTAssertEqual(
            WatchRelayTimingPolicy.remainingDirectTimeout(
                originalTimeout: 35,
                elapsed: 25
            ),
            10
        )
        XCTAssertNil(
            WatchRelayTimingPolicy.remainingDirectTimeout(
                originalTimeout: 12,
                elapsed: 12
            )
        )
        XCTAssertNil(
            WatchRelayTimingPolicy.remainingDirectTimeout(
                originalTimeout: 12,
                elapsed: 13
            )
        )
    }

    func testPreDispatchUnavailableAllowsDirectFallbackForEveryCurrentRoute() {
        for request in [
            makeRequest(method: "GET", path: "/health"),
            makeRequest(method: "POST", path: "/v1/read"),
            makeRequest(method: "POST", path: "/v1/sessions/open"),
            makeRequest(method: "POST", path: "/v1/sessions/session-1/fill")
        ] {
            XCTAssertTrue(
                WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
                    after: .preDispatchUnavailable,
                    for: request
                )
            )
        }
    }

    func testPhoneLocalSessionNeverFallsBackToCloud() {
        let localSessionID = "ios_00112233445566778899aabbccddeeff"
        for (method, path) in [
            ("POST", "/v1/sessions/\(localSessionID)/tap"),
            ("POST", "/v1/sessions/\(localSessionID)/refresh"),
            ("DELETE", "/v1/sessions/\(localSessionID)")
        ] {
            XCTAssertFalse(
                WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
                    after: .preDispatchUnavailable,
                    for: makeRequest(method: method, path: path)
                )
            )
            XCTAssertFalse(
                WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
                    after: .outcomeUncertain,
                    for: makeRequest(method: method, path: path)
                )
            )
        }
        XCTAssertTrue(
            WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
                after: .preDispatchUnavailable,
                for: makeRequest(method: "POST", path: "/v1/sessions/open")
            )
        )
    }

    func testUncertainOutcomeAllowsOnlyExplicitlyReplaySafeRoutes() {
        let safeRequests = [
            makeRequest(method: "GET", path: "/health"),
            makeRequest(method: "POST", path: "/v1/read"),
            makeRequest(method: "POST", path: "/v1/ask"),
            makeRequest(method: "DELETE", path: "/v1/sessions/session-1")
        ]
        for request in safeRequests {
            XCTAssertTrue(
                WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
                    after: .outcomeUncertain,
                    for: request
                )
            )
        }
    }

    func testUncertainOutcomeNeverReplaysOpenOrSessionPostActions() {
        let unsafePaths = [
            "/v1/sessions/open",
            "/v1/sessions/session-1/tap",
            "/v1/sessions/session-1/fill",
            "/v1/sessions/session-1/scroll",
            "/v1/sessions/session-1/back",
            "/v1/sessions/session-1/refresh"
        ]
        for path in unsafePaths {
            let request = makeRequest(method: "POST", path: path)
            XCTAssertFalse(
                WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
                    after: .outcomeUncertain,
                    for: request
                ),
                "Unexpected replay permission for \(path)"
            )
        }
    }

    func testOnlyValidatedSessionDeleteIsReplaySafe() {
        XCTAssertTrue(
            WatchRelayDirectFallbackPolicy.isReplaySafe(
                method: "DELETE",
                path: "/v1/sessions/abc_123-Z"
            )
        )
        for path in [
            "/v1/sessions/",
            "/v1/sessions/session-1/refresh",
            "/v1/sessions/session.1",
            "/v1/sessions/session-1?force=true"
        ] {
            XCTAssertFalse(
                WatchRelayDirectFallbackPolicy.isReplaySafe(
                    method: "DELETE",
                    path: path
                )
            )
        }
    }

    func testDefinitiveFailureNeverUsesDirectFallback() {
        let request = makeRequest(method: "POST", path: "/v1/read")
        XCTAssertFalse(
            WatchRelayDirectFallbackPolicy.shouldUseDirectNetwork(
                after: .definitiveFailure,
                for: request
            )
        )
    }

    func testQueryOrFragmentMakesAnOtherwiseSafeRequestNonReplayable() {
        var queryRequest = makeRequest(method: "POST", path: "/v1/read?retry=true")
        XCTAssertFalse(WatchRelayDirectFallbackPolicy.isReplaySafe(queryRequest))

        queryRequest.url = URL(string: "https://gateway.example/v1/read#retry")!
        XCTAssertFalse(WatchRelayDirectFallbackPolicy.isReplaySafe(queryRequest))
    }

    private func makeRequest(method: String, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://gateway.example\(path)")!)
        request.httpMethod = method
        return request
    }
}
