import XCTest
@testable import BrowserCore

final class GatewayProtocolTests: XCTestCase {
    func testAIRequestPathPrefersDirectDeepSeekThenCloudflareProxy() {
        XCTAssertEqual(
            AIRequestPathPolicy.select(
                hasDeepSeekCredential: true,
                hasValidCloudflareConfiguration: true
            ),
            .directDeepSeek
        )
        XCTAssertEqual(
            AIRequestPathPolicy.select(
                hasDeepSeekCredential: false,
                hasValidCloudflareConfiguration: true
            ),
            .cloudflareDeepSeekProxy
        )
        XCTAssertEqual(
            AIRequestPathPolicy.select(
                hasDeepSeekCredential: false,
                hasValidCloudflareConfiguration: false
            ),
            .unconfigured
        )
    }

    func testReadRequestUsesBoundedSnakeCaseContract() throws {
        let request = GatewayReadRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/a?q=1")),
            preferDynamic: true,
            maxBlocks: 999,
            maxCharacters: 999_999,
            maxLinks: 999
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(object["url"] as? String, "https://example.com/a?q=1")
        XCTAssertEqual(object["prefer_dynamic"] as? Bool, true)
        XCTAssertEqual(object["max_blocks"] as? Int, 40)
        XCTAssertEqual(object["max_characters"] as? Int, 12_000)
        XCTAssertEqual(object["max_links"] as? Int, 30)

        let lowerBound = GatewayReadRequest(
            url: try XCTUnwrap(URL(string: "https://example.com")),
            maxCharacters: 1
        )
        XCTAssertEqual(lowerBound.maxCharacters, 500)
    }

    func testRetryPolicyRetriesOnlyTheFirstStructuredFailure() {
        XCTAssertTrue(
            GatewayRetryPolicy.shouldRetry(
                attempt: 0,
                statusCode: 503,
                serverMarkedRetryable: false
            )
        )
        XCTAssertTrue(
            GatewayRetryPolicy.shouldRetry(
                attempt: 0,
                statusCode: 409,
                serverMarkedRetryable: true
            )
        )
        XCTAssertFalse(
            GatewayRetryPolicy.shouldRetry(
                attempt: 1,
                statusCode: 503,
                serverMarkedRetryable: true
            )
        )
        XCTAssertFalse(
            GatewayRetryPolicy.shouldRetry(
                attempt: 1,
                statusCode: 429,
                serverMarkedRetryable: false
            )
        )
    }

    func testGatewayRedirectPolicyRejectsSameAndCrossOriginRedirects() throws {
        let original = try XCTUnwrap(URL(string: "https://gateway.example/v1/ask"))
        XCTAssertFalse(
            GatewayRedirectPolicy.allowsRedirect(
                from: original,
                to: try XCTUnwrap(URL(string: "https://gateway.example/v2/ask"))
            )
        )
        XCTAssertFalse(
            GatewayRedirectPolicy.allowsRedirect(
                from: original,
                to: try XCTUnwrap(URL(string: "https://attacker.example/collect"))
            )
        )
    }

