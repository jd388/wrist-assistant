import Foundation
import SwiftUI

enum AIChatInitialTask: String, Equatable {
    case webQuestion
    case summarize
    case pageQuestion
}

struct AIChatView: View {
    @Binding private var serverURL: String
    @Binding private var accessToken: String
    private let browser: WatchRemoteBrowser?
    private let pageContext: GatewayPageContext?
    private let initialTask: AIChatInitialTask
    @StateObject private var model: AIChatModel
    @State private var showingConversation = false
    @State private var showingHistory = false
    @State private var showingDictionary = false
    #if DEBUG
    @State private var hasHandledLaunchNavigation = false
    #endif

    init(
        serverURL: Binding<String>,
        accessToken: Binding<String>,
        browser: WatchRemoteBrowser? = nil,
        pageContext: GatewayPageContext? = nil,
        initialTask: AIChatInitialTask = .webQuestion
    ) {
        _serverURL = serverURL
        _accessToken = accessToken
        self.browser = browser
        self.pageContext = pageContext
        self.initialTask = initialTask
        _model = StateObject(wrappedValue: AIChatModel(
            pageContext: pageContext,
            initialTask: initialTask
        ))
    }

    var body: some View {
        Group {
            if initialTask == .webQuestion && pageContext == nil {
                home
            } else {
                conversation
            }
        }
        #if DEBUG
        .task {
            // Exercise the real navigation destination on a physical Watch without
            // injecting a credential, creating a conversation, or sending a request.
            // The root reappears after a destination is popped. Consume launch
            // navigation once so a QA argument cannot push that destination again.
            guard initialTask == .webQuestion, pageContext == nil,
                  !hasHandledLaunchNavigation else { return }
            hasHandledLaunchNavigation = true
            if ProcessInfo.processInfo.arguments.contains("--wrist-ui-open-dictionary") {
                showingDictionary = true
            } else if ProcessInfo.processInfo.arguments.contains("--wrist-ui-open-history") {
                showingHistory = true
            } else if ProcessInfo.processInfo.arguments.contains("--wrist-ui-open-chat")
                || ProcessInfo.processInfo.arguments.contains("--wrist-ui-open-editor") {
                showingConversation = true
            }
        }
        #endif
    }

