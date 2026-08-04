import CmuxTerminal
import Foundation
import Testing

/// cmux is normally launched *from* a cmux terminal — every
/// `reload.sh --launch` is exactly that — and a spawned surface's environment
/// starts from cmux's own. So when the launching terminal had an integration
/// off, cmux inherits that integration's `*_HOOKS_DISABLED=1` and hands it to
/// every terminal it spawns.
///
/// Nothing surfaces it. Settings, `~/.config/cmux/cmux.json`, and UserDefaults
/// all still read "on", the wrapper shim silently injects no hooks, and the
/// agent's remaining reporters — the process table and the transcript — can
/// prove an agent is *present* but never that a turn is *running*. The sidebar
/// then shows 💤 for the whole of a working turn.
@Suite
struct TerminalSurfaceHookDisableEnvironmentTests {
    private static let allFlagKeys = [
        "CMUX_CLAUDE_HOOKS_DISABLED",
        "CMUX_CODEX_HOOKS_DISABLED",
        "CMUX_CURSOR_HOOKS_DISABLED",
        "CMUX_GEMINI_HOOKS_DISABLED",
        "CMUX_KIRO_HOOKS_DISABLED",
        "CMUX_AMP_HOOKS_DISABLED",
    ]

    private static func policy(
        claude: Bool = true,
        codex: Bool = true,
        cursor: Bool = true,
        gemini: Bool = true,
        kiro: Bool = true,
        amp: Bool = true
    ) -> TerminalSurfaceSpawnPolicy {
        TerminalSurfaceSpawnPolicy(
            claudeHooksEnabled: claude,
            codexHooksEnabled: codex,
            customClaudePath: nil,
            subagentNotificationEnvironmentKey: "CMUX_TEST_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            suppressSubagentNotifications: false,
            cursorHooksEnabled: cursor,
            geminiHooksEnabled: gemini,
            kiroHooksEnabled: kiro,
            kiroNotificationLevel: "all",
            ampHooksEnabled: amp,
            shellIntegrationEnabled: false,
            watchGitStatusEnabled: false,
            showPullRequestsEnabled: false
        )
    }

    /// The regression: an integration that is ON must neutralize the flag it
    /// inherited, not merely decline to write one. The spawn dictionary is
    /// *added* to an environment that already inherits cmux's own, so the
    /// enabled case has to overwrite the key, not drop it.
    @Test func enabledIntegrationsClearInheritedDisableFlags() {
        var environment = Dictionary(
            uniqueKeysWithValues: Self.allFlagKeys.map { ($0, "1") }
        )

        _ = Self.policy().applyHookDisableFlags(to: &environment)

        for key in Self.allFlagKeys {
            #expect(environment[key] == "", "\(key) survived an enabled integration")
        }
    }

    @Test func disabledIntegrationsStillExportTheirFlag() {
        var environment: [String: String] = [:]

        _ = Self.policy(
            claude: false,
            codex: false,
            cursor: false,
            gemini: false,
            kiro: false,
            amp: false
        ).applyHookDisableFlags(to: &environment)

        for key in Self.allFlagKeys {
            #expect(environment[key] == "1")
        }
    }

    /// One integration being off must not drag the others down with it: the
    /// inherited value is per-agent, and so is the setting.
    @Test func oneDisabledIntegrationDoesNotStrandTheOthers() {
        var environment = Dictionary(
            uniqueKeysWithValues: Self.allFlagKeys.map { ($0, "1") }
        )

        _ = Self.policy(codex: false).applyHookDisableFlags(to: &environment)

        #expect(environment["CMUX_CODEX_HOOKS_DISABLED"] == "1")
        #expect(environment["CMUX_CLAUDE_HOOKS_DISABLED"] == "")
        #expect(environment["CMUX_CURSOR_HOOKS_DISABLED"] == "")
    }

    /// A restored surface is spawned with the saved environment of the session
    /// that created it. Unless cmux claims these keys in both directions, that
    /// saved copy puts a cleared flag straight back.
    @Test func everyFlagKeyIsClaimedInBothDirections() {
        var environment: [String: String] = [:]

        let claimed = Self.policy(claude: false).applyHookDisableFlags(to: &environment)

        #expect(claimed == Set(Self.allFlagKeys))
    }

    /// The environment cmux does not own is not cmux's to edit.
    @Test func unrelatedEnvironmentEntriesAreLeftAlone() {
        var environment = [
            "CMUX_CLAUDE_HOOKS_DISABLED": "1",
            "PATH": "/usr/bin",
            "CLAUDE_CONFIG_DIR": "/Users/example/.claude",
        ]

        _ = Self.policy().applyHookDisableFlags(to: &environment)

        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/Users/example/.claude")
    }
}
