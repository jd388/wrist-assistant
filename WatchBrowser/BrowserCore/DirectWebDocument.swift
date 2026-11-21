import Foundation

public struct DirectWebLink: Equatable, Sendable {
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

public struct DirectWebDocument: Equatable, Sendable {
    public let title: String
    public let text: String
    public let links: [DirectWebLink]
    public let isLikelyDynamic: Bool
    public let wasTruncated: Bool

    public init(
        title: String,
        text: String,
        links: [DirectWebLink],
        isLikelyDynamic: Bool,
        wasTruncated: Bool = false
    ) {
        self.title = title
        self.text = text
        self.links = links
        self.isLikelyDynamic = isLikelyDynamic
        self.wasTruncated = wasTruncated
    }
}

public enum DirectWebDocumentError: LocalizedError, Equatable, Sendable {
    case unsupportedContentType(String)
    case invalidUTF8
    case emptyBody
    case searchResultsUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedContentType(let contentType):
            return "当前页面类型（\(contentType)）不是可读取的网页或纯文本。"
        case .invalidUTF8:
            return "无法识别网页文字编码。可以尝试系统网页模式。"
        case .emptyBody:
            return "网页已返回，但没有可显示的正文。它可能需要 JavaScript 才能加载内容。"
        case .searchResultsUnavailable:
            return "搜索服务没有返回可打开的结果，可能要求验证。请重试或换一个搜索词。"
        }
    }
}

public enum DirectWebDocumentParser {
    public static let maximumLinkCount = 40
    public static let maximumTextCharacters = 60_000

    public static func parse(
        data: Data,
        responseURL: URL,
        mimeType: String?,
        textEncodingName: String? = nil
    ) throws -> DirectWebDocument {
        let contentType = normalizedContentType(mimeType)
        if let contentType,
           !isHTML(contentType),
           !isPlainText(contentType),
           !isXML(contentType) {
            throw DirectWebDocumentError.unsupportedContentType(contentType)
        }

        guard var source = decodedString(data, declaredEncoding: textEncodingName) else {
            throw DirectWebDocumentError.invalidUTF8
        }

        if source.first == "\u{FEFF}" {
            source.removeFirst()
        }

        let shouldParseAsXML = contentType.map(isXML) ?? looksLikeRSS(source)
        if shouldParseAsXML, looksLikeRSS(source) {
            return try parseRSS(source, responseURL: responseURL)
        }

        let shouldParseAsHTML = contentType.map(isHTML) ?? looksLikeHTML(source)
        if !shouldParseAsHTML {
            let limited = limitedText(normalizedVisibleText(source))
            let text = limited.text
            guard !text.isEmpty else {
                throw DirectWebDocumentError.emptyBody
            }

            return DirectWebDocument(
                title: fallbackTitle(for: responseURL),
                text: text,
                links: [],
                isLikelyDynamic: false,
                wasTruncated: limited.wasTruncated
            )
        }

        return try parseHTML(source, responseURL: responseURL)
    }
}

private extension DirectWebDocumentParser {
    static func parseHTML(_ source: String, responseURL: URL) throws -> DirectWebDocument {
        let withoutComments = replacingMatches(
            in: source,
            pattern: #"(?is)<!--.*?-->"#,
            with: ""
        )
        let withoutExecutableContent = ["script", "style", "noscript"].reduce(withoutComments) {
            removingElement(named: $1, from: $0)
        }

        if isSogouSearchURL(responseURL) {
            return try parseSogouSearch(withoutExecutableContent, responseURL: responseURL)
        }

        let title = firstCapture(
            in: withoutExecutableContent,
            pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#
        )
        .map { normalizedVisibleText(decodeHTMLEntities(stripTags(from: $0))) }
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? fallbackTitle(for: responseURL)

        let bodySource = firstCapture(
            in: withoutExecutableContent,
            pattern: #"(?is)<body\b[^>]*>(.*?)</body\s*>"#
        ) ?? removingElement(named: "head", from: withoutExecutableContent)

        let links = extractLinks(from: bodySource, responseURL: responseURL)
        let visible = visibleText(fromHTML: bodySource)
        let limited = limitedText(visible)
        let text = limited.text

        guard !text.isEmpty else {
            throw DirectWebDocumentError.emptyBody
        }

        return DirectWebDocument(
            title: title,
            text: text,
            links: links,
            isLikelyDynamic: likelyRequiresJavaScript(source: source, visibleText: text),
            wasTruncated: limited.wasTruncated
        )
    }

