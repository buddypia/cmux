import Foundation

/// Canonical event kinds supported across CLI runtime adapters.
public enum CanonicalEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case sessionMeta = "session_meta"
    case userPrompt = "user_prompt"
    case turnStart = "turn_start"
    case text = "text"
    case thinking = "thinking"
    case toolStart = "tool_start"
    case toolEnd = "tool_end"
    case toolProgress = "tool_progress"
    case turnEnd = "turn_end"
    case sessionClear = "session_clear"
    case permissionRequired = "permission_required"
    case error = "error"
    case unknown = "unknown"
}

/// Runtime-neutral event model consumed by ``AgentFSM`` and Agent Studio UI.
public struct CanonicalEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        if let toolCallId = toolCallId, !toolCallId.isEmpty {
            return toolCallId
        }
        return "\(sessionId)_\(ts)"
    }
    /// The event variant identifier.
    public var kind: CanonicalEventKind
    /// Epoch timestamp in milliseconds.
    public var ts: Double
    /// CLI-native or Agent Studio session identifier.
    public var sessionId: String
    /// Unique tool invocation identifier if applicable.
    public var toolCallId: String?
    /// Name of the invoked tool (e.g. "view_file", "replace_file_content", "run_command").
    public var toolName: String?
    /// Text content for prompts, text stream, thinking, or errors.
    public var text: String?
    /// Role for text events ("user" or "assistant").
    public var role: String?
    /// Tool execution status ("ok", "error", "cancelled").
    public var status: String?
    /// Whether the tool is exempt from permission watch stalls.
    public var permissionExempt: Bool?
    /// Whether the tool runs asynchronously in background.
    public var runsAsync: Bool?
    /// Original unmapped raw type string if kind is `.unknown`.
    public var rawType: String?
    /// Tool parameter key-value dictionary.
    public var parameters: [String: String]?

    /// Human-readable summary of the event text or tool name.
    public var summary: String? {
        if let text = text, !text.isEmpty {
            return text
        }
        if let toolName = toolName, !toolName.isEmpty {
            return toolName
        }
        return nil
    }

    public init(
        id: String? = nil,
        kind: CanonicalEventKind,
        ts: Double = Date().timeIntervalSince1970 * 1000.0,
        sessionId: String = "",
        toolCallId: String? = nil,
        toolName: String? = nil,
        text: String? = nil,
        role: String? = nil,
        status: String? = nil,
        permissionExempt: Bool? = nil,
        runsAsync: Bool? = nil,
        rawType: String? = nil,
        parameters: [String: String]? = nil
    ) {
        self.kind = kind
        self.ts = ts
        self.sessionId = sessionId
        self.toolCallId = id ?? toolCallId
        self.toolName = toolName
        self.text = text
        self.role = role
        self.status = status
        self.permissionExempt = permissionExempt
        self.runsAsync = runsAsync
        self.rawType = rawType
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case ts
        case sessionId
        case toolCallId
        case toolName
        case text
        case role
        case status
        case permissionExempt
        case runsAsync
        case rawType
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = (try? container.decode(CanonicalEventKind.self, forKey: .kind)) ?? .unknown
        self.ts = (try? container.decode(Double.self, forKey: .ts)) ?? (Date().timeIntervalSince1970 * 1000.0)
        self.sessionId = (try? container.decode(String.self, forKey: .sessionId)) ?? ""
        self.toolCallId = try? container.decode(String.self, forKey: .toolCallId)
        self.toolName = try? container.decode(String.self, forKey: .toolName)
        self.text = try? container.decode(String.self, forKey: .text)
        self.role = try? container.decode(String.self, forKey: .role)
        self.status = try? container.decode(String.self, forKey: .status)
        self.permissionExempt = try? container.decode(Bool.self, forKey: .permissionExempt)
        self.runsAsync = try? container.decode(Bool.self, forKey: .runsAsync)
        self.rawType = try? container.decode(String.self, forKey: .rawType)
        self.parameters = try? container.decode([String: String].self, forKey: .parameters)
    }

    /// Parse a JSONL transcript line string into a ``CanonicalEvent``.
    ///
    /// Supports canonical event schemas as well as raw CLI JSON line payloads (Claude, Codex, Antigravity).
    public static func parseLine(_ jsonString: String) -> CanonicalEvent? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        // 1. Attempt standard CanonicalEvent decoding first
        if let canonical = try? JSONDecoder().decode(CanonicalEvent.self, from: data), canonical.kind != .unknown {
            return canonical
        }

        // 2. Parse dynamic JSON object to adapt CLI native formats
        guard let jsonObject = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        return parseJSONObject(jsonObject)
    }

    /// Helper to convert a generic JSON object into a CanonicalEvent.
    public static func parseJSONObject(_ obj: [String: Any]) -> CanonicalEvent? {
        let now = Date().timeIntervalSince1970 * 1000.0
        let ts = (obj["ts"] as? Double) ?? (obj["timestamp"] as? Double) ?? now
        let sessionId = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String) ?? ""

        // Check if explicitly passed 'kind'
        if let kindStr = obj["kind"] as? String, let kind = CanonicalEventKind(rawValue: kindStr) {
            let toolCallId = obj["toolCallId"] as? String ?? obj["tool_call_id"] as? String
            let toolName = obj["toolName"] as? String ?? obj["tool_name"] as? String
            let text = obj["text"] as? String
            let role = obj["role"] as? String
            let status = obj["status"] as? String
            let permissionExempt = obj["permissionExempt"] as? Bool ?? obj["permission_exempt"] as? Bool
            let runsAsync = obj["runsAsync"] as? Bool ?? obj["runs_async"] as? Bool
            let parameters = obj["parameters"] as? [String: String]

            return CanonicalEvent(
                kind: kind,
                ts: ts,
                sessionId: sessionId,
                toolCallId: toolCallId,
                toolName: toolName,
                text: text,
                role: role,
                status: status,
                permissionExempt: permissionExempt,
                runsAsync: runsAsync,
                parameters: parameters
            )
        }

        // Check native CLI 'type' tag
        if let typeStr = obj["type"] as? String {
            switch typeStr {
            case "user_prompt", "user", "user_message":
                let text = (obj["text"] as? String) ?? extractTextContent(obj["content"] ?? obj["message"])
                return CanonicalEvent(kind: .userPrompt, ts: ts, sessionId: sessionId, text: text, role: "user")

            case "thinking", "reasoning":
                let text = (obj["text"] as? String) ?? (obj["thinking"] as? String)
                return CanonicalEvent(kind: .thinking, ts: ts, sessionId: sessionId, text: text)

            case "tool_start", "tool_use", "call", "function_call":
                let toolCallId = (obj["toolCallId"] as? String) ?? (obj["tool_call_id"] as? String) ?? (obj["id"] as? String)
                let toolName = (obj["toolName"] as? String) ?? (obj["tool_name"] as? String) ?? (obj["name"] as? String)
                let parameters = extractParameters(obj["parameters"] ?? obj["input"] ?? obj["arguments"])
                return CanonicalEvent(
                    kind: .toolStart,
                    ts: ts,
                    sessionId: sessionId,
                    toolCallId: toolCallId,
                    toolName: toolName,
                    parameters: parameters
                )

            case "tool_end", "tool_result", "function_call_output":
                let toolCallId = (obj["toolCallId"] as? String) ?? (obj["tool_call_id"] as? String) ?? (obj["id"] as? String)
                let status = (obj["status"] as? String) ?? ((obj["is_error"] as? Bool == true) ? "error" : "ok")
                return CanonicalEvent(
                    kind: .toolEnd,
                    ts: ts,
                    sessionId: sessionId,
                    toolCallId: toolCallId,
                    status: status
                )

            case "permission_required", "exec_approval_request", "approval_request":
                let toolName = (obj["toolName"] as? String) ?? (obj["tool_name"] as? String)
                let toolCallId = (obj["toolCallId"] as? String) ?? (obj["tool_call_id"] as? String)
                return CanonicalEvent(
                    kind: .permissionRequired,
                    ts: ts,
                    sessionId: sessionId,
                    toolCallId: toolCallId,
                    toolName: toolName
                )

            case "turn_end", "done", "result", "stop":
                return CanonicalEvent(kind: .turnEnd, ts: ts, sessionId: sessionId)

            case "error", "exception":
                let text = (obj["text"] as? String) ?? (obj["message"] as? String) ?? (obj["error"] as? String)
                return CanonicalEvent(kind: .error, ts: ts, sessionId: sessionId, text: text)

            case "session_clear", "clear":
                return CanonicalEvent(kind: .sessionClear, ts: ts, sessionId: sessionId)

            case "assistant", "assistant_message":
                let text = (obj["text"] as? String) ?? extractTextContent(obj["content"] ?? obj["message"])
                return CanonicalEvent(kind: .text, ts: ts, sessionId: sessionId, text: text, role: "assistant")

            default:
                return CanonicalEvent(kind: .unknown, ts: ts, sessionId: sessionId, rawType: typeStr)
            }
        }

        return nil
    }

    private static func extractTextContent(_ value: Any?) -> String? {
        if let str = value as? String { return str }
        if let dict = value as? [String: Any], let text = dict["text"] as? String { return text }
        if let arr = value as? [[String: Any]] {
            for item in arr {
                if let text = item["text"] as? String { return text }
            }
        }
        return nil
    }

    private static func extractParameters(_ value: Any?) -> [String: String]? {
        if let dict = value as? [String: String] { return dict }
        if let str = value as? String,
           let data = str.data(using: .utf8),
           let jsonObj = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = jsonObj as? [String: Any] {
            return extractParameters(dict)
        }
        if let dict = value as? [String: Any] {
            var result: [String: String] = [:]
            for (k, v) in dict {
                if let str = v as? String {
                    result[k] = str
                } else if let data = try? JSONSerialization.data(withJSONObject: v),
                          let jsonStr = String(data: data, encoding: .utf8) {
                    result[k] = jsonStr
                } else {
                    result[k] = String(describing: v)
                }
            }
            return result
        }
        return nil
    }
}
