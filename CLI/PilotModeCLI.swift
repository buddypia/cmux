import Foundation

// Argument parsing and output formatting for `cmux pilot`, kept pure and free
// of CLI-private symbols because this file is compiled into both the bundled
// CLI target and the cmux-unit test target (the CLI is a tool target that tests
// cannot import). The socket call and the environment read live in
// `CMUXCLI+Pilot.swift`.

/// Which Pilot Mode switch a `cmux pilot` invocation is talking about.
enum PilotModeCLIScope: Equatable {
    /// The global switch.
    case global
    /// The tab the command runs in, resolved from `CMUX_SURFACE_ID`.
    case thisTab
    /// A specific surface, as passed on the command line.
    case surface(String)
}

enum PilotModeCLICommand: Equatable {
    case status(PilotModeCLIScope)
    case disable(PilotModeCLIScope)

    var scope: PilotModeCLIScope {
        switch self {
        case .status(let scope), .disable(let scope): return scope
        }
    }

    var isDisable: Bool {
        if case .disable = self { return true }
        return false
    }

    var socketMethod: String {
        isDisable ? "feed.pilot.disable" : "feed.pilot.status"
    }
}

enum PilotModeCLIParseResult: Equatable {
    case command(PilotModeCLICommand)
    case failure(String)
}

enum PilotModeCLI {
    static let usage = """
        Usage:
          cmux pilot [status] [--this-tab | --surface <uuid>] [--json]
          cmux pilot off      [--this-tab | --surface <uuid>] [--json]

        Scope:
          (default)          the global switch
          --this-tab         the tab this command runs in ($CMUX_SURFACE_ID)
          --surface <uuid>   a specific surface; `cmux surface list --json` has the ids

        Pilot Mode can only be turned on from Settings > Automation > Pilot Mode
        or the command palette, never from the CLI.
        """

    /// Rejecting `on` is the point of this verb, not an oversight. Every agent
    /// running in a cmux terminal holds the socket credentials its hooks use, and
    /// cmux cannot tell a human typing in a tab from the agent running in it — so
    /// a scriptable enable would let an agent grant itself the auto-approval that
    /// Pilot Mode's guardrails exist to withhold. Off is the safe direction and
    /// costs nothing but extra prompts, so only off is scriptable.
    static let enableRefusal = """
        Pilot Mode cannot be turned on from the CLI.

        Any agent in a cmux terminal can run this command, so an enable verb would
        let an agent grant itself auto-approval. Turn it on in
        Settings > Automation > Pilot Mode, or from the command palette.
        """

    static func parse(_ args: [String]) -> PilotModeCLIParseResult {
        var rest = args
        var isDisable = false
        switch rest.first?.lowercased() {
        case "off", "disable":
            isDisable = true
            rest.removeFirst()
        case "status":
            rest.removeFirst()
        case "on", "enable":
            return .failure(enableRefusal)
        case .none:
            break
        case .some(let first) where first.hasPrefix("-"):
            break
        case .some(let unknown):
            return .failure("Unknown subcommand '\(unknown)'.\n\n\(usage)")
        }

        var scope = PilotModeCLIScope.global
        var index = 0
        while index < rest.count {
            switch rest[index] {
            case "--this-tab":
                scope = .thisTab
                index += 1
            case "--surface":
                guard index + 1 < rest.count else {
                    return .failure("--surface needs a surface uuid.\n\n\(usage)")
                }
                scope = .surface(rest[index + 1])
                index += 2
            default:
                return .failure("Unknown option '\(rest[index])'.\n\n\(usage)")
            }
        }

        return .command(isDisable ? .disable(scope) : .status(scope))
    }

    /// Formats a `feed.pilot.*` payload for humans.
    static func summary(_ response: [String: Any], didDisable: Bool) -> String {
        let enabled = (response["enabled"] as? Bool) ?? false
        let scope = (response["scope"] as? String) ?? "global"
        let scopeLabel = scope == "surface"
            ? "for this tab"
            : "globally"

        if didDisable {
            let changed = (response["changed"] as? Bool) ?? false
            return changed
                ? "Pilot Mode turned off \(scopeLabel)."
                : "Pilot Mode was already off \(scopeLabel)."
        }

        var lines = ["Pilot Mode is \(enabled ? "on" : "off") \(scopeLabel)."]
        if let runMode = response["run_mode"] as? String {
            lines.append(
                runMode == "shadow"
                    ? "  mode: shadow (records verdicts, answers nothing)"
                    : "  mode: active (answers for you)"
            )
        }
        if scope == "surface" {
            // Says whether this tab was set deliberately or is just following the
            // global switch. Only the first is undone by clearing the override,
            // so a reader who cannot tell them apart cannot tell what to do next.
            if response["surface_override"] is Bool {
                lines.append("  scope: overridden for this tab only")
            } else {
                let global = (response["global_enabled"] as? Bool) ?? false
                lines.append("  scope: following the default (global is \(global ? "on" : "off"))")
            }
        }
        if enabled {
            var answers: [String] = []
            if (response["answers_permission_requests"] as? Bool) ?? false {
                answers.append("permission requests")
            }
            if (response["answers_questions"] as? Bool) ?? false {
                answers.append("questions")
            }
            lines.append("  answers: \(answers.isEmpty ? "nothing" : answers.joined(separator: ", "))")
            if let ceiling = response["max_consecutive_decisions"] as? Int {
                lines.append("  ceiling: \(ceiling) in a row per tab")
            }
        }
        return lines.joined(separator: "\n")
    }
}
