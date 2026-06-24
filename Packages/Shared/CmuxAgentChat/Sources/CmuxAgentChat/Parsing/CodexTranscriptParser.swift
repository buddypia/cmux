import Foundation

/// Converts Codex CLI rollout JSONL lines into ``ChatMessage`` values.
///
/// Reads the format written under `~/.codex/sessions/YYYY/MM/DD/` as of
/// Codex CLI 0.139: every line is `{timestamp, type, payload}`. Content
/// lives in `response_item` payloads (`message`, `reasoning`,
/// `function_call`, `function_call_output`, `custom_tool_call`,
/// `tool_search_call`, ...);
/// non-actionable `event_msg` rows, `turn_context`, and token bookkeeping
/// are skipped. `event_msg.user_message` rows become user prose,
/// `event_msg.agent_message` and `task_complete.last_agent_message` rows
/// become agent prose with duplicate mirrors collapsed, `event_msg.agent_reasoning`
/// rows become thoughts, and actionable
/// `exec_approval_request` and `request_user_input` events become
/// permission/question cards, and visible `error` messages become agent
/// prose. Lifecycle events such as `task_started`, `task_complete`,
/// `turn_complete`, `turn_aborted`, `thread_goal_updated`, `error`, and
/// `stream_error` additionally produce non-rendered state updates so the host
/// can keep ``ChatAgentState`` current without adding synthetic chat rows. The
/// parser is stateless and fails open: malformed or unknown lines are dropped
/// silently. Pairing of calls with their `*_output` works across parse calls
/// through ``ChatTranscriptParseState``.
public struct CodexTranscriptParser: Sendable {
    private static let userNoisePrefixes = [
        "<user_instructions",
        "<environment_context",
        "<permissions",
        "<collaboration_mode",
        "<turn_aborted",
        "# AGENTS.md instructions",
    ]
    private static let shellToolNames: Set<String> = [
        "shell", "exec_command", "local_shell_call", "container.exec", "write_stdin",
    ]
    private static let questionToolNames: Set<String> = [
        "askuserquestion", "request_user_input", "ask_user_question", "ask_question",
    ]
    private static let approvalResolutionEventNames: Set<String> = [
        "exec_approval_response", "exec_approval_result",
        "exec_approval_decision", "exec_approval_resolved",
        "approval_response", "approval_result",
        "approval_decision", "approval_resolved",
    ]
    private static let explicitCallIDKeys = [
        "call_id", "callId", "tool_call_id", "toolCallId",
        "request_id", "requestId",
    ]
    private static let callIDKeys = [
        "call_id", "callId", "tool_call_id", "toolCallId",
        "request_id", "requestId", "id",
    ]
    private static let approvalNestedPayloadKeys = [
        "approval", "authorization", "permission", "request",
        "response", "result", "toolCall", "tool_call", "call",
    ]
    private static let questionNestedPayloadKeys = [
        "question", "input", "arguments", "args", "parameters",
        "request", "payload",
    ]
    private static let shellWrapperBinaries: Set<String> = ["bash", "sh", "zsh"]
    private static let summaryArgumentKeys = [
        "path", "file_path", "pattern", "query", "url", "text", "key",
        "app", "repo", "session_id", "plan",
    ]
    private static let completionOutputKeys = ["output", "result", "message", "text"]

    private struct ParsedUserAttachment {
        let attachment: ChatAttachment
        let fingerprint: String
    }

    private let budget = TranscriptTextBudget()
    private let timestamps = TranscriptTimestampParser()

    /// Creates a Codex transcript parser.
    public init() {}

