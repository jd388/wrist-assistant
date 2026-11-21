import SwiftUI
#if DEBUG
import Darwin
import UIKit
#endif

@main
struct WatchBrowserApp: App {
    #if DEBUG
    private let acceptanceGatewayOverride: GatewayConfiguration?
    #endif

    init() {
        #if DEBUG
        let debugGatewayOverride = Self.takeAcceptanceGatewayOverrideIfPresent()
        let debugDeepSeekOverride = Self.takeAcceptanceDeepSeekOverrideIfPresent()
        acceptanceGatewayOverride = debugGatewayOverride
        #endif

        #if DEBUG
        if debugGatewayOverride == nil {
            _ = try? GatewayTokenStore.migrateLegacyTokenIfNeeded()
        }
        #else
        _ = try? GatewayTokenStore.migrateLegacyTokenIfNeeded()
        #endif
        importLocalDebugGatewayIfPresent()
        importLocalDebugDeepSeekIfPresent()
        #if DEBUG
        startAcceptanceProbeIfPresent(
            gatewayOverride: debugGatewayOverride,
            deepSeekAPIKeyOverride: debugDeepSeekOverride
        )
        #else
        startAcceptanceProbeIfPresent()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let parameters = visualQAParameters(
                gatewayOverride: acceptanceGatewayOverride
            ) {
                AcceptanceVisualView(parameters: parameters)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }

    private func importLocalDebugGatewayIfPresent() {
        #if DEBUG
        let urlName = "WRIST_GATEWAY_SETUP_URL"
        let tokenName = "WRIST_GATEWAY_SETUP_TOKEN"
        let attemptName = "WRIST_GATEWAY_SETUP_ATTEMPT_ID"
        let serverURL = environmentValue(urlName)
            ?? environmentValue("DEVICECTL_CHILD_\(urlName)")
        let token = environmentValue(tokenName)
            ?? environmentValue("DEVICECTL_CHILD_\(tokenName)")
        let attemptID = environmentValue(attemptName)
            ?? environmentValue("DEVICECTL_CHILD_\(attemptName)")
        guard serverURL != nil || token != nil || attemptID != nil else { return }

        [urlName, tokenName, attemptName].forEach {
            unsetenv($0)
            unsetenv("DEVICECTL_CHILD_\($0)")
        }

        let defaults = UserDefaults.standard
        let receiptID = attemptID ?? "legacy"
        defaults.set(receiptID, forKey: "gatewayLocalImportAttemptID")
        guard let serverURL, let token else {
            let message = "Mac 本地网关配置失败：地址或部署令牌缺失。"
            defaults.set(false, forKey: "gatewayLocalImportSucceeded")
            defaults.set(message, forKey: "gatewayLocalImportMessage")
            defaults.synchronize()
            writeGatewayImportReceipt(
                id: receiptID,
                succeeded: false,
                message: message
            )
            return
        }

        let previousURL = defaults.object(forKey: "rendererServerURL") as? String
        let previousToken: String?
        do {
            previousToken = try GatewayTokenStore.load()
        } catch {
            let message = "Mac 本地网关配置失败：无法读取原有 Keychain 配置。"
            defaults.set(false, forKey: "gatewayLocalImportSucceeded")
            defaults.set(message, forKey: "gatewayLocalImportMessage")
            defaults.synchronize()
            writeGatewayImportReceipt(
                id: receiptID,
                succeeded: false,
                message: message
            )
            return
        }

        do {
            let configuration = try GatewayConfiguration(
                serverURL: serverURL,
                token: token
            )
            let normalizedURL = configuration.baseURL.absoluteString
            try GatewayTokenStore.save(configuration.token)
            guard try GatewayTokenStore.load() == configuration.token else {
                throw GatewayTokenStoreError.migrationVerificationFailed
            }
            defaults.set(normalizedURL, forKey: "rendererServerURL")
            defaults.synchronize()
            guard defaults.string(forKey: "rendererServerURL") == normalizedURL else {
                throw GatewayTokenStoreError.migrationVerificationFailed
            }

            defaults.set(true, forKey: "gatewayLocalImportSucceeded")
            defaults.set(
                "网关地址已保存，部署令牌已写入手表 Keychain。",
                forKey: "gatewayLocalImportMessage"
            )
            defaults.synchronize()
            writeGatewayImportReceipt(
                id: receiptID,
                succeeded: true,
                message: "网关地址与部署令牌已安全保存。"
            )
        } catch {
            do {
                if let previousToken {
                    try GatewayTokenStore.save(previousToken)
                } else {
                    try GatewayTokenStore.delete()
                }
                if let previousURL {
                    defaults.set(previousURL, forKey: "rendererServerURL")
                } else {
                    defaults.removeObject(forKey: "rendererServerURL")
                }
                defaults.synchronize()
            } catch {
                // The receipt remains a failure; the settings screen can repair either value.
            }
            let message = "Mac 本地网关配置失败，原配置已尽量保留。"
            defaults.set(false, forKey: "gatewayLocalImportSucceeded")
            defaults.set(message, forKey: "gatewayLocalImportMessage")
            defaults.synchronize()
            writeGatewayImportReceipt(
                id: receiptID,
                succeeded: false,
                message: message
            )
        }
        #endif
    }

    private func importLocalDebugDeepSeekIfPresent() {
        #if DEBUG
        let keyName = "WRIST_DEEPSEEK_SETUP_KEY"
        let attemptName = "WRIST_DEEPSEEK_SETUP_ATTEMPT_ID"
        let apiKey = environmentValue(keyName)
            ?? environmentValue("DEVICECTL_CHILD_\(keyName)")
        let attemptID = environmentValue(attemptName)
            ?? environmentValue("DEVICECTL_CHILD_\(attemptName)")
        guard apiKey != nil || attemptID != nil else { return }

        [keyName, attemptName].forEach {
            unsetenv($0)
            unsetenv("DEVICECTL_CHILD_\($0)")
        }

        let receiptID = attemptID ?? "legacy"
        guard let apiKey else {
            writeDeepSeekImportReceipt(
                id: receiptID,
                succeeded: false,
                message: "Mac 本地 DeepSeek 配置失败：API Key 缺失。"
            )
            return
        }

        let previousKey: String?
        do {
            previousKey = try DeepSeekKeyStore.load()
        } catch {
            writeDeepSeekImportReceipt(
                id: receiptID,
                succeeded: false,
                message: "Mac 本地 DeepSeek 配置失败：无法读取原有 Keychain 配置。"
            )
            return
        }

        do {
            try DeepSeekKeyStore.save(apiKey)
            guard try DeepSeekKeyStore.load() == apiKey else {
                throw DeepSeekKeyStoreError.invalidStoredValue
            }
            writeDeepSeekImportReceipt(
                id: receiptID,
                succeeded: true,
                message: "DeepSeek API Key 已安全写入手表 Keychain。"
            )
        } catch {
            do {
                if let previousKey {
                    try DeepSeekKeyStore.save(previousKey)
                } else {
                    try DeepSeekKeyStore.delete()
                }
            } catch {
                // The receipt remains a failure; the settings screen can repair the key.
            }
            writeDeepSeekImportReceipt(
                id: receiptID,
                succeeded: false,
                message: "Mac 本地 DeepSeek 配置失败，原有 Key 已尽量保留。"
            )
        }
        #endif
    }

    private func startAcceptanceProbeIfPresent(
        gatewayOverride: GatewayConfiguration? = nil,
        deepSeekAPIKeyOverride: String? = nil
    ) {
        #if DEBUG
        let idName = "WRIST_ACCEPTANCE_PROBE_ID"
        let kindName = "WRIST_ACCEPTANCE_PROBE_KIND"
        let inputName = "WRIST_ACCEPTANCE_WEB_INPUT"
        let environmentID = environmentValue(idName)
            ?? environmentValue("DEVICECTL_CHILD_\(idName)")
            ?? commandLineValue(after: "--wrist-acceptance-id")
        let environmentKind = environmentValue(kindName)
            ?? environmentValue("DEVICECTL_CHILD_\(kindName)")
            ?? commandLineValue(after: "--wrist-acceptance-kind")
        let environmentWebInput = environmentValue(inputName)
            ?? environmentValue("DEVICECTL_CHILD_\(inputName)")
            ?? commandLineValue(after: "--wrist-web-input")

        let parameters: (id: String, kind: String, webInput: String?)
        if let environmentID, let environmentKind {
            parameters = (environmentID, environmentKind, environmentWebInput)
        } else if let request = readAcceptanceProbeRequest() {
            parameters = (request.attemptID, request.kind, request.webInput)
        } else {
            return
        }

        Self.removeAcceptanceReceipt()

        [idName, kindName, inputName].forEach {
            unsetenv($0)
            unsetenv("DEVICECTL_CHILD_\($0)")
        }

        Task {
            let receipt = await Self.runAcceptanceProbe(
                id: parameters.id,
                kind: parameters.kind,
                webInput: parameters.webInput,
                gatewayOverride: gatewayOverride,
                deepSeekAPIKeyOverride: deepSeekAPIKeyOverride
            )
            Self.writeAcceptanceReceipt(receipt)
        }
        #endif
    }

    #if DEBUG
    private static func takeAcceptanceGatewayOverrideIfPresent()
        -> GatewayConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        let hasProbeLaunch = (
            environment["WRIST_ACCEPTANCE_PROBE_ID"] != nil
                || environment["DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_ID"] != nil
        ) && (
            environment["WRIST_ACCEPTANCE_PROBE_KIND"] != nil
                || environment["DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_KIND"] != nil
        )
        let hasVisualLaunch = arguments.contains("--wrist-visual-qa-id")
            && arguments.contains("--wrist-visual-qa-kind")
        guard hasProbeLaunch || hasVisualLaunch else { return nil }

        let urlName = "WRIST_GATEWAY_SETUP_URL"
        let tokenName = "WRIST_GATEWAY_SETUP_TOKEN"
        let serverURL = environment[urlName]
            ?? environment["DEVICECTL_CHILD_\(urlName)"]
        let token = environment[tokenName]
            ?? environment["DEVICECTL_CHILD_\(tokenName)"]
        guard let serverURL, let token else { return nil }

        [urlName, tokenName].forEach {
            unsetenv($0)
            unsetenv("DEVICECTL_CHILD_\($0)")
        }
        return try? GatewayConfiguration(serverURL: serverURL, token: token)
    }

