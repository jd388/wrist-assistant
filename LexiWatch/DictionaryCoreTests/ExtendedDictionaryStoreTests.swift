import Foundation
import Testing
@preconcurrency import SQLite3
@testable import DictionaryCore

private let extendedDatabaseURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(
        "LexiWatchWatchApp/Resources/offline_dictionary_extended.sqlite"
    )

@Test("Extended dictionary finds an exact rare headword without loading the core JSON")
func extendedExactEnglishLookup() async throws {
    let store = ExtendedDictionaryStore(databaseURL: extendedDatabaseURL)
    #expect(await store.availability() == .available)
    let result = try await store.search("aardvark")
    let match = try #require(result.bestMatch)

    #expect(match.entry.headword == "aardvark")
    #expect(match.entry.meanings.first?.chinese == "土豚")
    #expect(match.kind == .exactHeadword)
}

@Test("Extended dictionary tolerates punctuation around one English token")
func extendedSingleTokenPunctuationLookup() async throws {
    let store = ExtendedDictionaryStore(databaseURL: extendedDatabaseURL)

    for query in ["aardvark.", "(aardvark)", "“aardvark”"] {
        let result = try await store.search(query)
        #expect(result.bestMatch?.entry.headword == "aardvark")
    }
}

@Test("Oxford-style exact expressions survive outer punctuation from dictation")
func extendedPhrasePunctuationLookup() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let entry = DictionaryEntry(
        id: "test:at some point",
        headword: "at some point",
        meanings: [.init(partOfSpeech: "phrase", chinese: "某个时候")]
    )
    try createValidSQLite(at: url, headword: entry.headword, payload: JSONEncoder().encode(entry))
    let store = ExtendedDictionaryStore(databaseURL: url)

    for query in ["at some point", "At some point.", "“At some point.”", "At some point，", "At some point。"] {
        let result = try await store.search(query, suggestionLimit: 0)
        #expect(result.bestMatch?.entry == entry, "Query: \(query)")
    }
    let sentence = try await store.search("It happened at some point.", suggestionLimit: 0)
    #expect(sentence.bestMatch == nil)
}

@Test("Extended dictionary resolves an ESDB inflection to its lemma")
func extendedInflectionLookup() async throws {
    let store = ExtendedDictionaryStore(databaseURL: extendedDatabaseURL)
    let result = try await store.search("aardvarks")
    let match = try #require(result.bestMatch)

    #expect(match.entry.headword == "aardvark")
    #expect(match.kind == .exactHeadword)
}

@Test("A standalone extended headword outranks the same spelling as a core inflection")
func extendedHeadwordOutranksCoreInflection() async throws {
    let coreEngine = DictionarySearchEngine(entries: [
        DictionaryEntry(
            id: "acoustic",
            headword: "acoustic",
            aliases: ["acoustics"],
            meanings: [.init(partOfSpeech: "adj.", chinese: "声学的")]
        )
    ])
    let core = coreEngine.search("acoustics")
    #expect(core.bestMatch?.entry.headword == "acoustic")
    #expect(UnifiedLookupPolicy.shouldConsultExtendedDictionary(after: core))

    let store = ExtendedDictionaryStore(databaseURL: extendedDatabaseURL)
    let extended = try await store.search("acoustics")
    let selected = try #require(
        UnifiedLookupPolicy.preferredDictionaryMatch(core: core, extended: extended)
    )

    #expect(selected.entry.headword == "acoustics")
    #expect(selected.entry.meanings.first?.chinese.contains("声学") == true)
}

@Test("A real core headword does not open the extended dictionary")
func directCoreHeadwordKeepsFastPath() {
    let coreEngine = DictionarySearchEngine(entries: [
        DictionaryEntry(
            id: "hello",
            headword: "hello",
            meanings: [.init(partOfSpeech: "interj.", chinese: "你好")]
        )
    ])
    let core = coreEngine.search("hello")

    #expect(!UnifiedLookupPolicy.shouldConsultExtendedDictionary(after: core))
}

@Test("Extended dictionary supports an indexed Chinese reverse lookup")
func extendedChineseReverseLookup() async throws {
    let store = ExtendedDictionaryStore(databaseURL: extendedDatabaseURL)
    let result = try await store.search("土豚")
    let match = try #require(result.bestMatch)

    #expect(match.entry.headword == "aardvark")
    #expect(match.kind == .exactMeaning)
}

@Test("Extended dictionary keeps phrase and joined-word keys distinct")
func extendedStrictBoundaryLookup() async throws {
    let store = ExtendedDictionaryStore(databaseURL: extendedDatabaseURL)
    let phrase = try await store.search("act on")
    let joined = try await store.search("Acton")
    let hyphenated = try await store.search("buy-in")
    let spaced = try await store.search("buy in")
    let tolerant = try await store.search("lip read")

    #expect(phrase.normalizedQuery == "act on")
    #expect(joined.normalizedQuery == "acton")
    #expect(hyphenated.bestMatch?.entry.headword == "buy-in")
    #expect(spaced.bestMatch?.entry.headword == "buy in")
    #expect(tolerant.bestMatch?.entry.headword == "lip-read")
}

@Test("Missing extended database throws a diagnosable resource error")
func missingExtendedDatabaseIsDiagnosable() async {
    let store = ExtendedDictionaryStore(databaseURL: nil)
    #expect(await store.availability() == .missing)
    await expectSearchError(
        .unavailable(.missing),
        from: store,
        query: "aardvark"
    )
}

@Test("Invalid extended database throws a diagnosable resource error")
func invalidExtendedDatabaseIsDiagnosable() async throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    try Data("not a sqlite database".utf8).write(to: temporaryURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let store = ExtendedDictionaryStore(databaseURL: temporaryURL)
    #expect(await store.availability() == .openFailed)
    await expectSearchError(
        .unavailable(.openFailed),
        from: store,
        query: "aardvark"
    )
}

