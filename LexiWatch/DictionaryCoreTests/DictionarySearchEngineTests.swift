import Foundation
import Testing
@testable import DictionaryCore

@Test("Fast key normalization preserves word boundaries and Unicode input")
func fastKeyNormalizationKeepsLookupSemantics() {
    for (input, expected) in [
        ("School", "school"), ("学校", "学校"), ("学 校。", "学校"),
        ("ＴＡＫＥ－ＯＦＦ", "take off"), ("takeoff", "takeoff"),
        ("act on", "act on"), ("Acton", "acton"),
        ("café", "cafe"), ("CAFE\u{301}", "cafe"),
        ("don't", "don't"), (" APPLE. ", "apple"), ("", "")
    ] {
        #expect(DictionarySearchEngine.normalize(input) == expected)
    }
}

private let fixtures = [
    DictionaryEntry(
        id: "apple",
        headword: "apple",
        pronunciation: "/ˈæp.əl/",
        aliases: ["apples"],
        keywords: ["苹果"],
        meanings: [
            .init(partOfSpeech: "n.", chinese: "苹果", example: "I ate an apple.", exampleChinese: "我吃了一个苹果。")
        ]
    ),
    DictionaryEntry(
        id: "study",
        headword: "study",
        aliases: ["studies", "studied", "studying"],
        keywords: ["学习", "研究"],
        meanings: [
            .init(partOfSpeech: "v.", chinese: "学习；研究")
        ]
    ),
    DictionaryEntry(
        id: "school",
        headword: "school",
        keywords: ["学校", "学派", "鱼群"],
        meanings: [
            .init(partOfSpeech: "n.", chinese: "学校；学派；鱼群")
        ]
    ),
    DictionaryEntry(
        id: "hello",
        headword: "hello",
        aliases: ["你好", "您好", "哈喽"],
        keywords: ["喂", "嘿"],
        meanings: [
            .init(partOfSpeech: "interj.", chinese: "喂；嘿")
        ]
    ),
    DictionaryEntry(
        id: "gig",
        headword: "gig",
        keywords: ["叉鱼", "刺激", "记过"],
        meanings: [
            .init(partOfSpeech: "v.", chinese: "叉鱼；刺激；记过")
        ],
        priority: 28_000
    ),
    DictionaryEntry(
        id: "stimulate",
        headword: "stimulate",
        aliases: ["刺激"],
        keywords: ["刺激", "激励", "促进"],
        meanings: [
            .init(
                partOfSpeech: "v.",
                chinese: "刺激；激励；促进",
                collocations: ["stimulate growth 促进增长"],
                example: "Light stimulates plant growth.",
                exampleChinese: "光会促进植物生长。"
            )
        ],
        priority: 2_000
    ),
    DictionaryEntry(
        id: "give",
        headword: "give",
        aliases: ["gave", "given", "giving"],
        keywords: ["给", "给予"],
        meanings: [
            .init(partOfSpeech: "v.", chinese: "给；给予")
        ],
        relatedExpressions: [
            .init(text: "give up", kind: .phrasalVerb, chinese: "放弃；认输", priority: 0),
            .init(text: "give in", kind: .phrasalVerb, chinese: "屈服；让步", priority: 1),
            .init(text: "give sth to sb", kind: .verbPattern, chinese: "把某物给某人", priority: 0)
        ],
        priority: 100
    )
]

@Test("Favorite snapshot round-trips without retaining a full entry")
func favoriteWordCodableRoundTrip() throws {
    let source = FavoriteWord(entry: fixtures[0])
    let data = try JSONEncoder().encode(source)
    let decoded = try JSONDecoder().decode(FavoriteWord.self, from: data)

    #expect(decoded == source)
    #expect(decoded.id == "apple")
    #expect(decoded.headword == "apple")
    #expect(decoded.pronunciation == "/ˈæp.əl/")
    #expect(decoded.conciseChinese == "苹果")
}

