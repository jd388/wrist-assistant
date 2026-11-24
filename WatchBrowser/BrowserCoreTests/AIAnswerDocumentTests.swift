import XCTest
@testable import BrowserCore

final class AIAnswerDocumentTests: XCTestCase {
    func testHeadingsParagraphsAndBothListStyles() {
        let blocks = AIAnswerDocument.parse("# 标题\n\n第一段\n第二行\n\n- 项目\n  2) 嵌套\n    续行")
        XCTAssertEqual(blocks.map(\.text), ["标题", "第一段\n第二行", "项目", "嵌套\n续行"])
        XCTAssertEqual(blocks[0].kind, .heading(1))
        XCTAssertEqual(blocks[2].kind, .listItem(marker: "•", depth: 0))
        XCTAssertEqual(blocks[3].kind, .listItem(marker: "2)", depth: 1))
    }

    func testQuotesRulesAndSetextHeadings() {
        let blocks = AIAnswerDocument.parse("小标题\n---\n\n> 引用一\n> 引用二\n\n***")
        XCTAssertEqual(blocks.map(\.kind), [.heading(2), .quote, .divider])
        XCTAssertEqual(blocks[1].text, "引用一\n引用二")
    }

    func testUnfinishedCodePreservesIndentationAndMarkdownSymbols() {
        let prefix = "```swift\n  let x = \"**literal**\"\n    print(x)"
        let pending = AIAnswerDocument.parse(prefix)
        XCTAssertEqual(pending, AIAnswerDocument.parse(prefix + "\n```"))
        XCTAssertEqual(pending[0].kind, .code(language: "swift"))
        XCTAssertEqual(pending[0].text, "  let x = \"**literal**\"\n    print(x)")
    }

    func testLongerFenceDoesNotCloseAtShorterFence() {
        let blocks = AIAnswerDocument.parse("````text\n```\ninside\n````\n\nend")
        XCTAssertEqual(blocks[0].text, "```\ninside")
        XCTAssertEqual(blocks.last?.text, "end")
    }

