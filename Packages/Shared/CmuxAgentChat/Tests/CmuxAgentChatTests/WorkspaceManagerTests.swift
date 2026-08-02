import XCTest
@testable import CmuxAgentChat

final class WorkspaceManagerTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var testFileURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentStudioTests_\(UUID().uuidString)", isDirectory: true)
        testFileURL = tempDirectoryURL.appendingPathComponent("workspaces.json", isDirectory: false)
    }

    override func tearDown() {
        if FileManager.default.fileExists(atPath: tempDirectoryURL.path) {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    // MARK: - WorkspaceStorage Tests

    func testWorkspaceStorageLoadEmptyFile() throws {
        let storage = WorkspaceStorage(fileURL: testFileURL)
        let loadedData = try storage.loadData()
        XCTAssertEqual(loadedData.version, 1)
        XCTAssertNil(loadedData.activeWorkspaceId)
        XCTAssertTrue(loadedData.workspaces.isEmpty)
    }

    func testWorkspaceStorageSaveAndLoad() throws {
        let storage = WorkspaceStorage(fileURL: testFileURL)

        let agent1 = AgentSeatConfig(
            id: "agent-1",
            name: "Claude Architect",
            cliProvider: .claude,
            role: "Architect",
            characterId: "char_0",
            seatIndex: 0,
            state: .idle
        )

        let workspace1 = AgentStudioWorkspaceConfig(
            id: "ws-1",
            name: "Test Workspace",
            path: "/tmp/project",
            theme: "office",
            agents: [agent1]
        )

        let dataToSave = AgentStudioWorkspaceData(
            version: 1,
            activeWorkspaceId: "ws-1",
            workspaces: [workspace1]
        )

        try storage.saveData(dataToSave)

        let reloadedData = try storage.loadData()
        XCTAssertEqual(reloadedData.version, 1)
        XCTAssertEqual(reloadedData.activeWorkspaceId, "ws-1")
        XCTAssertEqual(reloadedData.workspaces.count, 1)

        let reloadedWS = reloadedData.workspaces[0]
        XCTAssertEqual(reloadedWS.id, "ws-1")
        XCTAssertEqual(reloadedWS.name, "Test Workspace")
        XCTAssertEqual(reloadedWS.path, "/tmp/project")
        XCTAssertEqual(reloadedWS.agents.count, 1)
        XCTAssertEqual(reloadedWS.agents[0].id, "agent-1")
        XCTAssertEqual(reloadedWS.agents[0].cliProvider, .claude)
    }

    // MARK: - AgentStudioWorkspaceManager Tests

    @MainActor
    func testWorkspaceManagerInitialLoadCreatesDefaultWorkspace() throws {
        let storage = WorkspaceStorage(fileURL: testFileURL)
        let manager = AgentStudioWorkspaceManager(storage: storage)

        manager.loadWorkspaces()

        XCTAssertEqual(manager.workspaces.count, 1)
        XCTAssertNotNil(manager.activeWorkspaceId)
        XCTAssertEqual(manager.activeWorkspace?.name, "Default Workspace")
        XCTAssertEqual(manager.activeWorkspace?.agents.count, 3)

        // Verify persisted to disk
        let savedOnDisk = try storage.loadData()
        XCTAssertEqual(savedOnDisk.workspaces.count, 1)
    }

    @MainActor
    func testWorkspaceManagerCreateAndSwitchWorkspace() throws {
        let storage = WorkspaceStorage(fileURL: testFileURL)
        let manager = AgentStudioWorkspaceManager(storage: storage)
        manager.loadWorkspaces()

        let newWS = try manager.createWorkspace(name: "Backend Service", path: "/dev/backend", theme: "cyberpunk")
        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(newWS.name, "Backend Service")

        try manager.switchWorkspace(to: newWS.id)
        XCTAssertEqual(manager.activeWorkspaceId, newWS.id)
        XCTAssertEqual(manager.activeWorkspace?.name, "Backend Service")

        // Verify invalid switch throws error
        XCTAssertThrowsError(try manager.switchWorkspace(to: "non-existent-id"))
    }

    @MainActor
    func testWorkspaceManagerDeleteWorkspace() throws {
        let storage = WorkspaceStorage(fileURL: testFileURL)
        let manager = AgentStudioWorkspaceManager(storage: storage)
        manager.loadWorkspaces()

        let ws = try manager.createWorkspace(name: "Temporary WS", path: "/tmp/ws")
        let wsId = ws.id
        try manager.switchWorkspace(to: wsId)
        XCTAssertEqual(manager.activeWorkspaceId, wsId)

        try manager.deleteWorkspace(id: wsId)
        XCTAssertNil(manager.workspaces.first(where: { $0.id == wsId }))
        XCTAssertNotEqual(manager.activeWorkspaceId, wsId)
    }

    @MainActor
    func testWorkspaceManagerAgentOperations() throws {
        let storage = WorkspaceStorage(fileURL: testFileURL)
        let manager = AgentStudioWorkspaceManager(storage: storage)
        manager.loadWorkspaces()

        guard let wsId = manager.activeWorkspaceId else {
            XCTFail("Active workspace should exist")
            return
        }

        // Add Agent
        let addedAgent = try manager.addAgent(
            toWorkspaceId: wsId,
            name: "QA Runner",
            cliProvider: .antigravity,
            role: "QA",
            characterId: "char_3",
            seatIndex: 3
        )
        XCTAssertEqual(addedAgent.name, "QA Runner")
        XCTAssertEqual(addedAgent.cliProvider, .antigravity)
        XCTAssertEqual(addedAgent.seatIndex, 3)

        // Try adding to occupied seat
        XCTAssertThrowsError(try manager.addAgent(
            toWorkspaceId: wsId,
            name: "Duplicated Seat Agent",
            cliProvider: .claude,
            seatIndex: 3
        ))

        // Update Agent State
        try manager.updateAgentState(workspaceId: wsId, agentId: addedAgent.id, state: .activeType)
        let updatedWS = manager.activeWorkspace
        let updatedAgent = updatedWS?.agents.first(where: { $0.id == addedAgent.id })
        XCTAssertEqual(updatedAgent?.state, .activeType)

        // Assign Seat
        try manager.assignSeat(workspaceId: wsId, agentId: addedAgent.id, seatIndex: 4)
        let movedAgent = manager.activeWorkspace?.agents.first(where: { $0.id == addedAgent.id })
        XCTAssertEqual(movedAgent?.seatIndex, 4)

        // Remove Agent
        try manager.removeAgent(fromWorkspaceId: wsId, agentId: addedAgent.id)
        XCTAssertNil(manager.activeWorkspace?.agents.first(where: { $0.id == addedAgent.id }))
    }

    // MARK: - PTYBinding Tests

    @MainActor
    func testPTYBindingCommandLineGenerator() {
        XCTAssertEqual(PTYBinding.generateCommandLine(for: .claude), "claude")
        XCTAssertEqual(PTYBinding.generateCommandLine(for: .codex), "codex")
        XCTAssertEqual(PTYBinding.generateCommandLine(for: .antigravity), "antigravity")

        let withOptions = PTYBinding.generateCommandLine(for: .claude, options: ["--dangerously-skip-permissions", "--verbose"])
        XCTAssertEqual(withOptions, "claude --dangerously-skip-permissions --verbose")

        let args = PTYBinding.generateArguments(for: .codex, options: ["--model", "gpt-4o"])
        XCTAssertEqual(args, ["codex", "--model", "gpt-4o"])
    }

    @MainActor
    func testPTYBindingRegistryAndRouting() {
        let binding = PTYBinding()

        binding.bind(agentId: "agent-100", seatIndex: 2, terminalSessionId: "pty-session-1")

        XCTAssertEqual(binding.terminalSessionId(forAgentId: "agent-100"), "pty-session-1")
        XCTAssertEqual(binding.terminalSessionId(forSeatIndex: 2), "pty-session-1")
        XCTAssertEqual(binding.agentId(forTerminalSessionId: "pty-session-1"), "agent-100")

        var focusedSessionId: String?
        binding.onFocusTerminalRequested = { sessionId in
            focusedSessionId = sessionId
        }

        let agent1 = AgentSeatConfig(id: "agent-100", name: "Claude", cliProvider: .claude, seatIndex: 2)
        let agent2 = AgentSeatConfig(id: "agent-200", name: "Codex", cliProvider: .codex, seatIndex: 5)
        let ws = AgentStudioWorkspaceConfig(id: "ws-1", name: "WS", path: "/tmp/proj", agents: [agent1, agent2])

        // Selected existing bound agent -> trigger focus
        binding.handleAgentSelected(agentId: "agent-100", in: ws)
        XCTAssertEqual(focusedSessionId, "pty-session-1")

        // Selected seat 2 -> trigger focus
        focusedSessionId = nil
        binding.handleSeatSelected(seatIndex: 2, in: ws)
        XCTAssertEqual(focusedSessionId, "pty-session-1")

        // Selected unbound agent -> trigger spawn callback
        var spawnedAgent: AgentSeatConfig?
        var spawnedCommand: String?
        var spawnedCwd: String?

        binding.onSpawnTerminalRequested = { agent, command, cwd in
            spawnedAgent = agent
            spawnedCommand = command
            spawnedCwd = cwd
        }

        binding.handleAgentSelected(agentId: "agent-200", in: ws)
        XCTAssertEqual(spawnedAgent?.id, "agent-200")
        XCTAssertEqual(spawnedCommand, "codex")
        XCTAssertEqual(spawnedCwd, "/tmp/proj")

        // Unbind
        binding.unbind(agentId: "agent-100")
        XCTAssertNil(binding.terminalSessionId(forAgentId: "agent-100"))
        XCTAssertNil(binding.terminalSessionId(forSeatIndex: 2))
    }
}