    static func decodedString(_ data: Data, declaredEncoding: String?) -> String? {
        var encodings: [String.Encoding] = []
        if let declaredEncoding, let encoding = encoding(named: declaredEncoding) {
            encodings.append(encoding)
        }

        if let prefix = String(data: data.prefix(4_096), encoding: .isoLatin1),
           let charset = firstCapture(
               in: prefix,
               pattern: #"(?is)charset\s*=\s*[\"']?\s*([A-Za-z0-9._-]+)"#
           ),
           let encoding = encoding(named: charset) {
            encodings.append(encoding)
        }

        encodings.append(contentsOf: [.utf8, String.Encoding(rawValue: 0x80000632)])
        var seen = Set<UInt>()
        for encoding in encodings where seen.insert(encoding.rawValue).inserted {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        return nil
    }

    static func encoding(named rawName: String) -> String.Encoding? {
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch name {
        case "utf-8", "utf8":
            return .utf8
        case "us-ascii", "ascii":
            return .ascii
        case "iso-8859-1", "latin1", "iso-latin-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "gbk", "gb2312", "gb18030", "gb-18030":
            return String.Encoding(rawValue: 0x80000632)
        case "shift_jis", "shift-jis", "sjis":
            return .shiftJIS
        default:
            return nil
        }
    }

    static func limitedText(_ text: String) -> (text: String, wasTruncated: Bool) {
        guard text.count > maximumTextCharacters else {
            return (text, false)
        }
        return (String(text.prefix(maximumTextCharacters)), true)
    }

    static func normalizedContentType(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let value = mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return value.isEmpty ? nil : value
    }

    static func isHTML(_ contentType: String) -> Bool {
        contentType == "text/html" || contentType == "application/xhtml+xml"
    }

    static func isPlainText(_ contentType: String) -> Bool {
        contentType == "text/plain"
    }

    static func isXML(_ contentType: String) -> Bool {
        contentType == "text/xml"
            || contentType == "application/xml"
            || contentType == "application/rss+xml"
            || contentType == "application/atom+xml"
    }

    static func looksLikeRSS(_ source: String) -> Bool {
        let prefix = source.prefix(2_048).lowercased()
        return prefix.contains("<rss") && prefix.contains("<channel")
    }

    static func parseRSS(_ source: String, responseURL: URL) throws -> DirectWebDocument {
        let channelTitle = firstCapture(
            in: source,
            pattern: #"(?is)<channel\b[^>]*>.*?<title\b[^>]*>(.*?)</title\s*>"#
        )
        .map(cleanXMLText)
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? fallbackTitle(for: responseURL)

        let itemPattern = #"(?is)<item\b[^>]*>(.*?)</item\s*>"#
        guard let expression = try? NSRegularExpression(pattern: itemPattern) else {
            throw DirectWebDocumentError.emptyBody
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = expression.matches(in: source, range: range)
        var links: [DirectWebLink] = []
        var entries: [String] = []

        for (index, match) in matches.prefix(maximumLinkCount).enumerated() {
            guard let item = capture(match, group: 1, in: source) else { continue }
            let title = firstCapture(
                in: item,
                pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#
            ).map(cleanXMLText) ?? "搜索结果 \(index + 1)"
            let description = firstCapture(
                in: item,
                pattern: #"(?is)<description\b[^>]*>(.*?)</description\s*>"#
            ).map(cleanXMLText) ?? ""
            let rawLink = firstCapture(
                in: item,
                pattern: #"(?is)<link\b[^>]*>(.*?)</link\s*>"#
            ).map(cleanXMLText) ?? ""

            if let url = URL(string: rawLink),
               let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http" {
                links.append(DirectWebLink(title: title, url: url))
            }

            let entry = description.isEmpty
                ? "\(index + 1). \(title)"
                : "\(index + 1). \(title)\n\(description)"
            entries.append(entry)
        }

        let limited = limitedText(entries.joined(separator: "\n\n"))
        guard !limited.text.isEmpty else {
            throw DirectWebDocumentError.emptyBody
        }
        return DirectWebDocument(
            title: channelTitle,
            text: limited.text,
            links: links,
            isLikelyDynamic: false,
            wasTruncated: limited.wasTruncated
        )
    }

    static func cleanXMLText(_ source: String) -> String {
        let withoutCDATA = source
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
        return normalizedVisibleText(decodeHTMLEntities(stripTags(from: withoutCDATA)))
    }

    static func looksLikeHTML(_ source: String) -> Bool {
        let prefix = source.prefix(1_024).lowercased()
        return prefix.contains("<!doctype html")
            || prefix.contains("<html")
            || prefix.contains("<head")
            || prefix.contains("<body")
            || prefix.contains("<title")
    }

    static func fallbackTitle(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            return host
        }
        return url.absoluteString
    }