@Test("Favorite snapshots keep newest order and remove duplicate entries")
func favoriteWordDeduplication() {
    let oldApple = FavoriteWord(
        id: "apple",
        headword: "apple",
        pronunciation: nil,
        conciseChinese: "旧释义"
    )
    let study = FavoriteWord(entry: fixtures[1])
    let latestApple = FavoriteWord(entry: fixtures[0])

    let result = FavoriteWord.deduplicatingMostRecent([
        latestApple,
        study,
        oldApple
    ])

    #expect(result.map(\.id) == ["apple", "study"])
    #expect(result.first?.conciseChinese == "苹果")
}

@Test("Bundled dictionary decoding removes observed square and legacy source artifacts")
func bundledDictionaryTextSanitization() throws {
    let resourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LexiWatchWatchApp/Resources/offline_dictionary.json")
    let entries = try JSONDecoder().decode(
        [DictionaryEntry].self,
        from: Data(contentsOf: resourceURL)
    )

    let abstract = try #require(entries.first { $0.headword == "abstract" })
    #expect(!abstract.meanings[0].chinese.contains("■"))
    #expect(abstract.meanings[0].partOfSpeech == "adj.")
    let abstractNoun = try #require(abstract.meanings.first {
        $0.partOfSpeech == "n."
    })
    #expect(abstractNoun.chinese.contains("抽象概念"))

    let cluttered = try #require(entries.first { $0.headword == "cluttered" })
    #expect(!cluttered.meanings[0].chinese.contains("<X>"))
    #expect(!cluttered.meanings[0].chinese.contains("<DDX>"))
    #expect(cluttered.meanings[0].chinese.contains("乱糟糟地堆满"))

    let periphrastic = try #require(entries.first { $0.headword == "periphrastic" })
    #expect(!periphrastic.meanings[0].chinese.unicodeScalars.contains {
        $0.properties.generalCategory == .privateUse
    })
    #expect(periphrastic.meanings[0].chinese.contains("委婉的"))
    #expect(periphrastic.meanings[0].chinese.contains("冗长的"))

    let engel = try #require(entries.first { $0.headword == "engel" })
    #expect(!engel.meanings[0].chinese.contains("\t"))

    let melanoma = try #require(entries.first { $0.headword == "melanoma" })
    #expect(!melanoma.meanings[0].chinese.contains("│"))
}

@Test("Dictionary text cleaning preserves valid IPA CJK punctuation and source labels")
func dictionaryTextSanitizerPreservesLegitimateText() {
    let valid = "<英> /ˌɪntəˈnæʃənəl/；中文、繁體（θ、ð、ʃ、ʒ、ŋ、ɜː）→ 学习"
    #expect(DictionaryTextSanitizer.sanitize(valid) == valid)
}

@Test("Dictionary text cleaning handles future unsupported markers without losing content")
func dictionaryTextSanitizerHandlesUnsupportedMarkers() {
    let contaminated = "释义■ n. 零乱<X>零乱<DDX>vt. &amp; [医] \u{E7AB}嗦\t│尾部�"
    let cleaned = DictionaryTextSanitizer.sanitize(contaminated)

    #expect(!cleaned.contains("■"))
    #expect(!cleaned.contains("<X>"))
    #expect(!cleaned.contains("<DDX>"))
    #expect(!cleaned.contains("│"))
    #expect(!cleaned.contains("�"))
    #expect(!cleaned.unicodeScalars.contains {
        $0.properties.generalCategory == .privateUse
    })
    #expect(cleaned.contains("释义"))
    #expect(cleaned.contains("零乱"))
    #expect(cleaned.contains("尾部"))
    #expect(cleaned.contains("&"))
}

@Test("English headword finds an exact offline entry")
func exactEnglishLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search(" Apple ")
    #expect(result.bestMatch?.entry.id == "apple")
    #expect(result.bestMatch?.kind == .exactHeadword)
}

@Test("An English headword always outranks the same spelling stored as an alias")
func exactEnglishHeadwordOutranksAlias() {
    let frequentBaseWord = DictionaryEntry(
        id: "mean",
        headword: "mean",
        aliases: ["meaning"],
        keywords: ["意思"],
        meanings: [.init(partOfSpeech: "v.", chinese: "意思是")],
        priority: 1
    )
    let rareExactWord = DictionaryEntry(
        id: "meaning",
        headword: "meaning",
        keywords: ["含义"],
        meanings: [.init(partOfSpeech: "n.", chinese: "含义")],
        priority: 30_000
    )

    let result = DictionarySearchEngine(entries: [frequentBaseWord, rareExactWord])
        .search("meaning")
    #expect(result.bestMatch?.entry.headword == "meaning")
    #expect(result.bestMatch?.kind == .exactHeadword)
}

