import Foundation

/// Which agent binary should answer, and where it should run.
public struct PilotModeJudgeContext: Sendable, Equatable {
    /// Agent slug of the session that raised the request (`claude`, `codex`, …).
    public let agentSlug: String
    /// The session's working directory, shown to the judge as context. The
    /// judge process itself never runs there — it runs tool-less in a scratch
    /// directory.
    public let cwd: String?

    public init(agentSlug: String, cwd: String?) {
        self.agentSlug = agentSlug
        self.cwd = cwd
    }
}

/// Raw judge result, before parsing.
public enum PilotModeJudgeOutcome: Sendable, Equatable {
    case text(String)
    /// No judge binary could be resolved, or it failed to launch.
    case unavailable
    case timedOut
}

/// Runs one tool-less, one-shot model call and returns its raw text.
///
/// Injected as a protocol so the evaluator's decision logic is testable without
/// spawning a process; the production implementation lives in the app layer and
/// invokes the session's own agent CLI in headless mode.
public protocol PilotModeJudge: Sendable {
    func evaluate(
        prompt: String,
        timeout: TimeInterval,
        context: PilotModeJudgeContext
    ) async -> PilotModeJudgeOutcome
}
