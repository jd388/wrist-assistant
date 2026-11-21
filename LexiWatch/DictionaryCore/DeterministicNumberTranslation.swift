import Foundation

enum DeterministicNumberTranslation {
    private static let digitWords = [
        "zero", "one", "two", "three", "four",
        "five", "six", "seven", "eight", "nine",
    ]

    static func englishSpelling(for query: String) -> String? {
        var candidate = normalizeWidth(in: query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        var sign = ""
        if candidate.first == "-" {
            sign = "-"
            candidate.removeFirst()
        } else if candidate.first == "+" {
            candidate.removeFirst()
        }

        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count),
              let integerPart = parts.first,
              !integerPart.isEmpty,
              integerPart.allSatisfy(isASCIIDigit),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy(isASCIIDigit)) else {
            return nil
        }

        let digitCount = parts.reduce(0) { $0 + $1.count }
        let canonical = sign + candidate
        if digitCount <= 18 {
            let number = NSDecimalNumber(
                string: canonical,
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard number != .notANumber else { return nil }

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .spellOut
            formatter.maximumFractionDigits = parts.count == 2 ? parts[1].count : 0
            return formatter.string(from: number)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let spokenDigits = parts.enumerated().map { index, part in
            let words = part.compactMap { character -> String? in
                guard let value = character.wholeNumberValue,
                      digitWords.indices.contains(value) else {
                    return nil
                }
                return digitWords[value]
            }
            let prefix = index == 1 ? ["point"] : []
            return (prefix + words).joined(separator: " ")
        }
        .joined(separator: " ")

        return sign == "-" ? "minus \(spokenDigits)" : spokenDigits
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return (0x30 ... 0x39).contains(scalar.value)
    }

    private static func normalizeWidth(in text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF10 ... 0xFF19:
                result.append(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)
            case 0xFF0E:
                result.append(".")
            case 0xFF0D, 0x2212:
                result.append("-")
            case 0xFF0B:
                result.append("+")
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }
}
