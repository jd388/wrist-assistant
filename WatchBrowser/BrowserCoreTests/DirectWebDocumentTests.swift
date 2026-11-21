import Foundation
import XCTest
@testable import BrowserCore

final class DirectWebDocumentTests: XCTestCase {
    func testParsesTitleReadableBodyAndRelativeLinks() throws {
        let html = Data(
            """
            <!doctype html>
            <html>
              <head>
                <title>百度 &amp; 测试</title>
                <style>.hidden { display: none }</style>
                <script>document.body.textContent = "脚本内容"</script>
              </head>
              <body>
                <h1>搜索结果</h1>
                <p>第一段&nbsp;正文。</p>
                <noscript>不应显示</noscript>
                <a href="/news?id=1&amp;from=watch"><strong>查看</strong> 新闻</a>
                <a href="https://example.com/help">帮助</a>
              </body>
            </html>
            """.utf8
        )

        let document = try DirectWebDocumentParser.parse(
            data: html,
            responseURL: URL(string: "https://www.baidu.com/search/page")!,
            mimeType: "text/html; charset=utf-8"
        )

        XCTAssertEqual(document.title, "百度 & 测试")
        XCTAssertTrue(document.text.contains("搜索结果"))
        XCTAssertTrue(document.text.contains("第一段 正文。"))
        XCTAssertTrue(document.text.contains("查看 新闻"))
        XCTAssertFalse(document.text.contains("hidden"))
        XCTAssertFalse(document.text.contains("脚本内容"))
        XCTAssertFalse(document.text.contains("不应显示"))
        XCTAssertEqual(
            document.links,
            [
                DirectWebLink(
                    title: "查看 新闻",
                    url: URL(string: "https://www.baidu.com/news?id=1&from=watch")!
                ),
                DirectWebLink(
                    title: "帮助",
                    url: URL(string: "https://example.com/help")!
                )
            ]
        )
        XCTAssertFalse(document.isLikelyDynamic)
    }

    func testDecodesDecimalHexadecimalAndCommonNamedEntities() throws {
        let html = Data(
            """
            <html><head><title>&#x4E2D;&#25991;</title></head>
            <body><p>&lt;标签&gt; &#20013;&#x6587; &quot;测试&quot; &mdash; 完成&hellip;</p></body></html>
            """.utf8
        )

        let document = try DirectWebDocumentParser.parse(
            data: html,
            responseURL: URL(string: "https://example.com")!,
            mimeType: "text/html"
        )

        XCTAssertEqual(document.title, "中文")
        XCTAssertEqual(document.text, "<标签> 中文 \"测试\" — 完成…")
    }

    func testSupportsPlainTextAndUsesHostAsTitle() throws {
        let document = try DirectWebDocumentParser.parse(
            data: Data(" 第一行  \n\n\n第二行\t内容 ".utf8),
            responseURL: URL(string: "https://example.com/readme.txt")!,
            mimeType: "text/plain"
        )

        XCTAssertEqual(document.title, "example.com")
        XCTAssertEqual(document.text, "第一行\n\n第二行 内容")
        XCTAssertEqual(document.links, [])
        XCTAssertFalse(document.isLikelyDynamic)
        XCTAssertFalse(document.wasTruncated)
    }

    func testHonorsGB18030EncodingAndCapsVisibleText() throws {
        let encoding = String.Encoding(rawValue: 0x80000632)
        let html = "<html><head><meta charset='gb18030'><title>中文网页</title></head><body>正文内容</body></html>"
        let data = try XCTUnwrap(html.data(using: encoding))
        let decoded = try DirectWebDocumentParser.parse(
            data: data,
            responseURL: URL(string: "https://example.cn")!,
            mimeType: "text/html",
            textEncodingName: "gb18030"
        )
        XCTAssertEqual(decoded.title, "中文网页")
        XCTAssertEqual(decoded.text, "正文内容")

        let oversized = Data(String(
            repeating: "字",
            count: DirectWebDocumentParser.maximumTextCharacters + 20
        ).utf8)
        let limited = try DirectWebDocumentParser.parse(
            data: oversized,
            responseURL: URL(string: "https://example.cn/text")!,
            mimeType: "text/plain"
        )
        XCTAssertEqual(limited.text.count, DirectWebDocumentParser.maximumTextCharacters)
        XCTAssertTrue(limited.wasTruncated)
    }

