import XCTest
@testable import BrowserCore

final class AIConversationTests: XCTestCase {
    func testLongAnswerSurvivesStorageAndKeepsBoundedContext() throws {
        let answer = String(repeating: "答", count: DeepSeekRequestPolicy.maximumAnswerCharacters)
        let reasoning = String(repeating: "想", count: DeepSeekRequestPolicy.maximumReasoningCharacters)
        let conversation = AIConversation(messages: [
            AIConversationMessage(role: .user, text: "原问题"),
            AIConversationMessage(role: .assistant, text: answer, reasoning: reasoning)
        ])
        let archive = AIConversationArchive(
            conversations: [conversation], selectedConversationID: conversation.id
        )
        let restored = try JSONDecoder().decode(
            AIConversationArchive.self, from: JSONEncoder().encode(archive.compacted())
        )
        let saved = try XCTUnwrap(restored.conversations.first)
        XCTAssertEqual(saved.messages.last?.text, answer)
        XCTAssertEqual(saved.messages.last?.reasoning, reasoning)
        let history = saved.requestHistory()
        XCTAssertEqual(history.map(\.role), [.user, .assistant])
        XCTAssertEqual(history.last?.content.count, GatewayRequestPolicy.maximumConversationMessageCharacters)
        XCTAssertNoThrow(try GatewayAskRequest(question: "继续", webSearch: false, history: history))
    }

    func testUnsentDraftSurvivesArchiveRoundTripWithoutBecomingAMessage() throws {
        let conversation = AIConversation(draft: "这道题我还没有写完\n下一行 👋")
        let archive = AIConversationArchive(
            conversations: [conversation], selectedConversationID: conversation.id
        )
        let data = try JSONEncoder().encode(archive.compacted())
        let restored = try JSONDecoder().decode(AIConversationArchive.self, from: data)
        XCTAssertEqual(restored.conversations.first?.draft, conversation.draft)
        XCTAssertTrue(try XCTUnwrap(restored.conversations.first).messages.isEmpty)
        XCTAssertEqual(restored.selectedConversationID, conversation.id)
        XCTAssertEqual(restored.conversations.first?.preview, "草稿：\(conversation.draft)")
    }