    private static func takeAcceptanceDeepSeekOverrideIfPresent() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let idPresent = environment["WRIST_ACCEPTANCE_PROBE_ID"] != nil
            || environment["DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_ID"] != nil
        let kind = environment["WRIST_ACCEPTANCE_PROBE_KIND"]
            ?? environment["DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_KIND"]
        guard idPresent, kind == "ai" else { return nil }

        let keyName = "WRIST_ACCEPTANCE_DEEPSEEK_KEY"
        let value = environment[keyName]
            ?? environment["DEVICECTL_CHILD_\(keyName)"]
        unsetenv(keyName)
        unsetenv("DEVICECTL_CHILD_\(keyName)")
        return value
    }

    private func environmentValue(_ name: String) -> String? {
        guard let pointer = getenv(name) else { return nil }
        return String(cString: pointer)
    }

    private func commandLineValue(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private struct AcceptanceProbeRequest: Decodable {
        let attemptID: String
        let kind: String
        let webInput: String?

        enum CodingKeys: String, CodingKey {
            case attemptID = "attempt_id"
            case kind
            case webInput = "web_input"
        }
    }

    private func readAcceptanceProbeRequest() -> AcceptanceProbeRequest? {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let requestURL = cachesURL.appendingPathComponent("acceptance-probe-request.json")
        guard let data = try? Data(contentsOf: requestURL) else { return nil }
        do {
            let request = try JSONDecoder().decode(AcceptanceProbeRequest.self, from: data)
            try? FileManager.default.removeItem(at: requestURL)
            return request
        } catch {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let attemptedID = object?["attempt_id"] as? String ?? "invalid-request"
            try? FileManager.default.removeItem(at: requestURL)
            Self.writeAcceptanceReceipt(
                AcceptanceReceipt(
                    attemptID: attemptedID,
                    kind: "invalid",
                    succeeded: false,
                    code: "invalid_probe_request",
                    message: "验收请求 JSON 无法解码。"
                )
            )
            return nil
        }
    }

    private func writeGatewayImportReceipt(
        id: String,
        succeeded: Bool,
        message: String
    ) {
        struct Receipt: Encodable {
            let attemptID: String
            let succeeded: Bool
            let message: String

            enum CodingKeys: String, CodingKey {
                case attemptID = "attempt_id"
                case succeeded
                case message
            }
        }

        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }

        let receiptURL = cachesURL.appendingPathComponent("gateway-import-ack.json")
        do {
            try FileManager.default.createDirectory(
                at: cachesURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(
                Receipt(attemptID: id, succeeded: succeeded, message: message)
            )
            try data.write(to: receiptURL, options: .atomic)
        } catch {
            // The Mac helper treats a missing receipt as a failed import.
        }
    }

    private func writeDeepSeekImportReceipt(
        id: String,
        succeeded: Bool,
        message: String
    ) {
        struct Receipt: Encodable {
            let attemptID: String
            let succeeded: Bool
            let message: String

            enum CodingKeys: String, CodingKey {
                case attemptID = "attempt_id"
                case succeeded
                case message
            }
        }

        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }

        let receiptURL = cachesURL.appendingPathComponent("deepseek-import-ack.json")
        do {
            try FileManager.default.createDirectory(
                at: cachesURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(
                Receipt(attemptID: id, succeeded: succeeded, message: message)
            )
            try data.write(to: receiptURL, options: .atomic)
        } catch {
            // The Mac helper treats a missing receipt as a failed import.
        }
    }

    private struct AcceptanceReceipt: Encodable {
        let attemptID: String
        let kind: String
        let succeeded: Bool
        let code: String
        let message: String
        let answerCharacters: Int?
        let pageTitle: String?
        let visibleCharacters: Int?
        let linkCount: Int?
        let imageBytes: Int?
        let sessionSequence: UInt64?
        let webSearchUsed: Bool?
        let webSearchProvider: String?
        let citationCount: Int?
        let pageSource: String?
        let model: String?
        let reasoningCharacters: Int?
        let streamEventCount: Int?

        init(
            attemptID: String,
            kind: String,
            succeeded: Bool,
            code: String,
            message: String,
            answerCharacters: Int? = nil,
            pageTitle: String? = nil,
            visibleCharacters: Int? = nil,
            linkCount: Int? = nil,
            imageBytes: Int? = nil,
            sessionSequence: UInt64? = nil,
            webSearchUsed: Bool? = nil,
            webSearchProvider: String? = nil,
            citationCount: Int? = nil,
            pageSource: String? = nil,
            model: String? = nil,
            reasoningCharacters: Int? = nil,
            streamEventCount: Int? = nil
        ) {
            self.attemptID = attemptID
            self.kind = kind
            self.succeeded = succeeded
            self.code = code
            self.message = message
            self.answerCharacters = answerCharacters
            self.pageTitle = pageTitle
            self.visibleCharacters = visibleCharacters
            self.linkCount = linkCount
            self.imageBytes = imageBytes
            self.sessionSequence = sessionSequence
            self.webSearchUsed = webSearchUsed
            self.webSearchProvider = webSearchProvider
            self.citationCount = citationCount
            self.pageSource = pageSource
            self.model = model
            self.reasoningCharacters = reasoningCharacters
            self.streamEventCount = streamEventCount
        }

        enum CodingKeys: String, CodingKey {
            case attemptID = "attempt_id"
            case kind
            case succeeded
            case code
            case message
            case answerCharacters = "answer_characters"
            case pageTitle = "page_title"
            case visibleCharacters = "visible_characters"
            case linkCount = "link_count"
            case imageBytes = "image_bytes"
            case sessionSequence = "session_sequence"
            case webSearchUsed = "web_search_used"
            case webSearchProvider = "web_search_provider"
            case citationCount = "citation_count"
            case pageSource = "page_source"
            case model
            case reasoningCharacters = "reasoning_characters"
            case streamEventCount = "stream_event_count"
        }
    }

    private actor AIStreamProbeState {
        struct Snapshot: Sendable {
            let metadataReceived: Bool
            let contentEventCount: Int
            let doneReceived: Bool
        }

        private var metadataReceived = false
        private var contentEventCount = 0
        private var doneReceived = false

        func record(_ event: GatewayAskStreamEvent) {
            switch event {
            case .metadata:
                metadataReceived = true
            case .reasoningDelta, .delta:
                contentEventCount += 1
            case .done:
                doneReceived = true
            case .failure:
                break
            }
        }

        func snapshot() -> Snapshot {
            Snapshot(
                metadataReceived: metadataReceived,
                contentEventCount: contentEventCount,
                doneReceived: doneReceived
            )
        }
    }

    #if DEBUG
    private struct AcceptanceVisualParameters: Equatable {
        let id: String
        let kind: String
        let webInput: String?
        let gatewayOverride: GatewayConfiguration?
    }

    private func visualQAParameters(
        gatewayOverride: GatewayConfiguration?
    ) -> AcceptanceVisualParameters? {
        guard let id = commandLineValue(after: "--wrist-visual-qa-id"),
              let kind = commandLineValue(after: "--wrist-visual-qa-kind") else {
            return nil
        }
        return AcceptanceVisualParameters(
            id: id,
            kind: kind,
            webInput: commandLineValue(after: "--wrist-visual-qa-input"),
            gatewayOverride: gatewayOverride
        )
    }

    private struct AcceptanceVisualView: View {
        let parameters: AcceptanceVisualParameters
        @State private var receipt: AcceptanceReceipt?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: "checkmark.seal")
                        .font(.headline)
                        .foregroundStyle(.cyan)

                    if let receipt {
                        Label(
                            receipt.succeeded ? "验收通过" : "验收失败",
                            systemImage: receipt.succeeded
                                ? "checkmark.circle.fill"
                                : "xmark.octagon.fill"
                        )
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(receipt.succeeded ? .green : .orange)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(receipt.message)
                                    .font(.caption2)

                                Divider()
                                metric("结果码", receipt.code)
                                if let pageTitle = receipt.pageTitle {
                                    metric("页面", pageTitle)
                                }
                                if let pageSource = receipt.pageSource {
                                    metric("正文来源", pageSource)
                                }
                                if let visibleCharacters = receipt.visibleCharacters {
                                    metric("正文字符", String(visibleCharacters))
                                }
                                if let linkCount = receipt.linkCount {
                                    metric("链接", String(linkCount))
                                }
                                if let answerCharacters = receipt.answerCharacters {
                                    metric("回答字符", String(answerCharacters))
                                }
                                if let provider = receipt.webSearchProvider {
                                    metric("搜索来源", provider)
                                }
                                if let citationCount = receipt.citationCount {
                                    metric("引用", String(citationCount))
                                }
                                if let model = receipt.model {
                                    metric("模型", model)
                                }
                                if let reasoningCharacters = receipt.reasoningCharacters {
                                    metric("思考字符", String(reasoningCharacters))
                                }
                                if let streamEventCount = receipt.streamEventCount {
                                    metric("流式片段", String(streamEventCount))
                                }
                                if let imageBytes = receipt.imageBytes {
                                    metric("画面字节", String(imageBytes))
                                }
                                if let sequence = receipt.sessionSequence {
                                    metric("会话序列", String(sequence))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        HStack(spacing: 7) {
                            ProgressView()
                            Text("正在运行真实网络探针…")
                                .font(.caption)
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 5)
            .task(id: parameters.id) {
                let result = await WatchBrowserApp.runAcceptanceProbe(
                    id: parameters.id,
                    kind: parameters.kind,
                    webInput: parameters.webInput,
                    gatewayOverride: parameters.gatewayOverride
                )
                WatchBrowserApp.writeAcceptanceReceipt(result)
                receipt = result
            }
        }

        private var title: String {
            switch parameters.kind {
            case "web":
                return "网页正文"
            case "ai":
                return "AI 联网问答"
            case "browser":
                return "交互网页画面"
            default:
                return "未知探针"
            }
        }

        private func metric(_ label: String, _ value: String) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption2.monospaced())
            }
        }
    }
    #endif

    private struct BrowserAcceptanceOpenRequest: Encodable, Sendable {
        let url: String
        let viewportWidth: Int
        let viewportHeight: Int

        enum CodingKeys: String, CodingKey {
            case url
            case viewportWidth = "viewport_width"
            case viewportHeight = "viewport_height"
        }
    }

    private struct BrowserAcceptanceFrame: Decodable, Sendable {
        let sessionID: String
        let sequence: UInt64
        let url: String
        let title: String
        let canGoBack: Bool
        let scrollProgress: Double
        let imageBase64: String
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
            case focusedInput = "focused_input"
            case focusedInputLabel = "focused_input_label"
        }
    }

    private struct BrowserAcceptanceScrollRequest: Encodable, Sendable {
        let amount: Double
    }

    private struct BrowserAcceptanceTapRequest: Encodable, Sendable {
        let x: Double
        let y: Double
    }

    private struct BrowserAcceptanceFillRequest: Encodable, Sendable {
        let text: String
        let submit: Bool
    }

    private struct BrowserAcceptanceEmptyRequest: Encodable, Sendable {}

    private enum BrowserAcceptanceAction: String, Sendable {
        case back
        case fill
        case refresh
        case scroll
        case tap
    }

    private struct BrowserAcceptanceMetrics: Sendable {
        let imageBytes: Int
        let sessionSequence: UInt64
    }

    private enum BrowserAcceptanceError: LocalizedError, Sendable {
        case invalidTargetURL
        case invalidResponse
        case responseTooLarge
        case invalidSession
        case invalidFrame
        case invalidImage
        case interaction(String)
        case unexpectedTransport
        case network(URLError.Code)
        case http(Int, String?)

        var errorDescription: String? {
            switch self {
            case .invalidTargetURL:
                return "动态浏览验收网址无效。"
            case .invalidResponse:
                return "动态浏览网关返回了无法识别的响应。"
            case .responseTooLarge:
                return "动态浏览网关响应超过手表安全上限。"
            case .invalidSession:
                return "动态浏览网关返回了无效会话标识。"
            case .invalidFrame:
                return "动态浏览网关返回的画面元数据无效。"
            case .invalidImage:
                return "动态浏览网关返回的 PNG/JPEG 画面无效或过大。"
            case .interaction(let detail):
                return "动态浏览交互验收失败：\(detail)"
            case .unexpectedTransport:
                return "交互请求没有使用 iPhone 本地 WebKit 免费通道。"
            case .network(let code):
                return "动态浏览网络请求失败（\(code.rawValue)）。"
            case .http(let status, _):
                return "动态浏览网关拒绝了会话请求（HTTP \(status)）。"
            }
        }
    }

    private final class BrowserAcceptanceRedirectDelegate: NSObject,
        URLSessionTaskDelegate,
        @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private final class BrowserAcceptanceClient: @unchecked Sendable {
        private static let maximumResponseBytes = 250_000
        private let baseURL: URL
        private let token: String
        private let session: URLSession
        private let redirectDelegate: BrowserAcceptanceRedirectDelegate

        init(serverURL: String, token: String) throws {
            let gateway = try GatewayConfiguration(serverURL: serverURL, token: token)
            baseURL = gateway.baseURL
            self.token = gateway.token

            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.waitsForConnectivity = true
            configuration.allowsCellularAccess = true
            configuration.allowsExpensiveNetworkAccess = true
            configuration.allowsConstrainedNetworkAccess = true
            configuration.timeoutIntervalForRequest = 75
            configuration.timeoutIntervalForResource = 90
            configuration.httpMaximumConnectionsPerHost = 1
            let redirectDelegate = BrowserAcceptanceRedirectDelegate()
            self.redirectDelegate = redirectDelegate
            session = URLSession(
                configuration: configuration,
                delegate: redirectDelegate,
                delegateQueue: nil
            )
        }

        deinit {
            session.invalidateAndCancel()
        }

        func open(_ destination: URL) async throws -> BrowserAcceptanceFrame {
            let endpoint = ["v1", "sessions", "open"].reduce(baseURL) {
                $0.appendingPathComponent($1)
            }
            var request = authorizedRequest(url: endpoint, method: "POST")
            do {
                request.httpBody = try JSONEncoder().encode(
                    BrowserAcceptanceOpenRequest(
                        url: destination.absoluteString,
                        viewportWidth: 396,
                        viewportHeight: 484
                    )
                )
            } catch {
                throw BrowserAcceptanceError.invalidTargetURL
            }

            let (data, response) = try await fetchData(
                for: request,
                maximumBytes: Self.maximumResponseBytes
            )
            guard let http = response as? HTTPURLResponse else {
                throw BrowserAcceptanceError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let serverError = try? JSONDecoder().decode(GatewayErrorResponse.self, from: data)
                throw BrowserAcceptanceError.http(http.statusCode, serverError?.code)
            }
            do {
                return try JSONDecoder().decode(BrowserAcceptanceFrame.self, from: data)
            } catch {
                throw BrowserAcceptanceError.invalidResponse
            }
        }

        func action<Body: Encodable>(
            sessionID: String,
            action: BrowserAcceptanceAction,
            body: Body
        ) async throws -> BrowserAcceptanceFrame {
            let endpoint = ["v1", "sessions", sessionID, action.rawValue].reduce(baseURL) {
                $0.appendingPathComponent($1)
            }
            var request = authorizedRequest(url: endpoint, method: "POST")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw BrowserAcceptanceError.invalidResponse
            }
            let (data, response) = try await fetchData(
                for: request,
                maximumBytes: Self.maximumResponseBytes
            )
            guard let http = response as? HTTPURLResponse else {
                throw BrowserAcceptanceError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let serverError = try? JSONDecoder().decode(GatewayErrorResponse.self, from: data)
                throw BrowserAcceptanceError.http(http.statusCode, serverError?.code)
            }
            do {
                return try JSONDecoder().decode(BrowserAcceptanceFrame.self, from: data)
            } catch {
                throw BrowserAcceptanceError.invalidResponse
            }
        }

        func close(sessionID: String) async {
            let endpoint = ["v1", "sessions", sessionID].reduce(baseURL) {
                $0.appendingPathComponent($1)
            }
            var request = authorizedRequest(url: endpoint, method: "DELETE")
            request.timeoutInterval = 8
            _ = try? await fetchData(for: request, maximumBytes: 4_096)
        }

        private func authorizedRequest(url: URL, method: String) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if method == "POST" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("WatchBrowser/1.0 watchOS", forHTTPHeaderField: "User-Agent")
            return request
        }

        private func fetchData(
            for request: URLRequest,
            maximumBytes: Int
        ) async throws -> (Data, URLResponse) {
            let deadline = WatchRelayRequestDeadline(request: request)
            do {
                let relayed = try await WatchConnectivityRelayClient.shared.send(
                    request,
                    maximumResponseBytes: maximumBytes,
                    timeout: WatchRelayFallbackPolicy.relayTimeout(for: request)
                )
                guard let requestURL = request.url else {
                    throw BrowserAcceptanceError.invalidResponse
                }
                return (
                    relayed.body ?? Data(),
                    try relayed.urlResponse(for: requestURL)
                )
            } catch let error as BrowserAcceptanceError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let relayError as WatchConnectivityRelayError {
                guard WatchRelayFallbackPolicy.shouldUseDirectNetwork(
                    after: relayError,
                    for: request
                ) else {
                    throw BrowserAcceptanceError.invalidResponse
                }
                let directRequest: URLRequest
                do {
                    directRequest = try deadline.directFallbackRequest(from: request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let deadlineError as URLError {
                    throw BrowserAcceptanceError.network(deadlineError.code)
                }
                return try await fetchDirectData(
                    for: directRequest,
                    maximumBytes: maximumBytes
                )
            } catch {
                throw BrowserAcceptanceError.invalidResponse
            }
        }

        private func fetchDirectData(
            for request: URLRequest,
            maximumBytes: Int
        ) async throws -> (Data, URLResponse) {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                if response.expectedContentLength > Int64(maximumBytes) {
                    throw BrowserAcceptanceError.responseTooLarge
                }
                var data = Data()
                data.reserveCapacity(min(maximumBytes, 65_536))
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maximumBytes else {
                        throw BrowserAcceptanceError.responseTooLarge
                    }
                    data.append(byte)
                }
                return (data, response)
            } catch let error as BrowserAcceptanceError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let directError as URLError {
                if Task.isCancelled || directError.code == .cancelled {
                    throw CancellationError()
                }
                throw BrowserAcceptanceError.network(directError.code)
            } catch {
                throw BrowserAcceptanceError.invalidResponse
            }
        }
    }

    private static func runAcceptanceProbe(
        id: String,
        kind: String,
        webInput: String?,
        gatewayOverride: GatewayConfiguration? = nil,
        deepSeekAPIKeyOverride: String? = nil
    ) async -> AcceptanceReceipt {
        do {
            switch kind {
            case "ai":
                let storedAPIKey: String?
                if let deepSeekAPIKeyOverride {
                    storedAPIKey = deepSeekAPIKeyOverride
                } else {
                    storedAPIKey = try storedDeepSeekAPIKey()
                }
                let apiKey = storedAPIKey?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let gateway: GatewayConfiguration?
                if let gatewayOverride {
                    gateway = gatewayOverride
                } else {
                    gateway = try storedGatewayConfiguration()
                }
                let requestPath = AIRequestPathPolicy.select(
                    hasDeepSeekCredential: apiKey.map { (8...512).contains($0.count) } == true,
                    hasValidCloudflareConfiguration: gateway != nil
                )
                guard requestPath != .unconfigured else {
                    return AcceptanceReceipt(
                        attemptID: id,
                        kind: kind,
                        succeeded: false,
                        code: "ai_service_missing",
                        message: "手表尚未配置 DeepSeek API Key 或免费 Cloudflare DeepSeek 转发。"
                    )
                }
                let request = try GatewayAskRequest(
                    question: "请说明 Apple Watch 上独立 AI 问答最重要的两个技术条件，并给出来源。",
                    webSearch: true,
                    deepThinking: true,
                    history: [
                        try GatewayChatMessage(role: .user, content: "我们在讨论手表独立联网。"),
                        try GatewayChatMessage(
                            role: .assistant,
                            content: "好的，我会基于这个上下文继续回答。"
                        )
                    ]
                )
                let streamState = AIStreamProbeState()
                let response: GatewayAskResponse
                switch requestPath {
                case .directDeepSeek:
                    guard let apiKey else { throw DeepSeekServiceError.missingCredential }
                    response = try await DeepSeekService().answerStreaming(
                        request,
                        apiKey: apiKey
                    ) { event in
                        await streamState.record(event)
                    }
                case .cloudflareDeepSeekProxy:
                    guard let gateway else { throw GatewayClientError.tokenNotConfigured }
                    response = try await GatewayClient().answerStreaming(
                        request,
                        serverURL: gateway.baseURL.absoluteString,
                        token: gateway.token
                    ) { event in
                        await streamState.record(event)
                    }
                case .unconfigured:
                    throw DeepSeekServiceError.missingCredential
                }
                let answer = try response.validatedAnswer()
                let snapshot = await streamState.snapshot()
                let reasoningCharacters = response.reasoning?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .count ?? 0

                guard response.webSearchUsed, !response.citations.isEmpty else {
                    return AcceptanceReceipt(
                        attemptID: id,
                        kind: kind,
                        succeeded: false,
                        code: "deepseek_search_missing",
                        message: "设备收到了 DeepSeek 回答，但没有收到可验证的联网来源。",
                        answerCharacters: answer.count,
                        webSearchUsed: response.webSearchUsed,
                        webSearchProvider: providerName(response.webSearchProvider),
                        citationCount: response.citations.count,
                        model: response.model,
                        reasoningCharacters: reasoningCharacters,
                        streamEventCount: snapshot.contentEventCount
                    )
                }
                guard snapshot.metadataReceived,
                      snapshot.doneReceived,
                      snapshot.contentEventCount > 0 else {
                    return AcceptanceReceipt(
                        attemptID: id,
                        kind: kind,
                        succeeded: false,
                        code: "deepseek_stream_missing",
                        message: "DeepSeek 最终答案已收到，但流式事件链不完整。",
                        answerCharacters: answer.count,
                        webSearchUsed: response.webSearchUsed,
                        webSearchProvider: providerName(response.webSearchProvider),
                        citationCount: response.citations.count,
                        model: response.model,
                        reasoningCharacters: reasoningCharacters,
                        streamEventCount: snapshot.contentEventCount
                    )
                }
                return AcceptanceReceipt(
                    attemptID: id,
                    kind: kind,
                    succeeded: true,
                    code: acceptanceAICode(
                        requestPath: requestPath,
                        reasoningReceived: reasoningCharacters > 0
                    ),
                    message: acceptanceAIMessage(
                        requestPath: requestPath,
                        reasoningReceived: reasoningCharacters > 0
                    ),
                    answerCharacters: answer.count,
                    webSearchUsed: response.webSearchUsed,
                    webSearchProvider: providerName(response.webSearchProvider),
                    citationCount: response.citations.count,
                    model: response.model,
                    reasoningCharacters: reasoningCharacters,
                    streamEventCount: snapshot.contentEventCount
                )

            case "web":
                let destination = try WebDestination(rawValue: webInput ?? "https://www.gov.cn/")
                let gateway: GatewayConfiguration?
                if let gatewayOverride {
                    gateway = gatewayOverride
                } else {
                    gateway = try storedGatewayConfiguration()
                }
                if let gateway {
                    let response = try await GatewayClient().read(
                        url: destination.url,
                        serverURL: gateway.baseURL.absoluteString,
                        token: gateway.token
                    )
                    let document = try response.directDocument()
                    return AcceptanceReceipt(
                        attemptID: id,
                        kind: kind,
                        succeeded: true,
                        code: "document_loaded",
                        message: "设备已通过统一网关下载并解析网页正文。",
                        pageTitle: String(document.title.prefix(120)),
                        visibleCharacters: document.text.count,
                        linkCount: document.links.count,
                        pageSource: response.source
                    )
                }
                let loader = DirectWebLoader()
                let result = try await loader.load(destination.url)
                return AcceptanceReceipt(
                    attemptID: id,
                    kind: kind,
                    succeeded: true,
                    code: "document_loaded",
                    message: "设备已下载并解析网页正文。",
                    pageTitle: String(result.document.title.prefix(120)),
                    visibleCharacters: result.document.text.count,
                    linkCount: result.document.links.count,
                    pageSource: "direct"
                )

            case "browser":
                return try await runBrowserAcceptanceProbe(
                    id: id,
                    kind: kind,
                    webInput: webInput,
                    gatewayOverride: gatewayOverride
                )

            default:
                return AcceptanceReceipt(
                    attemptID: id,
                    kind: kind,
                    succeeded: false,
                    code: "unsupported_probe",
                    message: "不支持的自检类型。",
                    answerCharacters: nil,
                    pageTitle: nil
                )
            }
        } catch {
            return AcceptanceReceipt(
                attemptID: id,
                kind: kind,
                succeeded: false,
                code: acceptanceFailureCode(for: error),
                message: error.localizedDescription,
                answerCharacters: nil,
                pageTitle: nil
            )
        }
    }

    private static func runBrowserAcceptanceProbe(
        id: String,
        kind: String,
        webInput: String?,
        gatewayOverride: GatewayConfiguration?
    ) async throws -> AcceptanceReceipt {
        let destination: WebDestination
        do {
            destination = try WebDestination(
                rawValue: webInput
                    ?? "https://example.com/"
            )
        } catch {
            throw BrowserAcceptanceError.invalidTargetURL
        }

        let resolvedGateway: GatewayConfiguration?
        if let gatewayOverride {
            resolvedGateway = gatewayOverride
        } else {
            resolvedGateway = try storedGatewayConfiguration()
        }
        guard let gateway = resolvedGateway else {
            throw GatewayClientError.tokenNotConfigured
        }
        let client = try BrowserAcceptanceClient(
            serverURL: gateway.baseURL.absoluteString,
            token: gateway.token
        )

        var openedSessionID: String?
        var metrics: BrowserAcceptanceMetrics?
        var pageSource: String?
        var probeError: Error?
        do {
            var frame = try await client.open(destination.url)
            let safeSessionID = try validatedBrowserSessionID(frame.sessionID)
            openedSessionID = safeSessionID
            guard PhoneLocalBrowserRoute.isLocalSessionID(safeSessionID) else {
                throw BrowserAcceptanceError.unexpectedTransport
            }
            pageSource = "iphone-local-webkit"

            var previousSequence: UInt64 = 0
            metrics = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .scroll,
                body: BrowserAcceptanceScrollRequest(amount: 0.72)
            )
            metrics = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            guard frame.scrollProgress > 0.05 else {
                throw BrowserAcceptanceError.interaction("向下滚动后进度没有变化。")
            }
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .scroll,
                body: BrowserAcceptanceScrollRequest(amount: -3)
            )
            _ = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            guard frame.scrollProgress < 0.05 else {
                throw BrowserAcceptanceError.interaction("向上滚动后没有回到页面顶部。")
            }
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .tap,
                body: BrowserAcceptanceTapRequest(x: 0.30, y: 0.235)
            )
            _ = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            guard frame.focusedInput else {
                throw BrowserAcceptanceError.interaction("点按后输入框没有获得焦点。")
            }
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .fill,
                body: BrowserAcceptanceFillRequest(text: "watch-ok", submit: true)
            )
            _ = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            guard frame.url.contains("q=watch-ok"), frame.title.contains("watch-ok") else {
                throw BrowserAcceptanceError.interaction("输入提交后页面没有显示测试结果。")
            }
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .back,
                body: BrowserAcceptanceEmptyRequest()
            )
            _ = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            guard !frame.url.contains("q=watch-ok") else {
                throw BrowserAcceptanceError.interaction("返回操作没有离开提交结果页。")
            }
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .tap,
                body: BrowserAcceptanceTapRequest(x: 0.30, y: 0.34)
            )
            _ = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            guard frame.url.contains("page=2"), frame.title.contains("2") else {
                throw BrowserAcceptanceError.interaction("链接点按后没有进入第二页。")
            }
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .back,
                body: BrowserAcceptanceEmptyRequest()
            )
            _ = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
            previousSequence = frame.sequence

            frame = try await client.action(
                sessionID: safeSessionID,
                action: .refresh,
                body: BrowserAcceptanceEmptyRequest()
            )
            metrics = try validatedBrowserMetrics(
                frame,
                sessionID: safeSessionID,
                afterSequence: previousSequence
            )
        } catch {
            probeError = error
        }

        // Keep the free Browser Run session short. Cleanup is best-effort and happens
        // before the receipt is produced, including frame-validation failure paths.
        if let openedSessionID {
            await client.close(sessionID: openedSessionID)
        }

        if let probeError {
            throw probeError
        }
        guard let metrics else {
            throw BrowserAcceptanceError.invalidFrame
        }
        return AcceptanceReceipt(
            attemptID: id,
            kind: kind,
            succeeded: true,
            code: "browser_frame_received",
            message: "设备已通过 iPhone 本地 WebKit 完成载入、滚动、点按、填写、提交、返回、刷新与画面校验。",
            imageBytes: metrics.imageBytes,
            sessionSequence: metrics.sessionSequence,
            pageSource: pageSource
        )
    }

    private static func providerName(_ provider: GatewayWebSearchProvider?) -> String? {
        switch provider {
        case .cloudflare:
            return "cloudflare"
        case .wikimedia:
            return "wikimedia"
        case .other(let value):
            return value
        case .none:
            return nil
        }
    }

    private static func acceptanceAICode(
        requestPath: AIRequestPath,
        reasoningReceived: Bool
    ) -> String {
        let prefix = requestPath == .cloudflareDeepSeekProxy
            ? "deepseek_proxy"
            : "deepseek"
        return reasoningReceived
            ? "\(prefix)_deep_stream_answer_received"
            : "\(prefix)_deep_stream_answer_without_visible_reasoning"
    }

    private static func acceptanceAIMessage(
        requestPath: AIRequestPath,
        reasoningReceived: Bool
    ) -> String {
        let route = requestPath == .cloudflareDeepSeekProxy
            ? "手表已独立直连免费 Cloudflare DeepSeek 转发"
            : "手表已直连 DeepSeek"
        return reasoningReceived
            ? "\(route)，完成多轮、联网搜索、深度思考与流式回答。"
            : "\(route)，完成多轮、联网搜索与流式回答；本次模型未返回可展示的思考内容。"
    }

    private static func storedGatewayConfiguration() throws -> GatewayConfiguration? {
        let serverURL = UserDefaults.standard.string(forKey: "rendererServerURL")
            ?? BrowserServerDefaults.baseURL
        let token = try GatewayTokenStore.migrateLegacyTokenIfNeeded() ?? ""
        return try? GatewayConfiguration(serverURL: serverURL, token: token)
    }

    private static func storedDeepSeekAPIKey() throws -> String? {
        let value = try DeepSeekKeyStore.load()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, (8...512).contains(value.count) else { return nil }
        return value
    }

    private static func validatedBrowserSessionID(_ rawValue: String) throws -> String {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 160,
              rawValue != ".",
              rawValue != "..",
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  let isDigit = (48...57).contains(value)
                  let isUppercase = (65...90).contains(value)
                  let isLowercase = (97...122).contains(value)
                  return isDigit || isUppercase || isLowercase || "-._~:".unicodeScalars.contains(scalar)
              }) else {
            throw BrowserAcceptanceError.invalidSession
        }
        return rawValue
    }

    private static func validatedBrowserMetrics(
        _ frame: BrowserAcceptanceFrame,
        sessionID: String? = nil,
        afterSequence: UInt64 = 0
    ) throws -> BrowserAcceptanceMetrics {
        guard frame.sequence > afterSequence,
              sessionID == nil || frame.sessionID == sessionID else {
            throw BrowserAcceptanceError.invalidFrame
        }

        let trimmedTitle = frame.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle.count <= 1_000,
              let components = URLComponents(string: frame.url),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw BrowserAcceptanceError.invalidFrame
        }

        guard frame.imageBase64.utf8.count >= 80,
              frame.imageBase64.utf8.count <= 110_000,
              let imageData = Data(base64Encoded: frame.imageBase64),
              (64...80_000).contains(imageData.count) else {
            throw BrowserAcceptanceError.invalidImage
        }

        let header = [UInt8](imageData.prefix(8))
        let isPNG = header == [137, 80, 78, 71, 13, 10, 26, 10]
        let isJPEG = imageData.count >= 4
            && imageData[imageData.startIndex] == 0xFF
            && imageData[imageData.startIndex + 1] == 0xD8
            && imageData[imageData.startIndex + 2] == 0xFF
            && imageData[imageData.endIndex - 2] == 0xFF
            && imageData[imageData.endIndex - 1] == 0xD9
        guard isPNG || isJPEG,
              let image = UIImage(data: imageData),
              image.size.width >= 1,
              image.size.height >= 1,
              image.size.width <= 2_048,
              image.size.height <= 2_048 else {
            throw BrowserAcceptanceError.invalidImage
        }

        return BrowserAcceptanceMetrics(
            imageBytes: imageData.count,
            sessionSequence: frame.sequence
        )
    }

    private static func acceptanceFailureCode(for error: Error) -> String {
        if let browserError = error as? BrowserAcceptanceError {
            switch browserError {
            case .invalidTargetURL:
                return "browser_target_invalid"
            case .invalidResponse:
                return "browser_invalid_response"
            case .responseTooLarge:
                return "browser_response_too_large"
            case .invalidSession:
                return "browser_invalid_session"
            case .invalidFrame:
                return "browser_invalid_frame"
            case .invalidImage:
                return "browser_invalid_image"
            case .interaction:
                return "browser_interaction_failed"
            case .unexpectedTransport:
                return "browser_not_phone_local"
            case .network(let code):
                return "browser_url_error_\(code.rawValue)"
            case .http(let status, let code):
                return safeBrowserBackendCode(code) ?? "browser_http_\(status)"
            }
        }
        if let urlError = error as? URLError {
            return "url_error_\(urlError.code.rawValue)"
        }
        if let gatewayError = error as? GatewayClientError {
            switch gatewayError {
            case .serverNotConfigured:
                return "gateway_not_configured"
            case .tokenNotConfigured:
                return "gateway_token_missing"
            case .invalidServerURL:
                return "gateway_url_invalid"
            case .invalidResponse:
                return "gateway_invalid_response"
            case .responseTooLarge:
                return "gateway_response_too_large"
            case .requestTooLarge:
                return "gateway_request_too_large"
            case .network(let code):
                return "gateway_url_error_\(code.rawValue)"
            case .http(let status, let response):
                return response?.code ?? "gateway_http_\(status)"
            case .stream(let response):
                return response.code
            }
        }
        if let deepSeekError = error as? DeepSeekServiceError {
            switch deepSeekError {
            case .missingCredential:
                return "deepseek_key_missing"
            case .invalidCredential:
                return "deepseek_key_invalid"
            case .insufficientBalance:
                return "deepseek_balance_insufficient"
            case .invalidRequest:
                return "deepseek_request_invalid"
            case .invalidResponse:
                return "deepseek_response_invalid"
            case .missingFinalResponse:
                return "deepseek_final_event_missing"
            case .responseTooLarge:
                return "deepseek_response_too_large"
            case .requestTooLarge:
                return "deepseek_request_too_large"
            case .rateLimited:
                return "deepseek_rate_limited"
            case .serviceUnavailable:
                return "deepseek_unavailable"
            case .network(let code):
                return "deepseek_url_error_\(code.rawValue)"
            case .http(let status):
                return "deepseek_http_\(status)"
            }
        }
        if error is DirectWebReaderError {
            return "web_response_rejected"
        }
        if error is DirectWebDocumentError {
            return "web_parse_failed"
        }
        if error is GatewayTokenStoreError {
            return "gateway_keychain_error"
        }
        return "probe_failed"
    }

    private static func safeBrowserBackendCode(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 80,
              value.unicodeScalars.allSatisfy({ scalar in
                  let ascii = scalar.value
                  return (48...57).contains(ascii)
                      || (65...90).contains(ascii)
                      || (97...122).contains(ascii)
                      || scalar == "_"
                      || scalar == "-"
              }) else {
            return nil
        }
        return value
    }

    private static func writeAcceptanceReceipt(_ receipt: AcceptanceReceipt) {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        let receiptURL = cachesURL.appendingPathComponent("acceptance-probe-ack.json")
        let safeAttemptID = receipt.attemptID.filter {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
        do {
            try FileManager.default.createDirectory(
                at: cachesURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(receipt)
            try data.write(to: receiptURL, options: .atomic)
            if !safeAttemptID.isEmpty {
                let uniqueReceiptURL = cachesURL.appendingPathComponent(
                    "acceptance-probe-ack-\(safeAttemptID).json"
                )
                try data.write(to: uniqueReceiptURL, options: .atomic)
            }
        } catch {
            // A missing receipt is treated as a failed probe by the Mac-side verifier.
        }
    }

    private static func removeAcceptanceReceipt() {
        guard let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        try? FileManager.default.removeItem(
            at: cachesURL.appendingPathComponent("acceptance-probe-ack.json")
        )
    }
    #endif
}
