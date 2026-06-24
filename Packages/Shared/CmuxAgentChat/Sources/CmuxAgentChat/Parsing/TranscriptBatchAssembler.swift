import Foundation

/// Accumulates the messages of one parse call and routes tool results to
/// the right place: in-batch messages are completed in place, messages from
/// earlier calls are re-emitted as updates.
struct TranscriptBatchAssembler {
    private var messages: [ChatMessage] = []
    private var updatedMessages: [ChatMessage] = []
    private var stateUpdates: [ChatTranscriptStateUpdate] = []
    private var titleUpdate: String?
    private var pending: [String: [ChatMessage]]
    private var batchIndexByMessageID: [String: Int] = [:]
    private var lastAgentProseText: String?
    private var lastUserMessageFingerprint: String?
    private var lastLiveStateKind: ChatTranscriptStateUpdate.Kind?
    private let budget: TranscriptTextBudget

    /// Upper bound on tool invocations carried across parse calls awaiting a
    /// result. A `tool_use` whose `tool_result` never arrives (interrupted or
    /// crashed tool, malformed result line) would otherwise accumulate in
    /// `pending` for the life of the tailer. Capping to the most-recent N (by
    /// seq) bounds the carried state; dropping the oldest unresolved calls only
    /// means an extremely-late result (>N tool calls later) won't back-patch.
    static let maxPendingToolUses = 256

    /// Creates an assembler seeded with carried-over pending tool uses.
    ///
    /// - Parameters:
    ///   - state: The carry-over state from the previous parse call.
    ///   - budget: The text budget applied to completed outputs.
    init(state: ChatTranscriptParseState, budget: TranscriptTextBudget) {
        self.pending = state.pendingToolUses
        self.lastAgentProseText = state.lastAgentProseText
        self.lastUserMessageFingerprint = state.lastUserMessageFingerprint
        self.lastLiveStateKind = state.lastLiveStateKind
        self.budget = budget
    }

    /// Appends a newly parsed message, optionally registering it as a tool
    /// invocation awaiting its result.
    ///
    /// - Parameters:
    ///   - message: The message to append.
    ///   - pendingKey: The tool call identifier to pair a later result by,
    ///     or `nil` for messages that never receive results.
    mutating func append(
        _ message: ChatMessage,
        pendingKey: String? = nil,
        updatesVisibility: Bool = true
    ) {
        if let pendingKey {
            // A single tool call can register multiple messages (a
            // multi-question AskUserQuestion emits one card per question);
            // its result must resolve all of them, so group by call id.
            pending[pendingKey, default: []].append(message)
            batchIndexByMessageID[message.id] = messages.count
        }
        messages.append(message)
        if updatesVisibility {
            noteVisibleMessage(message)
        }
    }

    /// Records a live state transition that should not render as a message.
    mutating func appendStateUpdate(_ update: ChatTranscriptStateUpdate) {
        lastLiveStateKind = update.kind
        stateUpdates.append(update)
    }

    /// Records a session title update that should not render as a message.
    mutating func appendTitleUpdate(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        titleUpdate = trimmed
    }

    /// Records a goal-derived state transition, suppressing repeated ticks
    /// that map to the same live state.
    mutating func appendChangedGoalStateUpdate(
        _ kind: ChatTranscriptStateUpdate.Kind,
        seq: Int,
        timestamp: Date
    ) {
        guard lastLiveStateKind != kind else { return }
        appendStateUpdate(ChatTranscriptStateUpdate(kind: kind, seq: seq, timestamp: timestamp))
    }