@Test("Chinese meaning performs reverse lookup")
func chineseReverseLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search("苹果")
    #expect(result.bestMatch?.entry.headword == "apple")
    #expect(result.bestMatch?.kind == .exactMeaning)
}

@Test("A complete gloss hides unrelated exact keyword fragments")
func completeGlossFiltersWeakKeywordExactMatches() {
    let direct = DictionaryEntry(
        id: "learn",
        headword: "learn",
        meanings: [.init(partOfSpeech: "v.", chinese: "学习")],
        priority: 20_000
    )
    let fragment = DictionaryEntry(
        id: "pattern",
        headword: "pattern",
        keywords: ["学习"],
        meanings: [.init(partOfSpeech: "n.", chinese: "模式；图案")],
        priority: 1
    )

    let result = DictionarySearchEngine(entries: [fragment, direct]).search("学习")
    #expect(result.bestMatch?.entry.headword == "learn")
    #expect(!result.exactMatches.contains { $0.entry.headword == "pattern" })
}

@Test("A keyword-only Chinese lookup remains an offline dictionary result")
func keywordOnlyChineseLookupRemainsExact() {
    let rare = DictionaryEntry(
        id: "rare",
        headword: "rare",
        keywords: ["罕见译法"],
        meanings: [.init(partOfSpeech: "adj.", chinese: "稀有的")]
    )

    let result = DictionarySearchEngine(entries: [rare]).search("罕见译法")
    #expect(result.bestMatch?.entry.headword == "rare")
    #expect(result.bestMatch?.kind == .exactMeaning)
    #expect(UnifiedLookupPolicy.route(for: result) == .dictionary)
}

@Test("Chinese phrase inside a longer meaning is a direct local result")
func chineseContainedMeaningLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search("学校")
    #expect(result.bestMatch?.entry.headword == "school")
    #expect(result.bestMatch?.kind == .exactMeaning)
}

@Test("A direct Chinese gloss outranks exact and partial expression translations")
func directChineseGlossOutranksExpressions() {
    let directGloss = DictionaryEntry(
        id: "school",
        headword: "school",
        keywords: ["学校"],
        meanings: [.init(partOfSpeech: "n.", chinese: "学校")],
        priority: 30_000
    )
    let exactExpression = DictionaryEntry(
        id: "campus-label",
        headword: "campus label",
        meanings: [.init(partOfSpeech: "n.", chinese: "校园称呼")],
        relatedExpressions: [
            .init(text: "campus label", kind: .verbPattern, chinese: "学校", priority: 0)
        ],
        priority: 1
    )
    let partialExpression = DictionaryEntry(
        id: "eat",
        headword: "eat",
        meanings: [.init(partOfSpeech: "v.", chinese: "吃")],
        relatedExpressions: [
            .init(text: "eat at school", kind: .verbPattern, chinese: "在学校就餐", priority: 0)
        ],
        priority: 1
    )

    let result = DictionarySearchEngine(entries: [partialExpression, exactExpression, directGloss])
        .search("学校")
    #expect(result.bestMatch?.entry.headword == "school")
    #expect(result.exactMatches.contains {
        $0.entry.id == "campus-label" && $0.kind == .exactMeaning
    })
    #expect(!result.exactMatches.contains { $0.entry.id == "eat" })
    #expect(result.suggestions.contains {
        $0.entry.id == "eat" && $0.kind == .contains
    })
}

