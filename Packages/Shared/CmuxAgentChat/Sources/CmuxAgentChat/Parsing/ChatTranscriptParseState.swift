import Foundation

/// Carry-over state between incremental transcript parse calls.
///
/// Agent transcripts are tailed: a tool invocation and its result can land
/// in different parse calls. The state carries the registry of tool
/// invocations still awaiting a result so a later call can pair them, the
/// last seen timestamp for lines that omit one, plus lightweight duplicate
/// windows used to collapse mirrored transcript rows. Pass the state returned
/// by one ``ClaudeTranscriptParser/parse(lines:startingSeq:state:)`` or
/// ``CodexTranscriptParser/parse(lines:startingSeq:state:)`` call into the
/// next.
public struct ChatTranscriptParseState: Sendable, Equatable, Codable {
    /// Tool invocations awaiting a result, keyed by the transcript's tool
    /// call identifier (`tool_use_id` for Claude, `call_id` for Codex).
    ///
    /// Each value is the already-emitted message in its running form; when
    /// the result line arrives the parser re-emits a completed copy through
    /// ``ChatTranscriptParseResult/updatedMessages``.
    public var pendingToolUses: [String: [ChatMessage]]

    /// Timestamp of the last line that carried one, used as the fallback
    /// for subsequent lines that omit a timestamp.
    public var lastTimestamp: Date?

    /// Body of the most recent emitted agent prose message, when it is still
    /// the latest visible row. Codex mirrors the same agent text through
    /// `event_msg.agent_message`, `response_item.message`, and
    /// `task_complete.last_agent_message`; carrying this value across tail
    /// batches lets the parser drop those mechanical duplicates.
    public var lastAgentProseText: String?

    /// Fingerprint of the most recent emitted user prompt group, when it is
    /// still the latest visible row. Codex can mirror the same user prompt
    /// through `response_item.message` and `event_msg.user_message`; carrying
    /// this value lets the parser collapse those mechanical duplicates,
    /// including image attachments, without storing raw image payloads.
    public var lastUserMessageFingerprint: String?

    /// Latest live state emitted by the parser.
    ///
    /// Codex emits frequent `thread_goal_updated` rows while a long-running
    /// goal is active. Carrying the last state lets the parser publish only
    /// meaningful goal transitions instead of sending a state batch every
    /// progress tick.
    public var lastLiveStateKind: ChatTranscriptStateUpdate.Kind?

    /// Creates parse carry-over state.
    ///
    /// - Parameters:
    ///   - pendingToolUses: Tool invocations awaiting a result, keyed by
    ///     tool call identifier.
    ///   - lastTimestamp: Timestamp fallback for lines without one.
    ///   - lastAgentProseText: Latest emitted agent prose body, for duplicate
    ///     suppression across incremental parse calls.
    ///   - lastUserMessageFingerprint: Latest emitted user prompt group, for
    ///     duplicate suppression across incremental parse calls.
    ///   - lastLiveStateKind: Latest emitted live state, for suppressing
    ///     repeated progress ticks.
    public init(
        pendingToolUses: [String: [ChatMessage]] = [:],
        lastTimestamp: Date? = nil,
        lastAgentProseText: String? = nil,
        lastUserMessageFingerprint: String? = nil,
        lastLiveStateKind: ChatTranscriptStateUpdate.Kind? = nil
    ) {
        self.pendingToolUses = pendingToolUses
        self.lastTimestamp = lastTimestamp
        self.lastAgentProseText = lastAgentProseText
        self.lastUserMessageFingerprint = lastUserMessageFingerprint
        self.lastLiveStateKind = lastLiveStateKind
    }

    private enum CodingKeys: String, CodingKey {
        case pendingToolUses = "pending_tool_uses"
        case lastTimestamp = "last_timestamp"
        case lastAgentProseText = "last_agent_prose_text"
        case lastUserMessageFingerprint = "last_user_message_fingerprint"
        case lastLiveStateKind = "last_live_state_kind"
    }
}
