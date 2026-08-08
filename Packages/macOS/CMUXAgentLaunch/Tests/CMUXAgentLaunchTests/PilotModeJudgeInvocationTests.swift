import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Pilot Mode judge invocation")
struct PilotModeJudgeInvocationTests {
    private func invocation(_ slug: String) -> PilotModeJudgeInvocation? {
        PilotModeJudgeInvocationBuilder.invocation(
            agentSlug: slug,
            promptFilePath: "/tmp/scratch/prompt.txt",
            outputFilePath: "/tmp/scratch/verdict.txt",
            scratchDirectory: "/tmp/scratch",
            claudeModel: "haiku"
        )
    }

    @Test("Every supported judge runs without tools, network, or MCP")
    func judgesRunSandboxed() throws {
        // The judge reads text written by the agent it is reviewing. It must
        // not be able to act on it.
        let claude = try #require(invocation("claude"))
        #expect(claude.arguments.contains("--tools"))
        #expect(claude.arguments.contains("--strict-mcp-config"))
        #expect(claude.arguments.contains("--no-session-persistence"))

        let codex = try #require(invocation("codex"))
        #expect(codex.arguments.contains("default_tools_enabled=false"))
        #expect(codex.arguments.contains("web_search=false"))
        #expect(codex.arguments.contains("mcp_servers={}"))
        #expect(codex.arguments.contains("read-only"))
        #expect(codex.arguments.contains("--ignore-user-config"))

        let opencode = try #require(invocation("opencode"))
        #expect(opencode.arguments.contains("--pure"))
    }

    @Test("The judge never runs in the session's own directory")
    func judgeRunsInScratchDirectory() throws {
        let codex = try #require(invocation("codex"))
        let cdIndex = try #require(codex.arguments.firstIndex(of: "--cd"))
        #expect(codex.arguments[cdIndex + 1] == "/tmp/scratch")

        let opencode = try #require(invocation("opencode"))
        let dirIndex = try #require(opencode.arguments.firstIndex(of: "--dir"))
        #expect(opencode.arguments[dirIndex + 1] == "/tmp/scratch")
    }

    @Test("Unknown agents have no invocation")
    func unknownAgentsAreUnsupported() {
        #expect(invocation("grok") == nil)
        #expect(invocation("") == nil)
        #expect(invocation("acme") == nil)
    }

    @Test("The session's own agent judges when it can")
    func prefersSessionAgent() {
        let agent = PilotModeJudgeInvocationBuilder.resolveJudgeAgent(
            sessionAgent: "codex",
            isInstalled: { _ in true }
        )
        #expect(agent == "codex")
    }

    @Test("An agent that cannot judge falls back to an installed one")
    func fallsBackForUndriveableAgents() {
        let agent = PilotModeJudgeInvocationBuilder.resolveJudgeAgent(
            sessionAgent: "grok",
            isInstalled: { $0 == "codex" }
        )
        #expect(agent == "codex")
    }

    @Test("With nothing installed there is no judge")
    func noJudgeAvailable() {
        let agent = PilotModeJudgeInvocationBuilder.resolveJudgeAgent(
            sessionAgent: "claude",
            isInstalled: { _ in false }
        )
        #expect(agent == nil)
    }

    @Test("The judge environment cannot re-enter cmux hooks")
    func environmentDisarmsHooks() {
        let scrubbed = PilotModeJudgeEnvironment.judgeEnvironment(from: [
            "CMUX_SURFACE_ID": "surface:1",
            "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
            "CMUX_WORKSPACE_ID": "ws:1",
            "PATH": "/usr/bin",
            "ANTHROPIC_API_KEY": "sk-test",
        ])

        // Without a surface binding the hooks no-op, and the explicit flags
        // close the same door a second way. Otherwise a judge spawned to answer
        // a permission request would raise permission requests of its own.
        #expect(scrubbed["CMUX_SURFACE_ID"] == nil)
        #expect(scrubbed["CMUX_SOCKET_PATH"] == nil)
        #expect(scrubbed["CMUX_WORKSPACE_ID"] == nil)
        #expect(scrubbed["CMUX_CLAUDE_HOOKS_DISABLED"] == "1")
        #expect(scrubbed["CMUX_CODEX_HOOKS_DISABLED"] == "1")
        #expect(scrubbed["CMUX_OPENCODE_HOOKS_DISABLED"] == "1")
        // Credentials survive: the judge has to authenticate.
        #expect(scrubbed["ANTHROPIC_API_KEY"] == "sk-test")
        #expect(scrubbed["PATH"] == "/usr/bin")
    }

    @Test("Claude honors the small/fast model override")
    func claudeModelOverride() {
        #expect(PilotModeJudgeEnvironment.claudeModel(from: [:]) == "haiku")
        #expect(
            PilotModeJudgeEnvironment.claudeModel(
                from: ["ANTHROPIC_SMALL_FAST_MODEL": "custom-model"]
            ) == "custom-model"
        )
    }
}
