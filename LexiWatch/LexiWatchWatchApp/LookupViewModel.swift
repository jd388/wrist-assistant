import Foundation
import WatchKit

@MainActor
final class LookupViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching
        case translating
        case local(DictionaryMatch)
        case translation(LocalTranslation)
        case resourceError(DictionaryResourceIssue)
        case noResult(message: String)
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryDidChange()
        }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var suggestions: [DictionaryMatch] = []
    @Published private(set) var recentQueries: [String] = []
    @Published private(set) var favorites: [FavoriteWord] = []

    private static let favoritesDefaultsKey = "favoriteWords.v1"
    private static let historyDefaultsKey = "recentQueries"
    private static let legacyTranslationsDefaultsKey = "recentTranslations"
    private var searchEngine: DictionarySearchEngine?
    private var loadingTask: Task<Result<DictionarySearchEngine, DictionaryResourceIssue>, Never>?
    private var coreDictionaryIssue: DictionaryResourceIssue?
    private let extendedDictionary: ExtendedDictionaryStore
    private let oxfordDictionary: ExtendedDictionaryStore?
    private let translationService: LocalTranslationService
    private var searchTask: Task<Void, Never>?
    private var requestGate = LookupRequestGate()
    private let defaults: UserDefaults

    init(
        entries: [DictionaryEntry]? = nil,
        extendedDictionary: ExtendedDictionaryStore? = nil,
        translationService: LocalTranslationService = LocalTranslationService(),
        defaults: UserDefaults = .standard
    ) {
        self.translationService = translationService
        self.oxfordDictionary = Bundle.main.url(
            forResource: "oxford_advanced_10_zh_hans", withExtension: "sqlite"
        ).map { ExtendedDictionaryStore(databaseURL: $0) }
        self.extendedDictionary = extendedDictionary ?? ExtendedDictionaryStore(
            databaseURL: DictionaryRepository.extendedDatabaseURL()
        )
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.favoritesDefaultsKey),
           let savedFavorites = try? JSONDecoder().decode([FavoriteWord].self, from: data) {
            let deduplicated = FavoriteWord.deduplicatingMostRecent(savedFavorites)
            self.favorites = deduplicated
            if deduplicated != savedFavorites,
               let cleanedData = try? JSONEncoder().encode(deduplicated) {
                defaults.set(cleanedData, forKey: Self.favoritesDefaultsKey)
            }
        }
        let previousLookups = defaults.stringArray(forKey: Self.historyDefaultsKey) ?? []
        let previousTranslations = defaults.stringArray(
            forKey: Self.legacyTranslationsDefaultsKey
        ) ?? []
        self.recentQueries = SearchHistory.merging([
            previousLookups,
            previousTranslations
        ])
        defaults.set(self.recentQueries, forKey: Self.historyDefaultsKey)
        defaults.removeObject(forKey: Self.legacyTranslationsDefaultsKey)

        if let entries {
            self.searchEngine = DictionarySearchEngine(entries: entries)
        } else {
            let loader: Task<
                Result<DictionarySearchEngine, DictionaryResourceIssue>,
                Never
            > = Task.detached(priority: .userInitiated) {
                do {
                    return .success(
                        DictionarySearchEngine(
                            entries: try DictionaryRepository.loadBundledEntries()
                        )
                    )
                } catch let issue as DictionaryResourceIssue {
                    return .failure(issue)
                } catch {
                    return .failure(.coreInvalid)
                }
            }
            self.loadingTask = loader
            Task { @MainActor [weak self] in
                let result = await loader.value
                guard let self else { return }
                if case let .success(engine) = result {
                    self.searchEngine = engine
                } else if case let .failure(issue) = result {
                    self.coreDictionaryIssue = issue
                }
                self.loadingTask = nil
            }
        }