    func testArchiveWithoutDraftFieldRestoresExistingMessagesWithEmptyDraft() throws {
        let conversation = AIConversation(messages: [
            AIConversationMessage(role: .user, text: "保留历史消息")
        ])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)) as? [String: Any]
        )
        object.removeValue(forKey: "draft")
        let restored = try JSONDecoder().decode(
            AIConversation.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(restored.draft, "")
        XCTAssertEqual(restored.messages, conversation.messages)
        XCTAssertEqual(restored.id, conversation.id)
    }

    func testDraftsRemainSeparateAcrossConversations() throws {
        let first = AIConversation(draft: "第一段未发完的问题")
        let second = AIConversation(draft: "另一段问题")
        let archive = AIConversationArchive(
            conversations: [first, second], selectedConversationID: second.id
        )
        let restored = try JSONDecoder().decode(
            AIConversationArchive.self, from: JSONEncoder().encode(archive.compacted())
        )
        XCTAssertEqual(restored.conversations.first { $0.id == first.id }?.draft, first.draft)
        XCTAssertEqual(restored.conversations.first { $0.id == second.id }?.draft, second.draft)
        XCTAssertEqual(restored.selectedConversationID, second.id)
    }

    func testDraftCompactionCountsUnicodeBytesAndPreservesStorageLimits() throws {
        let conversation = AIConversation(
            messages: [AIConversationMessage(role: .user, text: "更早的消息")],
            draft: String(repeating: "👨‍👩‍👦‍👦", count: AIConversationPolicy.maximumStoredCharacters)
        )
        let compacted = AIConversationArchive(
            conversations: [conversation], selectedConversationID: conversation.id
        ).compacted()
        let retained = try XCTUnwrap(compacted.conversations.first)
        let characters = retained.messages.reduce(retained.draft.count) { $0 + $1.text.count }
        let bytes = retained.messages.reduce(retained.draft.utf8.count) { $0 + $1.text.utf8.count }
        XCTAssertFalse(retained.draft.isEmpty)
        XCTAssertLessThan(retained.draft.count, conversation.draft.count)
        XCTAssertLessThanOrEqual(characters, AIConversationPolicy.maximumStoredCharacters)
        XCTAssertLessThanOrEqual(bytes, AIConversationPolicy.maximumStoredBytes)
        XCTAssertEqual(compacted.compacted(), compacted)
    }

    func testNewConversationDefaultsOptionalCostlyModesOff() {
        let conversation = AIConversation()

        XCTAssertFalse(conversation.webSearchEnabled)
        XCTAssertFalse(conversation.deepThinkingEnabled)
    }

    func testFirstUserMessageCreatesBoundedReadableTitle() {
        var conversation = AIConversation()
        conversation.append(
            AIConversationMessage(
                role: .user,
                text: "  请   帮我总结今天最重要的科技新闻并说明影响  "
            )
        )

        XCTAssertEqual(conversation.title, "今天最重要的科技新闻")
        XCTAssertLessThanOrEqual(
            conversation.title.count,
            AIConversationPolicy.maximumTitleCharacters
        )
    }

    func testAutomaticTitleExtractsTopicWithoutPolitePrefixOrInstructions() {
        XCTAssertEqual(
            AIConversation.makeTitle(from: "请帮我介绍一下 Cloudflare Workers 的核心用途。要求举例"),
            "Cloudflare Workers 的核心用途"
        )
        XCTAssertEqual(AIConversation.makeTitle(from: "帮我制定一个 20 分钟学习计划"), "20 分钟学习计划")
        XCTAssertEqual(AIConversation.makeTitle(from: "请求超时如何排查"), "请求超时如何排查")
    }

    func testAutomaticTitleUsesActualTopicAfterGreeting() {
        var conversation = AIConversation()
        conversation.append(AIConversationMessage(role: .user, text: "你好！"))
        conversation.append(AIConversationMessage(role: .assistant, text: "你好"))
        conversation.append(AIConversationMessage(role: .user, text: "帮我解释一下光合作用"))
        XCTAssertEqual(conversation.title, "光合作用")
    }

    func testRefreshingLegacyAutomaticTitlePreservesMessagesAndRecency() {
        let originalDate = Date(timeIntervalSince1970: 123)
        var conversation = AIConversation(
            title: "请帮我介绍一下光合作用",
            updatedAt: originalDate,
            messages: [AIConversationMessage(role: .user, text: "请帮我介绍一下光合作用")]
        )
        let messages = conversation.messages
        let id = conversation.id
        XCTAssertTrue(conversation.refreshAutomaticTitle())
        XCTAssertEqual(conversation.title, "光合作用")
        XCTAssertEqual(conversation.messages, messages)
        XCTAssertEqual(conversation.id, id)
        XCTAssertEqual(conversation.updatedAt, originalDate)
        XCTAssertFalse(conversation.refreshAutomaticTitle())
    }

    func testRefreshingAutomaticTitleNeverOverwritesManualName() {
        var conversation = AIConversation(messages: [
            AIConversationMessage(role: .user, text: "请帮我解释一下光合作用")
        ])
        XCTAssertTrue(conversation.rename(to: "我的生物笔记"))
        XCTAssertFalse(conversation.refreshAutomaticTitle())
        conversation.append(AIConversationMessage(role: .user, text: "继续解释叶绿体"))
        XCTAssertEqual(conversation.title, "我的生物笔记")
    }

    func testLongAutomaticTopicHasBoundedDisplayWidth() {
        let title = AIConversation.makeTitle(from: "解释一下" + String(repeating: "非常长的学习主题", count: 10))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 17)
        XCTAssertLessThanOrEqual(title.utf8.count, AIConversationPolicy.maximumTitleBytes)
    }

    func testManualRenameNormalizesBoundsAndMarksTitleManual() {
        var conversation = AIConversation()
        let renamedAt = Date(timeIntervalSince1970: 123)
        let longTitle = "  \(String(repeating: "标题", count: 30))  "

        XCTAssertTrue(conversation.rename(to: longTitle, now: renamedAt))

        XCTAssertFalse(conversation.titleIsAutomatic)
        XCTAssertEqual(conversation.title.count, AIConversationPolicy.maximumTitleCharacters)
        XCTAssertTrue(conversation.title.hasSuffix("…"))
        XCTAssertEqual(conversation.updatedAt, renamedAt)
    }

    func testManualRenameBoundsUTF8BytesAndRejectsSingleOversizedGrapheme() {
        var conversation = AIConversation()
        let byteHeavy = "a" + String(repeating: "\u{0301}", count: 300)

        XCTAssertFalse(conversation.rename(to: byteHeavy))
        XCTAssertEqual(conversation.title, "新对话")
        XCTAssertTrue(conversation.titleIsAutomatic)

        let emojiTitle = String(repeating: "👨‍👩‍👧‍👦", count: 36) + "尾"
        XCTAssertTrue(conversation.rename(to: emojiTitle))
        XCTAssertLessThanOrEqual(
            conversation.title.utf8.count,
            AIConversationPolicy.maximumTitleBytes
        )
        XCTAssertLessThanOrEqual(
            conversation.title.count,
            AIConversationPolicy.maximumTitleCharacters
        )
        XCTAssertTrue(conversation.title.hasSuffix("…"))
    }

    func testBlankManualRenameIsRejectedWithoutMutation() {
        var conversation = AIConversation()
        let original = conversation

        XCTAssertFalse(conversation.rename(to: " \n\t "))
        XCTAssertEqual(conversation, original)
    }

    func testManualNewConversationTitleIsNotOverwrittenByFirstQuestion() {
        var conversation = AIConversation()
        XCTAssertTrue(conversation.rename(to: "新对话"))

        conversation.append(AIConversationMessage(role: .user, text: "第一问"))

        XCTAssertEqual(conversation.title, "新对话")
        XCTAssertFalse(conversation.titleIsAutomatic)
    }

    func testLegacyConversationWithoutAutomaticTitleFlagDecodesAsAutomatic() throws {
        let conversation = AIConversation(title: "旧自动标题")
        let data = try JSONEncoder().encode(conversation)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "titleIsAutomatic")

        let decoded = try JSONDecoder().decode(
            AIConversation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.title, "旧自动标题")
        XCTAssertTrue(decoded.titleIsAutomatic)
    }

    func testManualTitleStatePersistsAcrossCodingRoundTrip() throws {
        var conversation = AIConversation()
        XCTAssertTrue(conversation.rename(to: "我的标题"))

        let decoded = try JSONDecoder().decode(
            AIConversation.self,
            from: JSONEncoder().encode(conversation)
        )

        XCTAssertEqual(decoded.title, "我的标题")
        XCTAssertFalse(decoded.titleIsAutomatic)
    }

    func testReplacingFirstQuestionUpdatesAutomaticTitleAndTruncatesAnswer() {
        var conversation = AIConversation()
        let question = AIConversationMessage(role: .user, text: "旧问题")
        conversation.append(question)
        conversation.append(AIConversationMessage(role: .assistant, text: "旧答案"))

        XCTAssertTrue(
            conversation.replaceUserMessageAndTruncate(
                id: question.id,
                with: "  新的   第一问  "
            )
        )

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages[0].id, question.id)
        XCTAssertEqual(conversation.messages[0].text, "新的   第一问")
        XCTAssertEqual(conversation.title, "新的 第一问")
        XCTAssertTrue(conversation.titleIsAutomatic)
    }

    func testReplacingFirstQuestionPreservesManualTitle() {
        var conversation = AIConversation()
        let question = AIConversationMessage(role: .user, text: "旧问题")
        conversation.append(question)
        conversation.append(AIConversationMessage(role: .assistant, text: "旧答案"))
        XCTAssertTrue(conversation.rename(to: "保留的手动标题"))

        XCTAssertTrue(
            conversation.replaceUserMessageAndTruncate(
                id: question.id,
                with: "新的第一问"
            )
        )

        XCTAssertEqual(conversation.title, "保留的手动标题")
        XCTAssertFalse(conversation.titleIsAutomatic)
    }

    func testReplacingLastQuestionRetainsEarlierTurnAndRemovesOldAnswer() throws {
        let firstQuestion = AIConversationMessage(role: .user, text: "第一问")
        let firstAnswer = AIConversationMessage(role: .assistant, text: "第一答")
        let lastQuestion = AIConversationMessage(role: .user, text: "第二问")
        let oldAnswer = AIConversationMessage(role: .assistant, text: "旧第二答")
        var conversation = AIConversation(messages: [
            firstQuestion,
            firstAnswer,
            lastQuestion,
            oldAnswer
        ])

        XCTAssertTrue(
            conversation.replaceUserMessageAndTruncate(
                id: lastQuestion.id,
                with: "修改后的第二问"
            )
        )

        XCTAssertEqual(
            conversation.messages.map(\.id),
            [firstQuestion.id, firstAnswer.id, lastQuestion.id]
        )
        XCTAssertEqual(conversation.messages.last?.text, "修改后的第二问")
        XCTAssertEqual(
            conversation.requestHistory(excludingMessageID: lastQuestion.id),
            [
                try GatewayChatMessage(role: .user, content: "第一问"),
                try GatewayChatMessage(role: .assistant, content: "第一答")
            ]
        )
    }

    func testInvalidQuestionReplacementLeavesConversationUntouched() {
        let question = AIConversationMessage(role: .user, text: "原问题")
        let answer = AIConversationMessage(role: .assistant, text: "原答案")
        var conversation = AIConversation(messages: [question, answer])
        let original = conversation
        let utf8HeavyQuestion = String(repeating: "👨‍👩‍👧‍👦", count: 400)

        XCTAssertLessThanOrEqual(
            utf8HeavyQuestion.count,
            GatewayRequestPolicy.maximumQuestionCharacters
        )
        XCTAssertGreaterThan(
            utf8HeavyQuestion.utf8.count,
            GatewayRequestPolicy.maximumQuestionBytes
        )

        XCTAssertFalse(
            conversation.replaceUserMessageAndTruncate(
                id: question.id,
                with: utf8HeavyQuestion
            )
        )
        XCTAssertEqual(conversation, original)
        XCTAssertFalse(
            conversation.replaceUserMessageAndTruncate(
                id: answer.id,
                with: "错误目标"
            )
        )
        XCTAssertEqual(conversation, original)
    }

    func testLegacyMessageWithoutStatusDecodesAsCompleted() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "role": "assistant",
              "text": "旧归档答案",
              "createdAt": 0,
              "reasoning": null,
              "citations": [],
              "answerBasis": "",
              "wasTruncated": false
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(AIConversationMessage.self, from: data)

        XCTAssertEqual(message.status, .completed)
        XCTAssertEqual(message.text, "旧归档答案")
        XCTAssertNil(message.responseItems)
    }

    func testAssistantResponseItemsPersistAndUserCannotStoreThem() throws {
        let responseItems = try makeResponseItems(answer: "原始答案")
        let assistant = AIConversationMessage(
            role: .assistant,
            text: "原始答案",
            responseItems: responseItems
        )
        let user = AIConversationMessage(
            role: .user,
            text: "用户问题",
            responseItems: responseItems
        )
        let decoded = try JSONDecoder().decode(
            AIConversationMessage.self,
            from: JSONEncoder().encode(assistant)
        )

        XCTAssertEqual(decoded.responseItems, responseItems)
        XCTAssertNil(user.responseItems)
    }

    func testOversizedArchivedResponseItemsAreDroppedWithoutLosingMessage() throws {
        let message = AIConversationMessage(role: .assistant, text: "仍可显示的旧答案")
        let data = try JSONEncoder().encode(message)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["responseItems"] = Array(
            repeating: [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "答案"]]
            ],
            count: GatewayRequestPolicy.maximumResponseItemsPerMessage + 1
        )

        let decoded = try JSONDecoder().decode(
            AIConversationMessage.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.text, "仍可显示的旧答案")
        XCTAssertNil(decoded.responseItems)
    }

    func testRequestHistoryKeepsOnlyCompletedUserAssistantPairs() throws {
        var conversation = AIConversation()
        let currentQuestion = AIConversationMessage(role: .user, text: "继续解释")
        conversation.messages = [
            AIConversationMessage(role: .assistant, text: "不能作为开头"),
            AIConversationMessage(role: .user, text: "第一问"),
            AIConversationMessage(role: .assistant, text: "第一答"),
            AIConversationMessage(role: .user, text: "没有完成的问"),
            AIConversationMessage(
                role: .assistant,
                text: "未完成的部分回答",
                status: .pending
            ),
            AIConversationMessage(role: .user, text: "被连续问题替代"),
            AIConversationMessage(role: .user, text: "第二问"),
            AIConversationMessage(role: .assistant, text: "第二答"),
            AIConversationMessage(
                role: .assistant,
                text: "中断回答",
                status: .interrupted
            ),
            currentQuestion
        ]

        let history = conversation.requestHistory(excludingMessageID: currentQuestion.id)

        XCTAssertEqual(history, [
            try GatewayChatMessage(role: .user, content: "第一问"),
            try GatewayChatMessage(role: .assistant, content: "第一答"),
            try GatewayChatMessage(role: .user, content: "第二问"),
            try GatewayChatMessage(role: .assistant, content: "第二答")
        ])
    }

    func testRequestHistoryCarriesExactAssistantResponseItems() throws {
        let responseItems = try makeResponseItems(answer: "第一答")
        let conversation = AIConversation(messages: [
            AIConversationMessage(role: .user, text: "第一问"),
            AIConversationMessage(
                role: .assistant,
                text: "第一答",
                responseItems: responseItems
            )
        ])

        let history = conversation.requestHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertNil(history[0].responseItems)
        XCTAssertEqual(history[1].responseItems, responseItems)
    }

    func testRequestHistoryUsesNewestWholeTurnsWithinCharacterBudget() throws {
        let oversizedUser = AIConversationMessage(
            role: .user,
            text: String(repeating: "旧", count: GatewayRequestPolicy.maximumConversationCharacters)
        )
        let conversation = AIConversation(messages: [
            oversizedUser,
            AIConversationMessage(role: .assistant, text: "旧答案"),
            AIConversationMessage(role: .user, text: "最近问题"),
            AIConversationMessage(role: .assistant, text: "最近答案")
        ])

        XCTAssertEqual(conversation.requestHistory(), [
            try GatewayChatMessage(role: .user, content: "最近问题"),
            try GatewayChatMessage(role: .assistant, content: "最近答案")
        ])
    }

    func testRequestHistoryUsesNewestWholeTurnsWithinUTF8Budget() throws {
        let family = "👨‍👩‍👧‍👦"
        let large = String(repeating: family, count: 800)
        let conversation = AIConversation(messages: [
            AIConversationMessage(role: .user, text: large),
            AIConversationMessage(role: .assistant, text: large),
            AIConversationMessage(role: .user, text: large),
            AIConversationMessage(role: .assistant, text: large),
            AIConversationMessage(role: .user, text: large),
            AIConversationMessage(role: .assistant, text: large)
        ])

        let history = conversation.requestHistory()

        XCTAssertEqual(history.count, 4)
        XCTAssertLessThanOrEqual(
            history.reduce(0) { $0 + $1.content.utf8.count },
            GatewayRequestPolicy.maximumConversationBytes
        )
    }

    func testRequestHistoryDropsOldRawContextBeforeDroppingVisibleTurns() throws {
        let responseItems = try makeResponseItems(
            answer: "答案",
            padding: String(repeating: "x", count: 45_000)
        )
        var messages: [AIConversationMessage] = []
        for index in 0..<3 {
            messages.append(AIConversationMessage(role: .user, text: "q\(index)"))
            messages.append(
                AIConversationMessage(
                    role: .assistant,
                    text: "a\(index)",
                    responseItems: responseItems
                )
            )
        }

        let history = AIConversation(messages: messages).requestHistory()
        let retainedContextBytes = try history.reduce(into: 0) { total, message in
            if let items = message.responseItems {
                total += try GatewayResponseItemsPolicy.byteCount(of: items)
            }
        }

        XCTAssertEqual(history.count, 6)
        XCTAssertNil(history[1].responseItems)
        XCTAssertNotNil(history[3].responseItems)
        XCTAssertNotNil(history[5].responseItems)
        XCTAssertLessThanOrEqual(
            retainedContextBytes,
            GatewayRequestPolicy.maximumConversationResponseItemsBytes
        )
    }

    func testPendingAndInterruptedStatusRoundTripAndDriveEmptyPreview() throws {
        let pending = AIConversationMessage(
            role: .assistant,
            text: "",
            status: .pending
        )
        let interrupted = AIConversationMessage(
            role: .assistant,
            text: "",
            status: .interrupted
        )

        let decoded = try JSONDecoder().decode(
            AIConversationMessage.self,
            from: JSONEncoder().encode(pending)
        )

        XCTAssertEqual(decoded.status, .pending)
        XCTAssertEqual(AIConversation(messages: [pending]).preview, "正在回答…")
        XCTAssertEqual(AIConversation(messages: [interrupted]).preview, "回答已中断")
    }

    func testConversationCapsMessageCount() {
        var conversation = AIConversation()
        for index in 0..<(AIConversationPolicy.maximumMessagesPerConversation + 3) {
            conversation.append(
                AIConversationMessage(role: .user, text: "message-\(index)")
            )
        }

        XCTAssertEqual(
            conversation.messages.count,
            AIConversationPolicy.maximumMessagesPerConversation
        )
        XCTAssertEqual(conversation.messages.first?.text, "message-3")
    }

    func testArchiveKeepsNewestConversationsAndRepairsSelection() {
        let old = AIConversation(
            id: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1),
            messages: [AIConversationMessage(role: .user, text: "old")]
        )
        let selected = UUID()
        var conversations = [old]
        for index in 0..<(AIConversationPolicy.maximumConversations + 2) {
            conversations.append(
                AIConversation(
                    id: UUID(),
                    title: "chat-\(index)",
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 2)),
                    messages: [AIConversationMessage(role: .user, text: "new-\(index)")]
                )
            )
        }

        let compacted = AIConversationArchive(
            conversations: conversations,
            selectedConversationID: selected
        ).compacted()

        XCTAssertEqual(
            compacted.conversations.count,
            AIConversationPolicy.maximumConversations
        )
        XCTAssertEqual(compacted.conversations.first?.title, "chat-21")
        XCTAssertEqual(
            compacted.selectedConversationID,
            compacted.conversations.first?.id
        )
    }

    func testArchiveCompactionCountsAndCapsResponseItemBytes() throws {
        let padding = String(repeating: "x", count: 28_000)
        let responseItems = try makeResponseItems(answer: "答案", padding: padding)
        var messages: [AIConversationMessage] = []
        for index in 0..<10 {
            messages.append(AIConversationMessage(role: .user, text: "q\(index)"))
            messages.append(
                AIConversationMessage(
                    role: .assistant,
                    text: "a\(index)",
                    responseItems: responseItems
                )
            )
        }
        let conversation = AIConversation(messages: messages)
        let compacted = AIConversationArchive(
            conversations: [conversation],
            selectedConversationID: conversation.id
        ).compacted()
        let retained = try XCTUnwrap(compacted.conversations.first)
        let retainedBytes = try retained.messages.reduce(into: 0) { total, message in
            if let items = message.responseItems {
                total += try GatewayResponseItemsPolicy.byteCount(of: items)
            }
        }

        XCTAssertEqual(retained.messages.count, messages.count)
        XCTAssertNil(retained.messages[1].responseItems)
        XCTAssertNotNil(retained.messages.last?.responseItems)
        XCTAssertLessThanOrEqual(
            retainedBytes,
            AIConversationPolicy.maximumStoredResponseItemsBytes
        )
    }

    func testSSEParserHandlesMetadataDeltaDoneAndComments() throws {
        var parser = GatewaySSEParser()
        XCTAssertNil(try parser.consume(line: ": keepalive"))
        XCTAssertNil(try parser.consume(line: "data: {\"type\":\"delta\",\"text\":\"你\"}"))
        XCTAssertEqual(try parser.consume(line: ""), .delta("你"))

        XCTAssertNil(try parser.consume(
            line: "data: {\"type\":\"done\",\"answer\":\"你好\",\"reasoning\":null,\"truncated\":false}"
        ))
        XCTAssertEqual(
            try parser.finish(),
            .done(answer: "你好", reasoning: nil, truncated: false)
        )
    }

    func testSSEByteParserPreservesBlankEventBoundariesDroppedByAsyncLines() throws {
        let stream = """
        data: {"type":"delta","text":"你"}

        data: {"type":"reasoning_delta","text":"想"}

        data: {"type":"done","answer":"你好","reasoning":"想","truncated":false}

        """
        var parser = GatewaySSEByteParser()
        var events: [GatewayAskStreamEvent] = []
        for byte in Data(stream.utf8) {
            if let event = try parser.consume(byte: byte) {
                events.append(event)
            }
        }
        if let event = try parser.finish() {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .delta("你"),
            .reasoningDelta("想"),
            .done(answer: "你好", reasoning: "想", truncated: false)
        ])
    }

    func testSSEByteParserAcceptsCRLFAndFinalEventWithoutBlankLine() throws {
        let stream = "data: {\"type\":\"delta\",\"text\":\"OK\"}\r\n"
        var parser = GatewaySSEByteParser()
        var events: [GatewayAskStreamEvent] = []
        for byte in Data(stream.utf8) {
            if let event = try parser.consume(byte: byte) {
                events.append(event)
            }
        }
        if let event = try parser.finish() {
            events.append(event)
        }
        XCTAssertEqual(events, [.delta("OK")])
    }

    private func makeResponseItems(
        answer: String,
        padding: String = ""
    ) throws -> [GatewayResponseItem] {
        [
            try GatewayResponseItem(
                rawValue: .object([
                    "type": .string("reasoning"),
                    "summary": .array([])
                ])
            ),
            try GatewayResponseItem(
                rawValue: .object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string(answer)
                        ])
                    ]),
                    "padding": .string(padding)
                ])
            )
        ]
    }
}

