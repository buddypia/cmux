import Foundation

/// Why Pilot Mode handed a pending decision back to the human instead of
/// answering it. Every escalation is recorded verbatim in the audit trail, so
/// these cases double as the vocabulary the Feed card and the shadow log use to
/// explain themselves.
public enum PilotModeEscalation: Sendable, Equatable, Codable {
    /// A guardrail matched. `rule` names the matched rule so the audit trail
    /// says *which* one fired. Guardrails are absolute: no user instruction and
    /// no judge output can overturn them.
    case guardrail(rule: String)
    /// The item is a kind Pilot Mode does not answer (today: `.exitPlan`).
    case unsupportedKind
    /// The judge ran and explicitly declined to decide.
    case judgeDeclined(reason: String)
    /// The judge answered but was not confident enough to be trusted with it.
    case lowConfidence(confidence: Double)
    /// The judge's output did not parse into a decision this item accepts.
    case unparseableJudgeOutput
    /// No judge binary could be resolved for the session's agent.
    case judgeUnavailable
    /// The judge did not answer inside the decision budget.
    case judgeTimedOut
    /// The consecutive-automatic-decision ceiling was reached.
    case rateLimited
    /// Pilot Mode is off for this surface.
    case disabled
}

/// What Pilot Mode concluded for a single pending decision.
///
/// A verdict is *advice* until the caller applies it: in shadow mode the
/// verdict is recorded and the human still decides, and in active mode the
/// same verdict is replayed through the ordinary reply path
/// (`FeedCoordinator.deliverReply`). Both modes produce the same verdict for
/// the same input, which is what makes a shadow run a valid rehearsal of the
/// active run.
public enum PilotModeVerdict: Sendable, Equatable {
    /// Pilot Mode would answer with `decision`.
    case decide(WorkstreamDecision, rationale: String)
    /// Pilot Mode declines; the human answers.
    case escalate(PilotModeEscalation)

    public var isDecision: Bool {
        if case .decide = self { return true }
        return false
    }

    public var decision: WorkstreamDecision? {
        if case .decide(let decision, _) = self { return decision }
        return nil
    }

    public var escalation: PilotModeEscalation? {
        if case .escalate(let reason) = self { return reason }
        return nil
    }
}

/// How a verdict was reached. Recorded alongside the verdict so the audit trail
/// distinguishes "a guardrail settled this without spending a judge call" from
/// "the judge decided", which is the number that matters when tuning
/// instructions.
public enum PilotModeVerdictSource: String, Sendable, Equatable, Codable {
    /// Settled by a static rule, without invoking the judge.
    case guardrail
    /// Settled by the read-only fast path, without invoking the judge.
    case readOnlyFastPath
    /// Settled by the judge model.
    case judge
}