    /// Parses a contiguous run of JSONL lines into chat messages.
    ///
    /// - Parameters:
    ///   - lines: The raw JSONL lines, one rollout line each.
    ///   - startingSeq: The absolute line index of the first input line;
    ///     each parsed message gets `seq == startingSeq + lineOffset`.
    ///   - state: Carry-over state from the previous parse call.
    /// - Returns: The new messages, updates to earlier messages whose tool
    ///   output arrived in this call, and the next carry-over state.
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
            if let stamped = timestamps.date(from: root["timestamp"]?.string) {
                lastTimestamp = stamped
            }
            let timestamp = lastTimestamp ?? Date(timeIntervalSince1970: 0)
            let payload = root["payload"]
            switch normalizedEventType(root["type"]?.string) {
            case "session_meta":
                appendSessionStart(payload, seq: seq, timestamp: timestamp, into: &assembler)
            case "compacted":
                assembler.append(
                    ChatMessage(
                        id: "line-\(seq)",
                        seq: seq,
                        role: .system,
                        timestamp: timestamp,
                        kind: .status(
                            ChatStatusTransition(
                                event: .contextCompacted,
                                detail: nonEmpty(payload?["message"]?.string)
                                    ?? nonEmpty(root["message"]?.string)
                            )
                        )
                    )
                )
            case "response_item":
                appendResponseItem(payload, seq: seq, timestamp: timestamp, into: &assembler)
            case "event_msg":
                appendEventMessage(payload, seq: seq, timestamp: timestamp, into: &assembler)
            default:
                continue
            }
        }
        return assembler.result(lastTimestamp: lastTimestamp)
    }

    // MARK: - Line kinds

    private func appendSessionStart(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let sessionID = payload?["id"]?.string
        assembler.append(
            ChatMessage(
                id: sessionID.map { "session-\($0)" } ?? "line-\(seq)",
                seq: seq,
                role: .system,
                timestamp: timestamp,
                kind: .status(
                    ChatStatusTransition(
                        event: .sessionStarted,
                        detail: payload?["cwd"]?.string
                    )
                )
            )
        )
    }

    private func appendResponseItem(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let payload else { return }
        switch normalizedEventType(payload["type"]?.string) {
        case "message":
            appendMessage(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "reasoning":
            appendReasoning(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "function_call":
            appendFunctionCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "custom_tool_call":
            appendCustomToolCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "function_call_output", "custom_tool_call_output":
            resolveOutput(payload, timestamp: timestamp, into: &assembler)
        case "tool_search_call":
            appendToolSearchCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "tool_search_output":
            resolveToolSearchOutput(payload, timestamp: timestamp, into: &assembler)
        case "web_search_call":
            appendWebSearch(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "image_generation_call":
            appendImageGenerationCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        default:
            return
        }
    }

    private func appendEventMessage(
        _ payload: TranscriptJSONValue?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let payload else { return }
        switch normalizedEventType(payload["type"]?.string) {
        case "user_message":
            appendEventUserMessage(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "agent_message":
            appendAgentProse(
                payload["message"]?.string,
                seq: seq,
                timestamp: timestamp,
                into: &assembler
            )
        case "task_started":
            appendStateUpdate(.working, seq: seq, timestamp: timestamp, into: &assembler)
        case "task_complete", "turn_complete":
            appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
            resolvePendingAsCompleted(timestamp: timestamp, into: &assembler)
            appendAgentProse(
                payload["last_agent_message"]?.string,
                seq: seq,
                timestamp: timestamp,
                into: &assembler
            )
        case "agent_reasoning":
            appendEventReasoning(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "item_completed":
            appendCompletedItem(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "exec_approval_request":
            appendApprovalRequest(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case let eventType? where Self.approvalResolutionEventNames.contains(eventType):
            resolveApprovalEvent(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case let eventType? where Self.isQuestionToolName(eventType):
            appendQuestionRequest(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "error", "stream_error":
            appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
            resolvePendingAsInterrupted(payload, timestamp: timestamp, into: &assembler)
            appendErrorMessage(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "context_compacted":
            appendStatus(.contextCompacted, seq: seq, timestamp: timestamp, into: &assembler)
        case "turn_aborted":
            appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
            resolvePendingAsInterrupted(payload, timestamp: timestamp, into: &assembler)
            appendStatus(
                .interrupted,
                detail: nonEmpty(payload["reason"]?.string),
                seq: seq,
                timestamp: timestamp,
                into: &assembler
            )
        case "thread_rolled_back":
            appendStatus(
                .threadRolledBack,
                seq: seq,
                timestamp: timestamp,
                into: &assembler
            )
        case "thread_goal_updated":
            appendGoalStateUpdate(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "thread_name_updated":
            appendThreadNameUpdate(payload, into: &assembler)
        case "web_search_begin":
            appendWebSearchBegin(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "web_search_end":
            if !resolveEventToolCompletion(payload, timestamp: timestamp, into: &assembler) {
                appendWebSearchEndFallback(payload, seq: seq, timestamp: timestamp, into: &assembler)
            }
        case "exec_command_begin":
            appendEventExecCommandBegin(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "patch_apply_begin":
            appendEventPatchApplyBegin(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "mcp_tool_call_begin":
            appendEventMCPToolCallBegin(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "image_generation_begin":
            appendImageGenerationCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "exec_command_end", "patch_apply_end", "mcp_tool_call_end", "image_generation_end":
            if !resolveEventToolCompletion(payload, timestamp: timestamp, into: &assembler) {
                appendEventToolCompletionFallback(
                    payload,
                    seq: seq,
                    timestamp: timestamp,
                    into: &assembler
                )
            }
        case "view_image_tool_call":
            appendViewImageToolCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        default:
            return
        }
    }

    private func appendThreadNameUpdate(
        _ payload: TranscriptJSONValue,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let title = nonEmpty(payload["thread_name"]?.string)
            ?? nonEmpty(payload["threadName"]?.string)
            ?? nonEmpty(payload["title"]?.string)
            ?? nonEmpty(payload["name"]?.string)
        guard let title else { return }
        assembler.appendTitleUpdate(title)
    }

    private func normalizedEventType(_ raw: String?) -> String? {
        nonEmpty(raw)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func isQuestionToolName(_ raw: String) -> Bool {
        questionToolNames.contains(normalizedToolName(raw))
    }

    private static func isShellToolName(_ raw: String) -> Bool {
        shellToolNames.contains(normalizedToolName(raw))
    }

    private static func normalizedToolName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func qualifiedToolName(name rawName: String, namespace rawNamespace: String?) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let namespace = rawNamespace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !namespace.isEmpty,
              !name.hasPrefix(namespace) else {
            return name
        }
        if namespace.hasSuffix("__") || namespace.hasSuffix(".") {
            return "\(namespace)\(name)"
        }
        if namespace.hasPrefix("mcp__") {
            return "\(namespace)__\(name)"
        }
        return "\(namespace).\(name)"
    }

    private func appendGoalStateUpdate(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let kind = goalStateKind(in: payload) else { return }
        assembler.appendChangedGoalStateUpdate(kind, seq: seq, timestamp: timestamp)
    }

    private func goalStateKind(in payload: TranscriptJSONValue) -> ChatTranscriptStateUpdate.Kind? {
        let status = normalizedStatus(payload["goal"]?["status"]?.string)
            ?? normalizedStatus(payload["status"]?.string)
        switch status {
        case "active", "running", "in_progress":
            return .working
        case "complete", "completed", "done", "blocked":
            return .idle
        default:
            return nil
        }
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

    private func appendStatus(
        _ event: ChatStatusTransition.Event,
        detail: String? = nil,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        assembler.append(
            ChatMessage(
                id: "line-\(seq)",
                seq: seq,
                role: .system,
                timestamp: timestamp,
                kind: .status(ChatStatusTransition(event: event, detail: detail))
            )
        )
    }

    private func appendEventUserMessage(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let text = visibleUserText(payload["text"]?.string)
            ?? visibleUserText(payload["message"]?.string)
        let attachments = userMessageAttachments(in: payload)
        guard text != nil || !attachments.isEmpty else {
            return
        }
        assembler.appendDeduplicatedUserMessage(
            attachments: attachments.map(\.attachment),
            proseText: text,
            fingerprint: userMessageFingerprint(text: text, attachments: attachments),
            baseID: "line-\(seq)",
            seq: seq,
            timestamp: timestamp
        )
    }

    private func userMessageAttachments(in payload: TranscriptJSONValue) -> [ParsedUserAttachment] {
        var attachments: [ParsedUserAttachment] = []
        var seenFingerprints: Set<String> = []
        for hostPath in strings(from: payload["local_images"]?.array) {
            let trimmed = hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parsed = hostPathAttachment(trimmed)
            guard seenFingerprints.insert(parsed.fingerprint).inserted else { continue }
            attachments.append(parsed)
        }
        for image in strings(from: payload["images"]?.array) {
            let trimmed = image.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = imageAttachment(trimmed) else { continue }
            guard seenFingerprints.insert(parsed.fingerprint).inserted else { continue }
            attachments.append(parsed)
        }
        return attachments
    }

    private func inputImageAttachments(in blocks: [TranscriptJSONValue]) -> [ParsedUserAttachment] {
        var attachments: [ParsedUserAttachment] = []
        var seenFingerprints: Set<String> = []
        for block in blocks {
            guard block["type"]?.string == "input_image",
                  let parsed = imageAttachment(block["image_url"]?.string),
                  seenFingerprints.insert(parsed.fingerprint).inserted else {
                continue
            }
            attachments.append(parsed)
        }
        return attachments
    }

    private func imageAttachment(_ value: String?) -> ParsedUserAttachment? {
        guard let value = nonEmpty(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil {
            return ParsedUserAttachment(
                attachment: ChatAttachment(media: .image),
                fingerprint: "data:\(stableHash(trimmed))"
            )
        }
        if let url = URL(string: trimmed), url.isFileURL {
            return hostPathAttachment(url.path)
        }
        return hostPathAttachment(trimmed)
    }

    private func hostPathAttachment(_ hostPath: String) -> ParsedUserAttachment {
        let displayName = nonEmpty(URL(fileURLWithPath: hostPath).lastPathComponent)
        return ParsedUserAttachment(
            attachment: ChatAttachment(
                media: .image,
                displayName: displayName,
                hostPath: hostPath
            ),
            fingerprint: "host:\(hostPath)"
        )
    }

    private func userMessageFingerprint(
        text: String?,
        attachments: [ParsedUserAttachment]
    ) -> String {
        let attachmentPart = attachments.map(\.fingerprint).joined(separator: "|")
        let visibleText = text.map { budget.body($0) } ?? ""
        return "attachments=\(attachmentPart)\ntext=\(stableHash(visibleText))"
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func appendErrorMessage(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        appendAgentProse(payload["message"]?.string, seq: seq, timestamp: timestamp, into: &assembler)
    }

    private func appendApprovalRequest(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let candidates = approvalCandidatePayloads(in: payload)
        let arguments = approvalArguments(from: candidates)
        let command = firstString(in: candidates, keys: ["command", "cmd"])
            ?? candidates.lazy.compactMap {
                shellCommand(arguments: arguments, payload: $0).flatMap(nonEmpty)
            }.first
        let toolName = firstString(in: candidates, keys: ["name", "tool_name", "toolName", "tool"])
            ?? (command == nil ? nil : "exec_command")
        let subject = approvalSubject(command: command, toolName: toolName, arguments: arguments)
        guard !subject.isEmpty else { return }

        let requestID = approvalCallID(in: payload) ?? "line-\(seq)"
        let title: String
        if command != nil {
            title = "Codex wants to run:"
        } else if let toolName {
            title = "Codex wants to use \(toolName):"
        } else {
            title = "Codex needs approval:"
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

    private func appendEventExecCommandBegin(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let arguments = eventArguments(from: payload)
        let command = nonEmpty(payload["command"]?.string)
            ?? nonEmpty(payload["cmd"]?.string)
            ?? shellCommand(arguments: arguments, payload: payload).flatMap(nonEmpty)
        guard let command else { return }
        let requestID = callID(in: payload)
        append(
            kinds: [.terminal(ChatTerminalCapture(command: command, isRunning: true))],
            baseID: requestID ?? "line-\(seq)",
            pendingKey: requestID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    private func appendEventMCPToolCallBegin(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let name = nonEmpty(payload["tool"]?.string)
            ?? nonEmpty(payload["tool_name"]?.string)
            ?? nonEmpty(payload["toolName"]?.string)
            ?? nonEmpty(payload["name"]?.string)
        guard let name else { return }
        let namespace = nonEmpty(payload["namespace"]?.string)
            ?? mcpNamespace(from: payload)
        let toolName = Self.qualifiedToolName(name: name, namespace: namespace)
        let arguments = eventArguments(from: payload)
        let rawArguments = arguments.map { rawArgumentsText(for: $0) }
        let requestID = callID(in: payload)
        append(
            kinds: [genericToolUseKind(
                toolName: toolName,
                arguments: arguments,
                rawArguments: rawArguments
            )],
            baseID: requestID ?? "line-\(seq)",
            pendingKey: requestID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    private func appendEventPatchApplyBegin(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let patch = nonEmpty(payload["input"]?.string)
            ?? nonEmpty(payload["patch"]?.string)
            ?? nonEmpty(payload["changes"]?.string)
        let path = patch.flatMap(firstPatchedFile)
            ?? nonEmpty(payload["path"]?.string)
            ?? nonEmpty(payload["file_path"]?.string)
        var summary = "apply_patch"
        if let path {
            summary = "apply_patch \(budget.summaryArgument(path))"
        }
        let requestID = callID(in: payload)
        assembler.append(
            ChatMessage(
                id: requestID ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "apply_patch",
                        summary: summary,
                        inputDetail: patch.flatMap { budget.inputDetail($0) }
                    )
                )
            ),
            pendingKey: requestID
        )
    }

    private func mcpNamespace(from payload: TranscriptJSONValue) -> String? {
        let server = nonEmpty(payload["server"]?.string)
            ?? nonEmpty(payload["server_name"]?.string)
            ?? nonEmpty(payload["serverName"]?.string)
            ?? nonEmpty(payload["mcp_server"]?.string)
        guard let server else { return nil }
        if server.hasPrefix("mcp__") {
            return server
        }
        return "mcp__\(server)"
    }

    private func approvalArguments(from values: [TranscriptJSONValue]) -> TranscriptJSONValue? {
        for payload in values {
            for key in ["arguments", "args", "params", "parameters", "input", "toolInput", "tool_input"] {
                guard let value = payload[key] else { continue }
                if let raw = value.string {
                    if let parsed = TranscriptJSONValue(jsonLine: raw) {
                        return parsed
                    }
                    if nonEmpty(raw) != nil {
                        return value
                    }
                } else if value.object != nil || value.array != nil {
                    return value
                }
            }
        }
        return nil
    }

    private func eventArguments(from payload: TranscriptJSONValue) -> TranscriptJSONValue? {
        for key in ["arguments", "args", "params", "parameters"] {
            guard let value = payload[key] else { continue }
            if let raw = value.string {
                if let parsed = TranscriptJSONValue(jsonLine: raw) {
                    return parsed
                }
                if nonEmpty(raw) != nil {
                    return value
                }
            } else if value.object != nil || value.array != nil {
                return value
            }
        }
        return nil
    }

    private func approvalSubject(
        command: String?,
        toolName: String?,
        arguments: TranscriptJSONValue?
    ) -> String {
        if let command { return command }
        if let raw = nonEmpty(arguments?.string) {
            return raw
        }
        if let arguments {
            let json = arguments.compactJSONString()
            if !json.isEmpty && json != "{}" {
                return json
            }
        }
        return toolName ?? ""
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func visibleUserText(_ value: String?) -> String? {
        guard let value, let trimmed = nonEmpty(value) else { return nil }
        guard !Self.userNoisePrefixes.contains(where: { trimmed.hasPrefix($0) }) else {
            return nil
        }
        return value
    }

    private func appendMessage(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let role: ChatRole
        switch payload["role"]?.string {
        case "user": role = .user
        case "assistant": role = .agent
        default: return  // developer / system context injections
        }
        let blocks = payload["content"]?.array ?? []
        let attachments = role == .user ? inputImageAttachments(in: blocks) : []
        let texts = blocks.compactMap { block -> String? in
            guard
                let type = block["type"]?.string,
                type == "input_text" || type == "output_text",
                let text = block["text"]?.string
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if role == .user, visibleUserText(text) == nil {
                return nil
            }
            return text
        }
        guard !texts.isEmpty || !attachments.isEmpty else { return }
        let text = texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        if role == .agent {
            guard let text else { return }
            assembler.appendDeduplicatedAgentProse(
                id: "line-\(seq)",
                seq: seq,
                timestamp: timestamp,
                text: text
            )
            return
        }
        assembler.appendDeduplicatedUserMessage(
            attachments: attachments.map(\.attachment),
            proseText: text,
            fingerprint: userMessageFingerprint(text: text, attachments: attachments),
            baseID: "line-\(seq)",
            seq: seq,
            timestamp: timestamp
        )
    }

    private func appendAgentProse(
        _ value: String?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let text = nonEmpty(value) else { return }
        assembler.appendDeduplicatedAgentProse(
            id: "line-\(seq)",
            seq: seq,
            timestamp: timestamp,
            text: text
        )
    }

    private func appendReasoning(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let summaries = (payload["summary"]?.array ?? []).compactMap { item in
            item["text"]?.string
        }
        let text = summaries.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.append(
            ChatMessage(
                id: "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .thought(ChatThought(text: budget.body(text)))
            )
        )
    }

    private func appendEventReasoning(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let text = eventReasoningFragments(in: payload).joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assembler.append(
            ChatMessage(
                id: "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .thought(ChatThought(text: budget.body(text)))
            )
        )
    }

    private func appendCompletedItem(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let item = payload["item"],
              normalizedEventType(item["type"]?.string) == "plan",
              let text = nonEmpty(item["text"]?.string) else {
            return
        }
        assembler.append(
            ChatMessage(
                id: "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .thought(ChatThought(text: budget.body(text)))
            )
        )
    }

    private func eventReasoningFragments(in payload: TranscriptJSONValue) -> [String] {
        var fragments = ["text", "message"].compactMap { key in
            nonEmpty(payload[key]?.string)
        }
        for key in ["content", "summary"] {
            fragments.append(contentsOf: eventReasoningFragments(from: payload[key]))
        }
        return fragments
    }

    private func eventReasoningFragments(from value: TranscriptJSONValue?) -> [String] {
        guard let value else { return [] }
        if let text = nonEmpty(value.string) {
            return [text]
        }
        if let array = value.array {
            return array.flatMap { eventReasoningFragments(from: $0) }
        }
        guard value.object != nil else { return [] }
        return ["text", "message", "content", "summary"].flatMap { key in
            eventReasoningFragments(from: value[key])
        }
    }

    // MARK: - Tool calls

    private func appendFunctionCall(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let name = payload["name"]?.string else { return }
        let toolName = Self.qualifiedToolName(
            name: name,
            namespace: payload["namespace"]?.string
        )
        let callID = callID(in: payload)
        let arguments = callArguments(in: payload)
        let parsedArguments = arguments.value
        if Self.isShellToolName(name),
            let command = shellCommand(arguments: parsedArguments, payload: payload) {
            append(
                kinds: [.terminal(ChatTerminalCapture(command: command, isRunning: true))],
                baseID: callID ?? "line-\(seq)",
                pendingKey: callID,
                seq: seq,
                timestamp: timestamp,
                into: &assembler
            )
            return
        }
        if Self.isQuestionToolName(name) {
            if appendQuestionRequest(
                parsedArguments,
                callID: callID,
                seq: seq,
                timestamp: timestamp,
                into: &assembler
            ) {
                return
            }
        }
        append(
            kinds: [genericToolUseKind(
                toolName: toolName,
                arguments: parsedArguments,
                rawArguments: arguments.raw
            )],
            baseID: callID ?? "line-\(seq)",
            pendingKey: callID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    @discardableResult
    private func appendQuestionRequest(
        _ payload: TranscriptJSONValue,
        callID: String? = nil,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let candidates = questionCandidatePayloads(in: payload)
        let requestID = nonEmpty(callID)
            ?? firstCallID(in: candidates, keys: Self.callIDKeys)
        return appendQuestionRequest(
            candidates,
            callID: requestID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    @discardableResult
    private func appendQuestionRequest(
        _ arguments: TranscriptJSONValue?,
        callID: String?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let candidates = arguments.map { questionCandidatePayloads(in: $0) } ?? []
        return appendQuestionRequest(
            candidates,
            callID: callID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    @discardableResult
    private func appendQuestionRequest(
        _ candidates: [TranscriptJSONValue],
        callID: String?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        let questions = questionKinds(from: candidates)
        guard !questions.isEmpty else { return false }
        append(
            kinds: questions,
            baseID: callID ?? "line-\(seq)",
            pendingKey: callID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
        return true
    }

    private func questionCandidatePayloads(in payload: TranscriptJSONValue) -> [TranscriptJSONValue] {
        var candidates = [payload]
        for key in Self.questionNestedPayloadKeys {
            guard let candidate = objectPayload(payload[key]) else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    private func questionKinds(from candidates: [TranscriptJSONValue]) -> [ChatMessageKind] {
        for candidate in candidates {
            let kinds = questionKinds(arguments: candidate)
            if !kinds.isEmpty {
                return kinds
            }
        }
        return []
    }

    private func append(
        kinds: [ChatMessageKind],
        baseID: String,
        pendingKey: String?,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
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
    }

    private func appendToolSearchCall(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let callID = callID(in: payload)
        let arguments = callArguments(in: payload)
        append(
            kinds: [genericToolUseKind(
                toolName: "tool_search",
                arguments: arguments.value,
                rawArguments: arguments.raw
            )],
            baseID: callID ?? "line-\(seq)",
            pendingKey: callID,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    private func appendCustomToolCall(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let name = payload["name"]?.string else { return }
        let callID = callID(in: payload)
        let input = payload["input"]?.string ?? ""
        var summary = name
        if name == "apply_patch", let path = firstPatchedFile(in: input) {
            summary = "\(name) \(budget.summaryArgument(path))"
        }
        assembler.append(
            ChatMessage(
                id: callID ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: name,
                        summary: summary,
                        inputDetail: input.isEmpty ? nil : budget.inputDetail(input)
                    )
                )
            ),
            pendingKey: callID
        )
    }

    private func appendWebSearch(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let summary = webSearchSummary(in: payload) else { return }
        let detail = payload["action"].map { rawArgumentsText(for: $0) }
        assembler.append(
            ChatMessage(
                id: callID(in: payload) ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "web_search",
                        summary: summary,
                        inputDetail: detail.flatMap { budget.inputDetail($0) },
                        status: .succeeded
                    )
                )
            )
        )
    }

    private func appendWebSearchBegin(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let summary = webSearchSummary(in: payload) else { return }
        let callID = callID(in: payload)
        let detail = payload["action"].map { rawArgumentsText(for: $0) }
        assembler.append(
            ChatMessage(
                id: callID ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "web_search",
                        summary: summary,
                        inputDetail: detail.flatMap { budget.inputDetail($0) },
                        status: .running
                    )
                )
            ),
            pendingKey: callID
        )
    }

    private func appendWebSearchEndFallback(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let summary = webSearchEndFallbackSummary(in: payload) else { return }
        assembler.append(
            ChatMessage(
                id: callID(in: payload) ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "web_search",
                        summary: summary,
                        status: .succeeded
                    )
                )
            )
        )
    }

    private func appendEventToolCompletionFallback(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        switch normalizedEventType(payload["type"]?.string) {
        case "exec_command_end":
            appendExecCommandEndFallback(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "patch_apply_end":
            appendPatchApplyEndFallback(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "mcp_tool_call_end":
            appendMCPToolCallEndFallback(payload, seq: seq, timestamp: timestamp, into: &assembler)
        case "image_generation_end":
            guard nonEmpty(payload["saved_path"]?.string) != nil
                || nonEmpty(payload["savedPath"]?.string) != nil else { return }
            appendImageGenerationCall(payload, seq: seq, timestamp: timestamp, into: &assembler)
        default:
            return
        }
    }

    private func appendExecCommandEndFallback(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let arguments = eventArguments(from: payload)
        let command = nonEmpty(payload["command"]?.string)
            ?? nonEmpty(payload["cmd"]?.string)
            ?? shellCommand(arguments: arguments, payload: payload).flatMap(nonEmpty)
        guard let command else { return }
        let exitCode = eventExitCode(in: payload)
        assembler.append(
            ChatMessage(
                id: callID(in: payload) ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .terminal(
                    ChatTerminalCapture(
                        command: command,
                        output: eventOutput(in: payload),
                        exitCode: exitCode,
                        durationSeconds: eventDurationSeconds(in: payload),
                        isRunning: false
                    )
                )
            )
        )
    }

    private func appendPatchApplyEndFallback(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let patch = nonEmpty(payload["input"]?.string)
            ?? nonEmpty(payload["patch"]?.string)
            ?? nonEmpty(payload["changes"]?.string)
        let path = patch.flatMap(firstPatchedFile)
            ?? nonEmpty(payload["path"]?.string)
            ?? nonEmpty(payload["file_path"]?.string)
        var summary = "apply_patch"
        if let path {
            summary = "apply_patch \(budget.summaryArgument(path))"
        }
        let exitCode = eventExitCode(in: payload)
        assembler.append(
            ChatMessage(
                id: callID(in: payload) ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "apply_patch",
                        summary: summary,
                        inputDetail: patch.flatMap { budget.inputDetail($0) },
                        output: eventOutput(in: payload),
                        status: toolStatus(exitCode: exitCode)
                    )
                )
            )
        )
    }

    private func appendMCPToolCallEndFallback(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let name = nonEmpty(payload["tool"]?.string)
            ?? nonEmpty(payload["tool_name"]?.string)
            ?? nonEmpty(payload["toolName"]?.string)
            ?? nonEmpty(payload["name"]?.string)
        guard let name else { return }
        let namespace = nonEmpty(payload["namespace"]?.string)
            ?? mcpNamespace(from: payload)
        let toolName = Self.qualifiedToolName(name: name, namespace: namespace)
        let arguments = eventArguments(from: payload)
        let rawArguments = arguments.map { rawArgumentsText(for: $0) }
        let exitCode = eventExitCode(in: payload)
        assembler.append(
            ChatMessage(
                id: callID(in: payload) ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: genericToolUseKind(
                    toolName: toolName,
                    arguments: arguments,
                    rawArguments: rawArguments,
                    output: eventOutput(in: payload),
                    status: toolStatus(exitCode: exitCode)
                )
            )
        )
    }

    private func appendImageGenerationCall(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let callID = callID(in: payload)
        let messageID = callID
            ?? "line-\(seq)"
        let revisedPrompt = nonEmpty(payload["revised_prompt"]?.string)
        let summary: String
        if let revisedPrompt {
            summary = "Generate image \(budget.summaryArgument(revisedPrompt))"
        } else {
            summary = "Generate image"
        }
        let hasResult = hasImageGenerationResult(in: payload)
        let status = imageGenerationStatus(payload["status"]?.string, hasResult: hasResult)
        assembler.append(
            ChatMessage(
                id: messageID,
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "image_generation",
                        summary: summary,
                        inputDetail: revisedPrompt.flatMap { budget.inputDetail($0) },
                        output: nil,
                        status: status
                    )
                )
            ),
            pendingKey: status == .running ? callID : nil
        )
    }

    private func appendViewImageToolCall(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let path = nonEmpty(payload["path"]?.string) else { return }
        assembler.append(
            ChatMessage(
                id: callID(in: payload) ?? "line-\(seq)",
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "view_image",
                        summary: "view_image \(budget.summaryArgument(path))",
                        status: .succeeded
                    )
                )
            )
        )
    }

    private func hasImageGenerationResult(in payload: TranscriptJSONValue) -> Bool {
        if nonEmpty(payload["saved_path"]?.string) != nil {
            return true
        }
        if nonEmpty(payload["result"]?.string) != nil {
            return true
        }
        return payload["result"]?.object != nil || payload["result"]?.array != nil
    }

    private func imageGenerationStatus(
        _ rawStatus: String?,
        hasResult: Bool
    ) -> ChatToolUse.Status {
        if isFailureStatus(rawStatus) {
            return .failed
        }
        if hasResult {
            return .succeeded
        }
        guard let normalized = nonEmpty(rawStatus)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") else {
            return .running
        }
        switch normalized {
        case "generating", "running", "in_progress", "pending", "queued":
            return .running
        default:
            return .succeeded
        }
    }

    private func webSearchSummary(in payload: TranscriptJSONValue) -> String? {
        let action = payload["action"]
        switch action?["type"]?.string {
        case "search":
            return searchSummary(queries: webSearchQueries(in: payload))
        case "open_page":
            if let url = nonEmpty(action?["url"]?.string) {
                return "Open \(budget.summaryArgument(url))"
            }
        case "find_in_page":
            let pattern = nonEmpty(action?["pattern"]?.string)
            let url = nonEmpty(action?["url"]?.string)
            if let pattern, let url {
                return "Find \(budget.summaryArgument(pattern)) in \(budget.summaryArgument(url))"
            }
            if let pattern {
                return "Find \(budget.summaryArgument(pattern))"
            }
        default:
            break
        }
        return searchSummary(queries: webSearchQueries(in: payload))
    }

    private func webSearchEndFallbackSummary(in payload: TranscriptJSONValue) -> String? {
        let action = payload["action"]
        switch action?["type"]?.string {
        case "search":
            return nil
        case "open_page":
            guard nonEmpty(action?["url"]?.string) == nil else { return nil }
        case "find_in_page":
            guard nonEmpty(action?["url"]?.string) == nil,
                  nonEmpty(action?["pattern"]?.string) == nil else { return nil }
        default:
            break
        }
        return searchSummary(queries: webSearchQueries(in: payload))
    }

    private func searchSummary(queries: [String]) -> String? {
        guard !queries.isEmpty else { return nil }
        return "Search \(budget.summaryArgument(queries.joined(separator: "; ")))"
    }

    private func webSearchQueries(in payload: TranscriptJSONValue) -> [String] {
        let action = payload["action"]
        let actionQueries = strings(from: action?["queries"]?.array)
        if !actionQueries.isEmpty { return actionQueries }
        if let query = nonEmpty(action?["query"]?.string) { return [query] }

        let topLevelQueries = strings(from: payload["queries"]?.array)
        if !topLevelQueries.isEmpty { return topLevelQueries }
        if let query = nonEmpty(payload["query"]?.string) { return [query] }
        return []
    }

    private func strings(from values: [TranscriptJSONValue]?) -> [String] {
        (values ?? []).compactMap { value in
            nonEmpty(value.string)
        }
    }

    private func rawArgumentsText(for value: TranscriptJSONValue) -> String {
        if let string = value.string {
            return string
        }
        return value.compactJSONString()
    }

    private func genericToolUseKind(
        toolName: String,
        arguments: TranscriptJSONValue?,
        rawArguments: String?,
        output: String? = nil,
        status: ChatToolUse.Status = .running
    ) -> ChatMessageKind {
        var summary = toolName
        if let arguments {
            for key in Self.summaryArgumentKeys {
                if let value = arguments[key]?.string,
                    !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    summary = "\(toolName) \(budget.summaryArgument(value))"
                    break
                }
            }
        }
        let detail = rawArguments.flatMap { raw -> String? in
            raw.isEmpty || raw == "{}" ? nil : budget.inputDetail(raw)
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

    private func questionKinds(arguments: TranscriptJSONValue?) -> [ChatMessageKind] {
        let questions = questionValues(arguments: arguments)
        return questions.compactMap { question -> ChatMessageKind? in
            let prompt = nonEmpty(question["question"]?.string)
                ?? nonEmpty(question["prompt"]?.string)
                ?? nonEmpty(question["header"]?.string)
            guard let prompt else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option in
                questionOption(from: option)
            }
            return .question(ChatQuestion(prompt: prompt, options: options))
        }
    }

    private func questionValues(arguments: TranscriptJSONValue?) -> [TranscriptJSONValue] {
        if let questions = arguments?["questions"]?.array, !questions.isEmpty {
            return questions
        }
        if hasFlatQuestion(arguments) {
            return arguments.map { [$0] } ?? []
        }
        return []
    }

    private func hasFlatQuestion(_ value: TranscriptJSONValue?) -> Bool {
        nonEmpty(value?["question"]?.string) != nil
            || nonEmpty(value?["prompt"]?.string) != nil
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
        let detail = nonEmpty(option["description"]?.string)
            ?? nonEmpty(option["detail"]?.string)
        return ChatQuestion.Option(label: label, detail: detail)
    }

    private func questionOptionLabel(from value: TranscriptJSONValue?) -> String? {
        guard let value else { return nil }
        if let label = nonEmpty(value.string) {
            return label
        }
        if value.double != nil || value.bool != nil {
            return nonEmpty(value.compactJSONString())
        }
        return nil
    }

    private func indexedID(_ baseID: String, index: Int) -> String {
        index == 0 ? baseID : "\(baseID)#\(index)"
    }

    private func callID(in payload: TranscriptJSONValue) -> String? {
        firstCallID(in: [payload], keys: Self.callIDKeys)
    }

    private func firstCallID(
        in values: [TranscriptJSONValue],
        keys: [String]
    ) -> String? {
        firstString(in: values, keys: keys)
    }

    private func firstString(
        in values: [TranscriptJSONValue],
        keys: [String]
    ) -> String? {
        values.lazy.flatMap { value in
            keys.lazy.compactMap { key in
                nonEmpty(value[key]?.string)
            }
        }.first
    }

    private func approvalCallID(in payload: TranscriptJSONValue) -> String? {
        let candidates = approvalCandidatePayloads(in: payload)
        if let explicit = firstCallID(in: candidates, keys: Self.explicitCallIDKeys) {
            return explicit
        }
        let nested = Array(candidates.dropFirst())
        return firstCallID(in: nested, keys: ["id"])
            ?? firstCallID(in: [payload], keys: ["id"])
    }

    private func approvalCandidatePayloads(in payload: TranscriptJSONValue) -> [TranscriptJSONValue] {
        var candidates = [payload]
        for key in Self.approvalNestedPayloadKeys {
            guard let candidate = objectPayload(payload[key]) else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    private func objectPayload(_ value: TranscriptJSONValue?) -> TranscriptJSONValue? {
        guard let value else { return nil }
        if value.object != nil {
            return value
        }
        if let raw = value.string,
           let parsed = TranscriptJSONValue(jsonLine: raw),
           parsed.object != nil {
            return parsed
        }
        return nil
    }

    private func callArguments(
        in payload: TranscriptJSONValue
    ) -> (value: TranscriptJSONValue?, raw: String?) {
        guard let arguments = payload["arguments"] else { return (nil, nil) }
        if let raw = arguments.string {
            return (TranscriptJSONValue(jsonLine: raw), raw)
        }
        guard arguments.object != nil || arguments.array != nil else {
            return (nil, nil)
        }
        let raw = rawArgumentsText(for: arguments)
        return (arguments, raw.isEmpty ? nil : raw)
    }

    /// Extracts the human-meaningful command line from a shell-style call.
    ///
    /// Handles `{"cmd": "..."}` (current `exec_command`), `{"command":
    /// "..."}`, and `{"command": ["bash", "-lc", "actual"]}` (older
    /// `shell`), plus the `local_shell_call` `action.command` array.
    private func shellCommand(
        arguments: TranscriptJSONValue?,
        payload: TranscriptJSONValue
    ) -> String? {
        if let cmd = arguments?["cmd"]?.string { return cmd }
        if let cmd = arguments?["command"]?.string { return cmd }
        if let sessionID = stdinSessionID(in: arguments) {
            return "write_stdin session \(sessionID)"
        }
        let parts = arguments?["command"]?.array ?? payload["action"]?["command"]?.array
        guard let parts else { return nil }
        let strings = parts.compactMap(\.string)
        guard !strings.isEmpty else { return nil }
        if strings.count >= 3,
            let binary = strings[0].split(separator: "/").last,
            Self.shellWrapperBinaries.contains(String(binary)),
            strings[1] == "-lc" || strings[1] == "-c" {
            return strings[2...].joined(separator: " ")
        }
        return strings.joined(separator: " ")
    }

    private func stdinSessionID(in arguments: TranscriptJSONValue?) -> String? {
        if let sessionID = arguments?["session_id"]?.int {
            return String(sessionID)
        }
        return nonEmpty(arguments?["session_id"]?.string)
    }

    private func firstPatchedFile(in patch: String) -> String? {
        guard
            let match = patch.firstMatch(
                of: /\*\*\* (?:Update|Add|Delete) File: (.+)/
            )
        else { return nil }
        return String(match.1)
    }

    // MARK: - Tool outputs

    private func resolveOutput(
        _ payload: TranscriptJSONValue,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = callID(in: payload) else { return }
        assembler.resolve(
            key: callID,
            completion: completion(
                from: payload["output"],
                timestamp: timestamp,
                permissionResolution: .approved
            )
        )
    }

    private func resolveApprovalEvent(
        _ payload: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = approvalCallID(in: payload),
              let resolution = approvalResolution(in: payload) else {
            return
        }
        appendStateUpdate(.inputResolved, seq: seq, timestamp: timestamp, into: &assembler)
        let completion = TranscriptToolCompletion(
            output: approvalResolutionOutput(in: payload),
            isError: resolution != .approved,
            exitCode: resolution == .approved ? nil : 1,
            timestamp: timestamp,
            permissionResolution: resolution
        )
        if resolution == .approved {
            assembler.resolvePermissions(key: callID, completion: completion)
        } else {
            assembler.resolve(key: callID, completion: completion)
            appendStateUpdate(.idle, seq: seq, timestamp: timestamp, into: &assembler)
        }
    }

    private func resolvePendingAsInterrupted(
        _ payload: TranscriptJSONValue,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        assembler.resolveAll(
            completion: TranscriptToolCompletion(
                output: interruptionOutput(in: payload),
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

    @discardableResult
    private func resolveEventToolCompletion(
        _ payload: TranscriptJSONValue,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        guard let callID = callID(in: payload) else {
            return false
        }
        let exitCode = eventExitCode(in: payload)
        return assembler.resolve(
            key: callID,
            completion: TranscriptToolCompletion(
                output: eventOutput(in: payload),
                isError: (exitCode ?? 0) != 0,
                exitCode: exitCode,
                durationSeconds: eventDurationSeconds(in: payload),
                timestamp: timestamp
            )
        )
    }

    private func approvalResolution(in payload: TranscriptJSONValue) -> ChatPermissionRequest.Resolution? {
        for candidate in approvalCandidatePayloads(in: payload) {
            guard let resolution = approvalResolutionValue(in: candidate) else { continue }
            return resolution
        }
        return nil
    }

    private func approvalResolutionValue(
        in payload: TranscriptJSONValue
    ) -> ChatPermissionRequest.Resolution? {
        for key in ["approved", "allowed", "allow"] {
            guard let approved = payload[key]?.bool else { continue }
            return approved ? .approved : .denied
        }
        for key in ["denied", "rejected", "disallowed", "blocked"] {
            guard let denied = payload[key]?.bool else { continue }
            return denied ? .denied : .approved
        }
        for key in ["decision", "resolution", "status", "outcome", "result"] {
            guard let raw = normalizedStatus(payload[key]?.string) else { continue }
            switch raw {
            case "approve", "approved", "allow", "allowed", "accept", "accepted",
                 "grant", "granted", "yes", "true", "ok", "success", "succeeded":
                return .approved
            case "deny", "denied", "reject", "rejected", "disallow", "disallowed",
                 "block", "blocked", "no", "false":
                return .denied
            case "expire", "expired", "timeout", "timed_out", "cancel", "cancelled", "canceled":
                return .expired
            default:
                continue
            }
        }
        return nil
    }

    private func approvalResolutionOutput(in payload: TranscriptJSONValue) -> String? {
        for candidate in approvalCandidatePayloads(in: payload) {
            guard let output = approvalResolutionOutputValue(in: candidate) else { continue }
            return output
        }
        return nil
    }

    private func approvalResolutionOutputValue(in payload: TranscriptJSONValue) -> String? {
        for key in ["message", "reason", "detail", "error"] {
            guard let output = nonEmpty(payload[key]?.string) else { continue }
            return output
        }
        return nil
    }

    private func interruptionOutput(in payload: TranscriptJSONValue) -> String? {
        nonEmpty(payload["message"]?.string)
            ?? nonEmpty(payload["reason"]?.string)
            ?? nonEmpty(payload["detail"]?.string)
            ?? nonEmpty(payload["error"]?.string)
    }

    private func eventOutput(in payload: TranscriptJSONValue) -> String? {
        for key in ["aggregated_output", "aggregatedOutput", "formatted_output", "formattedOutput", "output"] {
            guard let output = nonEmpty(payload[key]?.string) else { continue }
            return output
        }

        let streams = ["stdout", "standardOutput", "stderr", "standardError"].compactMap { key in
            nonEmpty(payload[key]?.string)
        }
        if !streams.isEmpty {
            return streams.joined(separator: "\n\n")
        }

        if normalizedEventType(payload["type"]?.string) == "image_generation_end" {
            return nonEmpty(payload["saved_path"]?.string)
                ?? nonEmpty(payload["savedPath"]?.string)
        }

        if let result = payload["result"], let output = eventOutputValue(result) {
            return output
        }
        return nonEmpty(payload["saved_path"]?.string)
            ?? nonEmpty(payload["savedPath"]?.string)
            ?? nonEmpty(payload["revised_prompt"]?.string)
            ?? nonEmpty(payload["revisedPrompt"]?.string)
    }

    private func eventOutputValue(_ value: TranscriptJSONValue) -> String? {
        if let string = nonEmpty(value.string) {
            return string
        }
        guard value.object != nil || value.array != nil else { return nil }
        if let output = mcpResultOutput(in: value) {
            return output
        }
        let raw = value.compactJSONString()
        return raw.isEmpty || raw == "{}" || raw == "[]" ? nil : raw
    }

    private func eventExitCode(in payload: TranscriptJSONValue) -> Int? {
        if let result = payload["result"], mcpResultIsError(in: result) {
            return 1
        }
        for key in ["exit_code", "exitCode", "code"] {
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
        if normalizedEventType(payload["type"]?.string) == "image_generation_end",
           hasImageGenerationResult(in: payload) {
            return 0
        }
        guard let status = normalizedStatus(payload["status"]?.string) else {
            return nil
        }
        switch status {
        case "success", "succeeded", "ok", "completed", "complete", "done":
            return 0
        case "error", "failed", "failure", "cancel", "cancelled", "canceled",
             "timeout", "timed_out":
            return 1
        default:
            return nil
        }
    }

    private func mcpResultOutput(in value: TranscriptJSONValue) -> String? {
        if let error = nonEmpty(value["Err"]?.string) {
            return error
        }
        guard let ok = value["Ok"] else {
            return nil
        }
        let contentFragments = completionTextFragments(from: ok["content"] ?? ok)
        if !contentFragments.isEmpty {
            return contentFragments.joined(separator: "\n")
        }
        for structuredKey in ["structuredContent", "structured_content"] {
            guard let structured = ok[structuredKey] else { continue }
            for resultKey in ["result", "output", "message", "text"] {
                guard let candidate = structured[resultKey],
                      let output = eventOutputValue(candidate) else {
                    continue
                }
                return output
            }
            if let output = eventOutputValue(structured) {
                return output
            }
        }
        return nil
    }

    private func mcpResultIsError(in value: TranscriptJSONValue) -> Bool {
        if nonEmpty(value["Err"]?.string) != nil {
            return true
        }
        guard let ok = value["Ok"] else {
            return false
        }
        return ok["isError"]?.bool == true
            || ok["is_error"]?.bool == true
            || ok["error"]?.bool == true
    }

    private func eventDurationSeconds(in payload: TranscriptJSONValue) -> Double? {
        for key in ["duration", "duration_seconds", "durationSeconds", "elapsed_seconds", "elapsedSeconds"] {
            if let seconds = eventDurationSeconds(in: payload[key]) {
                return seconds
            }
        }
        for key in ["duration_ms", "durationMs", "elapsed_ms", "elapsedMs"] {
            if let milliseconds = payload[key]?.double {
                return milliseconds / 1_000
            }
            if let raw = payload[key]?.string,
               let milliseconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return milliseconds / 1_000
            }
        }
        return nil
    }

    private func eventDurationSeconds(in value: TranscriptJSONValue?) -> Double? {
        guard let value else { return nil }
        if let seconds = value.double {
            return seconds
        }
        if let raw = value.string,
           let seconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return seconds
        }
        let seconds = value["secs"]?.double ?? value["seconds"]?.double
        let nanos = value["nanos"]?.double ?? value["nanoseconds"]?.double
        guard seconds != nil || nanos != nil else { return nil }
        return (seconds ?? 0) + ((nanos ?? 0) / 1_000_000_000)
    }

    private func resolveToolSearchOutput(
        _ payload: TranscriptJSONValue,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = callID(in: payload) else { return }
        assembler.resolve(
            key: callID,
            completion: TranscriptToolCompletion(
                output: toolSearchOutput(in: payload),
                isError: isFailureStatus(payload["status"]?.string),
                timestamp: timestamp
            )
        )
    }

    private func toolSearchOutput(in payload: TranscriptJSONValue) -> String? {
        guard let tools = payload["tools"] else {
            return nonEmpty(payload["output"]?.string)
        }
        return eventOutputValue(tools)
    }

    private func isFailureStatus(_ status: String?) -> Bool {
        guard let normalized = normalizedStatus(status) else { return false }
        switch normalized {
        case "error", "failed", "failure", "cancel", "cancelled", "canceled",
             "timeout", "timed_out":
            return true
        default:
            return false
        }
    }

    private func toolStatus(exitCode: Int?) -> ChatToolUse.Status {
        (exitCode ?? 0) == 0 ? .succeeded : .failed
    }

    private func normalizedStatus(_ status: String?) -> String? {
        nonEmpty(status)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func completionMetadataExitCode(in value: TranscriptJSONValue?) -> Int? {
        guard let metadata = value?["metadata"] else { return nil }
        return eventExitCode(in: metadata)
    }

    private func completionMetadataDurationSeconds(in value: TranscriptJSONValue?) -> Double? {
        guard let metadata = value?["metadata"] else { return nil }
        return eventDurationSeconds(in: metadata)
    }

    private func completionFailureHint(in text: String?) -> Bool {
        guard let text = nonEmpty(text) else { return false }
        return text.hasPrefix("apply_patch verification failed:")
            || text.hasPrefix("write_stdin failed:")
    }

    private func completionTerminalIsRunning(in text: String?) -> Bool {
        guard let text = nonEmpty(text) else { return false }
        return text.prefix(400).contains("Process running with session ID")
    }

    /// Builds a completion from an output payload, which is a plain string,
    /// a JSON-encoded `{"output": ..., "metadata": {"exit_code": ...}}`
    /// string, or that object inline; exit code and wall time also appear
    /// as text headers (`Process exited with code N`, `Exit code: N`,
    /// `Wall time: S seconds`).
    private func completion(
        from value: TranscriptJSONValue?,
        timestamp: Date? = nil,
        permissionResolution: ChatPermissionRequest.Resolution? = nil
    ) -> TranscriptToolCompletion {
        var text = completionOutputText(from: value)
        var exitCode = completionMetadataExitCode(in: value)
        var duration = completionMetadataDurationSeconds(in: value)
        if let raw = text,
            let nested = TranscriptJSONValue(jsonLine: raw),
            let inner = completionOutputText(from: nested) {
            text = inner
            exitCode = completionMetadataExitCode(in: nested) ?? exitCode
            duration = completionMetadataDurationSeconds(in: nested) ?? duration
        }
        if exitCode == nil, let text {
            let head = text.prefix(400)
            if let match = head.firstMatch(
                of: /(?:Process exited with code|Exit code:?|exited with code) (-?\d+)/
            ) {
                exitCode = Int(match.1)
            }
        }
        if duration == nil, let text,
            let match = text.prefix(400).firstMatch(of: /Wall time: ([0-9.]+) seconds/) {
            duration = Double(match.1)
        }
        return TranscriptToolCompletion(
            output: text,
            isError: completionFailureHint(in: text) || (exitCode ?? 0) != 0,
            exitCode: exitCode,
            durationSeconds: duration,
            timestamp: timestamp,
            permissionResolution: permissionResolution,
            terminalIsRunning: completionTerminalIsRunning(in: text)
        )
    }

    private func completionOutputText(from value: TranscriptJSONValue?) -> String? {
        guard let value else { return nil }
        if let text = nonEmpty(value.string) {
            return text
        }
        if let array = value.array {
            let fragments = array.flatMap { completionTextFragments(from: $0) }
            return fragments.isEmpty ? nil : fragments.joined(separator: "\n")
        }
        guard value.object != nil else { return nil }
        for key in Self.completionOutputKeys {
            guard let output = completionOutputText(from: value[key]) else { continue }
            return output
        }
        if let answerOutput = structuredQuestionAnswerOutputText(from: value) {
            return answerOutput
        }
        return nil
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
        for key in ["data", "payload", "response", "functionResponse", "function_response"] {
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

    private func completionTextFragments(from value: TranscriptJSONValue) -> [String] {
        if let text = nonEmpty(value.string) {
            return [text]
        }
        if let array = value.array {
            return array.flatMap { completionTextFragments(from: $0) }
        }
        guard value.object != nil else { return [] }
        let type = value["type"]?.string
        if type == "input_text" || type == "output_text" || type == "text",
           let text = nonEmpty(value["text"]?.string) {
            return [text]
        }
        return value["content"].map { completionTextFragments(from: $0) } ?? []
    }
}