extension AIConversationTests {
    func testAnswerFooterUsesSavedRequestOptionsAndNormalizesHistoricalLabels() throws {
        var message = AIConversationMessage(role: .assistant, text: "回答",
            answerBasis: "DeepSeek V4 Pro 官方 API · Cloudflare 免费转发 · 深度思考 · DeepSeek 联网搜索")
        XCTAssertEqual(message.answerFooter, "DeepSeek V4 Pro · 深度思考 · 联网搜索")
        message.answerOptions = AIAnswerOptions(modelIdentifier: "deepseek-v4-flash",
            deepThinking: false, webSearch: true)
        let restored = try JSONDecoder().decode(AIConversationMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.answerFooter, "DeepSeek V4 Flash · 联网搜索")
        XCTAssertEqual(AIAnswerOptions(modelIdentifier: "deepseek-v4-pro", deepThinking: false, webSearch: false).footer,
                       "DeepSeek V4 Pro")
    }
}

extension AIConversationTests {
    func testGeneratedTitlePersistsAndManualRenameWins() throws {
        let first = AIConversationMessage(role: .user, text: "你好")
        let topic = AIConversationMessage(role: .user, text: "请解释为什么抛物线上的点到焦点和准线距离相等")
        var conversation = AIConversation()
        conversation.append(first)
        conversation.append(topic)
        XCTAssertEqual(conversation.topicQuestion?.id, topic.id)
        XCTAssertTrue(conversation.applyGeneratedTitle("「抛物线的焦点与准线」", for: topic))
        conversation.append(AIConversationMessage(role: .user, text: "能再举一个例子吗"))
        let data = try JSONEncoder().encode(conversation)
        var restored = try JSONDecoder().decode(AIConversation.self, from: data)
        XCTAssertFalse(restored.refreshAutomaticTitle())
        XCTAssertEqual(restored.title, "抛物线的焦点与准线")
        XCTAssertTrue(restored.rename(to: "解析几何"))
        XCTAssertFalse(restored.applyGeneratedTitle("旧请求返回的主题", for: topic))
        XCTAssertEqual(restored.title, "解析几何")
    }

    func testEditingTopicRejectsStaleTitleFromOriginalQuestion() {
        var conversation = AIConversation()
        let topic = AIConversationMessage(role: .user, text: "介绍一下抛物线")
        conversation.append(topic)
        XCTAssertTrue(conversation.applyGeneratedTitle("抛物线方程", for: topic))
        XCTAssertTrue(conversation.replaceUserMessageAndTruncate(id: topic.id, with: "解释椭圆定义"))
        XCTAssertNil(conversation.generatedTitleQuestionID)
        XCTAssertEqual(conversation.title, "椭圆定义")
        XCTAssertFalse(conversation.applyGeneratedTitle("旧抛物线主题", for: topic))
    }
}