    func testTableBecomesRecordsWithRepeatedColumnLabels() {
        let blocks = AIAnswerDocument.parse("| 名称 | 释义 |\n| :--- | ---: |\n| apple | 苹果 |\n| pear | 梨 |")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.kind), [.tableRecord, .tableRecord])
        XCTAssertEqual(blocks[0].fields.map(\.name), ["名称", "释义"])
        XCTAssertEqual(blocks[1].fields.map(\.value), ["pear", "梨"])
    }

    func testTableWithoutOuterPipesAndEscapedPipesOrInlineCode() {
        let blocks = AIAnswerDocument.parse("名称 | 说明\n--- | ---\na\\|b | `x|y`\nc | ``x|`y``")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].fields.map(\.value), ["a|b", "`x|y`"])
        XCTAssertEqual(blocks[1].fields.map(\.value), ["c", "``x|`y``"])
    }

    func testRaggedTableNeverDropsExtraValuesOrHeader() {
        let blocks = AIAnswerDocument.parse("| A | B |\n| --- | --- |\n| one |\n| two | three | four |")
        XCTAssertEqual(blocks[0].fields.map(\.value), ["one", "—"])
        XCTAssertEqual(blocks[1].fields.map(\.value), ["two", "three", "four"])
        XCTAssertEqual(blocks[1].fields.last?.name, "第3列")
        XCTAssertEqual(AIAnswerDocument.parse("| A | B |\n| --- | --- |").first?.text, "A · B")
    }

    func testPartialTableAndNonMarkdownPipesStayReadable() {
        for text in ["left | right", "| A | B |\n| --", "#hashtag", "2026.11.21", "**unfinished", "中文 👨‍👩‍👧‍👦"] {
            XCTAssertEqual(AIAnswerDocument.parse(text).map(\.text).joined(separator: "\n"), text)
        }
    }

    func testCompletedBlocksKeepTheirIdentityAndContentWhileStreaming() {
        let prefix = "# 标题\n\n- 已经读过的列表\n\n"
        for suffix in ["", "新", "新段落\n第二行", "新段落\n\n## 下一部分"] {
            XCTAssertEqual(Array(AIAnswerDocument.parse(prefix + suffix).prefix(2)), AIAnswerDocument.parse(prefix))
        }
    }

    func testLongUnicodeAnswerAndEmptyInput() {
        XCTAssertTrue(AIAnswerDocument.parse("").isEmpty)
        let paragraph = String(repeating: "长内容 👋", count: 10_000)
        XCTAssertEqual(AIAnswerDocument.parse(paragraph).first?.text, paragraph)
        XCTAssertEqual(AIAnswerDocument.parse("a\r\nb\r\nc").first?.text, "a\nb\nc")
    }

    func testReadingPausedThroughoutDragDecelerationAndContentGrowth() {
        var follow = AIReadingFollowState()
        XCTAssertTrue(follow.shouldFollowUpdates)
        follow.beginUserScroll()
        follow.updateGeometry(distanceFromBottom: 400)
        XCTAssertFalse(follow.shouldFollowUpdates)
        follow.endUserScroll(distanceFromBottom: 400)
        for distance in [450.0, 900, 2_000] { follow.updateGeometry(distanceFromBottom: distance) }
        XCTAssertFalse(follow.followsLatest)
        XCTAssertFalse(follow.shouldFollowUpdates)
    }

    func testContentGrowthAtBottomDoesNotDisableFollowing() {
        var follow = AIReadingFollowState()
        follow.updateGeometry(distanceFromBottom: 800)
        XCTAssertTrue(follow.shouldFollowUpdates)
    }

    func testWatchViewportAccountsForNavigationAndBottomInsets() {
        // Captured watchOS geometry: offset + container height alone misses 106pt
        // of visible content represented by the system's scroll insets.
        XCTAssertEqual(AIReadingFollowState.distanceFromBottom(contentHeight: 1470, bottomInset: 40, visibleBottom: 1510), 0)
        XCTAssertEqual(AIReadingFollowState.distanceFromBottom(contentHeight: 1470, bottomInset: 40, visibleBottom: 960), 550)
        XCTAssertEqual(AIReadingFollowState.distanceFromBottom(contentHeight: 1470, bottomInset: 40, visibleBottom: 1550), 0)
    }

    func testManualReturnToBottomAndExplicitReturnResumeFollowing() {
        var follow = AIReadingFollowState()
        follow.beginUserScroll()
        follow.endUserScroll(distanceFromBottom: 300)
        follow.beginUserScroll()
        follow.updateGeometry(distanceFromBottom: 20)
        XCTAssertFalse(follow.shouldFollowUpdates)
        follow.endUserScroll(distanceFromBottom: 20)
        XCTAssertTrue(follow.shouldFollowUpdates)
        follow.beginUserScroll()
        follow.returnToLatest()
        XCTAssertTrue(follow.shouldFollowUpdates)
    }

    func testEmptyConversationNeverOffersReturnEvenAfterScrollEvents() {
        var follow = AIReadingFollowState()
        follow.reset(answer: nil)
        follow.beginUserScroll()
        follow.endUserScroll(distanceFromBottom: 200)
        follow.observeAnswer(nil)
        XCTAssertFalse(follow.shouldShowReturnToLatest)
        follow.observeAnswer(.init(id: UUID(), text: " \n\t"))
        XCTAssertFalse(follow.shouldShowReturnToLatest)
    }

    func testBrowsingAnExistingAnswerDoesNotCreateUnreadContent() {
        let answer = AIReadingAnswerSnapshot(id: UUID(), text: "历史回答")
        var follow = AIReadingFollowState()
        follow.reset(answer: answer)
        follow.beginUserScroll()
        follow.endUserScroll(distanceFromBottom: 400)
        follow.observeAnswer(answer)
        XCTAssertFalse(follow.shouldShowReturnToLatest)
        follow.updateGeometry(distanceFromBottom: 800)
        XCTAssertFalse(follow.shouldShowReturnToLatest)
    }

    func testOnlyNewlyReceivedContentWhileAwayOffersReturn() {
        let id = UUID()
        var follow = AIReadingFollowState()
        follow.reset(answer: .init(id: id, text: "已经读过"))
        follow.beginUserScroll()
        follow.endUserScroll(distanceFromBottom: 400)
        follow.observeAnswer(.init(id: id, text: "已经读过，后续新内容"))
        XCTAssertTrue(follow.shouldShowReturnToLatest)
        // Finishing the request does not lose its unread indication.
        follow.observeAnswer(.init(id: id, text: "已经读过，后续新内容"), allowsUnread: false)
        XCTAssertTrue(follow.shouldShowReturnToLatest)
    }

    func testLoadingStaticHistoryWhileAwayDoesNotNotify() {
        var follow = AIReadingFollowState()
        follow.beginUserScroll()
        follow.endUserScroll(distanceFromBottom: 400)
        follow.observeAnswer(.init(id: UUID(), text: "刚加载的历史"), allowsUnread: false)
        XCTAssertFalse(follow.shouldShowReturnToLatest)
    }

    func testReceivingAtBottomKeepsFollowingWithoutAnIndicator() {
        let id = UUID()
        var follow = AIReadingFollowState()
        follow.reset(answer: .init(id: id, text: "第一段"))
        follow.observeAnswer(.init(id: id, text: "第一段\n\n第二段"))
        XCTAssertTrue(follow.shouldFollowUpdates)
        XCTAssertFalse(follow.shouldShowReturnToLatest)
    }

    func testBothExplicitAndManualReturnClearUnreadContent() {
        for explicit in [true, false] {
            let id = UUID()
            var follow = AIReadingFollowState()
            follow.reset(answer: .init(id: id, text: "原内容"))
            follow.beginUserScroll()
            follow.endUserScroll(distanceFromBottom: 300)
            follow.observeAnswer(.init(id: id, text: "原内容和新内容"))
            XCTAssertTrue(follow.shouldShowReturnToLatest)
            if explicit { follow.returnToLatest() }
            else { follow.beginUserScroll(); follow.endUserScroll(distanceFromBottom: 0) }
            XCTAssertFalse(follow.shouldShowReturnToLatest)
            XCTAssertFalse(follow.hasUnreadAnswer)
            XCTAssertTrue(follow.shouldFollowUpdates)
        }
    }

    func testSwitchingToEmptyOrAnotherConversationResetsUnreadContent() {
        let id = UUID()
        for next: AIReadingAnswerSnapshot? in [nil, .init(id: UUID(), text: "另一个对话")] {
            var follow = AIReadingFollowState()
            follow.reset(answer: .init(id: id, text: "原内容"))
            follow.beginUserScroll()
            follow.endUserScroll(distanceFromBottom: 300)
            follow.observeAnswer(.init(id: id, text: "原内容和新内容"))
            XCTAssertTrue(follow.shouldShowReturnToLatest)
            follow.reset(answer: next)
            XCTAssertFalse(follow.shouldShowReturnToLatest)
        }
    }

    func testClearingPendingAnswerRemovesStaleUnreadIndicator() {
        let id = UUID()
        var follow = AIReadingFollowState()
        follow.reset(answer: .init(id: id, text: "原内容"))
        follow.beginUserScroll()
        follow.endUserScroll(distanceFromBottom: 300)
        follow.observeAnswer(.init(id: id, text: "新内容"))
        XCTAssertTrue(follow.shouldShowReturnToLatest)
        follow.observeAnswer(.init(id: UUID(), text: ""))
        XCTAssertFalse(follow.shouldShowReturnToLatest)
    }
}

