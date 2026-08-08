import Foundation

/// What a permission request is asking to do, normalized across agents.
///
/// Every agent names its tools differently (Claude's `Bash`, Codex's `shell`,
/// Cursor's `run_terminal_cmd`), so guardrails classify by behavior rather than
/// by brand. Anything unrecognized lands in ``unknown``, which routes to the
/// judge rather than to a fast path — an agent cmux has never seen must never
/// inherit the read-only exemption by accident.
public enum PilotModeToolClass: String, Sendable, Equatable, Codable {
    /// Observes the workspace without changing it and without leaving the
    /// machine.
    case readOnly
    /// Runs an arbitrary shell command; the command string decides everything.
    case shell
    /// Writes to a path in the workspace.
    case write
    /// Leaves the machine: fetches a URL, searches the web, drives a browser.
    case network
    /// Not recognized.
    case unknown
}

/// Maps agent-specific tool names onto ``PilotModeToolClass``.
/// lint:allow namespace-type — stateless lookup table with no instance state.
public enum PilotModeToolClassification {
    /// Normalizes `Read`, `read_file`, and `read-file` onto one spelling so a
    /// single table covers every agent's casing convention.
    public static func normalize(toolName: String) -> String {
        toolName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let readOnlyTools: Set<String> = [
        "read", "readfile", "view", "viewfile", "cat",
        "glob", "globfile", "find", "findfiles", "filesearch",
        "grep", "greptool", "ripgrep", "searchtext", "codebasesearch",
        "ls", "listdir", "listdirectory", "listfiles",
        "notebookread", "readnotebook",
        "todowrite", "todoread", "updateplan", "planwrite",
        "outline", "symbols", "definition", "references",
    ]

    private static let shellTools: Set<String> = [
        "bash", "shell", "sh", "zsh", "terminal", "console",
        "exec", "execute", "executecommand", "executebash",
        "runcommand", "runterminalcmd", "runshellcommand", "runinterminal",
        "localshell", "containerexec", "processexec",
    ]

    private static let writeTools: Set<String> = [
        "write", "writefile", "createfile", "create",
        "edit", "editfile", "multiedit", "strreplace", "strreplaceeditor",
        "applypatch", "patch", "applydiff", "searchreplace",
        "notebookedit", "editnotebook",
        "delete", "deletefile", "remove", "removefile", "move", "rename", "copyfile",
    ]

    private static let networkTools: Set<String> = [
        "webfetch", "websearch", "fetch", "fetchurl", "urlfetch",
        "browser", "browse", "navigate", "playwright", "puppeteer",
        "httprequest", "request", "curl", "download",
    ]

    public static func classify(toolName: String) -> PilotModeToolClass {
        let key = normalize(toolName: toolName)
        guard !key.isEmpty else { return .unknown }
        if readOnlyTools.contains(key) { return .readOnly }
        if shellTools.contains(key) { return .shell }
        if writeTools.contains(key) { return .write }
        if networkTools.contains(key) { return .network }
        // MCP tools arrive as `mcp__server__tool`; the server half is
        // arbitrary, so they stay unknown and go to the judge.
        return .unknown
    }
}
