import Foundation

/// Converts Antigravity CLI history JSONL lines into ``ChatMessage`` values.
///
/// Reads the lightweight prompt history written under
/// `~/.gemini/antigravity-cli/history.jsonl`: each line describes one
/// conversation entry and identifies its conversation with keys such as
/// `conversationId` or `sessionId`. The history is shared across
/// conversations, so this parser filters to the session id passed at
/// initialization. When cmux has a per-session Antigravity transcript path,
/// the same parser also accepts Antigravity/Gemini role-discriminated JSONL
/// (`role: user/model/tool/event`), current `type: user/gemini` JSONL
/// records, and Antigravity's newer single-object `.json` session files whose
/// turns live under `messages[]`.
public struct AntigravityTranscriptParser: Sendable {
    private static let sessionIDKeys = [
        "conversationId", "conversation_id", "sessionId", "session_id", "id",
    ]
    private static let contentKeys = ["display", "prompt", "text", "message"]
    private static let typedHistoryRecordTypes: Set<String> = [
        "slash_command", "shell",
    ]
    private static let shellToolNames: Set<String> = [
        "bash", "shell", "run_command", "run_shell_command", "execute_bash",
    ]
    private static let questionToolNames: Set<String> = [
        "askuserquestion", "request_user_input", "ask_user_question", "ask_question",
    ]
    private static let permissionToolNames: Set<String> = [
        "ask_permission",
    ]
    private static let brainToolResultTypes: Set<String> = [
        "run_command", "view_file", "list_directory", "code_action",
        "grep_search", "search_web", "generate_image", "mcp_tool",
        "ask_question", "read_url_content", "generic",
    ]
    private static let questionRequestIDKeys = [
        "callId", "call_id", "requestId", "request_id",
        "toolCallId", "tool_call_id", "id",
    ]
    private static let questionArgumentKeys = [
        "args", "arguments", "parameters", "input", "toolInput",
        "tool_input", "payload", "data",
    ]
    private static let questionToolCallKeys = [
        "toolCall", "tool_call", "functionCall", "function_call",
    ]
    private static let functionCallKeys = ["functionCall", "function_call"]
    private static let functionResponseKeys = ["functionResponse", "function_response"]
    private static let toolCallIDKeys = [
        "id", "callId", "call_id", "toolCallId", "tool_call_id",
    ]
    private static let toolCallNameKeys = [
        "name", "toolName", "tool_name", "functionName", "function_name",
    ]
    private static let toolCallArgumentKeys = [
        "args", "arguments", "parameters", "input", "toolInput", "tool_input",
    ]
    private static let toolCallResultKeys = ["result", "results", "toolResults", "tool_results"]
    private static let toolResponsePayloadKeys = ["response", "result", "data", "payload"]
    private static let toolResponseOutputKeys = [
        "output", "result", "content", "message", "text",
        "formattedOutput", "formatted_output",
        "aggregatedOutput", "aggregated_output",
        "stdout", "standardOutput", "standard_output",
        "savedPath", "saved_path",
        "revisedPrompt", "revised_prompt",
    ]
    private static let toolResponseErrorKeys = [
        "error", "stderr", "standardError", "standard_error",
        "errorMessage", "error_message",
    ]
    private static let toolResponseExitCodeKeys = ["exit_code", "exitCode", "code"]
    private static let toolResponseDurationSecondKeys = [
        "duration", "duration_seconds", "durationSeconds",
        "elapsed_seconds", "elapsedSeconds",
    ]
    private static let toolResponseDurationMillisecondKeys = [
        "duration_ms", "durationMs", "elapsed_ms", "elapsedMs",
    ]
    private static let toolResponseNonInputKeys = Set(
        toolResponseOutputKeys
            + toolResponseErrorKeys
            + toolResponseExitCodeKeys
            + toolResponseDurationSecondKeys
            + toolResponseDurationMillisecondKeys
            + toolResponsePayloadKeys
            + ["metadata", "status", "timestamp", "created_at", "createdAt"]
    )
    private static let toolResultSucceededStatuses: Set<String> = [
        "success", "succeeded", "ok", "completed", "complete", "done",
    ]
    private static let toolResultFailedStatuses: Set<String> = [
        "error", "fail", "failed", "failure", "cancel", "cancelled", "canceled",
        "timeout", "timed_out",
    ]
    private static let summaryArgumentKeys = [
        "absolute_path", "path", "file_path", "command", "query", "url",
        "text", "name",
    ]
    private static let authorizationEventNames: Set<String> = [
        "tool_authorization_required", "permission_required",
    ]
    private static let authorizationResolutionEventNames: Set<String> = [
        "tool_authorization_decision", "tool_authorization_result",
        "tool_authorization_response", "tool_authorization_resolved",
        "permission_decision", "permission_result", "permission_response",
        "permission_resolved",
    ]
    private static let authorizationRequestIDKeys = [
        "requestId", "request_id", "toolCallId", "tool_call_id", "id",
    ]
    private static let authorizationResolutionKeys = [
        "decision", "resolution", "status", "outcome", "result",
        "approved", "allowed", "allow", "denied",
    ]
    private static let authorizationToolNameKeys = [
        "toolName", "tool_name", "functionName", "function_name",
    ]
    private static let authorizationArgumentKeys = [
        "args", "arguments", "parameters", "input", "toolInput", "tool_input",
    ]
    private static let authorizationSubjectKeys = [
        "command", "cmd", "query", "subject", "display", "prompt",
        "description", "reason", "text", "message",
    ]
    private static let authorizationToolCallKeys = [
        "toolCall", "tool_call", "functionCall", "function_call",
    ]
    private static let lifecycleStartedEventNames: Set<String> = [
        "task_started",
    ]
    private static let lifecycleCompletedEventNames: Set<String> = [
        "task_complete", "turn_complete",
    ]
    private static let lifecycleInterruptedEventNames: Set<String> = [
        "turn_aborted",
    ]
    private static let errorEventNames: Set<String> = [
        "error", "error_message", "stream_error",
    ]

    private let sessionID: String
    private let budget = TranscriptTextBudget()
    private let isoTimestamps = TranscriptTimestampParser()

    /// Creates an Antigravity history parser for one conversation.
    ///
    /// - Parameter sessionID: The Antigravity conversation/session id to
    ///   select from the shared `history.jsonl` file.
    public init(sessionID: String) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a contiguous run of JSONL history lines into chat messages.
    ///
    /// - Parameters:
    ///   - lines: The raw JSONL lines from Antigravity's `history.jsonl`.
    ///   - startingSeq: The absolute line index of the first input line;
    ///     each parsed message gets `seq == startingSeq + lineOffset`.
    ///   - state: Carry-over state from the previous parse call.
    /// - Returns: New user prompt messages and the updated timestamp state.
    public func parse(
        lines: some Sequence<String>,
        startingSeq: Int,
        state: ChatTranscriptParseState = ChatTranscriptParseState()
    ) -> ChatTranscriptParseResult {
        var assembler = TranscriptBatchAssembler(state: state, budget: budget)
        var lastTimestamp = state.lastTimestamp
        for (offset, line) in lines.enumerated() {
            let seq = startingSeq + offset
            guard let root = TranscriptJSONValue(jsonLine: line), root.object != nil else {
                continue
            }
            if let stamped = timestamp(in: root, keys: ["timestamp", "created_at", "createdAt"]) {
                lastTimestamp = stamped
            }
            let currentTimestamp = lastTimestamp ?? Date(timeIntervalSince1970: 0)

            if appendRoleTranscriptRecord(root, seq: seq, timestamp: currentTimestamp, into: &assembler) {
                continue
            }

            if appendCurrentAgyRecord(root, seq: seq, timestamp: currentTimestamp, into: &assembler) {
                continue
            }

            guard Self.historySessionID(in: root) == sessionID,
                  let text = Self.historyText(in: root) else { continue }
            assembler.append(userProse(text, id: "line-\(seq)", seq: seq, timestamp: currentTimestamp))
        }
        return assembler.result(lastTimestamp: lastTimestamp)
    }

