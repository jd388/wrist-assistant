import Foundation

enum SearchHistory {
    static func merging(_ histories: [[String]]) -> [String] {
        histories.flatMap { $0 }.reduce(into: []) { merged, item in
            guard !merged.contains(where: {
                $0.caseInsensitiveCompare(item) == .orderedSame
            }) else {
                return
            }
            merged.append(item)
        }
    }

    static func remembering(_ text: String, in history: [String]) -> [String] {
        [text] + history.filter {
            $0.caseInsensitiveCompare(text) != .orderedSame
        }
    }

    static func removing(_ text: String, from history: [String]) -> [String] {
        history.filter {
            $0.caseInsensitiveCompare(text) != .orderedSame
        }
    }
}
