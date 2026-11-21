import Foundation

public enum PhoneLocalBrowserAction: String, CaseIterable, Codable, Equatable, Sendable {
    case back
    case fill
    case refresh
    case scroll
    case tap
}

/// Identifies browser requests that belong to the free iPhone-local WebKit renderer.
/// A cloud-created session intentionally remains an upstream request so an existing
/// cloud session can continue after the phone becomes reachable again.
public enum PhoneLocalBrowserRoute: Equatable, Sendable {
    case open
    case action(sessionID: String, action: PhoneLocalBrowserAction)
    case close(sessionID: String)
    case upstream

    public static let sessionPrefix = "ios_"

    public static func makeSessionID(uuid: UUID = UUID()) -> String {
        sessionPrefix + uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func isLocalSessionID(_ value: String) -> Bool {
        guard value.hasPrefix(sessionPrefix) else { return false }
        let suffix = value.dropFirst(sessionPrefix.count)
        return suffix.count == 32 && suffix.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    public static func classify(method: String, path: String) -> PhoneLocalBrowserRoute {
        let normalizedMethod = method.uppercased()
        if normalizedMethod == "POST", path == "/v1/sessions/open" {
            return .open
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if normalizedMethod == "POST",
           segments.count == 5,
           segments[0].isEmpty,
           segments[1] == "v1",
           segments[2] == "sessions",
           isLocalSessionID(String(segments[3])),
           let action = PhoneLocalBrowserAction(rawValue: String(segments[4])) {
            return .action(sessionID: String(segments[3]), action: action)
        }
        if normalizedMethod == "DELETE",
           segments.count == 4,
           segments[0].isEmpty,
           segments[1] == "v1",
           segments[2] == "sessions",
           isLocalSessionID(String(segments[3])) {
            return .close(sessionID: String(segments[3]))
        }
        return .upstream
    }

    public static func requiresReachablePhone(method: String, path: String) -> Bool {
        switch classify(method: method, path: path) {
        case .action, .close:
            return true
        case .open, .upstream:
            return false
        }
    }
}

public struct PhoneLocalBrowserValidatedURL: Equatable, Sendable {
    public let url: URL
    public let host: String
    public let port: Int
    public let isIPAddress: Bool
}

public enum PhoneLocalBrowserURLPolicyError: LocalizedError, Equatable, Sendable {
    case emptyOrControlCharacter
    case malformed
    case unsupportedScheme
    case embeddedCredentials
    case blockedHost
    case unsupportedPort
    case invalidHost
    case nonPublicAddress
    case dnsResolutionFailed

    public var errorDescription: String? {
        switch self {
        case .emptyOrControlCharacter:
            return "网址为空或包含不安全字符。"
        case .malformed:
            return "网址格式无效。"
        case .unsupportedScheme:
            return "iPhone 本地浏览器只允许 HTTPS 网页。"
        case .embeddedCredentials:
            return "网址不能包含用户名或密码。"
        case .blockedHost:
            return "本地、内网和云主机元数据地址已被拦截。"
        case .unsupportedPort:
            return "iPhone 本地浏览器只允许标准 HTTPS 端口。"
        case .invalidHost:
            return "网页域名格式无效。"
        case .nonPublicAddress:
            return "网页解析到了本地、私有、保留或元数据地址。"
        case .dnsResolutionFailed:
            return "网页域名解析失败。"
        }
    }
}

/// The bounded subset of Cloudflare's DNS JSON response that is needed to
/// verify a system-proxy Fake-IP result. Parsing stays separate from transport
/// so the DNS question, truncation flag, CNAME chain and address family can be
/// unit tested without networking or WebKit.
public struct PhoneLocalBrowserTrustedDNSResponse: Codable, Equatable, Sendable {
    public struct Question: Codable, Equatable, Sendable {
        public let name: String
        public let type: Int

        public init(name: String, type: Int) {
            self.name = name
            self.type = type
        }
    }

    public struct Answer: Codable, Equatable, Sendable {
        public let name: String
        public let type: Int
        public let ttl: Int
        public let data: String

        enum CodingKeys: String, CodingKey {
            case name
            case type
            case ttl = "TTL"
            case data
        }

        public init(name: String, type: Int, ttl: Int, data: String) {
            self.name = name
            self.type = type
            self.ttl = ttl
            self.data = data
        }
    }

    public let status: Int
    public let truncated: Bool
    public let questions: [Question]
    public let answers: [Answer]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case truncated = "TC"
        case questions = "Question"
        case answers = "Answer"
    }

    public init(
        status: Int,
        truncated: Bool,
        questions: [Question],
        answers: [Answer]?
    ) {
        self.status = status
        self.truncated = truncated
        self.questions = questions
        self.answers = answers
    }

    public func validatedAddresses(
        forHost rawHost: String,
        queryType: Int
    ) throws -> [String] {
        guard queryType == 1 || queryType == 28,
              status == 0,
              !truncated,
              questions.count == 1,
              questions[0].type == queryType,
              let host = Self.normalizedDNSName(rawHost),
              Self.normalizedDNSName(questions[0].name) == host else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }

        let records = answers ?? []
        guard records.allSatisfy({ $0.ttl >= 0 }) else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }

        var current = host
        var reachableNames: Set<String> = [host]
        for _ in 0..<8 {
            let cnames = records.filter {
                $0.type == 5 && Self.normalizedDNSName($0.name) == current
            }
            guard cnames.count <= 1 else {
                throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
            }
            guard let cname = cnames.first else { break }
            guard let target = Self.normalizedDNSName(cname.data),
                  let destination = try? PhoneLocalBrowserURLPolicy.validateStructure(
                    "https://\(target)/"
                  ),
                  !destination.isIPAddress,
                  reachableNames.insert(target).inserted else {
                throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
            }
            current = target
        }

        // Reject an overlong chain and unrelated CNAME material. The JSON API
        // should return the answer section for exactly one question.
        if records.contains(where: {
            $0.type == 5 && Self.normalizedDNSName($0.name) == current
        }) {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }
        let cnameOwners = records.compactMap { record -> String? in
            guard record.type == 5 else { return nil }
            return Self.normalizedDNSName(record.name)
        }
        guard cnameOwners.allSatisfy(reachableNames.contains) else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }

        let addressRecords = records.filter { $0.type == 1 || $0.type == 28 }
        guard addressRecords.allSatisfy({ record in
            record.type == queryType && Self.normalizedDNSName(record.name) == current
        }) else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }
        return addressRecords.map(\.data)
    }

    private static func normalizedDNSName(_ input: String) -> String? {
        var value = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        return value
    }
}

/// Pure URL/IP checks shared by the app and unit tests. The iPhone renderer also
/// resolves host names before every top-level navigation and passes every answer
/// to `validateResolvedAddresses(_:)`.
public enum PhoneLocalBrowserURLPolicy {
    public static let maximumURLBytes = 4_096

    private static let blockedNames: Set<String> = [
        "localhost",
        "localhost.localdomain",
        "metadata",
        "metadata.google.internal",
        "instance-data"
    ]

    private static let explicitMetadataIPv4: Set<String> = [
        "100.100.100.200",
        "168.63.129.16",
        "169.254.169.254"
    ]

    private static let blockedIPv4Ranges: [(base: UInt32, prefix: Int)] = [
        (0x00000000, 8),
        (0x0a000000, 8),
        (0x64400000, 10),
        (0x7f000000, 8),
        (0xa9fe0000, 16),
        (0xac100000, 12),
        (0xc0000000, 24),
        (0xc0000200, 24),
        (0xc0586300, 24),
        (0xc0a80000, 16),
        (0xc6120000, 15),
        (0xc6336400, 24),
        (0xcb007100, 24),
        (0xe0000000, 4),
        (0xf0000000, 4)
    ]

