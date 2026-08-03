import CmuxAgentChat
import Foundation

/// What established an ``AgentChatSessionRecord/state``.
///
/// The distinction only bites on `.idle`, and there it is the difference
/// between a reading and a placeholder. Activity is self-proving — a `working`
/// sighting is evidence whoever reported it — but idleness is not: a record
/// minted from the process table proves an agent is running on the surface and
/// nothing at all about whether it is mid-turn.
enum AgentChatSessionStateProvenance: Sendable, Equatable {
    /// Discovered in the process table (or seeded by a cmux-initiated resume);
    /// no lifecycle evidence has arrived yet.
    case unobserved
    /// Proven by rows the agent itself wrote to its transcript.
    case transcript
    /// Reported by the agent's cmux hooks.
    case hook
}

/// Maps a chat-session record onto the workspace agent-lifecycle entry cmux
/// publishes for its surface — the value the sidebar's per-CLI badge strip and
/// the surface tab-title marker both read.
///
/// A pure function beside the record rather than inline in
/// ``AgentChatTranscriptService`` so "what does cmux claim about this agent"
/// is testable on its own and cannot drift from the provenance model above.
enum AgentChatWorkspaceLifecycleMirror {
    /// - Returns: The lifecycle to write, or `nil` when cmux must publish
    ///   nothing and clear whatever it wrote earlier.
    ///
    ///   `nil` is not "idle". It means cmux has no reading, so the strip draws
    ///   no pill and the tab keeps its bare title, instead of claiming
    ///   `💤 Idle` over an agent that may be working. That is the honest answer
    ///   for a CLI whose hook integration is off or failed to install: cmux can
    ///   see the process, and that is all it can see.
    static func lifecycle(
        for state: ChatAgentState,
        provenance: AgentChatSessionStateProvenance
    ) -> AgentHibernationLifecycleState? {
        switch state {
        case .ended:
            return nil
        case .working:
            return .running
        case .needsInput:
            return .needsInput
        case .idle:
            return provenance == .unobserved ? nil : .idle
        }
    }
}

/// One chat-capable agent session the Mac knows about: hook-derived
/// identity, terminal binding, transcript location, and live state.
struct AgentChatSessionRecord: Sendable {
    /// The agent's own session identifier (hook `session_id`, unprefixed).
    let sessionID: String

    /// Which agent runtime owns the session.
    let agentKind: ChatAgentKind

    /// Owning cmux workspace UUID string, when known.
    var workspaceID: String?

    /// Hosting cmux terminal surface UUID string, when known. Required for
    /// the send/interrupt path.
    var surfaceID: String?

    /// The session's working directory, when known.
    var workingDirectory: String?

    /// Absolute transcript path, when resolved.
    var transcriptPath: String?

    /// Live activity state derived from hook events.
    var state: ChatAgentState

    /// What established ``state``. Every mutator below sets it, so a caller
    /// asking "may I publish this?" never has to infer the answer from which
    /// setter happened to run.
    var stateProvenance: AgentChatSessionStateProvenance = .unobserved

    /// Whether `state` has been established by the agent's hook lifecycle.
    /// Process-table discovery proves presence and identity, but not idleness.
    var hasHookLifecycleState: Bool { stateProvenance == .hook }

    /// The workspace agent-lifecycle entry this record implies, or `nil` when
    /// cmux must publish nothing for it.
    var workspaceLifecycle: AgentHibernationLifecycleState? {
        AgentChatWorkspaceLifecycleMirror.lifecycle(for: state, provenance: stateProvenance)
    }

    /// When the record entered `.ended`. Best-effort process observations sampled
    /// before this point must not revive it after a hook or exit watcher ended it.
    var endedAt: Date?

    /// Timestamp of the most recent hook or transcript activity.
    var lastActivityAt: Date

    /// Conversation title (first user prompt), filled by the tailer.
    var title: String?

    /// The agent process id, for liveness sweeps.
    var pid: Int?

    /// Real hook-store key, when this record is surfaced under a pending alias.
    var hookStoreSessionID: String?

    /// Monotonic revision stamped by the registry on every change, so clients
    /// can reconcile best-effort pushes against authoritative pulls. Owned by
    /// the registry; mutators do not set it directly.
    var version: Int = 0

    var hookStoreLookupSessionID: String { hookStoreSessionID ?? sessionID }

    mutating func rememberHookStoreSessionID(_ id: String) {
        if id != sessionID { hookStoreSessionID = id }
    }

    /// When the last hook event moved `state`. Transcript-derived transitions
    /// only overrule a hook decision that is strictly older than the transcript
    /// row they came from, so a fully hooked agent keeps hook semantics while a
    /// half-installed or hook-less one still tracks its own log.
    var lastHookEventAt: Date?

    mutating func setHookLifecycleState(_ nextState: ChatAgentState, at eventAt: Date? = nil) {
        state = nextState
        stateProvenance = .hook
        lastHookEventAt = eventAt ?? lastActivityAt
    }

    /// Applies a state the transcript proved, without claiming hook authority.
    mutating func setTranscriptObservedState(_ nextState: ChatAgentState) {
        state = nextState
        stateProvenance = .transcript
    }

    /// Records that a live agent process was seen — and nothing more. `.idle`
    /// here is the record's "no news yet" value, not a claim that the agent is
    /// waiting, so it stays unpublished until a hook or the transcript speaks.
    mutating func setProcessObservedIdle() {
        state = .idle
        stateProvenance = .unobserved
    }

    mutating func setTranscriptObservedIdle() {
        state = .idle
        stateProvenance = .transcript
    }

    /// Adopts terminal/transcript bindings from a hook-store entry. The
    /// store is rewritten by every hook event, so its non-nil fields are
    /// fresher than the record's (panel UUIDs change across app
    /// relaunches; never keep a stale binding over a present one).
    ///
    /// - Parameter entry: The store entry to adopt from.
    /// - Parameters:
    ///   - entry: The store entry to adopt from.
    ///   - includingPID: Whether to adopt the process id. Failure-driven
    ///     refreshes pass `false`: the store can lag a SessionStart by one
    ///     write, and adopting a dead pid there would let the liveness
    ///     sweep end a live resumed session.
    mutating func adoptBindings(
        from entry: AgentChatHookSessionStore.Entry,
        includingPID: Bool = true
    ) {
        rememberHookStoreSessionID(entry.sessionID)
        surfaceID = entry.surfaceID ?? surfaceID
        workspaceID = entry.workspaceID ?? workspaceID
        transcriptPath = entry.transcriptPath ?? transcriptPath
        workingDirectory = entry.workingDirectory ?? workingDirectory
        if includingPID {
            pid = entry.pid ?? pid
        }
    }

    /// Fills gaps from the hook store without replacing live cmux bindings.
    mutating func adoptMissingBindings(
        from entry: AgentChatHookSessionStore.Entry,
        includingPID: Bool = true
    ) {
        rememberHookStoreSessionID(entry.sessionID)
        if surfaceID == nil { surfaceID = entry.surfaceID }
        if workspaceID == nil { workspaceID = entry.workspaceID }
        if transcriptPath == nil { transcriptPath = entry.transcriptPath }
        if workingDirectory == nil { workingDirectory = entry.workingDirectory }
        if includingPID, pid == nil { pid = entry.pid }
    }

    /// The wire descriptor for this record.
    var descriptor: ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: sessionID,
            agentKind: agentKind,
            title: title,
            workspaceID: workspaceID,
            terminalID: surfaceID,
            workingDirectory: workingDirectory,
            state: state,
            lastActivityAt: lastActivityAt,
            version: version
        )
    }
}
