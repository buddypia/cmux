import Foundation

/// Manages Auto Pilot Mode and Autonomous Continuation for AI CLI agents in Agent Studio.
public final class AutoPilotManager: @unchecked Sendable {
    private let lock = NSLock()
    private var isAutoPilotEnabled: [String: Bool] = [:]
    private var autoContinuePrompts: [String: String] = [:]

    public var onAutoContinueTriggered: ((String, String) -> Void)?

    public init() {}

    /// Check if Auto Pilot Mode is enabled for a specific agent ID.
    public func isEnabled(forAgentId id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAutoPilotEnabled[id] ?? false
    }

    /// Toggle or set Auto Pilot Mode for a specific agent ID.
    public func setAutoPilot(enabled: Bool, forAgentId id: String) {
        lock.lock()
        isAutoPilotEnabled[id] = enabled
        lock.unlock()
    }

    /// Default prompt to inject when Auto Pilot mode automatically continues an agent turn.
    public func defaultAutoContinuePrompt() -> String {
        return "Continue with the current task. Follow existing requirements and tests."
    }

    /// Evaluate if an auto-continue prompt should be triggered on agent task completion.
    public func handleTaskCompletion(forAgentId id: String, state: AgentState) {
        lock.lock()
        let enabled = isAutoPilotEnabled[id] ?? false
        let prompt = autoContinuePrompts[id] ?? defaultAutoContinuePrompt()
        lock.unlock()

        if enabled && state == .done {
            onAutoContinueTriggered?(id, prompt)
        }
    }
}