@Test("Single Chinese characters only match direct glosses, not arbitrary substrings")
func singleChineseCharacterDisablesSubstringRecovery() {
    let book = DictionaryEntry(
        id: "book",
        headword: "book",
        keywords: ["书"],
        meanings: [.init(partOfSpeech: "n.", chinese: "书")]
    )
    let writtenExpression = DictionaryEntry(
        id: "written-expression",
        headword: "written expression",
        keywords: ["书面表达"],
        meanings: [.init(partOfSpeech: "n.", chinese: "书面表达")],
        relatedExpressions: [
            .init(text: "written expression", kind: .verbPattern, chinese: "全国书面表达", priority: 0)
        ]
    )
    let big = DictionaryEntry(
        id: "big",
        headword: "big",
        keywords: ["大的"],
        meanings: [.init(partOfSpeech: "adj.", chinese: "大的")]
    )
    let approximately = DictionaryEntry(
        id: "approximately",
        headword: "approximately",
        keywords: ["大约"],
        meanings: [.init(partOfSpeech: "adv.", chinese: "大约")]
    )
    let engine = DictionarySearchEngine(
        entries: [writtenExpression, approximately, book, big]
    )

    let bookResult = engine.search("书")
    #expect(bookResult.bestMatch?.entry.headword == "book")
    #expect(bookResult.bestMatch?.kind == .exactMeaning)
    #expect(!bookResult.exactMatches.contains { $0.entry.id == "written-expression" })
    #expect(!bookResult.suggestions.contains { $0.entry.id == "written-expression" })

    let bigResult = engine.search("大")
    #expect(bigResult.bestMatch?.entry.headword == "big")
    #expect(bigResult.bestMatch?.kind == .exactMeaning)
    #expect(!bigResult.exactMatches.contains { $0.entry.id == "approximately" })
    #expect(!bigResult.suggestions.contains { $0.entry.id == "approximately" })
}

@Test("Curated Chinese aliases cover natural greeting queries")
func chineseAliasLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search("你好")
    #expect(result.bestMatch?.entry.headword == "hello")
    #expect(result.bestMatch?.kind == .exactHeadword)
}

@Test("Common high-school word outranks a rare short word for Chinese lookup")
func frequencyRankingForChineseLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search("刺激")
    #expect(result.bestMatch?.entry.headword == "stimulate")
}

@Test("Bundled dictionary returns the expected headword and gloss for a Chinese query")
func bundledDictionaryIntegration() throws {
    let resourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LexiWatchWatchApp/Resources/offline_dictionary.json")
    let entries = try JSONDecoder().decode(
        [DictionaryEntry].self,
        from: Data(contentsOf: resourceURL)
    )
    let result = DictionarySearchEngine(entries: entries).search("刺激")
    #expect(result.bestMatch?.entry.headword == "stimulate")
    #expect(result.bestMatch?.entry.meanings.contains { $0.chinese.contains("刺激") } == true)
}

@Test("Bundled Chinese reverse lookup prefers stimulate for 促进 and keeps common alternatives")
func bundledPromotionRanking() throws {
    let resourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LexiWatchWatchApp/Resources/offline_dictionary.json")
    let entries = try JSONDecoder().decode(
        [DictionaryEntry].self,
        from: Data(contentsOf: resourceURL)
    )

    let response = DictionarySearchEngine(entries: entries).search("促进")
    #expect(response.bestMatch?.entry.headword == "stimulate")
    #expect(Array(response.exactMatches.prefix(3).map(\.entry.headword)) == [
        "stimulate", "promote", "facilitate"
    ])
    #expect(Array(
        UnifiedLookupPolicy.correctionSuggestions(for: response).prefix(2).map(\.entry.headword)
    ) == ["promote", "facilitate"])
}

@Test("Bundled headword and Chinese reverse-lookup ranking regressions")
func bundledSearchRankingRegressions() throws {
    let resourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LexiWatchWatchApp/Resources/offline_dictionary.json")
    let entries = try JSONDecoder().decode(
        [DictionaryEntry].self,
        from: Data(contentsOf: resourceURL)
    )
    let engine = DictionarySearchEngine(entries: entries)

    let expectedTopResults = [
        (query: "meaning", headword: "meaning"),
        (query: "interested", headword: "interested"),
        (query: "surprised", headword: "surprised"),
        (query: "学校", headword: "school"),
        (query: "学习", headword: "learn"),
        (query: "书", headword: "book"),
        (query: "大", headword: "big"),
        (query: "悲伤", headword: "sad"),
        (query: "玩", headword: "play"),
        (query: "睡觉", headword: "sleep"),
        (query: "将", headword: "will"),
        (query: "是", headword: "be"),
        (query: "促进", headword: "stimulate"),
        (query: "刺激", headword: "stimulate")
    ]

    for expectation in expectedTopResults {
        let result = engine.search(expectation.query)
        #expect(result.bestMatch?.entry.headword == expectation.headword)
        #expect(result.bestMatch?.kind.isExact == true)
    }

    let study = engine.search("学习")
    #expect(!study.exactMatches.contains { ["pattern", "prefer"].contains($0.entry.headword) })

    let school = engine.search("学校")
    #expect(!school.exactMatches.contains { ["eat", "bunk"].contains($0.entry.headword) })

    let book = engine.search("书")
    #expect(!(book.exactMatches + book.suggestions).contains {
        ["find", "make"].contains($0.entry.headword)
    })

    let big = engine.search("大")
    #expect(!(big.exactMatches + big.suggestions).contains {
        ["say", "call"].contains($0.entry.headword)
    })
}

