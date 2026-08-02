import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The sidebar showed a bare spinner and the tab bar a bare title, so a
/// restored workspace could not answer "which CLI, in what state, and what did
/// it last say". These cover the value logic behind the badge strip and the
/// CLI-named tab marker.
final class AgentSurfaceStatusSummaryTests: XCTestCase {

    // MARK: - Display names

    func testDisplayNameMapsTheClaudeStatusKeyToItsDefinition() {
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "claude_code"), "Claude Code")
        XCTAssertEqual(AgentStatusKeyDisplayName.shortDisplayName(forStatusKey: "claude_code"), "Claude")
    }

    func testDisplayNameMatchesDefinitionIdsDirectly() {
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "codex"), "Codex")
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "rovodev"), "Rovo Dev")
    }

    func testDisplayNameStripsThePIDDiscriminator() {
        // PID keys arrive as `<statusKey>.<pid>`; the CLI name must survive it.
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "claude_code.4821"), "Claude Code")
    }

    func testDisplayNameTitleCasesAnUnknownKey() {
        // A CLI can report a status key before it has a coding-agent
        // definition; showing `some_new_cli` raw would leak a wire identifier.
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "some_new_cli"), "Some New Cli")
    }

    func testDisplayNameUnwrapsTheAgentChatWriterNamespace() {
        // The chat mirror writes `agentchat.<cli>`, so the CLI is the tail of
        // the key. Taking the head named the writer: "Agentchat", not "Codex".
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "agentchat.codex"), "Codex")
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "agentchat.claude"), "Claude Code")
    }

    func testDisplayNameKeepsANamespaceLikeKeyWithNoTail() {
        // A malformed `agentchat.` must not resolve to an empty name.
        XCTAssertEqual(AgentStatusKeyDisplayName.displayName(forStatusKey: "agentchat."), "Agentchat")
    }

    func testCanonicalDefinitionIdFoldsEveryWriterOfOneCLI() {
        // Hook key, PID-suffixed key and chat-mirror key are three spellings of
        // one CLI; grouping on anything else would draw three "Claude Code"
        // pills for one agent.
        XCTAssertEqual(AgentStatusKeyDisplayName.canonicalDefinitionId(forStatusKey: "claude_code"), "claude")
        XCTAssertEqual(AgentStatusKeyDisplayName.canonicalDefinitionId(forStatusKey: "claude_code.4821"), "claude")
        XCTAssertEqual(AgentStatusKeyDisplayName.canonicalDefinitionId(forStatusKey: "agentchat.claude"), "claude")
        XCTAssertEqual(AgentStatusKeyDisplayName.canonicalDefinitionId(forStatusKey: "antigravity.tui"), "antigravity")
    }

    // MARK: - Per-surface resolution

    func testResolveNamesTheRunningAgentWhenTwoShareASurface() {
        let summary = AgentSurfaceStatusSummary.resolve(
            lifecycleStates: ["codex": .idle, "claude_code": .running],
            hasBeenActive: true
        )

        XCTAssertEqual(summary?.status, .running)
        XCTAssertEqual(summary?.agentKey, "claude_code")
        XCTAssertEqual(summary?.isRestored, false)
    }

    func testResolveIgnoresManualWorkspaceLoaders() {
        XCTAssertNil(AgentSurfaceStatusSummary.resolve(
            lifecycleStates: ["manual:deploy": .running],
            hasBeenActive: true
        ))
    }

    func testResolveCarriesTheLastMessage() {
        let summary = AgentSurfaceStatusSummary.resolve(
            lifecycleStates: ["codex": .idle],
            hasBeenActive: true,
            lastMessage: "Refactored the parser"
        )

        XCTAssertEqual(summary?.status, .done)
        XCTAssertEqual(summary?.lastMessage, "Refactored the parser")
    }

    // MARK: - Badge aggregation

    func testBadgesAreOrderedWorkingDoneIdleWithCounts() {
        let badges = AgentStatusBadgeSummary.badges(from: [
            summary(.idle),
            summary(.done),
            summary(.running),
            summary(.done),
        ])

        XCTAssertEqual(badges.map(\.status), [.running, .done, .idle])
        XCTAssertEqual(badges.map(\.count), [1, 2, 1])
    }

    func testBadgesOmitStatusesWithNoSurfaces() {
        let badges = AgentStatusBadgeSummary.badges(from: [summary(.running)])

        XCTAssertEqual(badges.map(\.status), [.running])
    }

    func testABadgeIsRestoredOnlyWhenEverySurfaceBehindItIs() {
        // One live agent in the group means the count is live data; dimming it
        // would understate a running turn.
        let badges = AgentStatusBadgeSummary.badges(from: [
            summary(.done, isRestored: true),
            summary(.done, isRestored: false),
            summary(.idle, isRestored: true),
        ])

        XCTAssertEqual(badges.first { $0.status == .done }?.isRestored, false)
        XCTAssertEqual(badges.first { $0.status == .idle }?.isRestored, true)
    }

    func testEmptySummariesProduceNoBadges() {
        XCTAssertTrue(AgentStatusBadgeSummary.badges(from: []).isEmpty)
    }

    // MARK: - Per-CLI grouping

    func testCLIGroupsSplitTheWorkspacePerCLI() {
        // The whole point: three terminals running three CLIs must read as
        // three pills, not one merged count that cannot say which CLI is which.
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.running, agentKey: "codex"),
            summary(.done, agentKey: "claude_code"),
            summary(.done, agentKey: "claude_code"),
            summary(.idle, agentKey: "antigravity"),
        ])

        XCTAssertEqual(groups.map(\.agentKey), ["codex", "claude", "antigravity"])
        XCTAssertEqual(groups.map(\.displayName), ["Codex", "Claude Code", "Antigravity"])
        XCTAssertEqual(groups.map(\.surfaceCount), [1, 2, 1])
    }

    func testACLIGroupKeepsItsOwnPerStatusCounts() {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.done, agentKey: "codex"),
            summary(.running, agentKey: "codex"),
            summary(.done, agentKey: "codex"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].badges.map(\.status), [.running, .done])
        XCTAssertEqual(groups[0].badges.map(\.count), [1, 2])
        XCTAssertEqual(groups[0].leadingStatus, .running)
    }

    func testCLIGroupsRankTheMostActionableCLIFirst() {
        // "Nothing running anywhere" has to be readable off the leading pill,
        // so a working CLI outranks a finished one regardless of surface count.
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.done, agentKey: "claude_code"),
            summary(.done, agentKey: "claude_code"),
            summary(.done, agentKey: "claude_code"),
            summary(.running, agentKey: "codex"),
            summary(.idle, agentKey: "antigravity"),
        ])

        XCTAssertEqual(groups.map(\.agentKey), ["codex", "claude", "antigravity"])
    }

    func testCLIGroupsBreakTiesOnSurfaceCountThenKey() {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.running, agentKey: "codex"),
            summary(.running, agentKey: "gemini"),
            summary(.running, agentKey: "gemini"),
            summary(.running, agentKey: "amp"),
        ])

        // gemini leads on count; codex beats amp only after the count tie.
        XCTAssertEqual(groups.map(\.agentKey), ["gemini", "amp", "codex"])
    }

    func testCLIGroupsFoldEveryWriterOfOneCLIIntoOneGroup() {
        // A PID restart and the chat mirror must not mint extra "Claude Code"
        // groups — that would also make the sidebar snapshot compare unequal on
        // a tick where nothing user-visible changed.
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.done, agentKey: "claude_code.4821"),
            summary(.done, agentKey: "claude_code.5102"),
            summary(.done, agentKey: "agentchat.claude"),
        ])

        XCTAssertEqual(groups.map(\.agentKey), ["claude"])
        XCTAssertEqual(groups[0].surfaceCount, 3)
    }

    func testACLIGroupIsRestoredOnlyWhenEverySurfaceBehindItIs() {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.done, agentKey: "codex", isRestored: true),
            summary(.idle, agentKey: "codex", isRestored: true),
            summary(.done, agentKey: "claude_code", isRestored: true),
            summary(.running, agentKey: "claude_code", isRestored: false),
        ])

        XCTAssertEqual(groups.first { $0.agentKey == "codex" }?.isRestored, true)
        XCTAssertEqual(groups.first { $0.agentKey == "claude" }?.isRestored, false)
    }

    func testEmptySummariesProduceNoCLIGroups() {
        XCTAssertTrue(AgentStatusBadgeSummary.cliGroups(from: []).isEmpty)
    }

    // MARK: - Strip text

    func testPillTextNamesTheCLIBeforeItsCounts() {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.running, agentKey: "claude_code"),
            summary(.running, agentKey: "claude_code"),
            summary(.done, agentKey: "claude_code"),
        ])

        XCTAssertEqual(SidebarAgentStatusBadgeText.pillText(for: groups[0]), "Claude ⚡2 ✅1")
    }

    // The tooltip and accessibility strings are localized, so they are asserted
    // structurally: pinning the English wording would fail on a Japanese
    // machine even though the code is correct.

    func testTooltipSpellsOutTheCLIAndEveryStatus() {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.running, agentKey: "codex"),
            summary(.idle, agentKey: "codex"),
        ])

        let tooltip = SidebarAgentStatusBadgeText.tooltip(for: groups[0])
        XCTAssertTrue(tooltip.hasPrefix("Codex "), tooltip)
        XCTAssertTrue(tooltip.contains(AgentTabTitleStatus.running.badgeLabel), tooltip)
        XCTAssertTrue(tooltip.contains(AgentTabTitleStatus.idle.badgeLabel), tooltip)
        XCTAssertFalse(tooltip.contains(AgentTabTitleStatus.done.badgeLabel), tooltip)
    }

    func testTooltipMarksAFullyRestoredCLI() {
        let restored = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.done, agentKey: "codex", isRestored: true),
        ])
        let live = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.done, agentKey: "codex", isRestored: false),
        ])

        let restoredTooltip = SidebarAgentStatusBadgeText.tooltip(for: restored[0])
        let liveTooltip = SidebarAgentStatusBadgeText.tooltip(for: live[0])
        XCTAssertNotEqual(restoredTooltip, liveTooltip)
        XCTAssertTrue(restoredTooltip.hasPrefix(liveTooltip), restoredTooltip)
    }

    func testAccessibilityLabelNamesEveryCLI() {
        let groups = AgentStatusBadgeSummary.cliGroups(from: [
            summary(.running, agentKey: "codex"),
            summary(.done, agentKey: "claude_code"),
        ])

        let label = SidebarAgentStatusBadgeText.accessibilityLabel(for: groups)
        XCTAssertTrue(label.contains("Codex"), label)
        XCTAssertTrue(label.contains("Claude Code"), label)
        XCTAssertTrue(label.contains(AgentTabTitleStatus.running.badgeLabel), label)
        XCTAssertTrue(label.contains(AgentTabTitleStatus.done.badgeLabel), label)
    }

    // MARK: - Latest output

    func testLatestOutputPrefersAWorkingSurface() {
        let output = AgentStatusBadgeSummary.latestOutput(from: [
            summary(.done, lastMessage: "finished earlier"),
            summary(.running, lastMessage: "still working"),
        ])

        XCTAssertEqual(output, "still working")
    }

    func testLatestOutputFallsBackToADoneSurface() {
        let output = AgentStatusBadgeSummary.latestOutput(from: [
            summary(.idle, lastMessage: "never ran but has text"),
            summary(.done, lastMessage: "finished"),
        ])

        XCTAssertEqual(output, "finished")
    }

    func testLatestOutputIsNilWithoutAnyMessage() {
        XCTAssertNil(AgentStatusBadgeSummary.latestOutput(from: [summary(.running)]))
    }

    // MARK: - Tab title

    func testDecorateStampsTheCLINameBeforeTheTitle() {
        let title = AgentTabTitleStatus.decorate(
            title: "cmux-fork",
            status: .running,
            agentName: "Claude"
        )

        XCTAssertEqual(title, "⚡ Claude · cmux-fork")
    }

    func testDecorateSkipsARedundantCLIName() {
        // The process title is often already the CLI's own name; repeating it
        // would render "⚡ Codex · codex".
        let title = AgentTabTitleStatus.decorate(
            title: "codex",
            status: .done,
            agentName: "Codex"
        )

        XCTAssertEqual(title, "✅ codex")
    }

    func testDecorateIsIdempotentWithACLIName() {
        let once = AgentTabTitleStatus.decorate(title: "cmux-fork", status: .running, agentName: "Claude")
        let twice = AgentTabTitleStatus.decorate(title: once, status: .running, agentName: "Claude")
        let flipped = AgentTabTitleStatus.decorate(title: once, status: .done, agentName: "Claude")

        XCTAssertEqual(twice, "⚡ Claude · cmux-fork")
        XCTAssertEqual(flipped, "✅ Claude · cmux-fork")
    }

    func testUndecorateStripsTheCLINameSegment() {
        XCTAssertEqual(AgentTabTitleStatus.undecorated("⚡ Claude · cmux-fork"), "cmux-fork")
    }

    func testUndecorateLeavesAMiddleDotThatIsNotAMarkerSegment() {
        // Only the segment introduced by a status marker is owned by cmux; a
        // user title containing "·" must round-trip unchanged.
        XCTAssertEqual(AgentTabTitleStatus.undecorated("api · staging"), "api · staging")
    }

    // MARK: - Helpers

    private func summary(
        _ status: AgentTabTitleStatus,
        agentKey: String = "claude_code",
        isRestored: Bool = false,
        lastMessage: String? = nil
    ) -> AgentSurfaceStatusSummary {
        AgentSurfaceStatusSummary(
            status: status,
            agentKey: agentKey,
            isRestored: isRestored,
            lastMessage: lastMessage
        )
    }
}