    /// Parses Antigravity's single-object session JSON format.
    ///
    /// The current `agy` CLI can write a pretty-printed JSON document at
    /// `~/.antigravity/tmp/<sha256(cwd)>/chats/session-*.json` with a top-level
    /// `sessionId` and `messages[]`. That file cannot be tailed by line offset;
    /// callers should parse the whole file whenever its mtime changes and diff
    /// by the stable message ids produced here.
    ///
    /// - Parameters:
    ///   - raw: The full JSON document text.
    ///   - startingSeq: Sequence offset for the first `messages[]` element.
    ///   - state: Carry-over state, normally empty for whole-file reparses.
    /// - Returns: A parse result, or `nil` when the file is not a complete
    ///   Antigravity session JSON document for this parser's session id.
    public func parseSessionJSON(
        _ raw: String,
        startingSeq: Int = 0,
        state: ChatTranscriptParseState = ChatTranscriptParseState()
    ) -> ChatTranscriptParseResult? {
        guard let root = TranscriptJSONValue(jsonString: raw),
              root.object != nil else {
            return nil
        }
        if let generatedMessage = parseGeneratedMessageJSON(root, startingSeq: startingSeq, state: state) {
            return generatedMessage
        }
        guard let fileSessionID = root["sessionId"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileSessionID.isEmpty,
              let messages = root["messages"]?.array else {
            return nil
        }
        if !sessionID.isEmpty, fileSessionID != sessionID {
            return nil
        }

        var assembler = TranscriptBatchAssembler(state: state, budget: budget)
        var lastTimestamp = timestamp(from: root["startTime"]) ?? state.lastTimestamp
        for (offset, message) in messages.enumerated() {
            guard message.object != nil else { continue }
            let seq = startingSeq + offset
            if let stamped = timestamp(in: message, keys: ["timestamp", "created_at", "createdAt"]) {
                lastTimestamp = stamped
            }
            let currentTimestamp = lastTimestamp ?? Date(timeIntervalSince1970: 0)

            if appendCurrentAgyRecord(message, seq: seq, timestamp: currentTimestamp, into: &assembler) {
                continue
            }
            if appendRoleTranscriptRecord(message, seq: seq, timestamp: currentTimestamp, into: &assembler) {
                continue
            }
        }
        return assembler.result(lastTimestamp: lastTimestamp)
    }

    private func parseGeneratedMessageJSON(
        _ root: TranscriptJSONValue,
        startingSeq: Int,
        state: ChatTranscriptParseState
    ) -> ChatTranscriptParseResult? {
        guard let sender = root["sender"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let recipient = root["recipient"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              generatedMessageBelongsToSession(sender: sender, recipient: recipient) else {
            return nil
        }

        let timestamp = self.timestamp(in: root, keys: ["timestamp", "created_at", "createdAt"])
            ?? state.lastTimestamp
            ?? Date(timeIntervalSince1970: 0)
        var assembler = TranscriptBatchAssembler(state: state, budget: budget)
        if root["hideFromUser"]?.bool == true {
            if Self.hiddenGeneratedMessageIndicatesWorkStopped(root) {
                appendStateUpdate(.idle, seq: startingSeq, timestamp: timestamp, into: &assembler)
            }
            return assembler.result(lastTimestamp: timestamp)
        }
        guard let text = Self.currentAgyContent(in: root),
              let role = generatedMessageRole(sender: sender, recipient: recipient) else {
            return nil
        }
        if role == .user,
           generatedMessageIsTaskControlInput(root, sender: sender, recipient: recipient, content: text) {
            return assembler.result(lastTimestamp: timestamp)
        }
        if role == .agent, generatedMessageIsInternalTimer(root) {
            return assembler.result(lastTimestamp: timestamp)
        }
        if role != .user,
           generatedMessageIndicatesInterruption(root, content: text) {
            appendStateUpdate(.idle, seq: startingSeq, timestamp: timestamp, into: &assembler)
            assembler.append(status(.interrupted, detail: text, seq: startingSeq, timestamp: timestamp))
            return assembler.result(lastTimestamp: timestamp)
        }
        if role == .agent,
           let terminal = generatedCommandInputTerminal(in: root, content: text) {
            appendStateUpdate(.needsInput, seq: startingSeq, timestamp: timestamp, into: &assembler)
            assembler.append(
                ChatMessage(
                    id: root["id"]?.string ?? "line-\(startingSeq)",
                    seq: startingSeq,
                    role: role,
                    timestamp: timestamp,
                    kind: .terminal(terminal)
                ),
                pendingKey: generatedTaskPendingKey(sender: sender)
            )
            return assembler.result(lastTimestamp: timestamp)
        }
        if role == .agent,
           let terminal = generatedTaskResultTerminal(in: root, content: text) {
            if let pendingKey = generatedTaskPendingKey(sender: sender),
               assembler.resolve(
                   key: pendingKey,
                   completion: TranscriptToolCompletion(
                       output: terminal.output,
                       isError: (terminal.exitCode ?? 0) != 0,
                       exitCode: terminal.exitCode,
                       durationSeconds: terminal.durationSeconds,
                       timestamp: timestamp
                   )
               ) {
                appendStateUpdate(.inputResolved, seq: startingSeq, timestamp: timestamp, into: &assembler)
                appendStateUpdate(.idle, seq: startingSeq, timestamp: timestamp, into: &assembler)
                return assembler.result(lastTimestamp: timestamp)
            }
            assembler.append(
                ChatMessage(
                    id: root["id"]?.string ?? "line-\(startingSeq)",
                    seq: startingSeq,
                    role: role,
                    timestamp: timestamp,
                    kind: .terminal(terminal)
                )
            )
            return assembler.result(lastTimestamp: timestamp)
        }
        assembler.append(
            ChatMessage(
                id: root["id"]?.string ?? "line-\(startingSeq)",
                seq: startingSeq,
                role: role,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: budget.body(text)))
            )
        )
        return assembler.result(lastTimestamp: timestamp)
    }

    private func generatedTaskPendingKey(sender: String) -> String? {
        guard isSessionPath(sender), !isSessionRoot(sender) else { return nil }
        return "generated-task:\(sender)"
    }

    private func generatedMessageIsTaskControlInput(
        _ root: TranscriptJSONValue,
        sender: String,
        recipient: String,
        content: String
    ) -> Bool {
        guard generatedMessageTitle(in: root) == nil,
              isSessionRoot(sender),
              isSessionPath(recipient) else {
            return false
        }
        switch content.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "R", "r", "q":
            return true
        default:
            return false
        }
    }

    private static func hiddenGeneratedMessageIndicatesWorkStopped(_ root: TranscriptJSONValue) -> Bool {
        guard let text = currentAgyContent(in: root) else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("background tasks have been stopped")
            || normalized.contains("subagents and background tasks have been stopped")
            || normalized.contains("stopped due to server restart")
    }

    private func generatedMessageIsInternalTimer(_ root: TranscriptJSONValue) -> Bool {
        guard let title = generatedMessageTitle(in: root) else { return false }
        return title.range(of: "Timer has expired", options: [.caseInsensitive]) != nil
            || title.range(of: "Timer Cancelled", options: [.caseInsensitive]) != nil
            || title.range(of: "Timer Canceled", options: [.caseInsensitive]) != nil
    }

    private func generatedMessageIndicatesInterruption(
        _ root: TranscriptJSONValue,
        content: String
    ) -> Bool {
        [generatedMessageTitle(in: root), content].compactMap { $0 }
            .contains { Self.generatedNoticeTextIndicatesInterruption($0) }
    }

    private static func generatedNoticeTextIndicatesInterruption(_ text: String) -> Bool {
        let normalized = normalizedInfoText(text)
        guard !normalized.isEmpty,
              normalized.count <= 240,
              normalized.components(separatedBy: .newlines).count <= 3 else {
            return false
        }
        return infoTextIndicatesInterruption(normalized)
    }

