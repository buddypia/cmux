import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryLifecycleTests {
    @MainActor
    @Test func hookStoreSeedDoesNotRestoreStalePIDOntoExistingLiveRecord() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let (staleWorkspaceID, staleSurfaceID) = (UUID().uuidString, UUID().uuidString)
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(sessionID).jsonl"
        try writeClaudeHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: staleWorkspaceID,
            surfaceID: staleSurfaceID,
            transcriptPath: transcriptPath,
            pid: 444
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        await registry.seedFromHookStores(agentSources: ["claude"])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.workspaceID == workspaceID)
        #expect(record.surfaceID == surfaceID)
        #expect(record.transcriptPath == transcriptPath)
        #expect(record.pid == nil)
        #expect(record.state == .idle)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == sessionID)
    }

    @MainActor
    @Test func endedPendingClaudeObservationRevivesForNewIdleProcess() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let record = try #require(registry.record(sessionID: pendingID))
        #expect(record.state == .idle)
        #expect(record.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == pendingID)
    }

    @MainActor
    @Test func transcriptBackedEndedPendingClaudeIsPreservedWhenNewIdleProcessAppears() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/session.jsonl"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.transcriptPath = transcriptPath
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        let live = try #require(registry.record(sessionID: nextPendingID))
        #expect(ended.state == .ended)
        #expect(ended.transcriptPath == transcriptPath)
        #expect(live.state == .idle)
        #expect(live.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == nextPendingID)
    }

    @MainActor
    @Test func stalePendingClaudeObservationDoesNotCreateNewLiveAlias() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/session.jsonl"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.transcriptPath = transcriptPath
            record.state = .ended
        }
        let endedAt = try #require(registry.record(sessionID: pendingID)?.endedAt)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: endedAt.addingTimeInterval(-1)
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        #expect(ended.state == .ended)
        #expect(ended.pid == 111)
        #expect(registry.record(sessionID: nextPendingID) == nil)
        #expect(registry.liveSession(surfaceID: surfaceID) == nil)
    }

    @MainActor
    @Test func hookBackedEndedPendingClaudeIsPreservedWhenNewIdleProcessAppears() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let nextPendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID, pid: 222)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        registry.update(sessionID: pendingID) { record in
            record.rememberHookStoreSessionID(realSessionID)
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let ended = try #require(registry.record(sessionID: pendingID))
        let live = try #require(registry.record(sessionID: nextPendingID))
        #expect(ended.state == .ended)
        #expect(ended.hookStoreSessionID == realSessionID)
        #expect(live.state == .idle)
        #expect(live.pid == 222)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == nextPendingID)
    }

    @MainActor
    @Test func endedCodexObservationRevivesRealSessionID() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl"
            ),
        ])
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
        }

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.state == .idle)
        #expect(record.pid == 222)
        #expect(record.transcriptPath == "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl")
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == sessionID)
    }

    @MainActor
    @Test func staleProcessObservationDoesNotReviveEndedSession() throws {
        let registry = AgentChatSessionRegistry()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 111,
                workingDirectory: "/Users/example/project",
                transcriptPath: "/Users/example/.codex/sessions/rollout-\(sessionID).jsonl",
                sampledAt: Date(timeIntervalSince1970: 100)
            ),
        ])
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
        }
        let endedAt = try #require(registry.record(sessionID: sessionID)?.endedAt)

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: sessionID,
                agentKind: .codex,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: 222,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil,
                sampledAt: endedAt.addingTimeInterval(-1)
            ),
        ])

        let record = try #require(registry.record(sessionID: sessionID))
        #expect(record.state == .ended)
        #expect(record.pid == 111)
        #expect(registry.liveSession(surfaceID: surfaceID) == nil)
    }

    @MainActor
    @Test func pendingClaudeAliasRefreshesFromRealHookStoreSessionID() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"
        try writeClaudeHookStore(
            home: home,
            sessionID: realSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            pid: 222
        )
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))

        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: realSessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: 333,
            receivedAt: Date(timeIntervalSince1970: 150)
        ))

        let refreshed = try #require(await registry.refreshBindingsFromHookStore(sessionID: pendingID))
        #expect(refreshed.transcriptPath == transcriptPath)
        #expect(refreshed.pid == 333)
    }

    @MainActor
    @Test func endedSessionWithMissingTranscriptIsNotListableForMobileChat() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: transcriptURL.path,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )

        #expect(!service.hasBoundedReadableTranscript(record))

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        #expect(service.hasBoundedReadableTranscript(record))
        _ = service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID, hookEventName: .sessionEnd, source: "claude",
            workspaceId: record.workspaceID, surfaceId: record.surfaceID,
            transcriptPath: transcriptURL.path, cwd: "/Users/example/project", ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 250)
        ))
        let cachedRecord = try #require(service.sessionRecord(sessionID: sessionID))
        #expect(cachedRecord.state == .ended)
        #expect(service.shouldListEndedSession(cachedRecord))
    }

    @MainActor
    @Test func endedCodexSessionListabilityKeepsFallbackRowsWithoutScanningHistory() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".codex/sessions/2026/06/30", isDirectory: true)
            .appendingPathComponent("rollout-2026-06-30T00-00-00-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )

        #expect(!service.hasBoundedReadableTranscript(record))
        #expect(service.shouldListEndedSession(record))
    }

    @MainActor
    @Test func pendingClaudeAliasUsesRealHookSessionIDForFallbackTranscript() throws {
        let home = try temporaryHomeDirectory()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(realSessionID).jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
        var record = AgentChatSessionRecord(
            sessionID: pendingID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .ended,
            lastActivityAt: Date(),
            title: nil,
            pid: nil
        )
        record.rememberHookStoreSessionID(realSessionID)

        #expect(service.hasBoundedReadableTranscript(record))
    }

    @MainActor
    @Test func restoreStyleInitializationRebuildsSurfaceLookup() throws {
        let surfaceID = UUID().uuidString
        let older = AgentChatSessionRecord(
            sessionID: "older",
            agentKind: .codex,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: "/tmp/older.jsonl",
            state: .ended,
            lastActivityAt: Date(timeIntervalSince1970: 100),
            title: nil,
            pid: nil
        )
        let newer = AgentChatSessionRecord(
            sessionID: "newer",
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: "/tmp/newer.jsonl",
            state: .ended,
            lastActivityAt: Date(timeIntervalSince1970: 200),
            title: nil,
            pid: nil
        )
        let registry = AgentChatSessionRegistry(restoredRecords: [older, newer])

        let resolved = try #require(registry.currentOrMostRecentSession(surfaceID: surfaceID))
        #expect(resolved.sessionID == newer.sessionID)
    }

    private func temporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeClaudeHookStore(
        home: URL,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        transcriptPath: String,
        pid: Int
    ) throws {
        let directory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "sessions": [
                sessionID: [
                    "workspaceId": workspaceID,
                    "surfaceId": surfaceID,
                    "cwd": "/Users/example/project",
                    "transcriptPath": transcriptPath,
                    "pid": pid,
                    "updatedAt": 140.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("claude-hook-sessions.json"))
    }
}