@Test("Primary Chinese gloss outranks a more frequent secondary sense")
func primaryChineseSenseRanking() {
    let frequentSecondary = DictionaryEntry(
        id: "secondary",
        headword: "secondary",
        keywords: ["其他", "促进"],
        meanings: [.init(partOfSpeech: "adj.", chinese: "其他；促进")],
        priority: 1
    )
    let lessFrequentPrimary = DictionaryEntry(
        id: "primary",
        headword: "primary",
        keywords: ["促进"],
        meanings: [.init(partOfSpeech: "v.", chinese: "促进")],
        priority: 30_000
    )

    let result = DictionarySearchEngine(entries: [frequentSecondary, lessFrequentPrimary])
        .search("促进")
    #expect(result.bestMatch?.entry.headword == "primary")
}

@Test("A complete gloss outranks a keyword fragment extracted from a phrase")
func completeChineseGlossOutranksPhraseFragment() {
    let give = DictionaryEntry(
        id: "give",
        headword: "give",
        keywords: ["给", "给予"],
        meanings: [.init(partOfSpeech: "v.", chinese: "给；给予")],
        priority: 100
    )
    let show = DictionaryEntry(
        id: "show",
        headword: "show",
        keywords: ["给", "看"],
        meanings: [.init(partOfSpeech: "v.", chinese: "给……看；出示")],
        priority: 1
    )

    let result = DictionarySearchEngine(entries: [show, give]).search("给")
    #expect(result.bestMatch?.entry.headword == "give")
}

@Test("A normalized colloquial Chinese query can match a complete formal gloss")
func equivalentChineseGlossLookup() {
    let which = DictionaryEntry(
        id: "which",
        headword: "which",
        meanings: [.init(partOfSpeech: "pron.", chinese: "哪一个；哪一些")],
        priority: 100
    )

    let result = DictionarySearchEngine(entries: [which]).search("哪个")
    #expect(result.bestMatch?.entry.headword == "which")
}

@Test("Bundled give entry includes useful phrasal verbs before generic collocations")
func bundledGivePhrasalVerbs() throws {
    let resourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LexiWatchWatchApp/Resources/offline_dictionary.json")
    let entries = try JSONDecoder().decode(
        [DictionaryEntry].self,
        from: Data(contentsOf: resourceURL)
    )
    let expressions = try #require(
        DictionarySearchEngine(entries: entries).search("give").bestMatch?.entry.relatedExpressions
    )
    let phrasalVerbs = expressions.filter { $0.kind == .phrasalVerb }.map(\.text)
    #expect(Array(phrasalVerbs.prefix(3)) == ["give up", "give in", "give away"])
    #expect(expressions.contains {
        $0.kind == .verbPattern && $0.text == "give sb sth / give sth to sb"
    })
    #expect(expressions.contains {
        $0.kind == .verbPattern && $0.text == "give up doing sth"
    })
    #expect(expressions.first?.text == "give up")
    #expect(expressions.first?.chinese.contains("放弃") == true)
}

@Test("Inflection aliases return the base word")
func inflectionLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search("studied")
    #expect(result.bestMatch?.entry.headword == "study")
}

@Test("Phrasal verb is searchable even when stored under its base verb")
func phrasalVerbLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search("give up")
    #expect(result.bestMatch?.entry.headword == "give")
    #expect(result.bestMatch?.kind == .exactExpression)
}

