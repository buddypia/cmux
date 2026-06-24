import Foundation

/// A numbered, cursor-driven terminal menu visible in an agent TUI.
public struct ChatTerminalMenu: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let number: Int
        public let label: String
        public let isFreeText: Bool
        public let isEscape: Bool

        public init(number: Int, label: String, isFreeText: Bool, isEscape: Bool) {
            self.number = number
            self.label = label
            self.isFreeText = isFreeText
            self.isEscape = isEscape
        }
    }

    public let question: String
    public let options: [Option]
    public let cursorIndex: Int
    public let hasSubmitBar: Bool

    public init(question: String, options: [Option], cursorIndex: Int, hasSubmitBar: Bool) {
        self.question = question
        self.options = options
        self.cursorIndex = cursorIndex
        self.hasSubmitBar = hasSubmitBar
    }
}

public struct ChatTerminalMenuSelectionPlan: Sendable, Equatable {
    public let keys: [String]
    public let targetNumber: Int

    public init(keys: [String], targetNumber: Int) {
        self.keys = keys
        self.targetNumber = targetNumber
    }
}

/// Parser and key planner for Claude/Codex/Antigravity-style TUI menus.
///
/// This mirrors the cmux Pilot TUI parser's transport rule: navigate with named
/// keys only (`down`, `up`, `right`, `enter`) so mobile chat does not leak
/// literal escape sequences or rely on a CLI accepting number text.
public enum ChatTerminalMenuPlanner {
    public static func parseMenu(screen: String) -> ChatTerminalMenu? {
        guard !screen.isEmpty else { return nil }
        let lines = screen.components(separatedBy: .newlines)

        var footerIndex = -1
        var submitIndex = -1
        for (index, line) in lines.enumerated() {
            if hasFooter(line) {
                footerIndex = index
            }
            if hasSubmit(line) {
                submitIndex = index
            }
        }
        guard footerIndex >= 0 || submitIndex >= 0 else { return nil }

        let end = footerIndex >= 0 ? footerIndex : lines.count
        guard end > 0 else { return nil }
        var collected: [ParsedOptionLine] = []
        var firstOptionLine = end
        var numberingMode: NumberingMode?
        var lastExplicitNumber: Int?

        for index in stride(from: end - 1, through: 0, by: -1) {
            let line = lines[index]
            if !collected.isEmpty && hasFooter(line) {
                break
            }
            if isRule(line) || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            if let option = parseOptionLine(line) {
                var acceptsOption = true
                switch (numberingMode, option.number) {
                case (.none, .some(let number)):
                    numberingMode = .explicit
                    lastExplicitNumber = number
                case (.none, .none):
                    numberingMode = .implicit
                case (.explicit, .some(let number)):
                    if let lastExplicitNumber, number != lastExplicitNumber - 1 {
                        acceptsOption = false
                    } else {
                        lastExplicitNumber = number
                    }
                case (.explicit, .none), (.implicit, .some):
                    acceptsOption = false
                case (.implicit, .none):
                    break
                }
                guard acceptsOption else { break }
                collected.append(option)
                firstOptionLine = index
                if option.number == 1 {
                    break
                }
                continue
            }
            if collected.isEmpty {
                continue
            }
            if startsWithWhitespace(line) {
                continue
            }
            break
        }

        guard collected.count >= 2 else { return nil }
        collected.reverse()

        let options = collected.enumerated().map { index, option in
            ChatTerminalMenu.Option(
                number: option.number ?? index + 1,
                label: option.label,
                isFreeText: isFreeTextLabel(option.label),
                isEscape: isEscapeLabel(option.label)
            )
        }
        guard let cursorIndex = collected.firstIndex(where: \.cursor) else { return nil }

        var question = ""
        if firstOptionLine > 0 {
            for index in stride(from: firstOptionLine - 1, through: 0, by: -1) {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty || isRule(line) || hasSubmit(line) {
                    continue
                }
                question = line.trimmingCharacters(in: .whitespaces)
                break
            }
        }

        let hasSubmitBar = submitIndex >= 0
            && submitIndex < end
            && submitIndex > firstOptionLine - 8

        return ChatTerminalMenu(
            question: question,
            options: options,
            cursorIndex: cursorIndex,
            hasSubmitBar: hasSubmitBar
        )
    }

    public static func keysToSelect(cursorIndex: Int, targetIndex: Int) -> [String] {
        let delta = targetIndex - cursorIndex
        let step = delta >= 0 ? "down" : "up"
        var keys = Array(repeating: step, count: abs(delta))
        keys.append("enter")
        return keys
    }

