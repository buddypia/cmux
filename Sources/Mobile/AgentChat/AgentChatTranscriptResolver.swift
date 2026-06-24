import CMUXAgentLaunch
import CmuxAgentChat
import CryptoKit
import Foundation

/// Resolves the transcript path for an agent session.
///
/// Preference order: the hook store's recorded `transcriptPath`, then the
/// agent-specific conventional location (claude: encoded-cwd project dir;
/// codex: rollout filename containing the session id; antigravity: per-session
/// chats file, brain transcript, then matching entry in shared `history.jsonl`).
struct AgentChatTranscriptResolver: Sendable {
    private let homeDirectory: URL
    private var fileManager: FileManager { FileManager.default }
    private static let claudeTranscriptTitleReadLimit = 1_048_576
    private static let claudeTranscriptTitleChunkSize = 64 * 1024
    private static let claudeTranscriptTitleMaxLineBytes = 256 * 1024

    /// Creates a resolver.
    ///
    /// - Parameter homeDirectory: Injectable home directory for tests.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Resolves the transcript path for a session.
    ///
    /// - Parameters:
    ///   - record: The session's registry record.
    /// - Returns: An existing transcript path, or `nil` when none is found.
    func transcriptPath(for record: AgentChatSessionRecord) -> String? {
        let fileManager = FileManager.default
        if let recorded = record.transcriptPath {
            let expanded = (recorded as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return expanded
            }
        }
        switch record.agentKind {
        case .claude:
            return claudeFallbackPath(record: record)
        case .codex:
            return codexFallbackPath(sessionID: record.sessionID)
        case .antigravity:
            return antigravityFallbackPath(
                sessionID: record.sessionID,
                workingDirectory: record.workingDirectory
            )
        case .other:
            return nil
        }
    }

