import Foundation

public enum WorkspaceManagerError: Error, Equatable, Sendable {
    case workspaceNotFound(String)
    case agentNotFound(String)
    case seatOccupied(Int)
    case invalidSeatIndex(Int)
}

/// Manages multi-workspace state and agent seats in memory, synced with native JSON storage.
@MainActor
public final class AgentStudioWorkspaceManager: ObservableObject {
    @Published public private(set) var workspaces: [AgentStudioWorkspaceConfig] = []
    @Published public private(set) var activeWorkspaceId: String?

    public let storage: WorkspaceStorage

    public var onWorkspacesChanged: (([AgentStudioWorkspaceConfig]) -> Void)?
    public var onActiveWorkspaceChanged: ((AgentStudioWorkspaceConfig?) -> Void)?

    public init(storage: WorkspaceStorage = WorkspaceStorage()) {
        self.storage = storage
    }

    /// Load workspaces from disk. Creates a default workspace if none exists.
    public func loadWorkspaces() {
        do {
            let data = try storage.loadData()
            if data.workspaces.isEmpty {
                // Initialize default workspace
                let defaultWorkspace = AgentStudioWorkspaceConfig(
                    id: UUID().uuidString,
                    name: "Default Workspace",
                    path: FileManager.default.currentDirectoryPath,
                    theme: "office",
                    agents: [
                        AgentSeatConfig(name: "Claude Architect", cliProvider: .claude, role: "Architect", characterId: "char_0", seatIndex: 0),
                        AgentSeatConfig(name: "Codex Developer", cliProvider: .codex, role: "Developer", characterId: "char_1", seatIndex: 1),
                        AgentSeatConfig(name: "Antigravity Agent", cliProvider: .antigravity, role: "QA Specialist", characterId: "char_2", seatIndex: 2),
                    ]
                )
                self.workspaces = [defaultWorkspace]
                self.activeWorkspaceId = defaultWorkspace.id
                try saveWorkspaces()
            } else {
                self.workspaces = data.workspaces
                self.activeWorkspaceId = data.activeWorkspaceId ?? data.workspaces.first?.id
            }
        } catch {
            print("[AgentStudioWorkspaceManager] Failed to load workspaces: \(error)")
            self.workspaces = []
            self.activeWorkspaceId = nil
        }

        notifyChanges()
    }

    /// Save current state to storage.
    public func saveWorkspaces() throws {
        let data = AgentStudioWorkspaceData(
            version: 1,
            activeWorkspaceId: activeWorkspaceId,
            workspaces: workspaces
        )
        try storage.saveData(data)
    }

    /// Currently active workspace configuration.
    public var activeWorkspace: AgentStudioWorkspaceConfig? {
        guard let activeWorkspaceId else { return workspaces.first }
        return workspaces.first(where: { $0.id == activeWorkspaceId })
    }

    /// Create a new workspace and persist.
    @discardableResult
    public func createWorkspace(
        name: String,
        path: String,
        theme: String = "office",
        agents: [AgentSeatConfig] = []
    ) throws -> AgentStudioWorkspaceConfig {
        let newWorkspace = AgentStudioWorkspaceConfig(
            id: UUID().uuidString,
            name: name,
            path: path,
            theme: theme,
            agents: agents
        )
        workspaces.append(newWorkspace)
        if activeWorkspaceId == nil {
            activeWorkspaceId = newWorkspace.id
        }
        try saveWorkspaces()
        notifyChanges()
        return newWorkspace
    }

    /// Switch active workspace.
    public func switchWorkspace(to id: String) throws {
        guard workspaces.contains(where: { $0.id == id }) else {
            throw WorkspaceManagerError.workspaceNotFound(id)
        }
        activeWorkspaceId = id
        try saveWorkspaces()
        notifyChanges()
    }