    /// Returns the key sequence that moves from a completed step to Submit and confirms it.
    public static func keysToSubmit() -> [String] {
        ["right", "enter"]
    }

    /// Returns Submit keys when the visible submit bar has no unchecked steps.
    ///
    /// - Parameter screen: The terminal screen snapshot to inspect.
    /// - Returns: `right` + `enter` when the submit bar is ready, otherwise `nil`.
    public static func submitPlan(screen: String) -> [String]? {
        guard let submitBar = parseSubmitBar(screen: screen),
              submitBar.isReadyToSubmit else {
            return nil
        }
        return keysToSubmit()
    }

    public static func selectionPlan(
        screen: String,
        optionIndex: Int
    ) -> ChatTerminalMenuSelectionPlan? {
        guard optionIndex >= 0 else { return nil }
        guard let menu = parseMenu(screen: screen) else { return nil }
        let targetNumber = optionIndex + 1
        guard let targetIndex = menu.options.firstIndex(where: { $0.number == targetNumber }) else {
            return nil
        }
        return ChatTerminalMenuSelectionPlan(
            keys: keysToSelect(cursorIndex: menu.cursorIndex, targetIndex: targetIndex),
            targetNumber: targetNumber
        )
    }

    /// Returns the key sequence that enters a visible `Type something` option.
    public static func freeTextSelectionPlan(screen: String) -> ChatTerminalMenuSelectionPlan? {
        guard let menu = parseMenu(screen: screen),
              let targetIndex = menu.options.firstIndex(where: \.isFreeText) else {
            return nil
        }
        return ChatTerminalMenuSelectionPlan(
            keys: keysToSelect(cursorIndex: menu.cursorIndex, targetIndex: targetIndex),
            targetNumber: menu.options[targetIndex].number
        )
    }

    private struct ParsedOptionLine {
        let number: Int?
        let label: String
        let cursor: Bool
    }

    private enum NumberingMode {
        case explicit
        case implicit
    }

    private struct SubmitBar {
        let line: String
        let uncheckedCount: Int
        let stepMarkerCount: Int
        let isReadyToSubmit: Bool
    }

    private static func parseSubmitBar(screen: String) -> SubmitBar? {
        guard !screen.isEmpty else { return nil }
        let lines = screen.components(separatedBy: .newlines)
        guard let line = lines.reversed().first(where: hasSubmit) else { return nil }
        let bracketUncheckedCount = occurrenceCount(of: "[ ]", in: line)
        let bracketCheckedCount = occurrenceCount(of: "[x]", in: line)
            + occurrenceCount(of: "[X]", in: line)
        let parenthesizedUncheckedCount = occurrenceCount(of: "( )", in: line)
        let parenthesizedCheckedCount = occurrenceCount(of: "(*)", in: line)
            + occurrenceCount(of: "(x)", in: line)
            + occurrenceCount(of: "(X)", in: line)
        let uncheckedCount = line.filter(isSubmitUncheckedStepMarker).count
            + bracketUncheckedCount
            + parenthesizedUncheckedCount
        let stepMarkerCount = line.filter(isSubmitStepMarker).count
            + bracketUncheckedCount
            + bracketCheckedCount
            + parenthesizedUncheckedCount
            + parenthesizedCheckedCount
        return SubmitBar(
            line: line.trimmingCharacters(in: .whitespaces),
            uncheckedCount: uncheckedCount,
            stepMarkerCount: stepMarkerCount,
            isReadyToSubmit: stepMarkerCount >= 2 && uncheckedCount == 0
        )
    }

