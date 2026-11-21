import Foundation
import UIKit
import Darwin
@preconcurrency import WebKit

private struct PhoneLocalOpenRequest: Decodable {
    let url: String
    let viewportWidth: Int
    let viewportHeight: Int

    enum CodingKeys: String, CodingKey {
        case url
        case viewportWidth = "viewport_width"
        case viewportHeight = "viewport_height"
    }
}

private struct PhoneLocalScrollRequest: Decodable {
    let amount: Double
}

private struct PhoneLocalTapRequest: Decodable {
    let x: Double
    let y: Double
}

private struct PhoneLocalFillRequest: Decodable {
    let text: String
    let submit: Bool
}

private struct PhoneLocalFrameResponse: Encodable {
    let sessionID: String
    let sequence: UInt64
    let url: String
    let title: String
    let canGoBack: Bool
    let scrollProgress: Double
    let imageBase64: String
    let message: String
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
        case message
        case focusedInput = "focused_input"
        case focusedInputLabel = "focused_input_label"
    }
}

private struct PhoneLocalErrorResponse: Encodable {
    let code: String
    let message: String
    let retryable: Bool
}

private struct PhoneLocalDOMSignals: Decodable {
    let url: String
    let title: String
    let textCharacters: Int
    let links: Int
    let images: Int
    let scrollTop: Double
    let scrollHeight: Double
    let viewportHeight: Double
    let focused: Bool
    let focusedLabel: String?

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case textCharacters = "text_chars"
        case links
        case images
        case scrollTop = "scroll_top"
        case scrollHeight = "scroll_height"
        case viewportHeight = "viewport_height"
        case focused
        case focusedLabel = "focused_label"
    }
}

private struct PhoneLocalTapResult: Decodable {
    let link: String?
    let found: Bool
}

private struct PhoneLocalFillResult: Decodable {
    let filled: Bool
}

private struct PhoneLocalOperationContext {
    let requestID: UUID
    let generation: UInt64
    let deadline: ContinuousClock.Instant
}

private enum PhoneLocalActionSettlement {
    case short
    case navigationAware(baselineRevision: UInt64, startingURL: String?)
}

private final class PhoneLocalNoRedirectSessionDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct PhoneLocalBrowserServiceError: Error, Sendable {
    let code: String
    let message: String
    let statusCode: Int
    let retryable: Bool

    static let busy = Self(
        code: "browser_busy",
        message: "iPhone 本地浏览器正在处理上一项操作，请稍后重试。",
        statusCode: 429,
        retryable: true
    )
    static let invalidRequest = Self(
        code: "validation_error",
        message: "本地浏览器请求格式无效。",
        statusCode: 422,
        retryable: false
    )
    static let sessionExpired = Self(
        code: "session_expired",
        message: "iPhone 本地浏览会话已失效，请重新打开网页。",
        statusCode: 410,
        retryable: true
    )
    static let inputNotFocused = Self(
        code: "input_not_focused",
        message: "尚未选中可编辑输入框，请先在网页画面上点按输入框。",
        statusCode: 409,
        retryable: false
    )
    static let cannotGoBack = Self(
        code: "cannot_go_back",
        message: "当前网页没有可返回的上一页。",
        statusCode: 409,
        retryable: false
    )
    static let timedOut = Self(
        code: "browser_timeout",
        message: "iPhone 本地网页加载超时，请检查网络后重试。",
        statusCode: 504,
        retryable: true
    )
    static let rendererUnavailable = Self(
        code: "renderer_unavailable",
        message: "iPhone 本地 WebKit 暂时无法渲染网页；请打开手机端中继后重试。",
        statusCode: 503,
        retryable: true
    )
    static let rendererInitializationUnavailable = Self(
        code: "local_renderer_unavailable",
        message: "iPhone 本地 WebKit 无法初始化，将尝试免费云端兼容模式。",
        statusCode: 503,
        retryable: true
    )
    static let foregroundRequired = Self(
        code: "local_foreground_required",
        message: "请解锁 iPhone，并让“腕上浏览中继”的本地网页预览保持在前台。",
        statusCode: 503,
        retryable: true
    )
    static let localHTTPSRequired = Self(
        code: "local_https_required",
        message: "该网页不是 HTTPS，将尝试免费云端兼容模式。",
        statusCode: 503,
        retryable: true
    )
    static let invalidFrame = Self(
        code: "blank_frame",
        message: "iPhone 已载入网页，但未能生成有效画面。",
        statusCode: 502,
        retryable: true
    )
    static let frameTooLarge = Self(
        code: "frame_too_large",
        message: "网页画面无法压缩到手表传输上限。",
        statusCode: 500,
        retryable: true
    )
    static let webProcessTerminated = Self(
        code: "renderer_unavailable",
        message: "iPhone 网页进程已退出，请重新打开网页。",
        statusCode: 503,
        retryable: true
    )

