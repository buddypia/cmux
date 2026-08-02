import SwiftUI
import Combine

/// Central ViewModel managing state, selection, Auto Pilot Mode, and event synchronization for Agent Studio.
@MainActor
public final class AgentStudioViewModel: ObservableObject {
    @Published public var selectedAgentId: String? = nil
    @Published public var isAutoPilotEnabled: Bool = false
    @Published public var activeAgents: [String] = []
    @Published public var currentActionMessage: String? = nil
    @Published public var recentEvents: [CanonicalEvent] = []

    public let autoPilotManager: AutoPilotManager
    public let scene: AgentStudioScene

    public init(scene: AgentStudioScene, autoPilotManager: AutoPilotManager = AutoPilotManager()) {
        self.scene = scene
        self.autoPilotManager = autoPilotManager
        setupSceneWiring()
    }

    private func setupSceneWiring() {
        scene.onAgentSelected = { [weak self] agentId in
            guard let self = self else { return }
            self.selectAgent(id: agentId)
        }
    }

    /// Select an agent and hydrate ViewModel properties for SwiftUI Binding.
    public func selectAgent(id: String?) {
        self.selectedAgentId = id
        if let id = id {
            self.isAutoPilotEnabled = autoPilotManager.isEnabled(forAgentId: id)
            if let fsm = scene.fsms[id] {
                self.currentActionMessage = fsm.currentState.defaultMessage
            }
        } else {
            self.isAutoPilotEnabled = false
            self.currentActionMessage = nil
        }
    }

    /// Toggle Auto Pilot mode for the currently selected agent.
    public func toggleAutoPilot(enabled: Bool) {
        guard let id = selectedAgentId else { return }
        self.isAutoPilotEnabled = enabled
        autoPilotManager.setAutoPilot(enabled: enabled, forAgentId: id)
    }

    /// Manually trigger an auto-continue turn for the selected agent.
    public func triggerAutoContinue() {
        guard let id = selectedAgentId else { return }
        autoPilotManager.handleTaskCompletion(forAgentId: id, state: .done)
    }

    /// Append a new canonical log event to the active inspector feed.
    public func appendLogEvent(_ event: CanonicalEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 20 {
            recentEvents.removeLast()
        }
    }
}
