import Foundation
import Testing
import CryptoKit

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

    private static func antigravityRecord(sessionID: String, cwd: String) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .antigravity,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: cwd,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            title: nil,
            pid: nil
        )
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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

    @Test("Antigravity fallback finds current nested Gemini JSONL by sessionId")
    func antigravityCurrentGeminiNestedJSONL() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-agy-gemini-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("brief2dev", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let transcript = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("brief2dev", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("8a211dfc-80b1-4a68-a4a5-2486fa6f3beb", isDirectory: true)
            .appendingPathComponent("eriepr.jsonl", isDirectory: false)
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"sessionId":"eriepr","projectHash":"project-hash"}"#.utf8).write(to: transcript)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let record = Self.antigravityRecord(sessionID: "eriepr", cwd: cwd.path)

        #expect(resolver.transcriptPath(for: record) == transcript.path)
    }

    @Test("Antigravity fallback finds single-object JSON by sessionId")
    func antigravitySingleObjectJSON() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-agy-json-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("json-repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let transcript = home
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("json-repo", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("8a211dfc-80b1-4a68-a4a5-2486fa6f3beb", isDirectory: true)
            .appendingPathComponent("snapshot.json", isDirectory: false)
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": "agy-json-session",
            "projectHash": "project-hash",
            "messages": [
                ["type": "user", "content": "restore this JSON transcript"],
            ],
        ])
        try data.write(to: transcript)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let record = Self.antigravityRecord(sessionID: "agy-json-session", cwd: cwd.path)

        #expect(resolver.transcriptPath(for: record) == transcript.path)
    }

    @Test("Antigravity fallback finds older hash JSONL by top-level sessionId")
    func antigravityHashJSONL() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-agy-hash-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("proj-old", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let transcript = home
            .appendingPathComponent(".antigravity", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(Self.sha256Hex(cwd.path), isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("session-2026-05-06T10-00-keepme.jsonl", isDirectory: false)
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"sessionId":"native-session-123","role":"event","name":"session_metadata"}"#.utf8).write(to: transcript)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let record = Self.antigravityRecord(sessionID: "native-session-123", cwd: cwd.path)

        #expect(resolver.transcriptPath(for: record) == transcript.path)
    }
}
