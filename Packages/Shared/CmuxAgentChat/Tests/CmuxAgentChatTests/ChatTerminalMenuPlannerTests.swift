import Testing

@testable import CmuxAgentChat

@Suite("ChatTerminalMenuPlanner")
struct ChatTerminalMenuPlannerTests {
    private static let single = [
        "transcript noise",
        "どの観点で深掘りしますか？",
        "",
        "  1. 未コミット変更の整理",
        "❯ 2. コード品質の全体監査",
        "  3. 検証だけ先に実行",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let multi = [
        "  some prior transcript line that must be ignored",
        "────────────────────────────────────────",
        "←  ☐ ship 유도  ☐ cleanup 방식  ✔ Submit  →",
        "",
        "State B のとき create-pr 유도 강도는?",
        "",
        "❯ 1. BLOCK 1회 + AskUserQuestion (권장)",
        "     Stop을 1회 차단하고 질문",
        "  2. 비차단 알림만",
        "  3. 강제 차단 (defer 없음)",
        "  4. Type something.",
        "────────────────────────────────────────",
        "  5. Chat about this",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let unnumbered = [
        "Which action should the agent take?",
        "› Fast path",
        "  Thorough path",
        "  Chat about this",
        "Press Enter to choose · ↑/↓ to navigate · Esc to go back",
    ].joined(separator: "\n")

    private static let parenthesized = [
        "Choose an Antigravity action",
        "  1) Inspect first",
        "❯ 2) Patch now",
        "  3) Chat about this",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let checkboxNumbered = [
        "Select Codex context to include",
        "  ☐ 1. Terminal output",
        "❯ ☑ 2) Recent diff",
        "  [ ] 3: Dependency notes",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let radioNumbered = [
        "Select Antigravity context to include",
        "  ○ 1. Terminal output",
        "❯ ● 2) Recent diff",
        "  ◉ 3: Dependency notes",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let bracketedNumbered = [
        "Choose an Antigravity action",
        "  [1] Inspect first",
        "❯ [2] Patch now",
        "  (3) Chat about this",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let escapeWordFooter = [
        "Choose a Codex follow-up",
        "  1. Inspect transcript",
        "❯ 2. Apply focused fix",
        "  3. Chat about this",
        "Enter to select · ↑/↓ to navigate · Escape to cancel",
    ].joined(separator: "\n")

    private static let returnWordFooter = [
        "Choose an Antigravity follow-up",
        "  1. Inspect transcript",
        "❯ 2. Apply focused fix",
        "  3. Chat about this",
        "Return to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let controlCancelFooter = [
        "Choose a Codex follow-up",
        "  1. Inspect transcript",
        "❯ 2. Apply focused fix",
        "  3. Chat about this",
        "Enter to select · ↑/↓ to navigate · Ctrl+C to cancel",
    ].joined(separator: "\n")

    private static let arrowCursorQuitFooter = [
        "Choose an Antigravity follow-up",
        "  1. Inspect transcript",
        "→ 2. Apply focused fix",
        "  3. Chat about this",
        "Enter to select · ↑/↓ to navigate · Ctrl+C to quit",
    ].joined(separator: "\n")

    private static let iconCursorExitFooter = [
        "Choose a Codex follow-up",
        "  1. Inspect transcript",
        "▶ 2. Apply focused fix",
        "  3. Chat about this",
        "Return to choose · ↑/↓ to navigate · Esc to exit",
    ].joined(separator: "\n")

    private static let qQuitFooter = [
        "Choose an Antigravity follow-up",
        "  1. Inspect transcript",
        "❯ 2. Apply focused fix",
        "  3. Chat about this",
        "Enter to select · ↑/↓ to navigate · q to quit",
    ].joined(separator: "\n")

    private static let compactColonFooter = [
        "Choose a Codex follow-up",
        "  1. Inspect transcript",
        "❯ 2. Apply focused fix",
        "  3. Chat about this",
        "Enter: select · ↑/↓ navigate · q: quit",
    ].joined(separator: "\n")

    private static let equalsFooter = [
        "Choose an Antigravity follow-up",
        "  1. Inspect transcript",
        "❯ 2. Apply focused fix",
        "  3. Chat about this",
        "Enter = select · ↑/↓ navigate · Esc = cancel",
    ].joined(separator: "\n")

    private static let compactDelimiterFooter = [
        "Choose a Codex follow-up",
        "  1. Inspect transcript",
        "❯ 2. Apply focused fix",
        "  3. Chat about this",
        "Return:confirm · ↑/↓ navigate · Ctrl+C=abort",
    ].joined(separator: "\n")

    private static let readyToSubmit = [
        "下記の進路を選んでください:",
        "────────────────────────────────────────",
        "←  ✔ Ship可否  ✔ 60s閾値  ✔ Submit  →",
        "",
        "すべての項目を確認しました。",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitPlainCheck = [
        "Confirm the Codex action plan:",
        "←  ✓ Review scope  ✓ Verify tests  ✓ Submit  →",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitLowercaseLabel = [
        "Confirm the Antigravity action plan:",
        "←  ✓ Review scope  ✓ Verify tests  ✓ submit  →",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitReturnFooter = [
        "Confirm the Antigravity action plan:",
        "←  ✓ Review scope  ✓ Verify tests  ✓ Submit  →",
        "Return to submit · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitEmojiCheck = [
        "Confirm the Antigravity action plan:",
        "←  ✅ Review scope  ✅ Verify tests  ✅ Submit  →",
        "Return to submit · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitCheckboxCheck = [
        "Confirm the Codex action plan:",
        "←  ☑ Review scope  ☑ Verify tests  ☑ Submit  →",
        "Enter to submit · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitRadioCheck = [
        "Confirm the Antigravity action plan:",
        "←  ● Review scope  ● Verify tests  ● Submit  →",
        "Enter to submit · Tab/Arrow keys to navigate · Ctrl+C to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitParenthesizedCheck = [
        "Confirm the Codex action plan:",
        "←  (*) Review scope  (*) Verify tests  (*) Submit  →",
        "Return to submit · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let readyToSubmitBracketed = [
        "Confirm the Antigravity action plan:",
        "←  [x] Review scope  [x] Verify tests  [x] Submit  →",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let pendingSubmitRadioCheck = [
        "Confirm the Antigravity action plan:",
        "←  ● Review scope  ○ Verify tests  ● Submit  →",
        "Enter to submit · Tab/Arrow keys to navigate · Ctrl+C to cancel",
    ].joined(separator: "\n")

    private static let pendingSubmitParenthesizedCheck = [
        "Confirm the Codex action plan:",
        "←  (*) Review scope  ( ) Verify tests  (*) Submit  →",
        "Return to submit · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let pendingSubmitBracketed = [
        "Confirm the Antigravity action plan:",
        "←  [x] Review scope  [ ] Verify tests  [x] Submit  →",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let manyNumbered = ([
        "Pick a worktree action",
    ] + (1...12).map { number in
        number == 10 ? "❯ \(number). Option \(number)" : "  \(number). Option \(number)"
    } + [
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]).joined(separator: "\n")

    private static let ellipsisFreeText = [
        "Choose a Codex follow-up",
        "  1. Inspect transcript",
        "❯ 2. TYPE SOMETHING…",
        "  3. Chat about this",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private static let customResponseFreeText = [
        "Choose an Antigravity follow-up",
        "❯ 1. Inspect transcript",
        "  2. Custom response",
        "  3. Other…",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    @Test("parses a single-select menu")
    func parsesSingleSelectMenu() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.single))

        #expect(menu.question == "どの観点で深掘りしますか？")
        #expect(menu.options.count == 3)
        #expect(menu.options[0].number == 1)
        #expect(menu.options[1].label == "コード品質の全体監査")
        #expect(menu.cursorIndex == 1)
        #expect(menu.hasSubmitBar == false)
    }

    @Test("parses the last multi-select menu and flags escape rows")
    func parsesLastMultiSelectMenu() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.single + "\n\n" + Self.multi))

        #expect(menu.question == "State B のとき create-pr 유도 강도는?")
        #expect(menu.options.map(\.number) == [1, 2, 3, 4, 5])
        #expect(menu.options[3].isFreeText)
        #expect(menu.options[4].isEscape)
        #expect(menu.cursorIndex == 0)
        #expect(menu.hasSubmitBar)
    }

    @Test("parses unnumbered cursor menus")
    func parsesUnnumberedCursorMenu() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.unnumbered))

        #expect(menu.question == "Which action should the agent take?")
        #expect(menu.options.map(\.number) == [1, 2, 3])
        #expect(menu.options.map(\.label) == ["Fast path", "Thorough path", "Chat about this"])
        #expect(menu.options[2].isEscape)
        #expect(menu.cursorIndex == 0)
    }

    @Test("parses parenthesized option numbers with clean labels")
    func parsesParenthesizedOptionNumbers() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.parenthesized))

        #expect(menu.question == "Choose an Antigravity action")
        #expect(menu.options.map(\.number) == [1, 2, 3])
        #expect(menu.options.map(\.label) == ["Inspect first", "Patch now", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.parenthesized, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses checkbox-marked option numbers with clean labels")
    func parsesCheckboxMarkedOptionNumbers() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.checkboxNumbered))

