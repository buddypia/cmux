import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("PilotTuiMenuParser")
struct PilotTuiMenuParserTests {
    private let multi = [
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

    private let single = [
        "transcript noise",
        "どの観点で深掘りしますか？",
        "",
        "  1. 未コミット変更の整理",
        "❯ 2. コード品質の全体監査",
        "  3. 検証だけ先に実行",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private let preShip = [
        "下記の進路を選んでください:",
        "────────────────────────────────────────",
        "←  ☐ Ship可否  ☐ 60s閾値  ✔ Submit  →",
        "",
        "Pre-Ship Review Panel を確認しました。ship を進めますか？",
        "",
        "❯ 1. 進行 (CONTEXT.json 更新して ship)",
        "     既存 feature の CONTEXT.json に 2 件の修正 decision を追記",
        "  2. 進行 (コードのみ ship)",
        "  3. とどまる (レビューしたい)",
        "  4. Type something.",
        "────────────────────────────────────────",
        "  5. Chat about this",
    ].joined(separator: "\n")

    private let preShipReady = [
        "下記の進路を選んでください:",
        "────────────────────────────────────────",
        "←  ✔ Ship可否  ✔ 60s閾値  ✔ Submit  →",
        "",
        "すべての項目を確認しました。",
    ].joined(separator: "\n")

    @Test("single-select menu parses the question, options, and cursor")
    func singleSelectMenu() throws {
        let menu = try #require(PilotTuiMenuParser.parseMenu(screen: single))
        #expect(menu.question == "どの観点で深掘りしますか？")
        #expect(menu.options.count == 3)
        #expect(menu.options[0].number == 1)
        #expect(menu.options[1].label == "コード品質の全体監査")
        #expect(menu.cursorIndex == 1)
        #expect(menu.hasSubmitBar == false)
    }

    @Test("multi-select menu parses despite variable footer wording")
    func multiSelectMenu() throws {
        let menu = try #require(PilotTuiMenuParser.parseMenu(screen: multi))
        #expect(menu.question == "State B のとき create-pr 유도 강도는?")
        #expect(menu.options.count == 5)
        #expect(menu.cursorIndex == 0)
        #expect(menu.hasSubmitBar)
    }

    @Test("submit-bar menus parse even when no footer is visible")
    func footerlessSubmitBarMenu() throws {
        let menu = try #require(PilotTuiMenuParser.parseMenu(screen: preShip))
        #expect(menu.question == "Pre-Ship Review Panel を確認しました。ship を進めますか？")
        #expect(menu.options.count == 5)
        #expect(menu.options[0].label == "進行 (CONTEXT.json 更新して ship)")
        #expect(menu.options[3].isFreeText)
        #expect(menu.options[4].isEscape)
        #expect(menu.hasSubmitBar)
    }

    @Test("the last menu block wins when multiple prompts are present")
    func lastMenuWins() throws {
        let menu = try #require(PilotTuiMenuParser.parseMenu(screen: single + "\n\n" + multi))
        #expect(menu.question == "State B のとき create-pr 유도 강도는?")
        #expect(menu.options.count == 5)
    }

    @Test("non-menus and incomplete menus return nil")
    func invalidMenus() {
        #expect(PilotTuiMenuParser.parseMenu(screen: "just terminal output") == nil)

        let oneOption = [
            "pick one",
            "❯ 1. only option",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ].joined(separator: "\n")
        #expect(PilotTuiMenuParser.parseMenu(screen: oneOption) == nil)

        let noCursor = [
            "pick",
            "  1. a",
            "  2. b",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ].joined(separator: "\n")
        #expect(PilotTuiMenuParser.parseMenu(screen: noCursor) == nil)
    }

    @Test("submit bars report unfinished and ready states")
    func submitBarStates() throws {
        let pending = try #require(PilotTuiMenuParser.parseSubmitBar(screen: preShip))
        #expect(pending.uncheckedCount == 2)
        #expect(pending.isReadyToSubmit == false)

        let ready = try #require(PilotTuiMenuParser.parseSubmitBar(screen: preShipReady))
        #expect(ready.uncheckedCount == 0)
        #expect(ready.isReadyToSubmit)
    }

    @Test("selection keys use send_key tokens only")
    func selectionKeys() {
        #expect(PilotTuiMenuParser.keysToSelect(cursorIndex: 0, targetIndex: 2) == [
            .down, .down, .enter,
        ])
        #expect(PilotTuiMenuParser.keysToSelect(cursorIndex: 3, targetIndex: 1) == [
            .up, .up, .enter,
        ])
        #expect(PilotTuiMenuParser.keysToSelect(cursorIndex: 2, targetIndex: 2) == [.enter])
        #expect(PilotTuiMenuParser.keysToSubmit() == [.right, .enter])
    }

    @Test("planning skips unsafe targets and escapes low-confidence guesses")
    func planningSafety() throws {
        let menu = try #require(PilotTuiMenuParser.parseMenu(screen: multi))

        let select = PilotTuiMenuParser.planSelection(menu: menu, targetNumber: 3, confidence: 0.9)
        guard case .select(let keys, let targetNumber) = select else {
            Issue.record("expected select plan")
            return
        }
        #expect(keys == [.down, .down, .enter])
        #expect(targetNumber == 3)

        guard case .skip = PilotTuiMenuParser.planSelection(
            menu: menu,
            targetNumber: 4,
            confidence: 0.95
        ) else {
            Issue.record("expected free-text option to be skipped")
            return
        }

        guard case .skip = PilotTuiMenuParser.planSelection(
            menu: menu,
            targetNumber: 5,
            confidence: 0.95
        ) else {
            Issue.record("expected escape option to be skipped")
            return
        }

        guard case .skip = PilotTuiMenuParser.planSelection(
            menu: menu,
            targetNumber: 99,
            confidence: 0.95
        ) else {
            Issue.record("expected unknown option to be skipped")
            return
        }

        guard case .escape(let keys, _) = PilotTuiMenuParser.planSelection(
            menu: menu,
            targetNumber: 2,
            confidence: 0.4
        ) else {
            Issue.record("expected low confidence to escape")
            return
        }
        #expect(keys == [.escape])

        guard case .select = PilotTuiMenuParser.planSelection(
            menu: menu,
            targetNumber: 2,
            confidence: 0.6,
            requiredConfidence: 0.5
        ) else {
            Issue.record("expected custom threshold to allow selection")
            return
        }
    }
}
