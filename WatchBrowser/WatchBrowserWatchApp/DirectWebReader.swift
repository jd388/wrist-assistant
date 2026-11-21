import Foundation
import SwiftUI

enum DirectWebReaderPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String, DirectWebReaderRecovery)
}

enum DirectWebReaderRecovery: Equatable {
    case retry
    case systemPage
    case editInput
}

enum DirectWebReaderSource: Equatable {
    case direct
    case gatewayStatic
    case gatewayBrowser

    var label: String {
        switch self {
        case .direct:
            return "手表直读"
        case .gatewayStatic:
            return "云端正文解析"
        case .gatewayBrowser:
            return "云端动态渲染"
        }
    }
}

struct DirectWebLoadResult: Sendable {
    let document: DirectWebDocument
    let finalURL: URL
}

final class DirectWebLoader: @unchecked Sendable {
    static let maximumResponseBytes = 1_500_000
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = true
        // A cellular-only Watch can need a few seconds to bring up its data path
        // after the app enters the foreground. Waiting avoids an immediate false
        // "offline" result during that handoff.
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func load(_ url: URL) async throws -> DirectWebLoadResult {

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 35
        request.setValue(
            "text/html, application/xhtml+xml, text/plain;q=0.9, application/json;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw DirectWebReaderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DirectWebReaderError.httpStatus(http.statusCode)
        }
        if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
            throw DirectWebReaderError.pageTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Self.maximumResponseBytes, 65_536))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maximumResponseBytes else {
                throw DirectWebReaderError.pageTooLarge
            }
            data.append(byte)
        }

        let finalURL = http.url ?? url
        let document = try DirectWebDocumentParser.parse(
            data: data,
            responseURL: finalURL,
            mimeType: http.mimeType,
            textEncodingName: http.textEncodingName
        )
        try Task.checkCancellation()
        return DirectWebLoadResult(document: document, finalURL: finalURL)
    }
}

@MainActor
final class DirectWebReaderModel: ObservableObject {
    @Published private(set) var phase: DirectWebReaderPhase = .idle
    @Published private(set) var document: DirectWebDocument?
    @Published private(set) var currentURL: URL?
    @Published private(set) var attemptedURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var source: DirectWebReaderSource = .direct
    @Published private(set) var isLoadingThroughGateway = false
    @Published private(set) var lastAttemptUsedGateway = false
    @Published private(set) var needsGatewaySettings = false

    private let loader = DirectWebLoader()
    private let gateway = GatewayClient()
    private var history: [URL] = []
    private var gatewayPageContext: GatewayPageContext?
    private var requestTask: Task<Void, Never>?
    private var operationID: UUID?
    private var pendingNavigationIntent = ReaderNavigationIntent.none

    deinit {
        requestTask?.cancel()
    }

    func openIfNeeded(_ url: URL, serverURL _: String, token _: String) {
        guard currentURL == nil, attemptedURL == nil else { return }
        open(url)
    }

    func open(_ url: URL, rememberCurrentPage: Bool = true) {
        open(url, rememberCurrentPage: rememberCurrentPage, isBackNavigation: false)
    }

