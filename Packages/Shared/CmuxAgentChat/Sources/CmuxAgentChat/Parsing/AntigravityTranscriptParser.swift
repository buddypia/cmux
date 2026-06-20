import Foundation

/// Converts Antigravity CLI transcript JSONL lines and single-object JSON
/// snapshots into ``ChatMessage`` values.
///
/// Antigravity's hook contract exposes a `transcriptPath`, but its transcript
/// rows have evolved across releases. This parser therefore reads the current
/// `role`/`parts` JSONL shape plus the stable semantic shapes cmux already
/// receives from hooks: user and assistant/agent/model message rows, plus
/// `PreToolUse`/`PostToolUse` tool lifecycle rows. Unknown rows fail open.
public struct AntigravityTranscriptParser: Sendable {
    private static let userNoisePrefixes = [
        "<environment_context",
        "<permissions",
        "# AGENTS.md instructions",
    ]
    private static let shellToolNames: Set<String> = [
        "run_command", "execute_bash", "shell", "exec_command", "run_shell_command",
    ]
    private static let summaryArgumentKeys = [
        "path", "file_path", "absolute_path", "relative_path", "file", "pattern",
        "query", "url", "text", "command", "cmd",
    ]

    private let budget = TranscriptTextBudget()
    private let timestamps = TranscriptTimestampParser()

    /// Creates an Antigravity transcript parser.
    public init() {}

    /// Parses a contiguous run of JSONL lines into chat messages.
    ///
    /// - Parameters:
    ///   - lines: The raw JSONL lines, one transcript row each.
    ///   - startingSeq: The absolute line index of the first input line.
    ///   - state: Carry-over state from the previous parse call.
    /// - Returns: The new messages, updates to earlier messages whose tool
    ///   result arrived in this call, and the next carry-over state.
    public func parse(
        lines: some Sequence<String>,
        startingSeq: Int,
        state: ChatTranscriptParseState = ChatTranscriptParseState()
    ) -> ChatTranscriptParseResult {
        var records: [(seq: Int, root: TranscriptJSONValue)] = []
        for (offset, line) in lines.enumerated() {
            guard let root = TranscriptJSONValue(jsonLine: line), root.object != nil else {
                continue
            }
            records.append((seq: startingSeq + offset, root: root))
        }
        return parse(records: records, state: state)
    }

    /// Parses Antigravity's newer single-object `.json` transcript shape
    /// (`{ sessionId, projectHash, messages: [...] }`) into chat messages.
    ///
    /// The snapshot is treated as a virtual transcript: top-level metadata gets
    /// the first seq when present, followed by each row in `messages` or
    /// `conversation`.
    public func parse(
        transcriptJSONData data: Data,
        startingSeq: Int = 0,
        state: ChatTranscriptParseState = ChatTranscriptParseState()
    ) -> ChatTranscriptParseResult {
        guard let root = try? JSONDecoder().decode(TranscriptJSONValue.self, from: data),
              root.object != nil else {
            return ChatTranscriptParseResult(messages: [], updatedMessages: [], state: state)
        }

        var records: [(seq: Int, root: TranscriptJSONValue)] = []
        var nextSeq = startingSeq
        if root["sessionId"]?.string != nil, root["projectHash"]?.string != nil {
            records.append((seq: nextSeq, root: root))
            nextSeq += 1
        }
        if let rows = root["messages"]?.array ?? root["conversation"]?.array {
            for row in rows where row.object != nil {
                records.append((seq: nextSeq, root: row))
                nextSeq += 1
            }
        } else if records.isEmpty {
            records.append((seq: nextSeq, root: root))
        }
        return parse(records: records, state: state)
    }

