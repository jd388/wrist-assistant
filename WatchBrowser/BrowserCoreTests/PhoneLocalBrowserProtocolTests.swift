import Foundation
import XCTest
@testable import BrowserCore

final class PhoneLocalBrowserProtocolTests: XCTestCase {
    func testRouteClassificationKeepsCloudSessionsUpstream() {
        XCTAssertEqual(
            PhoneLocalBrowserRoute.classify(
                method: "POST",
                path: "/v1/sessions/open"
            ),
            .open
        )
        let sessionID = PhoneLocalBrowserRoute.makeSessionID(
            uuid: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )
        XCTAssertEqual(sessionID, "ios_00112233445566778899aabbccddeeff")
        XCTAssertEqual(
            PhoneLocalBrowserRoute.classify(
                method: "POST",
                path: "/v1/sessions/\(sessionID)/tap"
            ),
            .action(sessionID: sessionID, action: .tap)
        )
        XCTAssertEqual(
            PhoneLocalBrowserRoute.classify(
                method: "DELETE",
                path: "/v1/sessions/\(sessionID)"
            ),
            .close(sessionID: sessionID)
        )
        XCTAssertEqual(
            PhoneLocalBrowserRoute.classify(
                method: "POST",
                path: "/v1/sessions/cloud-session/tap"
            ),
            .upstream
        )
    }

    func testLocalSessionIDRequiresExactLowercaseHexShape() {
        XCTAssertTrue(
            PhoneLocalBrowserRoute.isLocalSessionID(
                "ios_00112233445566778899aabbccddeeff"
            )
        )
        for value in [
            "ios_0011",
            "ios_00112233445566778899AABBCCDDEEFF",
            "ios_00112233445566778899aabbccddeefg",
            "cloud_00112233445566778899aabbccddeeff"
        ] {
            XCTAssertFalse(PhoneLocalBrowserRoute.isLocalSessionID(value))
        }
    }

    func testPublicWebURLsAreNormalized() throws {
        let domain = try PhoneLocalBrowserURLPolicy.validateStructure(
            "https://Example.COM/path?q=1#part"
        )
        XCTAssertEqual(domain.host, "example.com")
        XCTAssertEqual(domain.port, 443)
        XCTAssertFalse(domain.isIPAddress)
        XCTAssertEqual(domain.url.absoluteString, "https://example.com/path?q=1#part")

        XCTAssertTrue(
            try PhoneLocalBrowserURLPolicy.validateStructure("https://8.8.8.8/")
                .isIPAddress
        )
        XCTAssertTrue(
            try PhoneLocalBrowserURLPolicy.validateStructure(
                "https://[2606:4700:4700::1111]/"
            ).isIPAddress
        )
    }

    func testPrivateReservedAndMetadataURLsAreBlocked() {
        let blocked: [(String, PhoneLocalBrowserURLPolicyError)] = [
            ("https://localhost/", .blockedHost),
            ("https://router.local/", .blockedHost),
            ("https://metadata.google.internal/", .blockedHost),
            ("https://127.0.0.1/", .nonPublicAddress),
            ("https://10.0.0.1/", .nonPublicAddress),
            ("https://100.100.100.200/", .nonPublicAddress),
            ("https://169.254.169.254/", .nonPublicAddress),
            ("https://192.168.1.1/", .nonPublicAddress),
            ("https://198.18.0.0/", .nonPublicAddress),
            ("https://198.19.255.255/", .nonPublicAddress),
            ("https://[::1]/", .nonPublicAddress),
            ("https://[fc00::1]/", .nonPublicAddress),
            ("https://[2001:db8::1]/", .nonPublicAddress),
            ("https://[::ffff:169.254.169.254]/", .nonPublicAddress)
        ]
        for (value, expectedError) in blocked {
            XCTAssertThrowsError(
                try PhoneLocalBrowserURLPolicy.validateStructure(value),
                "Expected blocked URL: \(value)"
            ) { error in
                XCTAssertEqual(
                    error as? PhoneLocalBrowserURLPolicyError,
                    expectedError,
                    "Unexpected policy error for: \(value)"
                )
            }
        }

        XCTAssertNoThrow(
            try PhoneLocalBrowserURLPolicy.validateStructure("https://198.17.255.255/")
        )
        XCTAssertNoThrow(
            try PhoneLocalBrowserURLPolicy.validateStructure("https://198.20.0.0/")
        )
    }

    func testCredentialsSchemesAndNonStandardPortsAreBlocked() {
        for value in [
            "http://example.com/",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "https://user:password@example.com/",
            "https://example.com:8443/"
        ] {
            XCTAssertThrowsError(
                try PhoneLocalBrowserURLPolicy.validateStructure(value),
                "Expected blocked URL: \(value)"
            )
        }
    }

    func testEveryResolvedAddressMustBePublic() throws {
        XCTAssertNoThrow(
            try PhoneLocalBrowserURLPolicy.validateResolvedAddresses([
                "8.8.8.8",
                "2606:4700:4700::1111"
            ])
        )
        XCTAssertThrowsError(
            try PhoneLocalBrowserURLPolicy.validateResolvedAddresses([])
        )
        XCTAssertThrowsError(
            try PhoneLocalBrowserURLPolicy.validateResolvedAddresses([
                "8.8.8.8",
                "192.168.1.1"
            ])
        )
    }