    private func open(
        _ url: URL,
        rememberCurrentPage: Bool,
        isBackNavigation: Bool
    ) {
        guard url.scheme == "https" || url.scheme == "http" else {
            phase = .failed(
                "这个链接不是网页地址。请返回并输入 http 或 https 网址。",
                .editInput
            )
            return
        }

        requestTask?.cancel()
        let currentOperationID = UUID()
        operationID = currentOperationID
        attemptedURL = url
        pendingNavigationIntent = ReaderNavigationIntent(
            remembersCurrentPage: rememberCurrentPage,
            isBackNavigation: isBackNavigation
        )
        lastAttemptUsedGateway = false
        needsGatewaySettings = false
        isLoadingThroughGateway = false
        canGoBack = !history.isEmpty
        phase = .loading

        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await loader.load(url)
                guard operationID == currentOperationID else { return }
                let navigationIntent = pendingNavigationIntent
                if navigationIntent.isBackNavigation {
                    if history.last == url {
                        history.removeLast()
                    }
                } else if navigationIntent.shouldPushCurrentPage(
                    hasCurrentDocument: document != nil,
                    currentURL: currentURL,
                    resolvedURL: result.finalURL
                ), let currentURL {
                    history.append(currentURL)
                }
                currentURL = result.finalURL
                attemptedURL = nil
                canGoBack = !history.isEmpty
                document = result.document
                gatewayPageContext = nil
                source = .direct
                pendingNavigationIntent = .none
                phase = .loaded
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled, operationID == currentOperationID else { return }
                phase = .failed(message(for: error), recovery(for: error))
            }
        }
    }

    func openThroughGateway(
        _ url: URL? = nil,
        serverURL: String,
        token: String,
        preferDynamic: Bool = false,
        rememberCurrentPage: Bool? = nil,
        isBackNavigation: Bool? = nil
    ) {
        let isContinuingPendingNavigation = attemptedURL != nil
        guard let target = url ?? attemptedURL ?? currentURL else { return }
        guard target.scheme == "https" || target.scheme == "http" else {
            phase = .failed(
                "这个链接不是网页地址。请返回并输入 http 或 https 网址。",
                .editInput
            )
            return
        }

        requestTask?.cancel()
        let currentOperationID = UUID()
        operationID = currentOperationID
        attemptedURL = target
        if let rememberCurrentPage {
            pendingNavigationIntent = ReaderNavigationIntent(
                remembersCurrentPage: rememberCurrentPage,
                isBackNavigation: isBackNavigation ?? false
            )
        } else if !isContinuingPendingNavigation {
            pendingNavigationIntent = .none
        }
        lastAttemptUsedGateway = true
        needsGatewaySettings = false
        isLoadingThroughGateway = true
        canGoBack = !history.isEmpty
        phase = .loading

        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await gateway.read(
                    url: target,
                    serverURL: serverURL,
                    token: token,
                    preferDynamic: preferDynamic
                )
                let resolvedURL = URL(string: response.finalURL) ?? target
                let resolvedDocument = try response.directDocument()
                guard operationID == currentOperationID else { return }
                let navigationIntent = pendingNavigationIntent
                if navigationIntent.isBackNavigation {
                    if history.last == target {
                        history.removeLast()
                    }
                } else if navigationIntent.shouldPushCurrentPage(
                    hasCurrentDocument: document != nil,
                    currentURL: currentURL,
                    resolvedURL: resolvedURL
                ), let currentURL {
                    history.append(currentURL)
                }
                currentURL = resolvedURL
                attemptedURL = nil
                canGoBack = !history.isEmpty
                document = resolvedDocument
                gatewayPageContext = response.pageContext
                source = response.source == "browser" ? .gatewayBrowser : .gatewayStatic
                isLoadingThroughGateway = false
                pendingNavigationIntent = .none
                phase = .loaded
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled, operationID == currentOperationID else { return }
                isLoadingThroughGateway = false
                if let gatewayError = error as? GatewayClientError {
                    needsGatewaySettings = gatewayError.isConfigurationError
                }
                phase = .failed(message(for: error), recovery(for: error))
            }
        }
    }

    func retry(serverURL: String, token: String) {
        guard let target = attemptedURL ?? currentURL else { return }
        let navigationIntent = pendingNavigationIntent
        if lastAttemptUsedGateway {
            openThroughGateway(
                target,
                serverURL: serverURL,
                token: token,
                rememberCurrentPage: navigationIntent.remembersCurrentPage,
                isBackNavigation: navigationIntent.isBackNavigation
            )
        } else {
            open(
                target,
                rememberCurrentPage: navigationIntent.remembersCurrentPage,
                isBackNavigation: navigationIntent.isBackNavigation
            )
        }
    }

    func reload(serverURL: String, token: String) {
        retry(serverURL: serverURL, token: token)
    }

    func goBack() {
        guard let previous = history.last else { return }
        open(previous, rememberCurrentPage: false, isBackNavigation: true)
    }

    func returnToLoadedPage() {
        guard document != nil else { return }
        requestTask?.cancel()
        operationID = nil
        attemptedURL = nil
        pendingNavigationIntent = .none
        lastAttemptUsedGateway = source != .direct
        isLoadingThroughGateway = false
        phase = .loaded
    }

    func cancel() {
        requestTask?.cancel()
        requestTask = nil
        if phase == .loading {
            isLoadingThroughGateway = false
            phase = .failed("已停止载入。网址已保留，可以直接重试。", .retry)
        }
    }

    var targetURL: URL? {
        attemptedURL ?? currentURL
    }

    var canReturnToLoadedPage: Bool {
        document != nil && attemptedURL != nil
    }

    var currentPageContext: GatewayPageContext? {
        if let gatewayPageContext { return gatewayPageContext }
        guard let document else { return nil }
        return GatewayPageContext(document: document, url: currentURL)
    }

    private func message(for error: Error) -> String {
        if let readerError = error as? DirectWebReaderError {
            return readerError.localizedDescription
        }
        if let parserError = error as? DirectWebDocumentError {
            return parserError.localizedDescription
        }
        if let gatewayError = error as? GatewayClientError {
            return gatewayError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "手表没有可用网络。请在控制中心确认蜂窝信号后重试。"
            case .timedOut:
                return "网页响应超时。网址已保留，请等待信号稳定后重试。"
            case .cannotFindHost, .dnsLookupFailed:
                return "找不到这个网站。请检查域名是否正确后重试。"
            case .cannotConnectToHost:
                return "网站拒绝了连接。可以稍后重试，或返回使用兼容模式。"
            case .secureConnectionFailed,
                 .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot:
                return "网站的 HTTPS 证书无效，为保护安全已停止载入。"
            case .networkConnectionLost:
                return "蜂窝连接中断。网址已保留，可以直接重试。"
            case .appTransportSecurityRequiresSecureConnection:
                return "这个网址只提供不安全的 HTTP，watchOS 已阻止载入。请改用 HTTPS 地址。"
            default:
                return "手表无法下载这个网页。可以重试，或返回使用兼容模式。"
            }
        }
        return "网页读取失败。网址已保留，可以重试或返回使用兼容模式。"
    }

    private func recovery(for error: Error) -> DirectWebReaderRecovery {
        if let gatewayError = error as? GatewayClientError,
           gatewayError.isConfigurationError {
            return .retry
        }
        if let readerError = error as? DirectWebReaderError {
            switch readerError {
            case .pageTooLarge:
                return .systemPage
            case .httpStatus(let status) where status == 401 || status == 403:
                return .systemPage
            case .httpStatus(let status) where status == 404:
                return .editInput
            default:
                return .retry
            }
        }
        if let parserError = error as? DirectWebDocumentError {
            switch parserError {
            case .unsupportedContentType, .emptyBody:
                return .systemPage
            case .searchResultsUnavailable:
                return .editInput
            case .invalidUTF8:
                return .systemPage
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return .editInput
            case .secureConnectionFailed,
                 .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .appTransportSecurityRequiresSecureConnection:
                return .editInput
            default:
                return .retry
            }
        }
        return .retry
    }
}