    /// Appends agent prose unless it is the same visible body that was just
    /// emitted by another transcript shape.
    ///
    /// Codex mirrors assistant text across `event_msg.agent_message`,
    /// `response_item.message`, and `task_complete.last_agent_message`.
    /// The comparison uses the stored, budgeted body so huge mirrored rows
    /// collapse consistently.
    @discardableResult
    mutating func appendDeduplicatedAgentProse(
        id: String,
        seq: Int,
        timestamp: Date,
        text: String
    ) -> Bool {
        let body = budget.body(text)
        guard lastAgentProseText != body else { return false }
        append(
            ChatMessage(
                id: id,
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: body))
            )
        )
        return true
    }

    /// Appends a user prompt group (attachments followed by prose) unless it
    /// is the same prompt group that was just emitted by a mirrored transcript
    /// row.
    @discardableResult
    mutating func appendDeduplicatedUserMessage(
        attachments: [ChatAttachment],
        proseText: String?,
        fingerprint: String? = nil,
        baseID: String,
        seq: Int,
        timestamp: Date
    ) -> Bool {
        let body = proseText.map { budget.body($0) }
        guard body != nil || !attachments.isEmpty else { return false }
        let fingerprint = fingerprint ?? Self.userMessageFingerprint(
            attachments: attachments,
            proseText: body
        )
        guard lastUserMessageFingerprint != fingerprint else { return false }
        for (index, attachment) in attachments.enumerated() {
            append(
                ChatMessage(
                    id: "\(baseID)-attachment-\(index)",
                    seq: seq,
                    role: .user,
                    timestamp: timestamp,
                    kind: .attachment(attachment)
                ),
                updatesVisibility: false
            )
        }
        if let body {
            append(
                ChatMessage(
                    id: baseID,
                    seq: seq,
                    role: .user,
                    timestamp: timestamp,
                    kind: .prose(ChatProse(text: body))
                ),
                updatesVisibility: false
            )
        }
        lastAgentProseText = nil
        lastUserMessageFingerprint = fingerprint
        return true
    }

    /// Pairs a tool result with its pending invocation, if registered.
    ///
    /// - Parameters:
    ///   - key: The tool call identifier from the result line.
    ///   - completion: The observed result.
    @discardableResult
    mutating func resolve(key: String, completion: TranscriptToolCompletion) -> Bool {
        guard let pendingMessages = pending.removeValue(forKey: key) else { return false }
        // Apply to every message registered under this call id. For
        // questions, `completion.applied` resolves each by its own prompt,
        // so multi-question cards each get their correct answer.
        for pendingMessage in pendingMessages {
            guard let completed = completion.applied(to: pendingMessage, budget: budget) else {
                continue
            }
            recordResolved(completed)
        }
        return true
    }

    /// Resolves only pending permission cards for a tool call, keeping the
    /// underlying running tool pending for its eventual output.
    @discardableResult
    mutating func resolvePermissions(key: String, completion: TranscriptToolCompletion) -> Bool {
        guard let pendingMessages = pending[key] else { return false }
        var unresolvedMessages: [ChatMessage] = []
        var didResolve = false
        for pendingMessage in pendingMessages {
            guard case .permissionRequest = pendingMessage.kind,
                  let completed = completion.applied(to: pendingMessage, budget: budget) else {
                unresolvedMessages.append(pendingMessage)
                continue
            }
            didResolve = true
            recordResolved(completed)
        }
        if unresolvedMessages.isEmpty {
            pending.removeValue(forKey: key)
        } else {
            pending[key] = unresolvedMessages
        }
        return didResolve
    }

    /// Resolves every pending tool/input row, normally when the agent aborts
    /// the turn before individual tool outputs can arrive.
    @discardableResult
    mutating func resolveAll(completion: TranscriptToolCompletion) -> Bool {
        let groups = pending.sorted { lhs, rhs in
            let lhsSeq = lhs.value.first?.seq ?? Int.max
            let rhsSeq = rhs.value.first?.seq ?? Int.max
            if lhsSeq != rhsSeq {
                return lhsSeq < rhsSeq
            }
            return lhs.key < rhs.key
        }
        guard !groups.isEmpty else { return false }
        pending.removeAll()
        for (_, pendingMessages) in groups {
            for pendingMessage in pendingMessages {
                guard let completed = completion.applied(to: pendingMessage, budget: budget) else {
                    continue
                }
                recordResolved(completed)
            }
        }
        return true
    }

    /// Finalizes the batch into a parse result.
    ///
    /// - Parameter lastTimestamp: The last timestamp seen, carried forward.
    /// - Returns: The assembled parse result.
    func result(lastTimestamp: Date?) -> ChatTranscriptParseResult {
        ChatTranscriptParseResult(
            messages: messages,
            updatedMessages: updatedMessages,
            stateUpdates: stateUpdates,
            titleUpdate: titleUpdate,
            state: ChatTranscriptParseState(
                pendingToolUses: Self.bounded(pending),
                lastTimestamp: lastTimestamp,
                lastAgentProseText: lastAgentProseText,
                lastUserMessageFingerprint: lastUserMessageFingerprint,
                lastLiveStateKind: lastLiveStateKind
            )
        )
    }

    private mutating func recordResolved(_ message: ChatMessage) {
        if let index = batchIndexByMessageID[message.id] {
            messages[index] = message
        } else {
            updatedMessages.append(message)
        }
    }

    /// Tracks whether the latest visible row is agent prose. Any other
    /// emitted row clears the duplicate window so a later turn can legitimately
    /// produce the same words again.
    private mutating func noteVisibleMessage(_ message: ChatMessage) {
        guard message.role == .agent, case .prose(let prose) = message.kind else {
            lastAgentProseText = nil
            lastUserMessageFingerprint = nil
            return
        }
        lastAgentProseText = prose.text
        lastUserMessageFingerprint = nil
    }

    private static func userMessageFingerprint(
        attachments: [ChatAttachment],
        proseText: String?
    ) -> String {
        let attachmentPart = attachments.map { attachment in
            [
                attachment.media.rawValue,
                attachment.displayName ?? "",
                attachment.hostPath ?? "",
            ].joined(separator: ":")
        }.joined(separator: "|")
        return "attachments=\(attachmentPart)\ntext=\(proseText ?? "")"
    }

    /// Caps carried pending tool uses to the most-recent ``maxPendingToolUses``
    /// by their newest message seq, evicting the oldest unresolved calls.
    private static func bounded(_ pending: [String: [ChatMessage]]) -> [String: [ChatMessage]] {
        guard pending.count > maxPendingToolUses else { return pending }
        let newestFirst = pending.sorted { lhs, rhs in
            (lhs.value.map(\.seq).max() ?? 0) > (rhs.value.map(\.seq).max() ?? 0)
        }
        return Dictionary(
            uniqueKeysWithValues: newestFirst.prefix(maxPendingToolUses).map { ($0.key, $0.value) }
        )
    }
}
