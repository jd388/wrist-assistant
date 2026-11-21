import Foundation
import Testing
@testable import DictionaryCore

private let commonWordDictionaryURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("LexiWatchWatchApp/Resources/offline_dictionary.json")

private let commonEnglishWords = [
    "apple", "school", "student", "teacher", "book", "word", "learn", "study",
    "speak", "listen", "read", "write", "give", "take", "make", "do", "go",
    "come", "see", "look", "know", "think", "want", "need", "like", "love",
    "help", "work", "play", "run", "walk", "eat", "drink", "sleep", "live",
    "home", "family", "friend", "people", "person", "child", "boy", "girl",
    "man", "woman", "day", "time", "year", "today", "tomorrow", "yesterday",
    "morning", "night", "good", "bad", "big", "small", "new", "old", "happy",
    "sad", "easy", "difficult", "important", "different", "beautiful",
    "interesting", "because", "before", "after", "with", "without", "in", "on",
    "at", "from", "to", "for", "about", "and", "but", "if", "can", "will",
    "must", "have", "be", "this", "that", "what", "why", "how", "where",
    "when", "who", "which", "one", "two", "first", "last",
]

private let commonChineseCases: [(query: String, accepted: [String])] = [
    ("苹果", ["apple"]), ("学校", ["school"]), ("学生", ["student"]),
    ("老师", ["teacher"]), ("书", ["book"]), ("词", ["word"]),
    ("学习", ["learn", "study"]), ("说", ["say", "speak", "talk"]),
    ("听", ["listen", "hear"]), ("读", ["read"]), ("写", ["write"]),
    ("给", ["give"]), ("拿", ["take", "hold"]), ("做", ["do", "make"]),
    ("去", ["go"]), ("来", ["come"]), ("看", ["see", "look", "look at", "watch"]),
    ("知道", ["know"]), ("想", ["think", "want", "miss"]), ("想要", ["want"]),
    ("需要", ["need"]), ("喜欢", ["like"]), ("爱", ["love"]),
    ("帮助", ["help", "assist", "aid"]), ("工作", ["work", "job"]),
    ("玩", ["play"]), ("跑", ["run"]), ("走", ["walk", "go"]),
    ("吃", ["eat"]), ("喝", ["drink"]), ("睡觉", ["sleep"]),
    ("生活", ["life", "live"]), ("家", ["home", "family", "house"]),
    ("家庭", ["family"]), ("朋友", ["friend"]), ("人们", ["people"]),
    ("人", ["person", "people", "man"]), ("孩子", ["child", "kid"]),
    ("男孩", ["boy"]), ("女孩", ["girl"]), ("男人", ["man"]),
    ("女人", ["woman"]), ("天", ["day", "sky"]), ("时间", ["time"]),
    ("年", ["year"]), ("今天", ["today"]), ("明天", ["tomorrow"]),
    ("昨天", ["yesterday"]), ("早上", ["morning"]),
    ("晚上", ["evening", "night"]), ("好", ["good", "well"]),
    ("坏", ["bad"]), ("大", ["big", "large", "great"]),
    ("小", ["small", "little"]), ("新", ["new"]), ("老", ["old"]),
    ("快乐", ["happy", "joy"]), ("悲伤", ["sad", "sorrow"]),
    ("容易", ["easy"]), ("困难", ["difficult", "difficulty", "hard"]),
    ("重要", ["important"]), ("不同", ["different"]),
    ("美丽", ["beautiful"]), ("有趣", ["interesting", "fun"]),
    ("因为", ["because"]), ("之前", ["before"]), ("之后", ["after"]),
    ("和", ["and", "with"]), ("没有", ["no", "without", "not", "have"]),
    ("在", ["in", "at", "on", "be"]), ("从", ["from"]),
    ("到", ["to", "arrive", "reach"]), ("为了", ["for"]),
    ("关于", ["about", "regarding"]), ("但是", ["but", "however"]), ("如果", ["if"]),
    ("能", ["can", "able"]), ("将", ["will"]), ("必须", ["must"]),
    ("有", ["have"]), ("是", ["be"]), ("这", ["this"]),
    ("那个", ["that"]), ("什么", ["what"]), ("为什么", ["why"]),
    ("怎么", ["how"]), ("哪里", ["where"]), ("什么时候", ["when"]),
    ("谁", ["who"]), ("哪个", ["which"]), ("一", ["one"]),
    ("二", ["two"]), ("第一", ["first"]), ("最后", ["last", "final"]),
    ("水", ["water"]), ("食物", ["food"]), ("房子", ["house", "home"]),
    ("城市", ["city"]), ("国家", ["country"]),
    ("促进", ["stimulate", "promote", "facilitate"]),
]

private let commonEnglishTypos = [
    (query: "appel", correction: "apple"),
    (query: "techer", correction: "teacher"),
    (query: "becuase", correction: "because"),
    (query: "freind", correction: "friend"),
    (query: "schol", correction: "school"),
]

@Test("Bundled dictionary keeps 100 common English and 100 Chinese lookups correct")
func bundledCommonWordRegression() throws {
    #expect(commonEnglishWords.count == 100)
    #expect(commonChineseCases.count == 100)

    let data = try Data(contentsOf: commonWordDictionaryURL)
    let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
    let engine = DictionarySearchEngine(entries: entries)

    for word in commonEnglishWords {
        let actual = engine.search(word).bestMatch?.entry.headword
        let actualDescription = actual ?? "nil"
        #expect(actual == word, "English query \(word) returned \(actualDescription)")
    }

    for item in commonChineseCases {
        let actual = engine.search(item.query).bestMatch?.entry.headword
        let normalizedAccepted = Set(item.accepted.map(DictionarySearchEngine.normalize))
        let accepted = actual.map {
            normalizedAccepted.contains(DictionarySearchEngine.normalize($0))
        } ?? false
        let actualDescription = actual ?? "nil"
        #expect(accepted, "Chinese query \(item.query) returned \(actualDescription)")
    }
}

@Test("Bundled 30k dictionary keeps likely spelling corrections in the first three UI suggestions")
func bundledCommonSpellingCorrectionRegression() throws {
    let data = try Data(contentsOf: commonWordDictionaryURL)
    let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
    #expect(entries.count == 30_000)

    let engine = DictionarySearchEngine(entries: entries)
    for item in commonEnglishTypos {
        let response = engine.search(item.query)
        let visible = UnifiedLookupPolicy.correctionSuggestions(for: response, limit: 3)
            .map(\.entry.headword)
        #expect(
            visible.contains(item.correction),
            "Typo \(item.query) showed \(visible) instead of \(item.correction)"
        )
    }
}

@Test("Outer dictation punctuation preserves visible English and Chinese alternatives")
func bundledPunctuatedSuggestionRegression() throws {
    let data = try Data(contentsOf: commonWordDictionaryURL)
    let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
    let engine = DictionarySearchEngine(entries: entries)

    let english = UnifiedLookupPolicy.correctionSuggestions(for: engine.search("appel."))
        .prefix(3)
        .map(\.entry.headword)
    #expect(english.contains("apple"))

    let chinese = UnifiedLookupPolicy.correctionSuggestions(for: engine.search("促进。"))
        .prefix(2)
        .map(\.entry.headword)
    #expect(Array(chinese) == ["promote", "facilitate"])
}
