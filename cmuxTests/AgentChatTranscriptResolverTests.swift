import CryptoKit
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Unit tests for the title-detected adoption transcript resolver. These cover
/// the subtle, silently-regressing cases that confounded earlier debugging:
/// the cwd-collision disambiguation (excludingSessionIDs) and the $HOME
/// junk-drawer guard. The resolver takes an injectable home directory, so the
/// whole thing runs against a temp filesystem with no app launch.
@Suite struct AgentChatTranscriptResolverTests {
    /// Creates a temp home with a claude project dir for `cwd`, writes the
    /// given session-id `.jsonl` files in ascending mtime order, and returns
    /// the resolver bound to that home plus the cwd used.
    private static func fixture(
        sessionsOldestFirst: [String],
        cwdName: String = "proj"
    ) throws -> (resolver: AgentChatTranscriptResolver, home: URL, cwd: String) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent(cwdName, isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let projectDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // Stamp ascending modification dates so "newest" is deterministic
        // without relying on write-order timing.
        for (index, sessionID) in sessionsOldestFirst.enumerated() {
            let file = projectDir.appendingPathComponent("\(sessionID).jsonl")
            try Data("{}\n".utf8).write(to: file)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: file.path
            )
        }
        return (AgentChatTranscriptResolver(homeDirectory: home), home, cwd.path)
    }

    @Test("returns the newest transcript when nothing is claimed")
    func newestUnclaimed() throws {
        let (resolver, _, cwd) = try Self.fixture(sessionsOldestFirst: ["older", "newer"])
        let result = resolver.newestClaudeTranscript(workingDirectory: cwd)
        #expect(result?.sessionID == "newer")
    }

    @Test("skips a claimed session so a same-dir second agent gets a distinct transcript")
    func excludesClaimedSession() throws {
        let (resolver, _, cwd) = try Self.fixture(sessionsOldestFirst: ["older", "newer"])
        // The first surface already adopted "newer"; the second must resolve
        // to "older" rather than colliding on the same file (or getting nil).
        let result = resolver.newestClaudeTranscript(
            workingDirectory: cwd,
            excludingSessionIDs: ["newer"]
        )
        #expect(result?.sessionID == "older")
    }

    @Test("returns nil when every transcript is already claimed")
    func allClaimedYieldsNil() throws {
        let (resolver, _, cwd) = try Self.fixture(sessionsOldestFirst: ["a", "b"])
        let result = resolver.newestClaudeTranscript(
            workingDirectory: cwd,
            excludingSessionIDs: ["a", "b"]
        )
        #expect(result == nil)
    }

    @Test("refuses to adopt from the home directory junk drawer")
    func homeDirectoryIsGuarded() throws {
        // A claude rooted directly at $HOME would match the home project dir,
        // which accumulates every home-rooted conversation; newest-by-mtime is
        // almost never this terminal's session, so the resolver returns nil.
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-home-\(UUID().uuidString)", isDirectory: true)
        let projectDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(home.path),
                isDirectory: true
            )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: projectDir.appendingPathComponent("home-sess.jsonl"))

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        #expect(resolver.newestClaudeTranscript(workingDirectory: home.path) == nil)
    }

    @Test("/private-toggled cwd resolves a /private-encoded project dir")
    func privatePrefixToggle() throws {
        // Simulate claude encoding the /private form while the panel cwd is the
        // bare form: create the project dir under the /private-prefixed path and
        // resolve from the non-prefixed one.
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-priv-\(UUID().uuidString)", isDirectory: true)
        let bareCwd = "/tmp/agentchat-resolver-\(UUID().uuidString)"
        let projectDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir("/private" + bareCwd),
                isDirectory: true
            )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: projectDir.appendingPathComponent("priv-sess.jsonl"))

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        #expect(resolver.newestClaudeTranscript(workingDirectory: bareCwd)?.sessionID == "priv-sess")
    }

    @Test("newestCodexTranscript resolves the newest cwd-matching rollout")
    func newestCodexTranscriptMatchesCWD() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-codex-newest-\(UUID().uuidString)", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let cwd = home.appendingPathComponent("repo", isDirectory: true)
        let otherCwd = home.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherCwd, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try writeCodexRollout(
            codexHome: codexHome,
            shard: "2026/06/18",
            sessionID: "older",
            cwd: cwd.path,
            modified: Date(timeIntervalSince1970: 100)
        )
        try writeCodexRollout(
            codexHome: codexHome,
            shard: "2026/06/19",
            sessionID: "newer",
            cwd: cwd.path,
            modified: Date(timeIntervalSince1970: 300)
        )
        try writeCodexRollout(
            codexHome: codexHome,
            shard: "2026/06/19",
            sessionID: "elsewhere",
            cwd: otherCwd.path,
            modified: Date(timeIntervalSince1970: 500)
        )

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let result = resolver.newestCodexTranscript(workingDirectory: cwd.path)

        #expect(result?.sessionID == "newer")
        #expect(result?.path.hasSuffix("/rollout-2026-06-19T00-00-00-newer.jsonl") == true)
    }

    @Test("newestCodexTranscript skips claimed rollouts")
    func newestCodexTranscriptSkipsClaimed() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-codex-claimed-\(UUID().uuidString)", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let cwd = home.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try writeCodexRollout(
            codexHome: codexHome,
            shard: "2026/06/18",
            sessionID: "older",
            cwd: cwd.path,
            modified: Date(timeIntervalSince1970: 100)
        )
        try writeCodexRollout(
            codexHome: codexHome,
            shard: "2026/06/19",
            sessionID: "claimed",
            cwd: cwd.path,
            modified: Date(timeIntervalSince1970: 300)
        )

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let result = resolver.newestCodexTranscript(
            workingDirectory: cwd.path,
            excludingSessionIDs: ["claimed"]
        )

        #expect(result?.sessionID == "older")
    }

    @Test("seedFromHookStores restores Antigravity chat sessions by default")
    func seedRestoresAntigravityHookSessions() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-seed-\(UUID().uuidString)", isDirectory: true)
        let stateDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let transcript = home.appendingPathComponent("antigravity-transcript.jsonl", isDirectory: false)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)
        defer { try? fm.removeItem(at: home) }

        let store = stateDir.appendingPathComponent("antigravity-hook-sessions.json", isDirectory: false)
        let pid = Int(getpid())
        let json = """
        {
          "sessions": {
            "antigravity-conversation-123": {
              "workspaceId": "11111111-1111-1111-1111-111111111111",
              "surfaceId": "22222222-2222-2222-2222-222222222222",
              "cwd": "/tmp/antigravity repo",
              "transcriptPath": "\(transcript.path)",
              "pid": \(pid),
              "updatedAt": 1779231774
            }
          }
        }
        """
        try Data(json.utf8).write(to: store)

        let records = await MainActor.run {
            let registry = AgentChatSessionRegistry(
                hookStore: AgentChatHookSessionStore(homeDirectory: home)
            )
            registry.seedFromHookStores()
            return registry.sessions(workspaceID: nil)
        }

        #expect(records.map(\.sessionID) == ["antigravity-conversation-123"])
        #expect(records.first?.agentKind.sourceName == "antigravity")
        #expect(records.first?.state == .idle)
        #expect(records.first?.transcriptPath == transcript.path)
    }

    @Test("seedFromHookStores restores legacy Antigravity source aliases by default")
    func seedRestoresLegacyAntigravityHookSessions() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-alias-seed-\(UUID().uuidString)", isDirectory: true)
        let stateDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let geminiTranscript = home.appendingPathComponent("gemini-transcript.jsonl", isDirectory: false)
        let agyTranscript = home.appendingPathComponent("agy-transcript.jsonl", isDirectory: false)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: geminiTranscript)
        try Data("{}\n".utf8).write(to: agyTranscript)
        defer { try? fm.removeItem(at: home) }

        let pid = Int(getpid())
        try Data("""
        {
          "sessions": {
            "gemini-conversation-123": {
              "workspaceId": "11111111-1111-1111-1111-111111111111",
              "surfaceId": "22222222-2222-2222-2222-222222222222",
              "cwd": "/tmp/gemini repo",
              "transcriptPath": "\(geminiTranscript.path)",
              "pid": \(pid),
              "updatedAt": 1779231774
            }
          }
        }
        """.utf8).write(
            to: stateDir.appendingPathComponent("gemini-hook-sessions.json", isDirectory: false)
        )
        try Data("""
        {
          "sessions": {
            "agy-conversation-123": {
              "workspaceId": "33333333-3333-3333-3333-333333333333",
              "surfaceId": "44444444-4444-4444-4444-444444444444",
              "cwd": "/tmp/agy repo",
              "transcriptPath": "\(agyTranscript.path)",
              "pid": \(pid),
              "updatedAt": 1779231775
            }
          }
        }
        """.utf8).write(
            to: stateDir.appendingPathComponent("agy-hook-sessions.json", isDirectory: false)
        )

        let records = await MainActor.run {
            let registry = AgentChatSessionRegistry(
                hookStore: AgentChatHookSessionStore(homeDirectory: home)
            )
            registry.seedFromHookStores()
            return registry.sessions(workspaceID: nil)
        }

        #expect(Set(records.map(\.sessionID)) == [
            "agy-conversation-123",
            "gemini-conversation-123",
        ])
        #expect(records.allSatisfy { $0.agentKind == .antigravity })
        #expect(records.allSatisfy { $0.state == .idle })
    }

    @Test("Antigravity fallback resolves shared history only when the session id is present")
    func antigravityFallbackHistory() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-fallback-\(UUID().uuidString)", isDirectory: true)
        let historyDir = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
        let history = historyDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try """
        {"conversationId":"other-conversation","display":"Wrong chat"}
        {"conversation_id":"antigravity-conversation-123","display":"Right chat"}
        """.write(to: history, atomically: true, encoding: .utf8)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let matchingRecord = AgentChatSessionRecord(
            sessionID: "antigravity-conversation-123",
            agentKind: .antigravity,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )
        let missingRecord = AgentChatSessionRecord(
            sessionID: "missing-conversation",
            agentKind: .antigravity,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )

        #expect(resolver.transcriptPath(for: matchingRecord) == history.path)
        #expect(resolver.transcriptPath(for: missingRecord) == nil)
    }

    @Test("Antigravity fallback resolves brain transcript by session id")
    func antigravityFallbackBrainTranscript() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-brain-\(UUID().uuidString)", isDirectory: true)
        let logs = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent("brain-session", isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        let transcript = logs.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let fullTranscript = logs.appendingPathComponent("transcript_full.jsonl", isDirectory: false)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try """
        {"type":"USER_INPUT","content":"Brain prompt","created_at":"2026-06-19T11:00:00Z"}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        try """
        {"type":"USER_INPUT","content":"Full brain prompt","created_at":"2026-06-19T11:00:00Z"}
        """.write(to: fullTranscript, atomically: true, encoding: .utf8)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let record = AgentChatSessionRecord(
            sessionID: "brain-session",
            agentKind: .antigravity,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )

        #expect(resolver.transcriptPath(for: record) == transcript.path)
    }

    @Test("Antigravity fallback resolves generated brain messages when logs are absent")
    func antigravityFallbackBrainGeneratedMessages() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-brain-messages-\(UUID().uuidString)", isDirectory: true)
        let messages = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent("brain-session", isDirectory: true)
            .appendingPathComponent("task-720", isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        try fm.createDirectory(at: messages, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try """
        {"id":"message-1","sender":"brain-session/task-720","recipient":"brain-session","content":"Generated reply"}
        """.write(
            to: messages.appendingPathComponent("message-1.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let record = AgentChatSessionRecord(
            sessionID: "brain-session/task-720",
            agentKind: .antigravity,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )

        #expect(resolver.transcriptPath(for: record) == messages.path)
    }

    @Test("Antigravity fallback prefers per-session JSON over shared history")
    func antigravityFallbackPrefersSessionJSON() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-json-fallback-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("repo", isDirectory: true)
        let hash = Self.sha256Hex(cwd.path)
        let chats = home
            .appendingPathComponent(".antigravity", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        let transcript = chats.appendingPathComponent("session-2026-06-19T10-00-json.json", isDirectory: false)
        let historyDir = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
        let history = historyDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: chats, withIntermediateDirectories: true)
        try fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try """
        {"sessionId":"agy-json-session","messages":[{"type":"user","id":"u","content":"JSON prompt"}]}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        try """
        {"conversationId":"agy-json-session","cwd":"\(cwd.path)","display":"History prompt"}
        """.write(to: history, atomically: true, encoding: .utf8)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let record = AgentChatSessionRecord(
            sessionID: "agy-json-session",
            agentKind: .antigravity,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: cwd.path,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )

        #expect(resolver.transcriptPath(for: record) == transcript.path)
    }

    @Test("newestAntigravityTranscript adopts the newest cwd-matching conversation")
    func newestAntigravityTranscriptMatchesCWD() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-newest-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("repo", isDirectory: true)
        let otherCwd = home.appendingPathComponent("other", isDirectory: true)
        let historyDir = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
        let history = historyDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try """
        {"conversationId":"older","cwd":"\(cwd.path)","display":"Older prompt","timestamp":1000}
        {"conversationId":"elsewhere","cwd":"\(otherCwd.path)","display":"Wrong cwd","timestamp":5000}
        {"conversation_id":"newer","workingDirectory":"\(cwd.path)","display":"Newest prompt","timestamp":2000}
        """.write(to: history, atomically: true, encoding: .utf8)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let result = resolver.newestAntigravityTranscript(workingDirectory: cwd.path)

        #expect(result?.sessionID == "newer")
        #expect(result?.path == history.path)
        #expect(result?.title == "Newest prompt")
    }

    @Test("newestAntigravityTranscript adopts current agy nested JSONL transcripts")
    func newestAntigravityTranscriptMatchesCurrentNestedJSONL() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-current-jsonl-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("brief2dev", isDirectory: true)
        let chats = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(cwd.lastPathComponent, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("8a211dfc-80b1-4a68-a4a5-2486fa6f3beb", isDirectory: true)
        let transcript = chats.appendingPathComponent("eriepr.jsonl", isDirectory: false)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try """
        {"sessionId":"eriepr","projectHash":"project-hash"}
        {"type":"user","id":"u","content":"Summarize the current agy session"}
        """.write(to: transcript, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 5_000)],
            ofItemAtPath: transcript.path
        )

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let result = resolver.newestAntigravityTranscript(workingDirectory: cwd.path)

        #expect(result?.sessionID == "eriepr")
        #expect(result?.path == transcript.path)
        #expect(result?.title == "Summarize the current agy session")
    }

    @Test("newestAntigravityTranscript skips claimed and cwd-less history rows")
    func newestAntigravityTranscriptSkipsClaimedAndAmbiguousRows() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-antigravity-claimed-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("repo", isDirectory: true)
        let historyDir = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
        let history = historyDir.appendingPathComponent("history.jsonl", isDirectory: false)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        try """
        {"conversationId":"older","cwd":"\(cwd.path)","display":"Older prompt","timestamp":1000}
        {"conversationId":"claimed","cwd":"\(cwd.path)","display":"Claimed prompt","timestamp":4000}
        {"conversationId":"ambiguous","display":"No cwd should not win","timestamp":9000}
        """.write(to: history, atomically: true, encoding: .utf8)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let result = resolver.newestAntigravityTranscript(
            workingDirectory: cwd.path,
            excludingSessionIDs: ["claimed"]
        )

        #expect(result?.sessionID == "older")
    }

    private func writeCodexRollout(
        codexHome: URL,
        shard: String,
        sessionID: String,
        cwd: String,
        modified: Date
    ) throws {
        let dir = codexHome.appendingPathComponent("sessions/\(shard)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(
            "rollout-2026-06-19T00-00-00-\(sessionID).jsonl",
            isDirectory: false
        )
        let meta: [String: Any] = [
            "timestamp": "2026-06-19T00:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": sessionID,
                "timestamp": "2026-06-19T00:00:00.000Z",
                "cwd": cwd,
                "originator": "codex-tui",
            ],
        ]
        var contents = try JSONSerialization.data(withJSONObject: meta)
        contents.append(0x0A)
        contents.append(Data(#"{"type":"turn_context","payload":{"model":"gpt-5"}}"#.utf8))
        contents.append(0x0A)
        try contents.write(to: fileURL)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fileURL.path)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
