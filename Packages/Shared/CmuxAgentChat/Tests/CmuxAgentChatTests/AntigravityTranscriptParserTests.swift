import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixtures cover the Antigravity transcript shapes cmux observes through
/// `transcriptPath`: loose JSONL message rows plus native hook lifecycle rows.
@Suite("AntigravityTranscriptParser")
struct AntigravityTranscriptParserTests {
    private let parser = AntigravityTranscriptParser()

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func messageLine(
        role: String,
        content: Any,
        id: String,
        timestamp: String = "2026-06-20T06:30:01.000Z"
    ) -> String {
        Self.json([
            "id": id,
            "timestamp": timestamp,
            "message": [
                "role": role,
                "content": content,
            ],
        ])
    }

    private func hookLine(_ event: String, _ fields: [String: Any]) -> String {
        var object = fields
        object["hook_event_name"] = event
        object["timestamp"] = object["timestamp"] ?? "2026-06-20T06:31:01.000Z"
        return Self.json(object)
    }

    @Test("user and assistant message rows map to prose and drop injected context")
    func proseMapping() {
        let lines = [
            messageLine(
                role: "user",
                content: "<environment_context>\n  <cwd>/repo</cwd>\n</environment_context>",
                id: "noise"
            ),
            messageLine(role: "user", content: "Update the release notes", id: "u-1"),
            messageLine(
                role: "assistant",
                content: [["type": "text", "text": "I updated the release notes."]],
                id: "a-1"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 10)

        #expect(result.messages.count == 2)
        #expect(result.messages[0].id == "u-1")
        #expect(result.messages[0].seq == 11)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Update the release notes")))
        #expect(result.messages[1].id == "a-1")
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "I updated the release notes.")))
    }

    @Test("assistant output_text and reasoning blocks map to prose and thought")
    func outputTextAndReasoning() {
        let line = messageLine(
            role: "model",
            content: [
                ["type": "reasoning", "text": "Check the failing test first"],
                ["type": "output_text", "text": "The fix is ready."],
            ],
            id: "model-1"
        )

        let result = parser.parse(lines: [line], startingSeq: 0)

        #expect(result.messages.count == 2)
        #expect(result.messages[0].kind == .thought(ChatThought(text: "Check the failing test first")))
        #expect(result.messages[1].kind == .prose(ChatProse(text: "The fix is ready.")))
    }

    @Test("SessionStart rows map to lifecycle status with workspace detail")
    func sessionStart() {
        let line = hookLine("SessionStart", [
            "conversationId": "agy-session-1",
            "workspacePaths": ["/repo"],
        ])

        let result = parser.parse(lines: [line], startingSeq: 3)

        #expect(result.messages.count == 1)
        #expect(result.messages[0].role == .system)
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(event: .sessionStarted, detail: "/repo")
        ))
    }

    @Test("PreToolUse run_command maps to a terminal and PostToolUse completes it")
    func toolLifecycleSameCall() {
        let lines = [
            hookLine("PreToolUse", [
                "toolCall": [
                    "id": "tool-1",
                    "name": "run_command",
                    "args": ["command": "swift test"],
                ],
            ]),
            hookLine("PostToolUse", [
                "toolCall": ["id": "tool-1", "name": "run_command"],
                "toolResult": [
                    "output": "Process exited with code 0\nOutput:\nTest Suite passed",
                    "durationSeconds": 1.25,
                ],
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].id == "tool-1")
        #expect(capture.command == "swift test")
        #expect(capture.output?.contains("Test Suite passed") == true)
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 1.25)
        #expect(!capture.isRunning)
    }

    @Test("PostToolUse in a later parse call re-emits the completed tool")
    func toolLifecycleAcrossCalls() {
        let first = parser.parse(
            lines: [
                hookLine("PreToolUse", [
                    "tool_name": "read_file",
                    "tool_input": ["path": "README.md"],
                    "tool_call_id": "read-1",
                ]),
            ],
            startingSeq: 20
        )
        #expect(first.state.pendingToolUses.count == 1)

        let second = parser.parse(
            lines: [
                hookLine("PostToolUse", [
                    "tool_call_id": "read-1",
                    "toolResult": ["output": "# README"],
                ]),
            ],
            startingSeq: 21,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        let updated = second.updatedMessages[0]
        #expect(updated.id == "read-1")
        #expect(updated.seq == 20)
        guard case .toolUse(let tool) = updated.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "read_file")
        #expect(tool.summary == "read_file README.md")
        #expect(tool.output == "# README")
        #expect(tool.status == .succeeded)
    }
}