#if DEBUG
        // Device QA can launch the app with a deterministic query so layout
        // and real-watch lookup paths can be verified without repeatedly
        // typing on the Watch. Release builds never include this behavior.
        let arguments = ProcessInfo.processInfo.arguments
        let qaArgument = arguments.first(where: { $0.hasPrefix("--qa-query=") })?
            .dropFirst("--qa-query=".count)
            .description
        let qaQuery = (
            qaArgument ?? ProcessInfo.processInfo.environment["LEXIWATCH_QA_QUERY"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let qaQuery,
           !qaQuery.isEmpty {
            query = qaQuery
            Task { @MainActor [weak self] in
                // Give SwiftUI time to install its phase observer so the
                // result module scrolls into view for the captured screenshot.
                try? await Task.sleep(nanoseconds: 750_000_000)
                self?.submit()
            }
        }
#endif
    }

    deinit {
        searchTask?.cancel()
        loadingTask?.cancel()
    }

    func submit() {
        let submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuery.isEmpty else { return }

        searchTask?.cancel()
        let token = requestGate.begin()
        searchTask = Task { [weak self] in
            await self?.performUnifiedLookup(submittedQuery, token: token)
        }
    }

    func retry() {
        submit()
    }

    func chooseSuggestion(_ match: DictionaryMatch) {
        cancelActiveLookup()
        query = match.entry.headword
        phase = .local(match)
        suggestions = []
        remember(match.entry.headword)
        WKInterfaceDevice.current().play(.success)
    }

    func selectRecent(_ text: String) {
        query = text
        submit()
    }

    func removeRecent(_ text: String) {
        recentQueries = SearchHistory.removing(text, from: recentQueries)
        persistHistory()
        WKInterfaceDevice.current().play(.click)
    }

    func clearRecentQueries() {
        guard !recentQueries.isEmpty else { return }
        recentQueries = []
        persistHistory()
        WKInterfaceDevice.current().play(.click)
    }

    func isFavorite(_ entry: DictionaryEntry) -> Bool {
        favorites.contains { $0.id == entry.id }
    }

    func toggleFavorite(_ entry: DictionaryEntry) {
        guard case let .local(match) = phase,
              match.entry.id == entry.id else {
            return
        }

        if let index = favorites.firstIndex(where: { $0.id == entry.id }) {
            favorites.remove(at: index)
            persistFavorites()
            WKInterfaceDevice.current().play(.click)
        } else {
            favorites = FavoriteWord.deduplicatingMostRecent([
                FavoriteWord(entry: entry)
            ] + favorites)
            persistFavorites()
            WKInterfaceDevice.current().play(.success)
        }
    }

    func selectFavorite(_ favorite: FavoriteWord) {
        query = favorite.headword
        submit()
    }

    func removeFavorite(_ favorite: FavoriteWord) {
        guard favorites.contains(where: { $0.id == favorite.id }) else { return }
        favorites.removeAll { $0.id == favorite.id }
        persistFavorites()
        WKInterfaceDevice.current().play(.click)
    }

    func editQuery() {
        cancelActiveLookup()
        phase = .idle
        suggestions = []
    }

    func clear() {
        cancelActiveLookup()
        query = ""
        phase = .idle
        suggestions = []
    }

    func translateUsingModelOnly() {
        let submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuery.isEmpty else { return }

        searchTask?.cancel()
        let token = requestGate.begin()
        searchTask = Task { [weak self] in
            await self?.performTranslation(submittedQuery, token: token)
        }
    }

    private func performUnifiedLookup(
        _ submittedQuery: String,
        token: LookupRequestGate.Token
    ) async {
        guard requestGate.isCurrent(token) else { return }
        suggestions = []

        if let spelling = DeterministicNumberTranslation.englishSpelling(for: submittedQuery) {
            guard requestGate.isCurrent(token) else { return }
            phase = .translation(
                LocalTranslation(
                    original: submittedQuery,
                    translated: spelling,
                    direction: .chineseToEnglish,
                    source: .deterministicNumber
                )
            )
            remember(submittedQuery)
            WKInterfaceDevice.current().play(.success)
            return
        }

        phase = .searching

        if let oxfordDictionary,
           !DictionarySearchEngine.containsChinese(submittedQuery) {
            let oxfordMatches = try? await oxfordDictionary.search(submittedQuery, suggestionLimit: 0)
            guard requestGate.isCurrent(token) else { return }
            if let match = oxfordMatches?.bestMatch {
                phase = .local(match)
                remember(submittedQuery)
                WKInterfaceDevice.current().play(.success)
                return
            }
        }

        let engine: DictionarySearchEngine
        do {
            engine = try await readySearchEngine()
        } catch let issue as DictionaryResourceIssue {
            guard requestGate.isCurrent(token) else { return }
            presentResourceIssue(issue)
            return
        } catch {
            guard requestGate.isCurrent(token) else { return }
            presentResourceIssue(.coreInvalid)
            return
        }
        guard requestGate.isCurrent(token) else { return }
        guard let local = await searchCore(engine, query: submittedQuery) else {
            return
        }
        guard requestGate.isCurrent(token) else { return }
        suggestions = UnifiedLookupPolicy.correctionSuggestions(for: local)

        if !UnifiedLookupPolicy.shouldConsultExtendedDictionary(after: local),
           let match = local.bestMatch {
            phase = .local(match)
            remember(submittedQuery)
            WKInterfaceDevice.current().play(.success)
            return
        }

        let extended: SearchResponse
        do {
            extended = try await extendedDictionary.search(submittedQuery)
        } catch let error as ExtendedDictionaryStoreError {
            guard requestGate.isCurrent(token) else { return }
            presentResourceIssue(DictionaryResourceIssue.extended(error))
            return
        } catch {
            guard requestGate.isCurrent(token) else { return }
            presentResourceIssue(.extendedOpenFailed)
            return
        }
        guard requestGate.isCurrent(token) else { return }
        if let match = UnifiedLookupPolicy.preferredDictionaryMatch(
            core: local,
            extended: extended
        ) {
            suggestions = UnifiedLookupPolicy.correctionSuggestions(for: extended)
            if let coreMatch = local.bestMatch,
               coreMatch.entry.id != match.entry.id {
                suggestions.insert(coreMatch, at: 0)
                suggestions = Array(suggestions.prefix(3))
            }
            phase = .local(match)
            remember(submittedQuery)
            WKInterfaceDevice.current().play(.success)
            return
        }
        if !extended.suggestions.isEmpty {
            var seen = Set(suggestions.map(\.entry.id))
            suggestions.append(contentsOf: extended.suggestions.filter {
                seen.insert($0.entry.id).inserted
            })
            suggestions = Array(suggestions.prefix(3))
        }

        await performTranslation(submittedQuery, token: token)
    }

    private func readySearchEngine() async throws -> DictionarySearchEngine {
        if let searchEngine { return searchEngine }
        if let coreDictionaryIssue { throw coreDictionaryIssue }
        if let loadingTask {
            let result = await loadingTask.value
            self.loadingTask = nil
            switch result {
            case let .success(engine):
                self.searchEngine = engine
                return engine
            case let .failure(issue):
                coreDictionaryIssue = issue
                throw issue
            }
        }
        throw DictionaryResourceIssue.coreInvalid
    }

    /// Fuzzy lookup touches the complete 30k core index for a misspelled word.
    /// Keep that CPU work off MainActor so editing or clearing the query stays
    /// responsive, and explicitly forward cancellation to the detached worker.
    private func searchCore(
        _ engine: DictionarySearchEngine,
        query: String
    ) async -> SearchResponse? {
        let worker = Task.detached(priority: .userInitiated) {
            engine.search(query)
        }
        return await withTaskCancellationHandler {
            let response = await worker.value
            return Task.isCancelled ? nil : response
        } onCancel: {
            worker.cancel()
        }
    }

    private func performTranslation(
        _ submittedQuery: String,
        token: LookupRequestGate.Token
    ) async {
        guard requestGate.isCurrent(token) else { return }
        phase = .translating
        do {
            let translation = try await translationService.translate(submittedQuery)
            guard requestGate.isCurrent(token) else { return }
            phase = .translation(translation)
            remember(submittedQuery)
            WKInterfaceDevice.current().play(.success)
        } catch {
            guard requestGate.isCurrent(token) else { return }
            let detail = (error as? LocalizedError)?.errorDescription
                ?? "本地模型暂时没有生成结果。"
            let recovery = suggestions.isEmpty
                ? "可以修改后重试。"
                : "也可以先选择下面的相近词。"
            phase = .noResult(message: "\(detail) 原输入已保留，\(recovery)")
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func presentResourceIssue(_ issue: DictionaryResourceIssue) {
        phase = .resourceError(issue)
        WKInterfaceDevice.current().play(.failure)
    }

    private func cancelActiveLookup() {
        searchTask?.cancel()
        searchTask = nil
        requestGate.invalidate()
    }

    private func queryDidChange() {
        cancelActiveLookup()
        phase = .idle
        suggestions = []
    }

    private func remember(_ text: String) {
        recentQueries = SearchHistory.remembering(text, in: recentQueries)
        persistHistory()
    }

    private func persistHistory() {
        defaults.set(recentQueries, forKey: Self.historyDefaultsKey)
    }

    private func persistFavorites() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: Self.favoritesDefaultsKey)
    }
}