    /// The newest Claude transcript in a working directory's project dir,
    /// with its session id (the filename stem).
    ///
    /// Used to adopt a Claude session cmux detected by terminal title but
    /// that never ran a hook (e.g. launched through a shell wrapper that
    /// bypasses cmux's hook injection), so we never learned its session id.
    /// The newest `.jsonl` in the cwd's project dir is the live conversation.
    ///
    /// - Parameters:
    ///   - workingDirectory: The agent's working directory.
    ///   - excludingSessionIDs: Session ids already bound to another surface;
    ///     their transcripts are skipped so two hook-bypassed claudes in the
    ///     same directory each adopt a distinct conversation instead of both
    ///     resolving to the single newest file (and the second getting nothing).
    /// - Returns: The session id and absolute transcript path of the newest
    ///   unclaimed transcript, or `nil` when none is found.
    func newestClaudeTranscript(
        workingDirectory: String,
        excludingSessionIDs: Set<String> = [],
        titleHint: String? = nil
    ) -> (sessionID: String, path: String)? {
        guard !Task.isCancelled else { return nil }
        let fileManager = FileManager.default
        // The home project dir is a junk drawer of every home-rooted claude
        // conversation, so newest-by-mtime there is almost never *this*
        // terminal's session. Refuse title-detected adoption from $HOME; a
        // hooked claude in ~ still resolves by its exact session id via
        // `claudeFallbackPath`, so only the fuzzy path is blocked.
        let home = homeDirectory.resolvingSymlinksInPath().path
        // claude encodes the project dir from the cwd it sees, which is the
        // symlink-resolved path (getcwd → /private/tmp), while a panel's cwd
        // is often the unresolved form (/tmp). Try every form so a /tmp-rooted
        // terminal still finds its /private/tmp transcript dir.
        let candidates = Self.cwdCandidates(workingDirectory)
            .filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != home }
        let normalizedTitleHint = Self.normalizedClaudeTitle(titleHint)
        for cwd in candidates {
            guard !Task.isCancelled else { return nil }
            let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
            let dir = homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectDir, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var transcriptCandidates: [(url: URL, date: Date, title: String?)] = []
            for url in entries where url.pathExtension == "jsonl" {
                guard !Task.isCancelled else { return nil }
                let sessionID = url.deletingPathExtension().lastPathComponent
                guard !excludingSessionIDs.contains(sessionID) else { continue }
                transcriptCandidates.append((
                    url: url,
                    date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                    title: Self.claudeTranscriptTitle(at: url)
                ))
            }
            let newest: URL?
            if let normalizedTitleHint {
                let exactTitleCandidates = transcriptCandidates
                    .filter { Self.normalizedClaudeTitle($0.title) == normalizedTitleHint }
                let untitledCandidates = transcriptCandidates.filter { $0.title == nil }
                let newestExact = exactTitleCandidates.max { $0.date < $1.date }
                let newestUntitled = untitledCandidates.max { $0.date < $1.date }
                if let newestExact,
                   let newestUntitled,
                   newestUntitled.date > newestExact.date {
                    return nil
                }
                newest = (newestExact ?? newestUntitled)?.url
            } else {
                // A generic "Claude Code" title cannot identify one of several
                // same-cwd sessions. Avoid stealing a transcript that already
                // has a conversation title; a later title-change scan can bind
                // it to the matching terminal.
                newest = transcriptCandidates
                    .filter { $0.title == nil }
                    .max { $0.date < $1.date }?
                    .url
            }
            if let newest {
                return (sessionID: newest.deletingPathExtension().lastPathComponent, path: newest.path)
            }
        }
        return nil
    }

    /// The newest Codex rollout in a working directory.
    ///
    /// Used to adopt a Codex session detected from terminal metadata/title
    /// before a hook event has registered it. Codex rollout files carry their
    /// `cwd` in the first `session_meta` line, so this delegates to
    /// `CodexSessionResolver` rather than guessing from filenames alone.
    ///
    /// - Parameters:
    ///   - workingDirectory: The agent's working directory.
    ///   - excludingSessionIDs: Session ids already bound to another surface.
    /// - Returns: The session id and absolute rollout path of the newest
    ///   unclaimed matching rollout, or `nil` when none is found.
    func newestCodexTranscript(
        workingDirectory: String,
        excludingSessionIDs: Set<String> = []
    ) -> (sessionID: String, path: String)? {
        guard let resolved = CodexSessionResolver().inferredCodexSession(
            cwd: workingDirectory,
            env: ["HOME": homeDirectory.path],
            excludingSessionIDs: excludingSessionIDs
        ) else {
            return nil
        }
        return (sessionID: resolved.sessionId, path: resolved.transcriptPath)
    }

    /// The newest Antigravity conversation in a working directory.
    ///
    /// Antigravity can write per-session transcripts under
    /// `~/.gemini/tmp/<workspace>/chats`, `~/.gemini/tmp/<sha256(cwd)>/chats`,
    /// or the older `~/.antigravity/tmp/<sha256(cwd)>/chats`. Those carry the
    /// assistant turns and tool calls, so they win over the older shared
    /// `~/.gemini/antigravity-cli/history.jsonl` prompt history fallback.
    /// Shared history rows without cwd are intentionally ignored here: without
    /// a hook-provided id, they are ambiguous across terminals.
    ///
    /// - Parameters:
    ///   - workingDirectory: The agent's working directory.
    ///   - excludingSessionIDs: Session ids already bound to another surface.
    /// - Returns: The session id, shared history path, and best title of the
    ///   newest matching conversation, or `nil` when none is found.
    func newestAntigravityTranscript(
        workingDirectory: String,
        excludingSessionIDs: Set<String> = []
    ) -> (sessionID: String, path: String, title: String?)? {
        if let newest = newestAntigravitySessionFile(
            workingDirectory: workingDirectory,
            excludingSessionIDs: excludingSessionIDs
        ) {
            return (sessionID: newest.sessionID, path: newest.path, title: newest.title)
        }

        let history = antigravityHistoryURL()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: history.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let cwdCandidates = Set(Self.cwdCandidates(workingDirectory))
        guard !cwdCandidates.isEmpty else { return nil }
        let fallbackModified = ((try? fileManager.attributesOfItem(atPath: history.path))?[.modificationDate] as? Date)
            ?? Date.distantPast
        var latestBySessionID: [String: AntigravityHistoryMetadata] = [:]

        SessionIndexStore.forEachJSONLine(url: history, maxBytes: Int.max) { object in
            guard let sessionID = Self.antigravityHistorySessionID(in: object),
                  !excludingSessionIDs.contains(sessionID),
                  let cwd = Self.firstString(in: object, keys: Self.antigravityCWDKeys),
                  Self.cwd(cwd, matchesAny: cwdCandidates) else {
                return false
            }
            let metadata = AntigravityHistoryMetadata(
                sessionID: sessionID,
                path: history.path,
                title: Self.antigravityHistoryTitle(in: object),
                modified: Self.antigravityHistoryModifiedDate(in: object, fallback: fallbackModified)
            )
            if let existing = latestBySessionID[sessionID] {
                if metadata.modified >= existing.modified {
                    latestBySessionID[sessionID] = metadata
                }
            } else {
                latestBySessionID[sessionID] = metadata
            }
            return false
        }

        guard let newest = latestBySessionID.values.max(by: {
            if $0.modified == $1.modified {
                return $0.sessionID > $1.sessionID
            }
            return $0.modified < $1.modified
        }) else {
            return nil
        }
        return (sessionID: newest.sessionID, path: newest.path, title: newest.title)
    }

    /// Every cwd form claude might have encoded its project dir from, most
    /// specific first. `URL.resolvingSymlinksInPath()` is not enough on its
    /// own: across macOS versions it strips a leading `/private` but does NOT
    /// add one (so `/tmp` stays `/tmp` instead of becoming `/private/tmp`),
    /// yet claude's `getcwd` returns the `/private`-prefixed form. So toggle
    /// the `/private` prefix explicitly on both the raw and symlink-resolved
    /// paths, deduped in order. Existence-free, so it works before the dir is
    /// created.
    static func cwdCandidates(_ workingDirectory: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            result.append(path)
        }
        let privateRoot = "/private"
        for base in [workingDirectory, URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path] {
            add(base)
            if base.hasPrefix(privateRoot + "/") {
                add(String(base.dropFirst(privateRoot.count)))
            } else if base.hasPrefix("/") {
                add(privateRoot + base)
            }
        }
        return result
    }

    private func claudeFallbackPath(record: AgentChatSessionRecord) -> String? {
        let fileManager = FileManager.default
        guard let cwd = record.workingDirectory else { return nil }
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let path = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDir, isDirectory: true)
            .appendingPathComponent("\(record.sessionID).jsonl", isDirectory: false)
            .path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    /// Codex rollout files are named `rollout-<timestamp>-<session-uuid>.jsonl`
    /// under `~/.codex/sessions/YYYY/MM/DD/`; scan recent day directories for
    /// the session id.
    private func codexFallbackPath(sessionID: String) -> String? {
        let fileManager = FileManager.default
        let root = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = sessionID.lowercased()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if url.lastPathComponent.lowercased().contains(needle) {
                return url.path
            }
        }
        return nil
    }

    /// Antigravity prefers per-session chat files, then appData brain logs.
    /// Fall back to shared `history.jsonl` only when no richer transcript can
    /// be found.
    private func antigravityFallbackPath(sessionID: String, workingDirectory: String?) -> String? {
        if let workingDirectory,
           let file = antigravitySessionFile(sessionID: sessionID, workingDirectory: workingDirectory) {
            return file.path
        }
        if let transcript = antigravityBrainTranscript(sessionID: sessionID) {
            return transcript.path
        }
        if let messages = antigravityBrainMessagesDirectory(sessionID: sessionID) {
            return messages.path
        }

        let history = antigravityHistoryURL()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: history.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              antigravityHistoryContainsSessionID(history, sessionID: sessionID) else {
            return nil
        }
        return history.path
    }

    private func newestAntigravitySessionFile(
        workingDirectory: String,
        excludingSessionIDs: Set<String>
    ) -> AntigravitySessionFileMetadata? {
        antigravitySessionFileCandidates(workingDirectory: workingDirectory)
            .filter { candidate in
                !excludingSessionIDs.contains(candidate.sessionID)
                    && !excludingSessionIDs.contains(candidate.fileStem)
            }
            .max { lhs, rhs in
                if lhs.modified == rhs.modified {
                    return lhs.sessionID > rhs.sessionID
                }
                return lhs.modified < rhs.modified
            }
    }

    private func antigravitySessionFile(
        sessionID: String,
        workingDirectory: String
    ) -> AntigravitySessionFileMetadata? {
        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return antigravitySessionFileCandidates(workingDirectory: workingDirectory)
            .filter { $0.sessionID == target || $0.fileStem == target }
            .max { lhs, rhs in
                if lhs.modified == rhs.modified {
                    return lhs.path > rhs.path
                }
                return lhs.modified < rhs.modified
            }
    }

    private func antigravitySessionFileCandidates(workingDirectory: String) -> [AntigravitySessionFileMetadata] {
        var result: [AntigravitySessionFileMetadata] = []
        var seenPaths = Set<String>()
        for dir in antigravityChatDirectories(workingDirectory: workingDirectory) {
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard seenPaths.insert(url.path).inserted,
                      Self.isAntigravitySessionTranscript(url),
                      ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) else {
                    continue
                }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date.distantPast
                let stem = url.deletingPathExtension().lastPathComponent
                let sessionID = Self.antigravitySessionFileSessionID(at: url) ?? stem
                result.append(
                    AntigravitySessionFileMetadata(
                        sessionID: sessionID,
                        fileStem: stem,
                        path: url.path,
                        title: Self.antigravitySessionFileTitle(at: url),
                        modified: modified
                    )
                )
            }
        }
        return result
    }

    private func antigravityChatDirectories(workingDirectory: String) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            result.append(url)
        }

        for cwd in Self.cwdCandidates(workingDirectory) {
            let hash = Self.sha256Hex(cwd)
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            let currentProjectDir = basename.isEmpty ? hash : basename
            add(
                homeDirectory
                    .appendingPathComponent(".gemini", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(currentProjectDir, isDirectory: true)
                    .appendingPathComponent("chats", isDirectory: true)
            )
            add(
                homeDirectory
                    .appendingPathComponent(".gemini", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(hash, isDirectory: true)
                    .appendingPathComponent("chats", isDirectory: true)
            )
            add(
                homeDirectory
                    .appendingPathComponent(".antigravity", isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(hash, isDirectory: true)
                    .appendingPathComponent("chats", isDirectory: true)
            )
        }
        return result
    }

    private func antigravityHistoryURL() -> URL {
        homeDirectory
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("history.jsonl", isDirectory: false)
    }

    private func antigravityBrainTranscript(sessionID: String) -> URL? {
        guard let sessionDirectory = antigravityBrainSessionDirectory(sessionID: sessionID) else {
            return nil
        }
        let logs = sessionDirectory
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        for filename in ["transcript.jsonl", "transcript_full.jsonl"] {
            let candidate = logs.appendingPathComponent(filename, isDirectory: false)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private func antigravityBrainMessagesDirectory(sessionID: String) -> URL? {
        guard let sessionDirectory = antigravityBrainSessionDirectory(sessionID: sessionID) else {
            return nil
        }
        let messages = sessionDirectory
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: messages.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return messages
    }

    private func antigravityBrainSessionDirectory(sessionID: String) -> URL? {
        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let components = target.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        var directory = homeDirectory
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
        for component in components {
            directory = directory.appendingPathComponent(component, isDirectory: true)
        }
        return directory
    }

    private func antigravityHistoryContainsSessionID(_ url: URL, sessionID: String) -> Bool {
        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        var found = false
        SessionIndexStore.forEachJSONLine(url: url, maxBytes: Int.max) { object in
            guard Self.antigravityHistorySessionID(in: object) == target else {
                return false
            }
            found = true
            return true
        }
        return found
    }

    private static func antigravityHistorySessionID(in object: [String: Any]) -> String? {
        firstString(in: object, keys: antigravitySessionIDKeys)
    }

    private static let antigravitySessionIDKeys = [
        "conversationId", "conversation_id", "sessionId", "session_id", "id",
    ]

    private static let antigravityCWDKeys = [
        "cwd", "workingDirectory", "workspacePath", "workspace", "projectPath", "directory",
    ]

    private struct AntigravityHistoryMetadata {
        let sessionID: String
        let path: String
        let title: String?
        let modified: Date
    }

    private struct AntigravitySessionFileMetadata {
        let sessionID: String
        let fileStem: String
        let path: String
        let title: String?
        let modified: Date
    }

    private static func isAntigravitySessionTranscript(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("__pending__") else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "json" || ext == "jsonl"
    }

    private static func antigravitySessionFileSessionID(at url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "json":
            return jsonObject(at: url).flatMap { firstString(in: $0, keys: antigravitySessionIDKeys) }
        case "jsonl":
            var found: String?
            SessionIndexStore.forEachJSONLine(url: url, maxBytes: 512 * 1024) { object in
                guard let sessionID = antigravityHistorySessionID(in: object) else {
                    return false
                }
                found = sessionID
                return true
            }
            return found
        default:
            return nil
        }
    }

    private static func antigravitySessionFileTitle(at url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "json":
            guard let object = jsonObject(at: url) else { return nil }
            if let messages = object["messages"] as? [Any] {
                for case let message as [String: Any] in messages
                    where message["type"] as? String == "user"
                        || message["type"] as? String == "USER_INPUT"
                        || message["role"] as? String == "user" {
                    if let title = firstText(in: message, keys: ["content", "display", "prompt", "parts"]) {
                        return title
                    }
                }
            }
            return firstText(in: object, keys: ["summary", "title"])
        case "jsonl":
            var title: String?
            SessionIndexStore.forEachJSONLine(url: url, maxBytes: 512 * 1024) { object in
                guard object["type"] as? String == "user"
                    || object["type"] as? String == "USER_INPUT"
                    || object["role"] as? String == "user" else {
                    return false
                }
                title = firstText(in: object, keys: ["content", "display", "prompt", "parts"])
                return title != nil
            }
            return title
        default:
            return nil
        }
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func antigravityHistoryTitle(in object: [String: Any]) -> String? {
        firstText(in: object, keys: ["title", "prompt", "display"])
            ?? firstTopLevelTitle(in: object)
    }

    private static func firstText(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let text = textValue(value) {
                return text
            }
        }
        return nil
    }

    private static func firstTopLevelTitle(in object: [String: Any]) -> String? {
        if let title = firstText(in: object, keys: ["title", "prompt"]) {
            return title
        }
        if let message = object["message"] as? [String: Any] {
            return firstText(in: message, keys: ["text", "content"])
        }
        return firstText(in: object, keys: ["text", "content"])
    }

    private static func textValue(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = value as? [Any] {
            let fragments = array.compactMap { textValue($0) }
            return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
        }
        if let object = value as? [String: Any] {
            for key in ["text", "content", "message"] {
                guard let nested = object[key],
                      let text = textValue(nested) else {
                    continue
                }
                return text
            }
        }
        return nil
    }

    private static func antigravityHistoryModifiedDate(in object: [String: Any], fallback: Date) -> Date {
        guard let timestamp = antigravityTimestamp(object["timestamp"]) else {
            return fallback
        }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func antigravityTimestamp(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func cwd(_ cwd: String, matchesAny candidates: Set<String>) -> Bool {
        !candidates.isDisjoint(with: Set(cwdCandidates(cwd)))
    }

    private static func normalizedClaudeTitle(_ title: String?) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        while let first = title.first, !first.isLetter && !first.isNumber {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalized = title.lowercased()
        guard !normalized.isEmpty,
              normalized != "claude code",
              !normalized.hasPrefix("claude ·") else {
            return nil
        }
        return normalized
    }

    private static func claudeTranscriptTitle(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var buffered = Data()
        var bytesRead = 0
        var droppingOversizedLine = false
        while bytesRead < claudeTranscriptTitleReadLimit {
            guard !Task.isCancelled else { return nil }
            let readSize = min(claudeTranscriptTitleChunkSize, claudeTranscriptTitleReadLimit - bytesRead)
            guard let chunk = try? handle.read(upToCount: readSize),
                  !chunk.isEmpty else {
                break
            }
            bytesRead += chunk.count
            buffered.append(chunk)

            while let newlineIndex = buffered.firstIndex(of: 0x0A) {
                let lineData = Data(buffered[..<newlineIndex])
                buffered.removeSubrange(...newlineIndex)
                if droppingOversizedLine {
                    droppingOversizedLine = false
                    continue
                }
                if let title = claudeTranscriptTitle(in: lineData) {
                    return title
                }
            }

            if buffered.count > claudeTranscriptTitleMaxLineBytes {
                buffered.removeAll(keepingCapacity: true)
                droppingOversizedLine = true
            }
        }
        guard !droppingOversizedLine else {
            return nil
        }
        return claudeTranscriptTitle(in: buffered)
    }

    private static func claudeTranscriptTitle(in lineData: Data) -> String? {
        guard lineData.range(of: Data(#""ai-title""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              object["type"] as? String == "ai-title" else {
            return nil
        }
        return object["aiTitle"] as? String
    }
}
