import Foundation

/// A small, loss-preserving presentation parser, independent of conversation storage.
/// Incomplete streaming blocks use the same renderer as completed answers.
public struct AIAnswerBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph, heading(Int), listItem(marker: String, depth: Int), quote
        case code(language: String), math, tableRecord, divider
    }
    public struct Field: Equatable, Sendable {
        public let name: String
        public let value: String
    }
    public let kind: Kind
    public let text: String
    public let fields: [Field]

    init(_ kind: Kind, _ text: String = "", fields: [Field] = []) {
        self.kind = kind
        self.text = text
        self.fields = fields
    }
}

public enum AIAnswerDocument {
    public static func parse(_ text: String) -> [AIAnswerBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [AIAnswerBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(AIAnswerBlock(.paragraph, paragraph.joined(separator: "\n")))
                paragraph.removeAll(keepingCapacity: true)
            }
        }
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); index += 1; continue }

            if let fence = fenceStart(line) {
                flush()
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.allSatisfy({ $0 == fence.character }), candidate.count >= fence.count {
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(AIAnswerBlock(.code(language: fence.language), code.joined(separator: "\n")))
                continue
            }

            if line.hasPrefix("$$") || line.hasPrefix(#"\["#) {
                flush()
                let closing = line.hasPrefix("$$") ? "$$" : #"\]"#
                var formula = line
                var remainder = ""
                if let end = line.dropFirst(2).range(of: closing) {
                    formula = String(line[..<end.upperBound])
                    remainder = String(line[end.upperBound...])
                } else {
                    while index + 1 < lines.count {
                        index += 1
                        let next = lines[index]
                        if let end = next.range(of: closing) {
                            formula += "\n" + next[..<end.upperBound]
                            remainder = String(next[end.upperBound...])
                            break
                        }
                        formula += "\n" + next
                    }
                }
                blocks.append(AIAnswerBlock(.math, formula))
                if !remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    paragraph.append(remainder)
                }
                index += 1
                continue
            }

            // A table is recognised only once its delimiter line has arrived.
            if index + 1 < lines.count, line.contains("|"),
               let headers = cells(line), let separators = cells(lines[index + 1]),
               headers.count == separators.count,
               separators.allSatisfy(isTableSeparator) {
                flush()
                index += 2
                var records = 0
                while index < lines.count, lines[index].contains("|"),
                      let values = cells(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let fields = (0..<max(headers.count, values.count)).map { column in
                        AIAnswerBlock.Field(
                            name: column < headers.count && !headers[column].isEmpty ? headers[column] : "第\(column + 1)列",
                            value: column < values.count && !values[column].isEmpty ? values[column] : "—"
                        )
                    }
                    blocks.append(AIAnswerBlock(.tableRecord, fields: fields))
                    records += 1
                    index += 1
                }
                if records == 0 { blocks.append(AIAnswerBlock(.paragraph, headers.joined(separator: " · "))) }
                continue
            }

            let hashes = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), line.dropFirst(hashes).first?.isWhitespace == true {
                flush()
                let title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(AIAnswerBlock(.heading(hashes), title))
            } else if isRule(line) {
                if !paragraph.isEmpty, line.allSatisfy({ $0 == "-" || $0 == "=" }) {
                    blocks.append(AIAnswerBlock(.heading(line.first == "=" ? 1 : 2), paragraph.joined(separator: "\n")))
                    paragraph.removeAll(keepingCapacity: true)
                } else {
                    flush()
                    blocks.append(AIAnswerBlock(.divider))
                }
            } else if line.hasPrefix(">") {
                flush()
                let quote = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let last = blocks.last, last.kind == .quote {
                    blocks[blocks.count - 1] = AIAnswerBlock(.quote, last.text + "\n" + quote)
                } else { blocks.append(AIAnswerBlock(.quote, quote)) }
            } else if let item = listItem(line) {
                flush()
                let indent = raw.prefix(while: { $0 == " " || $0 == "\t" })
                    .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                blocks.append(AIAnswerBlock(.listItem(marker: item.marker, depth: min(indent / 2, 3)), item.text))
            } else if raw.first?.isWhitespace == true, paragraph.isEmpty,
                      let last = blocks.last, case .listItem = last.kind {
                blocks[blocks.count - 1] = AIAnswerBlock(last.kind, last.text + "\n" + line)
            } else {
                paragraph.append(raw)
            }
            index += 1
        }
        flush()
        return blocks
    }

    private static func fenceStart(_ line: String) -> (character: Character, count: Int, language: String)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return (first, count, line.dropFirst(count).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_=".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first?.isWhitespace == true {
            return ("•", line.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let punctuation = line.dropFirst(digits.count).first,
              punctuation == "." || punctuation == ")",
              line.dropFirst(digits.count + 1).first?.isWhitespace == true else { return nil }
        return (String(digits) + String(punctuation), line.dropFirst(digits.count + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func isTableSeparator(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return value.count >= 3 && value.allSatisfy { $0 == "-" }
    }

    private static func cells(_ line: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var escaped = false
        var codeTicks = 0
        var tickRun = 0
        func finishTicks() {
            guard tickRun > 0 else { return }
            if codeTicks == 0 { codeTicks = tickRun }
            else if codeTicks == tickRun { codeTicks = 0 }
            tickRun = 0
        }
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                current.append(character == "|" ? "|" : "\\" + String(character))
                escaped = false
                continue
            }
            if character == "\\" { finishTicks(); escaped = true; continue }
            if character == "`" { tickRun += 1; current.append(character); continue }
            finishTicks()
            if character == "|", codeTicks == 0 {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else { current.append(character) }
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { result.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), result.last == "" { result.removeLast() }
        return result.isEmpty ? nil : result
    }
}

public struct AIReadingAnswerSnapshot: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let citationCount: Int
    public init(id: UUID, text: String, citationCount: Int = 0) {
        self.id = id
        self.text = text
        self.citationCount = citationCount
    }
    public var hasContent: Bool { text.contains { !$0.isWhitespace } || citationCount > 0 }
}

/// Scrolling away pauses following; only newly received answer content creates
/// an unread indicator. Layout, draft edits and browsing old content cannot.
public struct AIReadingFollowState: Equatable, Sendable {
    public private(set) var followsLatest = true
    public private(set) var isUserScrolling = false
    public private(set) var hasUnreadAnswer = false
    private var latestAnswer: AIReadingAnswerSnapshot?
    public init() {}
    public mutating func reset(answer: AIReadingAnswerSnapshot?) {
        self = AIReadingFollowState()
        latestAnswer = answer
    }
    public mutating func observeAnswer(_ answer: AIReadingAnswerSnapshot?, allowsUnread: Bool = true) {
        defer { latestAnswer = answer }
        guard let answer, answer.hasContent else {
            hasUnreadAnswer = false
            return
        }
        if answer != latestAnswer, allowsUnread, !shouldFollowUpdates { hasUnreadAnswer = true }
    }
    public static func distanceFromBottom(contentHeight: Double, bottomInset: Double, visibleBottom: Double) -> Double {
        max(0, contentHeight + bottomInset - visibleBottom)
    }
    public mutating func beginUserScroll() {
        isUserScrolling = true
        followsLatest = false
    }
    public mutating func endUserScroll(distanceFromBottom: Double) {
        isUserScrolling = false
        followsLatest = distanceFromBottom <= 36
        if followsLatest { hasUnreadAnswer = false }
    }
    public mutating func updateGeometry(distanceFromBottom: Double) {
        if isUserScrolling {
            followsLatest = distanceFromBottom <= 36
            if followsLatest { hasUnreadAnswer = false }
        }
    }
    public mutating func returnToLatest() {
        followsLatest = true
        isUserScrolling = false
        hasUnreadAnswer = false
    }
    public var shouldFollowUpdates: Bool { followsLatest && !isUserScrolling }
    public var shouldShowReturnToLatest: Bool {
        hasUnreadAnswer && !followsLatest && latestAnswer?.hasContent == true
    }
}

/// Recognizes math before Markdown can consume its escapes, underscores, or braces.
/// Each formula either renders in full or retains its original spelling.
enum AIMathText {
    enum Run: Equatable {
        case markdown(String)
        case literal(String)
    }

    static func runs(_ text: String) -> [Run] {
        var runs: [Run] = []
        var start = text.startIndex
        var cursor = start
        var ticks = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "`" {
                let end = text[cursor...].firstIndex(where: { $0 != "`" }) ?? text.endIndex
                let count = text.distance(from: cursor, to: end)
                if ticks == 0 { ticks = count }
                else if ticks == count { ticks = 0 }
                cursor = end
                continue
            }
            if ticks == 0, let match = formula(in: text, at: cursor) {
                if start < cursor { runs.append(.markdown(String(text[start..<cursor]))) }
                runs.append(.literal(match.text))
                cursor = match.end
                start = cursor
                continue
            }
            if character == "\\", ticks == 0 {
                let next = text.index(after: cursor)
                cursor = next < text.endIndex ? text.index(after: next) : next
            } else {
                cursor = text.index(after: cursor)
            }
        }
        if start < text.endIndex { runs.append(.markdown(String(text[start...]))) }
        return runs
    }

    private static func formula(in text: String, at start: String.Index) -> (text: String, end: String.Index)? {
        let tail = text[start...]
        if tail.hasPrefix(#"\ce{"#) {
            var parser = Renderer(String(tail.dropFirst(3)))
            guard let body = parser.readGroup() else { return (String(tail), text.endIndex) }
            let end = text.index(start, offsetBy: 3 + parser.position)
            return (Renderer.chemical(body) ?? String(text[start..<end]), end)
        }

        let opening: String
        let closing: String
        if tail.hasPrefix("$$") { (opening, closing) = ("$$", "$$") }
        else if tail.hasPrefix(#"\["#) { (opening, closing) = (#"\["#, #"\]"#) }
        else if tail.hasPrefix(#"\("#) { (opening, closing) = (#"\("#, #"\)"#) }
        else if tail.hasPrefix("$") { (opening, closing) = ("$", "$") }
        else { return nil }

        let bodyStart = text.index(start, offsetBy: opening.count)
        let inlineDollar = opening == "$"
        if inlineDollar && (bodyStart == text.endIndex || text[bodyStart].isWhitespace) {
            return nil
        }
        var index = bodyStart
        while index < text.endIndex {
            if inlineDollar && text[index].isNewline { return nil }
            if text[index...].hasPrefix(closing) {
                let end = text.index(index, offsetBy: closing.count)
                let body = String(text[bodyStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                if inlineDollar {
                    let before = text[text.index(before: index)]
                    if before.isWhitespace || (end < text.endIndex && text[end].isNumber) { return nil }
                }
                return (Renderer.convert(body) ?? String(text[start..<end]), end)
            }
            if text[index] == "\\" {
                let next = text.index(after: index)
                index = next < text.endIndex ? text.index(after: next) : next
            } else {
                index = text.index(after: index)
            }
        }
        // Explicit delimiters may still be arriving in a streaming answer.
        return inlineDollar ? nil : (String(tail), text.endIndex)
    }

    static func containsGrid(_ text: String) -> Bool {
        Renderer.gridDelimiters.keys.contains { text.contains("\\begin{\($0)}") }
    }

    static func attributed(
        _ text: String,
        decorateFormula: (String, AttributeContainer) -> AttributedString = {
            AttributedString($0, attributes: $1)
        }
    ) -> AttributedString {
        let runs = runs(text)
        var markdown = ""
        var formulas: [(key: String, text: String)] = []
        var tokenPrefix = "\u{E000}"
        while text.contains(tokenPrefix) { tokenPrefix += "\u{E000}" }
        for run in runs {
            switch run {
            case .markdown(let value): markdown += value
            case .literal(let value):
                let key = tokenPrefix + "FORMULA" + String(formulas.count) + "\u{E001}"
                formulas.append((key, value))
                markdown += key
            }
        }
        guard var result = try? AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for formula in formulas {
            guard let range = result.range(of: formula.key) else { continue }
            let attributes = result[range].runs.first?.attributes ?? AttributeContainer()
            result.replaceSubrange(range, with: decorateFormula(formula.text, attributes))
        }
        return result
    }

    static func scriptGlyph(_ character: Character) -> (character: Character, isSuperscript: Bool)? {
        Renderer.presentationScripts[character]
    }

    private struct Renderer {
        private static let commands = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
            "varepsilon": "ε", "theta": "θ", "lambda": "λ", "mu": "μ", "nu": "ν",
            "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ",
            "varphi": "ϕ", "chi": "χ", "psi": "ψ", "omega": "ω", "Delta": "Δ",
            "Gamma": "Γ", "Lambda": "Λ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
            "Psi": "Ψ", "Omega": "Ω", "Theta": "Θ",
            "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "le": "≤",
            "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈",
            "equiv": "≡", "circ": "∘", "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑",
            "prod": "∏", "int": "∫", "in": "∈", "notin": "∉", "subset": "⊂",
            "to": "→", "rightarrow": "→", "longrightarrow": "→", "leftarrow": "←",
            "longleftarrow": "←", "leftrightarrow": "↔", "longleftrightarrow": "↔",
            "rightleftharpoons": "⇌", "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
            "uparrow": "↑", "downarrow": "↓", "ldots": "…", "cdots": "⋯",
            "sin": "sin ", "cos": "cos ", "tan": "tan ", "log": "log ", "ln": "ln ",
            "exp": "exp ", "lim": "lim ", "quad": "  ", "qquad": "   "
        ]
        private static let scripts = [
            "^": Dictionary(uniqueKeysWithValues: zip("0123456789+-=()nix∘", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱˣ°")),
            "_": Dictionary(uniqueKeysWithValues: zip("0123456789+-=()aehiklnoprstuvx", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢₖₗₙₒₚᵣₛₜᵤᵥₓ"))
        ]
        static let presentationScripts: [Character: (character: Character, isSuperscript: Bool)] = {
            var values: [Character: (Character, Bool)] = [:]
            for (marker, glyphs) in scripts {
                for (character, glyph) in glyphs where glyph != "°" {
                    values[glyph] = (character, marker == "^")
                }
            }
            return values
        }()
        // Each string contains the single, top, middle, and bottom delimiters.
        static let gridDelimiters: [String: (left: String, right: String)] = [
            "matrix": ("    ", "    "), "smallmatrix": ("    ", "    "),
            "pmatrix": ("(⎛⎜⎝", ")⎞⎟⎠"), "bmatrix": ("[⎡⎢⎣", "]⎤⎥⎦"),
            "Bmatrix": ("{⎧⎨⎩", "}⎫⎬⎭"), "vmatrix": ("|│││", "|│││"),
            "Vmatrix": ("‖║║║", "‖║║║"), "cases": ("{⎧⎨⎩", "    ")
        ]
        private static let alignmentEnvironments: Set<String> = [
            "aligned", "gathered", "align", "align*", "gather", "gather*"
        ]
        private static let annotatedArrows = [
            "xrightarrow": "→", "xleftarrow": "←", "xleftrightarrow": "↔",
            "xRightarrow": "⇒", "xLeftarrow": "⇐", "xLeftrightarrow": "⇔",
            "xrightleftharpoons": "⇌"
        ]

        private let characters: [Character]
        private(set) var position = 0

        init(_ text: String) { characters = Array(text) }

        static func convert(_ text: String, depth: Int = 0) -> String? {
            guard depth < 15 else { return nil }
            var parser = Renderer(text)
            return parser.render(depth: depth)
        }

        private var next: Character? { position < characters.count ? characters[position] : nil }

        private mutating func consume() -> Character? {
            guard let next else { return nil }
            position += 1
            return next
        }

        private mutating func skipWhitespace() {
            while next?.isWhitespace == true { position += 1 }
        }

        mutating func readGroup(opening: Character = "{", closing: Character = "}") -> String? {
            skipWhitespace()
            guard consume() == opening else { return nil }
            let start = position
            var depth = 1
            var braceDepth = 0
            while let character = consume() {
                if character == "\\" { _ = consume(); continue }
                if opening == "[" {
                    if character == "{" { braceDepth += 1 }
                    if character == "}" { braceDepth -= 1 }
                    if braceDepth != 0 { continue }
                }
                if character == opening { depth += 1 }
                if character == closing {
                    depth -= 1
                    if depth == 0 { return String(characters[start..<(position - 1)]) }
                }
            }
            return nil
        }

        private mutating func readArgument() -> String? {
            skipWhitespace()
            if next == "{" { return readGroup() }
            if next == "\\" {
                position += 1
                return command().map { "\\" + $0 }
            }
            guard let next, !"}_^&".contains(next) else { return nil }
            position += 1
            return String(next)
        }

        private mutating func renderEnvironment(_ name: String, depth: Int) -> String? {
            let delimiters = Self.gridDelimiters[name]
            guard delimiters != nil || Self.alignmentEnvironments.contains(name) else { return nil }

            var rows: [[String]] = []
            var row: [String] = []
            var cellStart = position
            var braceDepth = 0
            while let character = consume() {
                let boundary = position - 1
                if character == "{" { braceDepth += 1 }
                if character == "}" { braceDepth -= 1 }
                var lastRow = false
                var endRow = false
                if character == "\\" {
                    guard let nameOrSymbol = command() else { return nil }
                    if braceDepth != 0 { continue }
                    if nameOrSymbol == "begin" { return nil }
                    if nameOrSymbol == "end" {
                        guard readGroup() == name else { return nil }
                        lastRow = true
                    } else if nameOrSymbol == "\\" {
                        endRow = true
                        skipWhitespace()
                        if next == "[", readGroup(opening: "[", closing: "]") == nil { return nil }
                    } else { continue }
                } else if character != "&" || braceDepth != 0 { continue }

                let raw = String(characters[cellStart..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                if lastRow, row.isEmpty, raw.isEmpty, !rows.isEmpty {
                    return Self.formatRows(rows, delimiters: delimiters)
                }
                guard row.count < 24, rows.count < 48,
                      let cell = Self.convert(raw, depth: depth + 1),
                      delimiters == nil || !cell.contains("\n") else { return nil }
                row.append(cell)
                if lastRow || endRow {
                    rows.append(row)
                    row.removeAll()
                }
                if lastRow { return Self.formatRows(rows, delimiters: delimiters) }
                cellStart = position
            }
            return nil
        }

        private static func formatRows(_ rows: [[String]], delimiters: (left: String, right: String)?) -> String {
            guard let delimiters else {
                return rows.map { $0.joined(separator: " ") }.joined(separator: "\n")
            }
            let columns = rows.map(\.count).max() ?? 0
            let widths = (0..<columns).map { column in
                rows.lazy.filter { $0.indices.contains(column) }.map { $0[column].count }.max() ?? 0
            }
            let left = Array(delimiters.left)
            let right = Array(delimiters.right)
            return rows.enumerated().map { index, row in
                let shape: Int
                if rows.count == 1 { shape = 0 }
                else if index == 0 { shape = 1 }
                else if index == rows.count - 1 { shape = 3 }
                else { shape = 2 }
                let hasRightDelimiter = right[shape] != " "
                let cells = widths.enumerated().map { column, width in
                    let value = row.indices.contains(column) ? row[column] : ""
                    guard column < columns - 1 || hasRightDelimiter else { return value }
                    return value + String(repeating: " ", count: width - value.count)
                }.joined(separator: "  ")
                return (left[shape] == " " ? "" : String(left[shape]) + " ")
                    + cells + (hasRightDelimiter ? " " + String(right[shape]) : "")
            }.joined(separator: "\n")
        }

        private mutating func render(depth: Int) -> String? {
            var output = ""
            var hasScalableDelimiter = false
            while let character = consume() {
                switch character {
                case "\\":
                    guard let command = command() else { return nil }
                    if let symbol = Self.commands[command] { output += symbol; continue }
                    if let arrow = Self.annotatedArrows[command] {
                        guard let value = renderArrow(arrow, depth: depth) else { return nil }
                        output += value
                        continue
                    }
                    switch command {
                    case "frac", "dfrac", "tfrac":
                        guard let top = readArgument().flatMap({ Self.convert($0, depth: depth + 1) }),
                              let bottom = readArgument().flatMap({ Self.convert($0, depth: depth + 1) }),
                              !top.isEmpty, !bottom.isEmpty else { return nil }
                        output += Self.operand(top) + "⁄" + Self.operand(bottom)
                    case "sqrt":
                        skipWhitespace()
                        var radical = "√"
                        if next == "[" {
                            guard let degree = readGroup(opening: "[", closing: "]")
                                .flatMap({ Self.convert($0, depth: depth + 1) }),
                                  !degree.isEmpty else { return nil }
                            if degree == "3" { radical = "∛" }
                            else if degree == "4" { radical = "∜" }
                            else if degree != "2" { radical = Self.script(degree, marker: "^") + radical }
                        }
                        guard let value = readArgument().flatMap({ Self.convert($0, depth: depth + 1) }),
                              !value.isEmpty else { return nil }
                        let root = radical + Self.operand(value)
                        output += next == "^" || next == "_" ? "(" + root + ")" : root
                    case "begin":
                        guard let name = readGroup(), let grid = renderEnvironment(name, depth: depth) else { return nil }
                        if Self.gridDelimiters[name] != nil, grid.contains("\n"),
                           output.last?.isNewline == false {
                            output = output.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
                            output += "\n"
                        }
                        output += grid
                    case "overset", "underset", "stackrel":
                        guard let label = readGroup().flatMap({ Self.convert($0, depth: depth + 1) }),
                              let base = readGroup().flatMap({ Self.convert($0, depth: depth + 1) }),
                              !base.isEmpty else { return nil }
                        output += Self.annotate(base, above: command == "underset" ? "" : label,
                                                below: command == "underset" ? label : "")
                    case "ce":
                        guard let body = readGroup(), let value = Self.chemical(body, depth: depth + 1) else { return nil }
                        output += value
                    case "text":
                        guard let body = readGroup() else { return nil }
                        output += body
                    case "mathrm", "mathbf", "operatorname":
                        guard let body = readGroup().flatMap({ Self.convert($0, depth: depth + 1) }) else { return nil }
                        output += body
                    case "left", "right": hasScalableDelimiter = true
                    case ",", ";", ":", " ": output += " "
                    case "!": break
                    case "\\": output += "\n"
                    case "{", "}", "_", "%", "|", "&", "$": output += command
                    default: return nil
                    }
                case "^", "_":
                    guard let raw = readArgument(), !raw.isEmpty,
                          let value = Self.convert(raw, depth: depth + 1) else { return nil }
                    output += Self.script(value, marker: character)
                case "{":
                    position -= 1
                    guard let body = readGroup().flatMap({ Self.convert($0, depth: depth + 1) }) else { return nil }
                    output += body
                case "}": return nil
                case ".": if !hasScalableDelimiter { output.append(character) }
                default: output.append(character)
                }
                hasScalableDelimiter = false
            }
            return output
        }

        private mutating func command() -> String? {
            guard let first = consume() else { return nil }
            guard first.isASCII && first.isLetter else { return String(first) }
            let start = position - 1
            while next?.isASCII == true && next?.isLetter == true { position += 1 }
            let name = String(characters[start..<position])
            _ = next == " " ? consume() : nil
            return name
        }

        private static func operand(_ value: String) -> String {
            value.allSatisfy { $0.isLetter || $0.isNumber || "₀₁₂₃₄₅₆₇₈₉".contains($0) }
                ? value : "(" + value + ")"
        }

        private static func script(_ text: String, marker: Character) -> String {
            let mapped = text.compactMap { scripts[String(marker)]?[$0] }
            if mapped.count == text.count { return String(mapped) }
            return String(marker) + "(" + text + ")"
        }

        private mutating func renderArrow(_ arrow: String, depth: Int) -> String? {
            skipWhitespace()
            var below = ""
            if next == "[" {
                guard let label = readGroup(opening: "[", closing: "]")
                    .flatMap({ Self.convert($0, depth: depth + 1) }) else { return nil }
                below = label
            }
            guard let above = readGroup().flatMap({ Self.convert($0, depth: depth + 1) }) else { return nil }
            return Self.annotate(arrow, above: above, below: below)
        }

        private static func annotate(_ base: String, above: String, below: String) -> String {
            let labels = [above.isEmpty ? nil : "上：\(above)", below.isEmpty ? nil : "下：\(below)"]
                .compactMap { $0 }
            return labels.isEmpty ? base : base + "（" + labels.joined(separator: "，") + "）"
        }

        private mutating func chemicalArrow() -> String? {
            let arrows = [("<=>", "⇌"), ("<->", "↔"), ("=>", "→"), ("->", "→"),
                          ("<-", "←"), ("⇌", "⇌"), ("→", "→"), ("←", "←"), ("↔", "↔")]
            for (spelling, symbol) in arrows where characters[position...].starts(with: spelling) {
                position += spelling.count
                return symbol
            }
            return nil
        }

        static func chemical(_ body: String, depth: Int = 0) -> String? {
            var parser = Renderer(body)
            var output = ""
            var previous: Character?
            while let character = parser.next {
                if "<-=⇌→←↔".contains(character), let arrow = parser.chemicalArrow() {
                    var labels: [String] = []
                    while labels.count < 2, parser.next == "[" {
                        guard let label = parser.readGroup(opening: "[", closing: "]")
                            .flatMap({ convert($0, depth: depth + 1) }) else { return nil }
                        labels.append(label)
                    }
                    output += annotate(arrow, above: labels.first ?? "", below: labels.count == 2 ? labels[1] : "")
                    previous = nil
                    continue
                }
                _ = parser.consume()
                if character == "^" || character == "_" {
                    let raw: String?
                    if parser.next == "{" { raw = parser.readGroup() }
                    else {
                        var inline = ""
                        while let next = parser.next, next.isNumber || next == "+" || next == "-" {
                            inline.append(next)
                            _ = parser.consume()
                            if next == "+" || next == "-" { break }
                        }
                        raw = inline
                    }
                    guard let raw, !raw.isEmpty else { return nil }
                    output += script(raw, marker: character)
                } else if character.isNumber, let previous,
                          previous.isASCII && (previous.isLetter || previous == ")" || previous == "]") {
                    var number = String(character)
                    while let next = parser.next, next.isNumber {
                        number.append(next)
                        _ = parser.consume()
                    }
                    output += script(number, marker: "_")
                } else if character == "\\" || character == "{" || character == "}" {
                    return nil
                } else {
                    output.append(character)
                }
                previous = character
            }
            return output
        }
    }
}
