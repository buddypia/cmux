import Foundation

/// Derives transient session-state signals from durable transcript rows.
///
/// Hook events remain the preferred source for live state, but Codex and
/// Antigravity sessions can surface actionable requests only through their
/// transcript. These helpers keep that transcript-derived path consistent
/// across Mac producers and package tests.
public enum ChatTranscriptStateSignal {
    /// Latest unresolved permission/question timestamp, or nil when the
    /// batch does not require user input.
    public static func needsInputTimestamp(in messages: [ChatMessage]) -> Date? {
        latestTimestamp(in: messages) { kind in
            switch kind {
            case .permissionRequest(let request):
                return request.resolution == nil
            case .question(let question):
                return question.isPending
            case .prose, .thought, .toolUse, .terminal, .fileEdit, .status, .attachment, .unsupported:
                return false
            }
        }
    }

    /// Latest resolved permission/question timestamp, or nil when the batch
    /// does not settle a pending input card.
    public static func resolvedInputTimestamp(in messages: [ChatMessage]) -> Date? {
        latestTimestamp(in: messages) { kind in
            switch kind {
            case .permissionRequest(let request):
                return request.resolution != nil
            case .question(let question):
                return question.isResolved
            case .prose, .thought, .toolUse, .terminal, .fileEdit, .status, .attachment, .unsupported:
                return false
            }
        }
    }

    /// Latest still-running tool/terminal timestamp, or nil when the batch
    /// contains no transcript evidence that the agent is actively working.
    public static func workingTimestamp(in messages: [ChatMessage]) -> Date? {
        latestTimestamp(in: messages) { kind in
            switch kind {
            case .toolUse(let toolUse):
                return toolUse.status == .running
            case .terminal(let capture):
                return capture.isRunning
            case .prose, .thought, .fileEdit, .permissionRequest, .question,
                 .status, .attachment, .unsupported:
                return false
            }
        }
    }

    /// Latest completed tool/terminal timestamp, or nil when the batch contains
    /// no transcript evidence that prior agent work has settled.
    public static func completedWorkTimestamp(in messages: [ChatMessage]) -> Date? {
        latestTimestamp(in: messages) { kind in
            switch kind {
            case .toolUse(let toolUse):
                return toolUse.status != .running
            case .terminal(let capture):
                return !capture.isRunning
            case .prose, .thought, .fileEdit, .permissionRequest, .question,
                 .status, .attachment, .unsupported:
                return false
            }
        }
    }

    /// Latest assistant prose/thought/unsupported timestamp when the batch
    /// contains no in-flight tool or user-action row.
    public static func completedAssistantTurnTimestamp(in messages: [ChatMessage]) -> Date? {
        guard !messages.isEmpty else { return nil }
        var completedAt: Date?
        for message in messages where message.role == .agent {
            switch message.kind {
            case .prose, .thought, .unsupported:
                completedAt = max(completedAt ?? message.timestamp, message.timestamp)
            case .toolUse, .terminal, .fileEdit:
                return nil
            case .permissionRequest(let request):
                if request.resolution == nil { return nil }
            case .question(let question):
                if question.isPending { return nil }
            case .status, .attachment:
                break
            }
        }
        return completedAt
    }

    /// Derives the live state transitions needed when hydrating a session from
    /// an already-existing transcript snapshot.
    public static func initialStateUpdates(
        messages: [ChatMessage],
        stateUpdates: [ChatTranscriptStateUpdate],
        hasPendingTranscriptWork: Bool
    ) -> [ChatTranscriptStateUpdate] {
        let latestInputUpdate = latestInputStateUpdate(messages: messages, stateUpdates: stateUpdates)
        if let latestInputUpdate,
           latestInputUpdate.kind == .needsInput {
            return [latestInputUpdate]
        }

        var candidates = stateUpdates.filter { $0.kind == .working || $0.kind == .idle }
        if let messageUpdate = latestMessageStateUpdate(
            in: messages,
            hasPendingTranscriptWork: hasPendingTranscriptWork,
            matching: { kind in
                switch kind {
                case .toolUse(let toolUse):
                    return toolUse.status == .running ? .working : .idle
                case .terminal(let capture):
                    return capture.isRunning ? .working : .idle
                case .prose, .thought, .unsupported:
                    return .idle
                case .permissionRequest, .question, .fileEdit, .status, .attachment:
                    return nil
                }
            }
        ) {
            candidates.append(messageUpdate)
        }
        let latestWorkUpdate = latestStateUpdate(in: candidates)
        var initialUpdates: [ChatTranscriptStateUpdate] = []
        if let latestInputUpdate,
           latestInputUpdate.kind == .inputResolved {
            initialUpdates.append(latestInputUpdate)
        }
        if let latestWorkUpdate,
           initialUpdates.last.map({ $0 != latestWorkUpdate }) ?? true {
            initialUpdates.append(latestWorkUpdate)
        }
        return ChatTranscriptStateUpdate.applicationOrder(initialUpdates)
    }

    private static func latestInputStateUpdate(
        messages: [ChatMessage],
        stateUpdates: [ChatTranscriptStateUpdate]
    ) -> ChatTranscriptStateUpdate? {
        var candidates = stateUpdates.filter { $0.kind == .needsInput || $0.kind == .inputResolved }
        if let messageUpdate = latestMessageStateUpdate(
            in: messages,
            hasPendingTranscriptWork: false,
            matching: { kind in
                switch kind {
                case .permissionRequest(let request):
                    return request.resolution == nil ? .needsInput : .inputResolved
                case .question(let question):
                    if question.isPending { return .needsInput }
                    return question.isResolved ? .inputResolved : nil
                case .prose, .thought, .toolUse, .terminal, .fileEdit, .status,
                     .attachment, .unsupported:
                    return nil
                }
            }
        ) {
            candidates.append(messageUpdate)
        }
        return latestStateUpdate(in: candidates)
    }

    private static func latestMessageStateUpdate(
        in messages: [ChatMessage],
        hasPendingTranscriptWork: Bool,
        matching kindToUpdate: (ChatMessageKind) -> ChatTranscriptStateUpdate.Kind?
    ) -> ChatTranscriptStateUpdate? {
        var latest: ChatTranscriptStateUpdate?
        for message in messages where message.role == .agent {
            guard let kind = kindToUpdate(message.kind) else { continue }
            guard !hasPendingTranscriptWork || kind != .idle else { continue }
            let update = ChatTranscriptStateUpdate(
                kind: kind,
                seq: message.seq,
                timestamp: message.timestamp
            )
            latest = latestStateUpdate(in: [latest, update].compactMap { $0 })
        }
        return latest
    }

    private static func latestStateUpdate(
        in updates: [ChatTranscriptStateUpdate]
    ) -> ChatTranscriptStateUpdate? {
        ChatTranscriptStateUpdate.latest(in: updates)
    }

    private static func latestTimestamp(
        in messages: [ChatMessage],
        matching matches: (ChatMessageKind) -> Bool
    ) -> Date? {
        var timestamp: Date?
        for message in messages where message.role == .agent && matches(message.kind) {
            timestamp = max(timestamp ?? message.timestamp, message.timestamp)
        }
        return timestamp
    }
}
