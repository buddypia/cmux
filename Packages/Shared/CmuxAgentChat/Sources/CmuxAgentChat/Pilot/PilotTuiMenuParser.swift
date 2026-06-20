import Foundation

/// Pure parser and planner for Claude-style terminal selection menus.
public enum PilotTuiMenuParser {
    private struct ParsedOption {
        let number: Int
        let label: String
        let hasCursor: Bool
    }

    /// Parses the last interactive menu block from a terminal screen snapshot.
    ///
    /// Returns `nil` when no menu is present, fewer than two options exist, or
    /// the menu does not show the cursor marker.
    public static func parseMenu(screen: String) -> PilotTuiMenu? {
        guard !screen.isEmpty else { return nil }

        let lines = screen.normalizedTerminalLines()
        var footerIndex: Int?
        var submitIndex: Int?
        for (index, line) in lines.enumerated() {
            if hasFooter(line) {
                footerIndex = index
            }
            if line.contains("✔ Submit") {
                submitIndex = index
            }
        }

        guard footerIndex != nil || submitIndex != nil else { return nil }

        let endIndex = footerIndex ?? lines.count
        guard endIndex > 0 else { return nil }

        var collected: [ParsedOption] = []
        var firstOptionLine = endIndex
        var lastNumber: Int?

        for index in stride(from: endIndex - 1, through: 0, by: -1) {
            let line = lines[index]
            if !collected.isEmpty && hasFooter(line) {
                break
            }
            if isRuleLine(line) || line.pilotTrimmedWhitespace().isEmpty {
                continue
            }
            if let option = parseOptionLine(line) {
                if let lastNumber, option.number != lastNumber - 1 {
                    break
                }
                collected.append(option)
                firstOptionLine = index
                lastNumber = option.number
                if option.number == 1 {
                    break
                }
                continue
            }
            if collected.isEmpty {
                continue
            }
            if line.first?.isWhitespace == true {
                continue
            }
            break
        }

        guard collected.count >= 2 else { return nil }
        collected.reverse()

        let options = collected.map { option in
            PilotTuiOption(
                number: option.number,
                label: option.label,
                isFreeText: option.label == "Type something." || option.label == "Type something",
                isEscape: option.label == "Chat about this"
            )
        }

        guard let cursorIndex = collected.firstIndex(where: { $0.hasCursor }) else {
            return nil
        }

        var question = ""
        if firstOptionLine > 0 {
            for index in stride(from: firstOptionLine - 1, through: 0, by: -1) {
                let line = lines[index]
                let trimmed = line.pilotTrimmedWhitespace()
                if trimmed.isEmpty || isRuleLine(line) || line.contains("✔ Submit") {
                    continue
                }
                question = trimmed
                break
            }
        }

        let hasSubmitBar = submitIndex.map { index in
            index < endIndex && index > firstOptionLine - 8
        } ?? false

        return PilotTuiMenu(
            question: question,
            options: options,
            cursorIndex: cursorIndex,
            hasSubmitBar: hasSubmitBar
        )
    }

    /// Parses the multi-step submit progress bar from a terminal screen snapshot.
    public static func parseSubmitBar(screen: String) -> PilotTuiSubmitBar? {
        guard !screen.isEmpty else { return nil }

        let line = screen.normalizedTerminalLines().last(where: { $0.contains("✔ Submit") })
        guard let line else { return nil }

        let uncheckedCount = line.filter { $0 == "☐" }.count
        let stepMarkerCount = line.filter { character in
            character == "☐" || character == "☑" || character == "☒" || character == "✔"
        }.count

        return PilotTuiSubmitBar(
            line: line.pilotTrimmedWhitespace(),
            uncheckedCount: uncheckedCount,
            stepMarkerCount: stepMarkerCount,
            isReadyToSubmit: stepMarkerCount >= 2 && uncheckedCount == 0
        )
    }

    /// Key sequence to move from the current cursor index to a target index.
    public static func keysToSelect(cursorIndex: Int, targetIndex: Int) -> [PilotTuiKey] {
        let delta = targetIndex - cursorIndex
        let step: PilotTuiKey = delta >= 0 ? .down : .up
        return Array(repeating: step, count: abs(delta)) + [.enter]
    }

    /// Key sequence to move from the final checked step to Submit and confirm.
    public static func keysToSubmit() -> [PilotTuiKey] {
        [.right, .enter]
    }

    /// Decides a safe key plan for selecting `targetNumber` in a parsed menu.
    public static func planSelection(
        menu: PilotTuiMenu,
        targetNumber: Int,
        confidence: Double,
        requiredConfidence: Double = 0.7
    ) -> PilotTuiPlan {
        guard let targetIndex = menu.options.firstIndex(where: { $0.number == targetNumber }) else {
            return .skip(reason: "target option \(targetNumber) not found")
        }

        let option = menu.options[targetIndex]
        guard option.isAutoSelectable else {
            if option.isFreeText {
                return .skip(reason: "free-text option is never auto-selected")
            }
            return .skip(reason: "escape option is never auto-selected")
        }

        guard confidence >= requiredConfidence else {
            return .escape(
                keys: [.escape],
                reason: "confidence \(confidence) below threshold \(requiredConfidence)"
            )
        }

        return .select(
            keys: keysToSelect(cursorIndex: menu.cursorIndex, targetIndex: targetIndex),
            targetNumber: targetNumber
        )
    }

    private static func hasFooter(_ line: String) -> Bool {
        line.contains("Enter to select") && line.contains("Esc to cancel")
    }

    private static func isRuleLine(_ line: String) -> Bool {
        let trimmed = line.pilotTrimmedWhitespace()
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" || $0 == "─" }
    }

    private static func parseOptionLine(_ line: String) -> ParsedOption? {
        var remainder = line[...]
        while remainder.first?.isWhitespace == true {
            remainder.removeFirst()
        }

        var hasCursor = false
        if remainder.first == "❯" {
            hasCursor = true
            remainder.removeFirst()
            while remainder.first?.isWhitespace == true {
                remainder.removeFirst()
            }
        }

        let digits = remainder.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        remainder.removeFirst(digits.count)

        guard remainder.first == "." else { return nil }
        remainder.removeFirst()
        guard remainder.first?.isWhitespace == true else { return nil }
        while remainder.first?.isWhitespace == true {
            remainder.removeFirst()
        }

        let label = String(remainder).pilotTrimmedWhitespace()
        guard !label.isEmpty else { return nil }
        return ParsedOption(number: number, label: label, hasCursor: hasCursor)
    }
}

private extension String {
    func normalizedTerminalLines() -> [String] {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    func pilotTrimmedWhitespace() -> String {
        trimmingCharacters(in: .whitespaces)
    }
}
