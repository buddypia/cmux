import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

/// A coding-agent session discovered by observing the process table, with no
/// dependency on hooks firing. Identity (and, for codex, the transcript path)
/// comes from the agent's own argv, environment, or open transcript file, so a
/// session launched through any indirection (a subrouter, a wrapper) is still
/// found.
struct ObservedAgentSession: Sendable {
    let sessionID: String
    let agentKind: ChatAgentKind
    let surfaceID: String
    let workspaceID: String?
    let pid: Int
    let workingDirectory: String?
    let transcriptPath: String?
    let sampledAt: Date

    init(
        sessionID: String,
        agentKind: ChatAgentKind,
        surfaceID: String,
        workspaceID: String?,
        pid: Int,
        workingDirectory: String?,
        transcriptPath: String?,
        sampledAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.transcriptPath = transcriptPath
        self.sampledAt = sampledAt
    }
}

extension AgentChatSessionRegistry {
    func stampLifecycleTransition(
        previous: AgentChatSessionRecord?,
        current: inout AgentChatSessionRecord,
        at transitionAt: Date
    ) {
        let wasEnded = previous.map { Self.stateIsEnded($0.state) } ?? false
        let isEnded = Self.stateIsEnded(current.state)
        if isEnded {
            if wasEnded {
                current.endedAt = current.endedAt ?? previous?.endedAt ?? transitionAt
            } else {
                current.endedAt = transitionAt
            }
        } else {
            current.endedAt = nil
        }
    }

    /// Strips an agent-name prefix from prefixed workstream ids
    /// (`claude-<uuid>`); raw hook ids pass through.
    static func normalizedSessionID(_ id: String, source: String) -> String {
        let prefix = "\(source)-"
        if id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }

    nonisolated static func nextState(
        previous: ChatAgentState,
        event: WorkstreamEvent
    ) -> ChatAgentState {
        if stateIsEnded(previous), event.hookEventName != .sessionStart {
            return .ended
        }
        switch event.hookEventName {
        case .sessionStart:
            return .idle
        case .userPromptSubmit, .preToolUse, .postToolUse, .todoWrite:
            if case .working = previous { return previous }
            return .working(since: event.receivedAt)
        case .preCompact, .postCompact:
            // Compaction is lifecycle telemetry. It can occur while a session
            // is idle, so it must not create a synthetic working state.
            return previous
        case .permissionRequest, .askUserQuestion, .exitPlanMode:
            if case .needsInput = previous { return previous }
            return .needsInput(since: event.receivedAt)
        case .notification:
            // `Notification` is the one hook agents overload. Claude fires it to
            // ask for permission, but Antigravity also fires it for progress
            // pings and turn-complete summaries — treating all of them as
            // needs-input pinned those sessions to "waiting for you" forever.
            switch NotificationHookIntent(event: event) {
            case .needsInput:
                if case .needsInput = previous { return previous }
                return .needsInput(since: event.receivedAt)
            case .completed:
                return .idle
            case .progress:
                return previous
            }
        case .stop:
            return .idle
        case .subagentStart, .subagentStop:
            // Task subagent lifecycle says nothing about the parent
            // session's activity; keep the current state.
            return previous
        case .sessionEnd:
            return .ended
        }
    }

    nonisolated static func stateIsEnded(_ state: ChatAgentState) -> Bool {
        if case .ended = state {
            return true
        }
        return false
    }
}

/// What a `Notification` hook event is actually reporting.
///
/// The hook carries no machine-readable intent, so it is read from the human
/// text the agent supplied (`message`, plus any string under `extra`). Ordering
/// is deliberate: needs-input wins over completion, because "approval denied"
/// mentions a failure *and* needs the user, and an unclassifiable notification
/// falls back to needs-input so Claude's permission prompts keep working.
enum NotificationHookIntent: Equatable {
    /// The agent is blocked on the user.
    case needsInput
    /// The turn finished.
    case completed
    /// A progress ping that says nothing about the turn's state.
    case progress

    init(event: WorkstreamEvent) {
        let texts = Self.candidateTexts(in: event)
        guard !texts.isEmpty else {
            self = .needsInput
            return
        }
        if texts.contains(where: Self.readsAsNeedsInput) {
            self = .needsInput
        } else if texts.contains(where: Self.readsAsCompleted) {
            self = .completed
        } else {
            self = .progress
        }
    }

    /// `message` plus every string under `extra`, lowercased. `extra` keys are
    /// included because agents signal through the key as often as the value
    /// (`{"extra": {"error": "..."}}`).
    private static func candidateTexts(in event: WorkstreamEvent) -> [String] {
        guard let json = event.extraFieldsJSON?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return []
        }
        var texts: [String] = []
        if let message = root["message"] as? String { texts.append(message.lowercased()) }
        if let extra = root["extra"] as? [String: Any] {
            for (key, value) in extra {
                texts.append(key.lowercased())
                if let string = value as? String { texts.append(string.lowercased()) }
            }
        }
        return texts
    }

    private static let needsInputNeedles = [
        "error", "failed", "failure", "denied", "rejected", "declined",
        "permission", "approval", "approve", "authorize", "confirm",
        "waiting", "awaiting", "needs your", "your input", "respond",
    ]

    private static let completedNeedles = [
        "complete", "completed", "finished", "done", "succeeded", "turn complete",
    ]

    private static func readsAsNeedsInput(_ text: String) -> Bool {
        needsInputNeedles.contains { text.contains($0) }
    }

    private static func readsAsCompleted(_ text: String) -> Bool {
        completedNeedles.contains { text.contains($0) }
    }
}