@Test("English normalization preserves phrase boundaries without changing Chinese cleanup")
func strictEnglishNormalization() {
    #expect(DictionarySearchEngine.normalize("hello.") == "hello")
    #expect(DictionarySearchEngine.normalize("hello!") == "hello")
    #expect(DictionarySearchEngine.normalize("(hello)") == "hello")
    #expect(DictionarySearchEngine.normalize("hello,") == "hello")
    #expect(DictionarySearchEngine.normalize("I love you.") == "i love you.")
    #expect(DictionarySearchEngine.normalize(" take  off ") == "take off")
    #expect(DictionarySearchEngine.normalize("take-off") == "take off")
    #expect(DictionarySearchEngine.normalize("take‑off") == "take off")
    #expect(DictionarySearchEngine.normalize("takeoff") == "takeoff")
    #expect(DictionarySearchEngine.normalize("act on") == "act on")
    #expect(DictionarySearchEngine.normalize("Acton") == "acton")
    #expect(DictionarySearchEngine.normalize(" 学 校。") == "学校")
}

@Test("Outer dictation punctuation still finds a single English word")
func punctuatedEnglishWordLookup() {
    let engine = DictionarySearchEngine(entries: fixtures)

    for query in ["hello.", "hello!", "(hello)", "hello,"] {
        let result = engine.search(query)
        #expect(result.bestMatch?.entry.headword == "hello", "Query \(query) missed hello")
        #expect(result.bestMatch?.kind == .exactHeadword)
        #expect(UnifiedLookupPolicy.route(for: result) == .dictionary)
    }

    #expect(UnifiedLookupPolicy.route(for: engine.search("I study at school.")) == .translation)
}

@Test("Phrasal verbs and closed compounds keep distinct exact lookup keys")
func phraseBoundaryCollisionLookup() {
    let take = DictionaryEntry(
        id: "take",
        headword: "take",
        meanings: [.init(partOfSpeech: "v.", chinese: "拿；取")],
        relatedExpressions: [
            .init(text: "take off", kind: .phrasalVerb, chinese: "起飞；脱下", priority: 0)
        ],
        priority: 30_000
    )
    let takeoff = DictionaryEntry(
        id: "takeoff",
        headword: "takeoff",
        meanings: [.init(partOfSpeech: "n.", chinese: "起飞")],
        priority: 1
    )
    let act = DictionaryEntry(
        id: "act",
        headword: "act",
        meanings: [.init(partOfSpeech: "v.", chinese: "行动")],
        relatedExpressions: [
            .init(text: "act on", kind: .phrasalVerb, chinese: "按照……行事", priority: 0)
        ],
        priority: 30_000
    )
    let acton = DictionaryEntry(
        id: "acton",
        headword: "Acton",
        meanings: [.init(partOfSpeech: "n.", chinese: "阿克顿")],
        priority: 1
    )
    let engine = DictionarySearchEngine(entries: [takeoff, take, acton, act])

    for query in ["take off", "take-off"] {
        let result = engine.search(query)
        #expect(result.bestMatch?.entry.id == "take")
        #expect(result.bestMatch?.kind == .exactExpression)
    }

    let closedCompound = engine.search("takeoff")
    #expect(closedCompound.bestMatch?.entry.id == "takeoff")
    #expect(closedCompound.bestMatch?.kind == .exactHeadword)

    let phrasalVerb = engine.search("act on")
    #expect(phrasalVerb.bestMatch?.entry.id == "act")
    #expect(phrasalVerb.bestMatch?.kind == .exactExpression)

    let properName = engine.search("Acton")
    #expect(properName.bestMatch?.entry.id == "acton")
    #expect(properName.bestMatch?.kind == .exactHeadword)
}

@Test("Base verb keeps distinct phrasal verbs and grammar patterns")
func structuredVerbUsage() {
    let result = DictionarySearchEngine(entries: fixtures).search("give")
    let expressions = result.bestMatch?.entry.relatedExpressions ?? []
    #expect(expressions.first?.text == "give up")
    #expect(expressions.contains { $0.kind == .phrasalVerb && $0.text == "give up" })
    #expect(expressions.contains { $0.kind == .verbPattern && $0.text == "give sth to sb" })
}

