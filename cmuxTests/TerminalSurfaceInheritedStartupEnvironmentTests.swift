import CmuxTerminal
import Foundation
import Testing

/// Same defect as the hook-disable flags, on the shell-integration keys: a
/// spawned surface's environment starts from cmux's own, and cmux is routinely
/// launched *from* a cmux terminal, so writing a key only in its "on" case
/// leaves the launching app's value in place for every other case.
///
/// Here the leak points into another app bundle. A tagged dev build launched
/// from the user's main app would advertise the main app's
/// `shell-integration` directory, and a user who switched integration off
/// would get it anyway.
@Suite
struct TerminalSurfaceInheritedStartupEnvironmentTests {
    /// The value a cmux terminal exports, as inherited by an app launched
    /// from it.
    private static func inheritedFromAnotherApp() -> [String: String] {
        [
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR":
                "/Applications/Other cmux.app/Contents/Resources/shell-integration",
            "CMUX_NO_GIT_WATCH": "1",
            "CMUX_NO_PR_WATCH": "1",
        ]
    }

    @Test func integrationOffOverwritesAnInheritedOnFlag() {
        var environment = Self.inheritedFromAnotherApp()
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedShellIntegrationEnvironment(
            integrationDirectory: nil,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        #expect(environment["CMUX_SHELL_INTEGRATION"] == "0")
        #expect(environment["CMUX_SHELL_INTEGRATION_DIR"] == "")
    }

    /// `""` would not do: every consumer reads
    /// `"${CMUX_SHELL_INTEGRATION:-1}" != "0"`, so an empty string still means
    /// on. Only the literal `"0"` turns it off.
    @Test func theOffValueIsZeroBecauseEmptyWouldStillReadAsOn() {
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedShellIntegrationEnvironment(
            integrationDirectory: nil,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        #expect(environment["CMUX_SHELL_INTEGRATION"] != "")
        #expect(environment["CMUX_SHELL_INTEGRATION"] == "0")
    }

    @Test func integrationOnAdvertisesThisBundlesDirectory() {
        var environment = Self.inheritedFromAnotherApp()
        var protectedKeys: Set<String> = []
        let thisBundle = "/Applications/cmux.app/Contents/Resources/shell-integration"

        TerminalSurface.applyManagedShellIntegrationEnvironment(
            integrationDirectory: thisBundle,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        #expect(environment["CMUX_SHELL_INTEGRATION"] == "1")
        #expect(environment["CMUX_SHELL_INTEGRATION_DIR"] == thisBundle)
    }

    /// Both keys are claimed either way, so a restored session's saved
    /// environment cannot put the launching app's value back.
    @Test func bothKeysAreClaimedInEitherDirection() {
        var environment: [String: String] = [:]
        var offKeys: Set<String> = []
        var onKeys: Set<String> = []

        TerminalSurface.applyManagedShellIntegrationEnvironment(
            integrationDirectory: nil,
            to: &environment,
            protectedKeys: &offKeys
        )
        TerminalSurface.applyManagedShellIntegrationEnvironment(
            integrationDirectory: "/somewhere",
            to: &environment,
            protectedKeys: &onKeys
        )

        let expected: Set<String> = ["CMUX_SHELL_INTEGRATION", "CMUX_SHELL_INTEGRATION_DIR"]
        #expect(offKeys == expected)
        #expect(onKeys == expected)
    }

    /// The git-watch pair already wrote both directions; it was simply never
    /// reached when integration was off, which left the launching window's
    /// policy in place.
    @Test func watchPolicyOverwritesAnInheritedOppositeValue() {
        var environment = Self.inheritedFromAnotherApp()
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedGitWatchEnvironment(
            watchGitStatusEnabled: true,
            showPullRequestsEnabled: true,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        #expect(environment["CMUX_NO_GIT_WATCH"] == "")
        #expect(environment["CMUX_NO_PR_WATCH"] == "")
    }
}
