import XCTest
@testable import CmuxAgentChat

@MainActor
final class LogMonitorTests: XCTestCase {

    var tempFileURL: URL!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
        tempFileURL = tempDir.appendingPathComponent("log_monitor_test_\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        if let url = tempFileURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    func testLogMonitorReadsInitialLines() throws {
        let initialLines = """
        {"kind":"user_prompt","text":"Start task"}
        {"kind":"tool_start","toolName":"view_file","toolCallId":"c1"}

        """
        try initialLines.write(to: tempFileURL, atomically: true, encoding: .utf8)

        let monitor = LogMonitor(filePath: tempFileURL.path, readFromBeginning: true)
        
        let expectation = self.expectation(description: "Events parsed")
        var count = 0

        monitor.onEventParsed = { event in
            count += 1
            if count == 2 {
                expectation.fulfill()
            }
        }

        monitor.startMonitoring()

        wait(for: [expectation], timeout: 2.0)
        monitor.stopMonitoring()

        XCTAssertEqual(count, 2)
    }

    func testLogMonitorTailsAppendedLinesAndDrivesFSM() throws {
        // Create initial empty file
        try "".write(to: tempFileURL, atomically: true, encoding: .utf8)

        let fsm = AgentFSM(doneAutoResetDelay: 0)
        let monitor = LogMonitor(filePath: tempFileURL.path, readFromBeginning: true)

        let expectation = self.expectation(description: "FSM transitions received")
        var fsmStates: [AgentState] = []

        fsm.onStateChange = { newState, _ in
            fsmStates.append(newState)
            if fsmStates.count == 4 {
                expectation.fulfill()
            }
        }

        monitor.onEventParsed = { event in
            fsm.handle(event: event)
        }

        monitor.startMonitoring()

        // Append lines incrementally to simulate live transcript tailing
        let fileHandle = try FileHandle(forWritingTo: tempFileURL)

        let line1 = "{\"kind\":\"user_prompt\",\"text\":\"Implement feature\"}\n"
        fileHandle.write(line1.data(using: .utf8)!)

        let line2 = "{\"kind\":\"tool_start\",\"toolName\":\"view_file\",\"toolCallId\":\"c10\"}\n"
        fileHandle.write(line2.data(using: .utf8)!)

        let line3 = "{\"kind\":\"tool_start\",\"toolName\":\"replace_file_content\",\"toolCallId\":\"c11\"}\n"
        fileHandle.write(line3.data(using: .utf8)!)

        let line4 = "{\"kind\":\"turn_end\"}\n"
        fileHandle.write(line4.data(using: .utf8)!)

        try fileHandle.close()

        // Force manual check if dispatch source event takes time in unit test environment
        monitor.readPendingContent()

        wait(for: [expectation], timeout: 3.0)
        monitor.stopMonitoring()

        XCTAssertEqual(fsmStates, [.walk, .activeRead, .activeType, .done])
    }
}
