import Foundation

/// Whether Pilot Mode only records what it would have answered, or actually
/// answers.
public enum PilotModeRunMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Evaluate every pending decision and record the verdict, but let the
    /// human answer. The rehearsal mode: it produces the same verdicts as
    /// ``active`` with none of the consequences, so the audit trail measures
    /// accuracy before anything is delegated.
    case shadow
    /// Replay the verdict through the ordinary reply path.
    case active
}

/// Resolved Pilot Mode configuration for one surface.
///
/// This is a plain value so the evaluator stays pure and testable; reading it
/// out of `~/.config/cmux/cmux.json` and applying per-surface overrides happens
/// in the app layer.
public struct PilotModeSettings: Sendable, Equatable {
    public var isEnabled: Bool
    public var runMode: PilotModeRunMode
    /// Free-form user policy, injected verbatim into the judge prompt. This is
    /// the "prompt instructions" control: it can make Pilot Mode more
    /// conservative or express project-specific preferences, but it is layered
    /// *under* the guardrails and cannot unblock them.
    public var instructions: String
    /// Answer `PermissionRequest` items.
    public var answersPermissionRequests: Bool
    /// Answer `AskUserQuestion` items.
    public var answersQuestions: Bool
    /// Approve read-only tool calls without spending a judge call. Turning this
    /// off routes even `Read`/`Grep` through the judge, so user instructions
    /// apply to them too, at the cost of latency on the most frequent requests.
    public var autoAllowsReadOnly: Bool
    /// Extra deny substrings; additive to the built-in guardrails.
    public var denyPatterns: [String]
    /// How many decisions Pilot Mode may answer in a row, per surface, before
    /// it escalates to force a human back into the loop. A runaway agent should
    /// not be able to convert an unattended session into unlimited approvals.
    public var maxConsecutiveDecisions: Int
    /// Judge budget. Kept well under the Feed hook's own wait so a slow judge
    /// degrades into a human prompt rather than a hook timeout.
    public var judgeTimeout: TimeInterval

    public static let defaultMaxConsecutiveDecisions = 25
    public static let defaultJudgeTimeout: TimeInterval = 25

    public init(
        isEnabled: Bool = false,
        runMode: PilotModeRunMode = .shadow,
        instructions: String = "",
        answersPermissionRequests: Bool = true,
        answersQuestions: Bool = true,
        autoAllowsReadOnly: Bool = true,
        denyPatterns: [String] = [],
        maxConsecutiveDecisions: Int = PilotModeSettings.defaultMaxConsecutiveDecisions,
        judgeTimeout: TimeInterval = PilotModeSettings.defaultJudgeTimeout
    ) {
        self.isEnabled = isEnabled
        self.runMode = runMode
        self.instructions = instructions
        self.answersPermissionRequests = answersPermissionRequests
        self.answersQuestions = answersQuestions
        self.autoAllowsReadOnly = autoAllowsReadOnly
        self.denyPatterns = denyPatterns
        self.maxConsecutiveDecisions = maxConsecutiveDecisions
        self.judgeTimeout = judgeTimeout
    }

    /// Clamps values that arrive from hand-edited JSON into workable ranges, so
    /// a typo degrades Pilot Mode instead of hanging a hook.
    public func normalized() -> PilotModeSettings {
        var copy = self
        copy.maxConsecutiveDecisions = max(1, min(maxConsecutiveDecisions, 1000))
        copy.judgeTimeout = max(5, min(judgeTimeout, 90))
        copy.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.denyPatterns = denyPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return copy
    }
}
