import Darwin
import Foundation
import Observation

/// Owns agent runtime maps that affect whether structured sidebar statuses are visible.
@MainActor
@Observable
final class WorkspaceSidebarAgentRuntimeObservationModel {
    @ObservationIgnored
    private(set) var agentPIDs: [String: pid_t] = [:]
    @ObservationIgnored
    private(set) var agentPIDProcessIdentitiesByKey: [String: AgentPIDProcessIdentity] = [:]
    @ObservationIgnored
    private(set) var agentPIDPanelIdsByKey: [String: UUID] = [:]
    @ObservationIgnored
    private(set) var agentPIDKeysByPanelId: [UUID: Set<String>] = [:]
    @ObservationIgnored
    private(set) var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] = [:]
    /// Panels whose agent reached `.running` at least once since the surface
    /// was created. Latched (never cleared while the agent stays bound) so the
    /// tab-title marker can tell "finished a turn" (`✅`) from "launched but
    /// never ran" (`💤`); the lifecycle map alone reports `.idle` for both.
    @ObservationIgnored
    private(set) var agentEverActivePanelIds: Set<UUID> = []
    /// Each surface's last agent conversation output, keyed by panel id.
    ///
    /// Written from the agent `Stop` hook regardless of the iMessage-mode
    /// setting: that setting governs the workspace-level chat preview, while
    /// this is the "what did the agent last say on this tab" text the sidebar
    /// and the session snapshot both need.
    @ObservationIgnored
    private(set) var agentLastMessagesByPanelId: [UUID: String] = [:]
    /// Statuses restored from the previous session's snapshot, shown until a
    /// live agent reports on that surface.
    @ObservationIgnored
    private(set) var restoredAgentStatusesByPanelId: [UUID: RestoredAgentSurfaceStatus] = [:]
    @ObservationIgnored
    private(set) var changeGeneration: UInt64 = 0

    @ObservationIgnored
    private(set) var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Emits whenever any runtime map changes.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeObservers[id] = nil }
            }
        }
    }

    func setAgentPIDs(_ newValue: [String: pid_t]) {
        guard agentPIDs != newValue else { return }
        agentPIDs = newValue
        notifyChanged()
    }

    func setAgentPIDProcessIdentitiesByKey(_ newValue: [String: AgentPIDProcessIdentity]) {
        guard agentPIDProcessIdentitiesByKey != newValue else { return }
        agentPIDProcessIdentitiesByKey = newValue
        notifyChanged()
    }

    func setAgentPIDPanelIdsByKey(_ newValue: [String: UUID]) {
        guard agentPIDPanelIdsByKey != newValue else { return }
        agentPIDPanelIdsByKey = newValue
        notifyChanged()
    }

    func setAgentPIDKeysByPanelId(_ newValue: [UUID: Set<String>]) {
        guard agentPIDKeysByPanelId != newValue else { return }
        agentPIDKeysByPanelId = newValue
        notifyChanged()
    }

    func setAgentLifecycleStatesByPanelId(_ newValue: [UUID: [String: AgentHibernationLifecycleState]]) {
        guard agentLifecycleStatesByPanelId != newValue else { return }
        agentLifecycleStatesByPanelId = newValue
        // Latch on the way in so every mutation lane (hooks, transcript
        // observation, manual socket writes) feeds the same flag, and drop
        // panels whose agents all went away so a recycled surface starts over.
        var everActive = agentEverActivePanelIds.intersection(newValue.keys)
        for (panelId, states) in newValue where states.values.contains(.running) {
            everActive.insert(panelId)
        }
        agentEverActivePanelIds = everActive
        notifyChanged()
    }

    func setAgentLastMessagesByPanelId(_ newValue: [UUID: String]) {
        guard agentLastMessagesByPanelId != newValue else { return }
        agentLastMessagesByPanelId = newValue
        notifyChanged()
    }

    func setRestoredAgentStatusesByPanelId(_ newValue: [UUID: RestoredAgentSurfaceStatus]) {
        guard restoredAgentStatusesByPanelId != newValue else { return }
        restoredAgentStatusesByPanelId = newValue
        notifyChanged()
    }

    /// Drops a surface's restored status once a live agent reports on it, so a
    /// resumed session stops advertising the pre-restart reading.
    func clearRestoredAgentStatus(panelId: UUID) {
        guard restoredAgentStatusesByPanelId[panelId] != nil else { return }
        restoredAgentStatusesByPanelId.removeValue(forKey: panelId)
        notifyChanged()
    }

    private func notifyChanged() {
        changeGeneration &+= 1
        // Termination cleanup arrives through a separate MainActor task. If
        // that task is delayed by sidebar work, publication is the
        // authoritative reconciliation point so dead observers cannot make
        // every later event progressively more expensive.
        var terminatedObserverIDs: [UUID] = []
        for (id, continuation) in changeObservers {
            if case .terminated = continuation.yield(()) {
                terminatedObserverIDs.append(id)
            }
        }
        for id in terminatedObserverIDs {
            changeObservers[id] = nil
        }
    }
}