    func testSniffsHTMLWhenMIMETypeIsMissing() throws {
        let document = try DirectWebDocumentParser.parse(
            data: Data("<html><body><p>可见内容</p></body></html>".utf8),
            responseURL: URL(string: "https://example.com")!,
            mimeType: nil
        )

        XCTAssertEqual(document.text, "可见内容")
    }

    func testParsesRSSSearchResultsIntoReadableLinks() throws {
        let rss = Data(
            """
            <?xml version="1.0" encoding="utf-8" ?>
            <rss version="2.0"><channel><title>Bing: 手表浏览器</title>
              <item><title>第一个结果</title><link>https://example.com/one</link><description><![CDATA[第一条 <b>摘要</b>]]></description></item>
              <item><title>第二个结果</title><link>https://example.com/two</link><description>第二条摘要</description></item>
            </channel></rss>
            """.utf8
        )
        let document = try DirectWebDocumentParser.parse(
            data: rss,
            responseURL: URL(string: "https://www.bing.com/search?q=watch&format=rss")!,
            mimeType: "text/xml",
            textEncodingName: "utf-8"
        )
        XCTAssertEqual(document.title, "Bing: 手表浏览器")
        XCTAssertTrue(document.text.contains("1. 第一个结果"))
        XCTAssertTrue(document.text.contains("第一条 摘要"))
        XCTAssertEqual(document.links.count, 2)
        XCTAssertEqual(document.links.first?.url.absoluteString, "https://example.com/one")
        XCTAssertFalse(document.isLikelyDynamic)
    }

    func testParsesSogouResultsAndOpensOriginalTargets() throws {
        let html = Data(
            """
            <html><head><title>QQ浏览器搜索</title></head><body>
              <a href="javascript:void(0)">全部</a>
              <a href="?keyword=相关搜索">相关搜索</a>
              <h3><a class="resultLink" href="./track/tc?url=https%3A%2F%2Fsupport.apple.com%2Fzh-cn%2Fguide%2Fwatch&amp;pcurl=https%3A%2F%2Fsupport.apple.com%2Fzh-cn">官方 <em>Apple Watch</em> 支持</a></h3>
              <a class="resultLink" href="./track/tc?url=https%3A%2F%2Fsupport.apple.com%2Fzh-cn%2Fguide%2Fwatch&amp;linkid=summary">重复摘要</a>
              <a class="resultLink" href="./track/tc?url=https%3A%2F%2Fexample.com%2Fnews">第二个结果</a>
            </body></html>
            """.utf8
        )
        let document = try DirectWebDocumentParser.parse(
            data: html,
            responseURL: URL(
                string: "https://m.sogou.com/web/searchList.jsp?keyword=Apple%20Watch"
            )!,
            mimeType: "text/html"
        )

        XCTAssertEqual(document.title, "“Apple Watch”的搜索结果")
        XCTAssertEqual(document.links.count, 2)
        XCTAssertEqual(document.links.first?.title, "官方 Apple Watch 支持")
        XCTAssertEqual(
            document.links.first?.url.absoluteString,
            "https://support.apple.com/zh-cn/guide/watch"
        )
        XCTAssertEqual(document.links.last?.url.absoluteString, "https://example.com/news")
        XCTAssertTrue(document.text.contains("找到 2 个可打开结果"))
        XCTAssertFalse(document.text.contains("相关搜索"))
    }

    func testReportsSogouVerificationPageWithoutSilentEmptyResult() {
        let html = Data(
            "<html><body><p>请完成验证</p><a href='/verify'>验证</a></body></html>".utf8
        )

        XCTAssertThrowsError(
            try DirectWebDocumentParser.parse(
                data: html,
                responseURL: URL(
                    string: "https://m.sogou.com/web/searchList.jsp?keyword=test"
                )!,
                mimeType: "text/html"
            )
        ) { error in
            XCTAssertEqual(error as? DirectWebDocumentError, .searchResultsUnavailable)
        }
    }

