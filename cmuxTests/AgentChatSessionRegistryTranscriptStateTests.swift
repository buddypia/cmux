import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("AgentChatSessionRegistry transcript state")
@MainActor
struct AgentChatSessionRegistryTranscriptStateTests {
    private let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    @Test("transcript pending input moves detected session to needs input")
    func transcriptPendingInputMovesDetectedSessionToNeedsInput() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "agy-session",
            agentKind: .antigravity,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/chat.json",
            at: baseTime
        )

        let inputAt = baseTime.addingTimeInterval(10)
        registry.noteTranscriptNeedsInput(sessionID: "agy-session", at: inputAt)

        let record = registry.record(sessionID: "agy-session")
        #expect(record?.state == .needsInput(since: inputAt))
        #expect(record?.lastActivityAt == inputAt)
    }

    @Test("transcript resolution clears needs input")
    func transcriptResolutionClearsNeedsInput() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "codex-session",
            agentKind: .codex,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/rollout.jsonl",
            at: baseTime
        )
        let inputAt = baseTime.addingTimeInterval(10)
        let resolvedAt = baseTime.addingTimeInterval(20)

        registry.noteTranscriptNeedsInput(sessionID: "codex-session", at: inputAt)
        registry.noteTranscriptInputResolved(sessionID: "codex-session", at: resolvedAt)

        let record = registry.record(sessionID: "codex-session")
        #expect(record?.state == .idle)
        #expect(record?.lastActivityAt == resolvedAt)
    }

    @Test("transcript running tool moves idle detected session to working")
    func transcriptRunningToolMovesDetectedSessionToWorking() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "codex-running-session",
            agentKind: .codex,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/rollout.jsonl",
            at: baseTime
        )

        let workingAt = baseTime.addingTimeInterval(15)
        registry.noteTranscriptWorking(sessionID: "codex-running-session", at: workingAt)

        let record = registry.record(sessionID: "codex-running-session")
        #expect(record?.state == .working(since: workingAt))
        #expect(record?.lastActivityAt == workingAt)
    }

    @Test("transcript completed work clears working")
    func transcriptCompletedWorkClearsWorking() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "codex-resolved-work-session",
            agentKind: .codex,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/rollout.jsonl",
            at: baseTime
        )
        let workingAt = baseTime.addingTimeInterval(15)
        let resolvedAt = baseTime.addingTimeInterval(30)

        registry.noteTranscriptWorking(sessionID: "codex-resolved-work-session", at: workingAt)
        registry.noteTranscriptWorkingResolved(sessionID: "codex-resolved-work-session", at: resolvedAt)

        let record = registry.record(sessionID: "codex-resolved-work-session")
        #expect(record?.state == .idle)
        #expect(record?.lastActivityAt == resolvedAt)
    }

    @Test("transcript running tool preserves active needs input")
    func transcriptRunningToolPreservesNeedsInput() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "agy-needs-input-session",
            agentKind: .antigravity,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/chat.json",
            at: baseTime
        )
        let inputAt = baseTime.addingTimeInterval(10)
        let workingAt = baseTime.addingTimeInterval(20)

        registry.noteTranscriptNeedsInput(sessionID: "agy-needs-input-session", at: inputAt)
        registry.noteTranscriptWorking(sessionID: "agy-needs-input-session", at: workingAt)

        let record = registry.record(sessionID: "agy-needs-input-session")
        #expect(record?.state == .needsInput(since: inputAt))
        #expect(record?.lastActivityAt == workingAt)
    }

    @Test("transcript completed work preserves active needs input")
    func transcriptCompletedWorkPreservesNeedsInput() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "agy-needs-input-resolved-work-session",
            agentKind: .antigravity,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/chat.json",
            at: baseTime
        )
        let inputAt = baseTime.addingTimeInterval(10)
        let resolvedAt = baseTime.addingTimeInterval(20)

        registry.noteTranscriptNeedsInput(sessionID: "agy-needs-input-resolved-work-session", at: inputAt)
        registry.noteTranscriptWorkingResolved(
            sessionID: "agy-needs-input-resolved-work-session",
            at: resolvedAt
        )

        let record = registry.record(sessionID: "agy-needs-input-resolved-work-session")
        #expect(record?.state == .needsInput(since: inputAt))
        #expect(record?.lastActivityAt == inputAt)
    }

    @Test("transcript pending input does not revive ended sessions")
    func transcriptPendingInputDoesNotReviveEndedSession() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "ended-session",
            agentKind: .antigravity,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/chat.json",
            at: baseTime
        )
        registry.update(sessionID: "ended-session") { $0.state = .ended }

        registry.noteTranscriptNeedsInput(
            sessionID: "ended-session",
            at: baseTime.addingTimeInterval(10)
        )

        #expect(registry.record(sessionID: "ended-session")?.state == .ended)
    }

    @Test("transcript running tool does not revive ended sessions")
    func transcriptRunningToolDoesNotReviveEndedSession() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "ended-working-session",
            agentKind: .codex,
            workspaceID: "workspace-1",
            surfaceID: "surface-1",
            workingDirectory: "/tmp/repo",
            transcriptPath: "/tmp/repo/rollout.jsonl",
            at: baseTime
        )
        registry.update(sessionID: "ended-working-session") { $0.state = .ended }

        registry.noteTranscriptWorking(
            sessionID: "ended-working-session",
            at: baseTime.addingTimeInterval(10)
        )

        #expect(registry.record(sessionID: "ended-working-session")?.state == .ended)
    }

    @Test("completion notifications clear hook-derived working state")
    func completionNotificationsClearHookDerivedWorkingState() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "agy-completion-notification"
        let workingAt = baseTime.addingTimeInterval(10)
        let completedAt = baseTime.addingTimeInterval(20)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: workingAt
        ))
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .notification,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: completedAt,
            extraFieldsJSON: #"{"message":"Turn complete in 1.0s."}"#
        ))

        let record = registry.record(sessionID: sessionID)
        #expect(record?.state == .idle)
        #expect(record?.lastActivityAt == completedAt)
    }

    @Test("neutral progress notifications preserve hook-derived working state")
    func neutralProgressNotificationsPreserveHookDerivedWorkingState() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "agy-progress-notification"
        let workingAt = baseTime.addingTimeInterval(10)
        let notifiedAt = baseTime.addingTimeInterval(20)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: workingAt
        ))
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .notification,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: notifiedAt,
            extraFieldsJSON: #"{"message":"Working through more changes"}"#
        ))

        let record = registry.record(sessionID: sessionID)
        #expect(record?.state == .working(since: workingAt))
        #expect(record?.lastActivityAt == notifiedAt)
    }

    @Test("extra error notifications move hook-derived working state to needs input")
    func extraErrorNotificationsMoveHookDerivedWorkingStateToNeedsInput() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "agy-extra-error-notification"
        let workingAt = baseTime.addingTimeInterval(10)
        let failedAt = baseTime.addingTimeInterval(20)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: workingAt
        ))
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .notification,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: failedAt,
            extraFieldsJSON: #"{"extra":{"error":"Command failed: approval denied"}}"#
        ))

        let record = registry.record(sessionID: sessionID)
        #expect(record?.state == .needsInput(since: failedAt))
        #expect(record?.lastActivityAt == failedAt)
    }

    @Test("extra completion notifications clear hook-derived working state")
    func extraCompletionNotificationsClearHookDerivedWorkingState() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "agy-extra-completion-notification"
        let workingAt = baseTime.addingTimeInterval(10)
        let completedAt = baseTime.addingTimeInterval(20)

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: workingAt
        ))
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .notification,
            source: "antigravity",
            workspaceId: "workspace-1",
            cwd: "/tmp/repo",
            receivedAt: completedAt,
            extraFieldsJSON: #"{"extra":{"summary":"Task completed"}}"#
        ))

        let record = registry.record(sessionID: sessionID)
        #expect(record?.state == .idle)
        #expect(record?.lastActivityAt == completedAt)
    }
}