    /// Delete a workspace.
    public func deleteWorkspace(id: String) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceManagerError.workspaceNotFound(id)
        }
        workspaces.remove(at: index)
        if activeWorkspaceId == id {
            activeWorkspaceId = workspaces.first?.id
        }
        try saveWorkspaces()
        notifyChanges()
    }

    /// Add an agent seat to a workspace.
    @discardableResult
    public func addAgent(
        toWorkspaceId workspaceId: String,
        name: String,
        cliProvider: AgentCLIProvider,
        role: String = "Developer",
        characterId: String = "char_0",
        seatIndex: Int? = nil
    ) throws -> AgentSeatConfig {
        guard let wIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            throw WorkspaceManagerError.workspaceNotFound(workspaceId)
        }

        let assignedSeat: Int
        if let seatIndex {
            guard seatIndex >= 0 && seatIndex < 6 else {
                throw WorkspaceManagerError.invalidSeatIndex(seatIndex)
            }
            if workspaces[wIndex].agents.contains(where: { $0.seatIndex == seatIndex }) {
                throw WorkspaceManagerError.seatOccupied(seatIndex)
            }
            assignedSeat = seatIndex
        } else {
            let takenSeats = Set(workspaces[wIndex].agents.map(\.seatIndex))
            guard let firstAvailable = (0..<6).first(where: { !takenSeats.contains($0) }) else {
                throw WorkspaceManagerError.invalidSeatIndex(-1)
            }
            assignedSeat = firstAvailable
        }

        let agent = AgentSeatConfig(
            id: UUID().uuidString,
            name: name,
            cliProvider: cliProvider,
            role: role,
            characterId: characterId,
            seatIndex: assignedSeat
        )

        workspaces[wIndex].agents.append(agent)
        workspaces[wIndex].updatedAt = Date()
        try saveWorkspaces()
        notifyChanges()
        return agent
    }

    /// Remove an agent from a workspace.
    public func removeAgent(fromWorkspaceId workspaceId: String, agentId: String) throws {
        guard let wIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            throw WorkspaceManagerError.workspaceNotFound(workspaceId)
        }

        guard let aIndex = workspaces[wIndex].agents.firstIndex(where: { $0.id == agentId }) else {
            throw WorkspaceManagerError.agentNotFound(agentId)
        }

        workspaces[wIndex].agents.remove(at: aIndex)
        workspaces[wIndex].updatedAt = Date()
        try saveWorkspaces()
        notifyChanges()
    }

    /// Update state for an agent in a workspace.
    public func updateAgentState(workspaceId: String, agentId: String, state: AgentState) throws {
        guard let wIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            throw WorkspaceManagerError.workspaceNotFound(workspaceId)
        }

        guard let aIndex = workspaces[wIndex].agents.firstIndex(where: { $0.id == agentId }) else {
            throw WorkspaceManagerError.agentNotFound(agentId)
        }

        workspaces[wIndex].agents[aIndex].state = state
        workspaces[wIndex].updatedAt = Date()
        try saveWorkspaces()
        notifyChanges()
    }

    /// Assign seat index to an agent in a workspace.
    public func assignSeat(workspaceId: String, agentId: String, seatIndex: Int) throws {
        guard seatIndex >= 0 && seatIndex < 6 else {
            throw WorkspaceManagerError.invalidSeatIndex(seatIndex)
        }

        guard let wIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            throw WorkspaceManagerError.workspaceNotFound(workspaceId)
        }

        if workspaces[wIndex].agents.contains(where: { $0.id != agentId && $0.seatIndex == seatIndex }) {
            throw WorkspaceManagerError.seatOccupied(seatIndex)
        }

        guard let aIndex = workspaces[wIndex].agents.firstIndex(where: { $0.id == agentId }) else {
            throw WorkspaceManagerError.agentNotFound(agentId)
        }

        workspaces[wIndex].agents[aIndex].seatIndex = seatIndex
        workspaces[wIndex].updatedAt = Date()
        try saveWorkspaces()
        notifyChanges()
    }

    private func notifyChanges() {
        onWorkspacesChanged?(workspaces)
        onActiveWorkspaceChanged?(activeWorkspace)
    }
}
