import CmuxAgentChat
import CryptoKit
import Foundation

/// Resolves the transcript path for an agent session.
///
/// Preference order: the hook store's recorded `transcriptPath`, then the
/// agent-specific conventional location (claude: encoded-cwd project dir;
/// codex: rollout filename containing the session id).
struct AgentChatTranscriptResolver {
    private let homeDirectory: URL
    private let fileManager: FileManager

    /// Creates a resolver.
    ///
    /// - Parameter homeDirectory: Injectable home directory for tests.
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        self.fileManager = FileManager.default
    }

    /// Resolves the transcript path for a session.
    ///
    /// - Parameters:
    ///   - record: The session's registry record.
    /// - Returns: An existing transcript path, or `nil` when none is found.
    func transcriptPath(for record: AgentChatSessionRecord) -> String? {
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
            return antigravityFallbackPath(record: record)
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
            let transcriptCandidates = entries
                .filter {
                    $0.pathExtension == "jsonl"
                        && !excludingSessionIDs.contains($0.deletingPathExtension().lastPathComponent)
                }
                .map { url in
                    (
                        url: url,
                        date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                        title: Self.claudeTranscriptTitle(at: url)
                    )
                }
            let newest: URL?
            if let normalizedTitleHint {
                newest = transcriptCandidates
                    .filter { Self.normalizedClaudeTitle($0.title) == normalizedTitleHint || $0.title == nil }
                    .max { $0.date < $1.date }?
                    .url
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

    /// Antigravity's current `agy` JSONL/JSON files live under
    /// `~/.gemini/tmp/<workspace-name>/chats/`, while older builds used a
    /// hash bucket under `~/.antigravity/tmp/<sha256(cwd)>/chats/`. Restrict
    /// fallback discovery to those cwd-derived directories so a stale session
    /// id cannot accidentally bind to an unrelated Antigravity transcript.
    private func antigravityFallbackPath(record: AgentChatSessionRecord) -> String? {
        guard let cwd = record.workingDirectory,
              !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let sessionID = record.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return nil }

        var matches: [(url: URL, date: Date)] = []
        for dir in antigravityCandidateChatDirs(workingDirectory: cwd) {
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard isAntigravityTranscriptFile(url),
                      antigravityTranscript(url, matchesSessionID: sessionID) else {
                    continue
                }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                matches.append((url, date))
            }
        }
        return matches.max { $0.date < $1.date }?.url.path
    }

    private func antigravityCandidateChatDirs(workingDirectory: String) -> [URL] {
        var bucketNames: [String] = []
        var seenBuckets = Set<String>()
        func addBucket(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenBuckets.insert(trimmed).inserted else { return }
            bucketNames.append(trimmed)
        }

        for cwd in Self.cwdCandidates(workingDirectory) {
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            addBucket(basename)
            addBucket(Self.sha256Hex(cwd))
        }

        var result: [URL] = []
        var seenPaths = Set<String>()
        for rootName in [".gemini", ".antigravity"] {
            for bucket in bucketNames {
                let dir = homeDirectory
                    .appendingPathComponent(rootName, isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(bucket, isDirectory: true)
                    .appendingPathComponent("chats", isDirectory: true)
                guard seenPaths.insert(dir.path).inserted else { continue }
                result.append(dir)
            }
        }
        return result
    }

    private func isAntigravityTranscriptFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return (url.pathExtension == "json" || url.pathExtension == "jsonl") && !name.hasPrefix("__pending__")
    }

    private func antigravityTranscript(_ url: URL, matchesSessionID sessionID: String) -> Bool {
        let needle = sessionID.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if stem == needle || stem.contains(needle) {
            return true
        }
        return antigravitySessionID(inTranscript: url)?.lowercased() == needle
    }

    private func antigravitySessionID(inTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        if url.pathExtension == "json", let id = Self.sessionIDField(in: text) {
            return id
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let id = Self.sessionIDField(in: String(line)) {
                return id
            }
        }
        return nil
    }

    private static func sessionIDField(in text: String) -> String? {
        for key in [#""sessionId""#, #""session_id""#] {
            guard let keyRange = text.range(of: key) else { continue }
            let afterKey = text[keyRange.upperBound...]
            guard let colon = afterKey.firstIndex(of: ":") else { continue }
            var cursor = afterKey.index(after: colon)
            while cursor < afterKey.endIndex, afterKey[cursor].isWhitespace {
                cursor = afterKey.index(after: cursor)
            }
            guard cursor < afterKey.endIndex, afterKey[cursor] == "\"" else { continue }
            cursor = afterKey.index(after: cursor)
            let valueStart = cursor
            var escaped = false
            while cursor < afterKey.endIndex {
                let character = afterKey[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return String(afterKey[valueStart..<cursor])
                }
                cursor = afterKey.index(after: cursor)
            }
        }
        return nil
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for line in contents.split(separator: "\n") where line.contains(#""ai-title""#) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "ai-title" else {
                continue
            }
            return object["aiTitle"] as? String
        }
        return nil
    }
}
