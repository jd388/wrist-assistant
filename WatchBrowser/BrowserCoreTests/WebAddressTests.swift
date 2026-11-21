import XCTest
@testable import BrowserCore

final class WebAddressTests: XCTestCase {
    func testDestinationUsesAddressWhenInputLooksLikeDomain() throws {
        let destination = try WebDestination(rawValue: "example.com/news")
        XCTAssertEqual(destination.kind, .address)
        XCTAssertEqual(destination.url.absoluteString, "https://example.com/news")
    }

    func testDestinationTurnsPlainTextIntoEncodedMobileSearch() throws {
        let destination = try WebDestination(rawValue: "Apple Watch 蜂窝网络")
        XCTAssertEqual(destination.kind, .search)
        XCTAssertEqual(destination.url.host, "m.sogou.com")
        XCTAssertEqual(destination.url.path, "/web/searchList.jsp")
        XCTAssertEqual(
            URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "keyword" })?.value,
            "Apple Watch 蜂窝网络"
        )
    }

    func testDestinationPreservesFullWidthURL() throws {
        let destination = try WebDestination(rawValue: "https：／／example.com/path")
        XCTAssertEqual(destination.kind, .address)
        XCTAssertEqual(destination.url.absoluteString, "https://example.com/path")
    }

    func testDestinationDoesNotMistakePunctuationInSearchForAddress() throws {
        for query in ["9.8和9.11哪个大", "天气:上海", "OpenAI.com 怎么用"] {
            let destination = try WebDestination(rawValue: query)
            XCTAssertEqual(destination.kind, .search, query)
            XCTAssertEqual(
                URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "keyword" })?.value,
                query
            )
        }
    }

    func testDestinationStillRecognizesDomainWithPortAndPath() throws {
        let destination = try WebDestination(rawValue: "example.com:8443/news")
        XCTAssertEqual(destination.kind, .address)
        XCTAssertEqual(destination.url.absoluteString, "https://example.com:8443/news")
    }

    func testAddsHTTPSWhenSchemeIsMissing() throws {
        let address = try WebAddress(rawValue: "baidu.com")
        XCTAssertEqual(address.url.absoluteString, "https://baidu.com")
    }

    func testPreservesPathQueryAndFragment() throws {
        let address = try WebAddress(rawValue: " https://example.com/a?q=watch#part ")
        XCTAssertEqual(address.url.absoluteString, "https://example.com/a?q=watch#part")
    }

    func testNormalizesFullWidthURLPunctuation() throws {
        let address = try WebAddress(rawValue: "https：／／example.com/path")
        XCTAssertEqual(address.url.absoluteString, "https://example.com/path")
    }

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try WebAddress(rawValue: "  \n ")) { error in
            XCTAssertEqual(error as? WebAddressError, .empty)
        }
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try WebAddress(rawValue: "file:///tmp/page.html")) { error in
            XCTAssertEqual(error as? WebAddressError, .unsupportedScheme("file"))
        }
    }

    func testRejectsMissingHost() {
        XCTAssertThrowsError(try WebAddress(rawValue: "https://")) { error in
            XCTAssertEqual(error as? WebAddressError, .missingHost)
        }
    }

    func testRejectsEmbeddedCredentials() {
        XCTAssertThrowsError(try WebAddress(rawValue: "https://name:secret@example.com")) { error in
            XCTAssertEqual(error as? WebAddressError, .embeddedCredentials)
        }
    }
}
