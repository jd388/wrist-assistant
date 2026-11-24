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
            let arguments = ProcessInfo.processInfo.arguments
            guard !arguments.contains("--wrist-ui-open-dictionary") else { return }
            if arguments.contains("--wrist-ui-open-history") {
                showingHistory = true
            } else if arguments.contains("--wrist-ui-open-chat") || arguments.contains("--wrist-ui-open-editor") {
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
        .navigationTitle("AI")
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
    @AppStorage(AIReplyPreferenceKey.showReasoning) private var showReasoning = true
    @AppStorage(AIReplyPreferenceKey.showSources) private var showSources = true
    private let browser: WatchRemoteBrowser?
    let pageContext: GatewayPageContext?
    let initialTask: AIChatInitialTask

    @ObservedObject private var model: AIChatModel
    private let conversationID: UUID?
    @State private var expandedReasoningIDs: Set<UUID> = []
    @State private var expandedSourceIDs: Set<UUID> = []
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
          AIReadingScrollView(
            update: ReadingUpdate(message: model.messages.last, phase: model.phase, draft: model.draft),
            answer: latestAnswerSnapshot,
            composerDraft: model.draft, contextID: model.selectedConversationID,
            showsReturnButton: model.messages.contains { $0.role == .user }
          ) {
                VStack(alignment: .leading, spacing: 10) {
                    if initialTask != .webQuestion {
                        header
                    }

                    if !hasAIService {
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

    private var latestAnswerSnapshot: AIReadingAnswerSnapshot? {
        guard let message = model.messages.last, message.role == .assistant else { return nil }
        return AIReadingAnswerSnapshot(id: message.id, text: message.text)
    }

    private var messageTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.messages) { message in
                messageView(message)
            }
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
                    AIAnswerContent(text: message.text)
                        .id("chat-answer-text-\(message.id.uuidString)")
                }

                if showReasoning, let reasoning = message.reasoning, !reasoning.isEmpty {
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
                    Label(
                        showReasoning
                            ? "回答或思考内容达到显示上限，可缩小问题范围后重试。"
                            : "内容已截断，可缩小问题范围后重试。",
                        systemImage: "scissors"
                    )
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                if message.status == .interrupted && message.text != "回答在完成前中断。" {
                    Text("回答已中断")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if showSources, !message.citations.isEmpty {
                    let expanded = expandedSourceIDs.contains(message.id)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expanded { expandedSourceIDs.remove(message.id) }
                            else { expandedSourceIDs.insert(message.id) }
                        }
                    } label: {
                        HStack {
                            Label("搜索来源", systemImage: "link")
                            Spacer(minLength: 2)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .accessibilityValue(expanded ? "已展开" : "已折叠")
                    if expanded {
                        ForEach(message.citations) { citation in
                            sourceLink(citation)
                        }
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

                let footer = message.answerFooter
                if !message.text.isEmpty && !footer.isEmpty {
                    Text(footer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("chat.answerModel")
                }
            }
            .padding(9)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
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
        Group {
            if model.isAsking {
                HStack(spacing: 6) {
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
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(
                            model.messages.isEmpty ? "输入问题" : "继续提问",
                            text: $model.draft,
                            axis: .vertical
                        )
                        .font(.body)
                        .lineLimit(1...)
                        .fixedSize(horizontal: false, vertical: true)
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

                    if model.isDraftTooLong {
                        Text("问题太长，请精简后再发送。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
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
                        .lineLimit(2...)
                        .fixedSize(horizontal: false, vertical: true)
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


private struct ReadingUpdate: Equatable {
    let message: AIConversationMessage?
    let phase: AIChatModel.Phase
    let draft: String
}

/// Shared by the actual conversation and the isolated, offline acceptance fixture.
private struct AIReadingScrollView<Update: Equatable, Content: View>: View {
    let update: Update
    var answer: AIReadingAnswerSnapshot? = nil
    var composerDraft = ""
    var contextID: UUID? = nil
    var showsReturnButton = true
    @ViewBuilder let content: () -> Content
    @State private var follow = AIReadingFollowState()
    @State private var followsAnswerText = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var answerTextAnchor: String? {
        guard let answer, !answer.text.isEmpty else { return nil }
        return "chat-answer-text-\(answer.id.uuidString)"
    }

    private var automaticScrollTarget: String {
        followsAnswerText ? (answerTextAnchor ?? "chat-bottom") : "chat-bottom"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1).id("chat-top")
                    content()
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
            }
            .onScrollGeometryChange(for: ReadingGeometry.self) { geometry in
                ReadingGeometry(
                    distance: AIReadingFollowState.distanceFromBottom(contentHeight: geometry.contentSize.height,
                        bottomInset: geometry.contentInsets.bottom, visibleBottom: geometry.visibleRect.maxY),
                    height: geometry.contentSize.height, offset: geometry.contentOffset.y,
                    container: geometry.containerSize.height, inset: geometry.contentInsets.bottom,
                    topInset: geometry.contentInsets.top, visibleBottom: geometry.visibleRect.maxY
                )
            } action: { old, new in
                follow.updateGeometry(distanceFromBottom: new.distance)
                #if DEBUG
                ReadingQARecorder.record("geometry", distance: new.distance, height: new.height, follows: follow.shouldFollowUpdates, offset: new.offset, container: new.container, inset: new.inset, topInset: new.topInset, visibleBottom: new.visibleBottom)
                #endif
                if (old.height != new.height || old.container != new.container || old.inset != new.inset), follow.shouldFollowUpdates {
                    proxy.scrollTo(automaticScrollTarget, anchor: .bottom)
                }
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting, .decelerating:
                    follow.beginUserScroll()
                case .idle:
                    if follow.isUserScrolling {
                        let geometry = context.geometry
                        follow.endUserScroll(distanceFromBottom: AIReadingFollowState.distanceFromBottom(
                            contentHeight: geometry.contentSize.height, bottomInset: geometry.contentInsets.bottom,
                            visibleBottom: geometry.visibleRect.maxY))
                    }
                default: break
                }
                #if DEBUG
                ReadingQARecorder.record("phase-\(phase)", distance: AIReadingFollowState.distanceFromBottom(
                    contentHeight: context.geometry.contentSize.height, bottomInset: context.geometry.contentInsets.bottom,
                    visibleBottom: context.geometry.visibleRect.maxY), follows: follow.shouldFollowUpdates)
                #endif
            }
            .onChange(of: update) { _, _ in
                #if DEBUG
                ReadingQARecorder.record("content", distance: 0, follows: follow.shouldFollowUpdates)
                #endif
                if follow.shouldFollowUpdates { proxy.scrollTo(automaticScrollTarget, anchor: .bottom) }
            }
            .onChange(of: answer?.id) { _, _ in
                followsAnswerText = false
            }
            .onChange(of: composerDraft) { _, _ in
                followsAnswerText = false
                if follow.shouldFollowUpdates { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: contextID) { _, _ in
                followsAnswerText = false
                follow = AIReadingFollowState()
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .onAppear {
                followsAnswerText = false
                follow = AIReadingFollowState()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--wrist-reading-qa-layout") {
                    follow.beginUserScroll()
                    follow.endUserScroll(distanceFromBottom: 1_000)
                    proxy.scrollTo("chat-top", anchor: .top)
                    return
                }
                #endif
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .toolbar {
                if showsReturnButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            followsAnswerText = true
                            follow.returnToLatest()
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                proxy.scrollTo(answerTextAnchor ?? "chat-bottom", anchor: .bottom)
                            }
                            #if DEBUG
                            ReadingQARecorder.record("return", distance: 0, follows: follow.shouldFollowUpdates)
                            #endif
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .accessibilityLabel("回到最新")
                        .accessibilityIdentifier("chat.returnToLatest")
                    }
                }
            }
        }
    }
}

private struct ReadingGeometry: Equatable {
    let distance: Double
    let height: Double
    let offset: Double
    let container: Double
    let inset: Double
    let topInset: Double
    let visibleBottom: Double
}

private struct AIAnswerContent: View {
    let text: String
    private var blocks: [AIAnswerBlock] { AIAnswerDocument.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(.body)
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 回答")
        .accessibilityIdentifier("chat.answer")
    }

    @ViewBuilder private func blockView(_ block: AIAnswerBlock) -> some View {
        switch block.kind {
        case .paragraph:
            inline(block.text)
                .lineSpacing(3)
        case .heading(let level):
            inline(block.text)
                .font(level <= 2 ? .headline : .body.weight(.semibold))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 8)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.cyan.opacity(0.7)).frame(width: 2)
                inline(block.text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language):
            VStack(alignment: .leading, spacing: 5) {
                if !language.isEmpty { Text(language).font(.caption2).foregroundStyle(.secondary) }
                // Wrap rather than introducing a second horizontal scroll gesture.
                Text(block.text).font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        case .math:
            inline(block.text)
                .font(AIMathText.containsGrid(block.text)
                      ? .system(.callout, design: .monospaced)
                      : .system(.body, design: .serif))
                .lineSpacing(4)
                .padding(.vertical, 2)
                .fixedSize(horizontal: false, vertical: true)
        case .tableRecord:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(block.fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 2) {
                        inline(field.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        inline(field.value)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Divider().offset(y: 4) }
        case .divider:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        Text(AIMathText.attributed(text, decorateFormula: Self.formulaText))
    }

    private static func formulaText(_ string: String, attributes: AttributeContainer) -> AttributedString {
        var result = AttributedString()
        var plain = ""
        for character in string {
            guard let script = AIMathText.scriptGlyph(character) else {
                plain.append(character)
                continue
            }
            if !plain.isEmpty {
                result += AttributedString(plain, attributes: attributes)
                plain.removeAll(keepingCapacity: true)
            }
            var digit = AttributedString(String(script.character), attributes: attributes)
            digit.font = .system(.caption2, design: .serif)
            digit.baselineOffset = script.isSuperscript ? 5 : -3
            result += digit
        }
        result += AttributedString(plain, attributes: attributes)
        return result
    }
}

#if DEBUG
private enum ReadingQARecorder {
    static func record(_ event: String, distance: Double, height: Double = 0, follows: Bool, offset: Double = 0, container: Double = 0, inset: Double = 0, topInset: Double = 0, visibleBottom: Double = 0) {
        guard ProcessInfo.processInfo.arguments.contains("--wrist-reading-qa"),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("reading-qa.jsonl")
        let record: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
            "distance": distance, "height": height, "follows": follows,
            "offset": offset, "container": container, "inset": inset, "topInset": topInset, "visibleBottom": visibleBottom]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data)
    }
}

private struct QAReadingUpdate: Equatable {
    let text: String
    let running: Bool
    let draft: String
}

/// No model, store, credentials or network client is constructed in this route.
struct AIReadingAcceptanceView: View {
    @State private var text = ""
    @State private var running = false
    @State private var answerID = UUID()
    @State private var qaDraft = ""
    private let sample = """
    # 抬腕就能读懂

    这是一段用于验收的本地长回答。**重点用粗体**，正文按段落呈现；生成中也保持同样的排版。

    ## 三个步骤
    1. 开始阅读，检查标题与正文的层级。
    2. 向上滚动，后续文字不应把阅读位置拉走。
    3. 点回到最新，继续跟随回答。

    > 阅读应该由你控制。引用内容与正文有明确区分。

    ## 逐项比较
    | 功能 | 作用 |
    | --- | --- |
    | 自动跟随 | 停在底部时跟随新增内容 |
    | 自由阅读 | 向上翻阅后保持当前位置 |

    ## 代码示例
    ```swift
    let message = "在小屏上自动换行，保留代码中的符号与缩进"
    print(message)
    ```

    ## 后续内容
    """

    var body: some View {
        NavigationStack {
            AIReadingScrollView(
                update: QAReadingUpdate(text: text, running: running, draft: qaDraft),
                answer: AIReadingAnswerSnapshot(id: answerID, text: text),
                composerDraft: qaDraft, contextID: answerID
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if !text.isEmpty {
                        AIAnswerContent(text: text)
                            .id("chat-answer-text-\(answerID.uuidString)")
                            .padding(9)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    TextField("输入问题", text: $qaDraft, axis: .vertical)
                        .lineLimit(1...)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("qa.composer")
                    Button(running ? "停止本地生成" : "继续本地生成") { running.toggle() }
                        .accessibilityIdentifier("qa.stream")
                    Text("本地验收 · 无网络请求").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("阅读验收")
            .task {
                if ProcessInfo.processInfo.arguments.contains("--qa-empty") { return }
                if ProcessInfo.processInfo.arguments.contains("--wrist-reading-qa-layout") {
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("--qa-table"), let range = sample.range(of: "## 逐项比较") {
                        text = String(sample[range.lowerBound...].components(separatedBy: "## 代码示例")[0])
                    } else if arguments.contains("--qa-code"), let range = sample.range(of: "## 代码示例") {
                        text = String(sample[range.lowerBound...].components(separatedBy: "## 后续内容")[0])
                    } else {
                        text = sample
                    }
                    return
                }
                text = sample + String(repeating: "\n\n新增段落：转动表冠或滑动屏幕阅读。正在生成的文字不会打断你查看前面的内容。", count: 5)
            }
            .task(id: running) {
                guard running else { return }
                for index in 1...120 {
                    do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
                    text += index.isMultiple(of: 4) ? "\n\n第\(index / 4)段：这是后续生成的内容。" : "新的文字继续到达。"
                }
                running = false
            }
        }
    }
}
#endif
