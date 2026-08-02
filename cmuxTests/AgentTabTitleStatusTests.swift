import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Surface tabs carried no agent status at all: a running agent and a finished
/// one looked identical in the tab bar. These cover the marker resolution and
/// the decorate/undecorate round-trip a rename has to survive.
final class AgentTabTitleStatusTests: XCTestCase {
    func testNoAgentYieldsNoMarker() {
        XCTAssertNil(AgentTabTitleStatus.resolve(lifecycleStates: [:], hasBeenActive: false))
    }

    func testManualWorkspaceLoaderIsNotAnAgent() {
        // `cmux workspace loading` raises a spinner on a plain shell tab; that
        // must not brand the tab as a running agent.
        let status = AgentTabTitleStatus.resolve(
            lifecycleStates: ["manual:deploy": .running],
            hasBeenActive: true
        )

        XCTAssertNil(status)
    }

    func testRunningAgentIsRunning() {
        let status = AgentTabTitleStatus.resolve(
            lifecycleStates: ["claude_code": .running],
            hasBeenActive: true
        )

        XCTAssertEqual(status, .running)
    }

    func testNeedsInputCountsAsRunning() {
        // Agent Studio folds a pending permission prompt into the working
        // marker; a tab that flips to Done while blocked would read as finished.
        let status = AgentTabTitleStatus.resolve(
            lifecycleStates: ["codex": .needsInput],
            hasBeenActive: true
        )

        XCTAssertEqual(status, .running)
    }

    func testRunningOutranksIdleAcrossKeys() {
        let status = AgentTabTitleStatus.resolve(
            lifecycleStates: ["codex": .idle, "agentchat.codex": .running],
            hasBeenActive: true
        )

        XCTAssertEqual(status, .running)
    }

    func testIdleAfterWorkIsDone() {
        let status = AgentTabTitleStatus.resolve(
            lifecycleStates: ["claude_code": .idle],
            hasBeenActive: true
        )

        XCTAssertEqual(status, .done)
    }

    func testIdleWithoutPriorWorkIsIdle() {
        let status = AgentTabTitleStatus.resolve(
            lifecycleStates: ["claude_code": .idle],
            hasBeenActive: false
        )

        XCTAssertEqual(status, .idle)
    }

    func testDecoratePrependsTheMarker() {
        XCTAssertEqual(AgentTabTitleStatus.decorate(title: "claude", status: .running), "⚡ claude")
        XCTAssertEqual(AgentTabTitleStatus.decorate(title: "codex", status: .done), "✅ codex")
    }

    func testDecorateIsIdempotentAndReplacesAStaleMarker() {
        let once = AgentTabTitleStatus.decorate(title: "claude", status: .running)
        let twice = AgentTabTitleStatus.decorate(title: once, status: .running)
        let flipped = AgentTabTitleStatus.decorate(title: once, status: .done)

        XCTAssertEqual(twice, "⚡ claude")
        XCTAssertEqual(flipped, "✅ claude")
    }

    func testDecorateWithNoStatusStripsAnExistingMarker() {
        let stripped = AgentTabTitleStatus.decorate(title: "✅ codex", status: nil)

        XCTAssertEqual(stripped, "codex")
    }

    func testUndecoratedToleratesAMissingSeparator() {
        XCTAssertEqual(AgentTabTitleStatus.undecorated("⚡claude"), "claude")
        XCTAssertEqual(AgentTabTitleStatus.undecorated("plain title"), "plain title")
    }

    func testUndecoratedLeavesAnEmojiThatIsNotAMarker() {
        XCTAssertEqual(AgentTabTitleStatus.undecorated("🚀 deploy"), "🚀 deploy")
    }
}
