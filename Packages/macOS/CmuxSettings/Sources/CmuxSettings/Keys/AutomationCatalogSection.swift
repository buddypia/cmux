import Foundation

/// Settings under the dotted-id prefix `automation.*`.
public struct AutomationCatalogSection: SettingCatalogSection {
    public let socketControlMode = DefaultsKey<SocketControlMode>(
        id: "automation.socketControlMode",
        defaultValue: .cmuxOnly,
        userDefaultsKey: "socketControlMode"
    )

    public let socketPassword = SecretFileKey(
        id: "automation.socketPassword",
        fileName: "socket-control-password"
    )

    public let claudeCodeIntegration = DefaultsKey<Bool>(
        id: "automation.claudeCodeIntegration",
        defaultValue: true,
        userDefaultsKey: "claudeCodeHooksEnabled"
    )

    public let claudeBinaryPath = DefaultsKey<String>(
        id: "automation.claudeBinaryPath",
        defaultValue: "",
        userDefaultsKey: "claudeCodeCustomClaudePath"
    )

    /// Opt-in AI auto-naming of workspaces and tabs from agent conversation
    /// content. Default off: enabling it lets cmux run the user's own agent
    /// binary (`claude -p` / `codex exec`) to summarize sessions into titles.
    public let workspaceAutoNaming = DefaultsKey<Bool>(
        id: "automation.workspaceAutoNaming",
        defaultValue: false,
        userDefaultsKey: "workspaceAutoNamingEnabled"
    )

    /// Which agent generates the auto-names. Stored as an open string so it
    /// stays fully customizable: ``AutoNamingAgentCatalog/autoSlug`` ("auto",
    /// the default) names each session with its own agent — identical to the
    /// original behavior — while any agent slug (see ``AutoNamingAgentCatalog``)
    /// overrides naming for every session. Unknown/undriveable slugs fall back
    /// to the session's own agent, so a bad value never breaks naming.
    public let autoNamingAgent = DefaultsKey<String>(
        id: "automation.autoNamingAgent",
        defaultValue: AutoNamingAgentCatalog.autoSlug,
        userDefaultsKey: "autoNamingAgent"
    )

    public let ripgrepBinaryPath = DefaultsKey<String>(
        id: "automation.ripgrepBinaryPath",
        defaultValue: "",
        userDefaultsKey: "ripgrepCustomBinaryPath"
    )

    public let suppressSubagentNotifications = DefaultsKey<Bool>(
        id: "automation.suppressSubagentNotifications",
        defaultValue: true,
        userDefaultsKey: "suppressSubagentNotifications"
    )

    // Several agent-integration toggles are intentionally exposed under both
    // `automation.*` (this catalog) and `integrations.*` (IntegrationsCatalogSection)
    // with the same `userDefaultsKey`, so writes through either namespace land
    // on the same persisted value. The shared keys are claudeCode*, cursor*,
    // gemini*, kiro* (including kiroNotificationLevel), amp*,
    // ripgrepCustomBinaryPath, and suppressSubagentNotifications. There is no
    // precedence ambiguity because both DefaultsKey wrappers read/write the
    // same `UserDefaults` slot — the dual namespace exists to keep the JSON
    // config UX (`automation.*`) and the Settings-catalog UX
    // (`integrations.*`) separately discoverable.
    public let ampIntegration = DefaultsKey<Bool>(
        id: "automation.ampIntegration",
        defaultValue: true,
        userDefaultsKey: "ampHooksEnabled"
    )

    public let cursorIntegration = DefaultsKey<Bool>(
        id: "automation.cursorIntegration",
        defaultValue: true,
        userDefaultsKey: "cursorHooksEnabled"
    )

    public let geminiIntegration = DefaultsKey<Bool>(
        id: "automation.geminiIntegration",
        defaultValue: true,
        userDefaultsKey: "geminiHooksEnabled"
    )

    public let kiroIntegration = DefaultsKey<Bool>(
        id: "automation.kiroIntegration",
        defaultValue: true,
        userDefaultsKey: "kiroHooksEnabled"
    )

