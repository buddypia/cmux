import XCTest
@testable import CmuxAgentChat

final class AgentFSMTests: XCTestCase {

    func testInitialStateIsIdle() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        XCTAssertEqual(fsm.currentState, .idle)
    }

    func testUserPromptTransitionsToWalk() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        let event = CanonicalEvent(kind: .userPrompt, text: "Build the app")
        
        let state = fsm.handle(event: event)
        XCTAssertEqual(state, .walk)
        XCTAssertEqual(fsm.currentState, .walk)
    }

    func testReadToolStartTransitionsToActiveRead() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        
        let event1 = CanonicalEvent(kind: .toolStart, toolCallId: "c1", toolName: "view_file")
        let state1 = fsm.handle(event: event1)
        XCTAssertEqual(state1, .activeRead)

        let event2 = CanonicalEvent(kind: .toolStart, toolCallId: "c2", toolName: "grep_search")
        let state2 = fsm.handle(event: event2)
        XCTAssertEqual(state2, .activeRead)
    }

    func testTypeToolStartTransitionsToActiveType() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        
        let event1 = CanonicalEvent(kind: .toolStart, toolCallId: "c1", toolName: "replace_file_content")
        let state1 = fsm.handle(event: event1)
        XCTAssertEqual(state1, .activeType)

        let event2 = CanonicalEvent(kind: .toolStart, toolCallId: "c2", toolName: "run_command")
        let state2 = fsm.handle(event: event2)
        XCTAssertEqual(state2, .activeType)
    }

    func testThinkingTransitionsToThinking() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        let event = CanonicalEvent(kind: .thinking, text: "Designing logic...")
        
        let state = fsm.handle(event: event)
        XCTAssertEqual(state, .thinking)
    }

    func testPermissionRequiredTransitionsToNeedsApproval() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        let event = CanonicalEvent(kind: .permissionRequired, toolName: "run_command")
        
        let state = fsm.handle(event: event)
        XCTAssertEqual(state, .needsApproval)
        XCTAssertTrue(state.needsAttention)
    }

    func testErrorTransitionsToError() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        let event = CanonicalEvent(kind: .error, text: "Build failed")
        
        let state = fsm.handle(event: event)
        XCTAssertEqual(state, .error)
        XCTAssertTrue(state.isTerminal)
    }

    func testTurnEndTransitionsToDone() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        let event = CanonicalEvent(kind: .turnEnd)
        
        let state = fsm.handle(event: event)
        XCTAssertEqual(state, .done)
        XCTAssertTrue(state.isTerminal)
    }

    func testSessionClearResetsToIdle() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        fsm.handle(event: CanonicalEvent(kind: .toolStart, toolName: "run_command"))
        XCTAssertEqual(fsm.currentState, .activeType)

        let state = fsm.handle(event: CanonicalEvent(kind: .sessionClear))
        XCTAssertEqual(state, .idle)
    }

    func testStateChangeCallbackIsInvoked() {
        let fsm = AgentFSM(doneAutoResetDelay: 0)
        var recordedStates: [AgentState] = []
        
        fsm.onStateChange = { newState, _ in
            recordedStates.append(newState)
        }

        fsm.handle(event: CanonicalEvent(kind: .userPrompt, text: "Hello"))
        fsm.handle(event: CanonicalEvent(kind: .toolStart, toolName: "view_file"))
        fsm.handle(event: CanonicalEvent(kind: .toolStart, toolName: "replace_file_content"))
        fsm.handle(event: CanonicalEvent(kind: .turnEnd))

        XCTAssertEqual(recordedStates, [.walk, .activeRead, .activeType, .done])
    }

    func testAgentStateHelpers() {
        XCTAssertTrue(AgentState.activeRead.isWorking)
        XCTAssertTrue(AgentState.activeType.isWorking)
        XCTAssertTrue(AgentState.thinking.isWorking)
        XCTAssertFalse(AgentState.idle.isWorking)
        XCTAssertFalse(AgentState.needsApproval.isWorking)
        XCTAssertTrue(AgentState.needsApproval.needsAttention)
        XCTAssertTrue(AgentState.error.needsAttention)
    }
}
