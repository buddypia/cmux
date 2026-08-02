import XCTest
@testable import CmuxAgentChat

final class CanonicalEventTests: XCTestCase {

    func testCanonicalEventEncodingAndDecoding() throws {
        let event = CanonicalEvent(
            kind: .toolStart,
            ts: 1600000000000,
            sessionId: "test-session-123",
            toolCallId: "call-99",
            toolName: "view_file",
            text: nil,
            role: nil,
            status: nil,
            permissionExempt: false,
            runsAsync: false,
            parameters: ["path": "/tmp/test.swift"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CanonicalEvent.self, from: data)

        XCTAssertEqual(decoded.kind, .toolStart)
        XCTAssertEqual(decoded.sessionId, "test-session-123")
        XCTAssertEqual(decoded.toolCallId, "call-99")
        XCTAssertEqual(decoded.toolName, "view_file")
        XCTAssertEqual(decoded.parameters?["path"], "/tmp/test.swift")
    }

    func testParseLineCanonicalJSON() {
        let jsonLine = """
        {"kind":"tool_start","ts":1700000000000,"sessionId":"s1","toolCallId":"c1","toolName":"replace_file_content"}
        """
        let event = CanonicalEvent.parseLine(jsonLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .toolStart)
        XCTAssertEqual(event?.toolName, "replace_file_content")
        XCTAssertEqual(event?.toolCallId, "c1")
    }

    func testParseLineNativeUserPrompt() {
        let jsonLine = """
        {"type":"user_prompt","text":"Please refactor the FSM module","sessionId":"sess-abc"}
        """
        let event = CanonicalEvent.parseLine(jsonLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .userPrompt)
        XCTAssertEqual(event?.text, "Please refactor the FSM module")
    }

    func testParseLineNativeThinking() {
        let jsonLine = """
        {"type":"thinking","text":"Analyzing file structure..."}
        """
        let event = CanonicalEvent.parseLine(jsonLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .thinking)
        XCTAssertEqual(event?.text, "Analyzing file structure...")
    }

    func testParseLineNativeToolUse() {
        let jsonLine = """
        {"type":"tool_use","id":"call_123","name":"run_command","input":{"command":"swift test"}}
        """
        let event = CanonicalEvent.parseLine(jsonLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .toolStart)
        XCTAssertEqual(event?.toolCallId, "call_123")
        XCTAssertEqual(event?.toolName, "run_command")
        XCTAssertEqual(event?.parameters?["command"], "swift test")
    }

    func testParseLineNativePermissionRequired() {
        let jsonLine = """
        {"type":"permission_required","tool_name":"run_command","tool_call_id":"call_456"}
        """
        let event = CanonicalEvent.parseLine(jsonLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .permissionRequired)
        XCTAssertEqual(event?.toolName, "run_command")
        XCTAssertEqual(event?.toolCallId, "call_456")
    }

    func testParseLineNativeTurnEnd() {
        let jsonLine = """
        {"type":"turn_end"}
        """
        let event = CanonicalEvent.parseLine(jsonLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .turnEnd)
    }

    func testParseLineInvalidJSONReturnsNil() {
        let event = CanonicalEvent.parseLine("NOT_VALID_JSON{{{")
        XCTAssertNil(event)
    }

    func testParseLineNativeToolUseStringifiedArguments() {
        let jsonLine = """
        {"type":"tool_use","id":"call_999","name":"run_command","arguments":"{\\"command\\": \\"swift test\\", \\"cwd\\": \\"/tmp\\"} "}
        """
        let event = CanonicalEvent.parseLine(jsonLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.kind, .toolStart)
        XCTAssertEqual(event?.toolCallId, "call_999")
        XCTAssertEqual(event?.toolName, "run_command")
        XCTAssertEqual(event?.parameters?["command"], "swift test")
        XCTAssertEqual(event?.parameters?["cwd"], "/tmp")
    }
}
