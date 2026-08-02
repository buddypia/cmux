import Foundation

/// Finite state machine managing an agent's lifecycle state for Agent Studio.
///
/// Consumes ``CanonicalEvent`` items and transitions through ``AgentState`` states:
/// `IDLE` -> `WALK` -> `ACTIVE_READ` / `ACTIVE_TYPE` / `THINKING` -> `NEEDS_APPROVAL` -> `DONE` / `ERROR` -> `IDLE`.
public final class AgentFSM: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentState = .idle
    private var activeToolCallIds: Set<String> = []
    private var resetWorkItem: DispatchWorkItem?

    /// Duration in seconds before a `.done` state automatically resets to `.idle`.
    /// Set to `0` or negative to disable automatic timer reset.
    public var doneAutoResetDelay: TimeInterval

    /// Optional callback notified on state changes.
    public var onStateChange: ((AgentState, CanonicalEvent?) -> Void)?

    /// Known tool names classified as read / search operations.
    public var readToolNames: Set<String> = [
        "view_file", "view", "grep_search", "find_by_name", "list_dir",
        "read_file", "read", "cat", "ls", "grep", "find", "glob", "search",
        "code_search", "list_feedback", "get_latest_feedback_context",
        "get_feedback_context", "get_project", "list_projects", "list_screens"
    ]

    /// Known tool names classified as write / edit / execution operations.
    public var typeToolNames: Set<String> = [
        "replace_file_content", "multi_replace_file_content", "write_to_file",
        "run_command", "bash", "edit", "write", "exec", "execute", "terminal",
        "generate_image", "edit_image", "delete_project", "create_project"
    ]

    /// The current state of the agent.
    public var currentState: AgentState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Initialize a new FSM with optional auto-reset delay.
    public init(initialState: AgentState = .idle, doneAutoResetDelay: TimeInterval = 2.0) {
        self.state = initialState
        self.doneAutoResetDelay = doneAutoResetDelay
    }

    /// Process a ``CanonicalEvent`` and perform state transition if applicable.
    @discardableResult
    public func handle(event: CanonicalEvent) -> AgentState {
        lock.lock()
        
        // Cancel any pending done-reset timer
        resetWorkItem?.cancel()
        resetWorkItem = nil

        let oldState = state
        let newState = computeNextState(for: event)
        self.state = newState
        
        lock.unlock()

        if oldState != newState {
            onStateChange?(newState, event)

            if newState == .done && doneAutoResetDelay > 0 {
                scheduleAutoResetToIdle()
            }
        }

        return newState
    }

    /// Manually reset the state machine to `.idle`.
    public func reset() {
        lock.lock()
        resetWorkItem?.cancel()
        resetWorkItem = nil
        activeToolCallIds.removeAll()
        let oldState = state
        state = .idle
        lock.unlock()

        if oldState != .idle {
            onStateChange?(.idle, nil)
        }
    }

    /// Manually force a specific state (useful for testing or direct overrides).
    public func forceState(_ newState: AgentState, event: CanonicalEvent? = nil) {
        lock.lock()
        resetWorkItem?.cancel()
        resetWorkItem = nil
        let oldState = state
        state = newState
        lock.unlock()

        if oldState != newState {
            onStateChange?(newState, event)
            if newState == .done && doneAutoResetDelay > 0 {
                scheduleAutoResetToIdle()
            }
        }
    }

    // MARK: - Transition Logic

    private func computeNextState(for event: CanonicalEvent) -> AgentState {
        switch event.kind {
        case .userPrompt, .turnStart:
            return .walk

        case .thinking:
            return .thinking

        case .toolStart:
            if let toolCallId = event.toolCallId {
                activeToolCallIds.insert(toolCallId)
            }
            let toolName = (event.toolName ?? "").lowercased()
            if isReadTool(toolName) {
                return .activeRead
            } else if isTypeTool(toolName) {
                return .activeType
            } else {
                // Default heuristic: if name contains 'read', 'search', 'get', 'list' -> activeRead, else activeType
                if toolName.contains("read") || toolName.contains("search") || toolName.contains("get") || toolName.contains("list") {
                    return .activeRead
                }
                return .activeType
            }

        case .toolEnd:
            if let toolCallId = event.toolCallId {
                activeToolCallIds.remove(toolCallId)
            }
            if event.status == "error" {
                return .error
            }
            // If tools are still active, remain in active/thinking state, else transition to thinking or walk
            if activeToolCallIds.isEmpty {
                return .thinking
            } else {
                return state
            }

        case .permissionRequired:
            return .needsApproval

        case .error:
            return .error

        case .turnEnd:
            activeToolCallIds.removeAll()
            return .done

        case .sessionClear:
            activeToolCallIds.removeAll()
            return .idle

        case .text:
            // Assistant stream text
            if state == .walk || state == .idle {
                return .thinking
            }
            return state

        case .sessionMeta, .toolProgress, .unknown:
            return state
        }
    }

    private func isReadTool(_ name: String) -> Bool {
        return readToolNames.contains(name) || readToolNames.contains(where: { name.hasPrefix($0) })
    }

    private func isTypeTool(_ name: String) -> Bool {
        return typeToolNames.contains(name) || typeToolNames.contains(where: { name.hasPrefix($0) })
    }

    private func scheduleAutoResetToIdle() {
        let delay = doneAutoResetDelay
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard self.state == .done else {
                self.lock.unlock()
                return
            }
            self.state = .idle
            self.lock.unlock()
            self.onStateChange?(.idle, nil)
        }
        lock.lock()
        self.resetWorkItem = workItem
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
