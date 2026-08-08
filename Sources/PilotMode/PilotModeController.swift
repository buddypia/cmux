import CMUXAgentLaunch
import Foundation

/// Drives Pilot Mode for pending Feed decisions.
///
/// Called from `FeedCoordinator.ingestBlocking` once the item is on the store
/// and the human-facing card is up. Evaluation runs concurrently with the user
/// looking at that card, and whichever answer lands first wins — the automatic
/// path claims the waiter with `onlyIfAwaiting`, so it can only ever fill a slot
/// the user has not.
final class PilotModeController: @unchecked Sendable {
    static let shared = PilotModeController()

    private let settingsStore: PilotModeSettingsStore
    private let judge: PilotModeJudge
    private let auditLog: PilotModeAuditLog
    private let lock = NSLock()
    /// Consecutive automatic decisions per surface, reset whenever a human
    /// answers on that surface.
    private var consecutiveDecisions: [UUID: Int] = [:]
    /// The surface each considered request belongs to. `deliverReply` knows only
    /// a request id, and the Feed's own `AttentionTarget` carries a workspace
    /// and panel rather than a surface, so the surface has to come from the
    /// event we saw on the way in.
    private var surfaceForRequest: [String: UUID] = [:]
    /// Insertion order for `surfaceForRequest`, so a request that is never
    /// answered (the hook gives up after 120s) cannot accumulate forever.
    private var requestOrder: [String] = []
    private static let maxTrackedRequests = 256

    init(
        settingsStore: PilotModeSettingsStore = .shared,
        judge: PilotModeJudge = PilotModeAgentJudge(),
        auditLog: PilotModeAuditLog = PilotModeAuditLog()
    ) {
        self.settingsStore = settingsStore
        self.judge = judge
        self.auditLog = auditLog
    }

    /// Entry point from the Feed ingress path. Returns immediately; the verdict
    /// is delivered asynchronously if Pilot Mode reaches one in time.
    func consider(event: WorkstreamEvent, requestId: String, itemId: UUID) {
        let surfaceId = event.surfaceId.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let settings = settingsStore.settings(forSurface: surfaceId)
        guard settings.isEnabled else { return }
        guard Self.isActionable(event.hookEventName) else { return }

        if let surfaceId {
            trackRequest(requestId, surfaceId: surfaceId)
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.evaluate(
                event: event,
                requestId: requestId,
                itemId: itemId,
                surfaceId: surfaceId,
                settings: settings
            )
        }
    }

    /// Resets the consecutive-decision counter for the surface the user just
    /// answered on. A human in the loop is exactly the condition the ceiling
    /// exists to force, so their answer restores the full budget.
    ///
    /// A request Pilot Mode never considered is not tracked, and resets nothing.
    func recordHumanDecision(requestId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let surfaceId = untrackRequestLocked(requestId) else { return }
        consecutiveDecisions[surfaceId] = 0
    }

    func forgetSurface(_ surfaceId: UUID) {
        lock.lock()
        consecutiveDecisions.removeValue(forKey: surfaceId)
        lock.unlock()
        settingsStore.forgetSurface(surfaceId)
    }

    private func trackRequest(_ requestId: String, surfaceId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if surfaceForRequest.updateValue(surfaceId, forKey: requestId) == nil {
            requestOrder.append(requestId)
        }
        while requestOrder.count > Self.maxTrackedRequests {
            surfaceForRequest.removeValue(forKey: requestOrder.removeFirst())
        }
    }

    /// Caller must hold `lock`.
    @discardableResult
    private func untrackRequestLocked(_ requestId: String) -> UUID? {
        guard let surfaceId = surfaceForRequest.removeValue(forKey: requestId) else { return nil }
        requestOrder.removeAll { $0 == requestId }
        return surfaceId
    }

    // MARK: - Evaluation

    private func evaluate(
        event: WorkstreamEvent,
        requestId: String,
        itemId: UUID,
        surfaceId: UUID?,
        settings: PilotModeSettings
    ) async {
        guard let payload = await payload(forItem: itemId) else { return }
        let startedAt = Date()

        let evaluation: PilotModeEvaluation
        if let surfaceId, exceededCeiling(surfaceId: surfaceId, settings: settings) {
            evaluation = PilotModeEvaluation(
                verdict: .escalate(.rateLimited),
                source: .guardrail
            )
        } else {
            evaluation = await PilotModeEvaluator(settings: settings, judge: judge)
                .evaluate(
                    payload: payload,
                    context: PilotModeJudgeContext(
                        agentSlug: event.source,
                        cwd: event.cwd
                    )
                )
        }

        var applied = false
        if settings.runMode == .active, let decision = evaluation.verdict.decision {
            applied = FeedCoordinator.shared.deliverReply(
                requestId: requestId,
                decision: decision,
                onlyIfAwaiting: true
            )
            if applied {
                recordAutomaticDecision(requestId: requestId, surfaceId: surfaceId)
            }
        }

        record(
            evaluation: evaluation,
            event: event,
            requestId: requestId,
            payload: payload,
            settings: settings,
            applied: applied,
            elapsed: Date().timeIntervalSince(startedAt)
        )
    }

    /// Synchronous so the lock is never taken from an async context, where
    /// `NSLock` is unavailable in the Swift 6 language mode.
    private func recordAutomaticDecision(requestId: String, surfaceId: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        untrackRequestLocked(requestId)
        if let surfaceId {
            consecutiveDecisions[surfaceId, default: 0] += 1
        }
    }

    private func exceededCeiling(surfaceId: UUID, settings: PilotModeSettings) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return consecutiveDecisions[surfaceId, default: 0] >= settings.maxConsecutiveDecisions
    }

    @MainActor
    private func payload(forItem itemId: UUID) -> WorkstreamPayload? {
        FeedCoordinator.shared.store?.items.first { $0.id == itemId }?.payload
    }

    private func record(
        evaluation: PilotModeEvaluation,
        event: WorkstreamEvent,
        requestId: String,
        payload: WorkstreamPayload,
        settings: PilotModeSettings,
        applied: Bool,
        elapsed: TimeInterval
    ) {
        let described = PilotModeAuditLog.describe(evaluation)
        auditLog.append(
            PilotModeAuditLog.Entry(
                timestamp: Date(),
                requestId: requestId,
                workspaceId: event.workspaceId,
                surfaceId: event.surfaceId,
                agent: event.source,
                runMode: settings.runMode.rawValue,
                kind: Self.kind(of: payload),
                toolName: event.toolName,
                outcome: described.outcome,
                decision: described.decision,
                escalation: described.escalation,
                source: evaluation.source.rawValue,
                rationale: described.rationale,
                applied: applied,
                evaluationSeconds: elapsed
            )
        )
    }

    private static func kind(of payload: WorkstreamPayload) -> String {
        switch payload {
        case .permissionRequest: return "permissionRequest"
        case .question: return "question"
        case .exitPlan: return "exitPlan"
        default: return "other"
        }
    }

    private static func isActionable(_ hookEventName: WorkstreamEvent.HookEventName) -> Bool {
        switch hookEventName {
        case .permissionRequest, .askUserQuestion:
            return true
        default:
            return false
        }
    }
}
