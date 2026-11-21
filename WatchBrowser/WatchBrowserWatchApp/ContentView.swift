import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("remoteBrowserAddress") private var address = ""
    @AppStorage("browserAddressMigrationVersion") private var addressMigrationVersion = 0
    @AppStorage("rendererServerURL") private var serverURL = BrowserServerDefaults.baseURL
    @State private var accessToken = ""
    @StateObject private var browser = WatchRemoteBrowser()
    @Environment(\.openURL) private var openURL
    @State private var directOpenError: String?
    @State private var systemOpenNotice: String?
    @State private var directReaderURL: URL?
    @State private var showingDirectReader = false
    @State private var gatewayTokenError: String?

    private enum BrowserInputAction {
        case safari
        case direct
        case cloud
    }

    var body: some View {
        NavigationStack {
            AIChatView(
                serverURL: $serverURL,
                accessToken: $accessToken
            )
        }
        .onAppear {
            // This fixed Workers Free endpoint serves page-reading compatibility and,
            // only when the Watch has no local DeepSeek key, the DeepSeek proxy fallback.
            serverURL = BrowserServerDefaults.freeReaderBaseURL
            loadGatewayToken()
        }
    }

    private var startView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .foregroundStyle(.blue)
                    Text("腕上浏览")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Text(appVersionLabel)
                        .font(.system(size: 8, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                Text("网页 / 搜索")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextFieldLink(
                    prompt: Text("说出网址或搜索内容，完成后直接读取"),
                    label: {
                        Label("输入网址或搜索", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    },
                    onSubmit: { value in
                        submitBrowserInput(value, action: .direct)
                    }
                )
                .buttonStyle(.borderedProminent)

                NavigationLink {
                    AIChatView(
                        serverURL: $serverURL,
                        accessToken: $accessToken,
                        browser: browser
                    )
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("AI 问答")
                                .font(.body.weight(.semibold))
                            Text("资料检索、连续追问与深度思考")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)

                Button {
                    submitBrowserInput("https://www.baidu.com", action: .direct)
                } label: {
                    Label("读取百度首页", systemImage: "b.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                TextFieldLink(
                    prompt: Text("系统网页可能拒绝部分网址"),
                    label: {
                        Label("尝试 Safari 原网页", systemImage: "safari.fill")
                            .frame(maxWidth: .infinity)
                    },
                    onSubmit: { value in
                        submitBrowserInput(value, action: .safari)
                    }
                )
                .buttonStyle(.bordered)

                if hasAddress {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("上次输入")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(address)
                            .font(.caption2)
                            .lineLimit(3)

                        HStack(spacing: 5) {
                            Button("Safari") {
                                openWithSystem(rawValue: address)
                            }
                            Button("直读") {
                                openDirect(rawValue: address)
                            }
                        }
                        .font(.caption2)
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                if let systemOpenNotice {
                    Label(systemOpenNotice, systemImage: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }

                if let directOpenError {
                    Label(directOpenError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let gatewayTokenError {
                    Label(gatewayTokenError, systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                NavigationLink {
                    cloudBrowserStartView
                } label: {
                    Label("交互浏览（iPhone优先）", systemImage: "server.rack")
                }
                .font(.caption)

                Text("静态页面优先正文阅读；需要点按、填写或 JavaScript 时使用交互浏览。配对 iPhone 可达时由本地 WebKit 免费渲染，云端仅作兼容后备。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var cloudBrowserStartView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(browser.isServiceReady ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(browser.connectionMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("交互浏览（iPhone优先）")
                    .font(.headline)

                TextFieldLink(
                    prompt: Text("说出网址或搜索内容"),
                    label: {
                        Label("输入并打开", systemImage: "iphone.gen3")
                            .frame(maxWidth: .infinity)
                    },
                    onSubmit: { value in
                        submitBrowserInput(value, action: .cloud)
                    }
                )
                .buttonStyle(.borderedProminent)
                .disabled(browser.isBusy)

                if hasAddress {
                    Text(address)
                        .font(.caption2)
                        .lineLimit(3)

                    Button {
                        browser.open(rawValue: address, serverURL: serverURL, token: accessToken)
                    } label: {
                        Label("重新打开", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(browser.isBusy)
                }

                NavigationLink {
                    ServerSettingsView(
                        serverURL: $serverURL,
                        accessToken: $accessToken,
                        browser: browser
                    )
                } label: {
                    Label("云端设置", systemImage: "gearshape")
                }
                .font(.caption)

                statusText

                Text("配对 iPhone 前台时由本地 WebKit 免费渲染；iPhone 不可达时才尝试免费云端兼容后备。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("交互浏览")
        .task {
            if !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                browser.checkService(serverURL: serverURL, token: accessToken)
            }
        }
    }

    private var hasAddress: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private func migrateLegacyAddressIfNeeded() {
        guard addressMigrationVersion < 2 else { return }
        let normalized = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if addressMigrationVersion < 1,
           (normalized == "https://www.baidu.com" || normalized == "https://baidu.com") {
            address = ""
        }
        addressMigrationVersion = 2
    }

    private func loadGatewayToken() {
        do {
            accessToken = try GatewayTokenStore.migrateLegacyTokenIfNeeded() ?? ""
            gatewayTokenError = nil
        } catch {
            accessToken = ""
            gatewayTokenError = error.localizedDescription
        }
    }

    private func submitBrowserInput(_ rawValue: String, action: BrowserInputAction) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            directOpenError = "没有收到输入，请重新听写或输入。"
            return
        }

        address = normalized
        switch action {
        case .safari:
            openWithSystem(rawValue: normalized)
        case .direct:
            openDirect(rawValue: normalized)
        case .cloud:
            directOpenError = nil
            systemOpenNotice = nil
            browser.open(rawValue: normalized, serverURL: serverURL, token: accessToken)
        }
    }

    private func openDirect(rawValue: String) {
        do {
            let destination = try WebDestination(rawValue: rawValue).url
            directOpenError = nil
            systemOpenNotice = nil
            directReaderURL = destination
            showingDirectReader = true
        } catch {
            directOpenError = error.localizedDescription
        }
    }

    private func openWithSystem(rawValue: String) {
        do {
            let destination = try WebDestination(rawValue: rawValue).url
            directOpenError = nil
            if #available(watchOS 26.0, *) {
                systemOpenNotice = "已请求 Safari 打开。系统不向应用回报最终载入结果；若页面没有出现，请返回并点“手表直读”。"
                openURL(destination, prefersInApp: true)
            } else {
                systemOpenNotice = nil
                directOpenError = "系统网页需要 watchOS 26；请使用手表直读。"
            }
        } catch {
            systemOpenNotice = nil
            directOpenError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch browser.phase {
        case .idle:
            EmptyView()
        case .loading(let message):
            Label(message, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .displaying:
            EmptyView()
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

struct ServerSettingsView: View {
    @Binding var serverURL: String
    @Binding var accessToken: String
    @ObservedObject var browser: WatchRemoteBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var tokenStatusMessage: String?
    @State private var tokenStatusIsError = false
    @State private var showingDeleteTokenConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text("服务地址")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(BrowserServerDefaults.freeReaderBaseURL)
                    .font(.system(size: 9))
                    .lineLimit(3)
                Text("兼容页面同样锁定免费 Worker，不接受自定义或旧付费地址。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("部署访问令牌（必填）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextFieldLink(
                    prompt: Text("输入个人访问码"),
                    label: {
                        Label(
                            accessToken.isEmpty ? "输入部署令牌" : "更换部署令牌（已保存）",
                            systemImage: "lock.fill"
                        )
                        .frame(maxWidth: .infinity)
                    },
                    onSubmit: { value in
                        saveToken(value)
                    }
                )
                .buttonStyle(.bordered)

                if let tokenStatusMessage {
                    Text(tokenStatusMessage)
                        .font(.caption2)
                        .foregroundStyle(tokenStatusIsError ? Color.orange : Color.green)
                }

                if !accessToken.isEmpty {
                    Button("删除部署令牌", role: .destructive) {
                        showingDeleteTokenConfirmation = true
                    }
                    .font(.caption)
                }

                Button {
                    browser.checkService(serverURL: serverURL, token: accessToken)
                } label: {
                    Label("检测统一网关", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Text(browser.connectionMessage)
                    .font(.caption2)
                    .foregroundStyle(browser.isGatewayReachable ? Color.green : Color.orange)

                if browser.isGatewayReachable {
                    Button("保存并返回") { dismiss() }
                        .buttonStyle(.bordered)
                }

                Text("此 Workers Free 地址和部署令牌用于正文、交互浏览及备用 DeepSeek 转发。手表有本地 DeepSeek Key 时仍优先直连；没有时才走转发，两者都不依赖 iPhone。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("云端设置")
        .onAppear {
            serverURL = BrowserServerDefaults.freeReaderBaseURL
            reloadToken()
        }
        .onChange(of: serverURL) { _, _ in browser.markConfigurationDirty() }
        .onChange(of: accessToken) { _, _ in browser.markConfigurationDirty() }
        .alert("删除部署令牌？", isPresented: $showingDeleteTokenConfirmation) {
            Button("删除", role: .destructive, action: deleteToken)
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后正文、交互浏览和备用 DeepSeek 转发都会停用；若手表已保存 DeepSeek API Key，AI 仍可直连使用。")
        }
    }

    private func reloadToken() {
        do {
            accessToken = try GatewayTokenStore.migrateLegacyTokenIfNeeded() ?? ""
        } catch {
            showTokenStatus(error.localizedDescription, isError: true)
        }
    }

    private func saveToken(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try GatewayTokenStore.save(normalized)
            guard try GatewayTokenStore.load() == normalized else {
                throw GatewayTokenStoreError.migrationVerificationFailed
            }
            GatewayTokenStore.finalizeLegacyCleanup()
            accessToken = normalized
            showTokenStatus("部署令牌已安全保存到手表 Keychain。", isError: false)
        } catch {
            showTokenStatus(error.localizedDescription, isError: true)
        }
    }

    private func deleteToken() {
        do {
            try GatewayTokenStore.delete()
            accessToken = ""
            showTokenStatus("部署令牌已从手表 Keychain 删除。", isError: false)
        } catch {
            showTokenStatus(error.localizedDescription, isError: true)
        }
    }

    private func showTokenStatus(_ message: String, isError: Bool) {
        tokenStatusMessage = message
        tokenStatusIsError = isError
    }
}

private struct RemotePageView: View {
    let image: UIImage
    @ObservedObject var browser: WatchRemoteBrowser
    @State private var showingTextInput = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            sendTap(at: value.location, in: proxy.size)
                        }
                    )

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    messageOverlay
                    controlBar
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
            }
        }
        .sheet(isPresented: $showingTextInput) {
            WebTextInputView(browser: browser)
        }
    }

    private var topBar: some View {
        HStack(spacing: 5) {
            controlButton("xmark", enabled: true, action: browser.dismissPage)
            Text(browser.pageTitle)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(Int(browser.scrollProgress * 100))%")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var messageOverlay: some View {
        switch browser.phase {
        case .loading(let message):
            Text(message)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(2)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 4)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .medium))
                .lineLimit(3)
                .padding(6)
                .foregroundStyle(.orange)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 9))
                .padding(.bottom, 4)
        case .idle, .displaying:
            EmptyView()
        }
    }

    private var controlBar: some View {
        HStack(spacing: 3) {
            controlButton(
                "chevron.backward",
                enabled: browser.canGoBack && !browser.isBusy,
                action: browser.goBack
            )
            controlButton("chevron.up", enabled: !browser.isBusy) { browser.scroll(-0.72) }
            controlButton("chevron.down", enabled: !browser.isBusy) { browser.scroll(0.72) }
            controlButton("keyboard", enabled: browser.focusedInputAvailable && !browser.isBusy) {
                showingTextInput = true
            }
            controlButton("arrow.clockwise", enabled: !browser.isBusy, action: browser.refresh)
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func controlButton(
        _ systemName: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 29, height: 29)
                .background(Color.black.opacity(0.42), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func sendTap(at point: CGPoint, in bounds: CGSize) {
        guard !browser.isBusy else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let renderedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (bounds.width - renderedSize.width) / 2,
            y: (bounds.height - renderedSize.height) / 2
        )
        let renderedRect = CGRect(origin: origin, size: renderedSize)
        guard renderedRect.contains(point) else { return }
        browser.tap(
            normalizedX: (point.x - origin.x) / renderedSize.width,
            normalizedY: (point.y - origin.y) / renderedSize.height
        )
    }
}

private struct WebTextInputView: View {
    @ObservedObject var browser: WatchRemoteBrowser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text(browser.focusedInputLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextFieldLink(
                    prompt: Text("听写、手写或键盘输入"),
                    label: {
                        Label("输入并提交", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    },
                    onSubmit: { value in
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalized.isEmpty else { return }
                        browser.fillFocusedInput(text: normalized, submit: true)
                        dismiss()
                    }
                )
                .buttonStyle(.borderedProminent)

                Text("也可以使用听写或手写。提交后，交互浏览器会按下回车并返回新画面。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    ContentView()
}