    private func parse(
        records: [(seq: Int, root: TranscriptJSONValue)],
        state: ChatTranscriptParseState
    ) -> ChatTranscriptParseResult {
        var assembler = TranscriptBatchAssembler(state: state, budget: budget)
        var lastTimestamp = state.lastTimestamp
        for (seq, root) in records {
            if let stamped = timestamps.date(from: firstString(in: root, keys: [
                "timestamp", "created_at", "createdAt", "time", "startTime", "lastUpdated",
            ])) {
                lastTimestamp = stamped
            }
            let timestamp = lastTimestamp ?? Date(timeIntervalSince1970: 0)
            if appendCurrentAgyRecord(root, seq: seq, timestamp: timestamp, into: &assembler) {
                continue
            }
            if appendRolePartsRecord(root, seq: seq, timestamp: timestamp, into: &assembler) {
                continue
            }
            let event = normalizedEventName(firstString(in: root, keys: [
                "hook_event_name", "hookEventName", "event_name", "eventName", "event", "type", "kind",
            ]))
            switch event {
            case "sessionstart":
                appendSessionStart(root, seq: seq, timestamp: timestamp, into: &assembler)
                continue
            case "sessionend":
                appendSessionEnd(root, seq: seq, timestamp: timestamp, into: &assembler)
                continue
            case "precompact", "postcompact", "compacted":
                appendContextCompacted(root, seq: seq, timestamp: timestamp, into: &assembler)
                continue
            case "pretooluse", "toolstart", "toolcall":
                appendToolStart(root, seq: seq, timestamp: timestamp, into: &assembler)
                continue
            case "posttooluse", "toolend", "toolresult":
                resolveToolResult(root, into: &assembler)
                continue
            default:
                break
            }
            appendMessage(root, seq: seq, timestamp: timestamp, into: &assembler)
        }
        return assembler.result(lastTimestamp: lastTimestamp)
    }

    // MARK: - Lifecycle

    private func appendSessionStart(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let detail = firstString(in: root, keys: ["cwd", "workspace", "workspacePath"])
            ?? root["workspacePaths"]?.array?.first?.string
        assembler.append(
            ChatMessage(
                id: lineID(root, seq: seq),
                seq: seq,
                role: .system,
                timestamp: timestamp,
                kind: .status(ChatStatusTransition(event: .sessionStarted, detail: detail))
            )
        )
    }

    private func appendSessionEnd(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        assembler.append(
            ChatMessage(
                id: lineID(root, seq: seq),
                seq: seq,
                role: .system,
                timestamp: timestamp,
                kind: .status(
                    ChatStatusTransition(
                        event: .sessionEnded,
                        detail: firstString(in: root, keys: ["terminationReason", "reason", "error"])
                    )
                )
            )
        )
    }

    private func appendContextCompacted(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        assembler.append(
            ChatMessage(
                id: lineID(root, seq: seq),
                seq: seq,
                role: .system,
                timestamp: timestamp,
                kind: .status(ChatStatusTransition(event: .contextCompacted))
            )
        )
    }

    // MARK: - Messages

