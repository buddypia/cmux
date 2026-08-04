/// One agent integration's `*_HOOKS_DISABLED` decision for a spawn.
///
/// Clearing carries the same weight as setting, which is the whole reason
/// this is a decision rather than a conditional write. A spawned surface's
/// environment starts from cmux's own process environment, and cmux is
/// routinely launched *from* a cmux terminal — every `reload.sh --launch`
/// does exactly that. An inherited `CMUX_CLAUDE_HOOKS_DISABLED=1` therefore
/// outlives the setting that produced it: the wrapper injects no hooks, the
/// agent's only remaining reporter is the process table and its transcript,
/// neither of which can prove a turn is *running*, and the sidebar shows 💤
/// for an agent that is mid-turn — while Settings, `~/.config/cmux/cmux.json`,
/// and UserDefaults all read "on". Writing the flag only when the integration
/// is off leaves that inherited value untouched, so the enabled case has to
/// remove it.
public struct TerminalSurfaceHookDisableFlag: Sendable, Equatable {
    /// Environment variable the agent's wrapper shim reads.
    public let key: String

    /// `true` exports `"1"`; `false` removes any inherited value.
    public let isDisabled: Bool

    public init(key: String, isDisabled: Bool) {
        self.key = key
        self.isDisabled = isDisabled
    }
}

extension TerminalSurfaceSpawnPolicy {
    /// Every hook-disable flag this policy decides.
    ///
    /// The wrapper shims stay on `PATH` whether or not their integration is
    /// on — a resumed agent has to route through them either way — so the
    /// environment variable is the only thing that tells a shim to no-op.
    public var hookDisableFlags: [TerminalSurfaceHookDisableFlag] {
        [
            TerminalSurfaceHookDisableFlag(
                key: "CMUX_CLAUDE_HOOKS_DISABLED",
                isDisabled: !claudeHooksEnabled
            ),
            TerminalSurfaceHookDisableFlag(
                key: "CMUX_CODEX_HOOKS_DISABLED",
                isDisabled: !codexHooksEnabled
            ),
            TerminalSurfaceHookDisableFlag(
                key: "CMUX_CURSOR_HOOKS_DISABLED",
                isDisabled: !cursorHooksEnabled
            ),
            TerminalSurfaceHookDisableFlag(
                key: "CMUX_GEMINI_HOOKS_DISABLED",
                isDisabled: !geminiHooksEnabled
            ),
            TerminalSurfaceHookDisableFlag(
                key: "CMUX_KIRO_HOOKS_DISABLED",
                isDisabled: !kiroHooksEnabled
            ),
            TerminalSurfaceHookDisableFlag(
                key: "CMUX_AMP_HOOKS_DISABLED",
                isDisabled: !ampHooksEnabled
            ),
        ]
    }

    /// Applies ``hookDisableFlags`` to a spawn environment.
    ///
    /// - Returns: The keys cmux now owns. The caller marks them protected so a
    ///   restored session's saved environment cannot resurrect a flag this
    ///   spawn just cleared — a restored surface carries the environment of
    ///   the session that created it, which is exactly where a stale value
    ///   would come from.
    public func applyHookDisableFlags(to environment: inout [String: String]) -> Set<String> {
        var ownedKeys: Set<String> = []
        for flag in hookDisableFlags {
            if flag.isDisabled {
                environment[flag.key] = "1"
            }
            ownedKeys.insert(flag.key)
        }
        return ownedKeys
    }
}
