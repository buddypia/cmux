import Foundation

/// A transcript-derived live state transition that is not a chat row.
///
/// Some CLIs emit lifecycle events such as "task started" without producing
/// visible transcript content. These updates let producers keep
/// ``ChatAgentState`` honest without adding synthetic bubbles.
public struct ChatTranscriptStateUpdate: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case working
        case needsInput = "needs_input"
        case inputResolved = "input_resolved"
        case idle
    }

    public let kind: Kind
    public let seq: Int
    public let timestamp: Date

    public init(kind: Kind, seq: Int, timestamp: Date) {
        self.kind = kind
        self.seq = seq
        self.timestamp = timestamp
    }

    /// Returns updates in the same order they should affect live session state.
    public static func applicationOrder(_ updates: [Self]) -> [Self] {
        updates.sorted { lhs, rhs in
            if lhs.seq == rhs.seq {
                if lhs.timestamp == rhs.timestamp {
                    return lhs.kind.applicationOrderRank < rhs.kind.applicationOrderRank
                }
                return lhs.timestamp < rhs.timestamp
            }

            return lhs.seq < rhs.seq
        }
    }

    public static func latest(in updates: [Self]) -> Self? {
        applicationOrder(updates).last
    }
}

private extension ChatTranscriptStateUpdate.Kind {
    var applicationOrderRank: Int {
        switch self {
        case .working: return 0
        case .needsInput: return 1
        case .inputResolved: return 2
        case .idle: return 3
        }
    }
}