extension AIAnswerDocumentTests {
    func testFormatsChemistryAndMathWithoutLettingMarkdownStripSyntax() {
        let formula = #"配平 \(\ce{2H2 + O2 -> 2H2O}\)，以及 **分数 $\frac{x^{2}}{\sqrt{2}}$**。"#
        let display = String(AIMathText.attributed(formula).characters)
        XCTAssertEqual(display, "配平 2H₂ + O₂ → 2H₂O，以及 分数 x²⁄(√2)。")
        XCTAssertEqual(String(AIMathText.attributed(#"\ce{Fe^{3+} + e^- -> Fe^{2+}}"#).characters), "Fe³⁺ + e⁻ → Fe²⁺")
        XCTAssertEqual(String(AIMathText.attributed(#"$\mathrm{CH_3COOH}$"#).characters), "CH₃COOH")
        let markdown = String(AIMathText.attributed(#"`$x_2$` 的价格是 $5 或 $10。"#).characters)
        XCTAssertEqual(markdown, "$x_2$ 的价格是 $5 或 $10。")
    }

    func testStreamingAndUnsupportedMarkupRetainOriginalText() {
        let incomplete = #"\[\frac{1}"#
        XCTAssertEqual(String(AIMathText.attributed(incomplete).characters), incomplete)
        let unsupported = #"\(\unknown{x_1}\)"#
        XCTAssertEqual(String(AIMathText.attributed(unsupported).characters), unsupported)
        let display = """
        第一段
        \\[
        x_{1} = \\alpha
        \\]下一段
        """
        let blocks = AIAnswerDocument.parse(display)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .math, .paragraph])
        XCTAssertEqual(String(AIMathText.attributed(blocks[1].text).characters), "x₁ = α")
        XCTAssertEqual(blocks[2].text, "下一段")
    }

    func testMatrixRowsKeepAlignmentAndEscapedAmpersands() {
        let input = #"\[A = \begin{bmatrix}1 & -20 \\[3pt] 30 & 4\end{bmatrix}\]"#
        let blocks = AIAnswerDocument.parse(input)
        XCTAssertEqual(blocks.map(\.kind), [.math])
        XCTAssertEqual(String(AIMathText.attributed(blocks[0].text).characters),
                       "A =\n⎡ 1   -20 ⎤\n⎣ 30  4   ⎦")
        let singleRow = #"$\begin{pmatrix}a\&b & 2\end{pmatrix}$"#
        XCTAssertEqual(String(AIMathText.attributed(singleRow).characters), "( a&b  2 )")
        let aligned = #"\[\begin{aligned}a&=1\\ b&=2\end{aligned}\]"#
        XCTAssertEqual(String(AIMathText.attributed(aligned).characters), "a =1\nb =2")
    }

    func testCasesAndIndexedRootsRenderTogether() {
        let input = #"\[f(x)=\begin{cases}\sqrt[3]{x}&\text{当 }x\ge 0\\ \sqrt[5]{-x}&\text{当 }x<0\end{cases}\]"#
        XCTAssertEqual(String(AIMathText.attributed(input).characters),
                       "f(x)=\n⎧ ∛x      当 x≥0\n⎩ ⁵√(-x)  当 x<0")
        XCTAssertEqual(String(AIMathText.attributed(#"$\sqrt[n+1]{x+1}$"#).characters), "ⁿ⁺¹√(x+1)")
        XCTAssertEqual(String(AIMathText.attributed(#"$\sqrt[3]{x}^2$"#).characters), "(∛x)²")
    }

    func testArrowAnnotationsAndReactionCoefficients() {
        let math = #"\(A \xrightarrow[\text{低温}]{\Delta} B \overset{k}{\rightleftharpoons} C\)"#
        XCTAssertEqual(String(AIMathText.attributed(math).characters), "A →（上：Δ，下：低温） B ⇌（上：k） C")
        let chemistry = #"\ce{2H2 + O2 ->[80^\circ\mathrm{C}][\text{Pt}] 2H2O}"#
        XCTAssertEqual(String(AIMathText.attributed(chemistry).characters), "2H₂ + O₂ →（上：80°C，下：Pt） 2H₂O")
        XCTAssertEqual(String(AIMathText.attributed(#"\ce{Fe^2+->Fe^3+}"#).characters), "Fe²⁺→Fe³⁺")
    }

    func testIncompleteStructuredMathAndUnknownChemistryStayLiteral() {
        let partial = #"\[A=\begin{pmatrix}1&2\\"#
        let mismatched = #"\[A=\begin{pmatrix}1&2\end{bmatrix}\]"#
        let unknown = #"\ce{A ->[\unknown{B}] C}"#
        for input in [partial, mismatched, unknown] {
            XCTAssertEqual(String(AIMathText.attributed(input).characters), input)
        }
    }

    func testSingleTokenFractionAndRootArgumentsDisplayInsteadOfRawMarkup() {
        let formula = #"\[5p^2+14p+17=5\left(p+\frac75\right)^2+\frac{36}{5}\]"#
        XCTAssertEqual(String(AIMathText.attributed(formula).characters), "5p²+14p+17=5(p+7⁄5)²+36⁄5")
        XCTAssertEqual(String(AIMathText.attributed(#"\(\sqrt[3]x+\frac\alpha2\)"#).characters), "∛x+α⁄2")
        XCTAssertEqual(String(AIMathText.attributed(#"\[\frac7\]"#).characters), #"\[\frac7\]"#)
    }

    func testFormulaDecorationExposesBothScriptPositions() {
        var scriptPositions: [Bool] = []
        let rendered = AIMathText.attributed(#"A \(t_1^2\), B \(t_2^2\)"#) { formula, attributes in
            for glyph in formula {
                if let script = AIMathText.scriptGlyph(glyph) { scriptPositions.append(script.isSuperscript) }
            }
            return AttributedString(formula, attributes: attributes)
        }
        XCTAssertEqual(String(rendered.characters), "A t₁², B t₂²")
        XCTAssertEqual(scriptPositions, [false, true, false, true])
    }
}
