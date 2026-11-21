import SwiftUI

/// Shared by the standalone dictionary and the combined Watch app.
struct LexiWatchLookupView: View {
    var ownsNavigationStack = true
    @StateObject private var model = LookupViewModel()
    @State private var isShowingHistory = false
    @State private var isShowingFavorites = false
    @State private var favoriteEntryPendingRemoval: DictionaryEntry?
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if ownsNavigationStack {
                NavigationStack { lookupContent }
            } else {
                lookupContent
            }
        }
        .sheet(isPresented: $isShowingHistory) {
            RecentHistoryView(model: model) {
                isShowingHistory = false
            }
        }
        .sheet(isPresented: $isShowingFavorites) {
            FavoritesView(model: model) {
                isShowingFavorites = false
            }
        }
        .confirmationDialog(
            "取消收藏这个单词？",
            isPresented: Binding(
                get: { favoriteEntryPendingRemoval != nil },
                set: { isPresented in
                    if !isPresented { favoriteEntryPendingRemoval = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let entry = favoriteEntryPendingRemoval {
                Button("取消收藏 \(entry.headword)", role: .destructive) {
                    model.toggleFavorite(entry)
                    favoriteEntryPendingRemoval = nil
                }
            }
            Button("保留收藏", role: .cancel) {
                favoriteEntryPendingRemoval = nil
            }
        } message: {
            Text("确认后会从单词本移除，也可以以后再收藏。")
        }
        .tint(Color(red: 0.35, green: 0.86, blue: 0.66))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1), value: model.phase)
    }

    private var lookupContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !showsDictionaryEntry {
                        searchField
                        historyEntry
                        favoritesEntry
                    }
                    resultModule
                        .id("lookup-result")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.phase) { _, phase in
                guard phase != .idle else { return }
                if reduceMotion {
                    proxy.scrollTo("lookup-result", anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("lookup-result", anchor: .top)
                    }
                }
            }
        }
        .navigationTitle("秒查")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)

            TextField(
                "单词、短语或句子",
                text: $model.query
            )
                .focused($inputFocused)
                .submitLabel(.search)
                .onSubmit(model.submit)
                .accessibilityLabel("输入要查询或翻译的中文或英文")

            if !model.query.isEmpty {
                Button(action: model.clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空输入")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var historyEntry: some View {
        Button {
            isShowingHistory = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text("搜索历史")
                        .font(.body.weight(.semibold))
                    Text(model.recentQueries.first ?? "暂无记录")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                countBadge(model.recentQueries.count)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(historyAccessibilityLabel)
        .accessibilityHint("查看全部记录，点击一项可重新查询")
    }

    private var favoritesEntry: some View {
        Button {
            isShowingFavorites = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                Text("单词本")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 4)
                countBadge(model.favorites.count)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("打开单词本，已收藏\(model.favorites.count)个单词")
        .accessibilityHint("可以查看或移除收藏的单词")
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: Capsule())
            .accessibilityHidden(true)
    }

    private var historyAccessibilityLabel: String {
        guard let latest = model.recentQueries.first else {
            return "打开搜索历史，暂无记录"
        }
        return "打开搜索历史，共\(model.recentQueries.count)条，最近\(latest)"
    }

    private var showsDictionaryEntry: Bool {
        if case .local = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var resultModule: some View {
        if model.phase != .idle {
            VStack(alignment: .leading, spacing: 7) {
                if !showsDictionaryEntry {
                    Label("本次结果", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
                phaseContent
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .searching:
            statusCard(
                icon: "ellipsis",
                title: "正在识别",
                detail: "正在查询离线词典。"
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .translating:
            VStack(alignment: .leading, spacing: 9) {
                statusCard(
                    icon: "memorychip",
                    title: "正在本地翻译",
                    detail: "词典没有精确结果，已自动使用手表模型；首次载入会稍慢。"
                ) {
                    ProgressView()
                        .controlSize(.small)
                }
                correctionSuggestions(title: "也可能想查")
            }
        case .local(let match):
            localResult(match)
        case .translation(let translation):
            translationResult(translation)
        case .resourceError(let issue):
            resourceErrorView(issue)
        case .noResult(let message):
            noResultView(message)
        }
    }

    private func localResult(_ match: DictionaryMatch) -> some View {
        let featuredExpressions = featuredExpressions(for: match.entry)

        return VStack(alignment: .leading, spacing: 6) {
            entryHeader(match.entry)

            if match.entry.meanings.count > 3 {
                ForEach(MeaningGroup.groups(for: match.entry.meanings)) { group in
                    meaningGroupLink(group, headword: match.entry.headword)
                }
            } else {
                ForEach(Array(match.entry.meanings.enumerated()), id: \.offset) { index, meaning in
                    MeaningCard(
                        meaning: meaning,
                        position: match.entry.meanings.count > 1 ? index + 1 : nil,
                        partOfSpeech: index == 0 || meaning.partOfSpeech != match.entry.meanings[index - 1].partOfSpeech
                    )
                }
            }

            expressionSection(
                title: "短语动词",
                icon: "arrow.triangle.branch",
                expressions: featuredExpressions.filter { $0.kind == .phrasalVerb }
            )

            expressionSection(
                title: "动词句型",
                icon: "text.line.first.and.arrowtriangle.forward",
                expressions: featuredExpressions.filter { $0.kind == .verbPattern }
            )

            expressionSection(
                title: "固定搭配",
                icon: "link",
                expressions: featuredExpressions.filter { $0.kind == .fixedPhrase }
            )

            if match.entry.relatedExpressions.count > featuredExpressions.count {
                NavigationLink {
                    RelatedExpressionsView(entry: match.entry)
                } label: {
                    Label(
                        "查看全部 \(match.entry.relatedExpressions.count) 条表达",
                        systemImage: "list.bullet"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("在新页面按类型查看，不会丢失当前查词结果")
            }

            correctionSuggestions(title: "其他常用译法")
            editButton

            Text(match.entry.source ?? (match.entry.priority >= 30_000 ? "扩展词库" : "离线词典"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
    }

    private func entryHeader(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 4) {
                Text(entry.headword)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                favoriteButton(for: entry)
            }
            if let pronunciation = entry.pronunciation, !pronunciation.isEmpty {
                Text(pronunciation)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private func meaningGroupLink(_ group: MeaningGroup, headword: String) -> some View {
        NavigationLink {
            MeaningGroupView(headword: headword, group: group)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text("\(group.meanings.count) 个义项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let first = group.meanings.first {
                        Text(first.chinese.isEmpty ? first.englishDefinition ?? "" : first.chinese)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看该词性的完整释义和例句")
    }

    private func favoriteButton(for entry: DictionaryEntry) -> some View {
        let isFavorite = model.isFavorite(entry)

        return Button {
            if isFavorite {
                favoriteEntryPendingRemoval = entry
            } else {
                model.toggleFavorite(entry)
            }
        } label: {
            Image(systemName: isFavorite ? "bookmark.fill" : "bookmark")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "\(entry.headword)已收藏" : "收藏\(entry.headword)到单词本")
        .accessibilityHint(isFavorite ? "轻点后确认取消收藏" : "轻点收藏，以后可从单词本快速查看")
    }

    @ViewBuilder
    private func expressionSection(
        title: String,
        icon: String,
        expressions: [DictionaryEntry.RelatedExpression]
    ) -> some View {
        if !expressions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)

                ForEach(expressions) { expression in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expression.text)
                            .font(.body.weight(.semibold))
                        if !expression.chinese.isEmpty {
                            Text(expression.chinese)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let example = expression.example {
                            Text(example)
                                .font(.caption2)
                                .italic()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let exampleChinese = expression.exampleChinese {
                            Text(exampleChinese)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(9)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func featuredExpressions(
        for entry: DictionaryEntry,
        limit: Int = 6
    ) -> [DictionaryEntry.RelatedExpression] {
        FeaturedExpressionPolicy.select(
            from: entry.relatedExpressions,
            limit: limit
        )
    }

    private func translationResult(_ translation: LocalTranslation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("翻译结果")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                sourceBadge(translation.source.label, systemImage: translation.source.systemImage)
            }
            Text(translation.translated)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.4)
            Text("原文")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(translation.original)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("\(translation.routeLabel) · 完全离线", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            correctionSuggestions(title: "也可能想查")
            editButton
        }
        .padding(10)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func correctionSuggestions(title: String) -> some View {
        if !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "text.magnifyingglass")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(model.suggestions) { suggestion in
                    Button {
                        model.chooseSuggestion(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.entry.headword)
                                .font(.body.weight(.semibold))
                            Text(suggestion.entry.meanings.first?.chinese ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func noResultView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("这次没有得到结果", systemImage: "questionmark.circle")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            correctionSuggestions(title: "可能想查")
            Button(action: model.retry) {
                Label("再次尝试", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            editButton
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func resourceErrorView(_ issue: DictionaryResourceIssue) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(issue.detail)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(issue.recovery)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            correctionSuggestions(title: "也可以先查")
            Button(action: model.translateUsingModelOnly) {
                Label("仅使用本地翻译", systemImage: "memorychip")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("跳过不可用的词典，明确使用离线模型处理原输入")
            editButton
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var editButton: some View {
        Button {
            model.editQuery()
            inputFocused = true
        } label: {
            Label("修改输入", systemImage: "pencil")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func sourceBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.13), in: Capsule())
    }

    private func statusCard<Trailing: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            trailing()
        }
        .padding(10)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusCard(icon: String, title: String, detail: String) -> some View {
        statusCard(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}


private struct MeaningGroup: Identifiable {
    let title: String
    let meanings: [DictionaryEntry.Meaning]
    var id: String { title }

    static func groups(for meanings: [DictionaryEntry.Meaning]) -> [Self] {
        var order: [String] = []
        var contents: [String: [DictionaryEntry.Meaning]] = [:]
        for meaning in meanings {
            let title = partOfSpeechTitle(meaning.partOfSpeech)
            if contents[title] == nil { order.append(title) }
            contents[title, default: []].append(meaning)
        }
        return order.map { Self(title: $0, meanings: contents[$0, default: []]) }
    }

    static func partOfSpeechTitle(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "noun", "n", "n.": return "名词"
        case "verb", "v", "v.", "vt.", "vi.": return "动词"
        case "adjective", "adj", "adj.", "a", "a.": return "形容词"
        case "adverb", "adv", "adv.": return "副词"
        case "pronoun", "pron", "pron.": return "代词"
        case "preposition", "prep", "prep.": return "介词"
        case "conjunction", "conj", "conj.": return "连词"
        case "interjection", "int", "int.", "interj.": return "感叹词"
        case "determiner", "det", "det.": return "限定词"
        default: return value.isEmpty ? "释义" : value
        }
    }
}

private struct MeaningGroupView: View {
    let headword: String
    let group: MeaningGroup

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(headword)
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(group.meanings.enumerated()), id: \.offset) { index, meaning in
                    MeaningCard(meaning: meaning, position: index + 1, partOfSpeech: false)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MeaningCard: View {
    let meaning: DictionaryEntry.Meaning
    let position: Int?
    let partOfSpeech: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if partOfSpeech && !meaning.partOfSpeech.isEmpty {
                Text(MeaningGroup.partOfSpeechTitle(meaning.partOfSpeech))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let position {
                    Text("\(position).")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(meaning.chinese.isEmpty ? meaning.englishDefinition ?? "" : meaning.chinese)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let definition = meaning.englishDefinition, !meaning.chinese.isEmpty {
                Text(definition)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let example = meaning.example {
                Divider()
                Text(example)
                    .font(.caption)
                    .italic()
                if let translation = meaning.exampleChinese {
                    Text(translation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !meaning.collocations.isEmpty {
                Divider()
                Text("搭配")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(Array(meaning.collocations.enumerated()), id: \.offset) { _, collocation in
                    Text(collocation).font(.caption)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RelatedExpressionsView: View {
    let entry: DictionaryEntry

    var body: some View {
        List {
            expressionSection(
                title: "短语动词",
                icon: "arrow.triangle.branch",
                kind: .phrasalVerb
            )
            expressionSection(
                title: "动词句型",
                icon: "text.line.first.and.arrowtriangle.forward",
                kind: .verbPattern
            )
            expressionSection(
                title: "固定搭配",
                icon: "link",
                kind: .fixedPhrase
            )
        }
        .listStyle(.carousel)
        .scrollIndicators(.hidden)
        .navigationTitle("全部表达 \(entry.relatedExpressions.count)")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func expressionSection(
        title: String,
        icon: String,
        kind: DictionaryEntry.RelatedExpression.Kind
    ) -> some View {
        let expressions = entry.relatedExpressions.filter { $0.kind == kind }
        if !expressions.isEmpty {
            Section {
                ForEach(expressions) { expression in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(expression.text)
                            .font(.body.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if !expression.chinese.isEmpty {
                            Text(expression.chinese)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let example = expression.example {
                            Text(example)
                                .font(.caption2)
                                .italic()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let exampleChinese = expression.exampleChinese {
                            Text(exampleChinese)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Label(title, systemImage: icon)
            }
        }
    }
}

private struct RecentHistoryView: View {
    @ObservedObject var model: LookupViewModel
    let close: () -> Void

    @State private var pendingDeletion: PendingDeletion?

    private enum PendingDeletion: Equatable {
        case query(String)
        case all
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.recentQueries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationTitle("搜索历史 \(model.recentQueries.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: close)
                        .accessibilityLabel("关闭搜索历史")
                }
                if !model.recentQueries.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("清空", role: .destructive) {
                            pendingDeletion = .all
                        }
                        .accessibilityLabel("清空全部搜索历史")
                        .accessibilityHint("需要再次确认")
                    }
                }
            }
        }
        .confirmationDialog(
            deletionDialogTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { pendingDeletion = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            switch pendingDeletion {
            case let .query(query):
                Button("删除 \(query)", role: .destructive) {
                    model.removeRecent(query)
                    pendingDeletion = nil
                }
            case .all:
                Button("清空全部", role: .destructive) {
                    model.clearRecentQueries()
                    pendingDeletion = nil
                }
            case nil:
                EmptyView()
            }
            Button("保留", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            switch pendingDeletion {
            case let .query(query):
                Text("只删除“\(query)”这条记录。")
            case .all:
                Text("将永久删除全部搜索历史。")
            case nil:
                EmptyView()
            }
        }
    }

    private var historyList: some View {
        List {
            ForEach(model.recentQueries, id: \.self) { query in
                historyRow(query)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = .query(query)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .accessibilityLabel("删除搜索记录\(query)")
                        .accessibilityHint("需要再次确认")
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.carousel)
        .scrollIndicators(.hidden)
    }

    private func historyRow(_ query: String) -> some View {
        Button {
            model.selectRecent(query)
            close()
        } label: {
            HStack(alignment: .center, spacing: 7) {
                Text(query)
                    .font(.body.weight(.semibold))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("重新查询\(query)")
        .accessibilityHint("轻点显示查询结果；向左滑动可以删除")
        .accessibilityAction(named: "删除") {
            pendingDeletion = .query(query)
        }
    }

    private var deletionDialogTitle: String {
        switch pendingDeletion {
        case .query:
            return "删除这条记录？"
        case .all:
            return "清空全部搜索历史？"
        case nil:
            return "删除搜索历史？"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("还没有搜索记录")
                .font(.headline)
            Text("查词或翻译成功后，最近输入会自动保存在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: close) {
                Label("返回搜索", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("关闭搜索历史并回到主页")
        }
        .padding(.horizontal, 10)
    }
}

private struct FavoritesView: View {
    @ObservedObject var model: LookupViewModel
    let close: () -> Void

    @State private var favoritePendingRemoval: FavoriteWord?

    var body: some View {
        NavigationStack {
            Group {
                if model.favorites.isEmpty {
                    emptyState
                } else {
                    favoritesList
                }
            }
            .navigationTitle("单词本 \(model.favorites.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: close)
                        .accessibilityLabel("关闭单词本")
                }
            }
        }
        .confirmationDialog(
            "从单词本移除？",
            isPresented: Binding(
                get: { favoritePendingRemoval != nil },
                set: { isPresented in
                    if !isPresented { favoritePendingRemoval = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let favorite = favoritePendingRemoval {
                Button("移除 \(favorite.headword)", role: .destructive) {
                    model.removeFavorite(favorite)
                    favoritePendingRemoval = nil
                }
            }
            Button("保留", role: .cancel) {
                favoritePendingRemoval = nil
            }
        } message: {
            if let favorite = favoritePendingRemoval {
                Text("将移除“\(favorite.headword)”，不会影响词典内容。")
            }
        }
    }

    private var favoritesList: some View {
        List {
            ForEach(model.favorites, id: \.id) { favorite in
                favoriteRow(favorite)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            favoritePendingRemoval = favorite
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                        .accessibilityLabel("移除收藏\(favorite.headword)")
                        .accessibilityHint("需要再次确认")
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.carousel)
        .scrollIndicators(.hidden)
    }

    private func favoriteRow(_ favorite: FavoriteWord) -> some View {
        Button {
            model.selectFavorite(favorite)
            close()
        } label: {
            HStack(alignment: .center, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(favorite.headword)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if let pronunciation = favorite.pronunciation,
                           !pronunciation.isEmpty {
                            Text(pronunciation)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(favorite.conciseChinese)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看\(favorite.headword)，\(favorite.conciseChinese)")
        .accessibilityHint("轻点显示完整词条；向左滑动可以移除")
        .accessibilityAction(named: "移除") {
            favoritePendingRemoval = favorite
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "bookmark")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("还没有收藏")
                .font(.headline)
            Text("先查一个单词，然后轻点“收藏到单词本”。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: close) {
                Label("返回查词", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("关闭单词本并回到查词页")
        }
        .padding(.horizontal, 10)
    }
}

#Preview {
    LexiWatchLookupView()
}
