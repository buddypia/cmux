import Foundation

/// Binds 2D SpriteKit seat and agent nodes in `AgentStudioScene` to native PTY terminal surfaces in cmux.
@MainActor
public final class PTYBinding {
    /// Maps agent ID to PTY terminal session identifier.
    public private(set) var agentToTerminalSession: [String: String] = [:]

    /// Maps seat index (0...5) to PTY terminal session identifier.
    public private(set) var seatToTerminalSession: [Int: String] = [:]

    /// Maps PTY terminal session identifier to agent ID.
    public private(set) var terminalSessionToAgent: [String: String] = [:]

    /// Callback requesting focus for an existing PTY terminal session ID.
    public var onFocusTerminalRequested: ((_ terminalSessionId: String) -> Void)?

    /// Callback requesting spawning of a new CLI session for an agent seat.
    public var onSpawnTerminalRequested: ((_ agent: AgentSeatConfig, _ command: String, _ workingDirectory: String) -> Void)?

    public init() {}

    // MARK: - CLI Launcher Command Generator

    /// Generate full command line string for spawning an Agent CLI session.
    public static func generateCommandLine(
        for provider: AgentCLIProvider,
        options: [String] = []
    ) -> String {
        let baseExecutable = provider.defaultExecutable
        if options.isEmpty {
            return baseExecutable
        } else {
            return "\(baseExecutable) \(options.joined(separator: " "))"
        }
    }

    /// Generate command line argument array for spawning an Agent CLI session.
    public static func generateArguments(
        for provider: AgentCLIProvider,
        options: [String] = []
    ) -> [String] {
        var args = [provider.defaultExecutable]
        args.append(contentsOf: options)
        return args
    }

    // MARK: - Session Binding Registry

    /// Bind an agent seat to a PTY terminal session ID.
    public func bind(agentId: String, seatIndex: Int, terminalSessionId: String) {
        agentToTerminalSession[agentId] = terminalSessionId
        seatToTerminalSession[seatIndex] = terminalSessionId
        terminalSessionToAgent[terminalSessionId] = agentId
    }

    /// Unbind an agent seat.
    public func unbind(agentId: String) {
        guard let session = agentToTerminalSession.removeValue(forKey: agentId) else { return }
        terminalSessionToAgent.removeValue(forKey: session)
        for (seat, sId) in seatToTerminalSession where sId == session {
            seatToTerminalSession.removeValue(forKey: seat)
        }
    }

    /// Query bound terminal session ID for an agent ID.
    public func terminalSessionId(forAgentId agentId: String) -> String? {
        return agentToTerminalSession[agentId]
    }

    /// Query bound terminal session ID for a seat index.
    public func terminalSessionId(forSeatIndex seatIndex: Int) -> String? {
        return seatToTerminalSession[seatIndex]
    }

    /// Query bound agent ID for a terminal session ID.
    public func agentId(forTerminalSessionId terminalSessionId: String) -> String? {
        return terminalSessionToAgent[terminalSessionId]
    }

    // MARK: - Selection Event Routing

    /// Handle user selecting an agent character in the SpriteKit scene.
    public func handleAgentSelected(agentId: String, in workspace: AgentStudioWorkspaceConfig) {
        if let terminalSessionId = agentToTerminalSession[agentId] {
            onFocusTerminalRequested?(terminalSessionId)
        } else if let agent = workspace.agents.first(where: { $0.id == agentId }) {
            let command = Self.generateCommandLine(for: agent.cliProvider)
            onSpawnTerminalRequested?(agent, command, workspace.path)
        }
    }

    /// Handle user selecting a desk seat location in the SpriteKit scene.
    public func handleSeatSelected(seatIndex: Int, in workspace: AgentStudioWorkspaceConfig) {
        if let terminalSessionId = seatToTerminalSession[seatIndex] {
            onFocusTerminalRequested?(terminalSessionId)
        } else if let agent = workspace.agents.first(where: { $0.seatIndex == seatIndex }) {
            handleAgentSelected(agentId: agent.id, in: workspace)
        }
    }

    /// Wire scene callbacks to this PTYBinding instance for a given workspace.
    public func attach(to scene: AgentStudioScene, workspace: AgentStudioWorkspaceConfig) {
        scene.onAgentSelected = { [weak self] agentId in
            self?.handleAgentSelected(agentId: agentId, in: workspace)
        }
        scene.onSeatSelected = { [weak self] seatIndex in
            self?.handleSeatSelected(seatIndex: seatIndex, in: workspace)
        }
    }
}