    private func generatedCommandInputTerminal(
        in root: TranscriptJSONValue,
        content: String
    ) -> ChatTerminalCapture? {
        let normalized = Self.generatedTaskResultText(content)
        guard generatedMessageIndicatesCommandInput(root, content: normalized) else {
            return nil
        }
        return ChatTerminalCapture(
            command: generatedCommandInputCommand(in: root),
            output: budget.body(normalized),
            isRunning: true
        )
    }

    private func generatedMessageIndicatesCommandInput(
        _ root: TranscriptJSONValue,
        content: String
    ) -> Bool {
        if generatedMessageTitle(in: root)?
            .range(of: "Command may require input", options: [.caseInsensitive]) != nil {
            return true
        }
        return content.range(
            of: "The command appears to be waiting for input",
            options: [.caseInsensitive]
        ) != nil
    }

    private func generatedCommandInputCommand(in root: TranscriptJSONValue) -> String {
        let title = generatedMessageTitle(in: root) ?? "Command may require input"
        guard let marker = title.range(
            of: ": Command may require input",
            options: [.caseInsensitive]
        ) else {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let command = String(title[..<marker.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? "Command may require input" : command
    }

    private func generatedTaskResultTerminal(
        in root: TranscriptJSONValue,
        content: String
    ) -> ChatTerminalCapture? {
        let normalized = Self.generatedTaskResultText(content)
        guard let markerRange = normalized.range(of: " finished with result:"),
              normalized.hasPrefix("Task id ") else {
            return nil
        }

        let body = String(normalized[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyLines = Self.strippingGeneratedTaskIndent(body)
            .components(separatedBy: .newlines)
        let exitCode: Int?
        if let failed = bodyLines.first?.range(
            of: #"^The command failed with exit code: ([0-9]+)"#,
            options: .regularExpression
        ) {
            let match = String(bodyLines[0][failed])
            exitCode = match.split(separator: " ").last.flatMap { Int($0) }
        } else if bodyLines.first == "The command completed successfully." {
            exitCode = 0
        } else {
            exitCode = nil
        }

        guard let outputIndex = bodyLines.firstIndex(of: "Output:") else {
            return nil
        }
        let output = bodyLines[(outputIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }

        return ChatTerminalCapture(
            command: generatedTaskCommand(in: root, fallback: String(normalized[..<markerRange.lowerBound])),
            output: budget.body(Self.collapsingGeneratedTaskBlankLines(output)),
            exitCode: exitCode,
            isRunning: false
        )
    }

    private func generatedTaskCommand(
        in root: TranscriptJSONValue,
        fallback: String
    ) -> String {
        let title = generatedMessageTitle(in: root)
        let raw = title?.isEmpty == false ? title! : fallback
        if raw.hasSuffix(" finished") {
            return String(raw.dropLast(" finished".count))
        }
        return raw
    }

    private func generatedMessageTitle(in root: TranscriptJSONValue) -> String? {
        let title = root["renderDetails"]?["messageTitle"]?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    private static func generatedTaskResultText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingGeneratedTaskIndent(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                if line.hasPrefix("\t\t\t\t") {
                    return String(line.dropFirst(4))
                }
                if line.hasPrefix("                ") {
                    return String(line.dropFirst(16))
                }
                return line
            }
            .joined(separator: "\n")
    }

    private static func collapsingGeneratedTaskBlankLines(_ text: String) -> String {
        var lines: [String] = []
        var previousWasBlank = false
        for line in text.components(separatedBy: .newlines) {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard !isBlank || !previousWasBlank else { continue }
            lines.append(line)
            previousWasBlank = isBlank
        }
        return lines.joined(separator: "\n")
    }

    private func generatedMessageBelongsToSession(sender: String, recipient: String) -> Bool {
        guard !sessionID.isEmpty else { return true }
        return isSessionPath(sender) || isSessionPath(recipient)
    }

    private func generatedMessageRole(sender: String, recipient: String) -> ChatRole? {
        if sender == "system" {
            return .system
        }
        if isSessionRoot(sender) {
            return .user
        }
        if isSessionPath(sender) {
            return .agent
        }
        if isSessionRoot(recipient) {
            return .agent
        }
        if isSessionPath(recipient) {
            return .user
        }
        return sessionID.isEmpty ? .agent : nil
    }

    private func isSessionRoot(_ value: String) -> Bool {
        !sessionID.isEmpty && value == sessionID
    }

    private func isSessionPath(_ value: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        return value == sessionID || value.hasPrefix("\(sessionID)/")
    }

    // MARK: - Antigravity JSONL transcript records

    private func appendRoleTranscriptRecord(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        guard let role = root["role"]?.string else { return false }
        let normalizedRole = Self.normalizedEventName(role)
        switch normalizedRole {
        case "user":
            let text = (root["parts"]?.array ?? [])
                .flatMap { Self.textFragments(from: $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            guard !text.isEmpty else { return true }
            assembler.append(userProse(text, id: "line-\(seq)", seq: seq, timestamp: timestamp))
        case "model":
            appendModelParts(root["parts"]?.array ?? [], seq: seq, timestamp: timestamp, into: &assembler)
        case "tool":
            resolveToolParts(root["parts"]?.array ?? [], seq: seq, timestamp: timestamp, into: &assembler)
        case "event":
            appendEvent(root, seq: seq, timestamp: timestamp, into: &assembler)
        default:
            return true
        }
        return true
    }

    private func appendCurrentAgyRecord(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        guard let type = root["type"]?.string else {
            if root["sessionId"]?.string != nil, root["projectHash"]?.string != nil {
                assembler.append(status(.sessionStarted, detail: root["model"]?.string, seq: seq, timestamp: timestamp))
                return true
            }
            return false
        }

        if appendLifecycleEvent(type, root: root, seq: seq, timestamp: timestamp, into: &assembler) {
            return true
        }
        if appendAuthorizationEvent(type, root: root, seq: seq, timestamp: timestamp, into: &assembler) {
            return true
        }
        if appendErrorEvent(type, root: root, seq: seq, timestamp: timestamp, into: &assembler) {
            return true
        }

        let normalizedType = Self.normalizedEventName(type)
        switch normalizedType {
        case "user", "user_input":
            guard let text = Self.currentAgyContent(in: root) else { return true }
            assembler.append(userProse(text, id: root["id"]?.string ?? "line-\(seq)", seq: seq, timestamp: timestamp))
        case "gemini":
            appendGeminiMessage(root, seq: seq, timestamp: timestamp, into: &assembler)
        case "planner_response":
            appendBrainPlannerResponse(root, seq: seq, timestamp: timestamp, into: &assembler)
        case "system_message":
            if let text = Self.brainSystemMessageText(in: root) {
                assembler.append(systemProse(
                    text,
                    id: root["id"]?.string ?? "line-\(seq)-system-message",
                    seq: seq,
                    timestamp: timestamp
                ))
            }
        case "conversation_history", "checkpoint":
            return true
        case "info":
            if let text = Self.currentAgyContent(in: root) {
                if Self.infoTextIndicatesAuthenticationResolved(text) {
                    appendStateUpdate(.inputResolved, seq: seq, timestamp: timestamp, into: &assembler)
                    assembler.append(systemProse(
                        text,
                        id: root["id"]?.string ?? "line-\(seq)-info",
                        seq: seq,
                        timestamp: timestamp
                    ))
                } else if Self.infoTextIndicatesAuthenticationRequired(text) {
                    appendStateUpdate(.needsInput, seq: seq, timestamp: timestamp, into: &assembler)
                    assembler.append(systemProse(
                        text,
                        id: root["id"]?.string ?? "line-\(seq)-info",
                        seq: seq,
                        timestamp: timestamp
                    ))
                } else if Self.infoTextIndicatesInterruption(text) {
                    resolvePendingAsInterrupted(output: text, timestamp: timestamp, into: &assembler)
                    appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
                    assembler.append(status(.interrupted, detail: text, seq: seq, timestamp: timestamp))
                } else {
                    assembler.append(systemProse(
                        text,
                        id: root["id"]?.string ?? "line-\(seq)-info",
                        seq: seq,
                        timestamp: timestamp
                    ))
                }
            }
        case "warning":
            if let text = Self.currentAgyContent(in: root)
                ?? Self.firstString(in: root, keys: ["message", "warning", "description"]) {
                assembler.append(systemProse(
                    text,
                    id: root["id"]?.string ?? "line-\(seq)-warning",
                    seq: seq,
                    timestamp: timestamp
                ))
            }
        default:
            if Self.typedHistoryRecordTypes.contains(normalizedType) {
                return false
            }
            if Self.brainToolResultTypes.contains(normalizedType) {
                appendBrainToolResult(root, type: type, seq: seq, timestamp: timestamp, into: &assembler)
            }
            return true
        }
        return true
    }

    private static func infoTextIndicatesAuthenticationRequired(_ text: String) -> Bool {
        let normalized = normalizedInfoText(text)
        return normalized.contains("login required")
            || normalized.contains("waiting for authentication")
            || normalized.contains("open authentication page")
            || normalized.contains("authentication page")
    }

    private static func infoTextIndicatesAuthenticationResolved(_ text: String) -> Bool {
        let normalized = normalizedInfoText(text)
        return normalized.contains("authentication succeeded")
            || normalized.contains("authentication successful")
            || normalized.contains("login succeeded")
            || normalized.contains("login successful")
    }

    private static func infoTextIndicatesInterruption(_ text: String) -> Bool {
        let normalized = normalizedInfoText(text)
        return normalized.contains("request cancelled")
            || normalized.contains("request canceled")
            || normalized.contains("request failed")
            || normalized.contains("user cancelled")
            || normalized.contains("user canceled")
            || normalized.contains("request has been halted")
            || normalized.contains("response stopped")
            || normalized.contains("response truncated")
            || normalized.contains("malformed function call")
            || normalized.contains("final error")
    }

    private static func normalizedInfoText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func appendStateUpdate(
        _ kind: ChatTranscriptStateUpdate.Kind,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        assembler.appendStateUpdate(
            ChatTranscriptStateUpdate(kind: kind, seq: seq, timestamp: timestamp)
        )
    }

    private func appendBrainPlannerResponse(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        if let thought = root["thinking"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thought.isEmpty {
            assembler.append(
                ChatMessage(
                    id: "line-\(seq)-brain-thinking",
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: .thought(ChatThought(text: budget.body(thought)))
                )
            )
        }
        if let text = Self.currentAgyContent(in: root) {
            assembler.append(agentProse(text, id: root["id"]?.string ?? "line-\(seq)-brain-content", seq: seq, timestamp: timestamp))
        }
        for (index, call) in (Self.firstArray(in: root, keys: ["tool_calls", "toolCalls"]) ?? []).enumerated() {
            let fallbackID = "line-\(seq)-brain-tool-\(index)"
            guard let name = Self.toolCallName(in: call) else { continue }
            let args = Self.toolCallArguments(in: call)
            let callID = Self.toolCallID(in: call)
            if Self.isQuestionToolName(name),
               appendQuestionRequest(
                   args,
                   baseID: callID ?? fallbackID,
                   pendingKey: callID,
                   seq: seq,
                   timestamp: timestamp,
                   into: &assembler
               ) {
                continue
            }
            if Self.isPermissionToolName(name),
               appendPermissionRequest(
                   args,
                   baseID: callID ?? fallbackID,
                   seq: seq,
                   timestamp: timestamp,
                   into: &assembler
               ) {
                continue
            }
            // Current brain logs do not include ids for ordinary tool calls,
            // while their result rows are separate records. Avoid emitting an
            // unresolvable running tool row unless a future log format gives
            // us a stable id to pair with a later completion.
            guard callID != nil else { continue }
            appendFunctionCall(
                call,
                fallbackID: fallbackID,
                seq: seq,
                timestamp: self.timestamp(in: call, keys: ["timestamp", "created_at", "createdAt"]) ?? timestamp,
                into: &assembler
            )
        }
    }

    private func appendBrainToolResult(
        _ root: TranscriptJSONValue,
        type: String,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let content = Self.currentAgyContent(in: root) else { return }
        let status = brainToolStatus(from: root["status"]?.string)
        assembler.append(
            ChatMessage(
                id: root["id"]?.string ?? "line-\(seq)-brain-tool",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: type,
                        summary: type,
                        output: budget.body(content),
                        status: status
                    )
                )
            )
        )
    }

    private func brainToolStatus(from rawStatus: String?) -> ChatToolUse.Status {
        guard let rawStatus else { return .succeeded }
        let normalized = rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if normalized.contains("running") || normalized.contains("in_progress") {
            return .running
        }
        if normalized.contains("error") || normalized.contains("fail")
            || normalized.contains("cancel") || normalized.contains("timeout") {
            return .failed
        }
        return .succeeded
    }

    private func appendModelParts(
        _ parts: [TranscriptJSONValue],
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        for (index, part) in parts.enumerated() {
            if let thought = part["thought"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thought.isEmpty {
                assembler.append(
                    ChatMessage(
                        id: "line-\(seq)-thought-\(index)",
                        seq: seq,
                        role: .agent,
                        timestamp: timestamp,
                        kind: .thought(ChatThought(text: budget.body(thought)))
                    )
                )
            }
            if let text = part["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                assembler.append(agentProse(text, id: "line-\(seq)-text-\(index)", seq: seq, timestamp: timestamp))
            }
            if let call = Self.firstNestedObject(in: part, keys: Self.functionCallKeys) {
                let callTimestamp = self.timestamp(from: call["timestamp"])
                    ?? self.timestamp(from: part["timestamp"])
                    ?? timestamp
                appendFunctionCall(
                    call,
                    fallbackID: "line-\(seq)-tool-\(index)",
                    seq: seq,
                    timestamp: callTimestamp,
                    into: &assembler
                )
            }
        }
    }

    private func appendGeminiMessage(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        if let text = Self.currentAgyContent(in: root) {
            assembler.append(agentProse(text, id: root["id"]?.string ?? "line-\(seq)", seq: seq, timestamp: timestamp))
        }
        for (index, thought) in (root["thoughts"]?.array ?? []).enumerated() {
            guard let description = thought["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !description.isEmpty else { continue }
            assembler.append(
                ChatMessage(
                    id: "line-\(seq)-thought-\(index)",
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: .thought(ChatThought(text: budget.body(description)))
                )
            )
        }
        for (index, call) in (Self.firstArray(in: root, keys: ["toolCalls", "tool_calls"]) ?? []).enumerated() {
            let callTimestamp = self.timestamp(from: call["timestamp"]) ?? timestamp
            appendFunctionCall(
                call,
                fallbackID: Self.toolCallID(in: call) ?? "line-\(seq)-tool-\(index)",
                seq: seq,
                timestamp: callTimestamp,
                into: &assembler
            )
            if let id = Self.toolCallID(in: call),
                   let completion = completion(
                       fromToolResults: Self.firstArray(in: call, keys: Self.toolCallResultKeys),
                       status: call["status"]?.string,
                       timestamp: callTimestamp
                   ) {
                assembler.resolve(key: id, completion: completion)
            }
        }
    }

    private func appendFunctionCall(
        _ call: TranscriptJSONValue,
        fallbackID: String,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let name = Self.toolCallName(in: call) else { return }
        let callID = Self.toolCallID(in: call)
        let args = Self.toolCallArguments(in: call)
        if Self.isQuestionToolName(name),
           appendQuestionRequest(
               args,
               baseID: callID ?? fallbackID,
               pendingKey: callID,
               seq: seq,
               timestamp: timestamp,
               into: &assembler
           ) {
            return
        }
        if Self.isShellToolName(name), let command = shellCommand(from: args) {
            assembler.append(
                ChatMessage(
                    id: callID ?? fallbackID,
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: .terminal(ChatTerminalCapture(command: command, isRunning: true))
                ),
                pendingKey: callID
            )
        } else {
            assembler.append(
                ChatMessage(
                    id: callID ?? fallbackID,
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: genericToolUseKind(toolName: name, args: args)
                ),
                pendingKey: callID
            )
        }
    }

    @discardableResult
    private func appendQuestionRequest(
        _ args: TranscriptJSONValue?,
        baseID: String,
        pendingKey: String?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let kinds = questionKinds(args: args)
        guard !kinds.isEmpty else { return false }
        for (index, kind) in kinds.enumerated() {
            assembler.append(
                ChatMessage(
                    id: indexedID(baseID, index: index),
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: kind
                ),
                pendingKey: pendingKey
            )
        }
        return true
    }

    private func resolveToolParts(
        _ parts: [TranscriptJSONValue],
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        for (index, part) in parts.enumerated() {
            guard let response = Self.firstNestedObject(in: part, keys: Self.functionResponseKeys),
                  let id = Self.toolCallID(in: response) else { continue }
            let result = toolResponseResult(in: response)
            let resolved = assembler.resolve(
                key: id,
                completion: TranscriptToolCompletion(
                    output: result.error ?? result.output,
                    isError: result.error != nil || (result.exitCode ?? 0) != 0,
                    exitCode: result.exitCode,
                    durationSeconds: result.durationSeconds,
                    timestamp: timestamp
                )
            )
            if !resolved {
                appendToolResponseFallback(
                    response,
                    result: result,
                    fallbackID: "line-\(seq)-tool-response-\(index)",
                    seq: seq,
                    timestamp: timestamp,
                    into: &assembler
                )
            }
        }
    }

    private func appendToolResponseFallback(
        _ response: TranscriptJSONValue,
        result: (output: String?, error: String?, exitCode: Int?, durationSeconds: Double?),
        fallbackID: String,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let toolName = Self.toolCallName(in: response) else { return }
        let payload = toolResponsePayload(in: response)
        let args = toolResponseInputArguments(in: payload)
        let output = result.error ?? result.output
        if Self.isShellToolName(toolName),
           let command = shellCommand(from: args) {
            assembler.append(
                ChatMessage(
                    id: Self.toolCallID(in: response) ?? fallbackID,
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: .terminal(
                        ChatTerminalCapture(
                            command: command,
                            output: output.flatMap { budget.body($0) },
                            exitCode: result.exitCode,
                            durationSeconds: result.durationSeconds,
                            isRunning: false
                        )
                    )
                )
            )
            return
        }

        assembler.append(
            ChatMessage(
                id: Self.toolCallID(in: response) ?? fallbackID,
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: genericToolUseKind(
                    toolName: toolName,
                    args: args,
                    output: output.flatMap { budget.body($0) },
                    status: toolResponseStatus(result: result)
                )
            )
        )
    }

    private func appendEvent(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let eventName = root["name"]?.string else { return }
        let normalizedEventName = Self.normalizedEventName(eventName)
        if Self.isQuestionToolName(eventName),
           appendQuestionEvent(root, seq: seq, timestamp: timestamp, into: &assembler) {
            return
        }
        if appendAuthorizationEvent(normalizedEventName, root: root, seq: seq, timestamp: timestamp, into: &assembler) {
            return
        }
        if appendLifecycleEvent(normalizedEventName, root: root, seq: seq, timestamp: timestamp, into: &assembler) {
            return
        }
        if appendErrorEvent(normalizedEventName, root: root, seq: seq, timestamp: timestamp, into: &assembler) {
            return
        }
        switch normalizedEventName {
        case "session_metadata":
            assembler.append(status(.sessionStarted, detail: root["cwd"]?.string, seq: seq, timestamp: timestamp))
        default:
            break
        }
    }

    @discardableResult
    private func appendAuthorizationEvent(
        _ rawEventName: String,
        root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let eventName = Self.normalizedEventName(rawEventName)
        if Self.authorizationEventNames.contains(eventName) {
            appendToolAuthorizationEvent(root, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        }
        if Self.authorizationResolutionEventNames.contains(eventName) {
            resolveToolAuthorizationEvent(root, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        }
        return false
    }

    @discardableResult
    private func appendErrorEvent(
        _ rawEventName: String,
        root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let eventName = Self.normalizedEventName(rawEventName)
        guard Self.errorEventNames.contains(eventName) else { return false }
        resolvePendingAsInterrupted(root, timestamp: timestamp, into: &assembler)
        appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
        assembler.append(status(.interrupted, detail: errorDetail(in: root), seq: seq, timestamp: timestamp))
        return true
    }

    @discardableResult
    private func appendLifecycleEvent(
        _ rawEventName: String,
        root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let eventName = Self.normalizedEventName(rawEventName)
        if Self.lifecycleStartedEventNames.contains(eventName) {
            appendStateUpdate(.working, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        }
        if Self.lifecycleCompletedEventNames.contains(eventName) {
            resolvePendingAsCompleted(timestamp: timestamp, into: &assembler)
            appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        }
        if Self.lifecycleInterruptedEventNames.contains(eventName) {
            resolvePendingAsInterrupted(root, timestamp: timestamp, into: &assembler)
            appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
            assembler.append(status(.interrupted, detail: errorDetail(in: root), seq: seq, timestamp: timestamp))
            return true
        }
        return false
    }

    @discardableResult
    private func appendQuestionEvent(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let toolCall = Self.firstNestedObject(in: root, keys: Self.questionToolCallKeys)
        let requestID = Self.firstString(in: root, keys: Self.questionRequestIDKeys)
            ?? toolCall.flatMap { Self.firstString(in: $0, keys: Self.questionRequestIDKeys) }
        let args = questionArguments(in: root, toolCall: toolCall)
        return appendQuestionRequest(
            args,
            baseID: requestID ?? "line-\(seq)",
            pendingKey: requestID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    private func userProse(_ text: String, id: String, seq: Int, timestamp: Date) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .user,
            timestamp: timestamp,
            kind: .prose(ChatProse(text: budget.body(text)))
        )
    }

    private func agentProse(_ text: String, id: String, seq: Int, timestamp: Date) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: timestamp,
            kind: .prose(ChatProse(text: budget.body(text)))
        )
    }

    private func systemProse(_ text: String, id: String, seq: Int, timestamp: Date) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .system,
            timestamp: timestamp,
            kind: .prose(ChatProse(text: budget.body(text)))
        )
    }

    private func status(
        _ event: ChatStatusTransition.Event,
        detail: String?,
        seq: Int,
        timestamp: Date
    ) -> ChatMessage {
        ChatMessage(
            id: "line-\(seq)-status",
            seq: seq,
            role: .system,
            timestamp: timestamp,
            kind: .status(ChatStatusTransition(event: event, detail: detail))
        )
    }

    private func errorDetail(in root: TranscriptJSONValue) -> String? {
        Self.currentAgyContent(in: root)
            ?? Self.firstString(in: root, keys: ["reason", "error", "message", "description"])
    }

    private func resolvePendingAsInterrupted(
        _ root: TranscriptJSONValue,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        resolvePendingAsInterrupted(output: errorDetail(in: root), timestamp: timestamp, into: &assembler)
    }

    private func resolvePendingAsInterrupted(
        output: String?,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        assembler.resolveAll(
            completion: TranscriptToolCompletion(
                output: output,
                isError: true,
                exitCode: 1,
                timestamp: timestamp,
                permissionResolution: .expired,
                questionResolution: .expired
            )
        )
    }

    private func resolvePendingAsCompleted(
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        assembler.resolveAll(
            completion: TranscriptToolCompletion(
                output: nil,
                isError: false,
                exitCode: 0,
                timestamp: timestamp,
                permissionResolution: .expired,
                questionResolution: .expired
            )
        )
    }

    private static func historySessionID(in root: TranscriptJSONValue) -> String? {
        for key in sessionIDKeys {
            guard let raw = root[key]?.string else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func historyText(in root: TranscriptJSONValue) -> String? {
        for key in contentKeys {
            let fragments = textFragments(from: root[key])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !fragments.isEmpty else { continue }
            return fragments.joined(separator: "\n\n")
        }
        return nil
    }

    private static func brainSystemMessageText(in root: TranscriptJSONValue) -> String? {
        guard let raw = currentAgyContent(in: root) else { return nil }
        return normalizedBrainSystemMessageText(raw)
    }

    private static func normalizedBrainSystemMessageText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let contentRange = trimmed.range(of: " content="),
           let closeRange = trimmed.range(
               of: "\n</SYSTEM_MESSAGE>",
               range: contentRange.upperBound..<trimmed.endIndex
           ) {
            let content = String(trimmed[contentRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                return content
            }
        }
        if let openRange = trimmed.range(of: "<SYSTEM_MESSAGE>"),
           let closeRange = trimmed.range(
               of: "</SYSTEM_MESSAGE>",
               range: openRange.upperBound..<trimmed.endIndex
           ) {
            let inner = String(trimmed[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                return inner
            }
        }
        return trimmed
    }

    private static func normalizedEventName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func isQuestionToolName(_ raw: String) -> Bool {
        questionToolNames.contains(normalizedEventName(raw))
    }

    private static func isPermissionToolName(_ raw: String) -> Bool {
        permissionToolNames.contains(normalizedEventName(raw))
    }

    private static func isShellToolName(_ raw: String) -> Bool {
        shellToolNames.contains(normalizedEventName(raw))
    }

    private static func textFragments(from value: TranscriptJSONValue?) -> [String] {
        guard let value else { return [] }
        if let string = value.string {
            return [string]
        }
        if let array = value.array {
            return array.flatMap { textFragments(from: $0) }
        }
        guard value.object != nil else {
            return []
        }

        switch value["type"]?.string {
        case "text", "input_text", "output_text":
            if let text = value["text"]?.string {
                return [text]
            }
        default:
            break
        }

        for key in ["text", "content", "output", "result", "message"] {
            let fragments = textFragments(from: value[key])
            if !fragments.isEmpty {
                return fragments
            }
        }
        return []
    }

    private static func currentAgyContent(in root: TranscriptJSONValue) -> String? {
        let fragments = textFragments(from: root["content"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return nil }
        return fragments.joined(separator: "\n\n")
    }

    private func genericToolUseKind(toolName: String, args: TranscriptJSONValue?) -> ChatMessageKind {
        genericToolUseKind(toolName: toolName, args: args, output: nil, status: .running)
    }

    private func genericToolUseKind(
        toolName: String,
        args: TranscriptJSONValue?,
        output: String?,
        status: ChatToolUse.Status
    ) -> ChatMessageKind {
        var summary = toolName
        if let args {
            for key in Self.summaryArgumentKeys {
                if let value = args[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    summary = "\(toolName) \(budget.summaryArgument(value))"
                    break
                }
            }
        }
        let detail = args.flatMap { value -> String? in
            let raw = value.compactJSONString()
            return raw.isEmpty || raw == "{}" ? nil : budget.inputDetail(raw)
        }
        return .toolUse(
            ChatToolUse(
                toolName: toolName,
                summary: summary,
                inputDetail: detail,
                output: output,
                status: status
            )
        )
    }

    private func questionKinds(args: TranscriptJSONValue?) -> [ChatMessageKind] {
        let questions = questionValues(args: args)
        return questions.compactMap { question -> ChatMessageKind? in
            let prompt = Self.firstString(in: question, keys: ["question", "prompt", "header"])
            guard let prompt else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option in
                questionOption(from: option)
            }
            return .question(ChatQuestion(prompt: prompt, options: options))
        }
    }

    private func questionValues(args: TranscriptJSONValue?) -> [TranscriptJSONValue] {
        if let questions = args?["questions"]?.array, !questions.isEmpty {
            return questions
        }
        if hasFlatQuestion(args) {
            return args.map { [$0] } ?? []
        }
        return []
    }

    private func hasFlatQuestion(_ value: TranscriptJSONValue?) -> Bool {
        guard let value else { return false }
        return Self.firstString(in: value, keys: ["question", "prompt"]) != nil
    }

    private func questionOption(from option: TranscriptJSONValue) -> ChatQuestion.Option? {
        if let label = questionOptionLabel(from: option) {
            return ChatQuestion.Option(label: label)
        }
        let label = questionOptionLabel(from: option["label"])
            ?? questionOptionLabel(from: option["title"])
            ?? questionOptionLabel(from: option["text"])
            ?? questionOptionLabel(from: option["value"])
            ?? questionOptionLabel(from: option["name"])
            ?? questionOptionLabel(from: option["id"])
        guard let label else { return nil }
        let detail = Self.firstString(in: option, keys: ["description", "detail"])
        return ChatQuestion.Option(label: label, detail: detail)
    }

    private func questionOptionLabel(from value: TranscriptJSONValue?) -> String? {
        guard let value else { return nil }
        if let label = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        if value.double != nil || value.bool != nil {
            let raw = value.compactJSONString()
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    private func questionArguments(
        in root: TranscriptJSONValue,
        toolCall: TranscriptJSONValue?
    ) -> TranscriptJSONValue? {
        if root["questions"]?.array != nil {
            return root
        }
        if let nested = Self.firstQuestionValue(in: root, keys: Self.questionArgumentKeys) {
            return nested
        }
        guard let toolCall else { return root }
        if toolCall["questions"]?.array != nil {
            return toolCall
        }
        return Self.firstQuestionValue(in: toolCall, keys: Self.questionArgumentKeys) ?? toolCall
    }

    private func indexedID(_ baseID: String, index: Int) -> String {
        index == 0 ? baseID : "\(baseID)#\(index)"
    }

    private func appendToolAuthorizationEvent(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let toolCall = Self.firstNestedObject(in: root, keys: Self.authorizationToolCallKeys)
        let requestID = Self.firstString(in: root, keys: Self.authorizationRequestIDKeys)
            ?? toolCall.flatMap { Self.firstString(in: $0, keys: Self.authorizationRequestIDKeys) }
            ?? "line-\(seq)"
        let toolName = Self.firstString(in: root, keys: Self.authorizationToolNameKeys)
            ?? toolCall.flatMap { Self.firstString(in: $0, keys: Self.authorizationToolNameKeys) }
            ?? toolCall.flatMap { Self.firstString(in: $0, keys: ["name"]) }
        let args = Self.firstValue(in: root, keys: Self.authorizationArgumentKeys)
            ?? toolCall.flatMap { Self.firstValue(in: $0, keys: Self.authorizationArgumentKeys) }
        let command = shellCommand(from: args)
            ?? Self.firstString(in: root, keys: ["command", "cmd", "query"])
            ?? toolCall.flatMap { Self.firstString(in: $0, keys: ["command", "cmd", "query"]) }
        let subject = authorizationSubject(
            command: command,
            toolName: toolName,
            args: args,
            root: root,
            toolCall: toolCall
        )
        guard !subject.isEmpty else { return }

        let title: String
        if command != nil {
            title = "Antigravity wants to run:"
        } else if let toolName, !toolName.isEmpty {
            title = "Antigravity wants to use \(toolName):"
        } else {
            title = "Antigravity needs approval:"
        }
        assembler.append(
            ChatMessage(
                id: "permission-\(requestID)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .permissionRequest(
                    ChatPermissionRequest(
                        title: title,
                        subject: budget.inputDetail(subject)
                    )
                )
            ),
            pendingKey: requestID
        )
    }

    @discardableResult
    private func appendPermissionRequest(
        _ args: TranscriptJSONValue?,
        baseID: String,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        guard let args else { return false }
        let toolName = permissionString(in: args, keys: ["Action", "action", "toolName", "tool_name"])
        let subject = permissionString(in: args, keys: [
            "Target", "target", "subject", "toolSummary", "tool_summary",
            "toolAction", "tool_action", "Reason", "reason",
        ]) ?? authorizationSubject(
            command: nil,
            toolName: toolName,
            args: args,
            root: args,
            toolCall: nil
        )
        guard !subject.isEmpty else { return false }

        let title: String
        if let toolName, !toolName.isEmpty {
            title = "Antigravity wants to use \(toolName):"
        } else {
            title = "Antigravity needs approval:"
        }
        assembler.append(
            ChatMessage(
                id: "permission-\(baseID)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .permissionRequest(
                    ChatPermissionRequest(
                        title: title,
                        subject: budget.inputDetail(subject)
                    )
                )
            )
        )
        return true
    }

    private func resolveToolAuthorizationEvent(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let toolCall = Self.firstNestedObject(in: root, keys: Self.authorizationToolCallKeys)
        guard let requestID = Self.firstString(in: root, keys: Self.authorizationRequestIDKeys)
            ?? toolCall.flatMap({ Self.firstString(in: $0, keys: Self.authorizationRequestIDKeys) }),
            let resolution = authorizationResolution(in: root, toolCall: toolCall) else {
            return
        }
        appendStateUpdate(.inputResolved, seq: seq, timestamp: timestamp, into: &assembler)
        assembler.resolve(
            key: requestID,
            completion: TranscriptToolCompletion(
                output: nil,
                isError: resolution != .approved,
                timestamp: timestamp,
                permissionResolution: resolution
            )
        )
        if resolution != .approved {
            appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
        }
    }

    private func authorizationSubject(
        command: String?,
        toolName: String?,
        args: TranscriptJSONValue?,
        root: TranscriptJSONValue,
        toolCall: TranscriptJSONValue?
    ) -> String {
        if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return command
        }
        if let subject = Self.firstString(in: root, keys: Self.authorizationSubjectKeys)
            ?? toolCall.flatMap({ Self.firstString(in: $0, keys: Self.authorizationSubjectKeys) }) {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let args {
            let raw = args.compactJSONString()
            if !raw.isEmpty, raw != "{}" {
                if let toolName, !toolName.isEmpty {
                    return "\(toolName) \(raw)"
                }
                return raw
            }
        }
        return toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func permissionString(in value: TranscriptJSONValue, keys: [String]) -> String? {
        for key in keys {
            guard let string = value[key]?.string,
                  let normalized = normalizedPermissionString(string) else {
                continue
            }
            return normalized
        }
        return nil
    }

    private func normalizedPermissionString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("\""),
           trimmed.hasSuffix("\""),
           let parsed = TranscriptJSONValue(jsonString: trimmed),
           let parsedString = parsed.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsedString.isEmpty {
            return parsedString
        }
        return trimmed
    }

    private func toolResponseResult(
        in response: TranscriptJSONValue
    ) -> (output: String?, error: String?, exitCode: Int?, durationSeconds: Double?) {
        let payload = toolResponsePayload(in: response)
        return (
            output: toolResponseOutput(in: payload),
            error: toolResponseError(in: payload),
            exitCode: toolResponseExitCode(in: payload),
            durationSeconds: toolResponseDurationSeconds(in: payload)
        )
    }

    private func toolResponsePayload(in response: TranscriptJSONValue) -> TranscriptJSONValue {
        for key in Self.toolResponsePayloadKeys {
            guard let candidate = response[key] else { continue }
            return normalizedToolResponsePayload(candidate)
        }
        return response
    }

    private func toolResponseInputArguments(in payload: TranscriptJSONValue) -> TranscriptJSONValue? {
        guard let object = payload.object else { return nil }
        let inputObject = object.filter { key, value in
            !Self.toolResponseNonInputKeys.contains(key)
                && value != .null
        }
        return inputObject.isEmpty ? nil : .object(inputObject)
    }

    private func toolResponseStatus(
        result: (output: String?, error: String?, exitCode: Int?, durationSeconds: Double?)
    ) -> ChatToolUse.Status {
        if result.error != nil || (result.exitCode ?? 0) != 0 {
            return .failed
        }
        return .succeeded
    }

    private func normalizedToolResponsePayload(_ value: TranscriptJSONValue) -> TranscriptJSONValue {
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return value
        }
        guard let parsed = TranscriptJSONValue(jsonString: raw),
              parsed.object != nil || parsed.array != nil else {
            return value
        }
        return parsed
    }

    private func toolResponseOutput(in payload: TranscriptJSONValue) -> String? {
        if let output = payload.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty {
            return output
        }
        if let output = Self.firstString(in: payload, keys: Self.toolResponseOutputKeys) {
            return output
        }
        if let output = structuredQuestionAnswerOutputText(from: payload) {
            return output
        }
        let fragments = Self.textFragments(from: payload)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return fragments.isEmpty ? nil : fragments.joined(separator: "\n")
    }

    private func structuredQuestionAnswerOutputText(from value: TranscriptJSONValue) -> String? {
        for key in [
            "answers", "responses", "selections", "selectedOptions", "selected_options",
            "questions", "results",
        ] {
            guard value[key] != nil else { continue }
            let raw = value.compactJSONString()
            return raw.isEmpty || raw == "{}" ? nil : raw
        }
        for key in ["output", "result", "data", "payload", "response", "functionResponse", "function_response"] {
            guard let nested = value[key],
                  let output = structuredQuestionAnswerOutputText(from: nested)
            else { continue }
            return output
        }
        if let array = value.array {
            for item in array {
                guard let output = structuredQuestionAnswerOutputText(from: item) else { continue }
                return output
            }
        }
        return nil
    }

    private func toolResponseError(in payload: TranscriptJSONValue) -> String? {
        if let error = Self.firstString(in: payload, keys: Self.toolResponseErrorKeys) {
            return error
        }
        for key in Self.toolResponseErrorKeys {
            guard let value = payload[key] else { continue }
            let normalized = normalizedToolResponsePayload(value)
            if let error = normalized.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !error.isEmpty {
                return error
            }
            let fragments = Self.textFragments(from: normalized)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !fragments.isEmpty {
                return fragments.joined(separator: "\n")
            }
        }
        return nil
    }

    private func toolResponseExitCode(in payload: TranscriptJSONValue) -> Int? {
        if let exitCode = explicitToolResponseExitCode(in: payload) {
            return exitCode
        }
        if let metadata = toolResponseMetadata(in: payload),
           let exitCode = explicitToolResponseExitCode(in: metadata) {
            return exitCode
        }
        return nil
    }

    private func explicitToolResponseExitCode(in payload: TranscriptJSONValue) -> Int? {
        for key in Self.toolResponseExitCodeKeys {
            if let exitCode = payload[key]?.int {
                return exitCode
            }
            if let raw = payload[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               let exitCode = Int(raw) {
                return exitCode
            }
        }
        if let success = payload["success"]?.bool {
            return success ? 0 : 1
        }
        return Self.toolResultExitCode(forStatus: Self.firstString(in: payload, keys: ["status"]))
    }

    private static func toolResultExitCode(forStatus rawStatus: String?) -> Int? {
        guard let normalizedStatus = rawStatus.map(normalizedEventName) else { return nil }
        if toolResultSucceededStatuses.contains(normalizedStatus) {
            return 0
        }
        if toolResultFailedStatuses.contains(normalizedStatus) {
            return 1
        }
        return nil
    }

    private func toolResponseDurationSeconds(in payload: TranscriptJSONValue) -> Double? {
        if let seconds = explicitToolResponseDurationSeconds(in: payload) {
            return seconds
        }
        if let metadata = toolResponseMetadata(in: payload) {
            return explicitToolResponseDurationSeconds(in: metadata)
        }
        return nil
    }

    private func explicitToolResponseDurationSeconds(in payload: TranscriptJSONValue) -> Double? {
        for key in Self.toolResponseDurationSecondKeys {
            if let seconds = toolResponseDurationSeconds(in: payload[key]) {
                return seconds
            }
        }
        for key in Self.toolResponseDurationMillisecondKeys {
            if let milliseconds = payload[key]?.double {
                return milliseconds / 1_000
            }
            if let raw = payload[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               let milliseconds = Double(raw) {
                return milliseconds / 1_000
            }
        }
        return nil
    }

    private func toolResponseMetadata(in payload: TranscriptJSONValue) -> TranscriptJSONValue? {
        guard let metadata = payload["metadata"] else { return nil }
        let normalized = normalizedToolResponsePayload(metadata)
        guard normalized.object != nil else { return nil }
        return normalized
    }

    private func toolResponseDurationSeconds(in value: TranscriptJSONValue?) -> Double? {
        guard let value else { return nil }
        if let seconds = value.double {
            return seconds
        }
        if let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Double(raw) {
            return seconds
        }
        let seconds = value["secs"]?.double ?? value["seconds"]?.double
        let nanos = value["nanos"]?.double ?? value["nanoseconds"]?.double
        guard seconds != nil || nanos != nil else { return nil }
        return (seconds ?? 0) + ((nanos ?? 0) / 1_000_000_000)
    }

    private func shellCommand(from args: TranscriptJSONValue?) -> String? {
        if let command = args?["command"]?.string { return command }
        if let command = args?["cmd"]?.string { return command }
        if let command = args?["query"]?.string { return command }
        let pieces = args?["command"]?.array?.compactMap(\.string) ?? []
        guard !pieces.isEmpty else { return nil }
        if pieces.count >= 3,
           let binary = pieces[0].split(separator: "/").last,
           ["bash", "sh", "zsh"].contains(String(binary)),
           pieces[1] == "-lc" || pieces[1] == "-c" {
            return pieces[2...].joined(separator: " ")
        }
        return pieces.joined(separator: " ")
    }

    private static func firstString(
        in value: TranscriptJSONValue,
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let string = value[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else { continue }
            return string
        }
        return nil
    }

    private static func firstValue(
        in value: TranscriptJSONValue,
        keys: [String]
    ) -> TranscriptJSONValue? {
        for key in keys {
            guard let candidate = value[key], candidate.object != nil || candidate.array != nil else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func firstArray(
        in value: TranscriptJSONValue,
        keys: [String]
    ) -> [TranscriptJSONValue]? {
        for key in keys {
            guard let array = value[key]?.array else { continue }
            return array
        }
        return nil
    }

    private static func toolCallID(in call: TranscriptJSONValue) -> String? {
        firstString(in: call, keys: toolCallIDKeys)
    }

    private static func toolCallName(in call: TranscriptJSONValue) -> String? {
        firstString(in: call, keys: toolCallNameKeys)
    }

    private static func toolCallArguments(in call: TranscriptJSONValue) -> TranscriptJSONValue? {
        for key in toolCallArgumentKeys {
            guard let candidate = call[key] else { continue }
            if candidate.object != nil || candidate.array != nil {
                return candidate
            }
            if let raw = candidate.string,
               let parsed = TranscriptJSONValue(jsonString: raw),
               parsed.object != nil || parsed.array != nil {
                return parsed
            }
        }
        return nil
    }

    private static func firstQuestionValue(
        in value: TranscriptJSONValue,
        keys: [String]
    ) -> TranscriptJSONValue? {
        for key in keys {
            guard let candidate = value[key] else { continue }
            if candidate.object != nil || candidate.array != nil {
                return candidate
            }
            if let raw = candidate.string,
               let parsed = TranscriptJSONValue(jsonLine: raw),
               parsed.object != nil || parsed.array != nil {
                return parsed
            }
        }
        return nil
    }

    private static func firstBool(
        in value: TranscriptJSONValue,
        keys: [String]
    ) -> Bool? {
        for key in keys {
            guard let bool = value[key]?.bool else { continue }
            return bool
        }
        return nil
    }

    private static func firstNestedObject(
        in value: TranscriptJSONValue,
        keys: [String]
    ) -> TranscriptJSONValue? {
        for key in keys {
            guard let candidate = value[key], candidate.object != nil else { continue }
            return candidate
        }
        return nil
    }

    private func authorizationResolution(
        in root: TranscriptJSONValue,
        toolCall: TranscriptJSONValue?
    ) -> ChatPermissionRequest.Resolution? {
        if let approved = Self.firstBool(in: root, keys: Self.authorizationResolutionKeys)
            ?? toolCall.flatMap({ Self.firstBool(in: $0, keys: Self.authorizationResolutionKeys) }) {
            return approved ? .approved : .denied
        }
        guard let raw = Self.firstString(in: root, keys: Self.authorizationResolutionKeys)
            ?? toolCall.flatMap({ Self.firstString(in: $0, keys: Self.authorizationResolutionKeys) }) else {
            return nil
        }
        switch raw.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "approve", "approved", "allow", "allowed", "accept", "accepted", "grant", "granted",
             "yes", "true", "ok", "success", "succeeded":
            return .approved
        case "deny", "denied", "reject", "rejected", "disallow", "disallowed", "block", "blocked",
             "no", "false", "error", "failed":
            return .denied
        case "expire", "expired", "timeout", "timed_out", "cancel", "cancelled", "canceled":
            return .expired
        default:
            return nil
        }
    }

    private func completion(
        fromToolResults results: [TranscriptJSONValue]?,
        status: String? = nil,
        timestamp: Date? = nil
    ) -> TranscriptToolCompletion? {
        var outputs: [String] = []
        var errors: [String] = []
        var exitCode: Int?
        var durationSeconds: Double?
        var completedAt = timestamp
        for result in results ?? [] {
            if let stamped = completionTimestamp(from: result) {
                completedAt = max(completedAt ?? stamped, stamped)
            }
            guard let functionResponse = Self.firstNestedObject(in: result, keys: Self.functionResponseKeys) else {
                continue
            }
            let response = toolResponsePayload(in: functionResponse)
            if let output = toolResponseOutput(in: response) {
                outputs.append(output)
            }
            if let error = toolResponseError(in: response) {
                errors.append(error)
            }
            exitCode = toolResponseExitCode(in: response) ?? exitCode
            durationSeconds = toolResponseDurationSeconds(in: response) ?? durationSeconds
        }
        let statusExitCode = Self.toolResultExitCode(forStatus: status)
        let statusSucceeded = statusExitCode == 0
        let statusFailed = statusExitCode == 1
        let isError = statusFailed || !errors.isEmpty || (exitCode ?? 0) != 0
        guard !outputs.isEmpty || !errors.isEmpty || statusSucceeded || statusFailed
            || exitCode != nil || durationSeconds != nil else {
            return nil
        }
        let selectedOutput = errors.isEmpty ? outputs : errors
        return TranscriptToolCompletion(
            output: selectedOutput.isEmpty ? nil : selectedOutput.joined(separator: "\n\n"),
            isError: isError,
            exitCode: exitCode,
            durationSeconds: durationSeconds,
            timestamp: completedAt
        )
    }

    private func completionTimestamp(from result: TranscriptJSONValue) -> Date? {
        let functionResponse = Self.firstNestedObject(in: result, keys: Self.functionResponseKeys)
        let response = functionResponse.map { toolResponsePayload(in: $0) }
        return [
            result["timestamp"],
            result["created_at"],
            result["createdAt"],
            functionResponse?["timestamp"],
            response?["timestamp"],
        ]
        .compactMap { timestamp(from: $0) }
        .max()
    }

    private func timestamp(in value: TranscriptJSONValue, keys: [String]) -> Date? {
        for key in keys {
            if let timestamp = timestamp(from: value[key]) {
                return timestamp
            }
        }
        return nil
    }

    private func timestamp(from value: TranscriptJSONValue?) -> Date? {
        guard let value else { return nil }
        if let numeric = value.double {
            return dateFromNumericTimestamp(numeric)
        }
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let numeric = Double(raw) {
            return dateFromNumericTimestamp(numeric)
        }
        return isoTimestamps.date(from: raw)
    }

    private func dateFromNumericTimestamp(_ value: Double) -> Date? {
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
