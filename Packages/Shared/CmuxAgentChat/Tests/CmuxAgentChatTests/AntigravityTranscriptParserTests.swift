import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixture lines mirror Antigravity CLI's native
/// `~/.gemini/antigravity-cli/history.jsonl` prompt history.
@Suite("AntigravityTranscriptParser")
struct AntigravityTranscriptParserTests {
    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("matching history records become user prose and preserve line seq")
    func matchingHistoryRecords() {
        let parser = AntigravityTranscriptParser(sessionID: "conversation-a")
        let lines = [
            "{not-json",
            line([
                "conversationId": "conversation-b",
                "display": "wrong conversation",
                "timestamp": 1_779_231_000_000,
            ]),
            line([
                "conversationId": "conversation-a",
                "display": "Implement Antigravity mobile chat",
                "timestamp": 1_779_231_774_516,
            ]),
            line([
                "session_id": "conversation-a",
                "prompt": [
                    ["type": "text", "text": "Wire the transcript tailer"],
                ],
            ]),
            line([
                "conversationId": "conversation-a",
                "display": "   ",
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 10)

        #expect(result.messages.count == 2)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.messages[0].id == "line-12")
        #expect(result.messages[0].seq == 12)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(
            ChatProse(text: "Implement Antigravity mobile chat")
        ))
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_779_231_774.516))
        #expect(result.messages[1].id == "line-13")
        #expect(result.messages[1].seq == 13)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "Wire the transcript tailer")))
        #expect(result.messages[1].timestamp == result.messages[0].timestamp)
        #expect(result.state.lastTimestamp == result.messages[0].timestamp)
    }

    @Test("typed history command records still become user prose")
    func typedHistoryCommandRecords() {
        let parser = AntigravityTranscriptParser(sessionID: "conversation-a")
        let lines = [
            line([
                "conversationId": "conversation-a",
                "display": "/clear",
                "timestamp": 1_781_920_406_196,
                "type": "slash_command",
            ]),
            line([
                "conversationId": "conversation-a",
                "display": "git status --short",
                "timestamp": 1_781_920_407_196,
                "type": "shell",
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 18)

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages.map(\.id) == ["line-18", "line-19"])
        #expect(result.messages.map(\.role) == [.user, .user])
        #expect(result.messages.map(\.kind) == [
            .prose(ChatProse(text: "/clear")),
            .prose(ChatProse(text: "git status --short")),
        ])
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_920_406.196))
        #expect(result.messages[1].timestamp == Date(timeIntervalSince1970: 1_781_920_407.196))
    }

    @Test("session id aliases and string timestamps are accepted")
    func sessionAliasesAndStringTimestamps() {
        let parser = AntigravityTranscriptParser(sessionID: "native-session-123")
        let lines = [
            line([
                "id": "native-session-123",
                "message": "Resume the Antigravity conversation",
                "timestamp": "1779231774516",
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .prose(
            ChatProse(text: "Resume the Antigravity conversation")
        ))
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_779_231_774.516))
    }

    @Test("role/parts JSONL maps user, assistant, thought, and tool turns")
    func rolePartsTranscript() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let lines = [
            line([
                "role": "user",
                "parts": [
                    ["text": "Read src/app.ts"],
                ],
                "timestamp": "2026-06-19T08:00:00Z",
            ]),
            line([
                "role": "model",
                "parts": [
                    ["thought": "I should inspect the file first."],
                    ["text": "I'll read the file and explain it."],
                    [
                        "functionCall": [
                            "id": "call-read",
                            "name": "read_file",
                            "args": ["absolute_path": "src/app.ts"],
                        ],
                    ],
                ],
            ]),
            line([
                "role": "tool",
                "parts": [
                    [
                        "functionResponse": [
                            "id": "call-read",
                            "name": "read_file",
                            "response": ["output": "export const app = 1;"],
                        ],
                    ],
                ],
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 20)

        #expect(result.messages.count == 4)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Read src/app.ts")))
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .thought(ChatThought(text: "I should inspect the file first.")))
        #expect(result.messages[2].role == .agent)
        #expect(result.messages[2].kind == .prose(ChatProse(text: "I'll read the file and explain it.")))
        #expect(result.messages[3].id == "call-read")
        #expect(result.messages[3].kind == .toolUse(ChatToolUse(
            toolName: "read_file",
            summary: "read_file src/app.ts",
            inputDetail: #"{"absolute_path":"src/app.ts"}"#,
            output: "export const app = 1;",
            status: .succeeded
        )))
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_856_000))
        #expect(result.messages[3].timestamp == result.messages[0].timestamp)
    }

    @Test("role/parts tool responses without a pending function call still render completed tools")
    func rolePartsToolResponseFallbackRendersCompletedTool() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let lines = [
            line([
                "role": "tool",
                "timestamp": "2026-06-19T08:00:03Z",
                "parts": [
                    [
                        "functionResponse": [
                            "id": "call-read-only-response",
                            "name": "read_file",
                            "response": [
                                "absolute_path": "src/app.ts",
                                "output": "export const app = 1;",
                            ],
                        ],
                    ],
                ],
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 24)

        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "call-read-only-response")
        #expect(result.messages.first?.seq == 24)
        #expect(result.messages.first?.timestamp == Date(timeIntervalSince1970: 1_781_856_003))
        #expect(tool.toolName == "read_file")
        #expect(tool.summary == "read_file src/app.ts")
        #expect(tool.inputDetail == #"{"absolute_path":"src/app.ts"}"#)
        #expect(tool.output == "export const app = 1;")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("role/parts role aliases map user, model, tool, and event rows")
    func rolePartsRoleAliases() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let lines = [
            line([
                "role": "USER",
                "parts": [
                    ["text": "Run Antigravity checks"],
                ],
                "timestamp": "2026-06-19T08:00:00Z",
            ]),
            line([
                "role": "MODEL",
                "parts": [
                    [
                        "functionCall": [
                            "id": "call-read",
                            "name": "read_file",
                            "args": ["absolute_path": "src/app.ts"],
                        ],
                    ],
                ],
            ]),
            line([
                "role": "TOOL",
                "parts": [
                    [
                        "functionResponse": [
                            "id": "call-read",
                            "name": "read_file",
                            "response": ["output": "export const app = 1;"],
                        ],
                    ],
                ],
            ]),
            line([
                "role": "EVENT",
                "name": "TASK-STARTED",
                "turn_id": "turn-alias",
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 40)

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Run Antigravity checks")))
        #expect(result.messages[1].kind == .toolUse(ChatToolUse(
            toolName: "read_file",
            summary: "read_file src/app.ts",
            inputDetail: #"{"absolute_path":"src/app.ts"}"#,
            output: "export const app = 1;",
            status: .succeeded
        )))
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .working,
                seq: 43,
                timestamp: Date(timeIntervalSince1970: 1_781_856_000)
            ),
        ])
    }

    @Test("role/parts function responses accept formatted output aliases")
    func rolePartsFunctionResponseFormattedOutputAlias() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let lines = [
            line([
                "role": "model",
                "parts": [
                    [
                        "functionCall": [
                            "id": "call-formatted-output",
                            "name": "read_file",
                            "args": ["absolute_path": "src/app.ts"],
                        ],
                    ],
                ],
            ]),
            line([
                "role": "tool",
                "parts": [
                    [
                        "functionResponse": [
                            "id": "call-formatted-output",
                            "name": "read_file",
                            "response": ["formattedOutput": "export const app = 2;"],
                        ],
                    ],
                ],
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 50)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.output == "export const app = 2;")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("role/parts function responses decode JSON string payloads")
    func rolePartsFunctionResponseJSONStringPayload() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:12Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-json-string-response",
                                "name": "run_shell_command",
                                "args": ["command": "swift test --filter JSONStringPayload"],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:15Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-json-string-response",
                                "response": line([
                                    "output": "JSON string payload passed",
                                    "exit_code": 7,
                                    "durationSeconds": 0.25,
                                ]),
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 52
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter JSONStringPayload")
        #expect(capture.output == "JSON string payload passed")
        #expect(capture.exitCode == 7)
        #expect(capture.durationSeconds == 0.25)
        #expect(capture.isRunning == false)
    }

    @Test("role/parts function responses accept plain string payloads")
    func rolePartsFunctionResponsePlainStringPayload() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-plain-string-response",
                                "name": "read_file",
                                "args": ["absolute_path": "src/plain.txt"],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-plain-string-response",
                                "name": "read_file",
                                "response": "plain string payload",
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 54
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.output == "plain string payload")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("role/parts function responses flatten content text fragments")
    func rolePartsFunctionResponseContentFragments() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:12Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-content-fragments",
                                "name": "run_shell_command",
                                "args": ["command": "swift test --filter ContentFragments"],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:16Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-content-fragments",
                                "response": [
                                    "content": [
                                        ["type": "output_text", "text": "first output line"],
                                        ["type": "text", "text": "second output line"],
                                    ],
                                    "exit_code": 0,
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 56
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter ContentFragments")
        #expect(capture.output == "first output line\nsecond output line")
        #expect(capture.exitCode == 0)
        #expect(capture.isRunning == false)
    }

    @Test("role/parts function responses flatten array payload fragments")
    func rolePartsFunctionResponseArrayPayloadFragments() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-array-fragments",
                                "name": "read_file",
                                "args": ["absolute_path": "src/array.txt"],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-array-fragments",
                                "name": "read_file",
                                "response": [
                                    ["type": "output_text", "text": "array payload"],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 58
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.output == "array payload")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("role/parts function call aliases map terminal captures")
    func rolePartsFunctionCallAliases() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:12Z",
                    "parts": [
                        [
                            "function_call": [
                                "call_id": "call-shell-snake",
                                "function_name": "run_shell_command",
                                "arguments": line([
                                    "command": "swift test --filter AntigravityTranscriptParserTests",
                                ]),
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:18Z",
                    "parts": [
                        [
                            "function_response": [
                                "call_id": "call-shell-snake",
                                "response": ["output": "Antigravity parser tests passed"],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 44
        )

        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.updatedMessages.isEmpty)
        #expect(result.messages[0].id == "call-shell-snake")
        #expect(result.messages[0].seq == 44)
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_856_018))
        #expect(result.messages[0].kind == .terminal(ChatTerminalCapture(
            command: "swift test --filter AntigravityTranscriptParserTests",
            output: "Antigravity parser tests passed",
            exitCode: 0,
            isRunning: false
        )))
    }

    @Test("role/parts function responses preserve terminal exit and duration metadata")
    func rolePartsFunctionResponseMetadataCompletesTerminalExitAndDuration() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:12Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-shell-metadata",
                                "name": "run_shell_command",
                                "args": [
                                    "command": "swift test --filter AntigravityTranscriptParserTests",
                                ],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:18Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-shell-metadata",
                                "response": [
                                    "output": "Antigravity parser tests failed",
                                    "exitCode": 2,
                                    "duration_ms": 1_500,
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 54
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter AntigravityTranscriptParserTests")
        #expect(capture.output == "Antigravity parser tests failed")
        #expect(capture.exitCode == 2)
        #expect(capture.durationSeconds == 1.5)
        #expect(capture.isRunning == false)
    }

    @Test("role/parts function responses read nested metadata objects")
    func rolePartsFunctionResponseNestedMetadataObject() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:20Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-metadata-object",
                                "name": "run_shell_command",
                                "args": [
                                    "command": "swift test --filter MetadataObject",
                                ],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:28Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-metadata-object",
                                "response": [
                                    "output": "metadata object failed",
                                    "metadata": [
                                        "exit_code": 4,
                                        "duration_seconds": 0.75,
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 56
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_856_028))
        #expect(capture.command == "swift test --filter MetadataObject")
        #expect(capture.output == "metadata object failed")
        #expect(capture.exitCode == 4)
        #expect(capture.durationSeconds == 0.75)
        #expect(capture.isRunning == false)
    }

    @Test("role/parts function response status strings normalize spaces")
    func rolePartsFunctionResponseStatusStringNormalizesSpaces() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:30Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-response-status-spaces",
                                "name": "run_shell_command",
                                "args": [
                                    "command": "swift test --filter ResponseStatusSpaces",
                                ],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:38Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-response-status-spaces",
                                "response": [
                                    "output": "response status timed out",
                                    "status": "timed out",
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 58
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter ResponseStatusSpaces")
        #expect(capture.output == "response status timed out")
        #expect(capture.exitCode == 1)
        #expect(capture.isRunning == false)
    }

    @Test("role/parts function response fail status marks terminal failed")
    func rolePartsFunctionResponseFailStatusMarksTerminalFailed() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:40Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-response-status-fail",
                                "name": "run_shell_command",
                                "args": [
                                    "command": "swift test --filter ResponseStatusFail",
                                ],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:48Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-response-status-fail",
                                "response": [
                                    "output": "response status fail",
                                    "status": "fail",
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 60
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter ResponseStatusFail")
        #expect(capture.output == "response status fail")
        #expect(capture.exitCode == 1)
        #expect(capture.isRunning == false)
    }

    @Test("tool results in a later parse call update the pending Antigravity tool row")
    func rolePartsToolResultAcrossParseCalls() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:00Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-shell",
                                "name": "run_shell_command",
                                "args": ["command": "swift test"],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 0
        )

        #expect(first.messages.count == 1)
        #expect(first.messages[0].kind == .terminal(ChatTerminalCapture(
            command: "swift test",
            isRunning: true
        )))

        let second = parser.parse(
            lines: [
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:09Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-shell",
                                "response": ["error": "tests failed"],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 1,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        #expect(second.updatedMessages[0].id == "call-shell")
        #expect(second.updatedMessages[0].timestamp == Date(timeIntervalSince1970: 1_781_856_009))
        #expect(second.updatedMessages[0].kind == .terminal(ChatTerminalCapture(
            command: "swift test",
            output: "tests failed",
            exitCode: 1,
            isRunning: false
        )))
    }

    @Test("role/parts function responses flatten error fragments")
    func rolePartsFunctionResponseErrorFragments() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:20Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-error-fragments",
                                "name": "run_shell_command",
                                "args": ["command": "swift test --filter ErrorFragments"],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 60
        )

        let second = parser.parse(
            lines: [
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:00:24Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-error-fragments",
                                "response": [
                                    "error": [
                                        ["type": "output_text", "text": "first error line"],
                                        ["type": "text", "text": "second error line"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 61,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        #expect(second.updatedMessages[0].kind == .terminal(ChatTerminalCapture(
            command: "swift test --filter ErrorFragments",
            output: "first error line\nsecond error line",
            exitCode: 1,
            isRunning: false
        )))
    }

    @Test("shell tool name aliases map to terminal captures")
    func shellToolNameAliasesMapToTerminalCaptures() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:00:11Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-shell-alias",
                                "name": "RUN-SHELL-COMMAND",
                                "args": ["command": "swift test --filter AntigravityTranscriptParserTests"],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 2
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages.first?.id == "call-shell-alias")
        #expect(result.messages.first?.seq == 2)
        #expect(capture.command == "swift test --filter AntigravityTranscriptParserTests")
        #expect(capture.isRunning)
    }

    @Test("role/parts AskUserQuestion maps to question cards and resolves answers")
    func rolePartsAskUserQuestion() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:10:00Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-questions",
                                "name": "AskUserQuestion",
                                "args": [
                                    "questions": [
                                        [
                                            "question": "Which path?",
                                            "options": [
                                                ["label": "Fast", "description": "Quick but rough"],
                                                ["label": "Slow", "description": "Thorough"],
                                            ],
                                        ],
                                        [
                                            "question": "Which env?",
                                            "options": [
                                                ["label": "Dev", "description": "Local"],
                                                ["label": "Prod", "description": "Live"],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 30
        )

        let pendingQuestions = first.messages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(pendingQuestions.count == 2)
        #expect(pendingQuestions.first?.prompt == "Which path?")
        #expect(pendingQuestions.first?.options.map(\.label) == ["Fast", "Slow"])
        #expect(pendingQuestions.first?.options[0].detail == "Quick but rough")
        #expect(first.messages.map(\.id) == ["call-questions", "call-questions#1"])
        #expect(first.state.pendingToolUses["call-questions"]?.count == 2)
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: first.messages)
                == Date(timeIntervalSince1970: 1_781_856_600)
        )

        let second = parser.parse(
            lines: [
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:10:05Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-questions",
                                "response": [
                                    "output": #"Your questions have been answered: "Which path?"="Slow", "Which env?"="Dev". Continue."#,
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 31,
            state: first.state
        )

        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 2)
        #expect(answered.first(where: { $0.prompt == "Which path?" })?.selectedOptionLabel == "Slow")
        #expect(answered.first(where: { $0.prompt == "Which env?" })?.selectedOptionLabel == "Dev")
        #expect(
            ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages)
                == Date(timeIntervalSince1970: 1_781_856_605)
        )
    }

    @Test("role/parts AskUserQuestion resolves prompt-associated JSON answers")
    func rolePartsAskUserQuestionJSONAnswers() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:12:00Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-json-questions",
                                "name": "AskUserQuestion",
                                "args": [
                                    "questions": [
                                        [
                                            "question": "Which path?",
                                            "options": ["Fast", "Slow"],
                                        ],
                                        [
                                            "question": "Which env?",
                                            "options": ["Dev", "Prod"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 34
        )

        let second = parser.parse(
            lines: [
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:12:05Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-json-questions",
                                "response": [
                                    "output": #"{"questions":[{"question":"Which path?","answer":"Slow"},{"prompt":"Which env?","selected":"Dev"}]}"#,
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 35,
            state: first.state
        )

        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 2)
        #expect(answered.first(where: { $0.prompt == "Which path?" })?.selectedOptionLabel == "Slow")
        #expect(answered.first(where: { $0.prompt == "Which env?" })?.selectedOptionLabel == "Dev")
    }

    @Test("role/parts AskUserQuestion resolves wrapped object answers")
    func rolePartsAskUserQuestionWrappedObjectAnswers() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:14:00Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-wrapped-object-answers",
                                "name": "AskUserQuestion",
                                "args": [
                                    "questions": [
                                        [
                                            "question": "Which wrapped path?",
                                            "options": ["Plan", "Ship"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 36
        )

        let second = parser.parse(
            lines: [
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T08:14:05Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "call-wrapped-object-answers",
                                "response": [
                                    "output": [
                                        "data": [
                                            "answers": ["Which wrapped path?": "Ship"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 37,
            state: first.state
        )

        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 1)
        #expect(answered.first?.selectedOptionLabel == "Ship")
        #expect(
            ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages)
                == Date(timeIntervalSince1970: 1_781_856_845)
        )
    }

    @Test("type-based request_user_input maps inline results to answered question cards")
    func currentTypeBasedRequestUserInputQuestion() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-gemini",
                    "timestamp": "2026-06-19T09:10:00Z",
                    "toolCalls": [
                        [
                            "id": "call-question",
                            "name": "request_user_input",
                            "args": [
                                "questions": [
                                    [
                                        "question": "Ship now?",
                                        "options": [
                                            ["label": "Yes", "description": "Proceed"],
                                            ["label": "No", "description": "Wait"],
                                        ],
                                    ],
                                ],
                            ],
                            "status": "success",
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:10:06Z",
                                    "functionResponse": [
                                        "id": "call-question",
                                        "response": [
                                            "output": #"Your questions have been answered: "Ship now?"="Yes". Continue."#,
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 50
        )

        #expect(result.messages.count == 1)
        guard case .question(let question) = result.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(result.messages[0].id == "call-question")
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_206))
        #expect(question.prompt == "Ship now?")
        #expect(question.options.map(\.label) == ["Yes", "No"])
        #expect(question.selectedOptionLabel == "Yes")
    }

    @Test("type-based request_user_input accepts a flat prompt with string options")
    func currentTypeBasedFlatRequestUserInputQuestion() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-flat-question",
                    "timestamp": "2026-06-19T09:15:00Z",
                    "toolCalls": [
                        [
                            "id": "call-flat-question",
                            "name": "request_user_input",
                            "args": [
                                "prompt": "Which Antigravity path?",
                                "options": [
                                    "Inspect",
                                    ["title": "Patch", "detail": "Edit now"],
                                ],
                            ],
                            "status": "success",
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:15:05Z",
                                    "functionResponse": [
                                        "id": "call-flat-question",
                                        "response": [
                                            "output": #"Your questions have been answered: "Which Antigravity path?"="Patch". Continue."#,
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 52
        )

        #expect(result.messages.count == 1)
        guard case .question(let question) = result.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(result.messages[0].id == "call-flat-question")
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_505))
        #expect(question.prompt == "Which Antigravity path?")
        #expect(question.options.map(\.label) == ["Inspect", "Patch"])
        #expect(question.options[1].detail == "Edit now")
        #expect(question.selectedOptionLabel == "Patch")
    }

    @Test("type-based request_user_input accepts scalar JSON options")
    func currentTypeBasedScalarOptions() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-scalar-options",
                    "timestamp": "2026-06-19T09:16:00Z",
                    "toolCalls": [
                        [
                            "id": "call-scalar-options",
                            "name": "request_user_input",
                            "args": [
                                "prompt": "How many Antigravity agents?",
                                "options": [
                                    1,
                                    2,
                                    true,
                                    ["value": false, "description": "Disable pilot mode"],
                                ],
                            ],
                            "status": "success",
                        ],
                    ],
                ]),
            ],
            startingSeq: 53
        )

        #expect(result.messages.count == 1)
        guard case .question(let question) = result.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(result.messages[0].id == "call-scalar-options")
        #expect(question.prompt == "How many Antigravity agents?")
        #expect(question.options.map(\.label) == ["1", "2", "true", "false"])
        if question.options.count > 3 {
            #expect(question.options[3].detail == "Disable pilot mode")
        }
    }

    @Test("type-based request_user_input accepts object options keyed by text, value, or name")
    func currentTypeBasedFallbackOptionLabels() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-fallback-labels",
                    "timestamp": "2026-06-19T09:18:00Z",
                    "toolCalls": [
                        [
                            "id": "call-fallback-labels",
                            "name": "request_user_input",
                            "args": [
                                "prompt": "Which Antigravity action?",
                                "options": [
                                    ["text": "Inspect first"],
                                    ["value": "Patch now", "description": "Edit immediately"],
                                    ["name": "Chat about this"],
                                ],
                            ],
                            "status": "success",
                        ],
                    ],
                ]),
            ],
            startingSeq: 54
        )

        #expect(result.messages.count == 1)
        guard case .question(let question) = result.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(result.messages[0].id == "call-fallback-labels")
        #expect(question.prompt == "Which Antigravity action?")
        #expect(question.options.map(\.label) == ["Inspect first", "Patch now", "Chat about this"])
        if question.options.count > 1 {
            #expect(question.options[1].detail == "Edit immediately")
        }
    }

    @Test("role event request_user_input maps to question cards and resolves answers")
    func roleEventRequestUserInputQuestion() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "request_user_input",
                    "requestId": "agy-question-1",
                    "timestamp": "2026-06-19T09:20:00Z",
                    "arguments": line([
                        "questions": [
                            [
                                "question": "Which Antigravity path?",
                                "options": [
                                    ["label": "Inspect", "description": "Read first"],
                                    ["label": "Patch", "description": "Edit now"],
                                ],
                            ],
                        ],
                    ]),
                ]),
            ],
            startingSeq: 55
        )

        #expect(first.messages.count == 1)
        guard case .question(let question) = first.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(first.messages[0].id == "agy-question-1")
        #expect(first.messages[0].seq == 55)
        #expect(first.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_800))
        #expect(question.prompt == "Which Antigravity path?")
        #expect(question.options.map(\.label) == ["Inspect", "Patch"])
        #expect(question.options[0].detail == "Read first")
        #expect(question.selectedOptionLabel == nil)
        #expect(first.state.pendingToolUses["agy-question-1"]?.count == 1)
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: first.messages)
                == Date(timeIntervalSince1970: 1_781_860_800)
        )

        let second = parser.parse(
            lines: [
                line([
                    "role": "tool",
                    "timestamp": "2026-06-19T09:20:05Z",
                    "parts": [
                        [
                            "functionResponse": [
                                "id": "agy-question-1",
                                "response": [
                                    "output": #"Your questions have been answered: "Which Antigravity path?"="Patch". Continue."#,
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 56,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .question(let answered) = second.updatedMessages[0].kind else {
            Issue.record("expected answered question kind")
            return
        }
        #expect(second.updatedMessages[0].id == "agy-question-1")
        #expect(second.updatedMessages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_805))
        #expect(answered.prompt == "Which Antigravity path?")
        #expect(answered.selectedOptionLabel == "Patch")
        #expect(
            ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages)
                == Date(timeIntervalSince1970: 1_781_860_805)
        )
    }

    @Test("request_user_input aliases map to question cards")
    func requestUserInputAliasesMapToQuestionCards() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-question-alias",
                    "timestamp": "2026-06-19T09:21:00Z",
                    "toolCalls": [
                        [
                            "id": "call-question-alias",
                            "name": "REQUEST-USER-INPUT",
                            "args": [
                                "prompt": "Which current Antigravity path?",
                                "options": ["Inspect", "Patch"],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "event",
                    "name": "ASK-QUESTION",
                    "requestId": "agy-question-alias",
                    "timestamp": "2026-06-19T09:21:05Z",
                    "payload": [
                        "prompt": "Which role event path?",
                        "options": ["Inspect", "Patch"],
                    ],
                ]),
            ],
            startingSeq: 57
        )

        #expect(result.messages.count == 2)
        guard case .question(let currentQuestion) = result.messages[0].kind,
              case .question(let eventQuestion) = result.messages[1].kind else {
            Issue.record("expected question kinds")
            return
        }
        #expect(result.messages[0].id == "call-question-alias")
        #expect(result.messages[0].seq == 57)
        #expect(currentQuestion.prompt == "Which current Antigravity path?")
        #expect(currentQuestion.options.map(\.label) == ["Inspect", "Patch"])
        #expect(result.messages[1].id == "agy-question-alias")
        #expect(result.messages[1].seq == 58)
        #expect(eventQuestion.prompt == "Which role event path?")
        #expect(eventQuestion.options.map(\.label) == ["Inspect", "Patch"])
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_860_865)
        )
    }

    @Test("role event tool authorization maps to a permission request")
    func roleEventToolAuthorizationRequest() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "tool_authorization_required",
                    "toolCallId": "call-shell",
                    "toolName": "run_shell_command",
                    "args": ["command": "swift test --filter AntigravityTranscriptParser"],
                    "timestamp": "2026-06-19T08:30:00Z",
                ]),
            ],
            startingSeq: 40
        )

        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "permission-call-shell")
        #expect(result.messages[0].seq == 40)
        #expect(result.messages[0].role == .agent)
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_857_800))
        #expect(result.messages[0].kind == .permissionRequest(
            ChatPermissionRequest(
                title: "Antigravity wants to run:",
                subject: "swift test --filter AntigravityTranscriptParser"
            )
        ))
    }

    @Test("role event tool authorization result updates the permission request")
    func roleEventToolAuthorizationResult() throws {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "tool_authorization_required",
                    "toolCallId": "call-shell",
                    "toolName": "run_shell_command",
                    "args": ["command": "swift test --filter AntigravityTranscriptParser"],
                    "timestamp": "2026-06-19T08:30:00Z",
                ]),
            ],
            startingSeq: 40
        )

        let second = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "tool_authorization_result",
                    "toolCallId": "call-shell",
                    "decision": "approved",
                    "timestamp": "2026-06-19T08:30:05Z",
                ]),
            ],
            startingSeq: 41,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        let updated = try #require(second.updatedMessages.first)
        #expect(updated.id == "permission-call-shell")
        #expect(updated.timestamp == Date(timeIntervalSince1970: 1_781_857_805))
        #expect(updated.kind == .permissionRequest(
            ChatPermissionRequest(
                title: "Antigravity wants to run:",
                subject: "swift test --filter AntigravityTranscriptParser",
                resolution: .approved
            )
        ))
    }

    @Test("role event tool authorization result without a retained request still clears input wait")
    func roleEventToolAuthorizationResultWithoutPendingRequestEmitsInputResolvedStateUpdate() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "tool_authorization_result",
                    "toolCallId": "call-shell-backfill",
                    "decision": "approved",
                    "timestamp": "2026-06-19T08:30:05Z",
                ]),
            ],
            startingSeq: 41
        )

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 41,
                timestamp: Date(timeIntervalSince1970: 1_781_857_805)
            ),
        ])
    }

    @Test("role event tool authorization denial without a retained request clears input and work")
    func roleEventToolAuthorizationDeniedWithoutPendingRequestEmitsInputResolvedAndIdleStateUpdates() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "tool_authorization_result",
                    "toolCallId": "call-shell-denied-backfill",
                    "decision": "denied",
                    "timestamp": "2026-06-19T08:30:06Z",
                ]),
            ],
            startingSeq: 42
        )

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 42,
                timestamp: Date(timeIntervalSince1970: 1_781_857_806)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 42,
                timestamp: Date(timeIntervalSince1970: 1_781_857_806)
            ),
        ])
    }

    @Test("current type-based tool authorization records map and resolve permission requests")
    func currentTypeBasedToolAuthorizationRecords() throws {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let first = parser.parse(
            lines: [
                line([
                    "type": "TOOL_AUTHORIZATION_REQUIRED",
                    "requestId": "auth-shell",
                    "toolName": "run_shell_command",
                    "arguments": ["command": "swift test --filter AntigravityTranscriptParser"],
                    "timestamp": "2026-06-19T08:31:00Z",
                ]),
            ],
            startingSeq: 42
        )

        #expect(first.messages.count == 1)
        let pending = try #require(first.messages.first)
        #expect(pending.id == "permission-auth-shell")
        #expect(pending.seq == 42)
        #expect(pending.timestamp == Date(timeIntervalSince1970: 1_781_857_860))
        #expect(pending.kind == .permissionRequest(
            ChatPermissionRequest(
                title: "Antigravity wants to run:",
                subject: "swift test --filter AntigravityTranscriptParser"
            )
        ))

        let second = parser.parse(
            lines: [
                line([
                    "type": "TOOL_AUTHORIZATION_RESULT",
                    "requestId": "auth-shell",
                    "decision": "denied",
                    "timestamp": "2026-06-19T08:31:05Z",
                ]),
            ],
            startingSeq: 43,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        let updated = try #require(second.updatedMessages.first)
        #expect(updated.id == "permission-auth-shell")
        #expect(updated.timestamp == Date(timeIntervalSince1970: 1_781_857_865))
        #expect(updated.kind == .permissionRequest(
            ChatPermissionRequest(
                title: "Antigravity wants to run:",
                subject: "swift test --filter AntigravityTranscriptParser",
                resolution: .denied
            )
        ))
        #expect(second.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 43,
                timestamp: Date(timeIntervalSince1970: 1_781_857_865)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 43,
                timestamp: Date(timeIntervalSince1970: 1_781_857_865)
            ),
        ])
    }

    @Test("role lifecycle events emit non-rendered transcript state updates")
    func roleLifecycleEventsEmitStateUpdates() throws {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "task_started",
                    "timestamp": "2026-06-19T11:06:00Z",
                    "turn_id": "turn-1",
                ]),
                line([
                    "role": "event",
                    "name": "task_complete",
                    "timestamp": "2026-06-19T11:06:01Z",
                    "turn_id": "turn-1",
                ]),
                line([
                    "role": "event",
                    "name": "turn_complete",
                    "timestamp": "2026-06-19T11:06:02Z",
                    "turn_id": "turn-2",
                ]),
                line([
                    "role": "event",
                    "name": "turn_aborted",
                    "timestamp": "2026-06-19T11:06:03Z",
                    "turn_id": "turn-3",
                    "reason": "interrupted",
                ]),
            ],
            startingSeq: 66
        )

        #expect(result.messages.map(\.kind) == [
            .status(ChatStatusTransition(event: .interrupted, detail: "interrupted")),
        ])
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .working,
                seq: 66,
                timestamp: Date(timeIntervalSince1970: 1_781_867_160)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 67,
                timestamp: Date(timeIntervalSince1970: 1_781_867_161)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 68,
                timestamp: Date(timeIntervalSince1970: 1_781_867_162)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 69,
                timestamp: Date(timeIntervalSince1970: 1_781_867_163)
            ),
        ])
    }

    @Test("current type-based lifecycle records emit non-rendered transcript state updates")
    func currentTypeBasedLifecycleRecordsEmitStateUpdates() throws {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "TASK_STARTED",
                    "timestamp": "2026-06-19T11:07:00Z",
                    "turn_id": "turn-1",
                ]),
                line([
                    "type": "TASK_COMPLETE",
                    "timestamp": "2026-06-19T11:07:01Z",
                    "turn_id": "turn-1",
                ]),
                line([
                    "type": "TURN_COMPLETE",
                    "timestamp": "2026-06-19T11:07:02Z",
                    "turn_id": "turn-2",
                ]),
                line([
                    "type": "TURN_ABORTED",
                    "timestamp": "2026-06-19T11:07:03Z",
                    "turn_id": "turn-3",
                    "message": "user interrupted",
                ]),
            ],
            startingSeq: 70
        )

        #expect(result.messages.map(\.kind) == [
            .status(ChatStatusTransition(event: .interrupted, detail: "user interrupted")),
        ])
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .working,
                seq: 70,
                timestamp: Date(timeIntervalSince1970: 1_781_867_220)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 71,
                timestamp: Date(timeIntervalSince1970: 1_781_867_221)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 72,
                timestamp: Date(timeIntervalSince1970: 1_781_867_222)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 73,
                timestamp: Date(timeIntervalSince1970: 1_781_867_223)
            ),
        ])
    }

    @Test("Antigravity turn_aborted fails running tools and expires pending permission requests")
    func turnAbortedClearsPendingToolAndPermissionRows() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:40:00Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-aborted",
                                "name": "run_shell_command",
                                "args": ["command": "npm test"],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "event",
                    "name": "tool_authorization_required",
                    "toolCallId": "call-aborted",
                    "toolName": "run_shell_command",
                    "args": ["command": "npm test"],
                    "timestamp": "2026-06-19T08:40:01Z",
                ]),
                line([
                    "role": "event",
                    "name": "turn_aborted",
                    "reason": "interrupted",
                    "timestamp": "2026-06-19T08:40:02Z",
                ]),
            ],
            startingSeq: 74
        )

        #expect(result.messages.count == 3)
        guard result.messages.count == 3 else { return }
        guard case .terminal(let terminal) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(terminal.command == "npm test")
        #expect(terminal.output == "interrupted")
        #expect(terminal.exitCode == 1)
        #expect(terminal.isRunning == false)

        guard case .permissionRequest(let request) = result.messages[1].kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.resolution == .expired)
        #expect(result.messages[2].kind == .status(
            ChatStatusTransition(event: .interrupted, detail: "interrupted")
        ))
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: [result.messages[1]]) != nil)
    }

    @Test("Antigravity stream_error fails carried pending tool rows from a previous parse")
    func streamErrorClearsCarriedPendingToolRows() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let first = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:41:00Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "search-interrupted",
                                "name": "search_web",
                                "args": ["query": "Swift Testing docs"],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 80
        )
        #expect(first.state.pendingToolUses["search-interrupted"]?.count == 1)

        let second = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "stream_error",
                    "message": "Stream disconnected before completion.",
                    "timestamp": "2026-06-19T08:41:01Z",
                ]),
            ],
            startingSeq: 81,
            state: first.state
        )

        #expect(second.messages.count == 1)
        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let search) = second.updatedMessages.first?.kind else {
            Issue.record("expected updated toolUse kind")
            return
        }
        #expect(search.toolName == "search_web")
        #expect(search.status == .failed)
        #expect(search.output == "Stream disconnected before completion.")
        #expect(second.state.pendingToolUses.isEmpty)
        #expect(second.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 81,
                timestamp: Date(timeIntervalSince1970: 1_781_858_461)
            ),
        ])
    }

    @Test("Antigravity task_complete resolves pending tools and expires permission requests")
    func taskCompleteClearsPendingToolAndPermissionRows() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "model",
                    "timestamp": "2026-06-19T08:43:00Z",
                    "parts": [
                        [
                            "functionCall": [
                                "id": "call-complete",
                                "name": "run_shell_command",
                                "args": ["command": "npm test"],
                            ],
                        ],
                    ],
                ]),
                line([
                    "role": "event",
                    "name": "tool_authorization_required",
                    "toolCallId": "call-complete",
                    "toolName": "run_shell_command",
                    "args": ["command": "npm test"],
                    "timestamp": "2026-06-19T08:43:01Z",
                ]),
                line([
                    "role": "event",
                    "name": "task_complete",
                    "turn_id": "turn-complete",
                    "timestamp": "2026-06-19T08:43:02Z",
                ]),
            ],
            startingSeq: 86
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        guard case .terminal(let terminal) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_858_582))
        #expect(terminal.command == "npm test")
        #expect(terminal.output == nil)
        #expect(terminal.exitCode == 0)
        #expect(terminal.isRunning == false)

        guard case .permissionRequest(let request) = result.messages[1].kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(result.messages[1].timestamp == Date(timeIntervalSince1970: 1_781_858_582))
        #expect(request.resolution == .expired)
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 88,
                timestamp: Date(timeIntervalSince1970: 1_781_858_582)
            ),
        ])
    }

    @Test("Antigravity task_complete expires pending question rows")
    func taskCompleteClearsPendingQuestionRows() {
        let parser = AntigravityTranscriptParser(sessionID: "session-file-123")
        let result = parser.parse(
            lines: [
                line([
                    "role": "event",
                    "name": "ask_question",
                    "requestId": "agy-question-complete",
                    "timestamp": "2026-06-19T08:45:00Z",
                    "prompt": "Continue Antigravity task?",
                    "options": ["Yes", "No"],
                ]),
                line([
                    "role": "event",
                    "name": "task_complete",
                    "turn_id": "turn-question-complete",
                    "timestamp": "2026-06-19T08:45:01Z",
                ]),
            ],
            startingSeq: 89
        )

        #expect(result.messages.count == 1)
        guard case .question(let question) = result.messages.first?.kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(question.prompt == "Continue Antigravity task?")
        #expect(question.selectedOptionLabel == nil)
        #expect(question.resolution == .expired)
        #expect(result.messages.first?.timestamp == Date(timeIntervalSince1970: 1_781_858_701))
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages) == nil)
        #expect(
            ChatTranscriptStateSignal.resolvedInputTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_858_701)
        )
    }

    @Test("current type-based tool_calls aliases map terminal captures")
    func currentTypeBasedToolCallAliases() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-calls-snake",
                    "timestamp": "2026-06-19T09:22:00Z",
                    "tool_calls": [
                        [
                            "call_id": "call-current-snake",
                            "function_name": "run_shell_command",
                            "arguments": line(["command": "swift test --package-path Packages/Shared/CmuxAgentChat"]),
                            "status": "success",
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:22:03Z",
                                    "function_response": [
                                        "call_id": "call-current-snake",
                                        "response": ["output": "Shared package passed"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 74
        )

        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "call-current-snake")
        #expect(result.messages[0].seq == 74)
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_923))
        #expect(result.messages[0].kind == .terminal(ChatTerminalCapture(
            command: "swift test --package-path Packages/Shared/CmuxAgentChat",
            output: "Shared package passed",
            exitCode: 0,
            isRunning: false
        )))
    }

    @Test("current type-based inline tool results flatten content fragments")
    func currentTypeBasedToolResultContentFragments() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-result-content-fragments",
                    "timestamp": "2026-06-19T09:22:10Z",
                    "toolCalls": [
                        [
                            "id": "call-current-content-fragments",
                            "name": "run_shell_command",
                            "args": ["command": "swift test --filter CurrentContentFragments"],
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:22:15Z",
                                    "functionResponse": [
                                        "id": "call-current-content-fragments",
                                        "response": [
                                            "content": [
                                                ["type": "output_text", "text": "first inline line"],
                                                ["type": "text", "text": "second inline line"],
                                            ],
                                            "exitCode": 0,
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 76
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_935))
        #expect(capture.command == "swift test --filter CurrentContentFragments")
        #expect(capture.output == "first inline line\nsecond inline line")
        #expect(capture.exitCode == 0)
        #expect(capture.isRunning == false)
    }

    @Test("current type-based inline tool results flatten error fragments")
    func currentTypeBasedToolResultErrorFragments() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-error-fragments",
                    "timestamp": "2026-06-19T09:22:20Z",
                    "toolCalls": [
                        [
                            "id": "call-current-error-fragments",
                            "name": "read_file",
                            "args": ["absolute_path": "src/missing.txt"],
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:22:22Z",
                                    "functionResponse": [
                                        "id": "call-current-error-fragments",
                                        "response": [
                                            "stderr": [
                                                ["type": "output_text", "text": "file not found"],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 77
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_942))
        #expect(tool.output == "file not found")
        #expect(tool.status == .failed)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("current type-based inline tool result status aliases fail terminal captures")
    func currentTypeBasedToolResultStatusAliasFailsTerminal() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-status-failed",
                    "timestamp": "2026-06-19T09:22:30Z",
                    "toolCalls": [
                        [
                            "id": "call-current-status-failed",
                            "name": "run_shell_command",
                            "args": ["command": "swift test --filter StatusAlias"],
                            "status": "FAILED",
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:22:34Z",
                                    "functionResponse": [
                                        "id": "call-current-status-failed",
                                        "response": [
                                            "output": "status alias failed",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 78
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_954))
        #expect(capture.command == "swift test --filter StatusAlias")
        #expect(capture.output == "status alias failed")
        #expect(capture.exitCode == 1)
        #expect(capture.isRunning == false)
    }

    @Test("current type-based inline tool result status aliases fail generic tool uses")
    func currentTypeBasedToolResultStatusAliasFailsGenericToolUse() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-status-timed-out",
                    "timestamp": "2026-06-19T09:22:40Z",
                    "toolCalls": [
                        [
                            "id": "call-current-status-timed-out",
                            "name": "read_file",
                            "args": ["absolute_path": "src/slow.txt"],
                            "status": "timed-out",
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:22:45Z",
                                    "functionResponse": [
                                        "id": "call-current-status-timed-out",
                                        "response": [
                                            "output": "tool timed out",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 79
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_965))
        #expect(tool.output == "tool timed out")
        #expect(tool.status == .failed)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("current type-based inline tool response status strings normalize spaces")
    func currentTypeBasedToolResponseStatusStringNormalizesSpaces() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-response-status-spaces",
                    "timestamp": "2026-06-19T09:22:50Z",
                    "toolCalls": [
                        [
                            "id": "call-current-response-status-spaces",
                            "name": "run_shell_command",
                            "args": ["command": "swift test --filter CurrentResponseStatusSpaces"],
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:22:55Z",
                                    "functionResponse": [
                                        "id": "call-current-response-status-spaces",
                                        "response": [
                                            "output": "inline response status timed out",
                                            "status": "timed out",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 80
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_975))
        #expect(capture.command == "swift test --filter CurrentResponseStatusSpaces")
        #expect(capture.output == "inline response status timed out")
        #expect(capture.exitCode == 1)
        #expect(capture.isRunning == false)
    }

    @Test("current type-based inline tool results complete from metadata-only responses")
    func currentTypeBasedToolResultMetadataOnlyCompletesTerminal() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-metadata-only",
                    "timestamp": "2026-06-19T09:23:00Z",
                    "toolCalls": [
                        [
                            "id": "call-current-metadata-only",
                            "name": "run_shell_command",
                            "args": ["command": "swift test --filter MetadataOnly"],
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:23:04Z",
                                    "functionResponse": [
                                        "id": "call-current-metadata-only",
                                        "response": [
                                            "exit_code": 3,
                                            "duration": [
                                                "secs": 2,
                                                "nanos": 500_000_000,
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 78
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_984))
        #expect(capture.command == "swift test --filter MetadataOnly")
        #expect(capture.output == nil)
        #expect(capture.exitCode == 3)
        #expect(capture.durationSeconds == 2.5)
        #expect(capture.isRunning == false)
    }

    @Test("current type-based inline tool results read nested metadata objects")
    func currentTypeBasedToolResultNestedMetadataObject() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-tool-metadata-object",
                    "timestamp": "2026-06-19T09:23:10Z",
                    "toolCalls": [
                        [
                            "id": "call-current-metadata-object",
                            "name": "run_shell_command",
                            "args": ["command": "swift test --filter CurrentMetadataObject"],
                            "result": [
                                [
                                    "timestamp": "2026-06-19T09:23:14Z",
                                    "functionResponse": [
                                        "id": "call-current-metadata-object",
                                        "response": [
                                            "output": "inline metadata object failed",
                                            "metadata": [
                                                "exit_code": 5,
                                                "duration_seconds": 1.25,
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 79
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_860_994))
        #expect(capture.command == "swift test --filter CurrentMetadataObject")
        #expect(capture.output == "inline metadata object failed")
        #expect(capture.exitCode == 5)
        #expect(capture.durationSeconds == 1.25)
        #expect(capture.isRunning == false)
    }

    @Test("current type-based Antigravity JSONL maps gemini turns and inline tool results")
    func currentTypeBasedTranscript() {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let lines = [
            line([
                "type": "user",
                "id": "msg-user",
                "content": "Summarize the code",
                "timestamp": "2026-06-19T09:00:00Z",
            ]),
            line([
                "type": "gemini",
                "id": "msg-gemini",
                "content": "I will inspect the project.",
                "thoughts": [
                    ["description": "Need to list the files first."],
                ],
                "toolCalls": [
                    [
                        "id": "call-list",
                        "name": "list_directory",
                        "args": ["path": "."],
                        "status": "success",
                        "result": [
                            [
                                "timestamp": "2026-06-19T09:00:09Z",
                                "functionResponse": [
                                    "id": "call-list",
                                    "response": ["output": "Sources\nTests"],
                                ],
                            ],
                        ],
                    ],
                ],
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 4)

        #expect(result.messages.count == 4)
        #expect(result.messages[0].id == "msg-user")
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Summarize the code")))
        #expect(result.messages[1].id == "msg-gemini")
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "I will inspect the project.")))
        #expect(result.messages[2].kind == .thought(ChatThought(text: "Need to list the files first.")))
        #expect(result.messages[3].kind == .toolUse(ChatToolUse(
            toolName: "list_directory",
            summary: "list_directory .",
            inputDetail: #"{"path":"."}"#,
            output: "Sources\nTests",
            status: .succeeded
        )))
        #expect(result.messages[3].timestamp == Date(timeIntervalSince1970: 1_781_859_609))
        #expect(
            ChatTranscriptStateSignal.completedWorkTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_859_609)
        )
    }

    @Test("single-object Antigravity session JSON maps messages array")
    func sessionJSONTranscript() throws {
        let parser = AntigravityTranscriptParser(sessionID: "json-session")
        let raw = line([
            "sessionId": "json-session",
            "projectHash": "hash",
            "startTime": "2026-06-19T10:00:00Z",
            "lastUpdated": "2026-06-19T10:01:00Z",
            "messages": [
                [
                    "type": "user",
                    "id": "json-user",
                    "timestamp": "2026-06-19T10:00:01Z",
                    "content": "Open the session JSON",
                ],
                [
                    "type": "gemini",
                    "id": "json-gemini",
                    "timestamp": "2026-06-19T10:00:02Z",
                    "content": "I will inspect the file.",
                    "thoughts": [
                        [
                            "subject": "plan",
                            "description": "The file is a whole JSON document.",
                            "timestamp": "2026-06-19T10:00:02Z",
                        ],
                    ],
                    "toolCalls": [
                        [
                            "id": "json-call-read",
                            "name": "read_file",
                            "args": ["absolute_path": "session.json"],
                            "status": "success",
                            "timestamp": "2026-06-19T10:00:03Z",
                            "result": [
                                [
                                    "functionResponse": [
                                        "id": "json-call-read",
                                        "response": ["output": #"{"messages":[]}"#],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])

        let result = try #require(parser.parseSessionJSON(raw))

        #expect(result.messages.count == 4)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.messages[0].id == "json-user")
        #expect(result.messages[0].seq == 0)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Open the session JSON")))
        #expect(result.messages[1].id == "json-gemini")
        #expect(result.messages[1].seq == 1)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "I will inspect the file.")))
        #expect(result.messages[2].id == "line-1-thought-0")
        #expect(result.messages[2].kind == .thought(ChatThought(text: "The file is a whole JSON document.")))
        #expect(result.messages[3].id == "json-call-read")
        #expect(result.messages[3].kind == .toolUse(ChatToolUse(
            toolName: "read_file",
            summary: "read_file session.json",
            inputDetail: #"{"absolute_path":"session.json"}"#,
            output: #"{"messages":[]}"#,
            status: .succeeded
        )))
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_863_201))
        #expect(result.messages[3].timestamp == Date(timeIntervalSince1970: 1_781_863_203))
    }

    @Test("single-object Antigravity session JSON completes status-only tool calls")
    func sessionJSONStatusOnlyToolCompletion() throws {
        let parser = AntigravityTranscriptParser(sessionID: "json-session")
        let raw = line([
            "sessionId": "json-session",
            "messages": [
                [
                    "type": "gemini",
                    "id": "json-gemini",
                    "content": "",
                    "toolCalls": [
                        [
                            "id": "json-call-list",
                            "name": "list_directory",
                            "args": ["path": "."],
                            "status": "success",
                            "result": [],
                        ],
                    ],
                ],
            ],
        ])

        let result = try #require(parser.parseSessionJSON(raw))

        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .toolUse(ChatToolUse(
            toolName: "list_directory",
            summary: "list_directory .",
            inputDetail: #"{"path":"."}"#,
            output: nil,
            status: .succeeded
        )))
    }

    @Test("type-based Antigravity tool calls use their own timestamps")
    func currentTypeBasedToolCallTimestamp() throws {
        let parser = AntigravityTranscriptParser(sessionID: "current-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "gemini",
                    "id": "msg-gemini",
                    "timestamp": "2026-06-19T09:00:00Z",
                    "toolCalls": [
                        [
                            "id": "call-shell",
                            "name": "run_command",
                            "args": ["command": "swift test"],
                            "timestamp": "2026-06-19T09:00:07Z",
                        ],
                    ],
                ]),
            ],
            startingSeq: 12
        )

        let message = try #require(result.messages.first)
        #expect(message.id == "call-shell")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_859_607))
    }

    @Test("single-object Antigravity session JSON maps nested tool authorization events")
    func sessionJSONNestedToolAuthorizationRequest() throws {
        let parser = AntigravityTranscriptParser(sessionID: "json-session")
        let raw = line([
            "sessionId": "json-session",
            "messages": [
                [
                    "role": "event",
                    "name": "tool_authorization_required",
                    "requestId": "auth-read",
                    "timestamp": "2026-06-19T10:00:10Z",
                    "toolCall": [
                        "id": "call-read",
                        "name": "read_file",
                        "args": ["absolute_path": "Package.swift"],
                    ],
                ],
            ],
        ])

        let result = try #require(parser.parseSessionJSON(raw))

        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "permission-auth-read")
        #expect(result.messages[0].seq == 0)
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_863_210))
        #expect(result.messages[0].kind == .permissionRequest(
            ChatPermissionRequest(
                title: "Antigravity wants to use read_file:",
                subject: #"read_file {"absolute_path":"Package.swift"}"#
            )
        ))
    }

    @Test("Antigravity generated message JSON maps sender and recipient roles")
    func generatedMessageJSONMapsSenderRecipientRoles() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")

        let user = try #require(parser.parseSessionJSON(line([
            "id": "message-user",
            "sender": "brain-session",
            "recipient": "brain-session/task-1",
            "timestamp": "2026-06-19T10:01:00Z",
            "content": "Please inspect the failing Antigravity task.",
        ])))
        let agent = try #require(parser.parseSessionJSON(line([
            "id": "message-agent",
            "sender": "brain-session/task-1",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T10:01:05Z",
            "content": "I found the generated message transcript.",
            "renderDetails": ["messageTitle": "Task update"],
        ])))
        let system = try #require(parser.parseSessionJSON(line([
            "id": "message-system",
            "sender": "system",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T10:01:06Z",
            "content": "Antigravity task completed.",
        ])))
        let hidden = try #require(parser.parseSessionJSON(line([
            "id": "message-hidden",
            "sender": "brain-session/task-1",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T10:01:07Z",
            "content": "Internal task note",
            "hideFromUser": true,
        ])))

        #expect(user.messages.count == 1)
        #expect(user.messages[0].id == "message-user")
        #expect(user.messages[0].role == .user)
        #expect(user.messages[0].seq == 0)
        #expect(user.messages[0].kind == .prose(
            ChatProse(text: "Please inspect the failing Antigravity task.")
        ))
        #expect(user.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_863_260))

        #expect(agent.messages.count == 1)
        #expect(agent.messages[0].id == "message-agent")
        #expect(agent.messages[0].role == .agent)
        #expect(agent.messages[0].kind == .prose(
            ChatProse(text: "I found the generated message transcript.")
        ))

        #expect(system.messages.count == 1)
        #expect(system.messages[0].id == "message-system")
        #expect(system.messages[0].role == .system)
        #expect(system.messages[0].kind == .prose(
            ChatProse(text: "Antigravity task completed.")
        ))

        #expect(hidden.messages.isEmpty)
        #expect(hidden.updatedMessages.isEmpty)
        #expect(hidden.stateUpdates.isEmpty)
    }

    @Test("Antigravity generated task results map to terminal captures")
    func generatedTaskResultMessageMapsToTerminal() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = try #require(parser.parseSessionJSON(line([
            "id": "message-task-result",
            "sender": "brain-session/task-30",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T10:01:08Z",
            "renderDetails": ["messageTitle": "Check gh auth finished"],
            "content": """
            Task id "brain-session/task-30" finished with result:

                            The command failed with exit code: 1
                            Output:
                            github.com
              X Timeout trying to log in


            Log: file:///tmp/antigravity/task-30.log
            """,
        ])))

        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "message-task-result")
        #expect(result.messages[0].role == .agent)
        #expect(result.messages[0].kind == .terminal(ChatTerminalCapture(
            command: "Check gh auth",
            output: """
            github.com
              X Timeout trying to log in

            Log: file:///tmp/antigravity/task-30.log
            """,
            exitCode: 1,
            isRunning: false
        )))
    }

    @Test("Antigravity generated command input prompts map to running terminals and needsInput")
    func generatedCommandInputPromptMapsToTerminalAndNeedsInput() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = try #require(parser.parseSessionJSON(line([
            "id": "message-command-input",
            "sender": "brain-session/task-1881",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T11:10:00Z",
            "renderDetails": ["messageTitle": "Relaunch app: Command may require input"],
            "content": """
            The command output has stabilized for 5s. The output delta since last check is:

            Build complete.
            Flutter run key commands.
            r Hot reload.
            q Quit.

            The command appears to be waiting for input: The command is prompting the user to enter a control key.
            """,
        ])))

        #expect(result.messages.count == 1)
        guard let message = result.messages.first else { return }
        #expect(message.id == "message-command-input")
        #expect(message.seq == 0)
        #expect(message.role == .agent)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_867_400))
        #expect(message.kind == .terminal(ChatTerminalCapture(
            command: "Relaunch app",
            output: """
            The command output has stabilized for 5s. The output delta since last check is:

            Build complete.
            Flutter run key commands.
            r Hot reload.
            q Quit.

            The command appears to be waiting for input: The command is prompting the user to enter a control key.
            """,
            isRunning: true
        )))
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .needsInput,
                seq: 0,
                timestamp: Date(timeIntervalSince1970: 1_781_867_400)
            ),
        ])
    }

    @Test("Antigravity generated task result resolves prior command input waits")
    func generatedTaskResultResolvesPriorCommandInputWait() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let first = try #require(parser.parseSessionJSON(line([
            "id": "message-command-input",
            "sender": "brain-session/task-1881",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T11:10:00Z",
            "renderDetails": ["messageTitle": "Relaunch app: Command may require input"],
            "content": """
            The command output has stabilized for 5s. The output delta since last check is:

            Build complete.

            The command appears to be waiting for input: The command is prompting the user to enter a control key.
            """,
        ])))

        let second = try #require(parser.parseSessionJSON(
            line([
                "id": "message-command-result",
                "sender": "brain-session/task-1881",
                "recipient": "brain-session",
                "timestamp": "2026-06-19T11:10:08Z",
                "renderDetails": ["messageTitle": "Relaunch app finished"],
                "content": """
                Task id "brain-session/task-1881" finished with result:

                                The command completed successfully.
                                Output:
                                Build complete.
                                App relaunched.
                """,
            ]),
            startingSeq: 1,
            state: first.state
        ))

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .terminal(let terminal) = second.updatedMessages.first?.kind else {
            Issue.record("expected updated terminal kind")
            return
        }
        #expect(terminal.command == "Relaunch app")
        #expect(terminal.output == "Build complete.\nApp relaunched.")
        #expect(terminal.exitCode == 0)
        #expect(terminal.isRunning == false)
        #expect(second.state.pendingToolUses.isEmpty)
        #expect(second.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 1,
                timestamp: Date(timeIntervalSince1970: 1_781_867_408)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 1,
                timestamp: Date(timeIntervalSince1970: 1_781_867_408)
            ),
        ])
    }

    @Test("Antigravity generated timer messages are suppressed as internal scheduler noise")
    func generatedTimerMessagesAreSuppressed() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = try #require(parser.parseSessionJSON(line([
            "id": "message-timer-check",
            "sender": "brain-session/task-87",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T11:11:00Z",
            "renderDetails": ["messageTitle": "Wait timer: Timer has expired"],
            "content": "Check task-85 output again",
        ])))

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates.isEmpty)
        #expect(result.state.lastTimestamp == Date(timeIntervalSince1970: 1_781_867_460))
    }

    @Test("Antigravity generated timer cancellations are suppressed as internal scheduler noise")
    func generatedTimerCancellationMessagesAreSuppressed() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = try #require(parser.parseSessionJSON(line([
            "id": "message-timer-cancelled",
            "sender": "brain-session/task-10",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T11:12:00Z",
            "renderDetails": ["messageTitle": "Set timer: Timer Cancelled"],
            "content": "Your scheduled timer was cancelled because you received another message.",
        ])))

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates.isEmpty)
        #expect(result.state.lastTimestamp == Date(timeIntervalSince1970: 1_781_867_520))
    }

    @Test("Antigravity generated task control key messages are suppressed as terminal control noise")
    func generatedTaskControlKeyMessagesAreSuppressed() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = try #require(parser.parseSessionJSON(line([
            "id": "message-hot-reload-key",
            "sender": "brain-session",
            "recipient": "brain-session/task-99",
            "timestamp": "2026-06-19T11:12:30Z",
            "content": "R",
        ])))

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates.isEmpty)
        #expect(result.state.lastTimestamp == Date(timeIntervalSince1970: 1_781_867_550))
    }

    @Test("Antigravity generated interruption notices clear transcript-derived working state")
    func generatedInterruptionNoticesClearTranscriptWorkingState() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = try #require(parser.parseSessionJSON(line([
            "id": "message-request-cancelled",
            "sender": "brain-session/task-101",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T11:12:40Z",
            "content": "Request cancelled.",
        ])))

        #expect(result.messages.map(\.kind) == [
            .status(ChatStatusTransition(event: .interrupted, detail: "Request cancelled.")),
        ])
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 0,
                timestamp: Date(timeIntervalSince1970: 1_781_867_560)
            ),
        ])
        #expect(result.state.lastTimestamp == Date(timeIntervalSince1970: 1_781_867_560))
    }

    @Test("Antigravity hidden server restart notices clear transcript-derived working state")
    func hiddenServerRestartNoticesClearTranscriptWorkingState() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = try #require(parser.parseSessionJSON(line([
            "id": "message-server-restart",
            "sender": "system",
            "recipient": "brain-session",
            "timestamp": "2026-06-19T11:13:00Z",
            "hideFromUser": true,
            "content": """
            [Notice] All your subagents and background tasks have been stopped due to server restart. If resuming work, please check on status and restart as needed.
            """,
        ])))

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 0,
                timestamp: Date(timeIntervalSince1970: 1_781_867_580)
            ),
        ])
        #expect(result.state.lastTimestamp == Date(timeIntervalSince1970: 1_781_867_580))
    }

    @Test("single-object Antigravity session JSON rejects malformed or mismatched files")
    func sessionJSONRejectsInvalidFiles() {
        let parser = AntigravityTranscriptParser(sessionID: "json-session")

        #expect(parser.parseSessionJSON(#"{"sessionId":"json-session"}"#) == nil)
        #expect(parser.parseSessionJSON(line([
            "sessionId": "other-session",
            "messages": [],
        ])) == nil)
    }

    @Test("Antigravity brain transcript logs map user, planner, and tool result rows")
    func brainTranscriptLogRows() {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "USER_INPUT",
                    "created_at": "2026-06-19T11:00:00Z",
                    "source": "USER_EXPLICIT",
                    "status": "DONE",
                    "content": "Wire Antigravity brain logs",
                ]),
                line([
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-06-19T11:00:02Z",
                    "source": "MODEL",
                    "status": "DONE",
                    "thinking": "The brain transcript has planner rows.",
                    "content": "I will read the generated transcript.",
                ]),
                line([
                    "type": "RUN_COMMAND",
                    "created_at": "2026-06-19T11:00:05Z",
                    "source": "MODEL",
                    "status": "DONE",
                    "content": "swift test passed",
                ]),
            ],
            startingSeq: 80
        )

        #expect(result.messages.count == 4)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.messages[0].id == "line-80")
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_866_800))
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Wire Antigravity brain logs")))
        #expect(result.messages[1].kind == .thought(ChatThought(text: "The brain transcript has planner rows.")))
        #expect(result.messages[2].kind == .prose(ChatProse(text: "I will read the generated transcript.")))
        #expect(result.messages[3].id == "line-82-brain-tool")
        #expect(result.messages[3].timestamp == Date(timeIntervalSince1970: 1_781_866_805))
        #expect(result.messages[3].kind == .toolUse(ChatToolUse(
            toolName: "RUN_COMMAND",
            summary: "RUN_COMMAND",
            inputDetail: nil,
            output: "swift test passed",
            status: .succeeded
        )))
        #expect(
            ChatTranscriptStateSignal.completedWorkTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_866_805)
        )
        #expect(ChatTranscriptStateSignal.workingTimestamp(in: result.messages) == nil)
    }

    @Test("Antigravity brain transcript type aliases map user, planner, and tool rows")
    func brainTranscriptTypeAliases() {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "USER-INPUT",
                    "created_at": "2026-06-19T11:00:10Z",
                    "content": "Use Antigravity aliases",
                ]),
                line([
                    "type": "PLANNER-RESPONSE",
                    "created_at": "2026-06-19T11:00:12Z",
                    "thinking": "Normalize current transcript row types.",
                    "content": "I will preserve the chat view.",
                ]),
                line([
                    "type": "RUN-COMMAND",
                    "created_at": "2026-06-19T11:00:15Z",
                    "status": "DONE",
                    "content": "swift test passed",
                ]),
            ],
            startingSeq: 85
        )

        #expect(result.messages.count == 4)
        guard result.messages.count == 4 else { return }
        #expect(result.messages[0].id == "line-85")
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Use Antigravity aliases")))
        #expect(result.messages[1].kind == .thought(ChatThought(text: "Normalize current transcript row types.")))
        #expect(result.messages[2].kind == .prose(ChatProse(text: "I will preserve the chat view.")))
        #expect(result.messages[3].id == "line-87-brain-tool")
        #expect(result.messages[3].kind == .toolUse(ChatToolUse(
            toolName: "RUN-COMMAND",
            summary: "RUN-COMMAND",
            inputDetail: nil,
            output: "swift test passed",
            status: .succeeded
        )))
    }

    @Test("Antigravity brain running tool rows remain in progress")
    func brainRunningToolRowsStayRunning() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "RUN_COMMAND",
                    "created_at": "2026-06-19T11:02:00Z",
                    "source": "MODEL",
                    "status": "RUNNING",
                    "content": "Tool is running as a background task with task id bg-1",
                ]),
            ],
            startingSeq: 83
        )

        let message = try #require(result.messages.first)
        #expect(message.id == "line-83-brain-tool")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_866_920))
        #expect(message.kind == .toolUse(ChatToolUse(
            toolName: "RUN_COMMAND",
            summary: "RUN_COMMAND",
            inputDetail: nil,
            output: "Tool is running as a background task with task id bg-1",
            status: .running
        )))
        #expect(
            ChatTranscriptStateSignal.workingTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_866_920)
        )
        #expect(ChatTranscriptStateSignal.completedWorkTimestamp(in: result.messages) == nil)
    }

    @Test("Antigravity error rows clear transcript-derived working state")
    func errorRowsClearTranscriptWorkingState() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "ERROR_MESSAGE",
                    "created_at": "2026-06-19T11:05:00Z",
                    "content": "Tool execution was interrupted",
                ]),
                line([
                    "type": "error",
                    "created_at": "2026-06-19T11:05:01Z",
                    "message": "Model stream closed",
                ]),
                line([
                    "type": "STREAM_ERROR",
                    "created_at": "2026-06-19T11:05:02Z",
                    "message": "Stream disconnected before completion",
                ]),
            ],
            startingSeq: 90
        )

        #expect(result.messages.map(\.kind) == [
            .status(ChatStatusTransition(event: .interrupted, detail: "Tool execution was interrupted")),
            .status(ChatStatusTransition(event: .interrupted, detail: "Model stream closed")),
            .status(ChatStatusTransition(event: .interrupted, detail: "Stream disconnected before completion")),
        ])
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 90,
                timestamp: Date(timeIntervalSince1970: 1_781_867_100)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 91,
                timestamp: Date(timeIntervalSince1970: 1_781_867_101)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 92,
                timestamp: Date(timeIntervalSince1970: 1_781_867_102)
            ),
        ])
    }

    @Test("Antigravity warning rows remain visible as system prose")
    func warningRowsRemainVisibleAsSystemProse() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "warning",
                    "created_at": "2026-06-19T11:06:00Z",
                    "content": "Skill conflict detected: local skill overrides global skill.",
                ]),
            ],
            startingSeq: 93
        )

        let message = try #require(result.messages.first)
        #expect(result.messages.count == 1)
        #expect(message.id == "line-93-warning")
        #expect(message.seq == 93)
        #expect(message.role == .system)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_867_160))
        #expect(message.kind == .prose(ChatProse(
            text: "Skill conflict detected: local skill overrides global skill."
        )))
        #expect(result.stateUpdates.isEmpty)
    }

    @Test("Antigravity info rows remain visible as system prose")
    func infoRowsRemainVisibleAsSystemProse() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "info",
                    "created_at": "2026-06-19T11:06:10Z",
                    "content": "Waiting for MCP servers to initialize...",
                ]),
            ],
            startingSeq: 94
        )

        let message = try #require(result.messages.first)
        #expect(result.messages.count == 1)
        #expect(message.id == "line-94-info")
        #expect(message.seq == 94)
        #expect(message.role == .system)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_867_170))
        #expect(message.kind == .prose(ChatProse(text: "Waiting for MCP servers to initialize...")))
        #expect(result.stateUpdates.isEmpty)
    }

    @Test("Antigravity cancelled info rows clear transcript-derived working state")
    func cancelledInfoRowsClearTranscriptWorkingState() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "info",
                    "created_at": "2026-06-19T11:06:20Z",
                    "content": "Request cancelled.",
                ]),
            ],
            startingSeq: 95
        )

        #expect(result.messages.map(\.kind) == [
            .status(ChatStatusTransition(event: .interrupted, detail: "Request cancelled.")),
        ])
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 95,
                timestamp: Date(timeIntervalSince1970: 1_781_867_180)
            ),
        ])
    }

    @Test("Antigravity failed info rows clear transcript-derived working state")
    func failedInfoRowsClearTranscriptWorkingState() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "info",
                    "created_at": "2026-06-19T11:06:30Z",
                    "content": "This request failed. Press F12 for diagnostics.",
                ]),
                line([
                    "type": "info",
                    "created_at": "2026-06-19T11:06:31Z",
                    "content": "Response stopped due to malformed function call.",
                ]),
            ],
            startingSeq: 96
        )

        #expect(result.messages.map(\.kind) == [
            .status(ChatStatusTransition(
                event: .interrupted,
                detail: "This request failed. Press F12 for diagnostics."
            )),
            .status(ChatStatusTransition(
                event: .interrupted,
                detail: "Response stopped due to malformed function call."
            )),
        ])
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 96,
                timestamp: Date(timeIntervalSince1970: 1_781_867_190)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 97,
                timestamp: Date(timeIntervalSince1970: 1_781_867_191)
            ),
        ])
    }

    @Test("Antigravity authentication info rows emit input state updates")
    func authenticationInfoRowsEmitInputStateUpdates() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "info",
                    "created_at": "2026-06-19T11:06:40Z",
                    "content": """
                    Code Assist login required.
                    Attempting to open authentication page in your browser.
                    """,
                ]),
                line([
                    "type": "info",
                    "created_at": "2026-06-19T11:06:41Z",
                    "content": "Authentication succeeded",
                ]),
            ],
            startingSeq: 98
        )

        #expect(result.messages.map(\.kind) == [
            .prose(ChatProse(text: """
            Code Assist login required.
            Attempting to open authentication page in your browser.
            """)),
            .prose(ChatProse(text: "Authentication succeeded")),
        ])
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .needsInput,
                seq: 98,
                timestamp: Date(timeIntervalSince1970: 1_781_867_200)
            ),
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 99,
                timestamp: Date(timeIntervalSince1970: 1_781_867_201)
            ),
        ])
    }

    @Test("Antigravity brain ASK_QUESTION result rows are preserved")
    func brainAskQuestionResultRowsArePreserved() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let answerSummary = """
        Created At: 2026-06-19T11:03:00Z
        Completed At: 2026-06-19T11:04:00Z
        A1: Continue with the shared parser fix.
        """
        let result = parser.parse(
            lines: [
                line([
                    "type": "ASK_QUESTION",
                    "created_at": "2026-06-19T11:04:00Z",
                    "source": "MODEL",
                    "status": "DONE",
                    "content": answerSummary,
                ]),
            ],
            startingSeq: 84
        )

        let message = try #require(result.messages.first)
        #expect(message.id == "line-84-brain-tool")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_867_040))
        #expect(message.kind == .toolUse(ChatToolUse(
            toolName: "ASK_QUESTION",
            summary: "ASK_QUESTION",
            inputDetail: nil,
            output: answerSummary,
            status: .succeeded
        )))
        #expect(
            ChatTranscriptStateSignal.completedWorkTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_867_040)
        )
    }

    @Test("Antigravity brain READ_URL_CONTENT result rows are preserved")
    func brainReadURLContentResultRowsArePreserved() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let readSummary = """
        Created At: 2026-06-19T11:06:00Z
        Completed At: 2026-06-19T11:06:02Z
        Title: Live reload docs
        Content: Reload the app after changing shared parser code.
        """
        let result = parser.parse(
            lines: [
                line([
                    "type": "READ_URL_CONTENT",
                    "created_at": "2026-06-19T11:06:02Z",
                    "source": "MODEL",
                    "status": "DONE",
                    "content": readSummary,
                ]),
            ],
            startingSeq: 85
        )

        let message = try #require(result.messages.first)
        #expect(message.id == "line-85-brain-tool")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_867_162))
        #expect(message.kind == .toolUse(ChatToolUse(
            toolName: "READ_URL_CONTENT",
            summary: "READ_URL_CONTENT",
            inputDetail: nil,
            output: readSummary,
            status: .succeeded
        )))
        #expect(
            ChatTranscriptStateSignal.completedWorkTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_867_162)
        )
    }

    @Test("Antigravity brain system messages preserve notification content")
    func brainSystemMessagesPreserveNotificationContent() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")

        let result = parser.parse(
            lines: [
                line([
                    "type": "SYSTEM_MESSAGE",
                    "created_at": "2026-06-19T11:01:04Z",
                    "source": "SYSTEM",
                    "status": "DONE",
                    "content": """
                    The following is a <SYSTEM_MESSAGE> not actually sent by the user.

                    <SYSTEM_MESSAGE>
                    [Message] timestamp=2026-06-19T11:01:03Z sender=brain-session/task-6 priority=MESSAGE_PRIORITY_HIGH content=Check task-6 output again
                    </SYSTEM_MESSAGE>
                    """,
                ]),
            ],
            startingSeq: 84
        )

        let message = try #require(result.messages.first)
        #expect(message.id == "line-84-system-message")
        #expect(message.seq == 84)
        #expect(message.role == .system)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_866_864))
        #expect(message.kind == .prose(ChatProse(text: "Check task-6 output again")))
    }

    @Test("Antigravity brain planner question tool calls map to input cards")
    func brainPlannerQuestionToolCall() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-06-19T11:01:00Z",
                    "source": "MODEL",
                    "status": "DONE",
                    "tool_calls": [
                        [
                            "name": "ASK_QUESTION",
                            "args": [
                                "prompt": "Continue with Antigravity brain logs?",
                                "options": ["Yes", "No"],
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 84
        )

        let message = try #require(result.messages.first)
        #expect(message.id == "line-84-brain-tool-0")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_866_860))
        #expect(message.kind == .question(ChatQuestion(
            prompt: "Continue with Antigravity brain logs?",
            options: [
                ChatQuestion.Option(label: "Yes"),
                ChatQuestion.Option(label: "No"),
            ]
        )))
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_866_860)
        )
    }

    @Test("Antigravity brain planner ask_permission tool calls map to permission cards")
    func brainPlannerPermissionToolCall() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-06-19T11:01:05Z",
                    "source": "MODEL",
                    "status": "DONE",
                    "tool_calls": [
                        [
                            "name": "ask_permission",
                            "args": [
                                "Action": #""read_file""#,
                                "Target": #""/tmp/antigravity-background.txt""#,
                                "Reason": #""Need to inspect Antigravity background tasks.""#,
                                "toolSummary": #""Request read permission""#,
                            ],
                        ],
                    ],
                ]),
            ],
            startingSeq: 86
        )

        let message = try #require(result.messages.first)
        #expect(message.id == "permission-line-86-brain-tool-0")
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_866_865))
        #expect(message.kind == .permissionRequest(ChatPermissionRequest(
            title: "Antigravity wants to use read_file:",
            subject: "/tmp/antigravity-background.txt"
        )))
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_866_865)
        )
    }

    @Test("Antigravity brain planner tool call aliases map input cards and terminal captures")
    func brainPlannerToolCallAliases() throws {
        let parser = AntigravityTranscriptParser(sessionID: "brain-session")
        let result = parser.parse(
            lines: [
                line([
                    "type": "PLANNER_RESPONSE",
                    "created_at": "2026-06-19T11:01:10Z",
                    "source": "MODEL",
                    "status": "DONE",
                    "toolCalls": [
                        [
                            "function_name": "ASK-QUESTION",
                            "arguments": line([
                                "prompt": "Use brain planner aliases?",
                                "options": ["Yes", "No"],
                            ]),
                        ],
                        [
                            "call_id": "brain-shell-alias",
                            "function_name": "run_shell_command",
                            "arguments": line([
                                "command": "swift test --filter AntigravityTranscriptParserTests",
                            ]),
                        ],
                    ],
                ]),
            ],
            startingSeq: 88
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].id == "line-88-brain-tool-0")
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_866_870))
        #expect(result.messages[0].kind == .question(ChatQuestion(
            prompt: "Use brain planner aliases?",
            options: [
                ChatQuestion.Option(label: "Yes"),
                ChatQuestion.Option(label: "No"),
            ]
        )))
        #expect(result.messages[1].id == "brain-shell-alias")
        #expect(result.messages[1].kind == .terminal(ChatTerminalCapture(
            command: "swift test --filter AntigravityTranscriptParserTests",
            isRunning: true
        )))
    }
}
