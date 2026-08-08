import Foundation
import Testing

// PilotModeCLI is compiled directly into this test target (the bundled CLI is a
// tool target that tests cannot import), so no app-module import is needed.

/// Behavior tests for `cmux pilot` argument parsing and output formatting.
@Suite("cmux pilot CLI")
struct PilotModeCLITests {
    private func parse(_ args: [String]) -> PilotModeCLIParseResult {
        PilotModeCLI.parse(args)
    }

    @Test("No arguments reports the global switch")
    func defaultsToGlobalStatus() {
        #expect(parse([]) == .command(.status(.global)))
        #expect(parse(["status"]) == .command(.status(.global)))
    }

    @Test("off disables, globally by default")
    func offDefaultsToGlobal() {
        #expect(parse(["off"]) == .command(.disable(.global)))
        #expect(parse(["disable"]) == .command(.disable(.global)))
    }

    @Test("Scope flags apply to both subcommands")
    func scopeFlags() {
        #expect(parse(["--this-tab"]) == .command(.status(.thisTab)))
        #expect(parse(["status", "--this-tab"]) == .command(.status(.thisTab)))
        #expect(parse(["off", "--this-tab"]) == .command(.disable(.thisTab)))
        #expect(parse(["off", "--surface", "abc"]) == .command(.disable(.surface("abc"))))
    }

    @Test("The CLI refuses to turn Pilot Mode on")
    func refusesEnable() {
        // The whole safety argument for a scriptable Pilot Mode rests on this:
        // an agent holding the socket credentials must not be able to grant
        // itself auto-approval.
        for verb in ["on", "enable", "ON", "Enable"] {
            guard case .failure(let message) = parse([verb]) else {
                Issue.record("`cmux pilot \(verb)` must be refused")
                continue
            }
            #expect(message.contains("cannot be turned on from the CLI"))
        }
    }

    @Test("Malformed invocations explain themselves instead of guessing")
    func rejectsMalformedInput() {
        guard case .failure(let missingValue) = parse(["off", "--surface"]) else {
            Issue.record("--surface without a value must fail")
            return
        }
        #expect(missingValue.contains("--surface needs a surface uuid"))

        guard case .failure(let unknownOption) = parse(["off", "--everywhere"]) else {
            Issue.record("an unknown option must fail")
            return
        }
        #expect(unknownOption.contains("Unknown option"))

        guard case .failure(let unknownSubcommand) = parse(["shadow"]) else {
            Issue.record("an unknown subcommand must fail")
            return
        }
        #expect(unknownSubcommand.contains("Unknown subcommand"))
    }

    @Test("A no-op disable says so rather than claiming a change")
    func disableSummaryDistinguishesNoOp() {
        let changed = PilotModeCLI.summary(
            ["scope": "global", "enabled": false, "changed": true],
            didDisable: true
        )
        #expect(changed == "Pilot Mode turned off globally.")

        let unchanged = PilotModeCLI.summary(
            ["scope": "global", "enabled": false, "changed": false],
            didDisable: true
        )
        #expect(unchanged == "Pilot Mode was already off globally.")
    }

    @Test("Status separates a deliberate tab override from following the default")
    func statusSummaryExplainsScope() {
        // Both tabs are off, but only one of them can be un-set, and the reader
        // needs to be able to tell which.
        let overridden = PilotModeCLI.summary(
            [
                "scope": "surface",
                "surface": "11111111-1111-1111-1111-111111111111",
                "enabled": false,
                "run_mode": "shadow",
                "global_enabled": true,
                "surface_override": false,
            ],
            didDisable: false
        )
        #expect(overridden.contains("overridden for this tab only"))
        #expect(!overridden.contains("following the default"))

        let inherited = PilotModeCLI.summary(
            [
                "scope": "surface",
                "surface": "11111111-1111-1111-1111-111111111111",
                "enabled": false,
                "run_mode": "shadow",
                "global_enabled": false,
            ],
            didDisable: false
        )
        #expect(inherited.contains("following the default (global is off)"))
    }

    @Test("Status spells out shadow mode, which answers nothing")
    func statusSummaryNamesRunMode() {
        let shadow = PilotModeCLI.summary(
            ["scope": "global", "enabled": true, "run_mode": "shadow"],
            didDisable: false
        )
        #expect(shadow.contains("shadow (records verdicts, answers nothing)"))

        let active = PilotModeCLI.summary(
            [
                "scope": "global",
                "enabled": true,
                "run_mode": "active",
                "answers_permission_requests": true,
                "answers_questions": false,
                "max_consecutive_decisions": 25,
            ],
            didDisable: false
        )
        #expect(active.contains("active (answers for you)"))
        #expect(active.contains("answers: permission requests"))
        #expect(!active.contains("questions,"))
        #expect(active.contains("ceiling: 25 in a row per tab"))
    }
}
