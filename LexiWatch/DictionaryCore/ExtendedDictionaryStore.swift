import Foundation
@preconcurrency import SQLite3

/// The independently observable state of the bundled extended dictionary.
///
/// A normal lookup miss is intentionally not represented here. Callers can
/// distinguish an absent/corrupt resource from a healthy database that simply
/// does not contain the requested word.
public enum ExtendedDictionaryAvailability: Equatable, Sendable {
    case available
    case missing
    case invalidSchema(expected: Int32, actual: Int32)
    case openFailed
}

/// A lookup-level failure that must not be mistaken for a healthy dictionary
/// miss. The app can map these cases to a resource error while a successful
/// empty `SearchResponse` continues to mean "word not found".
public enum ExtendedDictionaryStoreError: Error, Equatable, Sendable {
    case unavailable(ExtendedDictionaryAvailability)
    case queryFailed
    case invalidPayload
}

/// Lazy, indexed access to the broad offline lexicon.
///
/// The 30k learner dictionary stays in memory for rich common-word lookup.
/// This store opens the extension only after a core miss and decodes only the
/// handful of rows needed by the current query.
public actor ExtendedDictionaryStore {
    private static let schemaVersion: Int32 = 2

    private let databaseURL: URL?
    private var database: SQLiteConnection?
    private var didAttemptOpen = false
    private var resolvedAvailability: ExtendedDictionaryAvailability?

    public init(databaseURL: URL?) {
        self.databaseURL = databaseURL
    }

    /// Opens and validates the lazy database when needed, then reports its
    /// resource state without conflating it with a lookup result.
    public func availability() -> ExtendedDictionaryAvailability {
        _ = readyDatabase()
        return resolvedAvailability ?? .openFailed
    }

    public func search(
        _ rawQuery: String,
        suggestionLimit: Int = 3
    ) throws -> SearchResponse {
        let normalized = DictionarySearchEngine.normalize(rawQuery)
        let strictKey = Self.strictLookupKey(rawQuery)
        guard !strictKey.isEmpty else {
            return SearchResponse(
                query: rawQuery,
                normalizedQuery: normalized,
                exactMatches: [],
                suggestions: []
            )
        }
        guard let database = readyDatabase() else {
            throw ExtendedDictionaryStoreError.unavailable(
                resolvedAvailability ?? .openFailed
            )
        }

        do {
            var keys = [(key: strictKey, tolerant: false)]
            if !DictionarySearchEngine.containsChinese(strictKey) {
                keys.append((Self.tolerantLookupKey(strictKey), true))
                if strictKey.contains(" ") {
                    let phrase = Self.trimmingOuterPunctuation(strictKey)
                    if !phrase.isEmpty, phrase != strictKey {
                        keys.append((phrase, false))
                        keys.append((Self.tolerantLookupKey(phrase), true))
                    }
                }
            }

            var resolvedMatches: [DictionaryMatch] = []
            for (key, tolerant) in keys {
                resolvedMatches = try exactMatches(
                    for: key,
                    database: database,
                    limit: max(1, suggestionLimit + 1),
                    tolerant: tolerant
                )
                if !resolvedMatches.isEmpty { break }
            }
            let suggestions = resolvedMatches.isEmpty
                ? try prefixMatches(
                    for: strictKey,
                    database: database,
                    limit: suggestionLimit
                )
                : []
            return SearchResponse(
                query: rawQuery,
                normalizedQuery: normalized,
                exactMatches: resolvedMatches,
                suggestions: suggestions
            )
        } catch let error as ExtendedDictionaryStoreError {
            recordRuntimeFailure()
            throw error
        } catch {
            recordRuntimeFailure()
            throw ExtendedDictionaryStoreError.queryFailed
        }
    }

    private func readyDatabase() -> OpaquePointer? {
        if let database { return database.handle }
        guard !didAttemptOpen else { return nil }
        didAttemptOpen = true
        guard let databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            resolvedAvailability = .missing
            return nil
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close_v2(opened) }
            resolvedAvailability = .openFailed
            return nil
        }

        let schema = sqlite3_user_data_version(opened)
        guard schema >= 0 else {
            sqlite3_close_v2(opened)
            resolvedAvailability = .openFailed
            return nil
        }
        guard schema == Self.schemaVersion else {
            sqlite3_close_v2(opened)
            resolvedAvailability = .invalidSchema(
                expected: Self.schemaVersion,
                actual: schema
            )
            return nil
        }
        guard sqlite3_has_extended_dictionary_schema(opened) else {
            sqlite3_close_v2(opened)
            resolvedAvailability = .openFailed
            return nil
        }
        database = SQLiteConnection(handle: opened)
        resolvedAvailability = .available
        return opened
    }

    private func recordRuntimeFailure() {
        database = nil
        resolvedAvailability = .openFailed
    }

    private func exactMatches(
        for normalizedQuery: String,
        database: OpaquePointer,
        limit: Int,
        tolerant: Bool
    ) throws -> [DictionaryMatch] {
        let sql = """
            SELECT e.payload, l.kind
            FROM lookups AS l
            JOIN entries AS e USING (entry_id)
            WHERE l.lookup_key = ?
              AND \(tolerant ? "l.kind IN (3, 4)" : "l.kind IN (0, 1, 2)")
            ORDER BY l.kind, l.rank, e.priority
            LIMIT ?
            """
        let statement = try prepared(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(normalizedQuery, to: statement, at: 1)
        try bind(Int32(limit), to: statement, at: 2)

        var matches: [DictionaryMatch] = []
        var seenIDs = Set<String>()
        while try step(statement) == SQLITE_ROW {
            let entry = try decodedEntry(from: statement, column: 0)
            guard seenIDs.insert(entry.id).inserted else { continue }
            let lookupKind = sqlite3_column_int(statement, 1)
            let kind: MatchKind = lookupKind == 2 ? .exactMeaning : .exactHeadword
            let score: Int
            switch lookupKind {
            case 0: score = 3_000
            case 1: score = 2_750
            case 2: score = 1_900
            case 3: score = 2_450
            default: score = 2_250
            }
            matches.append(DictionaryMatch(entry: entry, kind: kind, score: score))
        }
        return matches
    }

    private func prefixMatches(
        for normalizedQuery: String,
        database: OpaquePointer,
        limit: Int
    ) throws -> [DictionaryMatch] {
        guard limit > 0,
              !DictionarySearchEngine.containsChinese(normalizedQuery),
              UnifiedLookupPolicy.isCompactLexicalInput(normalizedQuery) else {
            return []
        }
        let sql = """
            SELECT payload
            FROM entries
            WHERE normalized_headword LIKE (? || '%')
            ORDER BY priority, length(normalized_headword), headword
            LIMIT ?
            """
        let statement = try prepared(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(normalizedQuery, to: statement, at: 1)
        try bind(Int32(limit), to: statement, at: 2)

        var matches: [DictionaryMatch] = []
        while try step(statement) == SQLITE_ROW {
            let entry = try decodedEntry(from: statement, column: 0)
            matches.append(DictionaryMatch(entry: entry, kind: .prefix, score: 650))
        }
        return matches
    }

    /// Keep meaningful English hyphens in the primary key. This deliberately
    /// differs from the broad in-memory engine's historical normalization;
    /// otherwise `buy-in` and `buy in` collapse before SQLite can distinguish
    /// their separate entries.
    private static func strictLookupKey(_ rawValue: String) -> String {
        var folded = rawValue
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if DictionarySearchEngine.containsChinese(folded) {
            return DictionarySearchEngine.normalize(folded)
        }

        if folded.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            folded = trimmingOuterPunctuation(folded)
        }

        var result = ""
        var pendingSpace = false
        for scalar in folded.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            if scalar.properties.generalCategory == .dashPunctuation {
                result.append("-")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func trimmingOuterPunctuation(_ value: String) -> String {
        let outerPunctuation = CharacterSet(
            charactersIn: "\"“”‘’'()[]{}<>!?！？,，;；:：。"
        )
        var scalars = Array(value.unicodeScalars)
        while let first = scalars.first,
              outerPunctuation.contains(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last,
              outerPunctuation.contains(last) {
            scalars.removeLast()
        }

        // A single terminal period is ordinary dictation/sentence punctuation
        // (`aardvark.`). Keep lexical abbreviation periods (`a.m.`, `U.S.`).
        let period: UnicodeScalar = "."
        if scalars.last == period {
            var withoutTrailingPeriods = scalars
            while withoutTrailingPeriods.last == period {
                withoutTrailingPeriods.removeLast()
            }
            if !withoutTrailingPeriods.contains(period) {
                scalars = withoutTrailingPeriods
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tolerantLookupKey(_ strictKey: String) -> String {
        strictKey
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func prepared(
        _ sql: String,
        database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ExtendedDictionaryStoreError.queryFailed
        }
        return statement
    }

    private func bind(
        _ value: String,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else {
            throw ExtendedDictionaryStoreError.queryFailed
        }
    }

    private func bind(
        _ value: Int32,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else {
            throw ExtendedDictionaryStoreError.queryFailed
        }
    }

    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw ExtendedDictionaryStoreError.queryFailed
        }
        return result
    }

    private func decodedEntry(
        from statement: OpaquePointer,
        column: Int32
    ) throws -> DictionaryEntry {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else {
            throw ExtendedDictionaryStoreError.invalidPayload
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else {
            throw ExtendedDictionaryStoreError.invalidPayload
        }
        do {
            return try JSONDecoder().decode(
                DictionaryEntry.self,
                from: Data(bytes: bytes, count: count)
            )
        } catch {
            throw ExtendedDictionaryStoreError.invalidPayload
        }
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

private func sqlite3_user_data_version(_ database: OpaquePointer) -> Int32 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
        == SQLITE_OK,
        let statement else { return -1 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return sqlite3_column_int(statement, 0)
}

private func sqlite3_has_extended_dictionary_schema(
    _ database: OpaquePointer
) -> Bool {
    let requiredColumns: [String: [String: String]] = [
        "entries": [
            "entry_id": "INTEGER",
            "headword": "TEXT",
            "normalized_headword": "TEXT",
            "priority": "INTEGER",
            "payload": "BLOB",
        ],
        "lookups": [
            "lookup_key": "TEXT",
            "entry_id": "INTEGER",
            "kind": "INTEGER",
            "rank": "INTEGER",
        ],
        "metadata": [
            "key": "TEXT",
            "value": "TEXT",
        ],
    ]

    guard sqlite3_extended_dictionary_table_count(database)
        == Int32(requiredColumns.count) else {
        return false
    }

    for (table, expected) in requiredColumns {
        guard let actual = sqlite3_declared_columns(database, table: table),
              expected.allSatisfy({ actual[$0.key] == $0.value }) else {
            return false
        }
    }
    return true
}

private func sqlite3_extended_dictionary_table_count(
    _ database: OpaquePointer
) -> Int32? {
    var statement: OpaquePointer?
    let sql = """
        SELECT COUNT(*)
        FROM sqlite_master
        WHERE type = 'table' AND name IN ('entries', 'lookups', 'metadata')
        """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int(statement, 0)
}

private func sqlite3_declared_columns(
    _ database: OpaquePointer,
    table: String
) -> [String: String]? {
    var statement: OpaquePointer?
    let pragma = "PRAGMA table_info(\(table))"
    guard sqlite3_prepare_v2(database, pragma, -1, &statement, nil) == SQLITE_OK,
          let statement else { return nil }
    defer { sqlite3_finalize(statement) }

    var columns: [String: String] = [:]
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
        guard let nameText = sqlite3_column_text(statement, 1),
              let typeText = sqlite3_column_text(statement, 2) else {
            return nil
        }
        columns[String(cString: nameText)] = String(cString: typeText).uppercased()
        result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { return nil }
    return columns
}