    private static func parseOptionLine(_ line: String) -> ParsedOptionLine? {
        var body = line.trimmingCharacters(in: .whitespaces)
        let cursor = stripCursorPrefix(from: &body)
        if cursor {
            body = body.trimmingCharacters(in: .whitespaces)
        }
        stripSelectionMarkerPrefix(from: &body)

        if let option = parseBracketedNumberOptionLine(body: body, cursor: cursor) {
            return option
        }

        var digits = ""
        var current = body.startIndex
        while current < body.endIndex, body[current].isNumber {
            digits.append(body[current])
            current = body.index(after: current)
        }
        guard !digits.isEmpty,
              current < body.endIndex,
              isExplicitOptionDelimiter(body[current]),
              let number = Int(digits) else {
            return parseImplicitOptionLine(line, body: body, cursor: cursor)
        }
        current = body.index(after: current)
        let label = body[current...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return ParsedOptionLine(number: number, label: label, cursor: cursor)
    }

    private static func parseBracketedNumberOptionLine(
        body: String,
        cursor: Bool
    ) -> ParsedOptionLine? {
        guard let opening = body.first,
              let closing = matchingBracket(for: opening) else {
            return nil
        }
        var current = body.index(after: body.startIndex)
        var digits = ""
        while current < body.endIndex, body[current].isNumber {
            digits.append(body[current])
            current = body.index(after: current)
        }
        guard !digits.isEmpty,
              current < body.endIndex,
              body[current] == closing,
              let number = Int(digits) else {
            return nil
        }
        current = body.index(after: current)
        if current < body.endIndex, isExplicitOptionDelimiter(body[current]) {
            current = body.index(after: current)
        }
        let label = body[current...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return ParsedOptionLine(number: number, label: label, cursor: cursor)
    }

    private static func matchingBracket(for character: Character) -> Character? {
        switch character {
        case "[":
            return "]"
        case "(":
            return ")"
        default:
            return nil
        }
    }

    private static func stripSelectionMarkerPrefix(from body: inout String) {
        for prefix in [
            "- [ ]", "- [x]", "- [X]",
            "- ( )", "- (*)", "- (x)", "- (X)",
            "☐", "☑", "☒",
            "○", "◯", "●", "◉", "◎",
            "[ ]", "[x]", "[X]",
            "( )", "(*)", "(x)", "(X)",
        ] {
            guard body.hasPrefix(prefix) else { continue }
            body.removeFirst(prefix.count)
            body = body.trimmingCharacters(in: .whitespaces)
            return
        }
    }

    private static func isExplicitOptionDelimiter(_ character: Character) -> Bool {
        character == "." || character == ")" || character == ":"
    }

    private static func parseImplicitOptionLine(
        _ line: String,
        body: String,
        cursor: Bool
    ) -> ParsedOptionLine? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        guard cursor || (indent > 0 && indent <= 2) else { return nil }
        let label = body.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return ParsedOptionLine(number: nil, label: label, cursor: cursor)
    }

    private static func isFreeTextLabel(_ label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        switch normalized {
        case "type something", "custom response", "custom answer", "other":
            return true
        default:
            return normalized.hasPrefix("type custom ")
                || normalized.hasPrefix("type your ")
                || normalized.hasPrefix("write custom ")
                || normalized.hasPrefix("enter custom ")
        }
    }

    private static func isEscapeLabel(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chat about this"
    }

    @discardableResult
    private static func stripCursorPrefix(from body: inout String) -> Bool {
        for prefix in ["❯", "›", "▸", "▶", "➜", "→", ">"] {
            guard body.hasPrefix(prefix) else { continue }
            body.removeFirst(prefix.count)
            return true
        }
        return false
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "─" || $0 == "-" }
    }

    private static func hasFooter(_ line: String) -> Bool {
        let lower = line.lowercased()
        let hasEnterAction = hasFooterAction(
            in: lower,
            controls: ["enter", "return"],
            actions: ["select", "choose", "confirm", "submit"]
        )
        let hasEscapeAction = hasFooterAction(
            in: lower,
            controls: ["esc", "escape", "ctrl+c", "ctrl-c", "control-c", "q"],
            actions: ["cancel", "go back", "abort", "quit", "exit"]
        )
        return hasEnterAction && hasEscapeAction
    }

    private static func hasFooterAction(in line: String, controls: [String], actions: [String]) -> Bool {
        controls.contains { control in
            actions.contains { action in
                line.contains("\(control) to \(action)")
                    || line.contains("\(control): \(action)")
                    || line.contains("\(control):\(action)")
                    || line.contains("\(control) = \(action)")
                    || line.contains("\(control)=\(action)")
                    || line.contains("\(control) \(action)")
            }
        }
    }

    private static func hasSubmit(_ line: String) -> Bool {
        line.range(
            of: #"(?:[✔✓☑✅●◉◎]|\[[xX]\]|\(\*\)|\([xX]\))\s*Submit"#,
            options: [.caseInsensitive, .regularExpression]
        ) != nil
    }

    private static func isSubmitStepMarker(_ character: Character) -> Bool {
        character == "☐"
            || character == "☑"
            || character == "☒"
            || character == "○"
            || character == "◯"
            || character == "●"
            || character == "◉"
            || character == "◎"
            || character == "✔"
            || character == "✓"
            || character == "✅"
    }

    private static func isSubmitUncheckedStepMarker(_ character: Character) -> Bool {
        character == "☐" || character == "○" || character == "◯"
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func startsWithWhitespace(_ line: String) -> Bool {
        guard let scalar = line.unicodeScalars.first else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }
}
