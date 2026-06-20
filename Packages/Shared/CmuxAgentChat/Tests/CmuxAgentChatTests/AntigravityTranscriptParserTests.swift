import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixtures cover the Antigravity transcript shapes cmux observes through
/// `transcriptPath`: current role/parts JSONL rows, loose message rows, and
/// native hook lifecycle rows.
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

    @Test("current agy metadata JSONL maps to session start")
    func currentAgyMetadata() {
        let line = Self.json([
            "sessionId": "current-agy-session",
            "projectHash": "project-hash",
            "startTime": "2026-06-12T00:00:00.000Z",
            "lastUpdated": "2026-06-12T00:00:00.000Z",
            "kind": "main",
        ])

        let result = parser.parse(lines: [line], startingSeq: 4)

        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "current-agy-session")
        #expect(result.messages[0].role == .system)
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(event: .sessionStarted, detail: nil)
        ))
    }

    @Test("current agy gemini JSONL maps content thoughts and completed tool calls")
    func currentAgyGeminiMessage() {
        let line = Self.json([
            "id": "msg-gemini-1",
            "timestamp": "2026-06-12T00:00:02.000Z",
            "type": "gemini",
            "content": "done",
            "thoughts": [
                ["subject": "plan", "description": "thinking step 1"],
                ["subject": "plan", "description": "thinking step 2"],
            ],
            "toolCalls": [
                [
                    "id": "run_shell_command_1",
                    "name": "run_shell_command",
                    "args": ["command": "pwd"],
                    "status": "success",
                    "timestamp": "2026-06-12T00:00:02.000Z",
                ],
            ],
            "model": "gemini-3.1-pro-preview",
        ])

        let result = parser.parse(lines: [line], startingSeq: 5)

        #expect(result.messages.count == 4)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "done")))
        #expect(result.messages[1].kind == .thought(ChatThought(text: "thinking step 1")))
        #expect(result.messages[2].kind == .thought(ChatThought(text: "thinking step 2")))
        guard case .terminal(let capture) = result.messages[3].kind else {
            Issue.record("expected current agy toolCall to map to terminal")
            return
        }
        #expect(result.messages[3].id == "run_shell_command_1")
        #expect(capture.command == "pwd")
        #expect(!capture.isRunning)
        #expect(capture.exitCode == 0)
    }

    @Test("current role/parts JSONL maps a typical Antigravity turn")
    func rolePartsTypicalTurn() {
        let lines = [
            Self.json([
                "role": "event",
                "name": "session_metadata",
                "sessionId": "antigravity-session-001",
                "cwd": "/workspace/test-project",
                "cliVersion": "0.37.1",
                "timestamp": "2026-04-10T10:00:00.000Z",
            ]),
            Self.json([
                "role": "user",
                "parts": [["text": "Read the file src/app.ts"]],
                "timestamp": "2026-04-10T10:00:00.500Z",
            ]),
            Self.json([
                "role": "model",
                "parts": [
                    [
                        "functionCall": [
                            "id": "antigravity-call-001",
                            "name": "read_file",
                            "args": ["absolute_path": "/workspace/test-project/src/app.ts"],
                        ],
                    ],
                ],
                "timestamp": "2026-04-10T10:00:01.000Z",
            ]),
            Self.json([
                "role": "tool",
                "parts": [
                    [
                        "functionResponse": [
                            "id": "antigravity-call-001",
                            "name": "read_file",
                            "response": ["output": "const app = () => 'hello';"],
                        ],
                    ],
                ],
                "timestamp": "2026-04-10T10:00:01.500Z",
            ]),
            Self.json([
                "role": "model",
                "parts": [["text": "The file exports a simple function."]],
                "timestamp": "2026-04-10T10:00:02.000Z",
            ]),
            Self.json([
                "role": "event",
                "name": "turn_complete",
                "turnId": "gemini-turn-001",
                "timestamp": "2026-04-10T10:00:02.100Z",
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        #expect(result.messages.count == 4)
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(event: .sessionStarted, detail: "/workspace/test-project")
        ))
        #expect(result.messages[1].role == .user)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "Read the file src/app.ts")))
        guard case .toolUse(let tool) = result.messages[2].kind else {
            Issue.record("expected role/parts functionCall to map to toolUse")
            return
        }
        #expect(result.messages[2].id == "antigravity-call-001")
        #expect(tool.toolName == "read_file")
        #expect(tool.summary == "read_file /workspace/test-project/src/app.ts")
        #expect(tool.output == "const app = () => 'hello';")
        #expect(tool.status == .succeeded)
        #expect(result.messages[3].role == .agent)
        #expect(result.messages[3].kind == .prose(
            ChatProse(text: "The file exports a simple function.")
        ))
    }

    @Test("role/parts thought and functionCall parts emit in transcript order")
    func rolePartsThoughtAndFunctionCall() {
        let lines = [
            Self.json([
                "role": "model",
                "parts": [
                    ["thought": "Let me list the directory first."],
                    [
                        "functionCall": [
                            "id": "antigravity-call-002",
                            "name": "list_directory",
                            "args": ["path": "/workspace/test-project"],
                        ],
                    ],
                ],
                "timestamp": "2026-04-10T10:01:01.000Z",
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 7)

        #expect(result.messages.count == 2)
        #expect(result.messages[0].seq == 7)
        #expect(result.messages[0].kind == .thought(
            ChatThought(text: "Let me list the directory first.")
        ))
        guard case .toolUse(let tool) = result.messages[1].kind else {
            Issue.record("expected role/parts functionCall to map to toolUse")
            return
        }
        #expect(result.messages[1].id == "antigravity-call-002")
        #expect(tool.toolName == "list_directory")
        #expect(tool.summary == "list_directory /workspace/test-project")
    }

    @Test("role event tool authorization maps to a permission request")
    func roleEventToolAuthorizationRequired() {
        let line = Self.json([
            "role": "event",
            "name": "tool_authorization_required",
            "toolCallId": "antigravity-call-010",
            "toolName": "run_shell_command",
            "args": ["command": "rm file.txt"],
            "timestamp": "2026-04-10T10:02:00.000Z",
        ])

        let result = parser.parse(lines: [line], startingSeq: 12)

        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "antigravity-call-010")
        #expect(result.messages[0].role == .system)
        #expect(result.messages[0].kind == .permissionRequest(
            ChatPermissionRequest(
                title: "Antigravity needs approval:",
                subject: "rm file.txt"
            )
        ))
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