@Test("A small recognition typo produces a correction candidate")
func fuzzyLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search("appel")
    #expect(result.bestMatch == nil)
    #expect(result.suggestions.first?.entry.headword == "apple")
}

@Test("Bounded spelling distance keeps swaps and rejects over-budget candidates")
func boundedSpellingDistance() {
    func units(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    #expect(DictionarySearchEngine.boundedCorrectionDistance(
        units("appel"), units("apple"), maximumDistance: 1
    ) == 1)
    #expect(DictionarySearchEngine.boundedCorrectionDistance(
        units("techer"), units("teacher"), maximumDistance: 1
    ) == 1)
    #expect(DictionarySearchEngine.boundedCorrectionDistance(
        units("kitten"), units("sitting"), maximumDistance: 2
    ) == nil)
    #expect(DictionarySearchEngine.boundedCorrectionDistance(
        units("kitten"), units("sitting"), maximumDistance: 3
    ) == 3)
    #expect(DictionarySearchEngine.boundedCorrectionDistance(
        units("ab"), units("ba"), maximumDistance: 1
    ) == 1)
}

@Test("A cancelled search cooperatively returns no publishable result")
func cancelledSearchStopsCooperatively() async {
    let engine = DictionarySearchEngine(entries: fixtures)
    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return engine.search("apple")
    }
    task.cancel()

    let response = await task.value
    #expect(response.query == "apple")
    #expect(response.normalizedQuery == "apple")
    #expect(response.exactMatches.isEmpty)
    #expect(response.suggestions.isEmpty)
}

@Test("Punctuation and spaces do not cause false misses")
func normalizedLookup() {
    let result = DictionarySearchEngine(entries: fixtures).search(" 学 校。")
    #expect(result.bestMatch?.entry.headword == "school")
}

@Test("Unknown input preserves the original query")
func unknownPreservesQuery() {
    let result = DictionarySearchEngine(entries: fixtures).search("不在词库")
    #expect(result.query == "不在词库")
    #expect(result.exactMatches.isEmpty)
}

@Test("Unified entry keeps exact words and phrases in the learning dictionary")
func unifiedEntryUsesDictionaryForExactLexicalInput() {
    let engine = DictionarySearchEngine(entries: fixtures)
    #expect(UnifiedLookupPolicy.route(for: engine.search("hello")) == .dictionary)
    #expect(UnifiedLookupPolicy.route(for: engine.search("give up")) == .dictionary)
    #expect(UnifiedLookupPolicy.route(for: engine.search("刺激")) == .dictionary)
}

@Test("Unified entry sends sentences and unknown words to local translation")
func unifiedEntryFallsBackToTranslation() {
    let engine = DictionarySearchEngine(entries: fixtures)
    #expect(UnifiedLookupPolicy.route(for: engine.search("I love you.")) == .translation)
    #expect(UnifiedLookupPolicy.route(for: engine.search("我把作业忘在教室了。")) == .translation)
    #expect(UnifiedLookupPolicy.route(for: engine.search("unlistedword")) == .translation)
}

@Test("Spelling suggestions never block sentence translation")
func unifiedSuggestionsOnlyAppearForCompactInputs() {
    let engine = DictionarySearchEngine(entries: fixtures)
    let typo = engine.search("appel")
    let punctuatedTypo = engine.search("appel.")
    let sentence = engine.search("I study at school")
    let internallyTerminated = engine.search("app.el")

    #expect(UnifiedLookupPolicy.route(for: typo) == .translation)
    #expect(UnifiedLookupPolicy.correctionSuggestions(for: typo).first?.entry.headword == "apple")
    #expect(UnifiedLookupPolicy.correctionSuggestions(for: punctuatedTypo).first?.entry.headword == "apple")
    #expect(UnifiedLookupPolicy.route(for: sentence) == .translation)
    #expect(UnifiedLookupPolicy.correctionSuggestions(for: sentence).isEmpty)
    #expect(UnifiedLookupPolicy.correctionSuggestions(for: internallyTerminated).isEmpty)
    #expect(UnifiedLookupPolicy.isCompactLexicalInput("appel."))
    #expect(!UnifiedLookupPolicy.isCompactLexicalInput("app.el"))
    #expect(!UnifiedLookupPolicy.isCompactLexicalInput("I study."))
}