    func testSyntheticProxyRangeIsRecognizedWithoutBecomingPublic() {
        for value in [
            "198.18.0.0",
            "198.18.1.240",
            "198.19.255.255",
            "::ffff:198.18.1.240",
            "[::ffff:c612:01f0]"
        ] {
            XCTAssertTrue(
                PhoneLocalBrowserURLPolicy.isSyntheticProxyIPAddress(value),
                "Expected synthetic proxy address: \(value)"
            )
            XCTAssertFalse(
                PhoneLocalBrowserURLPolicy.isPublicIPAddress(value),
                "Synthetic proxy address must remain non-public: \(value)"
            )
        }

        for value in [
            "198.17.255.255",
            "198.20.0.0",
            "192.168.1.1",
            "8.8.8.8",
            "2606:4700:4700::1111"
        ] {
            XCTAssertFalse(
                PhoneLocalBrowserURLPolicy.isSyntheticProxyIPAddress(value),
                "Expected non-synthetic address: \(value)"
            )
        }
    }

    func testTrustedDNSFallbackRequiresOnlySyntheticSystemAnswers() {
        XCTAssertTrue(
            PhoneLocalBrowserURLPolicy.requiresTrustedDNSFallback(
                forSystemAddresses: ["198.18.1.240", "::ffff:198.18.1.241"]
            )
        )
        XCTAssertFalse(
            PhoneLocalBrowserURLPolicy.requiresTrustedDNSFallback(
                forSystemAddresses: []
            )
        )
        XCTAssertFalse(
            PhoneLocalBrowserURLPolicy.requiresTrustedDNSFallback(
                forSystemAddresses: ["198.18.1.240", "8.8.8.8"]
            )
        )
        XCTAssertFalse(
            PhoneLocalBrowserURLPolicy.requiresTrustedDNSFallback(
                forSystemAddresses: ["198.18.1.240", "192.168.1.1"]
            )
        )
    }

    func testTrustedDNSResponseValidatesDualStackAndNoData() throws {
        let a = PhoneLocalBrowserTrustedDNSResponse(
            status: 0,
            truncated: false,
            questions: [.init(name: "Example.COM.", type: 1)],
            answers: [
                .init(name: "example.com.", type: 1, ttl: 60, data: "93.184.216.34")
            ]
        )
        XCTAssertEqual(
            try a.validatedAddresses(forHost: "example.com", queryType: 1),
            ["93.184.216.34"]
        )

        let aaaa = PhoneLocalBrowserTrustedDNSResponse(
            status: 0,
            truncated: false,
            questions: [.init(name: "example.com", type: 28)],
            answers: [
                .init(
                    name: "example.com",
                    type: 28,
                    ttl: 60,
                    data: "2606:2800:220:1:248:1893:25c8:1946"
                )
            ]
        )
        XCTAssertEqual(
            try aaaa.validatedAddresses(forHost: "example.com", queryType: 28),
            ["2606:2800:220:1:248:1893:25c8:1946"]
        )

        let noData = PhoneLocalBrowserTrustedDNSResponse(
            status: 0,
            truncated: false,
            questions: [.init(name: "example.com", type: 28)],
            answers: nil
        )
        XCTAssertEqual(
            try noData.validatedAddresses(forHost: "example.com", queryType: 28),
            []
        )
    }

    func testTrustedDNSResponseValidatesBoundedCNAMEChain() throws {
        let response = PhoneLocalBrowserTrustedDNSResponse(
            status: 0,
            truncated: false,
            questions: [.init(name: "example.com", type: 1)],
            answers: [
                .init(name: "example.com", type: 5, ttl: 30, data: "edge.example.net."),
                .init(name: "edge.example.net", type: 1, ttl: 30, data: "203.0.113.10")
            ]
        )
        let addresses = try response.validatedAddresses(
            forHost: "example.com",
            queryType: 1
        )
        XCTAssertEqual(addresses, ["203.0.113.10"])
        XCTAssertThrowsError(
            try PhoneLocalBrowserURLPolicy.validateResolvedAddresses(addresses)
        )
    }

    func testTrustedDNSResponseRejectsMalformedOrUnrelatedAnswers() {
        let invalidResponses: [PhoneLocalBrowserTrustedDNSResponse] = [
            .init(
                status: 2,
                truncated: false,
                questions: [.init(name: "example.com", type: 1)],
                answers: nil
            ),
            .init(
                status: 0,
                truncated: true,
                questions: [.init(name: "example.com", type: 1)],
                answers: nil
            ),
            .init(
                status: 0,
                truncated: false,
                questions: [.init(name: "other.example", type: 1)],
                answers: nil
            ),
            .init(
                status: 0,
                truncated: false,
                questions: [.init(name: "example.com", type: 1)],
                answers: [
                    .init(name: "example.com", type: 28, ttl: 60, data: "2606:4700::1")
                ]
            ),
            .init(
                status: 0,
                truncated: false,
                questions: [.init(name: "example.com", type: 1)],
                answers: [
                    .init(name: "unrelated.example", type: 1, ttl: 60, data: "8.8.8.8")
                ]
            ),
            .init(
                status: 0,
                truncated: false,
                questions: [.init(name: "example.com", type: 1)],
                answers: [
                    .init(name: "example.com", type: 5, ttl: 60, data: "edge.example"),
                    .init(name: "edge.example", type: 5, ttl: 60, data: "example.com")
                ]
            )
        ]
        for response in invalidResponses {
            XCTAssertThrowsError(
                try response.validatedAddresses(forHost: "example.com", queryType: 1)
            )
        }
    }

    func testLocalSessionsNeverFallBackDirectly() {
        let sessionID = "ios_00112233445566778899aabbccddeeff"
        XCTAssertTrue(
            PhoneLocalBrowserRoute.requiresReachablePhone(
                method: "POST",
                path: "/v1/sessions/\(sessionID)/refresh"
            )
        )
        XCTAssertFalse(
            PhoneLocalBrowserRoute.requiresReachablePhone(
                method: "POST",
                path: "/v1/sessions/open"
            )
        )
    }
}