    public static func validateStructure(
        _ rawURL: String
    ) throws -> PhoneLocalBrowserValidatedURL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumURLBytes,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
              }) else {
            throw PhoneLocalBrowserURLPolicyError.emptyOrControlCharacter
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host else {
            throw PhoneLocalBrowserURLPolicyError.malformed
        }
        guard scheme == "https" else {
            throw PhoneLocalBrowserURLPolicyError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw PhoneLocalBrowserURLPolicyError.embeddedCredentials
        }

        var host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else {
            throw PhoneLocalBrowserURLPolicyError.invalidHost
        }
        guard !isBlockedName(host) else {
            throw PhoneLocalBrowserURLPolicyError.blockedHost
        }

        let port = components.port ?? 443
        guard port == 443 else {
            throw PhoneLocalBrowserURLPolicyError.unsupportedPort
        }

        let isIPv4 = parseIPv4(host) != nil
        let isIPv6 = parseIPv6(host) != nil
        let isIPAddress = isIPv4 || isIPv6
        if isIPAddress {
            guard isPublicIPAddress(host) else {
                throw PhoneLocalBrowserURLPolicyError.nonPublicAddress
            }
        } else {
            guard !host.contains(":"),
                  host.utf8.count <= 253,
                  host.split(separator: ".", omittingEmptySubsequences: false)
                    .allSatisfy(isValidDomainLabel) else {
                throw PhoneLocalBrowserURLPolicyError.invalidHost
            }
        }

        components.scheme = scheme
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = nil
        guard let normalizedURL = components.url else {
            throw PhoneLocalBrowserURLPolicyError.malformed
        }
        return PhoneLocalBrowserValidatedURL(
            url: normalizedURL,
            host: host,
            port: port,
            isIPAddress: isIPAddress
        )
    }

    public static func validateResolvedAddresses(_ addresses: [String]) throws {
        guard !addresses.isEmpty else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }
        guard addresses.allSatisfy(isPublicIPAddress) else {
            throw PhoneLocalBrowserURLPolicyError.nonPublicAddress
        }
    }

    /// Some system-wide proxy/VPN products deliberately return addresses from
    /// RFC 2544's 198.18.0.0/15 benchmark range and translate them later in the
    /// network stack. That range must never be treated as public. The renderer
    /// may, however, use a trusted DNS-over-HTTPS lookup when *every* system DNS
    /// answer is one of these synthetic addresses, then validate the real
    /// answers with the normal public-address policy.
    public static func requiresTrustedDNSFallback(
        forSystemAddresses addresses: [String]
    ) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy(isSyntheticProxyIPAddress)
    }

    public static func isSyntheticProxyIPAddress(_ input: String) -> Bool {
        let normalized = input
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if let ipv4 = parseIPv4(normalized) {
            return isIPv4(ipv4, inBase: 0xc6120000, prefix: 15)
        }
        guard let ipv6 = parseIPv6(normalized),
              ipv6.prefix(10).allSatisfy({ $0 == 0 }),
              ipv6[10] == 0xff,
              ipv6[11] == 0xff else {
            return false
        }
        let mapped = UInt32(ipv6[12]) << 24
            | UInt32(ipv6[13]) << 16
            | UInt32(ipv6[14]) << 8
            | UInt32(ipv6[15])
        return isIPv4(mapped, inBase: 0xc6120000, prefix: 15)
    }

    public static func isPublicIPAddress(_ input: String) -> Bool {
        let normalized = input
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if let ipv4 = parseIPv4(normalized) {
            if explicitMetadataIPv4.contains(normalized) { return false }
            return !blockedIPv4Ranges.contains { range in
                isIPv4(ipv4, inBase: range.base, prefix: range.prefix)
            }
        }
        guard let ipv6 = parseIPv6(normalized) else { return false }
        if ipv6.prefix(10).allSatisfy({ $0 == 0 }), ipv6[10] == 0xff, ipv6[11] == 0xff {
            let mapped = UInt32(ipv6[12]) << 24
                | UInt32(ipv6[13]) << 16
                | UInt32(ipv6[14]) << 8
                | UInt32(ipv6[15])
            let mappedText = [24, 16, 8, 0]
                .map { String((mapped >> UInt32($0)) & 0xff) }
                .joined(separator: ".")
            return isPublicIPAddress(mappedText)
        }

        // Public global-unicast IPv6 occupies 2000::/3. Explicitly reject the
        // special/documentation ranges mirrored by the cloud renderer policy.
        guard ipv6[0] & 0xe0 == 0x20 else { return false }
        let blocked: [([UInt8], Int)] = [
            ([0x20, 0x01, 0x00], 23),
            ([0x20, 0x01, 0x0d, 0xb8], 32),
            ([0x3f, 0xff, 0x00], 20),
            ([0x5f, 0x00], 16)
        ]
        return !blocked.contains { prefix, bitCount in
            matches(ipv6, prefix: prefix, bitCount: bitCount)
        }
    }

    private static func isBlockedName(_ host: String) -> Bool {
        blockedNames.contains(host)
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".home.arpa")
    }

    private static func isValidDomainLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty,
              label.utf8.count <= 63,
              label.first != "-",
              label.last != "-" else {
            return false
        }
        return label.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 97 && byte <= 122)
                || byte == 45
        }
    }

    private static func parseIPv4(_ input: String) -> UInt32? {
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty,
                  part.count <= 3,
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let byte = UInt8(part) else {
                return nil
            }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    private static func isIPv4(_ value: UInt32, inBase base: UInt32, prefix: Int) -> Bool {
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        return value & mask == base & mask
    }

    private static func parseIPv6(_ input: String) -> [UInt8]? {
        var candidate = input.lowercased()
        guard !candidate.isEmpty, !candidate.contains("%") else { return nil }

        if candidate.contains(".") {
            guard let lastColon = candidate.lastIndex(of: ":"),
                  let ipv4 = parseIPv4(String(candidate[candidate.index(after: lastColon)...])) else {
                return nil
            }
            let high = String((ipv4 >> 16) & 0xffff, radix: 16)
            let low = String(ipv4 & 0xffff, radix: 16)
            candidate = String(candidate[...lastColon]) + high + ":" + low
        }

        let halves = candidate.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func parseHalf(_ value: String) -> [UInt16]? {
            guard !value.isEmpty else { return [] }
            var output: [UInt16] = []
            for piece in value.split(separator: ":", omittingEmptySubsequences: false) {
                guard !piece.isEmpty,
                      piece.count <= 4,
                      piece.utf8.allSatisfy({ byte in
                          (byte >= 48 && byte <= 57)
                              || (byte >= 97 && byte <= 102)
                      }),
                      let word = UInt16(piece, radix: 16) else {
                    return nil
                }
                output.append(word)
            }
            return output
        }
        guard let head = parseHalf(halves[0]) else { return nil }
        let words: [UInt16]
        if halves.count == 1 {
            guard head.count == 8 else { return nil }
            words = head
        } else {
            guard let tail = parseHalf(halves[1]), head.count + tail.count < 8 else {
                return nil
            }
            words = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        guard words.count == 8 else { return nil }
        return words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
    }

    private static func matches(
        _ value: [UInt8],
        prefix: [UInt8],
        bitCount: Int
    ) -> Bool {
        let wholeBytes = bitCount / 8
        let remainingBits = bitCount % 8
        guard value.count >= wholeBytes + (remainingBits == 0 ? 0 : 1),
              prefix.count >= wholeBytes + (remainingBits == 0 ? 0 : 1) else {
            return false
        }
        for index in 0..<wholeBytes where value[index] != prefix[index] {
            return false
        }
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << UInt8(8 - remainingBits)
        return value[wholeBytes] & mask == prefix[wholeBytes] & mask
    }
}