    func testPersonalAIFallbackIsLimitedToOrdinaryQuestionsAndUnavailableGateway() {
        XCTAssertTrue(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: false,
                isNetworkFailure: true
            )
        )
        XCTAssertTrue(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: false,
                isNetworkFailure: false,
                httpStatusCode: 503,
                errorCode: "ai_not_configured"
            )
        )
        XCTAssertFalse(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: true,
                isNetworkFailure: true,
                httpStatusCode: 503,
                errorCode: "ai_not_configured"
            )
        )
        XCTAssertFalse(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: false,
                isNetworkFailure: false,
                httpStatusCode: 429,
                errorCode: "rate_limited"
            )
        )
        XCTAssertFalse(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: false,
                isNetworkFailure: false,
                httpStatusCode: 401,
                errorCode: "unauthorized"
            )
        )
        XCTAssertFalse(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: false,
                isNetworkFailure: false,
                httpStatusCode: 503,
                errorCode: "workers_ai_daily_limit"
            )
        )
        XCTAssertFalse(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: false,
                isNetworkFailure: false,
                httpStatusCode: 503,
                errorCode: "ai_provider_capacity",
                errorMessage: "Cloudflare error 3040: capacity temporarily exhausted"
            )
        )
        XCTAssertFalse(
            GatewayPersonalFallbackPolicy.shouldOffer(
                forPageBoundTask: false,
                isNetworkFailure: false,
                httpStatusCode: 429,
                errorCode: "ai_capacity_unavailable"
            )
        )
    }

    func testFreeGatewayIssuesClassifyQuotaAvailabilityAndExpiredSessions() {
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 429,
                errorCode: "ai_daily_limit"
            ),
            .aiDailyQuotaExhausted
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 503,
                errorCode: "workers_ai_daily_limit"
            ),
            .aiDailyQuotaExhausted
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 429,
                errorCode: "ai_provider_error",
                errorMessage: "Workers AI internal code 3036: Account limited"
            ),
            .aiDailyQuotaExhausted
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 503,
                errorCode: "ai_provider_capacity",
                errorMessage: "Cloudflare error 3040: capacity temporarily exhausted"
            ),
            .aiCapacityUnavailable
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 429,
                errorCode: "ai_capacity_unavailable"
            ),
            .aiCapacityUnavailable
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 429,
                errorCode: "browser_run_daily_limit_exceeded"
            ),
            .dynamicDailyQuotaExhausted
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 503,
                errorCode: "renderer_quota_exhausted"
            ),
            .dynamicDailyQuotaExhausted
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 429,
                errorCode: "too_many_requests"
            ),
            .rateLimited
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 503,
                errorCode: "browser_run_unavailable"
            ),
            .dynamicServiceUnavailable
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 503,
                errorCode: "ai_missing_key"
            ),
            .aiNotConfigured
        )
        XCTAssertEqual(
            GatewayServiceIssuePolicy.classify(
                statusCode: 410,
                errorCode: nil
            ),
            .sessionExpired
        )
    }

    func testHealthAcceptsOKAndDegradedOn2xxThenKeepsReadinessSeparate() throws {
        let ok = try JSONDecoder().decode(
            GatewayHealthResponse.self,
            from: Data(
                """
                {"status":"ok","browser_ready":true,"reader_ready":true,"ai_configured":false}
                """.utf8
            )
        )
        XCTAssertTrue(ok.isAccepted(httpStatusCode: 200))
        XCTAssertTrue(ok.browserReady)
        XCTAssertTrue(ok.effectiveReaderReady)
        XCTAssertEqual(ok.aiConfigured, false)

        let degraded = try JSONDecoder().decode(
            GatewayHealthResponse.self,
            from: Data(
                """
                {"status":"degraded","browser_ready":false,"reader_ready":true,"ai_configured":true,"detail":"renderer unavailable"}
                """.utf8
            )
        )
        XCTAssertTrue(degraded.isAccepted(httpStatusCode: 206))
        XCTAssertFalse(degraded.browserReady)
        XCTAssertTrue(degraded.effectiveReaderReady)
        XCTAssertEqual(degraded.aiConfigured, true)
        XCTAssertFalse(degraded.isAccepted(httpStatusCode: 503))

        let unknown = try JSONDecoder().decode(
            GatewayHealthResponse.self,
            from: Data("{\"status\":\"down\",\"browser_ready\":false}".utf8)
        )
        XCTAssertFalse(unknown.isAccepted(httpStatusCode: 200))
    }

    func testNavigationIntentSurvivesFallbackAndPushesPriorPageOnce() throws {
        let intent = ReaderNavigationIntent(
            remembersCurrentPage: true,
            isBackNavigation: false
        )
        let pageA = try XCTUnwrap(URL(string: "https://example.com/a"))
        let pageB = try XCTUnwrap(URL(string: "https://example.com/b"))
        XCTAssertTrue(
            intent.shouldPushCurrentPage(
                hasCurrentDocument: true,
                currentURL: pageA,
                resolvedURL: pageB
            )
        )
        XCTAssertFalse(
            intent.shouldPushCurrentPage(
                hasCurrentDocument: true,
                currentURL: pageA,
                resolvedURL: pageA
            )
        )
        XCTAssertFalse(
            ReaderNavigationIntent.none.shouldPushCurrentPage(
                hasCurrentDocument: true,
                currentURL: pageA,
                resolvedURL: pageB
            )
        )
    }

    func testCredentialMigrationPrefersDefaultsAndRejectsBuildPlaceholders() {
        XCTAssertEqual(
            GatewayCredentialMigrationPolicy.preferredLegacyToken(
                defaultsToken: " user-token ",
                bundleToken: "bundle-token"
            ),
            "user-token"
        )
        XCTAssertEqual(
            GatewayCredentialMigrationPolicy.preferredLegacyToken(
                defaultsToken: nil,
                bundleToken: " bundle-token "
            ),
            "bundle-token"
        )
        XCTAssertNil(
            GatewayCredentialMigrationPolicy.preferredLegacyToken(
                defaultsToken: "$(BROWSER_RENDERER_TOKEN)",
                bundleToken: " "
            )
        )
    }

    func testReadResponseDecodesIntoWatchDocumentAndPageContext() throws {
        let data = Data(
            """
            {
              "url": "https://example.com/start",
              "final_url": "https://example.com/final",
              "title": "示例页",
              "blocks": [
                {"kind": "heading", "text": "标题"},
                {"kind": "paragraph", "text": "正文"}
              ],
              "links": [
                {"text": "下一页", "url": "/next"},
                {"text": "危险链接", "url": "file:///tmp/a"}
              ],
              "truncated": true,
              "source": "browser",
              "character_count": 4,
              "blocked_subresources": 2
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(GatewayReadResponse.self, from: data)
        let document = try response.directDocument()

        XCTAssertEqual(document.title, "示例页")
        XCTAssertEqual(document.text, "标题\n\n正文")
        XCTAssertEqual(document.links, [
            DirectWebLink(title: "下一页", url: try XCTUnwrap(URL(string: "https://example.com/next")))
        ])
        XCTAssertTrue(document.wasTruncated)
        XCTAssertEqual(response.blockedSubresources, 2)
        XCTAssertEqual(response.pageContext.url, "https://example.com/final")
    }

    func testAskContractsCoverWebSearchSummaryAndPageQuestion() throws {
        let page = GatewayPageContext(
            url: "https://example.com",
            title: "示例",
            blocks: [GatewayContentBlock(kind: "paragraph", text: "页面内容")]
        )
        let web = try GatewayAskRequest(
            question: " 今天有什么新闻？ ",
            webSearch: true
        )
        let summary = try GatewayAskRequest(
            question: "请总结当前页面",
            mode: .summarize,
            webSearch: false,
            page: page
        )
        let pageQuestion = try GatewayAskRequest(
            question: "作者的结论是什么？",
            webSearch: false,
            page: page
        )

        XCTAssertEqual(web.question, "今天有什么新闻？")
        XCTAssertTrue(web.webSearch)
        XCTAssertNil(web.page)
        XCTAssertEqual(summary.mode, .summarize)
        XCTAssertEqual(summary.page, page)
        XCTAssertEqual(pageQuestion.mode, .answer)
        XCTAssertEqual(pageQuestion.page, page)

        let emptyPage = GatewayPageContext(url: nil, title: nil, blocks: [])
        let emptyPageObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(emptyPage)) as? [String: Any]
        )
        XCTAssertNotNil(emptyPageObject["blocks"] as? [Any])
    }

    func testAskRequestEncodesDeepThinkingStableIDAndCompleteHistory() throws {
        let requestID = "2db5f4c6-1a37-4e3c-9d4b-62d22147a02b"
        let request = try GatewayAskRequest(
            requestID: requestID,
            question: "继续解释",
            webSearch: true,
            deepThinking: true,
            history: [
                try GatewayChatMessage(role: .user, content: "第一问"),
                try GatewayChatMessage(role: .assistant, content: "第一答")
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["request_id"] as? String, requestID)
        XCTAssertEqual(object["deep_thinking"] as? Bool, true)
        XCTAssertEqual(object["web_search"] as? Bool, true)
        let history = try XCTUnwrap(object["history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0]["role"] as? String, "user")
        XCTAssertEqual(history[1]["role"] as? String, "assistant")
    }

    func testAskRequestRejectsInvalidHistorySequenceAndUTF8Overflow() throws {
        XCTAssertThrowsError(
            try GatewayAskRequest(
                question: "继续",
                webSearch: false,
                history: [
                    try GatewayChatMessage(role: .assistant, content: "错误开头"),
                    try GatewayChatMessage(role: .user, content: "错误结尾")
                ]
            )
        ) { error in
            XCTAssertEqual(error as? GatewayProtocolError, .invalidConversationSequence)
        }

        let family = "👨‍👩‍👧‍👦"
        XCTAssertThrowsError(
            try GatewayAskRequest(
                question: String(repeating: family, count: 400),
                webSearch: false
            )
        ) { error in
            XCTAssertEqual(
                error as? GatewayProtocolError,
                .questionTooLong(maximum: GatewayRequestPolicy.maximumQuestionCharacters)
            )
        }

        XCTAssertThrowsError(
            try GatewayChatMessage(
                role: .user,
                content: String(repeating: family, count: 1_300)
            )
        ) { error in
            XCTAssertEqual(error as? GatewayProtocolError, .conversationMessageTooLong)
        }
    }

    func testResponseItemsRoundTripAndAreAssistantOnly() throws {
        let item = try JSONDecoder().decode(
            GatewayResponseItem.self,
            from: Data(
                """
                {
                  "type": "message",
                  "id": "msg_1",
                  "role": "assistant",
                  "status": "completed",
                  "content": [{
                    "type": "output_text",
                    "text": "包含 \\\"引号\\\" 与换行\\n内容",
                    "annotations": []
                  }],
                  "metadata": {"attempt": 1, "cached": false, "extra": null}
                }
                """.utf8
            )
        )
        let assistant = try GatewayChatMessage(
            role: .assistant,
            content: "可见答案",
            responseItems: [item]
        )
        let encoded = try JSONEncoder().encode(assistant)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNotNil(object["response_items"])
        XCTAssertNil(object["responseItems"])
        XCTAssertEqual(try JSONDecoder().decode(GatewayChatMessage.self, from: encoded), assistant)
        XCTAssertThrowsError(
            try GatewayChatMessage(
                role: .user,
                content: "用户问题",
                responseItems: [item]
            )
        ) { error in
            XCTAssertEqual(error as? GatewayProtocolError, .invalidResponseItems)
        }
    }

    func testResponseItemsRejectUnsupportedTypeWrongRoleAndExcessCount() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                GatewayResponseItem.self,
                from: Data(#"{"type":"file_search_call"}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                GatewayResponseItem.self,
                from: Data(#"{"type":"message","role":"user","content":[]}"#.utf8)
            )
        )

        let reasoning = try JSONDecoder().decode(
            GatewayResponseItem.self,
            from: Data(#"{"type":"reasoning","summary":[]}"#.utf8)
        )
        XCTAssertThrowsError(
            try GatewayChatMessage(
                role: .assistant,
                content: "答案",
                responseItems: Array(
                    repeating: reasoning,
                    count: GatewayRequestPolicy.maximumResponseItemsPerMessage + 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? GatewayProtocolError, .invalidResponseItems)
        }
    }

    func testAskRequestCapsAggregateResponseItemBytes() throws {
        let padding = String(repeating: "上下文", count: 4_000)
        let raw = GatewayJSONValue.object([
            "type": .string("message"),
            "role": .string("assistant"),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string("答案")
                ])
            ]),
            "padding": .string(padding)
        ])
        let item = try GatewayResponseItem(rawValue: raw)
        var history: [GatewayChatMessage] = []
        for index in 0..<12 {
            history.append(try GatewayChatMessage(role: .user, content: "问\(index)"))
            history.append(
                try GatewayChatMessage(
                    role: .assistant,
                    content: "答\(index)",
                    responseItems: [item]
                )
            )
        }

        XCTAssertThrowsError(
            try GatewayAskRequest(question: "继续", webSearch: true, history: history)
        ) { error in
            XCTAssertEqual(error as? GatewayProtocolError, .conversationTooLong)
        }
    }

    func testStreamEventDecodesReasoningDelta() throws {
        let data = Data(
            #"{"type":"reasoning_delta","text":"先分析条件"}"#.utf8
        )

        XCTAssertEqual(
            try JSONDecoder().decode(GatewayAskStreamEvent.self, from: data),
            .reasoningDelta("先分析条件")
        )
    }

    func testSummaryRequiresPageAndQuestionLengthIsBounded() {
        XCTAssertThrowsError(
            try GatewayAskRequest(
                question: "请总结",
                mode: .summarize,
                webSearch: false
            )
        ) { error in
            XCTAssertEqual(error as? GatewayProtocolError, .pageRequired)
        }

        XCTAssertThrowsError(
            try GatewayAskRequest(
                question: String(
                    repeating: "问",
                    count: GatewayRequestPolicy.maximumQuestionCharacters + 1
                ),
                webSearch: true
            )
        ) { error in
            XCTAssertEqual(
                error as? GatewayProtocolError,
                .questionTooLong(maximum: GatewayRequestPolicy.maximumQuestionCharacters)
            )
        }
    }

    func testAskResponseDecodesEvidenceFlagsAndRejectsBlankAnswer() throws {
        let valid = Data(
            """
            {
              "answer": "  最终答案  ",
              "citations": [{"title": "来源", "url": "https://example.com/source"}],
              "model": "deepseek-chat",
              "web_search_used": true,
              "web_search_provider": "wikimedia",
              "page_context_used": false,
              "truncated": true
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(GatewayAskResponse.self, from: valid)
        XCTAssertEqual(try response.validatedAnswer(), "最终答案")
        XCTAssertNil(response.reasoning)
        XCTAssertTrue(response.webSearchUsed)
        XCTAssertEqual(response.webSearchProvider, .wikimedia)
        XCTAssertFalse(response.pageContextUsed)
        XCTAssertEqual(response.truncated, true)
        XCTAssertEqual(response.citations.count, 1)

        let empty = GatewayAskResponse(
            answer: " \n ",
            citations: [],
            model: "model",
            webSearchUsed: false,
            webSearchProvider: nil,
            pageContextUsed: true,
            truncated: nil
        )
        XCTAssertThrowsError(try empty.validatedAnswer()) { error in
            XCTAssertEqual(error as? GatewayProtocolError, .emptyAnswer)
        }
    }

    func testAskResponseAcceptsMissingAndFutureWebSearchProviders() throws {
        let withoutProvider = Data(
            """
            {
              "answer": "旧网关答案",
              "citations": [],
              "model": "model",
              "web_search_used": false,
              "page_context_used": false
            }
            """.utf8
        )
        let legacyResponse = try JSONDecoder().decode(
            GatewayAskResponse.self,
            from: withoutProvider
        )
        XCTAssertNil(legacyResponse.webSearchProvider)
        XCTAssertNil(legacyResponse.responseItems)

        let futureProvider = Data(
            """
            {
              "answer": "新搜索服务答案",
              "citations": [],
              "model": "model",
              "web_search_used": true,
              "web_search_provider": "future-provider",
              "page_context_used": false
            }
            """.utf8
        )
        let futureResponse = try JSONDecoder().decode(
            GatewayAskResponse.self,
            from: futureProvider
        )
        XCTAssertEqual(futureResponse.webSearchProvider, .other("future-provider"))
    }

    func testAskResponseAndStreamMetadataDecodeResponseItemsCompatibly() throws {
        let response = try JSONDecoder().decode(
            GatewayAskResponse.self,
            from: Data(
                """
                {
                  "answer": "答案",
                  "citations": [],
                  "model": "deepseek-v4-pro",
                  "web_search_used": true,
                  "web_search_provider": "deepseek",
                  "page_context_used": false,
                  "response_items": [
                    {"type":"reasoning","summary":[]},
                    {"type":"message","role":"assistant","content":[{"type":"output_text","text":"答案"}]}
                  ]
                }
                """.utf8
            )
        )
        XCTAssertEqual(response.responseItems?.count, 2)

        let event = try JSONDecoder().decode(
            GatewayAskStreamEvent.self,
            from: Data(
                """
                {
                  "type": "metadata",
                  "citations": [],
                  "model": "deepseek-v4-pro",
                  "web_search_used": true,
                  "web_search_provider": "deepseek",
                  "page_context_used": false,
                  "response_items": [
                    {"type":"web_search_call","id":"search_1"},
                    {"type":"message","role":"assistant","content":[{"type":"output_text","text":"答案"}]}
                  ]
                }
                """.utf8
            )
        )
        guard case .metadata(let metadata) = event else {
            return XCTFail("Expected metadata")
        }
        XCTAssertEqual(metadata.responseItems?.count, 2)

        let legacyMetadata = try JSONDecoder().decode(
            GatewayAskStreamEvent.self,
            from: Data(
                """
                {"type":"metadata","citations":[],"model":"legacy","web_search_used":false,"page_context_used":false}
                """.utf8
            )
        )
        guard case .metadata(let metadata) = legacyMetadata else {
            return XCTFail("Expected legacy metadata")
        }
        XCTAssertNil(metadata.responseItems)
    }

    func testReadResponseAcceptsExpandedCharacterCountContract() throws {
        let data = Data(
            """
            {
              "url": "https://example.com",
              "final_url": "https://example.com",
              "title": "示例",
              "blocks": [{"kind": "paragraph", "text": "正文"}],
              "links": [],
              "truncated": false,
              "source": "static",
              "total_character_count": 99
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(GatewayReadResponse.self, from: data)
        XCTAssertEqual(response.characterCount, 99)
        XCTAssertEqual(response.blockedSubresources, 0)
    }
}
