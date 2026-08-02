import Foundation

/// State of an agent in Agent Studio's finite state machine (FSM).
///
/// Drives the 2D pixel-art visual animations (walk, read at desk, type on PC, thinking, approval bubble, error, done).
public enum AgentState: String, Codable, Sendable, Equatable, CaseIterable {
    case idle = "IDLE"
    case walk = "WALK"
    case activeRead = "ACTIVE_READ"
    case activeType = "ACTIVE_TYPE"
    case thinking = "THINKING"
    case needsApproval = "NEEDS_APPROVAL"
    case error = "ERROR"
    case done = "DONE"

    /// Custom decoder to accept both uppercase ("ACTIVE_READ") and lowercase ("active_read" / "activeRead") formats.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawString = try container.decode(String.self)
        let normalized = rawString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch normalized {
        case "IDLE":
            self = .idle
        case "WALK", "WALKING":
            self = .walk
        case "ACTIVE_READ", "ACTIVE-READ", "READ", "READING":
            self = .activeRead
        case "ACTIVE_TYPE", "ACTIVE-TYPE", "TYPE", "TYPING", "WRITE", "WRITING", "BASH":
            self = .activeType
        case "THINKING", "THINK":
            self = .thinking
        case "NEEDS_APPROVAL", "NEEDS-APPROVAL", "APPROVAL", "WAITING_APPROVAL", "POSSIBLY_STUCK", "POSSIBLYSTUCK":
            self = .needsApproval
        case "ERROR", "FAILED":
            self = .error
        case "DONE", "FINISHED", "COMPLETED":
            self = .done
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown AgentState raw value: \(rawString)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    /// Whether the agent is actively executing work.
    public var isWorking: Bool {
        switch self {
        case .walk, .activeRead, .activeType, .thinking:
            return true
        case .idle, .needsApproval, .error, .done:
            return false
        }
    }

    /// Whether the agent requires user attention or interaction.
    public var needsAttention: Bool {
        return self == .needsApproval || self == .error
    }

    /// Whether the state is a terminal end state before returning to idle.
    public var isTerminal: Bool {
        return self == .done || self == .error
    }

    /// User-facing display name of the agent state.
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .walk: return "Walking"
        case .activeRead: return "Reading File"
        case .activeType: return "Writing Code"
        case .thinking: return "Thinking"
        case .needsApproval: return "Needs Approval"
        case .error: return "Error"
        case .done: return "Turn Complete"
        }
    }

    /// Default action message description.
    public var defaultMessage: String {
        switch self {
        case .idle: return "Waiting for next instruction..."
        case .walk: return "Navigating to desk workspace"
        case .activeRead: return "Reading and analyzing repository files"
        case .activeType: return "Editing code files and running commands"
        case .thinking: return "Reasoning about solution strategy"
        case .needsApproval: return "Waiting for user permission approval"
        case .error: return "Encountered an execution error"
        case .done: return "Finished current task execution turn"
        }
    }
}