        #expect(menu.question == "Select Codex context to include")
        #expect(menu.options.map(\.number) == [1, 2, 3])
        #expect(menu.options.map(\.label) == ["Terminal output", "Recent diff", "Dependency notes"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.checkboxNumbered, optionIndex: 2))
        #expect(plan.targetNumber == 3)
        #expect(plan.keys == ["down", "enter"])
    }

    @Test("parses radio-marked option numbers with clean labels")
    func parsesRadioMarkedOptionNumbers() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.radioNumbered))

        #expect(menu.question == "Select Antigravity context to include")
        #expect(menu.options.map(\.number) == [1, 2, 3])
        #expect(menu.options.map(\.label) == ["Terminal output", "Recent diff", "Dependency notes"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.radioNumbered, optionIndex: 2))
        #expect(plan.targetNumber == 3)
        #expect(plan.keys == ["down", "enter"])
    }

    @Test("parses bracketed option numbers with clean labels")
    func parsesBracketedOptionNumbers() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.bracketedNumbered))

        #expect(menu.question == "Choose an Antigravity action")
        #expect(menu.options.map(\.number) == [1, 2, 3])
        #expect(menu.options.map(\.label) == ["Inspect first", "Patch now", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.bracketedNumbered, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses menus whose footer spells out Escape")
    func parsesEscapeWordFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.escapeWordFooter))

        #expect(menu.question == "Choose a Codex follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.escapeWordFooter, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses menus whose footer says Return instead of Enter")
    func parsesReturnWordFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.returnWordFooter))

        #expect(menu.question == "Choose an Antigravity follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.returnWordFooter, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses menus whose footer uses Ctrl+C as the cancel hint")
    func parsesControlCancelFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.controlCancelFooter))

        #expect(menu.question == "Choose a Codex follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.controlCancelFooter, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses arrow cursor menus whose footer says quit")
    func parsesArrowCursorQuitFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.arrowCursorQuitFooter))

        #expect(menu.question == "Choose an Antigravity follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.arrowCursorQuitFooter, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses icon cursor menus whose footer says exit")
    func parsesIconCursorExitFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.iconCursorExitFooter))

        #expect(menu.question == "Choose a Codex follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.iconCursorExitFooter, optionIndex: 2))
        #expect(plan.targetNumber == 3)
        #expect(plan.keys == ["down", "enter"])
    }

    @Test("parses menus whose footer uses q as the quit hint")
    func parsesQQuitFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.qQuitFooter))

        #expect(menu.question == "Choose an Antigravity follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.qQuitFooter, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses menus whose footer uses compact colon hints")
    func parsesCompactColonFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.compactColonFooter))

        #expect(menu.question == "Choose a Codex follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.compactColonFooter, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses menus whose footer uses equals hints")
    func parsesEqualsFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.equalsFooter))

        #expect(menu.question == "Choose an Antigravity follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.equalsFooter, optionIndex: 0))
        #expect(plan.targetNumber == 1)
        #expect(plan.keys == ["up", "enter"])
    }

    @Test("parses menus whose footer uses compact delimiter hints")
    func parsesCompactDelimiterFooter() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.compactDelimiterFooter))

        #expect(menu.question == "Choose a Codex follow-up")
        #expect(menu.options.map(\.label) == ["Inspect transcript", "Apply focused fix", "Chat about this"])
        #expect(menu.cursorIndex == 1)

        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.compactDelimiterFooter, optionIndex: 2))
        #expect(plan.targetNumber == 3)
        #expect(plan.keys == ["down", "enter"])
    }

    @Test("plans submit keys only when a submit bar has no unchecked steps")
    func plansCompletedSubmitBar() {
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.multi) == nil)
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmit) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitPlainCheck) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitLowercaseLabel) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitReturnFooter) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitEmojiCheck) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitCheckboxCheck) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitRadioCheck) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitParenthesizedCheck) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.pendingSubmitRadioCheck) == nil)
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.pendingSubmitParenthesizedCheck) == nil)
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.pendingSubmitBracketed) == nil)
        #expect(ChatTerminalMenuPlanner.submitPlan(screen: Self.readyToSubmitBracketed) == ["right", "enter"])
        #expect(ChatTerminalMenuPlanner.keysToSubmit() == ["right", "enter"])
    }

    @Test("plans named keys from the visible cursor to the requested option")
    func plansSelectionKeys() throws {
        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.multi, optionIndex: 2))

        #expect(plan.targetNumber == 3)
        #expect(plan.keys == ["down", "down", "enter"])
    }

    @Test("plans keys to enter the visible free-text option")
    func plansFreeTextSelectionKeys() throws {
        let plan = try #require(ChatTerminalMenuPlanner.freeTextSelectionPlan(screen: Self.multi))

        #expect(plan.targetNumber == 4)
        #expect(plan.keys == ["down", "down", "down", "enter"])
        #expect(ChatTerminalMenuPlanner.freeTextSelectionPlan(screen: Self.single) == nil)
    }

    @Test("recognizes case-insensitive ellipsis free-text menu rows")
    func plansEllipsisFreeTextSelectionKeys() throws {
        let plan = try #require(ChatTerminalMenuPlanner.freeTextSelectionPlan(screen: Self.ellipsisFreeText))

        #expect(plan.targetNumber == 2)
        #expect(plan.keys == ["enter"])
    }

    @Test("recognizes custom response and other free-text menu rows")
    func plansCustomResponseFreeTextSelectionKeys() throws {
        let menu = try #require(ChatTerminalMenuPlanner.parseMenu(screen: Self.customResponseFreeText))

        #expect(menu.options[1].isFreeText)
        #expect(menu.options[2].isFreeText)

        let plan = try #require(ChatTerminalMenuPlanner.freeTextSelectionPlan(screen: Self.customResponseFreeText))
        #expect(plan.targetNumber == 2)
        #expect(plan.keys == ["down", "enter"])
    }

    @Test("plans unnumbered menu selections by display index")
    func plansUnnumberedSelectionKeys() throws {
        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.unnumbered, optionIndex: 1))

        #expect(plan.targetNumber == 2)
        #expect(plan.keys == ["down", "enter"])
    }

    @Test("plans numbered selections above the digit fallback range")
    func plansDoubleDigitSelectionKeys() throws {
        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.manyNumbered, optionIndex: 11))

        #expect(plan.targetNumber == 12)
        #expect(plan.keys == ["down", "down", "enter"])
    }

    @Test("plans enter only when the cursor is already on the option")
    func plansAlreadySelectedOption() throws {
        let plan = try #require(ChatTerminalMenuPlanner.selectionPlan(screen: Self.single, optionIndex: 1))

        #expect(plan.targetNumber == 2)
        #expect(plan.keys == ["enter"])
    }

    @Test("falls back when no menu or target option exists")
    func noPlanForNonMenuOrUnknownOption() {
        #expect(ChatTerminalMenuPlanner.selectionPlan(screen: "plain transcript", optionIndex: 0) == nil)
        #expect(ChatTerminalMenuPlanner.selectionPlan(screen: Self.single, optionIndex: 8) == nil)
        #expect(ChatTerminalMenuPlanner.parseMenu(screen: "Enter to select · ↑/↓ to navigate · Esc to cancel") == nil)
    }

    @Test("requires a cursor so stale numbered output is not mistaken for a live menu")
    func requiresCursor() {
        let noCursor = [
            "pick",
            "  1. a",
            "  2. b",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ].joined(separator: "\n")

        #expect(ChatTerminalMenuPlanner.parseMenu(screen: noCursor) == nil)
    }
}
