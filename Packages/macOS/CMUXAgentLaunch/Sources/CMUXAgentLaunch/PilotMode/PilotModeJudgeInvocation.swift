import Foundation

/// How to launch one agent CLI as a Pilot Mode judge.
public struct PilotModeJudgeInvocation: Sendable, Equatable {
    /// Agent slug whose binary should run.
    public let agentSlug: String
    /// Executable name to resolve on `PATH`.
    public let executableName: String
    public let arguments: [String]
    /// Whether the prompt is written to the process's stdin.
    public let deliversPromptOnStdin: Bool
    /// When non-nil, the verdict is read from this file instead of stdout
    /// (Codex writes its final message there).
    public let outputFilePath: String?

    public init(
        agentSlug: String,
        executableName: String,
        arguments: [String],
        deliversPromptOnStdin: Bool,
        outputFilePath: String?
    ) {
        self.agentSlug = agentSlug
        self.executableName = executableName
        self.arguments = arguments
        self.deliversPromptOnStdin = deliversPromptOnStdin
        self.outputFilePath = outputFilePath
    }
}

/// Builds judge invocations.
///
/// Every invocation runs the agent with tools, network, MCP servers, session
/// persistence, and user config disabled. That matters twice over: the judge
/// must not act on the request it is reviewing, and the request text it reads
/// is written by the agent under review, so it is treated as hostile input with
/// no capabilities available to it.
/// lint:allow namespace-type — stateless argv table, mirroring AutoNamingAgentCatalog.
public enum PilotModeJudgeInvocationBuilder {
    /// Agents cmux knows how to drive as a one-shot, tool-less judge. Kept in
    /// step with the auto-naming summarizer dispatch, which uses the same
    /// headless entry points.
    public static let supportedSlugs: Set<String> = ["claude", "codex", "opencode"]

    /// Order used when the session's own agent cannot judge. Sticking to a
    /// fixed order keeps the choice predictable across runs.
    public static let fallbackOrder = ["claude", "codex", "opencode"]

    /// Picks the agent that judges this request: the session's own agent when
    /// it can judge and is installed, otherwise the first installed fallback.
    /// Returns `nil` when nothing on the machine can judge, which the evaluator
    /// turns into an escalation.
    public static func resolveJudgeAgent(
        sessionAgent: String,
        isInstalled: (String) -> Bool
    ) -> String? {
        let session = sessionAgent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if supportedSlugs.contains(session), isInstalled(session) {
            return session
        }
        return fallbackOrder.first { isInstalled($0) }
    }

    /// Builds the invocation. `promptFilePath` is required for agents that read
    /// the prompt from a file; `scratchDirectory` is a throwaway cwd so the
    /// judge never runs inside the user's repository.
    public static func invocation(
        agentSlug: String,
        promptFilePath: String,
        outputFilePath: String,
        scratchDirectory: String,
        claudeModel: String?
    ) -> PilotModeJudgeInvocation? {
        switch agentSlug {
        case "claude":
            var arguments = ["-p"]
            if let claudeModel, !claudeModel.isEmpty {
                arguments += ["--model", claudeModel]
            }
            arguments += [
                "--tools", "",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--strict-mcp-config",
                "--mcp-config", "{}",
            ]
            return PilotModeJudgeInvocation(
                agentSlug: agentSlug,
                executableName: "claude",
                arguments: arguments,
                deliversPromptOnStdin: true,
                outputFilePath: nil
            )

        case "codex":
            return PilotModeJudgeInvocation(
                agentSlug: agentSlug,
                executableName: "codex",
                arguments: [
                    "exec",
                    "-c", "default_tools_enabled=false",
                    "-c", "tools={}",
                    "-c", "mcp_servers={}",
                    "-c", "web_search=false",
                    "-c", "approval_policy=never",
                    "-c", "shell_environment_policy.inherit=none",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "--ignore-user-config",
                    "--ignore-rules",
                    "--sandbox", "read-only",
                    "--cd", scratchDirectory,
                    "--output-last-message", outputFilePath,
                    "-",
                ],
                deliversPromptOnStdin: true,
                outputFilePath: outputFilePath
            )

        case "opencode":
            return PilotModeJudgeInvocation(
                agentSlug: agentSlug,
                executableName: "opencode",
                arguments: [
                    "run",
                    "--pure",
                    "--format", "default",
                    "--dir", scratchDirectory,
                    "--file", promptFilePath,
                    "Answer with the single JSON object the attached instructions specify.",
                ],
                deliversPromptOnStdin: false,
                outputFilePath: nil
            )

        default:
            return nil
        }
    }
}