    private func appendCurrentAgyRecord(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        if root["type"] == nil,
           root["sessionId"]?.string != nil,
           root["projectHash"]?.string != nil {
            appendSessionStart(root, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        }
        switch root["type"]?.string?.lowercased() {
        case "gemini":
            appendCurrentAgyGemini(root, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        case "user":
            guard let text = currentAgyContentText(root["content"]),
                  !Self.userNoisePrefixes.contains(where: { text.hasPrefix($0) })
            else { return true }
            assembler.append(
                ChatMessage(
                    id: lineID(root, seq: seq),
                    seq: seq,
                    role: .user,
                    timestamp: timestamp,
                    kind: .prose(ChatProse(text: budget.body(text)))
                )
            )
            return true
        default:
            return false
        }
    }

    private func appendCurrentAgyGemini(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        if let text = currentAgyContentText(root["content"]) {
            assembler.append(
                ChatMessage(
                    id: partLineID(root, seq: seq, label: "text", index: 0),
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: .prose(ChatProse(text: budget.body(text)))
                )
            )
        }
        for (index, thought) in (root["thoughts"]?.array ?? []).enumerated() {
            guard let text = nonEmpty(thought["description"]?.string ?? thought["text"]?.string) else {
                continue
            }
            assembler.append(
                ChatMessage(
                    id: partLineID(root, seq: seq, label: "thought", index: index),
                    seq: seq,
                    role: .agent,
                    timestamp: timestamp,
                    kind: .thought(ChatThought(text: budget.body(text)))
                )
            )
        }
        for call in root["toolCalls"]?.array ?? [] {
            guard let callID = toolCallID(root: root, call: call) else { continue }
            appendToolInvocation(
                root: root,
                call: call,
                seq: seq,
                timestamp: timestamp,
                into: &assembler
            )
            assembler.resolve(key: callID, completion: currentAgyCompletion(from: call))
        }
    }

    private func appendRolePartsRecord(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) -> Bool {
        guard let role = root["role"]?.string?.lowercased() else { return false }
        if role == "event" {
            appendRoleEvent(root, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        }
        guard let parts = root["parts"]?.array else { return false }
        switch role {
        case "user":
            appendRoleUserParts(root, parts: parts, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        case "model", "assistant", "agent":
            appendRoleModelParts(root, parts: parts, seq: seq, timestamp: timestamp, into: &assembler)
            return true
        case "tool":
            resolveRoleToolParts(root, parts: parts, into: &assembler)
            return true
        default:
            return false
        }
    }

    private func appendRoleEvent(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        switch normalizedEventName(firstString(in: root, keys: ["name", "event", "type", "kind"])) {
        case "sessionmetadata":
            appendSessionStart(root, seq: seq, timestamp: timestamp, into: &assembler)
        case "toolauthorizationrequired", "permissionrequired":
            appendPermissionRequest(root, seq: seq, timestamp: timestamp, into: &assembler)
        case "toolauthorizationresult", "toolauthorizationdecision",
             "toolauthorizationresponse", "toolauthorizationresolved",
             "permissionresult", "permissiondecision", "permissionresponse":
            resolvePermissionResult(root, into: &assembler)
        case "turncomplete":
            break
        default:
            break
        }
    }

    private func appendRoleUserParts(
        _ root: TranscriptJSONValue,
        parts: [TranscriptJSONValue],
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let text = parts
            .compactMap { nonEmpty($0["text"]?.string) }
            .joined(separator: " ")
        guard !text.isEmpty,
              !Self.userNoisePrefixes.contains(where: { text.hasPrefix($0) })
        else { return }
        assembler.append(
            ChatMessage(
                id: lineID(root, seq: seq),
                seq: seq,
                role: .user,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: budget.body(text)))
            )
        )
    }

    private func appendRoleModelParts(
        _ root: TranscriptJSONValue,
        parts: [TranscriptJSONValue],
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        for (index, part) in parts.enumerated() {
            if let thought = nonEmpty(part["thought"]?.string) {
                assembler.append(
                    ChatMessage(
                        id: partLineID(root, seq: seq, label: "thought", index: index),
                        seq: seq,
                        role: .agent,
                        timestamp: timestamp,
                        kind: .thought(ChatThought(text: budget.body(thought)))
                    )
                )
            } else if let text = nonEmpty(part["text"]?.string) {
                assembler.append(
                    ChatMessage(
                        id: partLineID(root, seq: seq, label: "text", index: index),
                        seq: seq,
                        role: .agent,
                        timestamp: timestamp,
                        kind: .prose(ChatProse(text: budget.body(text)))
                    )
                )
            } else if let call = part["functionCall"] {
                appendToolInvocation(
                    root: root,
                    call: call,
                    seq: seq,
                    timestamp: timestamp,
                    into: &assembler
                )
            }
        }
    }

    private func resolveRoleToolParts(
        _ root: TranscriptJSONValue,
        parts: [TranscriptJSONValue],
        into assembler: inout TranscriptBatchAssembler
    ) {
        for part in parts {
            guard let response = part["functionResponse"],
                  let callID = toolCallID(root: root, call: response)
            else { continue }
            let result = firstObject(in: response, keys: ["response", "result", "output"])
            assembler.resolve(key: callID, completion: completion(from: result ?? response))
        }
    }

    private func appendPermissionRequest(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let callID = firstString(in: root, keys: [
            "toolCallId", "tool_call_id", "requestId", "request_id", "id",
        ])
        let toolName = firstString(in: root, keys: ["toolName", "tool_name", "tool"])
        let input = firstObject(in: root, keys: ["args", "arguments", "tool_input", "toolInput", "parameters"])
        let subject = shellCommand(from: input)
            ?? input.flatMap { nonEmpty($0.compactJSONString()) }
            ?? toolName
            ?? "Antigravity tool"
        assembler.append(
            ChatMessage(
                id: callID ?? lineID(root, seq: seq),
                seq: seq,
                role: .system,
                timestamp: timestamp,
                kind: .permissionRequest(
                    ChatPermissionRequest(
                        title: "Antigravity needs approval:",
                        subject: budget.summaryArgument(subject)
                    )
                )
            ),
            pendingKey: callID
        )
    }

    private func resolvePermissionResult(
        _ root: TranscriptJSONValue,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let callID = firstString(in: root, keys: [
            "toolCallId", "tool_call_id", "requestId", "request_id", "callId", "call_id", "id",
        ]),
            let resolution = permissionResolution(from: root)
        else { return }
        let denied = resolution == .denied
        assembler.resolve(
            key: callID,
            completion: TranscriptToolCompletion(
                output: nil,
                isError: denied,
                exitCode: denied ? 1 : 0
            )
        )
    }

    private func appendMessage(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        for container in containers(from: root) {
            guard let role = chatRole(from: container) else { continue }
            if let thought = thoughtText(from: container), !thought.isEmpty {
                assembler.append(
                    ChatMessage(
                        id: "\(lineID(root, seq: seq))-thought",
                        seq: seq,
                        role: .agent,
                        timestamp: timestamp,
                        kind: .thought(ChatThought(text: budget.body(thought)))
                    )
                )
            }
            guard let text = messageText(from: container), !text.isEmpty else { continue }
            if role == .user,
               Self.userNoisePrefixes.contains(where: { text.hasPrefix($0) }) {
                continue
            }
            assembler.append(
                ChatMessage(
                    id: lineID(root, seq: seq),
                    seq: seq,
                    role: role,
                    timestamp: timestamp,
                    kind: .prose(ChatProse(text: budget.body(text)))
                )
            )
            return
        }
    }

    private func chatRole(from value: TranscriptJSONValue) -> ChatRole? {
        let role = firstString(in: value, keys: ["role", "author", "speaker"])?.lowercased()
        let type = firstString(in: value, keys: ["type", "kind"])?.lowercased()
        switch role ?? type {
        case "user", "human":
            return .user
        case "assistant", "agent", "model", "assistant_message", "agent_message", "model_message":
            return .agent
        default:
            return nil
        }
    }

    private func messageText(from value: TranscriptJSONValue) -> String? {
        if let content = value["content"] {
            if let text = content.string {
                return nonEmpty(text)
            }
            let texts = (content.array ?? []).compactMap { block -> String? in
                let type = block["type"]?.string
                guard type == nil || type == "text" || type == "input_text" || type == "output_text" else {
                    return nil
                }
                return nonEmpty(block["text"]?.string ?? block["content"]?.string ?? "")
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n\n")
            }
        }
        return firstString(in: value, keys: [
            "text", "body", "summary", "assistant_response", "assistantResponse",
            "last_assistant_message", "lastAssistantMessage",
        ]).flatMap(nonEmpty)
    }

    private func thoughtText(from value: TranscriptJSONValue) -> String? {
        let blocks = value["content"]?.array ?? []
        let texts = blocks.compactMap { block -> String? in
            switch block["type"]?.string {
            case "thinking":
                return nonEmpty(block["thinking"]?.string ?? block["text"]?.string ?? "")
            case "reasoning":
                return nonEmpty(block["text"]?.string ?? block["summary"]?.string ?? "")
            default:
                return nil
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    // MARK: - Tools

    private func appendToolStart(
        _ root: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let call = toolCall(in: root) else { return }
        appendToolInvocation(
            root: root,
            call: call,
            seq: seq,
            timestamp: timestamp,
            into: &assembler
        )
    }

    private func appendToolInvocation(
        root: TranscriptJSONValue,
        call: TranscriptJSONValue,
        seq: Int,
        timestamp: Date,
        into assembler: inout TranscriptBatchAssembler
    ) {
        guard let name = firstString(in: call, keys: ["name", "tool_name", "toolName", "tool"])
        else { return }
        let callID = toolCallID(root: root, call: call)
        let input = toolInput(root: root, call: call)
        let kind: ChatMessageKind
        if Self.shellToolNames.contains(name),
           let command = shellCommand(from: input) {
            kind = .terminal(ChatTerminalCapture(command: command, isRunning: true))
        } else {
            let inputDetail = input.flatMap { value -> String? in
                let json = value.compactJSONString()
                return json == "{}" ? nil : budget.inputDetail(json)
            }
            kind = .toolUse(
                ChatToolUse(
                    toolName: name,
                    summary: toolSummary(name: name, input: input),
                    inputDetail: inputDetail
                )
            )
        }
        assembler.append(
            ChatMessage(
                id: callID ?? lineID(root, seq: seq),
                seq: seq,
                role: .agent,
                timestamp: timestamp,
                kind: kind
            ),
            pendingKey: callID
        )
    }

    private func resolveToolResult(
        _ root: TranscriptJSONValue,
        into assembler: inout TranscriptBatchAssembler
    ) {
        let call = toolCall(in: root)
        guard let callID = toolCallID(root: root, call: call) else { return }
        let result = firstObject(in: root, keys: ["tool_result", "toolResult", "result", "response", "output"])
        assembler.resolve(key: callID, completion: completion(from: result ?? root))
    }

    private func toolCall(in root: TranscriptJSONValue) -> TranscriptJSONValue? {
        for container in containers(from: root) {
            if let call = firstObject(in: container, keys: ["toolCall", "tool_call", "tool"]) {
                return call
            }
            if firstString(in: container, keys: ["tool_name", "toolName", "name"]) != nil {
                return container
            }
        }
        return nil
    }

    private func toolInput(root: TranscriptJSONValue, call: TranscriptJSONValue) -> TranscriptJSONValue? {
        if let input = firstObject(in: call, keys: ["args", "arguments", "input", "tool_input", "toolInput"]) {
            return input
        }
        for container in containers(from: root) {
            if let input = firstObject(in: container, keys: ["tool_input", "toolInput", "args", "arguments"]) {
                return input
            }
        }
        return nil
    }

    private func toolCallID(root: TranscriptJSONValue, call: TranscriptJSONValue?) -> String? {
        if let call,
           let id = firstString(in: call, keys: ["id", "call_id", "callId", "tool_call_id", "toolCallId"]) {
            return id
        }
        return firstString(in: root, keys: ["tool_call_id", "toolCallId", "call_id", "callId", "id"])
    }

    private func shellCommand(from input: TranscriptJSONValue?) -> String? {
        guard let input else { return nil }
        if let cmd = firstString(in: input, keys: ["command", "cmd", "script"]) {
            return cmd
        }
        if let parts = input["command"]?.array ?? input["cmd"]?.array {
            let strings = parts.compactMap(\.string)
            guard !strings.isEmpty else { return nil }
            if strings.count >= 3,
               let binary = strings[0].split(separator: "/").last,
               ["bash", "sh", "zsh"].contains(String(binary)),
               strings[1] == "-lc" || strings[1] == "-c" {
                return strings[2...].joined(separator: " ")
            }
            return strings.joined(separator: " ")
        }
        return nil
    }

    private func toolSummary(name: String, input: TranscriptJSONValue?) -> String {
        guard let input else { return name }
        for key in Self.summaryArgumentKeys {
            if let value = input[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(name) \(budget.summaryArgument(value))"
            }
        }
        return name
    }

    private func completion(from value: TranscriptJSONValue) -> TranscriptToolCompletion {
        let text = firstString(in: value, keys: ["output", "result", "stdout", "stderr", "text", "message"])
            ?? value["error"]?.string
            ?? value.string
        var exitCode = firstInt(in: value, keys: ["exit_code", "exitCode", "status"])
            ?? firstInt(in: value["metadata"], keys: ["exit_code", "exitCode"])
        let duration = firstDouble(in: value, keys: ["duration_seconds", "durationSeconds", "wall_time_seconds"])
            ?? firstDouble(in: value["metadata"], keys: ["duration_seconds", "durationSeconds"])
        if exitCode == nil, let text,
           let match = text.prefix(400).firstMatch(of: /(?:Process exited with code|Exit code:?|exited with code) (-?\d+)/) {
            exitCode = Int(match.1)
        }
        let explicitError = value["is_error"]?.bool
            ?? value["isError"]?.bool
            ?? value["error"]?.bool
            ?? (value["error"] == nil ? nil : true)
        return TranscriptToolCompletion(
            output: text,
            isError: explicitError ?? ((exitCode ?? 0) != 0),
            exitCode: exitCode,
            durationSeconds: duration
        )
    }

    // MARK: - Helpers

    private func currentAgyContentText(_ value: TranscriptJSONValue?) -> String? {
        guard let value else { return nil }
        if let text = nonEmpty(value.string) {
            return text
        }
        let texts = (value.array ?? []).compactMap { part -> String? in
            nonEmpty(part.string ?? part["text"]?.string ?? part["content"]?.string)
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    private func currentAgyCompletion(from call: TranscriptJSONValue) -> TranscriptToolCompletion {
        let status = call["status"]?.string?.lowercased()
        let isError = status.map { $0 != "success" && $0 != "ok" && $0 != "succeeded" } ?? false
        let result = call["result"]
        let output = firstString(in: call, keys: ["output", "stdout", "stderr", "message"])
            ?? currentAgyContentText(result)
            ?? result?.compactJSONString()
        return TranscriptToolCompletion(
            output: nonEmpty(output),
            isError: isError,
            exitCode: isError ? 1 : 0
        )
    }

    private func containers(from root: TranscriptJSONValue) -> [TranscriptJSONValue] {
        [
            root,
            root["message"],
            root["payload"],
            root["data"],
            root["event"],
        ].compactMap { $0 }
    }

    private func firstString(in value: TranscriptJSONValue?, keys: [String]) -> String? {
        guard let value else { return nil }
        for key in keys {
            if let string = value[key]?.string {
                return string
            }
        }
        return nil
    }

    private func firstObject(in value: TranscriptJSONValue?, keys: [String]) -> TranscriptJSONValue? {
        guard let value else { return nil }
        for key in keys {
            if value[key]?.object != nil || value[key]?.string != nil {
                return value[key]
            }
        }
        return nil
    }

    private func firstInt(in value: TranscriptJSONValue?, keys: [String]) -> Int? {
        guard let value else { return nil }
        for key in keys {
            if let int = value[key]?.int { return int }
            if let string = value[key]?.string, let int = Int(string) { return int }
        }
        return nil
    }

    private func firstDouble(in value: TranscriptJSONValue?, keys: [String]) -> Double? {
        guard let value else { return nil }
        for key in keys {
            if let double = value[key]?.double { return double }
            if let string = value[key]?.string, let double = Double(string) { return double }
        }
        return nil
    }

    private func firstBool(in value: TranscriptJSONValue?, keys: [String]) -> Bool? {
        guard let value else { return nil }
        for key in keys {
            if let bool = value[key]?.bool { return bool }
            if let string = value[key]?.string?.lowercased() {
                switch string {
                case "true", "yes", "1":
                    return true
                case "false", "no", "0":
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }

    private func permissionResolution(from value: TranscriptJSONValue) -> ChatPermissionRequest.Resolution? {
        if let approved = firstBool(in: value, keys: ["approved", "allowed", "allow"]) {
            return approved ? .approved : .denied
        }
        if let denied = firstBool(in: value, keys: ["denied", "rejected", "blocked"]) {
            return denied ? .denied : .approved
        }
        for key in ["decision", "resolution", "status", "outcome", "result"] {
            guard let raw = value[key]?.string else { continue }
            switch normalizedEventName(raw) {
            case "approve", "approved", "allow", "allowed", "accept", "accepted",
                 "grant", "granted", "ok", "success", "succeeded":
                return .approved
            case "deny", "denied", "reject", "rejected", "block", "blocked",
                 "error", "failed", "failure", "cancel", "cancelled", "canceled":
                return .denied
            default:
                continue
            }
        }
        return nil
    }

    private func lineID(_ root: TranscriptJSONValue, seq: Int) -> String {
        firstString(in: root, keys: ["uuid", "id", "messageId", "message_id", "sessionId", "conversationId"])
            ?? "line-\(seq)"
    }

    private func partLineID(_ root: TranscriptJSONValue, seq: Int, label: String, index: Int) -> String {
        "\(lineID(root, seq: seq))-\(label)-\(index)"
    }

    private func normalizedEventName(_ raw: String?) -> String {
        (raw ?? "")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func nonEmpty(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
