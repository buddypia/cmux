import XCTest
@testable import CMUXAgentLaunch

final class AntigravitySessionResolverTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testInferredAntigravitySessionFromLastConversations() throws {
        let geminiDir = tempDirectory.appendingPathComponent(".gemini/antigravity-cli/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        let workspacePath = tempDirectory.appendingPathComponent("my-workspace").path
        let expectedSessionId = "b551fe55-6041-4dbf-87db-b2129a781b57"
        let jsonContent = """
        {
          "\(workspacePath)": "\(expectedSessionId)"
        }
        """
        let jsonFile = geminiDir.appendingPathComponent("last_conversations.json")
        try jsonContent.write(to: jsonFile, atomically: true, encoding: .utf8)

        let env = ["HOME": tempDirectory.path]
        let resolver = AntigravitySessionResolver()
        let result = resolver.inferredAntigravitySession(cwd: workspacePath, env: env)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, expectedSessionId)
        XCTAssertEqual(result?.source, "last_conversations.json")
    }

    func testInferredAntigravitySessionFromHistoryJsonl() throws {
        let geminiDir = tempDirectory.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        let workspacePath = tempDirectory.appendingPathComponent("my-workspace").path
        let expectedSessionId = "11111111-2222-3333-4444-555555555555"
        let jsonlContent = """
        {"display":"hello","timestamp":1000,"workspace":"\(workspacePath)","conversationId":"old-session-id"}
        {"display":"world","timestamp":2000,"workspace":"\(workspacePath)","conversationId":"\(expectedSessionId)"}
        """
        let jsonlFile = geminiDir.appendingPathComponent("history.jsonl")
        try jsonlContent.write(to: jsonlFile, atomically: true, encoding: .utf8)

        let env = ["HOME": tempDirectory.path]
        let resolver = AntigravitySessionResolver()
        let result = resolver.inferredAntigravitySession(cwd: workspacePath, env: env)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionId, expectedSessionId)
        XCTAssertEqual(result?.source, "history.jsonl")
    }
}