    func testSogouResultsRejectLookalikeClassesAndUnsafeTrackers() throws {
        let html = Data(
            """
            <html><body>
              <a class="notresultlink" href="./track/tc?url=https%3A%2F%2Fevil.example%2Flookalike">伪类名</a>
              <a data-note="resultLink" href="./track/tc?url=https%3A%2F%2Fevil.example%2Fdata">伪属性</a>
              <a class="resultLink" href="http://m.sogou.com/web/track/tc?url=https%3A%2F%2Fevil.example%2Finsecure">非 HTTPS 追踪</a>
              <a class="resultLink" href="./track/not-tc?url=https%3A%2F%2Fevil.example%2Fwrong-path">错误追踪路径</a>
              <a class="resultLink" href="./track/tc?pcurl=https%3A%2F%2Fevil.example%2Fpc-only">只有 pcurl</a>
              <a class="resultLink" href="./track/tc?url=https%3A%2F%2Fname%3Asecret%40evil.example%2F">目标含账号</a>
              <a class="card resultLink selected" href="./track/tc?url=https%3A%2F%2Fsafe.example%2Farticle">安全结果</a>
            </body></html>
            """.utf8
        )
        let document = try DirectWebDocumentParser.parse(
            data: html,
            responseURL: URL(
                string: "https://m.sogou.com/web/searchList.jsp?keyword=safety"
            )!,
            mimeType: "text/html"
        )

        XCTAssertEqual(
            document.links,
            [DirectWebLink(title: "安全结果", url: URL(string: "https://safe.example/article")!)]
        )
    }

    func testOrdinarySogouPageDoesNotRewriteTrackingLikeLink() throws {
        let html = Data(
            """
            <html><body><p>普通页面</p>
              <a href="/web/track/tc?url=https%3A%2F%2Fexample.com%2Foriginal">站内链接</a>
            </body></html>
            """.utf8
        )
        let document = try DirectWebDocumentParser.parse(
            data: html,
            responseURL: URL(string: "https://m.sogou.com/about")!,
            mimeType: "text/html"
        )
        XCTAssertEqual(
            document.links.first?.url.absoluteString,
            "https://m.sogou.com/web/track/tc?url=https%3A%2F%2Fexample.com%2Foriginal"
        )
    }

    func testFiltersUnsupportedLinksDeduplicatesAndCapsCount() throws {
        var anchors = [
            "<a href='javascript:alert(1)'>脚本</a>",
            "<a href='mailto:test@example.com'>邮件</a>",
            "<a href='/same'>首次</a>",
            "<a href='https://example.com/same'>重复</a>"
        ]
        anchors += (0..<(DirectWebDocumentParser.maximumLinkCount + 10)).map {
            "<a href='/item/\($0)'>项目 \($0)</a>"
        }
        let html = Data("<html><body>正文\(anchors.joined())</body></html>".utf8)

        let document = try DirectWebDocumentParser.parse(
            data: html,
            responseURL: URL(string: "https://example.com/base")!,
            mimeType: "text/html"
        )

        XCTAssertEqual(document.links.count, DirectWebDocumentParser.maximumLinkCount)
        XCTAssertEqual(document.links.first?.title, "首次")
        XCTAssertEqual(document.links.first?.url.absoluteString, "https://example.com/same")
        XCTAssertEqual(Set(document.links.map(\.url)).count, document.links.count)
    }

    func testFlagsLikelyDynamicShell() throws {
        let html = Data(
            """
            <html><head><title>应用</title></head><body>
            <div id="root"></div><script src="/bundle.js"></script>
            <p>JavaScript is required.</p>
            </body></html>
            """.utf8
        )

        let document = try DirectWebDocumentParser.parse(
            data: html,
            responseURL: URL(string: "https://example.com/app")!,
            mimeType: "text/html"
        )

        XCTAssertTrue(document.isLikelyDynamic)
    }

    func testReportsEmptyVisibleBodyClearly() {
        let html = Data(
            "<html><head><title>空页面</title></head><body><script>render()</script></body></html>".utf8
        )

        XCTAssertThrowsError(
            try DirectWebDocumentParser.parse(
                data: html,
                responseURL: URL(string: "https://example.com")!,
                mimeType: "text/html"
            )
        ) { error in
            XCTAssertEqual(error as? DirectWebDocumentError, .emptyBody)
            XCTAssertEqual(
                error.localizedDescription,
                "网页已返回，但没有可显示的正文。它可能需要 JavaScript 才能加载内容。"
            )
        }
    }

    func testRejectsUnsupportedContentTypeAndInvalidUTF8() {
        XCTAssertThrowsError(
            try DirectWebDocumentParser.parse(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                responseURL: URL(string: "https://example.com/image.png")!,
                mimeType: "image/png"
            )
        ) { error in
            XCTAssertEqual(
                error as? DirectWebDocumentError,
                .unsupportedContentType("image/png")
            )
        }

        XCTAssertThrowsError(
            try DirectWebDocumentParser.parse(
                data: Data("not an image".utf8),
                responseURL: URL(string: "https://example.com/image.png")!,
                mimeType: "image/png"
            )
        ) { error in
            XCTAssertEqual(error as? DirectWebDocumentError, .unsupportedContentType("image/png"))
        }
    }
}
