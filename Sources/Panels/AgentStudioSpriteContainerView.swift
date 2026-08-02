import SwiftUI
import SpriteKit
import CmuxAgentChat

/// Container view integrating native Apple `SpriteView` and SwiftUI progress inspector overlay via ViewModel.
public struct AgentStudioSpriteContainerView: View {
    @ObservedObject public var viewModel: AgentStudioViewModel

    public init(viewModel: AgentStudioViewModel) {
        self.viewModel = viewModel
    }

    public init(scene: AgentStudioScene) {
        self.viewModel = AgentStudioViewModel(scene: scene)
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // MARK: - Native Apple SpriteView (Best Practice)
            SpriteView(scene: viewModel.scene)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            // MARK: - SwiftUI Inspector Overlay Panel
            if let agentId = viewModel.selectedAgentId {
                let fsm = viewModel.scene.fsms[agentId]
                let currentState = fsm?.currentState ?? .idle

                AgentProgressInspectorView(
                    agentId: agentId,
                    roleName: "AI Developer",
                    cliType: "Claude Code",
                    currentState: currentState,
                    currentActionMessage: viewModel.currentActionMessage,
                    recentEvents: viewModel.recentEvents,
                    isAutoPilotEnabled: $viewModel.isAutoPilotEnabled,
                    onClose: {
                        viewModel.selectAgent(id: nil)
                    },
                    onToggleAutoPilot: { enabled in
                        viewModel.toggleAutoPilot(enabled: enabled)
                    },
                    onTriggerAutoContinue: {
                        viewModel.triggerAutoContinue()
                    }
                )
                .padding(16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.selectedAgentId)
            }
        }
    }
}