    static func removingElement(named name: String, from source: String) -> String {
        replacingMatches(
            in: source,
            pattern: "(?is)<\(name)\\b[^>]*>.*?</\(name)\\s*>",
            with: ""
        )
    }

    static func visibleText(fromHTML html: String) -> String {
        var text = html
        let lineBreakElements = [
            "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt",
            "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
            "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
            "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"
        ].joined(separator: "|")

        text = replacingMatches(
            in: text,
            pattern: "(?is)</?(?:\(lineBreakElements))\\b[^>]*>",
            with: "\n"
        )
        text = stripTags(from: text)
        text = decodeHTMLEntities(text)
        return normalizedVisibleText(text)
    }

    static func stripTags(from source: String) -> String {
        replacingMatches(in: source, pattern: #"(?is)<[^>]*>"#, with: "")
    }

    static func normalizedVisibleText(_ source: String) -> String {
        let normalizedNewlines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        let lines = normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        var previousWasEmpty = true

        for line in lines {
            let collapsed = line
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")

            if collapsed.isEmpty {
                if !previousWasEmpty {
                    output.append("")
                    previousWasEmpty = true
                }
            } else {
                output.append(collapsed)
                previousWasEmpty = false
            }
        }

        while output.last == "" {
            output.removeLast()
        }
        return output.joined(separator: "\n")
    }

    static func isSogouSearchURL(_ url: URL) -> Bool {
        url.host(percentEncoded: false)?.lowercased() == "m.sogou.com"
            && url.path == "/web/searchList.jsp"
    }

    static func parseSogouSearch(
        _ html: String,
        responseURL: URL
    ) throws -> DirectWebDocument {
        let links = extractLinks(
            from: html,
            responseURL: responseURL,
            sogouResultsOnly: true
        )
        guard !links.isEmpty else {
            throw DirectWebDocumentError.searchResultsUnavailable
        }

        let query = URLComponents(url: responseURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "keyword" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let query, !query.isEmpty {
            title = "“\(String(query.prefix(40)))”的搜索结果"
        } else {
            title = "搜索结果"
        }

        let resultList = links.enumerated().map { index, link in
            "\(index + 1). \(link.title)"
        }.joined(separator: "\n")
        let limited = limitedText("找到 \(links.count) 个可打开结果。点下方标题直接打开。\n\n\(resultList)")
        return DirectWebDocument(
            title: title,
            text: limited.text,
            links: links,
            isLikelyDynamic: false,
            wasTruncated: limited.wasTruncated
        )
    }

    static func extractLinks(
        from html: String,
        responseURL: URL,
        sogouResultsOnly: Bool = false
    ) -> [DirectWebLink] {
        let pattern = #"(?is)<a\b[^>]*\bhref\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))[^>]*>(.*?)</a\s*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = expression.matches(in: html, range: fullRange)
        var result: [DirectWebLink] = []
        var seenURLs = Set<String>()

        for match in matches {
            guard result.count < maximumLinkCount else { break }

            if sogouResultsOnly {
                let anchor = capture(match, group: 0, in: html) ?? ""
                guard anchorHasClassToken("resultLink", anchorHTML: anchor) else { continue }
            }

            let href = (1...3)
                .compactMap { capture(match, group: $0, in: html) }
                .first ?? ""
            let decodedHref = decodeHTMLEntities(href)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decodedHref.isEmpty,
                  let rawResolved = URL(string: decodedHref, relativeTo: responseURL)?.absoluteURL else {
                continue
            }
            let resolved: URL
            if sogouResultsOnly {
                guard let target = unwrappedSogouTarget(from: rawResolved) else { continue }
                resolved = target
            } else {
                resolved = rawResolved
            }
            guard isSafeHTTPURL(resolved) else {
                continue
            }

            let key = resolved.absoluteString
            guard seenURLs.insert(key).inserted else { continue }

            let rawTitle = capture(match, group: 4, in: html) ?? ""
            let visibleTitle = normalizedVisibleText(
                decodeHTMLEntities(stripTags(from: rawTitle))
            )
            result.append(
                DirectWebLink(
                    title: visibleTitle.isEmpty ? resolved.host ?? key : visibleTitle,
                    url: resolved
                )
            )
        }

        return result
    }

    static func anchorHasClassToken(_ token: String, anchorHTML: String) -> Bool {
        guard let openingTagEnd = anchorHTML.firstIndex(of: ">") else { return false }
        let openingTag = String(anchorHTML[...openingTagEnd])
        let pattern = #"(?is)\bclass\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: openingTag,
                  range: NSRange(openingTag.startIndex..<openingTag.endIndex, in: openingTag)
              ) else {
            return false
        }
        let classValue = (1...3)
            .compactMap { capture(match, group: $0, in: openingTag) }
            .first ?? ""
        return classValue
            .split(whereSeparator: { $0.isWhitespace })
            .contains(where: { String($0).caseInsensitiveCompare(token) == .orderedSame })
    }

    static func unwrappedSogouTarget(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host(percentEncoded: false)?.lowercased() == "m.sogou.com",
              url.path.hasPrefix("/web/"),
              url.path.hasSuffix("/tc"),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.user == nil,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.password == nil,
              let queryItems = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )?.queryItems else {
            return nil
        }

        let targetValues = queryItems.filter { $0.name == "url" }.compactMap(\.value)
        guard targetValues.count == 1,
              let value = targetValues.first,
              value.count <= 4_096,
              let target = URL(string: value),
              target.scheme?.lowercased() == "https",
              isSafeHTTPURL(target) else {
            return nil
        }
        return target
    }

