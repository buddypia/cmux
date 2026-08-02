import Testing
import Foundation
@testable import CmuxAgentChat

@MainActor
@Suite("AgentStudioViewModel Tests")
struct AgentStudioViewModelTests {

    @Test("ViewModel selects agent and updates properties correctly")
    func testAgentSelection() {
        let scene = AgentStudioScene()
        let autoPilot = AutoPilotManager()
        let vm = AgentStudioViewModel(scene: scene, autoPilotManager: autoPilot)

        let agentId = "agent_100"
        autoPilot.setAutoPilot(enabled: true, forAgentId: agentId)

        #expect(vm.selectedAgentId == nil)
        #expect(vm.isAutoPilotEnabled == false)

        vm.selectAgent(id: agentId)

        #expect(vm.selectedAgentId == agentId)
        #expect(vm.isAutoPilotEnabled == true)

        vm.selectAgent(id: nil)

        #expect(vm.selectedAgentId == nil)
        #expect(vm.isAutoPilotEnabled == false)
    }

    @Test("ViewModel appends and limits log event buffer size")
    func testLogEventBuffer() {
        let scene = AgentStudioScene()
        let vm = AgentStudioViewModel(scene: scene)

        for i in 0..<25 {
            let event = CanonicalEvent(
                id: "event_\(i)",
                kind: .text,
                text: "Summary \(i)"
            )
            vm.appendLogEvent(event)
        }

        #expect(vm.recentEvents.count == 20)
        #expect(vm.recentEvents.first?.id == "event_24")
    }
}