@Test("Old extended schema is reported separately from a normal miss")
func invalidExtendedSchemaIsDiagnosable() async throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try createSQLite(at: temporaryURL, userVersion: 1, includeTables: false)

    let store = ExtendedDictionaryStore(databaseURL: temporaryURL)
    #expect(
        await store.availability()
            == .invalidSchema(expected: 2, actual: 1)
    )
}

@Test("Schema version without required tables is reported as open failure")
func missingExtendedTablesAreDiagnosable() async throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try createSQLite(at: temporaryURL, userVersion: 2, includeTables: false)

    let store = ExtendedDictionaryStore(databaseURL: temporaryURL)
    #expect(await store.availability() == .openFailed)
}

@Test("Schema v2 table names with missing required columns fail validation")
func missingExtendedColumnsAreDiagnosable() async throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try createSQLite(at: temporaryURL, userVersion: 2, includeTables: true)

    let store = ExtendedDictionaryStore(databaseURL: temporaryURL)
    #expect(await store.availability() == .openFailed)
    await expectSearchError(
        .unavailable(.openFailed),
        from: store,
        query: "aardvark"
    )
}

@Test("A healthy extended database miss stays distinct from a resource failure")
func healthyExtendedMissReturnsAnEmptyResponse() async throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try createValidSQLite(at: temporaryURL)

    let store = ExtendedDictionaryStore(databaseURL: temporaryURL)
    #expect(await store.availability() == .available)
    let result = try await store.search("not-present")

    #expect(!result.hasExactMatch)
    #expect(result.suggestions.isEmpty)
    #expect(await store.availability() == .available)
}

@Test("Corrupt entry payload throws and marks the database unavailable")
func corruptExtendedPayloadIsDiagnosable() async throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try createValidSQLite(
        at: temporaryURL,
        headword: "broken",
        payload: Data("not valid JSON".utf8)
    )

    let store = ExtendedDictionaryStore(databaseURL: temporaryURL)
    #expect(await store.availability() == .available)
    await expectSearchError(.invalidPayload, from: store, query: "broken")
    #expect(await store.availability() == .openFailed)
}

@Test("A runtime SQL prepare failure throws and marks the database unavailable")
func runtimePrepareFailureIsDiagnosable() async throws {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try createValidSQLite(at: temporaryURL)

    let store = ExtendedDictionaryStore(databaseURL: temporaryURL)
    #expect(await store.availability() == .available)
    try executeSQLite("DROP TABLE lookups", at: temporaryURL)

    await expectSearchError(.queryFailed, from: store, query: "aardvark")
    #expect(await store.availability() == .openFailed)
}

private func expectSearchError(
    _ expected: ExtendedDictionaryStoreError,
    from store: ExtendedDictionaryStore,
    query: String
) async {
    do {
        _ = try await store.search(query)
        Issue.record("Expected extended dictionary search to throw \(expected)")
    } catch let error as ExtendedDictionaryStoreError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func createSQLite(
    at url: URL,
    userVersion: Int,
    includeTables: Bool
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK,
          let database else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close_v2(database) }

    var error: UnsafeMutablePointer<CChar>?
    let tables = includeTables
        ? "CREATE TABLE entries(entry_id INTEGER);"
            + "CREATE TABLE lookups(entry_id INTEGER);"
            + "CREATE TABLE metadata(key TEXT);"
        : ""
    let sql = "PRAGMA user_version = \(userVersion);\(tables)"
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        if let error { sqlite3_free(error) }
        throw CocoaError(.fileWriteUnknown)
    }
}

private func createValidSQLite(
    at url: URL,
    headword: String? = nil,
    payload: Data? = nil
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK,
          let database else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close_v2(database) }

    try executeSQLite(
        """
        PRAGMA user_version = 2;
        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE entries (
            entry_id INTEGER PRIMARY KEY,
            headword TEXT NOT NULL COLLATE BINARY UNIQUE,
            normalized_headword TEXT NOT NULL,
            priority INTEGER NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE lookups (
            lookup_key TEXT NOT NULL,
            entry_id INTEGER NOT NULL,
            kind INTEGER NOT NULL,
            rank INTEGER NOT NULL,
            PRIMARY KEY (lookup_key, entry_id, kind)
        ) WITHOUT ROWID;
        """,
        database: database
    )

    guard let headword, let payload else { return }
    var statement: OpaquePointer?
    let insert = """
        INSERT INTO entries(
            entry_id, headword, normalized_headword, priority, payload
        ) VALUES (1, ?, ?, 30000, ?)
        """
    guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let headwordResult = headword.withCString {
        sqlite3_bind_text(statement, 1, $0, -1, transient)
    }
    let normalizedResult = headword.withCString {
        sqlite3_bind_text(statement, 2, $0, -1, transient)
    }
    let payloadResult = payload.withUnsafeBytes {
        sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient)
    }
    guard headwordResult == SQLITE_OK,
          normalizedResult == SQLITE_OK,
          payloadResult == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
        throw CocoaError(.fileWriteUnknown)
    }
    try executeSQLite(
        "INSERT INTO lookups(lookup_key, entry_id, kind, rank) "
            + "VALUES ('\(headword)', 1, 0, 0)",
        database: database
    )
}

private func executeSQLite(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK,
          let database else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close_v2(database) }
    try executeSQLite(sql, database: database)
}

private func executeSQLite(_ sql: String, database: OpaquePointer) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        if let error { sqlite3_free(error) }
        throw CocoaError(.fileWriteUnknown)
    }
}
