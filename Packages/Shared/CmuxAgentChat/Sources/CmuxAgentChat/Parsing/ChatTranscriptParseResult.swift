import Foundation

/// The outcome of one incremental transcript parse call.
///
/// Seq assignment: every message parsed from the JSONL line at offset `n`
/// of the input gets `seq == startingSeq + n`, so seqs equal absolute line
/// indexes when the caller tails a file from the top. When one line yields
/// several messages (a Claude assistant line with multiple content blocks)
/// they all share that line's seq and are disambiguated by id suffixes
/// (`uuid`, `uuid#1`, ...). History pagination uses strict `beforeSeq`
/// comparisons, so equal-seq groups never split mid-page as long as
/// producers always emit whole lines and pagers keep equal-seq groups
/// together.
public struct ChatTranscriptParseResult: Sendable, Equatable {
    /// Messages newly produced by this parse call, in transcript order.
    public let messages: [ChatMessage]

    /// Completed re-emissions of messages from *earlier* parse calls whose
    /// tool result arrived in this call. Each carries the original id and
    /// seq; callers replace the stored message by id.
    public let updatedMessages: [ChatMessage]

    /// Artifact occurrences captured from raw pre-budget text or from
    /// artifacts-only sidechain traffic that is intentionally absent from
    /// ``messages``.
    public let artifactReferences: [ChatArtifactTranscriptReference]

    /// State updates emitted by this parse call.
    public let stateUpdates: [ChatTranscriptStateUpdate]

    /// Optional title update emitted during parsing.
    public let titleUpdate: String?

    /// The session's first user prompt, when the transcript states it in a row
    /// that produces no message of its own.
    ///
    /// Codex writes the prompt twice — once as an `event_msg`/`user_message`
    /// telemetry row and once as the `response_item` the chat actually renders.
    /// Only the second becomes a message, so the first has to reach the tailer
    /// through this channel instead; appending it too would show every prompt
    /// twice in the conversation.
    public let promptTitleCandidate: String?

    /// Carry-over state to pass into the next parse call.
    public let state: ChatTranscriptParseState

    /// Creates a parse result.
    ///
    /// - Parameters:
    ///   - messages: Messages newly produced by this call.
    ///   - updatedMessages: Completed re-emissions of earlier messages.
    ///   - artifactReferences: Raw-text and sidechain artifact occurrences.
    ///   - stateUpdates: State updates emitted by this parse call.
    ///   - titleUpdate: Optional title update emitted during parsing.
    ///   - promptTitleCandidate: First user prompt stated by a message-less row.
    ///   - state: Carry-over state for the next call.
    public init(
        messages: [ChatMessage],
        updatedMessages: [ChatMessage],
        artifactReferences: [ChatArtifactTranscriptReference] = [],
        stateUpdates: [ChatTranscriptStateUpdate] = [],
        titleUpdate: String? = nil,
        promptTitleCandidate: String? = nil,
        state: ChatTranscriptParseState
    ) {
        self.messages = messages
        self.updatedMessages = updatedMessages
        self.artifactReferences = artifactReferences
        self.stateUpdates = stateUpdates
        self.titleUpdate = titleUpdate
        self.promptTitleCandidate = promptTitleCandidate
        self.state = state
    }
}