    private var home: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        model.newConversation()
                        showingConversation = true
                    } label: {
                        WatchChatActionLabel("新对话", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .accessibilityIdentifier("chat.new")

                    NavigationLink {
                        LexiWatchLookupView(ownsNavigationStack: false)
                    } label: {
                        WatchChatActionLabel("秒查词典", systemImage: "character.book.closed.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.35, green: 0.86, blue: 0.66))
                    .accessibilityIdentifier("dictionary.open")
                    .accessibilityHint("离线查词、中英翻译与单词本")

                    if !model.messages.isEmpty || !model.draft.isEmpty {
                        Button {
                            showingConversation = true
                        } label: {
                            WatchChatActionLabel("继续对话", systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.bordered)
                    }

                    NavigationLink {
                        history
                    } label: {
                        WatchChatActionLabel("对话历史", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)

                    if let warning = model.storageWarning {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: max(0, geometry.size.width - 16), alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("腕上助手")
        .navigationDestination(isPresented: $showingDictionary) {
            LexiWatchLookupView(ownsNavigationStack: false)
        }
        .navigationDestination(isPresented: $showingConversation) {
            conversation
        }
        .navigationDestination(isPresented: $showingHistory) {
            history
        }
    }

    private var conversation: some View {
        AIChatSessionView(
            model: model,
            serverURL: $serverURL,
            accessToken: $accessToken,
            browser: browser,
            pageContext: pageContext,
            initialTask: initialTask
        )
    }

    private var history: some View {
        AIConversationHistoryView(
            model: model,
            serverURL: $serverURL,
            accessToken: $accessToken
        )
    }
}

/// Constrains button text before watchOS applies its rounded button insets.
private struct WatchChatActionLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct AIChatSessionView: View {
    @Binding private var serverURL: String
    @Binding private var accessToken: String
    private let browser: WatchRemoteBrowser?
    let pageContext: GatewayPageContext?
    let initialTask: AIChatInitialTask

    @ObservedObject private var model: AIChatModel
    private let conversationID: UUID?
    @State private var expandedReasoningIDs: Set<UUID> = []
    @State private var deepSeekAPIKey = ""
    @State private var credentialLoadError: String?
    @State private var showingQuestionEditor = false
    @FocusState private var isComposerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(
        model: AIChatModel,
        serverURL: Binding<String>,
        accessToken: Binding<String>,
        browser: WatchRemoteBrowser? = nil,
        pageContext: GatewayPageContext? = nil,
        initialTask: AIChatInitialTask = .webQuestion,
        conversationID: UUID? = nil
    ) {
        self.model = model
        self.conversationID = conversationID
        _serverURL = serverURL
        _accessToken = accessToken
        self.browser = browser
        self.pageContext = pageContext
        self.initialTask = initialTask
    }

    var body: some View {
        GeometryReader { geometry in
          ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if initialTask != .webQuestion {
                        header
                    }

                    if hasAIService {
                        modeControls
                    } else {
                        aiServiceRequired
                    }

                    if !model.messages.isEmpty {
                        messageTimeline
                    }

                    generationStatus
                        .id("chat-status")

                    if let warning = model.storageWarning {
                        Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if let credentialLoadError {
                        Label(credentialLoadError, systemImage: "key.slash")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if hasAIService {
                        composer
                    }
                }
                .frame(width: max(0, geometry.size.width - 16), alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: model.messages.last?.text) { _, _ in
                guard model.isAsking else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.messages.count) { _, _ in
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .onChange(of: model.phase) { _, phase in
                if case .failed = phase {
                    proxy.scrollTo("chat-status", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
          }
        }
        .navigationTitle(navigationTitle)
        .sheet(isPresented: $showingQuestionEditor, onDismiss: {
            if model.questionEdit != nil { model.cancelQuestionEdit() }
        }) {
            AIQuestionEditView(
                model: model,
                onSubmit: submitQuestionEdit,
                onCancel: { showingQuestionEditor = false }
            )
        }
        .onChange(of: model.questionEdit) { _, edit in
            if edit == nil { showingQuestionEditor = false }
        }
        .onAppear {
            if let conversationID, conversationID != model.selectedConversationID {
                model.selectConversation(conversationID)
            }
            reloadDeepSeekCredential()
        }
        .onDisappear {
            model.cancelIfNeeded()
            model.saveDraft()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.cancelIfNeeded()
                model.saveDraft()
            }
        }
        .task(id: "\(initialTask.rawValue)|\(activeRequestPath)") {
            guard initialTask == .summarize,
                  model.messages.isEmpty,
                  hasAIService else { return }
            send("请总结当前页面")
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--wrist-ui-open-editor") {
                model.beginEditingLastQuestion()
                showingQuestionEditor = model.questionEdit != nil
            }
        }
        #endif
    }

    private var header: some View {
        Text(headerSubtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var messageTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.messages) { message in
                messageView(message)
            }
            Color.clear
                .frame(height: 1)
                .id("chat-bottom")
        }
    }

    @ViewBuilder
    private func messageView(_ message: AIConversationMessage) -> some View {
        if message.role == .user {
            Text(message.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("你说：\(message.text)")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                if message.text.isEmpty && model.isAsking {
                    HStack(spacing: 7) {
                        ProgressView()
                        Text(model.loadingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !message.text.isEmpty {
                    assistantText(message)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("AI 回答：\(message.text)")
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expandedReasoningIDs.contains(message.id) {
                                expandedReasoningIDs.remove(message.id)
                            } else {
                                expandedReasoningIDs.insert(message.id)
                            }
                        }
                    } label: {
                        HStack {
                            Label("思考过程", systemImage: "brain.head.profile")
                            Spacer(minLength: 2)
                            Image(systemName: expandedReasoningIDs.contains(message.id) ? "chevron.up" : "chevron.down")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)

                    if expandedReasoningIDs.contains(message.id) {
                        Text(reasoning)
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                }

                if message.wasTruncated {
                    Label("回答或思考内容达到显示上限，可缩小问题范围后重试。", systemImage: "scissors")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                if !message.answerBasis.isEmpty {
                    Text(message.answerBasis)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                if !message.citations.isEmpty {
                    Divider()
                    Text("来源")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(message.citations.prefix(5))) { citation in
                        sourceLink(citation)
                    }
                }

                if message.id == model.messages.last?.id,
                   !model.isAsking,
                   !message.text.isEmpty {
                    HStack(spacing: 5) {
                        Button {
                            retryLast()
                        } label: {
                            Label("重答", systemImage: "arrow.clockwise")
                        }
                        if model.questionEdit == nil {
                            Button {
                                model.beginEditingLastQuestion()
                                showingQuestionEditor = model.questionEdit != nil
                            } label: {
                                Label("修改", systemImage: "pencil")
                            }
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                }
            }
            .padding(9)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func assistantText(_ message: AIConversationMessage) -> Text {
        guard message.status == .completed,
              let attributed = try? AttributedString(
                  markdown: message.text,
                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              ) else {
            return Text(message.text)
        }
        return Text(attributed)
    }

    private func sourceLink(_ citation: GatewayCitation) -> some View {
        Group {
            if let url = URL(string: citation.url),
               url.scheme == "https" || url.scheme == "http" {
                NavigationLink {
                    DirectWebReaderView(
                        initialURL: url,
                        serverURL: $serverURL,
                        accessToken: $accessToken,
                        browser: browser
                    )
                } label: {
                    Text(citation.title.isEmpty ? (url.host ?? "查看来源") : citation.title)
                        .font(.caption2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var modeControls: some View {
        HStack(spacing: 6) {
            if initialTask == .webQuestion {
                modeButton(
                    title: "联网",
                    systemImage: "globe",
                    enabled: model.webSearchEnabled
                ) {
                    model.setWebSearchEnabled(!model.webSearchEnabled)
                }
            }
            modeButton(
                title: "深思",
                systemImage: "brain.head.profile",
                enabled: model.deepThinkingEnabled
            ) {
                model.setDeepThinkingEnabled(!model.deepThinkingEnabled)
            }
        }
    }

    private func modeButton(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: enabled ? "checkmark.circle.fill" : systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(enabled ? .cyan : .gray)
        .disabled(model.isAsking)
        .accessibilityValue(enabled ? "已开启" : "已关闭")
    }

    @ViewBuilder
    private var generationStatus: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .asking:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                if !model.messages.isEmpty, model.questionEdit == nil {
                    Button("重试上一问") {
                        retryLast()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            if model.isAsking {
                ProgressView()
                    .controlSize(.small)
                Text("正在回答…")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止回答")
            } else {
                TextField(
                    model.messages.isEmpty ? "输入问题" : "继续提问",
                    text: $model.draft,
                    axis: .vertical
                )
                .font(.body)
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .submitLabel(.done)
                .onSubmit {
                    isComposerFocused = false
                    model.saveDraft()
                }
                .accessibilityIdentifier("chat.followup")
                .frame(maxWidth: .infinity, minHeight: 44)

                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .tint(.cyan)
                .disabled(!model.canSendDraft || model.questionEdit != nil)
                .accessibilityLabel("发送问题")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var aiServiceRequired: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("尚未配置密钥", systemImage: "key.fill")
                .font(.caption.weight(.semibold))
            Text("请在 Mac 上运行密钥配置工具，完成后重新打开对话。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var hasDeepSeekCredential: Bool {
        let value = deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return (8...512).contains(value.count)
    }

    private var hasCloudflareProxyConfiguration: Bool {
        (try? GatewayConfiguration(serverURL: serverURL, token: accessToken)) != nil
    }

    private var activeRequestPath: AIRequestPath {
        AIRequestPathPolicy.select(
            hasDeepSeekCredential: hasDeepSeekCredential,
            hasValidCloudflareConfiguration: hasCloudflareProxyConfiguration
        )
    }

    private var hasAIService: Bool {
        activeRequestPath != .unconfigured
    }

    private func send(_ value: String) {
        model.send(
            value,
            apiKey: deepSeekAPIKey,
            serverURL: serverURL,
            accessToken: accessToken
        )
    }

    private func retryLast() {
        model.retryLast(
            apiKey: deepSeekAPIKey,
            serverURL: serverURL,
            accessToken: accessToken
        )
    }

    private func sendDraft() {
        isComposerFocused = false
        model.sendDraft(
            apiKey: deepSeekAPIKey,
            serverURL: serverURL,
            accessToken: accessToken
        )
    }

    private func submitQuestionEdit() {
        model.submitQuestionEdit(
            apiKey: deepSeekAPIKey,
            serverURL: serverURL,
            accessToken: accessToken
        )
        if model.questionEdit == nil {
            showingQuestionEditor = false
        }
    }

    private func reloadDeepSeekCredential() {
        do {
            deepSeekAPIKey = try DeepSeekKeyStore.load() ?? ""
            credentialLoadError = nil
        } catch {
            deepSeekAPIKey = ""
            credentialLoadError = error.localizedDescription
        }
    }

    private var navigationTitle: String {
        switch initialTask {
        case .webQuestion: return model.messages.isEmpty ? "新对话" : "对话"
        case .summarize: return "总结内容"
        case .pageQuestion: return "询问内容"
        }
    }

    private var headerSubtitle: String {
        let connection: String
        switch activeRequestPath {
        case .directDeepSeek:
            connection = "手表直连 DeepSeek"
        case .cloudflareDeepSeekProxy:
            connection = "DeepSeek 转发"
        case .unconfigured:
            connection = "尚未配置密钥"
        }
        switch initialTask {
        case .webQuestion: return connection
        case .summarize: return "\(connection) · 当前正文"
        case .pageQuestion: return "\(connection) · 正文追问"
        }
    }
}

private struct AIQuestionEditView: View {
    @ObservedObject var model: AIChatModel
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("修改问题", text: $model.questionEditDraft, axis: .vertical)
                        .focused($isQuestionFocused)
                        .font(.body)
                        .lineLimit(2...5)
                        .submitLabel(.done)
                        .accessibilityIdentifier("chat.edit.question")

                    if case .failed(let error) = model.phase {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if model.questionEditDraft.count > GatewayRequestPolicy.maximumQuestionCharacters
                        || model.questionEditDraft.utf8.count > GatewayRequestPolicy.maximumQuestionBytes {
                        Text("问题太长，请精简后再发送。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Button("重新发送") {
                        isQuestionFocused = false
                        onSubmit()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmitQuestionEdit)
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("修改问题")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        isQuestionFocused = false
                        onCancel()
                    }
                }
            }
        }
    }
}

private struct AIConversationHistoryView: View {
    @ObservedObject var model: AIChatModel
    @Binding var serverURL: String
    @Binding var accessToken: String
    @State private var query = ""
    @State private var pendingDeletion: UUID?
    @State private var renameError: String?
    @State private var showingRenameEditor = false
    @State private var renamingConversationID: UUID?
    @State private var renameDraft = ""

    var body: some View {
        let results = filteredConversations
        List {
                TextFieldLink(
                    prompt: Text("输入标题或消息关键词"),
                    label: {
                        Label(query.isEmpty ? "搜索历史" : "更改搜索词", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    },
                    onSubmit: { query = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
                .buttonStyle(.bordered)

                if !query.isEmpty {
                    Text("搜索词：\(query)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("查看全部历史") { query = "" }
                        .font(.caption2)
                }

                Section {
                if results.isEmpty {
                    Text(query.isEmpty ? "还没有对话" : "没有找到包含“\(query)”的对话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { conversation in
                            NavigationLink {
                                AIChatSessionView(
                                    model: model,
                                    serverURL: $serverURL,
                                    accessToken: $accessToken,
                                    conversationID: conversation.id
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(searchPreview(for: conversation))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(query.isEmpty ? 1 : 3)
                                    Text(conversation.updatedAt.formatted(.dateTime.year().month().day()))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                            .accessibilityHint("点按继续聊天，左滑改名或删除")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeletion = conversation.id
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    renamingConversationID = conversation.id
                                    renameDraft = conversation.title
                                    renameError = nil
                                    showingRenameEditor = true
                                } label: {
                                    Label("改名", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }

                    Text("左滑会话可改名或删除")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                } header: {
                    Text(query.isEmpty ? "全部对话（\(results.count)）" : "搜索结果（\(results.count)）")
                }
        }
        .navigationTitle("对话历史")
        .sheet(isPresented: $showingRenameEditor, onDismiss: {
            renamingConversationID = nil
            renameError = nil
        }) {
            renameEditor
        }
        .confirmationDialog(
            "删除这段对话？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("删除对话", role: .destructive) {
                if let id = pendingDeletion { model.deleteConversation(id) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private func searchPreview(for conversation: AIConversation) -> String {
        guard !query.isEmpty else { return conversation.preview }
        let matchingText: String?
        if conversation.draft.localizedCaseInsensitiveContains(query) {
            matchingText = conversation.draft
        } else {
            matchingText = conversation.messages.last {
                $0.text.localizedCaseInsensitiveContains(query)
            }?.text
        }
        guard let text = matchingText,
              let match = text.range(of: query, options: .caseInsensitive) else {
            return conversation.preview
        }
        let start = text.index(match.lowerBound, offsetBy: -20, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 60, limitedBy: text.endIndex)
            ?? text.endIndex
        return (start == text.startIndex ? "" : "…")
            + String(text[start..<end])
            + (end == text.endIndex ? "" : "…")
    }

    private var renameEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("对话标题", text: $renameDraft, axis: .vertical)
                        .lineLimit(2...3)
                        .submitLabel(.done)
                    if let renameError {
                        Text(renameError)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Button("保存标题") {
                        guard let id = renamingConversationID,
                              model.renameConversation(id, to: renameDraft) else {
                            renameError = "标题不能为空或过长，请重新输入。"
                            return
                        }
                        showingRenameEditor = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("修改标题")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { showingRenameEditor = false }
                }
            }
        }
    }

    private var filteredConversations: [AIConversation] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = model.conversations.filter { !$0.messages.isEmpty || !$0.draft.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !normalized.isEmpty else { return sorted }
        return sorted.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(normalized)
                || conversation.draft.localizedCaseInsensitiveContains(normalized)
                || conversation.messages.contains {
                    $0.text.localizedCaseInsensitiveContains(normalized)
                }
        }
    }
}
