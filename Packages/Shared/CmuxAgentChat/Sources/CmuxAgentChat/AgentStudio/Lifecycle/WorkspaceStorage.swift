import Foundation

/// CLI provider enum representing supported AI CLI tools.
public enum AgentCLIProvider: String, Codable, CaseIterable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case antigravity = "antigravity"

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity Agent"
        }
    }

    public var defaultExecutable: String {
        return self.rawValue
    }
}

/// Agent seat configuration inside a workspace.
public struct AgentSeatConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var cliProvider: AgentCLIProvider
    public var role: String
    public var characterId: String
    public var seatIndex: Int
    public var state: AgentState
    public var transcriptPath: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        cliProvider: AgentCLIProvider,
        role: String = "Developer",
        characterId: String = "char_0",
        seatIndex: Int = 0,
        state: AgentState = .idle,
        transcriptPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cliProvider = cliProvider
        self.role = role
        self.characterId = characterId
        self.seatIndex = seatIndex
        self.state = state
        self.transcriptPath = transcriptPath
    }
}

/// Configuration for a single multi-agent workspace.
public struct AgentStudioWorkspaceConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var theme: String
    public var agents: [AgentSeatConfig]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        theme: String = "office",
        agents: [AgentSeatConfig] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.theme = theme
        self.agents = agents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Top-level workspace storage wrapper for `~/.agent-studio/workspaces.json`.
public struct AgentStudioWorkspaceData: Codable, Equatable, Sendable {
    public var version: Int
    public var activeWorkspaceId: String?
    public var workspaces: [AgentStudioWorkspaceConfig]

    public init(
        version: Int = 1,
        activeWorkspaceId: String? = nil,
        workspaces: [AgentStudioWorkspaceConfig] = []
    ) {
        self.version = version
        self.activeWorkspaceId = activeWorkspaceId
        self.workspaces = workspaces
    }
}

/// Manages native persistence of multi-workspace configuration in `~/.agent-studio/workspaces.json`.
public final class WorkspaceStorage: Sendable {
    public let fileURL: URL

    public static var defaultFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".agent-studio", isDirectory: true)
            .appendingPathComponent("workspaces.json", isDirectory: false)
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    /// Load workspaces data from disk. If the file does not exist, returns a default empty data struct.
    public func loadData() throws -> AgentStudioWorkspaceData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AgentStudioWorkspaceData()
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentStudioWorkspaceData.self, from: data)
    }

    /// Persist workspaces data to disk, automatically creating parent directories if needed.
    public func saveData(_ data: AgentStudioWorkspaceData) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encodedData = try encoder.encode(data)
        try encodedData.write(to: fileURL, options: .atomic)
    }
}
