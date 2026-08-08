import Foundation

/// The few fields Pilot Mode needs out of an agent's `tool_input` blob.
///
/// Tool inputs are agent-defined and unbounded, so this deliberately reads only
/// the keys that drive a safety decision and keeps a truncated rendering of the
/// rest for the judge prompt.
public struct PilotModeToolInput: Sendable, Equatable {
    /// Shell command, when the tool runs one.
    public let command: String?
    /// Target path, when the tool reads or writes one.
    public let path: String?
    /// Target URL, when the tool leaves the machine.
    public let url: String?
    /// Human-readable rendering of the whole input, truncated for the prompt.
    public let summary: String

    public init(command: String?, path: String?, url: String?, summary: String) {
        self.command = command
        self.path = path
        self.url = url
        self.summary = summary
    }

    private static let commandKeys = [
        "command", "cmd", "shell_command", "shellCommand", "script",
        "command_line", "commandLine", "input", "code",
    ]
    private static let pathKeys = [
        "file_path", "filePath", "path", "file", "filename", "fileName",
        "target_file", "targetFile", "notebook_path", "notebookPath",
        "absolute_path", "absolutePath", "directory", "dir_path",
    ]
    private static let urlKeys = ["url", "uri", "link", "href", "endpoint"]

    /// Parses `toolInputJSON`, tolerating malformed or non-object payloads: an
    /// unreadable input yields no extracted fields, which routes the request to
    /// the judge rather than to a fast path.
    public static func parse(toolInputJSON: String, summaryLimit: Int = 2000) -> PilotModeToolInput {
        let trimmed = toolInputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = truncate(trimmed, limit: summaryLimit)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return PilotModeToolInput(command: nil, path: nil, url: nil, summary: summary)
        }
        return PilotModeToolInput(
            command: firstString(in: dictionary, keys: commandKeys),
            path: firstString(in: dictionary, keys: pathKeys),
            url: firstString(in: dictionary, keys: urlKeys),
            summary: summary
        )
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            // Some agents pass argv arrays instead of a command string.
            if let array = value as? [String] {
                let joined = array.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            }
        }
        return nil
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…[truncated]"
    }
}
