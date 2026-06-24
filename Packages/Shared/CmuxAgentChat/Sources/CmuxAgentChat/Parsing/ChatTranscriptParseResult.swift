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

    /// Live state transitions observed in this parse call that should not be
    /// rendered as transcript rows.
    public let stateUpdates: [ChatTranscriptStateUpdate]

    /// Latest non-rendered session title update observed in this parse call.
    public let titleUpdate: String?

    /// Carry-over state to pass into the next parse call.
    public let state: ChatTranscriptParseState

    /// Creates a parse result.
    ///
    /// - Parameters:
    ///   - messages: Messages newly produced by this call.
    ///   - updatedMessages: Completed re-emissions of earlier messages.
    ///   - stateUpdates: Non-rendered live state transitions from the lines.
    ///   - titleUpdate: Non-rendered session title update from the lines.
    ///   - state: Carry-over state for the next call.
    public init(
        messages: [ChatMessage],
        updatedMessages: [ChatMessage],
        stateUpdates: [ChatTranscriptStateUpdate] = [],
        titleUpdate: String? = nil,
        state: ChatTranscriptParseState
    ) {
        self.messages = messages
        self.updatedMessages = updatedMessages
        self.stateUpdates = stateUpdates
        self.titleUpdate = titleUpdate
        self.state = state
    }
}