    static func blocked(_ message: String) -> Self {
        Self(code: "url_blocked", message: message, statusCode: 400, retryable: false)
    }

    static func dns(_ message: String) -> Self {
        Self(code: "dns_resolution_failed", message: message, statusCode: 502, retryable: true)
    }

    static func navigation(_ message: String) -> Self {
        Self(code: "navigation_failed", message: message, statusCode: 502, retryable: true)
    }
}

/// A zero-cost renderer for interactive Watch browsing. It deliberately keeps a
/// single ephemeral WKWebView, never logs page data, and returns the same bounded
/// frame JSON used by the cloud renderer. Cloud sessions remain handled upstream.
@MainActor
final class PhoneLocalBrowserService: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let maximumImageBytes = 42_000
    private static let idleLifetime: TimeInterval = 5 * 60
    private static let navigationBudget: TimeInterval = 18
    private static let actionSettleBudget: TimeInterval = 6
    private static let navigationDetectionBudget: TimeInterval = 1
    nonisolated private static let trustedDNSRequestTimeout: TimeInterval = 4
    nonisolated private static let maximumTrustedDNSResponseBytes = 64 * 1_024
    private static let contentRuleIdentifier = "WatchBrowserPhoneLocalSiteBoundary-v2"

    private let clock = ContinuousClock()
    private var webView: WKWebView?
    private var sessionID: String?
    private var sequence: UInt64 = 0
    private var lastAccess = Date.distantPast
    private var currentAllowedHost: String?
    private var navigationFailure: PhoneLocalBrowserServiceError?
    private var operationGeneration: UInt64 = 0
    private var activeOperationGeneration: UInt64?
    private var navigationRevision: UInt64 = 0
    private var pendingMainFramePolicyDecisionIDs: Set<UUID> = []
    private weak var renderHost: PhoneBrowserRenderHostView?
    private var applicationIsActive = false
    private var renderingWasAvailable = false

    var isForegroundRendererReady: Bool {
        applicationIsActive && renderHost?.window != nil
    }

    func attachRenderHost(_ host: PhoneBrowserRenderHostView) {
        if renderHost !== host {
            renderHost?.display(nil)
            renderHost = host
        }
        host.display(webView)
        updateRenderingAvailability()
    }

    func detachRenderHost(_ host: PhoneBrowserRenderHostView) {
        guard renderHost === host else { return }
        host.display(nil)
        renderHost = nil
        updateRenderingAvailability()
    }

    func renderHostWindowDidChange(_ host: PhoneBrowserRenderHostView) {
        guard renderHost === host else { return }
        updateRenderingAvailability()
    }

    func setApplicationActive(_ isActive: Bool) {
        applicationIsActive = isActive
        updateRenderingAvailability()
    }

    func handle(_ request: WatchRelayRequest) async -> WatchRelayHTTPResponse {
        let route = PhoneLocalBrowserRoute.classify(
            method: request.method.rawValue,
            path: request.path
        )
        do {
            switch route {
            case .close(let requestedSessionID):
                guard requestedSessionID == sessionID else {
                    throw PhoneLocalBrowserServiceError.sessionExpired
                }
                // Closing is deliberately allowed to preempt an in-flight local
                // operation. Advancing the generation makes every late await from
                // that operation fail before it can publish a frame or mutate state.
                closeCurrentSession()
                return try WatchRelayHTTPResponse(statusCode: 204, headers: [:], body: nil)
            case .upstream:
                throw PhoneLocalBrowserServiceError.invalidRequest
            case .open, .action:
                break
            }

            guard isForegroundRendererReady else {
                throw PhoneLocalBrowserServiceError.foregroundRequired
            }
            guard activeOperationGeneration == nil else {
                throw PhoneLocalBrowserServiceError.busy
            }
            if Date().timeIntervalSince(lastAccess) >= Self.idleLifetime {
                closeCurrentSession()
            }
            let context = try beginOperation(for: request)
            defer { finishOperation(context) }

            switch route {
            case .open:
                let response = try await open(request, context: context)
                try checkOperation(context)
                return response
            case .action(let requestedSessionID, let action):
                let response = try await operate(
                    request,
                    sessionID: requestedSessionID,
                    action: action,
                    context: context
                )
                try checkOperation(context)
                return response
            case .close, .upstream:
                preconditionFailure("Handled before starting a local operation")
            }
        } catch is CancellationError {
            return errorResponse(
                .init(
                    code: "browser_cancelled",
                    message: "iPhone 本地浏览操作已取消。",
                    statusCode: 499,
                    retryable: true
                )
            )
        } catch let error as PhoneLocalBrowserServiceError {
            return errorResponse(error)
        } catch let error as PhoneLocalBrowserURLPolicyError {
            return errorResponse(serviceError(for: error))
        } catch {
            return errorResponse(.rendererUnavailable)
        }
    }

    private func open(
        _ request: WatchRelayRequest,
        context: PhoneLocalOperationContext
    ) async throws -> WatchRelayHTTPResponse {
        let body: PhoneLocalOpenRequest = try decodeBody(
            request.body,
            allowedKeys: ["url", "viewport_width", "viewport_height"]
        )
        guard body.url.utf8.count <= PhoneLocalBrowserURLPolicy.maximumURLBytes,
              (160...512).contains(body.viewportWidth),
              (160...640).contains(body.viewportHeight) else {
            throw PhoneLocalBrowserServiceError.invalidRequest
        }
        let destination = try await validateDestination(body.url)
        try checkOperation(context)
        let candidate: WKWebView
        do {
            candidate = try await makeWebView(
                width: body.viewportWidth,
                height: body.viewportHeight,
                allowedHost: destination.host
            )
        } catch {
            try checkOperation(context)
            throw PhoneLocalBrowserServiceError.rendererInitializationUnavailable
        }
        try checkOperation(context)

        closeCurrentSession(invalidateOperation: false)
        webView = candidate
        renderHost?.display(candidate)
        currentAllowedHost = destination.host
        sessionID = PhoneLocalBrowserRoute.makeSessionID()
        sequence = 0
        navigationFailure = nil

        let baselineRevision = navigationRevision
        let startingURL = candidate.url?.absoluteString
        candidate.load(URLRequest(
            url: destination.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.navigationBudget
        ))
        do {
            try await settleAfterPotentialNavigation(
                candidate,
                baselineRevision: baselineRevision,
                startingURL: startingURL,
                context: context
            )
            try checkOperation(context, webView: candidate)
            let response = try await frame(
                message: "由 iPhone 本地 WebKit 免费载入。",
                context: context
            )
            try checkOperation(context, webView: candidate)
            return response
        } catch {
            if isCurrentOperation(context) {
                closeCurrentSession()
            }
            throw error
        }
    }

    private func operate(
        _ request: WatchRelayRequest,
        sessionID requestedSessionID: String,
        action: PhoneLocalBrowserAction,
        context: PhoneLocalOperationContext
    ) async throws -> WatchRelayHTTPResponse {
        guard requestedSessionID == sessionID, let webView else {
            throw PhoneLocalBrowserServiceError.sessionExpired
        }
        let message: String
        var settlement = PhoneLocalActionSettlement.short
        switch action {
        case .scroll:
            let body: PhoneLocalScrollRequest = try decodeBody(
                request.body,
                allowedKeys: ["amount"]
            )
            guard body.amount.isFinite, (-3...3).contains(body.amount) else {
                throw PhoneLocalBrowserServiceError.invalidRequest
            }
            _ = try await webView.callAsyncJavaScript(
                """
                const delta = Math.max(-3, Math.min(3, Number(amount)))
                  * Math.max(1, window.innerHeight || 1);
                window.scrollBy({ top: delta, left: 0, behavior: 'instant' });
                return true;
                """,
                arguments: ["amount": body.amount],
                in: nil,
                contentWorld: .page
            )
            try checkOperation(context, webView: webView)
            message = "iPhone 本地网页已滚动。"
        case .tap:
            let body: PhoneLocalTapRequest = try decodeBody(
                request.body,
                allowedKeys: ["x", "y"]
            )
            guard body.x.isFinite,
                  body.y.isFinite,
                  (0...1).contains(body.x),
                  (0...1).contains(body.y) else {
                throw PhoneLocalBrowserServiceError.invalidRequest
            }
            let baselineRevision = navigationRevision
            let startingURL = webView.url?.absoluteString
            navigationFailure = nil
            let raw = try await webView.callAsyncJavaScript(
                """
                const px = Math.max(0, Math.min(1, Number(x))) * Math.max(1, window.innerWidth);
                const py = Math.max(0, Math.min(1, Number(y))) * Math.max(1, window.innerHeight);
                let element = document.elementFromPoint(px, py);
                if (!element) return JSON.stringify({ found: false, link: null });
                const anchor = element.closest ? element.closest('a[href]') : null;
                if (anchor && /^https?:/i.test(anchor.href || '')) {
                  return JSON.stringify({ found: true, link: anchor.href });
                }
                if (typeof element.focus === 'function') element.focus({ preventScroll: true });
                if (typeof element.click === 'function') element.click();
                return JSON.stringify({ found: true, link: null });
                """,
                arguments: ["x": body.x, "y": body.y],
                in: nil,
                contentWorld: .page
            )
            try checkOperation(context, webView: webView)
            let result: PhoneLocalTapResult = try decodeJavaScriptJSON(raw)
            guard result.found else {
                throw PhoneLocalBrowserServiceError.navigation("点按位置没有可交互的网页元素。")
            }
            if let link = result.link {
                let destination = try await validateDestination(link)
                try checkOperation(context, webView: webView)
                try await applySiteBoundary(destination.host, to: webView)
                try checkOperation(context, webView: webView)
                currentAllowedHost = destination.host
                navigationFailure = nil
                webView.load(URLRequest(
                    url: destination.url,
                    cachePolicy: .useProtocolCachePolicy,
                    timeoutInterval: Self.navigationBudget
                ))
            }
            settlement = .navigationAware(
                baselineRevision: baselineRevision,
                startingURL: startingURL
            )
            message = "iPhone 本地网页已点按。"
        case .fill:
            let body: PhoneLocalFillRequest = try decodeBody(
                request.body,
                allowedKeys: ["text", "submit"]
            )
            guard body.text.count <= 500 else {
                throw PhoneLocalBrowserServiceError.invalidRequest
            }
            let baselineRevision = navigationRevision
            let startingURL = webView.url?.absoluteString
            navigationFailure = nil
            let raw = try await webView.callAsyncJavaScript(
                """
                const element = document.activeElement;
                if (!element) return JSON.stringify({ filled: false });
                const tag = String(element.tagName || '').toLowerCase();
                const inputType = tag === 'input'
                  ? String(element.getAttribute('type') || 'text').toLowerCase()
                  : '';
                const editableTypes = new Set(['text','search','url','tel','email','password','number']);
                const editable = tag === 'textarea'
                  || (tag === 'input' && editableTypes.has(inputType))
                  || element.isContentEditable;
                if (!editable || element.disabled || element.readOnly) {
                  return JSON.stringify({ filled: false });
                }
                if (element.isContentEditable) {
                  element.textContent = String(value);
                } else {
                  const prototype = tag === 'textarea'
                    ? window.HTMLTextAreaElement.prototype
                    : window.HTMLInputElement.prototype;
                  const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
                  if (setter) setter.call(element, String(value));
                  else element.value = String(value);
                }
                element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: String(value) }));
                element.dispatchEvent(new Event('change', { bubbles: true }));
                if (Boolean(submit)) {
                  const form = element.form || element.closest?.('form');
                  if (form && typeof form.requestSubmit === 'function') form.requestSubmit();
                  else element.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
                }
                return JSON.stringify({ filled: true });
                """,
                arguments: ["value": body.text, "submit": body.submit],
                in: nil,
                contentWorld: .page
            )
            try checkOperation(context, webView: webView)
            let result: PhoneLocalFillResult = try decodeJavaScriptJSON(raw)
            guard result.filled else {
                throw PhoneLocalBrowserServiceError.inputNotFocused
            }
            message = body.submit
                ? "iPhone 本地网页已填写并提交。"
                : "iPhone 本地网页已填写。"
            if body.submit {
                settlement = .navigationAware(
                    baselineRevision: baselineRevision,
                    startingURL: startingURL
                )
            }
        case .back:
            _ = try decodeEmptyBody(request.body)
            guard let backURL = webView.backForwardList.backItem?.url else {
                throw PhoneLocalBrowserServiceError.cannotGoBack
            }
            let destination = try await validateDestination(backURL.absoluteString)
            try checkOperation(context, webView: webView)
            try await applySiteBoundary(destination.host, to: webView)
            try checkOperation(context, webView: webView)
            currentAllowedHost = destination.host
            navigationFailure = nil
            let baselineRevision = navigationRevision
            let startingURL = webView.url?.absoluteString
            guard webView.goBack() != nil else {
                throw PhoneLocalBrowserServiceError.cannotGoBack
            }
            settlement = .navigationAware(
                baselineRevision: baselineRevision,
                startingURL: startingURL
            )
            message = "iPhone 本地网页已返回上一页。"
        case .refresh:
            _ = try decodeEmptyBody(request.body)
            navigationFailure = nil
            let baselineRevision = navigationRevision
            let startingURL = webView.url?.absoluteString
            guard webView.reload() != nil else {
                throw PhoneLocalBrowserServiceError.navigation("当前网页无法刷新。")
            }
            settlement = .navigationAware(
                baselineRevision: baselineRevision,
                startingURL: startingURL
            )
            message = "iPhone 本地网页已刷新。"
        }

        switch settlement {
        case .short:
            try await settle(
                webView,
                budget: Self.actionSettleBudget,
                requiresStableLoad: false,
                context: context
            )
        case .navigationAware(let baselineRevision, let startingURL):
            try await settleAfterPotentialNavigation(
                webView,
                baselineRevision: baselineRevision,
                startingURL: startingURL,
                context: context
            )
        }
        try checkOperation(context, webView: webView)
        let response = try await frame(message: message, context: context)
        try checkOperation(context, webView: webView)
        return response
    }

    private func frame(
        message: String,
        context: PhoneLocalOperationContext
    ) async throws -> WatchRelayHTTPResponse {
        guard let webView, let sessionID else {
            throw PhoneLocalBrowserServiceError.sessionExpired
        }
        let signals = try await domSignals(webView)
        try checkOperation(context, webView: webView)
        guard signals.textCharacters > 0 || signals.links > 0 || signals.images > 0 else {
            throw PhoneLocalBrowserServiceError.invalidFrame
        }
        let current = try await validateDestination(signals.url)
        try checkOperation(context, webView: webView)
        if current.host != currentAllowedHost {
            try await applySiteBoundary(current.host, to: webView)
            try checkOperation(context, webView: webView)
            currentAllowedHost = current.host
        }
        let image = try await snapshotJPEG(webView)
        try checkOperation(context, webView: webView)
        let maximumScroll = max(0, signals.scrollHeight - signals.viewportHeight)
        let progress = maximumScroll > 0
            ? min(1, max(0, signals.scrollTop / maximumScroll))
            : 0
        let nextSequence = sequence + 1
        let response = PhoneLocalFrameResponse(
            sessionID: sessionID,
            sequence: nextSequence,
            url: String(current.url.absoluteString.prefix(4_096)),
            title: String(signals.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)),
            canGoBack: webView.canGoBack,
            scrollProgress: progress.isFinite ? progress : 0,
            imageBase64: image.base64EncodedString(),
            message: message,
            focusedInput: signals.focused,
            focusedInputLabel: signals.focusedLabel.map { String($0.prefix(120)) }
        )
        let body = try JSONEncoder().encode(response)
        guard body.count <= WatchRelayPolicy.maximumBodyBytes else {
            throw PhoneLocalBrowserServiceError.frameTooLarge
        }
        let relay = try WatchRelayHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: body
        )
        do {
            _ = try WatchRelayCodec.encode(
                .response(WatchRelayResponse(requestID: context.requestID, payload: .http(relay)))
            )
        } catch {
            throw PhoneLocalBrowserServiceError.frameTooLarge
        }
        try checkOperation(context, webView: webView)
        sequence = nextSequence
        lastAccess = Date()
        return relay
    }

    private func domSignals(_ webView: WKWebView) async throws -> PhoneLocalDOMSignals {
        let raw = try await webView.callAsyncJavaScript(
            """
            const element = document.activeElement;
            const tag = String(element?.tagName || '').toLowerCase();
            const inputType = tag === 'input'
              ? String(element.getAttribute('type') || 'text').toLowerCase()
              : '';
            const editableTypes = new Set(['text','search','url','tel','email','password','number']);
            const focused = Boolean(element) && !element.disabled && !element.readOnly && (
              tag === 'textarea' || (tag === 'input' && editableTypes.has(inputType)) || element.isContentEditable
            );
            let label = null;
            if (focused) {
              const labels = element.labels
                ? Array.from(element.labels).map(item => item.innerText || item.textContent || '').join(' ')
                : '';
              label = element.getAttribute('aria-label') || labels
                || element.getAttribute('placeholder') || element.getAttribute('name')
                || element.getAttribute('title') || null;
              if (label) label = String(label).replace(/\\s+/g, ' ').trim().slice(0, 120) || null;
            }
            const root = document.scrollingElement || document.documentElement;
            const bodyText = document.body?.innerText?.trim() || '';
            return JSON.stringify({
              url: location.href,
              title: document.title || '',
              text_chars: Math.min(100000, bodyText.length),
              links: document.querySelectorAll('a[href]').length,
              images: document.querySelectorAll('img,svg,canvas,video').length,
              scroll_top: Math.max(0, root?.scrollTop || window.scrollY || 0),
              scroll_height: Math.max(root?.scrollHeight || 0, document.body?.scrollHeight || 0),
              viewport_height: Math.max(1, window.innerHeight || 1),
              focused,
              focused_label: label
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        return try decodeJavaScriptJSON(raw)
    }

    private func snapshotJPEG(_ webView: WKWebView) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        configuration.afterScreenUpdates = true
        let image: UIImage
        do {
            image = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            throw PhoneLocalBrowserServiceError.rendererUnavailable
        }

        for scale in [1.0, 0.85, 0.70] {
            let size = CGSize(
                width: max(1, webView.bounds.width * scale),
                height: max(1, webView.bounds.height * scale)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in [0.60, 0.45, 0.30, 0.20, 0.10, 0.03] {
                if let data = rendered.jpegData(compressionQuality: quality),
                   data.count <= Self.maximumImageBytes {
                    return data
                }
            }
        }
        throw PhoneLocalBrowserServiceError.frameTooLarge
    }

    private func makeWebView(
        width: Int,
        height: Int,
        allowedHost: String
    ) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        configuration.suppressesIncrementalRendering = false
        configuration.upgradeKnownHostsToHTTPS = true
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1 WatchBrowserLocal/1.0"
        try await applySiteBoundary(allowedHost, to: webView)
        return webView
    }

    private func applySiteBoundary(_ host: String, to webView: WKWebView) async throws {
        let escaped = NSRegularExpression.escapedPattern(for: host)
        let hostPattern: String
        if host.contains(":") {
            hostPattern = "\\[\(escaped)\\]"
        } else {
            hostPattern = escaped
        }
        // WKContentRuleList's regular-expression subset does not support
        // disjunctions. Absolute HTTP(S) URLs always contain a slash after the
        // authority, so this exact-host expression also blocks suffix-confusion
        // hosts and unverified subdomains without using `|`.
        let allowedURL = "^https://\(hostPattern)(:443)?/"
        let rules: [[String: Any]] = [
            [
                "trigger": ["url-filter": ".*"],
                "action": ["type": "block"]
            ],
            [
                "trigger": [
                    "url-filter": allowedURL,
                    "url-filter-is-case-sensitive": false
                ],
                "action": ["type": "ignore-previous-rules"]
            ],
            [
                "trigger": ["url-filter": "^about:blank"],
                "action": ["type": "ignore-previous-rules"]
            ],
            [
                "trigger": ["url-filter": "^data:"],
                "action": ["type": "ignore-previous-rules"]
            ],
            [
                "trigger": ["url-filter": "^blob:https://"],
                "action": ["type": "ignore-previous-rules"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: rules, options: [])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw PhoneLocalBrowserServiceError.rendererUnavailable
        }
        let ruleList = try await compileRuleList(encoded)
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.configuration.userContentController.add(ruleList)
    }

    private func compileRuleList(_ encoded: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: Self.contentRuleIdentifier,
                encodedContentRuleList: encoded
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(
                        throwing: error ?? PhoneLocalBrowserServiceError.rendererUnavailable
                    )
                }
            }
        }
    }

    private func settleAfterPotentialNavigation(
        _ webView: WKWebView,
        baselineRevision: UInt64,
        startingURL: String?,
        context: PhoneLocalOperationContext
    ) async throws {
        let observationDeadline = min(
            context.deadline,
            clock.now.advanced(by: .seconds(Self.navigationDetectionBudget))
        )
        while clock.now < observationDeadline {
            try checkOperation(context, webView: webView)
            if let navigationFailure {
                self.navigationFailure = nil
                throw navigationFailure
            }
            if navigationRevision != baselineRevision
                || !pendingMainFramePolicyDecisionIDs.isEmpty
                || webView.isLoading
                || webView.url?.absoluteString != startingURL {
                try await settle(
                    webView,
                    budget: Self.navigationBudget,
                    requiresStableLoad: true,
                    minimumReadyNavigationRevision: baselineRevision &+ 2,
                    context: context
                )
                try checkOperation(context, webView: webView)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
            try checkOperation(context, webView: webView)
        }

        // A click or form submission may be handled entirely in-page. Only after a
        // full navigation-observation window do we use the shorter DOM settle path.
        try await settle(
            webView,
            budget: Self.actionSettleBudget,
            requiresStableLoad: false,
            minimumReadyNavigationRevision: nil,
            context: context
        )
        try checkOperation(context, webView: webView)
    }

    private func settle(
        _ webView: WKWebView,
        budget: TimeInterval,
        requiresStableLoad: Bool,
        minimumReadyNavigationRevision: UInt64? = nil,
        context: PhoneLocalOperationContext
    ) async throws {
        let deadline = min(
            context.deadline,
            clock.now.advanced(by: .seconds(budget))
        )
        var stableReadyChecks = 0
        var readyWhileLoadingChecks = 0
        while clock.now < deadline {
            try checkOperation(context, webView: webView)
            if let navigationFailure {
                self.navigationFailure = nil
                throw navigationFailure
            }
            let readyState = try? await webView.evaluateJavaScript(
                "document.readyState",
                in: nil,
                contentWorld: .page
            ) as? String
            try checkOperation(context, webView: webView)
            let isReady = readyState == "interactive" || readyState == "complete"
            let committedRequestedNavigation = minimumReadyNavigationRevision.map {
                navigationRevision >= $0
            } ?? true
            if isReady && (
                !requiresStableLoad
                    || (committedRequestedNavigation
                        && pendingMainFramePolicyDecisionIDs.isEmpty
                        && !webView.isLoading)
            ) {
                stableReadyChecks += 1
                readyWhileLoadingChecks = 0
                if stableReadyChecks >= 2 { return }
            } else if isReady
                && requiresStableLoad
                && committedRequestedNavigation
                && pendingMainFramePolicyDecisionIDs.isEmpty {
                stableReadyChecks = 0
                readyWhileLoadingChecks += 1
                if readyWhileLoadingChecks >= 12 {
                    webView.stopLoading()
                }
            } else {
                stableReadyChecks = 0
                readyWhileLoadingChecks = 0
            }
            try await Task.sleep(for: .milliseconds(150))
            try checkOperation(context, webView: webView)
        }
        webView.stopLoading()
        try checkOperation(context, webView: webView)
        if let navigationFailure {
            self.navigationFailure = nil
            throw navigationFailure
        }
        throw PhoneLocalBrowserServiceError.timedOut
    }

    private func validateDestination(
        _ rawURL: String
    ) async throws -> PhoneLocalBrowserValidatedURL {
        let destination = try PhoneLocalBrowserURLPolicy.validateStructure(rawURL)
        if !destination.isIPAddress {
            let systemAddresses = try await Self.resolve(host: destination.host)
            if PhoneLocalBrowserURLPolicy.requiresTrustedDNSFallback(
                forSystemAddresses: systemAddresses
            ) {
                let trustedAddresses = try await Self.resolveWithTrustedDNS(
                    host: destination.host
                )
                try PhoneLocalBrowserURLPolicy.validateResolvedAddresses(trustedAddresses)
            } else {
                try PhoneLocalBrowserURLPolicy.validateResolvedAddresses(systemAddresses)
            }
        }
        return destination
    }

    nonisolated private static func resolve(host: String) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_flags = AI_ADDRCONFIG
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            var first: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &first)
            guard status == 0, let first else {
                throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
            }
            defer { freeaddrinfo(first) }

            var addresses: Set<String> = []
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let current = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    current.pointee.ai_addr,
                    socklen_t(current.pointee.ai_addrlen),
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    addresses.insert(String(decoding: bytes, as: UTF8.self))
                }
                cursor = current.pointee.ai_next
            }
            guard !addresses.isEmpty else {
                throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
            }
            return addresses.sorted()
        }.value
    }

    nonisolated private static func resolveWithTrustedDNS(
        host: String
    ) async throws -> [String] {
        async let ipv4 = queryTrustedDNS(host: host, type: 1)
        async let ipv6 = queryTrustedDNS(host: host, type: 28)
        let (ipv4Answers, ipv6Answers) = try await (ipv4, ipv6)
        let answers = Array(Set(ipv4Answers + ipv6Answers)).sorted()
        guard !answers.isEmpty else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }
        return answers
    }

    nonisolated private static func queryTrustedDNS(
        host: String,
        type: Int
    ) async throws -> [String] {
        var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")
        components?.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: String(type))
        ]
        guard let url = components?.url else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: trustedDNSRequestTimeout
        )
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = trustedDNSRequestTimeout
        configuration.timeoutIntervalForResource = trustedDNSRequestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let delegate = PhoneLocalNoRedirectSessionDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == "cloudflare-dns.com",
              (http.url?.port ?? 443) == 443,
              http.url?.path == "/dns-query",
              http.mimeType?.lowercased() == "application/dns-json",
              data.count <= maximumTrustedDNSResponseBytes else {
            throw PhoneLocalBrowserURLPolicyError.dnsResolutionFailed
        }
        let payload = try JSONDecoder().decode(
            PhoneLocalBrowserTrustedDNSResponse.self,
            from: data
        )
        return try payload.validatedAddresses(forHost: host, queryType: type)
    }

    private func beginOperation(
        for request: WatchRelayRequest
    ) throws -> PhoneLocalOperationContext {
        let remainingMilliseconds = request.remainingTimeoutMilliseconds(
            atMillisecondsSince1970: WatchRelayPolicy.millisecondsSince1970()
        )
        guard remainingMilliseconds > 0 else {
            throw PhoneLocalBrowserServiceError.timedOut
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        activeOperationGeneration = generation
        return PhoneLocalOperationContext(
            requestID: request.id,
            generation: generation,
            deadline: clock.now.advanced(
                by: .milliseconds(Int64(remainingMilliseconds))
            )
        )
    }

    private func finishOperation(_ context: PhoneLocalOperationContext) {
        if activeOperationGeneration == context.generation {
            activeOperationGeneration = nil
        }
    }

    private func isCurrentOperation(_ context: PhoneLocalOperationContext) -> Bool {
        operationGeneration == context.generation
            && activeOperationGeneration == context.generation
    }

    private func checkOperation(
        _ context: PhoneLocalOperationContext,
        webView expectedWebView: WKWebView? = nil
    ) throws {
        try Task.checkCancellation()
        guard isForegroundRendererReady else {
            expectedWebView?.stopLoading()
            throw PhoneLocalBrowserServiceError.foregroundRequired
        }
        guard isCurrentOperation(context) else {
            throw CancellationError()
        }
        guard clock.now < context.deadline else {
            expectedWebView?.stopLoading()
            throw PhoneLocalBrowserServiceError.timedOut
        }
        if let expectedWebView {
            guard let currentWebView = webView, currentWebView === expectedWebView else {
                throw CancellationError()
            }
        }
    }

    private func decodeBody<Value: Decodable>(
        _ body: Data?,
        allowedKeys: Set<String>
    ) throws -> Value {
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(object.keys).isSubset(of: allowedKeys) else {
            throw PhoneLocalBrowserServiceError.invalidRequest
        }
        do {
            return try JSONDecoder().decode(Value.self, from: body)
        } catch {
            throw PhoneLocalBrowserServiceError.invalidRequest
        }
    }

    private func decodeEmptyBody(_ body: Data?) throws -> Bool {
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object.isEmpty else {
            throw PhoneLocalBrowserServiceError.invalidRequest
        }
        return true
    }

    private func decodeJavaScriptJSON<Value: Decodable>(_ value: Any?) throws -> Value {
        guard let source = value as? String,
              let data = source.data(using: .utf8) else {
            throw PhoneLocalBrowserServiceError.rendererUnavailable
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw PhoneLocalBrowserServiceError.rendererUnavailable
        }
    }

    private func serviceError(
        for error: PhoneLocalBrowserURLPolicyError
    ) -> PhoneLocalBrowserServiceError {
        switch error {
        case .dnsResolutionFailed:
            return .dns(error.localizedDescription)
        case .unsupportedScheme, .unsupportedPort:
            return .localHTTPSRequired
        default:
            return .blocked(error.localizedDescription)
        }
    }

    private func errorResponse(_ error: PhoneLocalBrowserServiceError) -> WatchRelayHTTPResponse {
        let body = try? JSONEncoder().encode(
            PhoneLocalErrorResponse(
                code: error.code,
                message: error.message,
                retryable: error.retryable
            )
        )
        return (try? WatchRelayHTTPResponse(
            statusCode: error.statusCode,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: body
        )) ?? (try! WatchRelayHTTPResponse(statusCode: 500, headers: [:], body: nil))
    }

    private func closeCurrentSession(invalidateOperation: Bool = true) {
        if invalidateOperation {
            operationGeneration &+= 1
            activeOperationGeneration = nil
        }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        renderHost?.display(nil)
        webView = nil
        sessionID = nil
        sequence = 0
        currentAllowedHost = nil
        navigationFailure = nil
        pendingMainFramePolicyDecisionIDs.removeAll()
        navigationRevision &+= 1
        lastAccess = Date.distantPast
    }

    private func updateRenderingAvailability() {
        let isAvailable = isForegroundRendererReady
        defer { renderingWasAvailable = isAvailable }
        guard renderingWasAvailable, !isAvailable else { return }

        let interruptedOperation = activeOperationGeneration != nil
        operationGeneration &+= 1
        activeOperationGeneration = nil
        webView?.stopLoading()
        navigationFailure = nil

        // An interrupted operation may have partially navigated or mutated the page.
        // Discard that session so it cannot publish a stale frame when the app returns.
        if interruptedOperation {
            closeCurrentSession(invalidateOperation: false)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let rawURL = url.absoluteString
        let decisionGeneration = operationGeneration
        let decisionID = UUID()
        pendingMainFramePolicyDecisionIDs.insert(decisionID)
        Task { @MainActor [weak self, weak webView] in
            defer {
                self?.pendingMainFramePolicyDecisionIDs.remove(decisionID)
            }
            guard let self,
                  let webView,
                  webView === self.webView,
                  decisionGeneration == self.operationGeneration else {
                decisionHandler(.cancel)
                return
            }
            do {
                let destination = try await self.validateDestination(rawURL)
                guard webView === self.webView,
                      decisionGeneration == self.operationGeneration else {
                    decisionHandler(.cancel)
                    return
                }
                if destination.host != self.currentAllowedHost {
                    try await self.applySiteBoundary(destination.host, to: webView)
                    guard webView === self.webView,
                          decisionGeneration == self.operationGeneration else {
                        decisionHandler(.cancel)
                        return
                    }
                    self.currentAllowedHost = destination.host
                }
                decisionHandler(.allow)
            } catch let error as PhoneLocalBrowserURLPolicyError {
                self.navigationFailure = self.serviceError(for: error)
                decisionHandler(.cancel)
            } catch {
                self.navigationFailure = .rendererUnavailable
                decisionHandler(.cancel)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        guard webView === self.webView else { return }
        navigationRevision &+= 1
    }

    func webView(
        _ webView: WKWebView,
        didCommit navigation: WKNavigation!
    ) {
        guard webView === self.webView else { return }
        navigationRevision &+= 1
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        recordNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        recordNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        navigationFailure = .webProcessTerminated
    }

    private func recordNavigationFailure(_ error: Error) {
        let code = (error as? URLError)?.code
        if code == .cancelled, navigationFailure != nil { return }
        if code == .cancelled { return }
        if code == .timedOut {
            navigationFailure = .timedOut
        } else {
            navigationFailure = .navigation("网页导航失败：\(error.localizedDescription)")
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        completionHandler(nil)
    }
}
