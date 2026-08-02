import AppKit
import Foundation
import CmuxAgentChat

@MainActor
final class AgentSessionPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .agentSession
    private(set) var workspaceId: UUID
    let rendererKind: AgentSessionRendererKind
    let initialProviderID: AgentSessionProviderID
    private(set) var workingDirectory: String?

    let scene: AgentStudioScene
    let workspaceManager: AgentStudioWorkspaceManager
    let ptyBinding: PTYBinding

    private(set) var currentProviderID: AgentSessionProviderID
    private(set) var displayTitle: String
    var displayIcon: String? { "sparkles.rectangle.stack" }
    private(set) var isDirty: Bool = false
    var onDisplayStateChanged: ((String, Bool) -> Void)? {
        didSet {
            onDisplayStateChanged?(displayTitle, isDirty)
        }
    }

    init(
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID = .codex,
        workingDirectory: String? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = initialProviderID
        self.currentProviderID = initialProviderID
        self.workingDirectory = workingDirectory
        self.displayTitle = Self.title(provider: initialProviderID, rendererKind: rendererKind)

        let scene = AgentStudioScene(size: CGSize(width: 800, height: 600))
        let manager = AgentStudioWorkspaceManager()
        let binding = PTYBinding()

        self.scene = scene
        self.workspaceManager = manager
        self.ptyBinding = binding

        manager.loadWorkspaces()
        if let active = manager.activeWorkspace {
            binding.attach(to: scene, workspace: active)
            for agent in active.agents {
                scene.addAgent(id: agent.id, characterId: agent.characterId, seatIndex: agent.seatIndex)
            }
        }
    }

    nonisolated static func title(
        provider: AgentSessionProviderID,
        rendererKind: AgentSessionRendererKind
    ) -> String {
        let format = String(localized: "agentSession.panel.title", defaultValue: "%@ · %@")
        return String(format: format, provider.displayName, rendererKind.displayName)
    }

    func focus() {}

    func unfocus() {}

    func close() {}

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func clearWorkingDirectory() {
        workingDirectory = nil
    }

    private func setHasActiveProvider(_ hasActiveProvider: Bool) {
        guard isDirty != hasActiveProvider else { return }
        isDirty = hasActiveProvider
        emitDisplayStateChanged()
    }

    private func setCurrentProviderID(_ providerID: AgentSessionProviderID) {
        guard currentProviderID != providerID else { return }
        currentProviderID = providerID
        displayTitle = Self.title(provider: providerID, rendererKind: rendererKind)
        emitDisplayStateChanged()
    }

    private func emitDisplayStateChanged() {
        onDisplayStateChanged?(displayTitle, isDirty)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
