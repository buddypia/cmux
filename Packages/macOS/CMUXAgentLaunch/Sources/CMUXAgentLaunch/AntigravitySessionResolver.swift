import Foundation

/// Resolves an Antigravity session ID from disk for a live, option-less `agy` process
/// given only its working directory and environment.
///
/// Antigravity CLI writes session metadata to:
///   1. `$HOME/.gemini/antigravity-cli/cache/last_conversations.json`
///      (A JSON dictionary mapping normalized CWD path -> conversationId UUID string).
///   2. `$HOME/.gemini/antigravity-cli/history.jsonl`
///      (JSONL records carrying `"workspace"` and `"conversationId"`).
///
/// Used by live-process detection (`VaultAgentProcessScanner`) so an `agy`/`antigravity`
/// process that was launched interactively without `--conversation <id>` can still be
/// restored when the process terminates unexpectedly.
public struct AntigravitySessionResolver {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the conversation ID of the newest Antigravity session matching `cwd`,
    /// or `nil` if `cwd` is missing or no session matches.
    public func inferredAntigravitySessionId(cwd: String?, env: [String: String]) -> String? {
        inferredAntigravitySession(cwd: cwd, env: env)?.sessionId
    }

    /// Returns the Antigravity conversation ID matching `cwd`, excluding any IDs
    /// in `excludingSessionIDs` to prevent duplicate surface bindings.
    public func inferredAntigravitySession(
        cwd: String?,
        env: [String: String],
        excludingSessionIDs: Set<String> = []
    ) -> (sessionId: String, source: String)? {
        guard let normalizedCwd = RovoDevIndex.normalizedPath(cwd), !normalizedCwd.isEmpty else {
            return nil
        }

        // 1. Check last_conversations.json
        if let lastSessionId = checkLastConversations(normalizedCwd: normalizedCwd, env: env),
           !excludingSessionIDs.contains(lastSessionId) {
            return (sessionId: lastSessionId, source: "last_conversations.json")
        }

        // 2. Check history.jsonl (newest first by scanning backwards)
        if let historySessionId = checkHistoryJsonl(normalizedCwd: normalizedCwd, env: env, excludingSessionIDs: excludingSessionIDs) {
            return (sessionId: historySessionId, source: "history.jsonl")
        }

        return nil
    }

    /// Root directory for Antigravity state.
    public func antigravityRoot(env: [String: String]) -> String {
        let home = normalizedValue(env["HOME"]) ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".gemini/antigravity-cli")
    }

    private func checkLastConversations(normalizedCwd: String, env: [String: String]) -> String? {
        let path = (antigravityRoot(env: env) as NSString).appendingPathComponent("cache/last_conversations.json")
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        for (workspaceKey, value) in json {
            guard let sessionId = value as? String, !sessionId.isEmpty else { continue }
            if let normKey = RovoDevIndex.normalizedPath(workspaceKey), normKey == normalizedCwd {
                return sessionId
            }
        }
        return nil
    }

    private func checkHistoryJsonl(
        normalizedCwd: String,
        env: [String: String],
        excludingSessionIDs: Set<String>
    ) -> String? {
        let path = (antigravityRoot(env: env) as NSString).appendingPathComponent("history.jsonl")
        guard fileManager.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        // Read the tail (up to 128KB) to scan recent conversations
        let fileSize = (try? fileManager.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let readLength = Int(min(fileSize, 128 * 1024))
        guard readLength > 0 else { return nil }

        let offset = UInt64(fileSize) - UInt64(readLength)
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        let data = handle.readData(ofLength: readLength)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: .newlines).reversed()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let conversationId = json["conversationId"] as? String,
                  !conversationId.isEmpty,
                  !excludingSessionIDs.contains(conversationId),
                  let workspace = json["workspace"] as? String,
                  let normWorkspace = RovoDevIndex.normalizedPath(workspace),
                  normWorkspace == normalizedCwd else {
                continue
            }
            return conversationId
        }
        return nil
    }

    private func normalizedValue(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
