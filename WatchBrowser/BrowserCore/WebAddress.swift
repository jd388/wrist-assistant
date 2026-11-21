import Foundation

public struct WebDestination: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case address
        case search
    }

    public let url: URL
    public let kind: Kind

    public init(rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebAddressError.empty
        }

        if Self.looksLikeAddress(trimmed) {
            url = try WebAddress(rawValue: trimmed).url
            kind = .address
            return
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "m.sogou.com"
        components.path = "/web/searchList.jsp"
        components.queryItems = [
            URLQueryItem(name: "keyword", value: trimmed)
        ]
        guard let searchURL = components.url else {
            throw WebAddressError.malformed
        }
        url = searchURL
        kind = .search
    }

    private static func looksLikeAddress(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "／", with: "/")
        if normalized.contains("://") {
            return true
        }

        guard !normalized.contains(where: { $0.isWhitespace }) else {
            return false
        }

        guard let firstPart = normalized
            .split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" })
            .first else {
            return false
        }
        let hostAndPort = String(firstPart)
        let domainPattern = #"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+(?:[A-Za-z]{2,63}|xn--[A-Za-z0-9-]{2,59})(?::[0-9]{1,5})?$"#
        let ipv4Pattern = #"^(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?$"#
        return hostAndPort.range(of: domainPattern, options: .regularExpression) != nil
            || hostAndPort.range(of: ipv4Pattern, options: .regularExpression) != nil
    }
}

public struct WebAddress: Equatable, Sendable {
    public let url: URL

    public init(rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebAddressError.empty
        }

        let punctuationNormalized = trimmed
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "／", with: "/")

        let candidate: String
        if punctuationNormalized.contains("://") {
            candidate = punctuationNormalized
        } else {
            candidate = "https://\(punctuationNormalized)"
        }

        guard var components = URLComponents(string: candidate) else {
            throw WebAddressError.malformed
        }

        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http" else {
            throw WebAddressError.unsupportedScheme(components.scheme ?? "未知")
        }

        guard let host = components.host,
              !host.isEmpty,
              !host.contains(where: { $0.isWhitespace }) else {
            throw WebAddressError.missingHost
        }

        guard components.user == nil, components.password == nil else {
            throw WebAddressError.embeddedCredentials
        }

        components.scheme = scheme
        guard let url = components.url else {
            throw WebAddressError.malformed
        }

        self.url = url
    }
}

public enum WebAddressError: LocalizedError, Equatable, Sendable {
    case empty
    case malformed
    case missingHost
    case unsupportedScheme(String)
    case embeddedCredentials

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "请输入网址。"
        case .malformed:
            return "网址格式无法识别，请检查空格和符号。"
        case .missingHost:
            return "网址缺少网站域名，例如 baidu.com。"
        case .unsupportedScheme(let scheme):
            return "不支持 \(scheme) 链接，只能打开 http 或 https 网页。"
        case .embeddedCredentials:
            return "为保护账号安全，请不要把用户名或密码写进网址。"
        }
    }
}
