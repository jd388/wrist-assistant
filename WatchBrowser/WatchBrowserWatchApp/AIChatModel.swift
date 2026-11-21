import Foundation
import WatchKit

@MainActor
final class AIChatModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case asking
        case failed(String)
    }

    struct QuestionEdit: Equatable {
        let conversationID: UUID
        let userMessageID: UUID
        let originalText: String
    }

    @Published private(set) var conversations: [AIConversation]
    @Published private(set) var selectedConversationID: UUID
    @Published var draft = "" {
        didSet { retainDraft() }
    }
    @Published var questionEditDraft = ""
    @Published private(set) var questionEdit: QuestionEdit?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var storageWarning: String?

    private struct Attempt {
        let generation: UUID
        let requestID: String
        let conversationID: UUID
        let userMessageID: UUID
        let assistantMessageID: UUID
        let question: String
        let deepThinking: Bool
        let requestPath: AIRequestPath
        var metadata: GatewayAskStreamMetadata?
    }

    private enum RequestTransport: Sendable {
        case directDeepSeek(apiKey: String)
        case cloudflareDeepSeekProxy(serverURL: String, token: String)

        var path: AIRequestPath {
            switch self {
            case .directDeepSeek:
                return .directDeepSeek
            case .cloudflareDeepSeekProxy:
                return .cloudflareDeepSeekProxy
            }
        }
    }

    private let deepSeek = DeepSeekService()
    private let gateway = GatewayClient()
    private let store: AIConversationStore?
    private let pageContext: GatewayPageContext?
    private let initialTask: AIChatInitialTask
    private let persistsConversations: Bool
    private var requestTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var activeAttempt: Attempt?

    init(
        pageContext: GatewayPageContext?,
        initialTask: AIChatInitialTask
    ) {
        self.pageContext = pageContext
        self.initialTask = initialTask
        persistsConversations = initialTask == .webQuestion && pageContext == nil

        var loadedStore: AIConversationStore?
        var loadedConversations: [AIConversation] = []
        var loadedSelection: UUID?
        var warning: String?
        var repairedInterruptedMessages = false
        var refreshedTitles = false
        if persistsConversations {
            do {
                let candidate = try AIConversationStore()
                loadedStore = candidate
                if let archive = try candidate.load() {
                    loadedConversations = archive.conversations
                    loadedSelection = archive.selectedConversationID
                    repairedInterruptedMessages = Self.repairInterruptedMessages(
                        in: &loadedConversations
                    )
                    for index in loadedConversations.indices {
                        if loadedConversations[index].refreshAutomaticTitle() {
                            refreshedTitles = true
                        }
                    }
                }
            } catch {
                warning = "对话记录暂时无法读取；新对话仍可使用。"
            }
        }
        let initialConversation: AIConversation
        if let selected = loadedSelection,
           loadedConversations.contains(where: { $0.id == selected }) {
            initialConversation = loadedConversations.first(where: { $0.id == selected })!
        } else if let first = loadedConversations.first {
            initialConversation = first
            loadedSelection = first.id
        } else {
            initialConversation = AIConversation(
                webSearchEnabled: false,
                deepThinkingEnabled: false
            )
            loadedConversations = [initialConversation]
            loadedSelection = initialConversation.id
        }
        conversations = loadedConversations
        selectedConversationID = loadedSelection ?? initialConversation.id
        store = loadedStore
        storageWarning = warning
        draft = initialConversation.draft
        if repairedInterruptedMessages || refreshedTitles {
            persist()
        }
    }

    deinit {
        requestTask?.cancel()
        draftSaveTask?.cancel()
    }

    var currentConversation: AIConversation {
        conversations.first(where: { $0.id == selectedConversationID })
            ?? conversations[0]
    }

    var messages: [AIConversationMessage] { currentConversation.messages }
    var isAsking: Bool { phase == .asking }
    var webSearchEnabled: Bool { currentConversation.webSearchEnabled }
    var deepThinkingEnabled: Bool { currentConversation.deepThinkingEnabled }
    var canSendDraft: Bool {
        !isAsking
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.count <= GatewayRequestPolicy.maximumQuestionCharacters
            && draft.utf8.count <= GatewayRequestPolicy.maximumQuestionBytes
    }
    var canSubmitQuestionEdit: Bool {
        let normalized = questionEditDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return questionEdit != nil
            && !isAsking
            && !normalized.isEmpty
            && normalized.count <= GatewayRequestPolicy.maximumQuestionCharacters
            && normalized.utf8.count <= GatewayRequestPolicy.maximumQuestionBytes
    }

    var loadingMessage: String {
        if initialTask == .summarize { return "正在总结当前内容…" }
        if initialTask == .pageQuestion { return "正在根据当前内容回答…" }
        if webSearchEnabled { return deepThinkingEnabled ? "正在检索资料并深度思考…" : "正在检索资料…" }
        return deepThinkingEnabled ? "正在深度思考…" : "正在生成回答…"
    }

    func setWebSearchEnabled(_ enabled: Bool) {
        guard initialTask == .webQuestion, !isAsking else { return }
        mutateConversation(selectedConversationID) { conversation in
            conversation.webSearchEnabled = enabled
            conversation.updatedAt = Date()
        }
        persist()
    }

    func setDeepThinkingEnabled(_ enabled: Bool) {
        guard !isAsking else { return }
        mutateConversation(selectedConversationID) { conversation in
            conversation.deepThinkingEnabled = enabled
            conversation.updatedAt = Date()
        }
        persist()
    }

    func send(
        _ rawValue: String,
        apiKey: String,
        serverURL: String,
        accessToken: String
    ) {
        guard questionEdit == nil else { return }
        _ = startRequest(
            rawValue,
            apiKey: apiKey,
            serverURL: serverURL,
            accessToken: accessToken,
            existingUserMessageID: nil
        )
    }

    func sendDraft(apiKey: String, serverURL: String, accessToken: String) {
        send(
            draft,
            apiKey: apiKey,
            serverURL: serverURL,
            accessToken: accessToken
        )
    }

    func retryLast(apiKey: String, serverURL: String, accessToken: String) {
        guard !isAsking,
              let userIndex = currentConversation.messages.lastIndex(where: { $0.role == .user }) else {
            return
        }
        let user = currentConversation.messages[userIndex]
        cancelQuestionEdit()
        _ = startRequest(
            user.text,
            apiKey: apiKey,
            serverURL: serverURL,
            accessToken: accessToken,
            existingUserMessageID: user.id
        )
    }

    func beginEditingLastQuestion() {
        guard !isAsking,
              let userIndex = currentConversation.messages.lastIndex(where: { $0.role == .user }) else {
            return
        }
        let user = currentConversation.messages[userIndex]
        questionEdit = QuestionEdit(
            conversationID: selectedConversationID,
            userMessageID: user.id,
            originalText: user.text
        )
        questionEditDraft = user.text
        phase = .idle
    }

    func cancelQuestionEdit() {
        questionEdit = nil
        questionEditDraft = ""
        if !isAsking { phase = .idle }
    }

    func submitQuestionEdit(
        apiKey: String,
        serverURL: String,
        accessToken: String
    ) {
        guard !isAsking,
              let edit = questionEdit,
              edit.conversationID == selectedConversationID,
              currentConversation.messages.last(where: { $0.role == .user })?.id
                == edit.userMessageID else {
            cancelQuestionEdit()
            return
        }
        let started = startRequest(
            questionEditDraft,
            apiKey: apiKey,
            serverURL: serverURL,
            accessToken: accessToken,
            existingUserMessageID: edit.userMessageID
        )
        if started {
            questionEdit = nil
            questionEditDraft = ""
        }
    }

    func cancel() {
        guard isAsking else { return }
        let attempt = activeAttempt
        requestTask?.cancel()
        requestTask = nil
        if let attempt {
            markInterrupted(attempt)
        }
        activeAttempt = nil
        phase = .failed("已停止回答，问题和已生成内容都已保留。")
        persist()
    }

    func cancelIfNeeded() {
        if isAsking { cancel() }
    }

    func saveDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        persist()
    }

    private func retainDraft() {
        guard currentConversation.draft != draft else { return }
        mutateConversation(selectedConversationID) {
            $0.draft = draft
            $0.updatedAt = Date()
        }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
            } catch { return }
            self?.persist()
        }
    }

    func newConversation() {
        if isAsking { cancel() }
        let conversation = AIConversation(webSearchEnabled: false, deepThinkingEnabled: false)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        draft = ""
        questionEdit = nil
        questionEditDraft = ""
        phase = .idle
        persist()
    }

    func selectConversation(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        if isAsking { cancel() }
        selectedConversationID = id
        draft = currentConversation.draft
        questionEdit = nil
        questionEditDraft = ""
        phase = .idle
        persist()
    }

    @discardableResult
    func renameConversation(_ id: UUID, to rawTitle: String) -> Bool {
        var renamed = false
        mutateConversation(id) { conversation in
            renamed = conversation.rename(to: rawTitle)
        }
        if renamed { persist() }
        return renamed
    }

    func deleteConversation(_ id: UUID) {
        if activeAttempt?.conversationID == id { cancel() }
        if questionEdit?.conversationID == id {
            questionEdit = nil
            questionEditDraft = ""
        }
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            let replacement = AIConversation()
            conversations = [replacement]
            selectedConversationID = replacement.id
        } else if !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations[0].id
        }
        draft = currentConversation.draft
        persist()
    }

    func clearAllConversations() {
        if isAsking { cancel() }
        let replacement = AIConversation()
        conversations = [replacement]
        selectedConversationID = replacement.id
        draft = ""
        questionEdit = nil
        questionEditDraft = ""
        phase = .idle
        do {
            try store?.deleteArchive()
            storageWarning = nil
        } catch {
            storageWarning = "旧对话记录未能完全删除，请稍后再试。"
        }
        persist()
    }

    @discardableResult
    private func startRequest(
        _ rawValue: String,
        apiKey: String,
        serverURL: String,
        accessToken: String,
        existingUserMessageID: UUID?
    ) -> Bool {
        guard !isAsking else { return false }
        let question = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            phase = .failed("没有收到问题，请重新听写或输入。")
            return false
        }
        guard question.count <= GatewayRequestPolicy.maximumQuestionCharacters,
              question.utf8.count <= GatewayRequestPolicy.maximumQuestionBytes else {
            if existingUserMessageID == nil {
                draft = question
            }
            phase = .failed("问题太长，请缩短到 \(GatewayRequestPolicy.maximumQuestionCharacters) 字以内。")
            return false
        }
        let transport = requestTransport(
            apiKey: apiKey,
            serverURL: serverURL,
            accessToken: accessToken
        )
        guard let transport else {
            if existingUserMessageID == nil {
                draft = question
            }
            phase = .failed("请设置 DeepSeek API Key，或配置免费的 Cloudflare DeepSeek 转发。")
            return false
        }

        let conversationID = selectedConversationID
        var proposedConversation = currentConversation
        let userMessageID: UUID
        if let existingUserMessageID {
            guard proposedConversation.replaceUserMessageAndTruncate(
                id: existingUserMessageID,
                with: question
            ) else {
                phase = .failed("找不到要修改的问题，请重新选择。")
                return false
            }
            userMessageID = existingUserMessageID
        } else {
            let user = AIConversationMessage(role: .user, text: question)
            userMessageID = user.id
            proposedConversation.append(user)
        }
        let history = proposedConversation.requestHistory(excludingMessageID: userMessageID)
        let assistant = AIConversationMessage(
            role: .assistant,
            text: "",
            status: .pending
        )

        let generation = UUID()
        let requestID = UUID().uuidString.lowercased()
        let deepThinking = proposedConversation.deepThinkingEnabled
        let mode: GatewayAskMode = initialTask == .summarize ? .summarize : .answer
        let request: GatewayAskRequest
        do {
            request = try GatewayAskRequest(
                requestID: requestID,
                question: question,
                mode: mode,
                webSearch: initialTask == .webQuestion
                    && proposedConversation.webSearchEnabled,
                deepThinking: deepThinking,
                history: history,
                page: initialTask == .webQuestion ? nil : pageContext
            )
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }

        do {
            switch transport {
            case .directDeepSeek:
                _ = try DeepSeekService.requestBody(for: request)
            case .cloudflareDeepSeekProxy:
                _ = try GatewayClient.askRequestBody(for: request)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }

        proposedConversation.append(assistant)
        mutateConversation(conversationID) { $0 = proposedConversation }
        activeAttempt = Attempt(
            generation: generation,
            requestID: requestID,
            conversationID: conversationID,
            userMessageID: userMessageID,
            assistantMessageID: assistant.id,
            question: question,
            deepThinking: deepThinking,
            requestPath: transport.path,
            metadata: nil
        )
        if existingUserMessageID == nil {
            draft = ""
        }
        phase = .asking
        persist()

        requestTask?.cancel()
        requestTask = Task { [weak self] in
            guard let self else { return }
            await self.perform(
                request,
                generation: generation,
                transport: transport
            )
        }
        return true
    }

    private func perform(
        _ request: GatewayAskRequest,
        generation: UUID,
        transport: RequestTransport
    ) async {
        do {
            let result: GatewayAskResponse
            switch transport {
            case .directDeepSeek(let apiKey):
                result = try await deepSeek.answerStreaming(
                    request,
                    apiKey: apiKey
                ) { [weak self] event in
                    await self?.apply(event, generation: generation)
                }
            case .cloudflareDeepSeekProxy(let serverURL, let token):
                result = try await gateway.answerStreaming(
                    request,
                    serverURL: serverURL,
                    token: token
                ) { [weak self] event in
                    await self?.apply(event, generation: generation)
                }
            }
            try Task.checkCancellation()
            finish(result, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            fail(error, generation: generation)
        }
    }

    private func apply(_ event: GatewayAskStreamEvent, generation: UUID) {
        guard var attempt = activeAttempt, attempt.generation == generation else { return }
        switch event {
        case .metadata(let metadata):
            attempt.metadata = metadata
            activeAttempt = attempt
            mutateMessage(
                conversationID: attempt.conversationID,
                messageID: attempt.assistantMessageID
            ) { message in
                message.citations = metadata.citations
                if let responseItems = metadata.responseItems {
                    message.responseItems = responseItems
                }
                message.answerBasis = Self.answerBasis(
                    for: metadata,
                    deepThinking: attempt.deepThinking,
                    requestPath: attempt.requestPath
                )
            }
            persist()
        case .reasoningDelta(let text):
            mutateMessage(
                conversationID: attempt.conversationID,
                messageID: attempt.assistantMessageID
            ) { message in
                let current = message.reasoning ?? ""
                let remaining = max(0, 6_000 - current.count)
                message.reasoning = current + String(text.prefix(remaining))
            }
        case .delta(let text):
            mutateMessage(
                conversationID: attempt.conversationID,
                messageID: attempt.assistantMessageID
            ) { message in
                let remaining = max(0, 8_000 - message.text.count)
                message.text += String(text.prefix(remaining))
            }
        case .done(let answer, let reasoning, let truncated):
            mutateMessage(
                conversationID: attempt.conversationID,
                messageID: attempt.assistantMessageID
            ) { message in
                message.text = answer
                if let reasoning {
                    message.reasoning = reasoning
                }
                message.wasTruncated = truncated
                message.status = .completed
            }
        case .failure(let error):
            let serviceError: Error = attempt.requestPath == .cloudflareDeepSeekProxy
                ? GatewayClientError.stream(error)
                : DeepSeekProtocolError.failed(error.code)
            fail(serviceError, generation: generation)
        }
    }

    private func finish(_ result: GatewayAskResponse, generation: UUID) {
        guard let attempt = activeAttempt, attempt.generation == generation else { return }
        mutateMessage(
            conversationID: attempt.conversationID,
            messageID: attempt.assistantMessageID
        ) { message in
            message.text = result.answer
            if let reasoning = result.reasoning {
                message.reasoning = reasoning
            }
            message.citations = result.citations
            message.wasTruncated = result.truncated ?? false
            message.responseItems = result.responseItems
            message.answerBasis = Self.answerBasis(
                for: result,
                deepThinking: attempt.deepThinking,
                requestPath: attempt.requestPath
            )
            message.status = .completed
        }
        activeAttempt = nil
        requestTask = nil
        phase = .idle
        persist()
        WKInterfaceDevice.current().play(.success)
    }

    private func fail(_ error: Error, generation: UUID) {
        guard let attempt = activeAttempt, attempt.generation == generation else { return }
        let wasInterrupted = markInterrupted(attempt)
        activeAttempt = nil
        requestTask = nil
        phase = wasInterrupted ? .failed(error.localizedDescription) : .idle
        persist()
        WKInterfaceDevice.current().play(wasInterrupted ? .failure : .success)
    }

    @discardableResult
    private func markInterrupted(_ attempt: Attempt) -> Bool {
        var changed = false
        mutateMessage(
            conversationID: attempt.conversationID,
            messageID: attempt.assistantMessageID
        ) { message in
            guard message.status == .pending else { return }
            message.status = .interrupted
            Self.makeInterruptedStateExplicit(&message)
            changed = true
        }
        return changed
    }

    private func mutateConversation(
        _ id: UUID,
        mutation: (inout AIConversation) -> Void
    ) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutation(&conversations[index])
    }

    private func mutateMessage(
        conversationID: UUID,
        messageID: UUID,
        mutation: (inout AIConversationMessage) -> Void
    ) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(
                where: { $0.id == messageID }
              ) else {
            return
        }
        mutation(&conversations[conversationIndex].messages[messageIndex])
        conversations[conversationIndex].updatedAt = Date()
    }

    private func persist() {
        guard persistsConversations, let store else { return }
        do {
            try store.save(
                AIConversationArchive(
                    conversations: conversations,
                    selectedConversationID: selectedConversationID
                )
            )
            storageWarning = nil
        } catch {
            storageWarning = "对话已显示，但暂时无法保存到手表。"
        }
    }

    private static func repairInterruptedMessages(
        in conversations: inout [AIConversation]
    ) -> Bool {
        var repaired = false
        for conversationIndex in conversations.indices {
            for messageIndex in conversations[conversationIndex].messages.indices {
                var message = conversations[conversationIndex].messages[messageIndex]
                guard message.role == .assistant else { continue }
                let isEmpty = message.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                guard message.status == .pending || isEmpty else { continue }
                message.status = .interrupted
                makeInterruptedStateExplicit(&message)
                conversations[conversationIndex].messages[messageIndex] = message
                repaired = true
            }
        }
        return repaired
    }

    private static func makeInterruptedStateExplicit(
        _ message: inout AIConversationMessage
    ) {
        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message.text = "回答在完成前中断。"
        }
        if message.answerBasis.isEmpty {
            message.answerBasis = "回答已中断"
        } else if !message.answerBasis.contains("已中断") {
            message.answerBasis += " · 已中断"
        }
    }

    private static func answerBasis(
        for response: GatewayAskResponse,
        deepThinking: Bool,
        requestPath: AIRequestPath
    ) -> String {
        answerBasis(
            modelIdentifier: response.model,
            webSearchUsed: response.webSearchUsed,
            webSearchProvider: response.webSearchProvider,
            pageContextUsed: response.pageContextUsed,
            deepThinking: deepThinking,
            requestPath: requestPath
        )
    }

    private static func answerBasis(
        for metadata: GatewayAskStreamMetadata,
        deepThinking: Bool,
        requestPath: AIRequestPath
    ) -> String {
        answerBasis(
            modelIdentifier: metadata.model,
            webSearchUsed: metadata.webSearchUsed,
            webSearchProvider: metadata.webSearchProvider,
            pageContextUsed: metadata.pageContextUsed,
            deepThinking: deepThinking,
            requestPath: requestPath
        )
    }

    private static func answerBasis(
        modelIdentifier: String,
        webSearchUsed: Bool,
        webSearchProvider: GatewayWebSearchProvider?,
        pageContextUsed: Bool,
        deepThinking: Bool,
        requestPath: AIRequestPath
    ) -> String {
        let model: String
        if modelIdentifier.contains("deepseek-v4-pro") {
            model = "DeepSeek V4 Pro 官方 API"
        } else if modelIdentifier.contains("deepseek-v4-flash") {
            model = "DeepSeek V4 Flash 官方 API"
        } else if modelIdentifier.contains("qwen3-30b") {
            model = "Qwen3 30B（旧回答）"
        } else if modelIdentifier.contains("deepseek-r1-distill") {
            model = "DeepSeek-R1 Distill（旧回答）"
        } else if modelIdentifier.contains("llama-3.2-3b") {
            model = "Llama 3.2（旧回答）"
        } else {
            model = modelIdentifier
        }
        var parts = [model]
        if requestPath == .cloudflareDeepSeekProxy {
            parts.append("Cloudflare 免费转发")
        }
        parts.append(deepThinking ? "深度思考" : "快速回答")
        if pageContextUsed {
            parts.append("当前内容")
        }
        if webSearchUsed {
            switch webSearchProvider {
            case .other("deepseek"):
                parts.append("DeepSeek 联网搜索")
            case .wikimedia:
                parts.append("Wikimedia 开放资料")
            default:
                parts.append("在线资料检索")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func requestTransport(
        apiKey: String,
        serverURL: String,
        accessToken: String
    ) -> RequestTransport? {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDeepSeekCredential = (8...512).contains(normalizedAPIKey.count)
            && normalizedAPIKey.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }
        let gatewayConfiguration = try? GatewayConfiguration(
            serverURL: serverURL,
            token: accessToken
        )
        let path = AIRequestPathPolicy.select(
            hasDeepSeekCredential: hasDeepSeekCredential,
            hasValidCloudflareConfiguration: gatewayConfiguration != nil
        )
        switch path {
        case .directDeepSeek:
            return .directDeepSeek(apiKey: normalizedAPIKey)
        case .cloudflareDeepSeekProxy:
            guard let gatewayConfiguration else { return nil }
            return .cloudflareDeepSeekProxy(
                serverURL: gatewayConfiguration.baseURL.absoluteString,
                token: gatewayConfiguration.token
            )
        case .unconfigured:
            return nil
        }
    }
}