/// Regression tests for the sidebar drawing `💤 Idle` over an agent that is
/// mid-turn.
///
/// A Claude Code session launched with the cmux hook integration off
/// (`automation.claudeCodeIntegration: false`, which exports
/// `CMUX_CLAUDE_HOOKS_DISABLED=1` and makes `cmux-claude-wrapper` inject no
/// hooks) reaches the registry through one lane only: the process table.
/// ``AgentChatSessionRecord/hasHookLifecycleState`` documents that lane as
/// proving "presence and identity, but not idleness" — yet its placeholder
/// `.idle` was mirrored onto the surface as an `agentchat.<cli>` lifecycle
/// entry, which the sidebar's per-CLI badge strip and the surface tab title
/// both render as `💤`. Nothing could move it off `💤` afterwards either: only
/// the Codex and Antigravity transcript parsers emit state updates, so the pill
/// said "Idle" for the entire time Claude Code was working.
@MainActor
struct AgentChatWorkspaceLifecycleMirrorTests {
    private static let claudeMirrorKey = "agentchat.claude"
    private static let codexMirrorKey = "agentchat.codex"
    private let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    @MainActor
    private struct Fixture {
        let registry: AgentChatSessionRegistry
        let service: AgentChatTranscriptService
        let workspace: Workspace
        let panelId: UUID
        let restore: () -> Void

        var surfaceID: String { panelId.uuidString }
        var workspaceID: String { workspace.id.uuidString }

        /// The lifecycle entry the sidebar badge strip and the tab title read.
        func mirroredLifecycle(_ key: String) -> AgentHibernationLifecycleState? {
            workspace.agentLifecycleStatesByPanelId[panelId]?[key]
        }
    }