enum DirectWebReaderError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case pageTooLarge
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "网站没有返回可识别的网页响应。可以重试或使用兼容模式。"
        case .pageTooLarge:
            return "网页内容超过手表直接读取上限。请返回并使用兼容模式。"
        case .httpStatus(let status):
            switch status {
            case 401, 403:
                return "网站要求登录或禁止直接读取。请返回并使用兼容模式。"
            case 404:
                return "网页不存在（404）。请检查网址后重试。"
            case 408, 504:
                return "网站响应超时。网址已保留，可以直接重试。"
            case 429:
                return "网站请求过多。请稍后再试。"
            case 500...599:
                return "网站服务器暂时故障（\(status)）。请稍后重试。"
            default:
                return "网站返回错误（\(status)）。可以重试或使用兼容模式。"
            }
        }
    }
}

struct DirectWebReaderView: View {
    let initialURL: URL
    @Binding var serverURL: String
    @Binding var accessToken: String
    let browser: WatchRemoteBrowser?
    @StateObject private var reader = DirectWebReaderModel()
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var systemOpenNotice: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear
                        .frame(height: 0)
                        .id("reader-top")
                    readerHeader

                    if let systemOpenNotice {
                        Label(systemOpenNotice, systemImage: "info.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }

                    phaseContent
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: reader.currentURL) { _, newURL in
                guard newURL != nil else { return }
                Task { @MainActor in
                    proxy.scrollTo("reader-top", anchor: .top)
                }
            }
        }
        .navigationTitle("网页阅读")
        .task(id: initialURL) {
            reader.openIfNeeded(
                initialURL,
                serverURL: serverURL,
                token: accessToken
            )
        }
        .onDisappear {
            if reader.phase == .loading {
                reader.cancel()
            }
        }
    }

    private var readerHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                reader.isLoadingThroughGateway || reader.source != .direct
                    ? "统一 HTTPS 网关阅读"
                    : "手表网络直接读取",
                systemImage: reader.isLoadingThroughGateway || reader.source != .direct
                    ? "server.rack"
                    : "antenna.radiowaves.left.and.right"
            )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.cyan)

            Text(reader.targetURL?.host ?? initialURL.host ?? "网页")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch reader.phase {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    ProgressView()
                    Text(
                        reader.isLoadingThroughGateway
                            ? "正在通过云端 reader 提取正文…"
                            : "正在直接下载网页正文…"
                    )
                        .font(.caption)
                }
                Button(role: .cancel, action: reader.cancel) {
                    Label("停止载入", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

        case .failed(let message, let recovery):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                failureActions(recovery)

                gatewayRecoveryActions

                if reader.canReturnToLoadedPage {
                    Button(action: reader.returnToLoadedPage) {
                        Label("返回上一网页", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.bordered)
                }

                Text(browser == nil
                    ? "网址与上一次成功内容都会保留；可重试或改用云端正文。"
                    : "网址与上一次成功内容都会保留；可重试、改用云端正文或进入交互浏览（iPhone优先）。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

        case .loaded:
            if let document = reader.document {
                loadedDocument(document)
            }
        }
    }

    @ViewBuilder
    private func failureActions(_ recovery: DirectWebReaderRecovery) -> some View {
        switch recovery {
        case .retry:
            Button {
                reader.retry(serverURL: serverURL, token: accessToken)
            } label: {
                Label("重试当前网址", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button(action: openCurrentURLWithSystem) {
                Label("尝试 Safari 系统网页", systemImage: "safari.fill")
            }
            .buttonStyle(.bordered)

        case .systemPage:
            Button(action: openCurrentURLWithSystem) {
                Label("尝试 Safari 系统网页", systemImage: "safari.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                reader.retry(serverURL: serverURL, token: accessToken)
            } label: {
                Label("仍然重试直读", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

        case .editInput:
            Button(action: dismiss.callAsFunction) {
                Label("修改网址或搜索词", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                reader.retry(serverURL: serverURL, token: accessToken)
            } label: {
                Label("重试当前内容", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var gatewayRecoveryActions: some View {
        if reader.needsGatewaySettings, let browser {
            NavigationLink {
                ServerSettingsView(
                    serverURL: $serverURL,
                    accessToken: $accessToken,
                    browser: browser
                )
            } label: {
                Label("检查网关地址与令牌", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
        } else if reader.needsGatewaySettings {
            Text("备用读取服务尚未配置。")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if hasGatewayConfiguration {
            if !reader.lastAttemptUsedGateway {
                Button {
                    reader.openThroughGateway(
                        serverURL: serverURL,
                        token: accessToken
                    )
                } label: {
                    Label("用云端正文读取", systemImage: "text.document")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            NavigationLink {
                if let browser {
                    ServerSettingsView(
                        serverURL: $serverURL,
                        accessToken: $accessToken,
                        browser: browser
                    )
                } else {
                    EmptyView()
                }
            } label: {
                Label("设置 HTTPS 网关", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
    }

    private func loadedDocument(_ document: DirectWebDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if reader.canGoBack {
                    Button(action: reader.goBack) {
                        Label("返回", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    reader.reload(serverURL: serverURL, token: accessToken)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .font(.caption2)

            Text(document.title)
                .font(.headline)

            Label(reader.source.label, systemImage: sourceIcon)
                .font(.system(size: 9))
                .foregroundStyle(reader.source == .direct ? Color.cyan : Color.green)

            if document.isLikelyDynamic {
                VStack(alignment: .leading, spacing: 5) {
                    Label("此网页主要依赖脚本，直读内容可能不完整。", systemImage: "exclamationmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Button {
                        if hasGatewayConfiguration {
                            reader.openThroughGateway(
                                serverURL: serverURL,
                                token: accessToken,
                                preferDynamic: true
                            )
                        } else {
                            openCurrentURLWithSystem()
                        }
                    } label: {
                        Label(
                            hasGatewayConfiguration ? "云端补全文" : "显示系统原网页",
                            systemImage: hasGatewayConfiguration ? "text.document" : "safari.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }
            }

            Text(document.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            if document.wasTruncated {
                Label("正文较长，已在手表安全长度处截断。", systemImage: "scissors")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            if let pageContext = reader.currentPageContext {
                HStack(spacing: 5) {
                    NavigationLink {
                        AIChatView(
                            serverURL: $serverURL,
                            accessToken: $accessToken,
                            browser: browser,
                            pageContext: pageContext,
                            initialTask: .summarize
                        )
                    } label: {
                        Label("总结", systemImage: "sparkles")
                    }
                    NavigationLink {
                        AIChatView(
                            serverURL: $serverURL,
                            accessToken: $accessToken,
                            browser: browser,
                            pageContext: pageContext,
                            initialTask: .pageQuestion
                        )
                    } label: {
                        Label("问此页", systemImage: "questionmark.bubble")
                    }
                }
                .font(.caption2)
            }

            if !document.links.isEmpty {
                Divider()
                Text("页面链接")
                    .font(.caption.weight(.semibold))

                ForEach(Array(document.links.prefix(24).enumerated()), id: \.element.url) { _, link in
                    Button {
                        reader.open(link.url)
                    } label: {
                        HStack(spacing: 5) {
                            Text(link.title)
                                .font(.caption2)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 8, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(reader.source == .direct
                ? (browser == nil
                    ? "来源页由手表网络直接读取；不会运行 JavaScript。"
                    : "直读不会运行 JavaScript；需要时可改用 HTTPS 网关正文或交互浏览（iPhone优先）。")
                : "正文已由可选的 Cloudflare HTTPS 网关提取；此来源请求不包含 DeepSeek API Key。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var hasGatewayConfiguration: Bool {
        (try? GatewayConfiguration(serverURL: serverURL, token: accessToken)) != nil
    }

    private var sourceIcon: String {
        switch reader.source {
        case .direct:
            return "applewatch.radiowaves.left.and.right"
        case .gatewayStatic:
            return "text.document"
        case .gatewayBrowser:
            return "server.rack"
        }
    }

    private func openCurrentURLWithSystem() {
        guard let url = reader.targetURL else { return }
        if #available(watchOS 26.0, *) {
            systemOpenNotice = "已交给系统网页；若仍无法载入，请返回继续使用直读。"
            openURL(url, prefersInApp: true)
        } else {
            systemOpenNotice = "当前 watchOS 不支持应用内系统网页。"
        }
    }
}