    static func isSafeHTTPURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return url.absoluteString.count <= 4_096
    }

    static func decodeHTMLEntities(_ source: String) -> String {
        let namedEntities: [String: String] = [
            "amp": "&", "apos": "'", "bull": "•", "copy": "©", "emsp": " ",
            "ensp": " ", "gt": ">", "hellip": "…", "laquo": "«", "lt": "<",
            "mdash": "—", "middot": "·", "nbsp": " ", "ndash": "–", "quot": "\"",
            "raquo": "»", "reg": "®"
        ]
        let pattern = #"&(?:#([0-9]{1,7})|#[xX]([0-9A-Fa-f]{1,6})|([A-Za-z][A-Za-z0-9]{1,31}));"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }

        let matches = expression.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        var decoded = source

        for match in matches.reversed() {
            let replacement: String?
            if let decimal = capture(match, group: 1, in: source),
               let value = UInt32(decimal),
               let scalar = UnicodeScalar(value),
               isAllowedHTMLScalar(scalar) {
                replacement = String(scalar)
            } else if let hexadecimal = capture(match, group: 2, in: source),
                      let value = UInt32(hexadecimal, radix: 16),
                      let scalar = UnicodeScalar(value),
                      isAllowedHTMLScalar(scalar) {
                replacement = String(scalar)
            } else if let name = capture(match, group: 3, in: source) {
                replacement = namedEntities[name.lowercased()]
            } else {
                replacement = nil
            }

            guard let replacement, let range = Range(match.range, in: decoded) else { continue }
            decoded.replaceSubrange(range, with: replacement)
        }
        return decoded
    }

    static func isAllowedHTMLScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value != 0
            && !(0xD800...0xDFFF).contains(scalar.value)
            && scalar.value <= 0x10FFFF
    }

    static func likelyRequiresJavaScript(source: String, visibleText: String) -> Bool {
        let lowercased = source.lowercased()
        let explicitMarkers = [
            "id=\"__next\"", "id='__next'", "__next_data__", "data-reactroot",
            "ng-version=", "enable javascript", "javascript is required"
        ]
        if explicitMarkers.contains(where: lowercased.contains) {
            return true
        }

        let hasEmptyAppRoot = lowercased.contains("id=\"root\"")
            || lowercased.contains("id='root'")
            || lowercased.contains("id=\"app\"")
            || lowercased.contains("id='app'")
        return hasEmptyAppRoot && visibleText.count < 80 && lowercased.contains("<script")
    }

    static func firstCapture(in source: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: source,
                  range: NSRange(source.startIndex..<source.endIndex, in: source)
              ) else {
            return nil
        }
        return capture(match, group: 1, in: source)
    }

    static func capture(_ match: NSTextCheckingResult, group: Int, in source: String) -> String? {
        let range = match.range(at: group)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else {
            return nil
        }
        return String(source[swiftRange])
    }

    static func replacingMatches(in source: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source),
            withTemplate: replacement
        )
    }
}