    /// A workspace registered with the live `AppDelegate`, because the mirror
    /// resolves its target through `AppDelegate.workspaceFor(tabId:)` — a
    /// detached `Workspace()` would make every assertion vacuously pass.
    private func makeFixture() throws -> Fixture {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()
        let originalTabManager = appDelegate.tabManager
        appDelegate.tabManager = manager
        let workspace = manager.addWorkspace(select: false)
        let panelId = try #require(workspace.focusedPanelId)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let registry = AgentChatSessionRegistry()
        let service = AgentChatTranscriptService(
            registry: registry,
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        return Fixture(
            registry: registry,
            service: service,
            workspace: workspace,
            panelId: panelId,
            restore: {
                // The registry holds the service weakly through
                // `onRecordChanged`; keep it alive for the whole test.
                withExtendedLifetime(service) {}
                if manager.tabs.contains(where: { $0.id == workspace.id }) {
                    manager.closeWorkspace(workspace)
                }
                appDelegate.tabManager = originalTabManager
                try? FileManager.default.removeItem(at: home)
            }
        )
    }

    /// What the process-table sweep reports for a hook-less `claude` running on
    /// the surface: an alive pid, a surface binding, and no transcript yet.
    private func observedClaudeProcess(_ fixture: Fixture, at timestamp: Date) -> ObservedAgentSession {
        ObservedAgentSession(
            sessionID: AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: fixture.surfaceID),
            agentKind: .claude,
            surfaceID: fixture.surfaceID,
            workspaceID: fixture.workspaceID,
            // The test process itself: a genuinely live pid, so the registry's
            // exit watcher cannot race the assertion by ending the record.
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            sampledAt: timestamp
        )
    }

    @Test func processDiscoveredAgentPublishesNoStatusOntoItsSurface() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }

        fixture.registry.applyObservedSessions([observedClaudeProcess(fixture, at: baseTime)])

        // Presence and identity were proven, so the record exists ...
        let sessionID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: fixture.surfaceID)
        #expect(fixture.registry.record(sessionID: sessionID) != nil)
        // ... but nothing proved the agent is *idle*, and a working agent is
        // exactly what the process table cannot rule out. Publish nothing.
        #expect(fixture.mirroredLifecycle(Self.claudeMirrorKey) == nil)
    }

    @Test func hookReportedIdlePublishesIdleEvenWhenProcessDiscoveryFoundItFirst() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let hookSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        fixture.registry.applyObservedSessions([observedClaudeProcess(fixture, at: baseTime)])
        // SessionStart reports `.idle` — the same value the process lane already
        // held, so only its provenance changed. The sidebar must start showing
        // it: this one is a reading, not a placeholder.
        _ = fixture.service.noteHookEvent(WorkstreamEvent(
            sessionId: hookSessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: fixture.workspaceID,
            surfaceId: fixture.surfaceID,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: Int(ProcessInfo.processInfo.processIdentifier),
            receivedAt: baseTime.addingTimeInterval(1)
        ))

        #expect(fixture.mirroredLifecycle(Self.claudeMirrorKey) == .idle)
    }

    @Test func hookReportedWorkingPublishesRunning() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let hookSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"

        fixture.registry.applyObservedSessions([observedClaudeProcess(fixture, at: baseTime)])
        _ = fixture.service.noteHookEvent(WorkstreamEvent(
            sessionId: hookSessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: fixture.workspaceID,
            surfaceId: fixture.surfaceID,
            transcriptPath: nil,
            cwd: "/Users/example/project",
            ppid: Int(ProcessInfo.processInfo.processIdentifier),
            receivedAt: baseTime.addingTimeInterval(1)
        ))

        #expect(fixture.mirroredLifecycle(Self.claudeMirrorKey) == .running)
    }

    @Test func transcriptProvenIdleStillPublishesIdle() throws {
        let fixture = try makeFixture()
        defer { fixture.restore() }
        let sessionID = "019fc599-2304-7fe0-8cbd-886d17d6241b"

        // The Codex/Antigravity lane: the transcript itself proves the agent
        // started and then settled, so both states are readings and both must
        // reach the sidebar.
        fixture.registry.adoptDetectedSession(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: fixture.workspaceID,
            surfaceID: fixture.surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            at: baseTime
        )
        #expect(fixture.mirroredLifecycle(Self.codexMirrorKey) == nil)

        fixture.registry.noteTranscriptWorking(sessionID: sessionID, at: baseTime.addingTimeInterval(1))
        #expect(fixture.mirroredLifecycle(Self.codexMirrorKey) == .running)

        fixture.registry.noteTranscriptWorkingResolved(sessionID: sessionID, at: baseTime.addingTimeInterval(2))
        #expect(fixture.mirroredLifecycle(Self.codexMirrorKey) == .idle)
    }
}
