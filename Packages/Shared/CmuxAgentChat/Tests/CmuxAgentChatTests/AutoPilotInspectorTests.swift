import Testing
import Foundation
@testable import CmuxAgentChat

@Suite("AutoPilotManager and Progress Inspector Tests")
struct AutoPilotInspectorTests {

    @Test("AutoPilotManager toggles enable state correctly per agent")
    func testAutoPilotToggle() {
        let manager = AutoPilotManager()
        let agentId = "agent_1"

        #expect(manager.isEnabled(forAgentId: agentId) == false)

        manager.setAutoPilot(enabled: true, forAgentId: agentId)
        #expect(manager.isEnabled(forAgentId: agentId) == true)

        manager.setAutoPilot(enabled: false, forAgentId: agentId)
        #expect(manager.isEnabled(forAgentId: agentId) == false)
    }

    @Test("AutoPilotManager triggers auto-continue callback on task completion when enabled")
    func testAutoContinueTrigger() {
        let manager = AutoPilotManager()
        let agentId = "agent_test"

        var triggeredAgentId: String? = nil
        var triggeredPrompt: String? = nil

        manager.onAutoContinueTriggered = { id, prompt in
            triggeredAgentId = id
            triggeredPrompt = prompt
        }

        manager.setAutoPilot(enabled: true, forAgentId: agentId)
        manager.handleTaskCompletion(forAgentId: agentId, state: .done)

        #expect(triggeredAgentId == agentId)
        #expect(triggeredPrompt != nil)
    }
}
