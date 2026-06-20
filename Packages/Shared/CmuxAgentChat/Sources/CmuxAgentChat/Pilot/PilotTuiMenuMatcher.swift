import Foundation

public enum PilotTuiOptionMatchResult: Sendable, Equatable {
    case matched(PilotTuiDecision)
    case noMatch(reason: String)
    case ambiguous(reason: String, optionNumbers: [Int])
}

public enum PilotTuiMenuMatcher {
    public static func match(
        menu: PilotTuiMenu,
        query: String,
        confidence: Double,
        reason: String? = nil
    ) -> PilotTuiOptionMatchResult {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else {
            return .noMatch(reason: "empty match query")
        }

        let candidates = menu.options.filter(\.isAutoSelectable)
        let exactMatches = candidates.filter { normalize($0.label) == normalizedQuery }
        if exactMatches.count == 1, let exact = exactMatches.first {
            return .matched(PilotTuiDecision(
                optionNumber: exact.number,
                confidence: confidence,
                reason: reason ?? "matched exact option label"
            ))
        }
        if exactMatches.count > 1 {
            return .ambiguous(
                reason: "match query is ambiguous",
                optionNumbers: exactMatches.map(\.number)
            )
        }

        let substringMatches = candidates.filter { normalize($0.label).contains(normalizedQuery) }
        if substringMatches.count == 1, let match = substringMatches.first {
            return .matched(PilotTuiDecision(
                optionNumber: match.number,
                confidence: confidence,
                reason: reason ?? "matched unique option label substring"
            ))
        }
        if substringMatches.count > 1 {
            return .ambiguous(
                reason: "match query is ambiguous",
                optionNumbers: substringMatches.map(\.number)
            )
        }

        return .noMatch(reason: "no safe option label matched query")
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
