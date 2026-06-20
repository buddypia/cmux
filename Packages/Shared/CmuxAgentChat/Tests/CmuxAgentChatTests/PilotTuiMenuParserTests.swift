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

    private let shipStep = [
        "下記の進路を選んでください:",
        "────────────────────────────────────────",
        "←  ☐ Ship可否  ☐ 60s閾値  ✔ Submit  →",
        "",
        "ship を進めますか？",
        "",
        "❯ 1. 進行",
        "  2. とどまる",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    ].joined(separator: "\n")

    private let thresholdStep = [
        "下記の進路を選んでください:",
        "────────────────────────────────────────",
        "←  ✔ Ship可否  ☐ 60s閾値  ✔ Submit  →",
        "",
        "60s 閾値を使いますか？",
        "",
        "❯ 1. 使う",
        "  2. 使わない",
        "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
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

    @Test("surface key alphabet mirrors the backend-neutral Pilot contract")
    func surfaceKeyAlphabet() {
        #expect(PilotTuiKey.allCases.map(\.rawValue) == [
            "up",
            "down",
            "left",
            "right",
            "enter",
            "escape",
            "tab",
            "backspace",
            "0",
            "1",
            "2",
            "3",
            "4",
            "5",
            "6",
            "7",
            "8",
            "9",
        ])
    }

    @Test("surface driver contract is implementable by async backends")
    func surfaceDriverContract() async throws {
        let driver = RecordingPilotSurfaceDriver(screen: "screen")
        let text = try await driver.readScreen(options: PilotTuiSurfaceReadOptions(lines: 120))
        try await driver.sendKey(.enter)
        try await driver.sendText("continue\n")
        try await driver.notify(PilotTuiSurfaceNotification(title: "Pilot Mode", body: "sent"))

        #expect(text == "screen")
        #expect(driver.readLineCounts == [120])
        #expect(driver.keys == [.enter])
        #expect(driver.sentTexts == ["continue\n"])
        #expect(driver.notifications == [
            PilotTuiSurfaceNotification(title: "Pilot Mode", body: "sent"),
        ])
    }

    @Test("auto selector reads the screen and sends planned selection keys")
    func autoSelectorSendsSelectionKeys() async throws {
        let driver = RecordingPilotSurfaceDriver(screen: multi)
        let result = try await PilotTuiAutoSelector.run(
            driver: driver,
            request: PilotTuiAutoSelectRequest(targetNumber: 3, confidence: 0.9, readLines: 80)
        )

        #expect(result == .selected(targetNumber: 3, keys: [.down, .down, .enter]))
        #expect(driver.readLineCounts == [80])
        #expect(driver.keys == [.down, .down, .enter])
    }

    @Test("auto selector confirms a ready submit bar before choosing an option")
    func autoSelectorSubmitsReadyBar() async throws {
        let driver = RecordingPilotSurfaceDriver(screen: preShipReady)
        let result = try await PilotTuiAutoSelector.run(
            driver: driver,
            request: PilotTuiAutoSelectRequest(targetNumber: nil, confidence: 0)
        )

        #expect(result == .submitted(keys: [.right, .enter]))
        #expect(driver.keys == [.right, .enter])
    }

    @Test("auto selector presses escape on low-confidence menu choices")
    func autoSelectorEscapesLowConfidence() async throws {
        let driver = RecordingPilotSurfaceDriver(screen: multi)
        let result = try await PilotTuiAutoSelector.run(
            driver: driver,
            request: PilotTuiAutoSelectRequest(targetNumber: 2, confidence: 0.4)
        )

        guard case .escaped(let keys, _) = result else {
            Issue.record("expected escaped result")
            return
        }
        #expect(keys == [.escape])
        #expect(driver.keys == [.escape])
    }

    @Test("auto selector skips unsafe or missing decisions without sending keys")
    func autoSelectorSkipsWithoutKeys() async throws {
        let unsafe = RecordingPilotSurfaceDriver(screen: multi)
        let unsafeResult = try await PilotTuiAutoSelector.run(
            driver: unsafe,
            request: PilotTuiAutoSelectRequest(targetNumber: 4, confidence: 0.95)
        )
        guard case .skipped = unsafeResult else {
            Issue.record("expected unsafe option to be skipped")
            return
        }
        #expect(unsafe.keys.isEmpty)

        let missing = RecordingPilotSurfaceDriver(screen: single)
        let missingResult = try await PilotTuiAutoSelector.run(
            driver: missing,
            request: PilotTuiAutoSelectRequest(targetNumber: nil, confidence: 0.95)
        )
        guard case .skipped = missingResult else {
            Issue.record("expected missing target to be skipped")
            return
        }
        #expect(missing.keys.isEmpty)
    }

    @Test("auto selector loop advances submit-bar menus through multiple steps")
    func autoSelectorLoopSubmitsMultiStepForms() async throws {
        let driver = RecordingPilotSurfaceDriver(screens: [shipStep, thresholdStep, preShipReady])
        let decisions = PilotDecisionQueue([
            PilotTuiDecision(optionNumber: 1, confidence: 0.92, reason: "ship"),
            PilotTuiDecision(optionNumber: 2, confidence: 0.91, reason: "threshold"),
        ])

        let result = try await PilotTuiAutoSelector.runLoop(
            driver: driver,
            request: PilotTuiAutoSelectLoopRequest(settleDelayNanoseconds: 0),
            decide: { _, _ in await decisions.next() },
            sleep: { _ in }
        )

        #expect(result == .submitted(
            keys: [.enter, .down, .enter, .right, .enter],
            optionNumbers: [1, 2]
        ))
        #expect(driver.keys == [.enter, .down, .enter, .right, .enter])
        #expect(driver.readLineCounts == [120, 120, 120])
        #expect(await decisions.isEmpty())
    }

    @Test("auto selector loop stops stale submit-bar flows at the action limit")
    func autoSelectorLoopStopsAtActionLimit() async throws {
        let driver = RecordingPilotSurfaceDriver(screens: [shipStep, shipStep])
        let result = try await PilotTuiAutoSelector.runLoop(
            driver: driver,
            request: PilotTuiAutoSelectLoopRequest(maxMenuActions: 1, settleDelayNanoseconds: 0),
            decide: { _, _ in PilotTuiDecision(optionNumber: 1, confidence: 0.9, reason: "same") },
            sleep: { _ in }
        )

        #expect(result == .skipped(
            reason: "submit-bar action limit 1 reached",
            keys: [.enter],
            optionNumbers: [1]
        ))
        #expect(driver.keys == [.enter])
    }

    @Test("auto selector loop reports no menu before sending keys")
    func autoSelectorLoopReportsNoMenu() async throws {
        let driver = RecordingPilotSurfaceDriver(screen: "plain output")
        let result = try await PilotTuiAutoSelector.runLoop(
            driver: driver,
            decide: { _, _ in PilotTuiDecision(optionNumber: 1, confidence: 1, reason: "unused") },
            sleep: { _ in }
        )

        #expect(result == .noMenu)
        #expect(driver.keys.isEmpty)
    }

    @Test("inspector reports parsed menu and submit-bar status")
    func inspectorReportsMenuStatus() throws {
        let menuInspection = PilotTuiInspector.inspect(screen: multi)
        #expect(menuInspection.status == .menu)
        #expect(menuInspection.menu?.question == "State B のとき create-pr 유도 강도는?")
        #expect(menuInspection.menu?.options.map(\.number) == [1, 2, 3, 4, 5])
        #expect(menuInspection.submitBar?.isReadyToSubmit == false)

        let readyInspection = PilotTuiInspector.inspect(screen: preShipReady)
        #expect(readyInspection.status == .submitReady)
        #expect(readyInspection.submitBar?.isReadyToSubmit == true)

        let emptyInspection = PilotTuiInspector.inspect(screen: "plain terminal output")
        #expect(emptyInspection.status == .noMenu)
        #expect(emptyInspection.menu == nil)
        #expect(emptyInspection.submitBar == nil)
    }

    @Test("inspection encodes as stable JSON for CLI output")
    func inspectorCodableJSON() throws {
        let inspection = PilotTuiInspector.inspect(screen: single)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let data = try encoder.encode(inspection)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["status"] as? String == "menu")
        let menu = try #require(object["menu"] as? [String: Any])
        #expect(menu["question"] as? String == "どの観点で深掘りしますか？")
        #expect(menu["cursor_index"] as? Int == 1)
        let options = try #require(menu["options"] as? [[String: Any]])
        #expect(options.count == 3)
        #expect(options[1]["label"] as? String == "コード品質の全体監査")
    }

    @Test("menu matcher resolves exact and unique substring labels safely")
    func menuMatcherResolvesLabelsSafely() throws {
        let menu = try #require(PilotTuiMenuParser.parseMenu(screen: single))

        #expect(PilotTuiMenuMatcher.match(menu: menu, query: "コード品質の全体監査", confidence: 0.95) == .matched(
            PilotTuiDecision(optionNumber: 2, confidence: 0.95, reason: "matched exact option label")
        ))
        #expect(PilotTuiMenuMatcher.match(menu: menu, query: "検証", confidence: 0.91) == .matched(
            PilotTuiDecision(optionNumber: 3, confidence: 0.91, reason: "matched unique option label substring")
        ))
        #expect(PilotTuiMenuMatcher.match(menu: menu, query: "", confidence: 1) == .noMatch(reason: "empty match query"))
    }

    @Test("menu matcher skips unsafe options and ambiguous labels")
    func menuMatcherRejectsUnsafeAndAmbiguousChoices() throws {
        let menu = try #require(PilotTuiMenuParser.parseMenu(screen: multi))
        let duplicateMenu = PilotTuiMenu(
            question: "Pick one",
            options: [
                PilotTuiOption(number: 1, label: "Proceed"),
                PilotTuiOption(number: 2, label: "Proceed"),
            ],
            cursorIndex: 0,
            hasSubmitBar: false
        )

        #expect(PilotTuiMenuMatcher.match(menu: menu, query: "Type something", confidence: 1) == .noMatch(
            reason: "no safe option label matched query"
        ))
        #expect(PilotTuiMenuMatcher.match(menu: menu, query: "차단", confidence: 1) == .ambiguous(
            reason: "match query is ambiguous",
            optionNumbers: [2, 3]
        ))
        #expect(PilotTuiMenuMatcher.match(menu: duplicateMenu, query: "Proceed", confidence: 1) == .ambiguous(
            reason: "match query is ambiguous",
            optionNumbers: [1, 2]
        ))
    }

    @Test("auto matcher reads the screen and sends planned selection keys")
    func autoMatcherReadsAndSendsKeys() async throws {
        let driver = RecordingPilotSurfaceDriver(screen: single)

        let result = try await PilotTuiAutoSelector.runMatched(
            driver: driver,
            request: PilotTuiAutoMatchRequest(query: "検証", confidence: 0.95, readLines: 80)
        )

        #expect(result == .selected(targetNumber: 3, keys: [.down, .enter]))
        #expect(driver.readLineCounts == [80])
        #expect(driver.keys == [.down, .enter])
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

private final class RecordingPilotSurfaceDriver: PilotTuiSurfaceDriving, @unchecked Sendable {
    private let screens: [String]
    private var readIndex = 0
    private(set) var readLineCounts: [Int] = []
    private(set) var keys: [PilotTuiKey] = []
    private(set) var sentTexts: [String] = []
    private(set) var notifications: [PilotTuiSurfaceNotification] = []

    init(screen: String) {
        self.screens = [screen]
    }

    init(screens: [String]) {
        self.screens = screens
    }

    func readScreen(options: PilotTuiSurfaceReadOptions) async throws -> String {
        readLineCounts.append(options.lines)
        let index = min(readIndex, screens.count - 1)
        readIndex += 1
        return screens[index]
    }

    func sendKey(_ key: PilotTuiKey) async throws {
        keys.append(key)
    }

    func sendText(_ text: String) async throws {
        sentTexts.append(text)
    }

    func notify(_ notification: PilotTuiSurfaceNotification) async throws {
        notifications.append(notification)
    }
}

private actor PilotDecisionQueue {
    private var decisions: [PilotTuiDecision]

    init(_ decisions: [PilotTuiDecision]) {
        self.decisions = decisions
    }

    func next() -> PilotTuiDecision {
        decisions.removeFirst()
    }

    func isEmpty() -> Bool {
        decisions.isEmpty
    }
}
