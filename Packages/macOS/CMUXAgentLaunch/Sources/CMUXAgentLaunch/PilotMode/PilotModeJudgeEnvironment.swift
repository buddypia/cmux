import Foundation

/// Environment for the judge subprocess.
///
/// Two jobs. First, keep the judge's own hooks from firing: a judge that
/// inherited `CMUX_SURFACE_ID` would emit Feed events of its own, and a judge
/// spawned to answer a permission request would raise permission requests —
/// recursively. Stripping every `CMUX_*` variable removes the surface binding
/// the hooks require, and the explicit disable flags close the same door a
/// second way.
///
/// Second, keep the session's identity out of it: the judge must not resume,
/// write to, or otherwise touch the conversation it is reviewing.
/// lint:allow namespace-type — stateless environment policy.
public enum PilotModeJudgeEnvironment {
    /// Per-agent hook kill switches, set explicitly even though stripping
    /// `CMUX_*` already disarms the hooks. Belt and braces: an agent that
    /// learns to find its surface another way still sees the flag.
    public static let hookDisableKeys = [
        "CMUX_CLAUDE_HOOKS_DISABLED",
        "CMUX_CODEX_HOOKS_DISABLED",
        "CMUX_OPENCODE_HOOKS_DISABLED",
        "CMUX_GROK_HOOKS_DISABLED",
        "CMUX_GEMINI_HOOKS_DISABLED",
        "CMUX_CURSOR_HOOKS_DISABLED",
        "CMUX_PI_HOOKS_DISABLED",
        "CMUX_OMP_HOOKS_DISABLED",
        "CMUX_AMP_HOOKS_DISABLED",
        "CMUX_KIRO_HOOKS_DISABLED",
        "CMUX_COPILOT_HOOKS_DISABLED",
        "CMUX_CODEBUDDY_HOOKS_DISABLED",
        "CMUX_FACTORY_HOOKS_DISABLED",
        "CMUX_QODER_HOOKS_DISABLED",
        "CMUX_KIMI_HOOKS_DISABLED",
        "CMUX_CAMPFIRE_HOOKS_DISABLED",
        "CMUX_ROVODEV_HOOKS_DISABLED",
    ]

    private static let scrubbedExactKeys: Set<String> = ClaudeSessionEnvironmentPolicy()
        .inheritedSessionIdentityKeys
        .union(["NODE_OPTIONS"])

    /// The broad environment minus cmux context and session identity. Provider
    /// credentials stay, because the judge needs them to authenticate; exposure
    /// is bounded by launching it with tools, network, and MCP disabled, so the
    /// untrusted request text it reads has no channel to exfiltrate anything.
    public static func judgeEnvironment(from env: [String: String]) -> [String: String] {
        var result = env.filter { key, _ in
            if key.hasPrefix("CMUX_") { return false }
            if scrubbedExactKeys.contains(key) { return false }
            return true
        }
        for key in hookDisableKeys {
            result[key] = "1"
        }
        return result
    }

    /// Model for `claude -p`. Honors the user's small/fast override so Vertex
    /// and Bedrock deployments are not broken by a hardcoded alias.
    public static func claudeModel(from env: [String: String]) -> String {
        let override = env["ANTHROPIC_SMALL_FAST_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? "haiku" : override
    }
}