    public let kiroNotificationLevel = DefaultsKey<String>(
        id: "automation.kiroNotificationLevel",
        defaultValue: "standard",
        userDefaultsKey: "kiroNotificationLevel"
    )

    // MARK: - Pilot Mode

    /// Master switch for Pilot Mode: letting cmux answer an agent's pending
    /// permission requests and questions instead of waiting for the user.
    /// Default off — this delegates decisions the user would otherwise make.
    public let pilotMode = DefaultsKey<Bool>(
        id: "automation.pilotMode.enabled",
        defaultValue: false,
        userDefaultsKey: "automation.pilotMode.enabled"
    )

    /// `shadow` records the verdict Pilot Mode *would* have sent and leaves the
    /// decision to the user; `active` sends it. Default `shadow` so enabling
    /// Pilot Mode first produces evidence about its accuracy, and only an
    /// explicit second step delegates anything.
    /// Values mirror `PilotModeRunMode` in CMUXAgentLaunch, which owns the
    /// semantics. This catalog stays dependency-light, so the two are kept in
    /// step by `PilotModeSettingsResolverTests` rather than by the type system.
    public let pilotModeRunMode = DefaultsKey<String>(
        id: "automation.pilotMode.runMode",
        defaultValue: "shadow",
        userDefaultsKey: "automation.pilotMode.runMode"
    )

    /// Free-form standing instructions handed to the judge with every request.
    /// Layered under the guardrails: it can make Pilot Mode more cautious or
    /// express project preferences, never unblock a guardrail.
    public let pilotModeInstructions = DefaultsKey<String>(
        id: "automation.pilotMode.instructions",
        defaultValue: "",
        userDefaultsKey: "automation.pilotMode.instructions"
    )

    public let pilotModeAnswersPermissionRequests = DefaultsKey<Bool>(
        id: "automation.pilotMode.answerPermissionRequests",
        defaultValue: true,
        userDefaultsKey: "automation.pilotMode.answerPermissionRequests"
    )

    public let pilotModeAnswersQuestions = DefaultsKey<Bool>(
        id: "automation.pilotMode.answerQuestions",
        defaultValue: true,
        userDefaultsKey: "automation.pilotMode.answerQuestions"
    )

    /// Approve read-only tool calls without a judge call. Turning this off
    /// costs latency on the most frequent requests but subjects them to the
    /// user's instructions too.
    public let pilotModeAutoAllowReadOnly = DefaultsKey<Bool>(
        id: "automation.pilotMode.autoAllowReadOnly",
        defaultValue: true,
        userDefaultsKey: "automation.pilotMode.autoAllowReadOnly"
    )

    /// Newline-separated substrings that force a request back to the user.
    /// Additive to the built-in guardrails.
    public let pilotModeDenyPatterns = DefaultsKey<String>(
        id: "automation.pilotMode.denyPatterns",
        defaultValue: "",
        userDefaultsKey: "automation.pilotMode.denyPatterns"
    )

    /// How many decisions Pilot Mode may answer in a row on one surface before
    /// it forces a human back into the loop.
    public let pilotModeMaxConsecutiveDecisions = DefaultsKey<Int>(
        id: "automation.pilotMode.maxConsecutiveDecisions",
        defaultValue: 25,
        userDefaultsKey: "automation.pilotMode.maxConsecutiveDecisions"
    )

    /// Seconds the judge gets before the request falls back to the user.
    public let pilotModeJudgeTimeout = DefaultsKey<Double>(
        id: "automation.pilotMode.judgeTimeoutSeconds",
        defaultValue: 25,
        userDefaultsKey: "automation.pilotMode.judgeTimeoutSeconds"
    )

    public let portBase = DefaultsKey<Int>(
        id: "automation.portBase",
        defaultValue: 9100,
        userDefaultsKey: "cmuxPortBase"
    )

    public let portRange = DefaultsKey<Int>(
        id: "automation.portRange",
        defaultValue: 10,
        userDefaultsKey: "cmuxPortRange"
    )

    public init() {}
}
