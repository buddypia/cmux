import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixture lines mirror the real `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
/// format (Codex CLI 0.139), with content anonymized.
@Suite("CodexTranscriptParser")
struct CodexTranscriptParserTests {
    private let parser = CodexTranscriptParser()

    private func line(
        type: String,
        payload: [String: Any],
        timestamp: String = "2026-06-11T21:38:05.381Z"
    ) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp, "type": type, "payload": payload,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func messageLine(role: String, texts: [String]) -> String {
        let blockType = role == "assistant" ? "output_text" : "input_text"
        return line(
            type: "response_item",
            payload: [
                "type": "message", "role": role,
                "content": texts.map { ["type": blockType, "text": $0] },
            ]
        )
    }

    private func functionCallLine(
        name: String,
        arguments: String,
        callID: String = "call_1",
        timestamp: String = "2026-06-11T21:38:05.381Z"
    ) -> String {
        line(
            type: "response_item",
            payload: [
                "type": "function_call", "name": name,
                "arguments": arguments, "call_id": callID,
            ],
            timestamp: timestamp
        )
    }

    private func outputLine(
        callID: String = "call_1",
        output: String,
        timestamp: String = "2026-06-11T21:38:05.381Z"
    ) -> String {
        line(
            type: "response_item",
            payload: ["type": "function_call_output", "call_id": callID, "output": output],
            timestamp: timestamp
        )
    }

    // MARK: - Session and prose

    @Test("session_meta maps to a sessionStarted status with the cwd as detail")
    func sessionMeta() {
        let metaLine = line(
            type: "session_meta",
            payload: [
                "id": "019eb89e-aaaa", "timestamp": "2026-06-11T21:38:03.916Z",
                "cwd": "/repo", "originator": "codex-tui", "cli_version": "0.139.0",
            ]
        )
        let result = parser.parse(lines: [metaLine], startingSeq: 0)
        #expect(result.messages.count == 1)
        let message = result.messages[0]
        #expect(message.role == .system)
        #expect(message.kind == .status(
            ChatStatusTransition(event: .sessionStarted, detail: "/repo")
        ))
    }

    @Test("user and assistant messages map to prose; injected context blocks are dropped")
    func proseMapping() {
        let lines = [
            messageLine(role: "developer", texts: ["<permissions instructions>\nstuff"]),
            messageLine(role: "user", texts: [
                "# AGENTS.md instructions for /repo\n<INSTRUCTIONS>...",
                "<environment_context>\n  <cwd>/repo</cwd>\n</environment_context>",
            ]),
            messageLine(role: "user", texts: ["fix the parser"]),
            messageLine(role: "assistant", texts: ["On it."]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "fix the parser")))
        #expect(result.messages[0].seq == 2)
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .prose(ChatProse(text: "On it.")))
    }

    @Test("response_item user messages preserve input_image attachments")
    func responseItemUserMessageInputImageAttachment() {
        let dataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"
        let prompt = line(
            type: "response_item",
            payload: [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": "Describe this screenshot",
                    ],
                    [
                        "type": "input_image",
                        "image_url": dataURL,
                        "detail": "high",
                    ],
                ],
            ]
        )
        let result = parser.parse(lines: [prompt], startingSeq: 5)

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].id == "line-5-attachment-0")
        #expect(result.messages[0].seq == 5)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .attachment(ChatAttachment(media: .image)))
        #expect(result.messages[1].id == "line-5")
        #expect(result.messages[1].seq == 5)
        #expect(result.messages[1].role == .user)
        #expect(result.messages[1].kind == .prose(
            ChatProse(text: "Describe this screenshot")
        ))
    }

    @Test("mirrored Codex user image messages collapse to one visible prompt")
    func mirroredUserImageMessagesCollapse() {
        let dataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"
        let lines = [
            line(
                type: "response_item",
                payload: [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": "Describe this screenshot",
                        ],
                        [
                            "type": "input_image",
                            "image_url": dataURL,
                        ],
                    ],
                ]
            ),
            line(
                type: "event_msg",
                payload: [
                    "type": "user_message",
                    "images": [dataURL],
                    "local_images": [],
                    "message": "Describe this screenshot",
                    "text_elements": [],
                ]
            ),
        ]
        let result = parser.parse(lines: lines, startingSeq: 6)

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].kind == .attachment(ChatAttachment(media: .image)))
        #expect(result.messages[1].kind == .prose(
            ChatProse(text: "Describe this screenshot")
        ))
    }

    @Test("event_msg user_message maps to user prose")
    func eventMessageUserMessage() {
        let prompt = line(
            type: "event_msg",
            payload: [
                "type": "user_message",
                "text": "Check current directory",
            ]
        )
        let result = parser.parse(lines: [prompt], startingSeq: 5)
        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "line-5")
        #expect(result.messages[0].seq == 5)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Check current directory")))
    }

    @Test("event_msg user_message accepts message-key transcripts")
    func eventMessageUserMessageMessageKey() {
        let prompt = line(
            type: "event_msg",
            payload: [
                "type": "user_message",
                "images": [],
                "local_images": [],
                "message": "Summarize the latest Codex transcript.",
                "text_elements": [],
            ]
        )
        let result = parser.parse(lines: [prompt], startingSeq: 6)
        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "line-6")
        #expect(result.messages[0].seq == 6)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .prose(
            ChatProse(text: "Summarize the latest Codex transcript.")
        ))
    }

    @Test("event_msg user_message preserves local image attachments")
    func eventMessageUserMessageLocalImageAttachment() {
        let prompt = line(
            type: "event_msg",
            payload: [
                "type": "user_message",
                "images": [],
                "local_images": ["/tmp/codex-screenshot.png"],
                "message": "What changed in this screenshot?",
                "text_elements": [
                    [
                        "placeholder": "<image 1>",
                        "byte_range": [0, 9],
                    ],
                ],
            ]
        )
        let result = parser.parse(lines: [prompt], startingSeq: 7)

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].id == "line-7-attachment-0")
        #expect(result.messages[0].seq == 7)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[0].kind == .attachment(ChatAttachment(
            media: .image,
            displayName: "codex-screenshot.png",
            hostPath: "/tmp/codex-screenshot.png"
        )))
        #expect(result.messages[1].id == "line-7")
        #expect(result.messages[1].seq == 7)
        #expect(result.messages[1].role == .user)
        #expect(result.messages[1].kind == .prose(
            ChatProse(text: "What changed in this screenshot?")
        ))
    }

    @Test("event_msg agent_message maps to agent prose")
    func eventMessageAgentMessage() {
        let message = line(
            type: "event_msg",
            payload: [
                "type": "agent_message",
                "message": "I'll inspect that now.",
                "phase": "commentary",
            ]
        )
        let result = parser.parse(lines: [message], startingSeq: 8)
        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "line-8")
        #expect(result.messages[0].seq == 8)
        #expect(result.messages[0].role == .agent)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "I'll inspect that now.")))
    }

    @Test("duplicate Codex agent prose event shapes collapse to one message")
    func duplicateAgentProseEventsCollapse() {
        let lines = [
            line(
                type: "event_msg",
                payload: [
                    "type": "agent_message",
                    "message": "All checks passed.",
                    "phase": "final_answer",
                ]
            ),
            messageLine(role: "assistant", texts: ["All checks passed."]),
            line(
                type: "event_msg",
                payload: [
                    "type": "task_complete",
                    "turn_id": "turn-1",
                    "last_agent_message": "All checks passed.",
                ]
            ),
        ]
        let result = parser.parse(lines: lines, startingSeq: 20)
        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "line-20")
        #expect(result.messages[0].seq == 20)
        #expect(result.messages[0].role == .agent)
        #expect(result.messages[0].kind == .prose(ChatProse(text: "All checks passed.")))
    }

    @Test("task_complete last_agent_message is a fallback across parse calls")
    func taskCompleteLastAgentMessageFallback() {
        let first = parser.parse(
            lines: [messageLine(role: "assistant", texts: ["Final answer."])],
            startingSeq: 30
        )
        let duplicate = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "task_complete",
                        "turn_id": "turn-2",
                        "last_agent_message": "Final answer.",
                    ]
                ),
            ],
            startingSeq: 31,
            state: first.state
        )
        #expect(duplicate.messages.isEmpty)

        let fallback = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "task_complete",
                        "turn_id": "turn-3",
                        "last_agent_message": "Only final answer.",
                    ]
                ),
            ],
            startingSeq: 40
        )
        #expect(fallback.messages.count == 1)
        guard fallback.messages.count == 1 else { return }
        #expect(fallback.messages[0].id == "line-40")
        #expect(fallback.messages[0].kind == .prose(ChatProse(text: "Only final answer.")))
    }

    @Test("reasoning summaries concatenate into a thought; empty summaries are skipped")
    func reasoning() {
        let lines = [
            line(type: "response_item", payload: [
                "type": "reasoning", "summary": [], "encrypted_content": "gAAAA",
            ]),
            line(type: "response_item", payload: [
                "type": "reasoning",
                "summary": [
                    ["type": "summary_text", "text": "Inspect the file"],
                    ["type": "summary_text", "text": "Then run tests"],
                ],
            ]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .thought(
            ChatThought(text: "Inspect the file\n\nThen run tests")
        ))
    }

    @Test("event_msg agent_reasoning maps visible text to thoughts")
    func eventMessageAgentReasoning() {
        let lines = [
            line(type: "event_msg", payload: [
                "type": "agent_reasoning",
                "text": "Inspect the failing parser.",
            ]),
            line(type: "event_msg", payload: [
                "type": "agent_reasoning",
                "summary": [
                    ["type": "summary_text", "text": "Patch the case"],
                    ["type": "summary_text", "text": "Run focused tests"],
                ],
            ]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 50)
        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].seq == 50)
        #expect(result.messages[0].role == .agent)
        #expect(result.messages[0].kind == .thought(
            ChatThought(text: "Inspect the failing parser.")
        ))
        #expect(result.messages[1].seq == 51)
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .thought(
            ChatThought(text: "Patch the case\n\nRun focused tests")
        ))
    }

    @Test("event_msg item_completed Plan maps visible text to a thought")
    func eventMessageItemCompletedPlan() {
        let result = parser.parse(
            lines: [
                line(type: "event_msg", payload: [
                    "type": "item_completed",
                    "thread_id": "thread-1",
                    "turn_id": "turn-1",
                    "item": [
                        "id": "plan-1",
                        "type": "Plan",
                        "text": "Inspect transcript events, then patch the parser.",
                    ],
                ]),
            ],
            startingSeq: 52
        )

        #expect(result.messages.count == 1)
        guard let message = result.messages.first else { return }
        #expect(message.id == "line-52")
        #expect(message.seq == 52)
        #expect(message.role == .agent)
        #expect(message.kind == .thought(
            ChatThought(text: "Inspect transcript events, then patch the parser.")
        ))
    }

    // MARK: - Shell calls

    @Test("exec_command extracts the cmd string from the arguments JSON string")
    func execCommand() {
        let call = functionCallLine(
            name: "exec_command",
            arguments: #"{"cmd":"rg -n \"foo\" .","workdir":"/repo","yield_time_ms":10000}"#
        )
        let result = parser.parse(lines: [call], startingSeq: 7)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].id == "call_1")
        #expect(result.messages[0].seq == 7)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == #"rg -n "foo" ."#)
        #expect(capture.isRunning)
    }

    @Test("shell tool name aliases map to terminal captures")
    func shellToolNameAliasesMapToTerminalCaptures() {
        let call = functionCallLine(
            name: "EXEC-COMMAND",
            arguments: #"{"cmd":"swift test --filter CodexTranscriptParserTests"}"#
        )
        let result = parser.parse(lines: [call], startingSeq: 8)
        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages.first?.id == "call_1")
        #expect(result.messages.first?.seq == 8)
        #expect(capture.command == "swift test --filter CodexTranscriptParserTests")
        #expect(capture.isRunning)
    }

    @Test("function_call object arguments map terminal captures and question cards")
    func functionCallObjectArguments() {
        let result = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "function_call",
                        "call_id": "call_object_shell",
                        "name": "exec_command",
                        "arguments": [
                            "cmd": "swift test --filter CodexTranscriptParserTests",
                            "workdir": "/repo",
                        ],
                    ]
                ),
                line(
                    type: "response_item",
                    payload: [
                        "type": "function_call",
                        "call_id": "call_object_question",
                        "name": "request_user_input",
                        "arguments": [
                            "prompt": "Use object arguments?",
                            "options": ["Yes", "No"],
                        ],
                    ]
                ),
            ],
            startingSeq: 9
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].id == "call_object_shell")
        #expect(result.messages[0].seq == 9)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter CodexTranscriptParserTests")
        #expect(capture.isRunning)
        #expect(result.messages[1].id == "call_object_question")
        guard case .question(let question) = result.messages[1].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(question.prompt == "Use object arguments?")
        #expect(question.options.map(\.label) == ["Yes", "No"])
    }

    @Test("shell extracts the script from a bash -lc command array")
    func shellCommandArray() {
        let call = functionCallLine(
            name: "shell",
            arguments: #"{"command":["bash","-lc","echo hi"],"timeout_ms":5000}"#
        )
        let result = parser.parse(lines: [call], startingSeq: 0)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "echo hi")
    }

    @Test("function_call_output in the same call completes the terminal with exit code and wall time")
    func outputSameCall() {
        let lines = [
            functionCallLine(name: "exec_command", arguments: #"{"cmd":"swift build"}"#),
            outputLine(output: "Chunk ID: 8f9491\nWall time: 1.5000 seconds\nProcess exited with code 0\nOutput:\nBuild complete!"),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 1.5)
        #expect(!capture.isRunning)
        #expect(capture.output?.contains("Build complete!") == true)
    }

    @Test("function_call_output keeps terminal running when Codex reports a process session")
    func outputProcessRunningSession() {
        let lines = [
            functionCallLine(
                name: "exec_command",
                arguments: #"{"cmd":"npm run dev","yield_time_ms":1000}"#
            ),
            outputLine(
                output:
                    "Chunk ID: abc123\n"
                    + "Wall time: 1.0000 seconds\n"
                    + "Process running with session ID 42\n"
                    + "Original token count: 10\n"
                    + "Output:\nServer started"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "npm run dev")
        #expect(capture.output?.contains("Process running with session ID 42") == true)
        #expect(capture.exitCode == nil)
        #expect(capture.durationSeconds == 1.0)
        #expect(capture.isRunning)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("write_stdin session continuations map to terminal captures")
    func writeStdinSessionContinuationMapsToTerminalCapture() {
        let lines = [
            functionCallLine(
                name: "write_stdin",
                arguments: #"{"session_id":42,"chars":"","yield_time_ms":1000,"max_output_tokens":2000}"#,
                callID: "call_stdin_poll"
            ),
            outputLine(
                callID: "call_stdin_poll",
                output:
                    "Chunk ID: def456\n"
                    + "Wall time: 1.0000 seconds\n"
                    + "Process exited with code 0\n"
                    + "Original token count: 10\n"
                    + "Output:\nServer stopped"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "write_stdin session 42")
        #expect(capture.output?.contains("Server stopped") == true)
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 1.0)
        #expect(capture.isRunning == false)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("write_stdin failure outputs mark terminal continuations as failed")
    func writeStdinFailureOutputMarksTerminalContinuationAsFailed() {
        let lines = [
            functionCallLine(
                name: "write_stdin",
                arguments: #"{"session_id":42,"chars":"","yield_time_ms":1000,"max_output_tokens":2000}"#,
                callID: "call_stdin_failed"
            ),
            outputLine(
                callID: "call_stdin_failed",
                output:
                    "write_stdin failed: stdin is closed for this session; "
                    + "rerun exec_command with tty=true to keep stdin open"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "write_stdin session 42")
        #expect(capture.output?.hasPrefix("write_stdin failed:") == true)
        #expect(capture.exitCode == 1)
        #expect(capture.durationSeconds == nil)
        #expect(capture.isRunning == false)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("response_item tool call id aliases pair with output id aliases")
    func responseItemToolCallIDAliasesPairWithOutputIDAliases() {
        let lines = [
            line(
                type: "response_item",
                payload: [
                    "type": "function_call",
                    "id": "call_id_alias",
                    "name": "exec_command",
                    "arguments": #"{"cmd":"swift test --filter CodexTranscriptParserTests"}"#,
                ],
                timestamp: "2026-06-11T21:38:05.000Z"
            ),
            line(
                type: "response_item",
                payload: [
                    "type": "function_call_output",
                    "id": "call_id_alias",
                    "output": "Wall time: 2.2500 seconds\nExit code: 0\nOutput:\nCodex parser tests passed",
                ],
                timestamp: "2026-06-11T21:38:08.000Z"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 9)

        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "call_id_alias")
        #expect(result.messages[0].seq == 9)
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_213_888))
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter CodexTranscriptParserTests")
        #expect(capture.output?.contains("Codex parser tests passed") == true)
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 2.25)
        #expect(capture.isRunning == false)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("response_item tool calls accept camelCase and tool_call_id aliases")
    func responseItemToolCallCamelCaseAndToolCallIDAliases() {
        let lines = [
            line(
                type: "response_item",
                payload: [
                    "type": "function_call",
                    "callId": "call_camel_alias",
                    "name": "exec_command",
                    "arguments": #"{"cmd":"swift test --filter CodexTranscriptParserTests"}"#,
                ],
                timestamp: "2026-06-11T21:38:05.000Z"
            ),
            line(
                type: "response_item",
                payload: [
                    "type": "function_call_output",
                    "tool_call_id": "call_camel_alias",
                    "output": "Wall time: 1.1250 seconds\nExit code: 0\nOutput:\nCamel alias passed",
                ],
                timestamp: "2026-06-11T21:38:08.000Z"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 10)

        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "call_camel_alias")
        #expect(result.messages[0].seq == 10)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.output?.contains("Camel alias passed") == true)
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 1.125)
        #expect(capture.isRunning == false)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("function_call_output in a later parse call re-emits via updatedMessages")
    func outputAcrossCalls() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"make"}"#,
                    callID: "call_z",
                    timestamp: "2026-06-11T21:38:05.000Z"
                ),
            ],
            startingSeq: 3
        )
        #expect(first.state.pendingToolUses.count == 1)
        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call_z",
                    output: "Process exited with code 1\nOutput:\nerror",
                    timestamp: "2026-06-11T21:38:11.000Z"
                ),
            ],
            startingSeq: 4,
            state: first.state
        )
        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        let updated = second.updatedMessages[0]
        #expect(updated.id == "call_z")
        #expect(updated.seq == 3)
        #expect(updated.timestamp == Date(timeIntervalSince1970: 1_781_213_891))
        #expect(
            ChatTranscriptStateSignal.completedWorkTimestamp(in: second.updatedMessages)
                == Date(timeIntervalSince1970: 1_781_213_891)
        )
        guard case .terminal(let capture) = updated.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.exitCode == 1)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg exec_command_end completes a pending terminal")
    func eventMessageExecCommandEndCompletesPendingTerminal() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"swift test"}"#,
                    callID: "call_exec_end",
                    timestamp: "2026-06-19T08:00:00.000Z"
                ),
            ],
            startingSeq: 10
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_end",
                        "call_id": "call_exec_end",
                        "aggregated_output": "Build complete\n",
                        "exit_code": 0,
                        "duration": ["secs": 2, "nanos": 500_000_000],
                    ],
                    timestamp: "2026-06-19T08:00:03.000Z"
                ),
            ],
            startingSeq: 11,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .terminal(let capture) = second.updatedMessages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(second.updatedMessages.first?.timestamp == Date(timeIntervalSince1970: 1_781_856_003))
        #expect(capture.command == "swift test")
        #expect(capture.output == "Build complete\n")
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 2.5)
        #expect(capture.isRunning == false)
    }

    @Test("event_msg exec_command_begin starts a pending terminal")
    func eventMessageExecCommandBeginStartsPendingTerminal() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_begin",
                        "call_id": "call_exec_begin",
                        "cmd": "swift test --package-path Packages/Shared/CmuxAgentChat --quiet",
                    ],
                    timestamp: "2026-06-19T08:00:00.000Z"
                ),
            ],
            startingSeq: 12
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages.first?.id == "call_exec_begin")
        #expect(result.messages.first?.seq == 12)
        #expect(capture.command == "swift test --package-path Packages/Shared/CmuxAgentChat --quiet")
        #expect(capture.output == nil)
        #expect(capture.isRunning == true)
        #expect(result.state.pendingToolUses["call_exec_begin"]?.count == 1)
    }

    @Test("event_msg exec_command_begin pairs with exec_command_end in the same batch")
    func eventMessageExecCommandBeginPairsWithEndInSameBatch() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_begin",
                        "call_id": "call_exec_begin_end",
                        "command": "swift test --filter CodexTranscriptParserTests",
                    ],
                    timestamp: "2026-06-19T08:00:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_end",
                        "call_id": "call_exec_begin_end",
                        "aggregated_output": "Selected tests passed\n",
                        "exit_code": 0,
                    ],
                    timestamp: "2026-06-19T08:00:05.000Z"
                ),
            ],
            startingSeq: 14
        )

        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages.first?.id == "call_exec_begin_end")
        #expect(result.messages.first?.seq == 14)
        #expect(result.messages.first?.timestamp == Date(timeIntervalSince1970: 1_781_856_005))
        #expect(capture.command == "swift test --filter CodexTranscriptParserTests")
        #expect(capture.output == "Selected tests passed\n")
        #expect(capture.exitCode == 0)
        #expect(capture.isRunning == false)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg exec_command_end without a pending begin still renders a completed terminal")
    func eventMessageExecCommandEndFallbackRendersCompletedTerminal() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_end",
                        "call_id": "call_exec_end_only",
                        "command": "swift test --filter CodexTranscriptParserTests",
                        "aggregated_output": "Selected tests passed\n",
                        "exit_code": 0,
                        "duration_ms": 4_200,
                    ],
                    timestamp: "2026-06-19T08:00:07.000Z"
                ),
            ],
            startingSeq: 16
        )

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages.first?.id == "call_exec_end_only")
        #expect(result.messages.first?.seq == 16)
        #expect(capture.command == "swift test --filter CodexTranscriptParserTests")
        #expect(capture.output == "Selected tests passed\n")
        #expect(capture.exitCode == 0)
        #expect(capture.durationSeconds == 4.2)
        #expect(capture.isRunning == false)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg exec_command_end accepts camelCase output, exit, and duration aliases")
    func eventMessageExecCommandEndAcceptsOutputExitAndDurationAliases() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"swift test --filter CodexTranscriptParserTests"}"#,
                    callID: "call_exec_end_aliases",
                    timestamp: "2026-06-19T08:00:00.000Z"
                ),
            ],
            startingSeq: 12
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_end",
                        "callId": "call_exec_end_aliases",
                        "formattedOutput": "Alias build failed\n",
                        "exitCode": 2,
                        "duration_ms": 1_250,
                    ],
                    timestamp: "2026-06-19T08:00:02.000Z"
                ),
            ],
            startingSeq: 13,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .terminal(let capture) = second.updatedMessages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter CodexTranscriptParserTests")
        #expect(capture.output == "Alias build failed\n")
        #expect(capture.exitCode == 2)
        #expect(capture.durationSeconds == 1.25)
        #expect(capture.isRunning == false)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg exec_command_end normalizes status strings with spaces")
    func eventMessageExecCommandEndNormalizesStatusStringsWithSpaces() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"swift test --filter TimedOutStatus"}"#,
                    callID: "call_exec_status_spaces",
                    timestamp: "2026-06-19T08:00:04.000Z"
                ),
            ],
            startingSeq: 14
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_end",
                        "call_id": "call_exec_status_spaces",
                        "aggregated_output": "Timed out\n",
                        "status": "timed out",
                    ],
                    timestamp: "2026-06-19T08:00:08.000Z"
                ),
            ],
            startingSeq: 15,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .terminal(let capture) = second.updatedMessages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter TimedOutStatus")
        #expect(capture.output == "Timed out\n")
        #expect(capture.exitCode == 1)
        #expect(capture.isRunning == false)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg exec_command_end parses string exit codes")
    func eventMessageExecCommandEndParsesStringExitCodes() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"swift test --filter StringExitCode"}"#,
                    callID: "call_exec_string_exit_code",
                    timestamp: "2026-06-19T08:00:09.000Z"
                ),
            ],
            startingSeq: 16
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_command_end",
                        "call_id": "call_exec_string_exit_code",
                        "aggregated_output": "String exit failed\n",
                        "exit_code": "2",
                    ],
                    timestamp: "2026-06-19T08:00:10.000Z"
                ),
            ],
            startingSeq: 17,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .terminal(let capture) = second.updatedMessages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter StringExitCode")
        #expect(capture.output == "String exit failed\n")
        #expect(capture.exitCode == 2)
        #expect(capture.isRunning == false)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("function_call_output parses JSON metadata string values for terminal completions")
    func functionCallOutputParsesJSONMetadataStringValuesForTerminalCompletions() {
        let lines = [
            functionCallLine(
                name: "exec_command",
                arguments: #"{"cmd":"swift test --filter OutputMetadataStrings"}"#,
                callID: "call_output_metadata_strings",
                timestamp: "2026-06-19T08:00:11.000Z"
            ),
            outputLine(
                callID: "call_output_metadata_strings",
                output: #"{"output":"metadata strings failed","metadata":{"exit_code":"2","duration_seconds":"0.125"}}"#,
                timestamp: "2026-06-19T08:00:12.000Z"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 18)

        #expect(result.messages.count == 1)
        guard case .terminal(let capture) = result.messages.first?.kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(capture.command == "swift test --filter OutputMetadataStrings")
        #expect(capture.output == "metadata strings failed")
        #expect(capture.exitCode == 2)
        #expect(capture.durationSeconds == 0.125)
        #expect(capture.isRunning == false)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("function_call_output unwraps JSON result string values")
    func functionCallOutputUnwrapsJSONResultString() {
        let lines = [
            functionCallLine(
                name: "mcp__serena__activate_project",
                arguments: #"{"project":"/repo"}"#,
                callID: "call_output_result_string"
            ),
            outputLine(
                callID: "call_output_result_string",
                output: #"{"result":"Created and activated a new project."}"#
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 18)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "mcp__serena__activate_project")
        #expect(tool.output == "Created and activated a new project.")
        #expect(tool.status == .succeeded)
    }

    // MARK: - Other tools

    @Test("non-shell function calls map to toolUse and JSON-object outputs fill exit info")
    func genericFunctionCall() {
        let lines = [
            functionCallLine(
                name: "update_plan",
                arguments: #"{"plan":[{"step":"do it","status":"pending"}]}"#,
                callID: "call_p"
            ),
            outputLine(
                callID: "call_p",
                output: #"{"output":"plan rejected","metadata":{"exit_code":2,"duration_seconds":0.1}}"#
            ),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "update_plan")
        #expect(tool.output == "plan rejected")
        #expect(tool.status == .failed)
        #expect(tool.inputDetail?.contains("plan") == true)
    }

    @Test("namespaced MCP function calls show the fully qualified tool name")
    func namespacedMCPFunctionCall() {
        let lines = [
            line(
                type: "response_item",
                payload: [
                    "type": "function_call",
                    "call_id": "call_mcp_namespace",
                    "namespace": "mcp__computer_use__",
                    "name": "get_app_state",
                    "arguments": #"{"app":"Safari"}"#,
                ]
            ),
            outputLine(callID: "call_mcp_namespace", output: "Computer Use state captured."),
        ]

        let result = parser.parse(lines: lines, startingSeq: 18)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "mcp__computer_use__get_app_state")
        #expect(tool.summary == "mcp__computer_use__get_app_state Safari")
        #expect(tool.output == "Computer Use state captured.")
        #expect(tool.status == .succeeded)
    }

    @Test("namespaced MCP function calls accept namespaces without a trailing separator")
    func namespacedMCPFunctionCallWithoutTrailingSeparator() {
        let lines = [
            line(
                type: "response_item",
                payload: [
                    "type": "function_call",
                    "call_id": "call_mcp_namespace_no_trailing",
                    "namespace": "mcp__supabase",
                    "name": "execute_sql",
                    "arguments": #"{"query":"select 1"}"#,
                ]
            ),
            outputLine(callID: "call_mcp_namespace_no_trailing", output: "Rows returned."),
        ]

        let result = parser.parse(lines: lines, startingSeq: 20)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "mcp__supabase__execute_sql")
        #expect(tool.summary == "mcp__supabase__execute_sql select 1")
        #expect(tool.output == "Rows returned.")
        #expect(tool.status == .succeeded)
    }

    @Test("non-shell function calls parse JSON metadata string values")
    func genericFunctionCallParsesJSONMetadataStringValues() {
        let lines = [
            functionCallLine(
                name: "update_plan",
                arguments: #"{"plan":[{"step":"do it","status":"pending"}]}"#,
                callID: "call_p_strings"
            ),
            outputLine(
                callID: "call_p_strings",
                output: #"{"output":"plan timed out","metadata":{"exit_code":"3","duration_seconds":"0.25"}}"#
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "update_plan")
        #expect(tool.output == "plan timed out")
        #expect(tool.status == .failed)
        #expect(tool.inputDetail?.contains("plan") == true)
    }

    @Test("function_call_output content arrays keep text and drop embedded images")
    func outputContentArray() {
        let lines = [
            functionCallLine(
                name: "mcp__computer_use__get_app_state",
                arguments: #"{"app":"Antigravity"}"#,
                callID: "call_cua"
            ),
            line(
                type: "response_item",
                payload: [
                    "type": "function_call_output",
                    "call_id": "call_cua",
                    "output": [
                        [
                            "type": "input_text",
                            "text": "Wall time: 0.5270 seconds\nOutput:",
                        ],
                        [
                            "type": "input_text",
                            "text": "Computer Use state\n<app_state>Window: Antigravity</app_state>",
                        ],
                        [
                            "type": "input_image",
                            "image_url": "data:image/png;base64,AAAA",
                        ],
                    ],
                ]
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 38)
        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "mcp__computer_use__get_app_state")
        #expect(tool.output?.contains("Computer Use state") == true)
        #expect(tool.output?.contains("data:image/png;base64") == false)
        #expect(tool.status == .succeeded)
    }

    @Test("mcp_tool_call_end extracts nested MCP text content")
    func eventMessageMCPToolCallEndTextContent() {
        let lines = [
            functionCallLine(
                name: "mcp__serena__activate_project",
                arguments: #"{"project":"/repo"}"#,
                callID: "call_mcp_ok"
            ),
            line(
                type: "event_msg",
                payload: [
                    "type": "mcp_tool_call_end",
                    "call_id": "call_mcp_ok",
                    "duration": ["secs": 1, "nanos": 250_000_000],
                    "result": [
                        "Ok": [
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Created and activated a new project.",
                                ],
                            ],
                            "structuredContent": [
                                "result": "Created and activated a new project.",
                            ],
                            "isError": false,
                        ],
                    ],
                ],
                timestamp: "2026-06-19T08:10:00.000Z"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 40)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "mcp__serena__activate_project")
        #expect(tool.output == "Created and activated a new project.")
        #expect(tool.status == .succeeded)
    }

    @Test("mcp_tool_call_end extracts structured MCP message content")
    func eventMessageMCPToolCallEndStructuredMessageContent() {
        let lines = [
            functionCallLine(
                name: "mcp__github__get_pull_request",
                arguments: #"{"owner":"buddypia","repo":"agent-studio","pullNumber":42}"#,
                callID: "call_mcp_structured"
            ),
            line(
                type: "event_msg",
                payload: [
                    "type": "mcp_tool_call_end",
                    "call_id": "call_mcp_structured",
                    "result": [
                        "Ok": [
                            "structuredContent": [
                                "message": "Pull request loaded.",
                                "number": 42,
                            ],
                            "isError": false,
                        ],
                    ],
                ],
                timestamp: "2026-06-19T08:10:00.000Z"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 42)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "mcp__github__get_pull_request")
        #expect(tool.output == "Pull request loaded.")
        #expect(tool.status == .succeeded)
    }

    @Test("mcp_tool_call_end Ok isError results fail with structured message content")
    func eventMessageMCPToolCallEndOkIsErrorStructuredMessageContent() {
        let lines = [
            functionCallLine(
                name: "mcp__github__add_issue_comment",
                arguments: #"{"owner":"buddypia","repo":"agent-studio","issueNumber":42}"#,
                callID: "call_mcp_ok_error"
            ),
            line(
                type: "event_msg",
                payload: [
                    "type": "mcp_tool_call_end",
                    "call_id": "call_mcp_ok_error",
                    "result": [
                        "Ok": [
                            "structured_content": [
                                "message": "Permission denied.",
                                "code": "forbidden",
                            ],
                            "isError": true,
                        ],
                    ],
                ],
                timestamp: "2026-06-19T08:10:01.000Z"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 43)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.output == "Permission denied.")
        #expect(tool.status == .failed)
    }

    @Test("mcp_tool_call_end Err results fail the pending tool")
    func eventMessageMCPToolCallEndErrorResult() {
        let lines = [
            functionCallLine(
                name: "mcp__supabase__get_advisors",
                arguments: #"{"type":"security"}"#,
                callID: "call_mcp_err"
            ),
            line(
                type: "event_msg",
                payload: [
                    "type": "mcp_tool_call_end",
                    "call_id": "call_mcp_err",
                    "result": [
                        "Err": "tool call error: Auth required",
                    ],
                ],
                timestamp: "2026-06-19T08:10:01.000Z"
            ),
        ]

        let result = parser.parse(lines: lines, startingSeq: 42)

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.output == "tool call error: Auth required")
        #expect(tool.status == .failed)
    }

    @Test("event_msg mcp_tool_call_begin starts a pending MCP tool")
    func eventMessageMCPToolCallBeginStartsPendingTool() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "mcp_tool_call_begin",
                        "call_id": "call_mcp_begin",
                        "server": "github",
                        "tool": "get_pull_request",
                        "arguments": [
                            "owner": "buddypia",
                            "repo": "agent-studio",
                            "pullNumber": "42",
                        ],
                    ],
                    timestamp: "2026-06-19T08:10:02.000Z"
                ),
            ],
            startingSeq: 44
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "call_mcp_begin")
        #expect(result.messages.first?.seq == 44)
        #expect(tool.toolName == "mcp__github__get_pull_request")
        #expect(tool.summary == "mcp__github__get_pull_request agent-studio")
        #expect(tool.inputDetail?.contains("pullNumber") == true)
        #expect(tool.status == .running)
        #expect(result.state.pendingToolUses["call_mcp_begin"]?.count == 1)
    }

    @Test("event_msg mcp_tool_call_begin pairs with mcp_tool_call_end in the same batch")
    func eventMessageMCPToolCallBeginPairsWithEndInSameBatch() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "mcp_tool_call_begin",
                        "call_id": "call_mcp_begin_end",
                        "server": "github",
                        "tool": "get_pull_request",
                        "arguments": #"{"owner":"buddypia","repo":"agent-studio","pullNumber":42}"#,
                    ],
                    timestamp: "2026-06-19T08:10:03.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "mcp_tool_call_end",
                        "call_id": "call_mcp_begin_end",
                        "result": [
                            "Ok": [
                                "structuredContent": [
                                    "message": "Pull request loaded.",
                                    "number": 42,
                                ],
                                "isError": false,
                            ],
                        ],
                    ],
                    timestamp: "2026-06-19T08:10:04.000Z"
                ),
            ],
            startingSeq: 45
        )

        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "call_mcp_begin_end")
        #expect(result.messages.first?.seq == 45)
        #expect(result.messages.first?.timestamp == Date(timeIntervalSince1970: 1_781_856_604))
        #expect(tool.toolName == "mcp__github__get_pull_request")
        #expect(tool.output == "Pull request loaded.")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg mcp_tool_call_end without a pending begin still renders a completed tool")
    func eventMessageMCPToolCallEndFallbackRendersCompletedTool() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "mcp_tool_call_end",
                        "call_id": "call_mcp_end_only",
                        "server": "github",
                        "tool": "get_pull_request",
                        "arguments": [
                            "owner": "buddypia",
                            "repo": "agent-studio",
                            "pullNumber": "42",
                        ],
                        "result": [
                            "Ok": [
                                "structuredContent": [
                                    "message": "Pull request loaded.",
                                    "number": 42,
                                ],
                                "isError": false,
                            ],
                        ],
                    ],
                    timestamp: "2026-06-19T08:10:06.000Z"
                ),
            ],
            startingSeq: 48
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "call_mcp_end_only")
        #expect(result.messages.first?.seq == 48)
        #expect(tool.toolName == "mcp__github__get_pull_request")
        #expect(tool.summary == "mcp__github__get_pull_request agent-studio")
        #expect(tool.output == "Pull request loaded.")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("tool_search_call maps to a pending tool and tool_search_output completes it")
    func toolSearchCallOutput() {
        let first = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "tool_search_call",
                        "call_id": "call_tool_search",
                        "status": "completed",
                        "arguments": [
                            "query": "browser automation",
                            "limit": 8,
                        ],
                    ]
                ),
            ],
            startingSeq: 34
        )
        #expect(first.messages.count == 1)
        guard case .toolUse(let running) = first.messages.first?.kind else {
            Issue.record("expected running toolUse")
            return
        }
        #expect(first.messages.first?.id == "call_tool_search")
        #expect(running.toolName == "tool_search")
        #expect(running.summary == "tool_search browser automation")
        #expect(running.status == .running)
        #expect(running.inputDetail?.contains("browser automation") == true)
        #expect(first.state.pendingToolUses["call_tool_search"]?.count == 1)

        let second = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "tool_search_output",
                        "call_id": "call_tool_search",
                        "status": "completed",
                        "tools": [[
                            "name": "browser",
                            "description": "Control the in-app browser",
                        ]],
                    ]
                ),
            ],
            startingSeq: 35,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let completed) = second.updatedMessages.first?.kind else {
            Issue.record("expected completed toolUse")
            return
        }
        #expect(completed.toolName == "tool_search")
        #expect(completed.status == .succeeded)
        #expect(completed.output?.contains("browser") == true)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("tool_search_call accepts id aliases and JSON string arguments")
    func toolSearchCallIDAliasAndJSONStringArguments() {
        let first = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "tool_search_call",
                        "id": "tool_search_id_alias",
                        "status": "completed",
                        "arguments": #"{"query":"browser automation","limit":8}"#,
                    ]
                ),
            ],
            startingSeq: 36
        )
        #expect(first.messages.count == 1)
        guard case .toolUse(let running) = first.messages.first?.kind else {
            Issue.record("expected running toolUse")
            return
        }
        #expect(first.messages.first?.id == "tool_search_id_alias")
        #expect(running.toolName == "tool_search")
        #expect(running.summary == "tool_search browser automation")
        #expect(running.status == .running)
        #expect(running.inputDetail?.contains("browser automation") == true)
        #expect(first.state.pendingToolUses["tool_search_id_alias"]?.count == 1)

        let second = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "tool_search_output",
                        "id": "tool_search_id_alias",
                        "status": "completed",
                        "tools": [[
                            "name": "browser",
                            "description": "Control the in-app browser",
                        ]],
                    ]
                ),
            ],
            startingSeq: 37,
            state: first.state
        )

        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let completed) = second.updatedMessages.first?.kind else {
            Issue.record("expected completed toolUse")
            return
        }
        #expect(completed.toolName == "tool_search")
        #expect(completed.status == .succeeded)
        #expect(completed.output?.contains("browser") == true)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("web_search_call maps current query arrays to one completed search row")
    func webSearchCallQueryArray() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "web_search_end",
                        "call_id": "ws_1",
                        "action": [
                            "type": "search",
                            "queries": [
                                "Swift Testing documentation",
                                "Xcode derived data settings",
                            ],
                        ],
                    ],
                    timestamp: "2026-06-19T08:08:00.000Z"
                ),
                line(
                    type: "response_item",
                    payload: [
                        "type": "web_search_call",
                        "status": "completed",
                        "action": [
                            "type": "search",
                            "queries": [
                                "Swift Testing documentation",
                                "Xcode derived data settings",
                            ],
                        ],
                    ],
                    timestamp: "2026-06-19T08:08:00.003Z"
                ),
            ],
            startingSeq: 36
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let search) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.seq == 37)
        #expect(search.toolName == "web_search")
        #expect(search.summary == "Search Swift Testing documentation; Xcode derived data settings")
        #expect(search.output == nil)
        #expect(search.status == .succeeded)
    }

    @Test("sparse web_search_end falls back to its top-level query")
    func sparseWebSearchEndFallsBackToQuery() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "web_search_end",
                        "call_id": "ws_sparse",
                        "query": "Swift Testing package path",
                        "action": [
                            "type": "open_page",
                        ],
                    ],
                    timestamp: "2026-06-19T08:08:02.000Z"
                ),
            ],
            startingSeq: 38
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let search) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ws_sparse")
        #expect(search.toolName == "web_search")
        #expect(search.summary == "Search Swift Testing package path")
        #expect(search.output == nil)
        #expect(search.status == .succeeded)
    }

    @Test("event_msg web_search_begin starts a pending web search tool")
    func eventMessageWebSearchBeginStartsPendingTool() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "web_search_begin",
                        "call_id": "ws_begin",
                        "action": [
                            "type": "search",
                            "query": "Swift Testing package path",
                        ],
                    ],
                    timestamp: "2026-06-19T08:08:03.000Z"
                ),
            ],
            startingSeq: 39
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let search) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ws_begin")
        #expect(result.messages.first?.seq == 39)
        #expect(search.toolName == "web_search")
        #expect(search.summary == "Search Swift Testing package path")
        #expect(search.inputDetail?.contains("Swift Testing package path") == true)
        #expect(search.output == nil)
        #expect(search.status == .running)
        #expect(result.state.pendingToolUses["ws_begin"]?.count == 1)
    }

    @Test("event_msg web_search_begin pairs with web_search_end in the same batch")
    func eventMessageWebSearchBeginPairsWithEndInSameBatch() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "web_search_begin",
                        "call_id": "ws_begin_end",
                        "action": [
                            "type": "search",
                            "query": "Swift Testing package path",
                        ],
                    ],
                    timestamp: "2026-06-19T08:08:04.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "web_search_end",
                        "call_id": "ws_begin_end",
                        "status": "completed",
                        "action": [
                            "type": "search",
                            "query": "Swift Testing package path",
                        ],
                    ],
                    timestamp: "2026-06-19T08:08:05.000Z"
                ),
            ],
            startingSeq: 40
        )

        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .toolUse(let search) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ws_begin_end")
        #expect(result.messages.first?.seq == 40)
        #expect(search.toolName == "web_search")
        #expect(search.summary == "Search Swift Testing package path")
        #expect(search.output == nil)
        #expect(search.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("web_search_call maps open-page and find-in-page actions")
    func webSearchCallOpenAndFindActions() {
        let result = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "web_search_call",
                        "status": "completed",
                        "action": [
                            "type": "open_page",
                            "url": "https://developers.openai.com/codex/hooks/",
                        ],
                    ],
                    timestamp: "2026-06-19T08:09:00.000Z"
                ),
                line(
                    type: "response_item",
                    payload: [
                        "type": "web_search_call",
                        "status": "completed",
                        "action": [
                            "type": "find_in_page",
                            "url": "https://developer.android.com/material3",
                            "pattern": "An M3 theme contains",
                        ],
                    ],
                    timestamp: "2026-06-19T08:09:02.000Z"
                ),
            ],
            startingSeq: 40
        )

        #expect(result.messages.count == 2)
        let tools = result.messages.compactMap { message -> ChatToolUse? in
            if case .toolUse(let tool) = message.kind { return tool }
            return nil
        }
        #expect(tools.count == 2)
        #expect(tools.map(\.summary) == [
            "Open https://developers.openai.com/codex/hooks/",
            "Find An M3 theme contains in https://developer.android.com/material3",
        ])
        #expect(tools.allSatisfy { $0.toolName == "web_search" && $0.status == .succeeded })
    }

    @Test("event_msg view_image_tool_call maps to a completed tool row")
    func eventMessageViewImageToolCall() {
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "view_image_tool_call",
                        "call_id": "view-image-1",
                        "path": "/tmp/codex-screen.png",
                    ],
                    timestamp: "2026-06-19T08:09:30.000Z"
                ),
            ],
            startingSeq: 42
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let viewImage) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "view-image-1")
        #expect(result.messages.first?.seq == 42)
        #expect(viewImage.toolName == "view_image")
        #expect(viewImage.summary == "view_image /tmp/codex-screen.png")
        #expect(viewImage.output == nil)
        #expect(viewImage.status == .succeeded)
    }

    @Test("image_generation_call maps inline image results without dumping image payload")
    func imageGenerationCallInlineResult() {
        let imagePayload = String(repeating: "iVBORw0KGgo", count: 256)
        let revisedPrompt = "A small blue app icon on a neutral background"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "image_generation_end",
                        "call_id": "ig_1",
                        "status": "generating",
                        "revised_prompt": revisedPrompt,
                        "result": imagePayload,
                    ],
                    timestamp: "2026-06-19T08:10:00.000Z"
                ),
                line(
                    type: "response_item",
                    payload: [
                        "type": "image_generation_call",
                        "id": "ig_1",
                        "status": "generating",
                        "revised_prompt": revisedPrompt,
                        "result": imagePayload,
                    ],
                    timestamp: "2026-06-19T08:10:00.003Z"
                ),
            ],
            startingSeq: 42
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let generation) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ig_1")
        #expect(result.messages.first?.seq == 43)
        #expect(generation.toolName == "image_generation")
        #expect(generation.summary == "Generate image A small blue app icon on a neutral background")
        #expect(generation.inputDetail == revisedPrompt)
        #expect(generation.output == nil)
        #expect(generation.status == .succeeded)
    }

    @Test("image_generation_end completes without dumping inline image payload")
    func imageGenerationEndDoesNotDumpInlineResult() {
        let imagePayload = String(repeating: "iVBORw0KGgo", count: 256)
        let revisedPrompt = "A small blue app icon on a neutral background"
        let result = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "image_generation_call",
                        "id": "ig_pending",
                        "status": "generating",
                        "revised_prompt": revisedPrompt,
                    ],
                    timestamp: "2026-06-19T08:10:01.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "image_generation_end",
                        "call_id": "ig_pending",
                        "status": "generating",
                        "revised_prompt": revisedPrompt,
                        "result": imagePayload,
                    ],
                    timestamp: "2026-06-19T08:10:02.000Z"
                ),
            ],
            startingSeq: 44
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let generation) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ig_pending")
        #expect(generation.output == nil)
        #expect(generation.status == .succeeded)
    }

    @Test("event_msg image_generation_begin starts a pending image generation tool")
    func eventMessageImageGenerationBeginStartsPendingTool() {
        let revisedPrompt = "A small blue app icon on a neutral background"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "image_generation_begin",
                        "call_id": "ig_begin",
                        "revised_prompt": revisedPrompt,
                    ],
                    timestamp: "2026-06-19T08:10:03.000Z"
                ),
            ],
            startingSeq: 46
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let generation) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ig_begin")
        #expect(result.messages.first?.seq == 46)
        #expect(generation.toolName == "image_generation")
        #expect(generation.summary == "Generate image A small blue app icon on a neutral background")
        #expect(generation.inputDetail == revisedPrompt)
        #expect(generation.output == nil)
        #expect(generation.status == .running)
        #expect(result.state.pendingToolUses["ig_begin"]?.count == 1)
    }

    @Test("event_msg image_generation_begin pairs with image_generation_end in the same batch")
    func eventMessageImageGenerationBeginPairsWithEndInSameBatch() {
        let imagePayload = String(repeating: "iVBORw0KGgo", count: 256)
        let revisedPrompt = "A small blue app icon on a neutral background"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "image_generation_begin",
                        "call_id": "ig_begin_end",
                        "revised_prompt": revisedPrompt,
                    ],
                    timestamp: "2026-06-19T08:10:03.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "image_generation_end",
                        "call_id": "ig_begin_end",
                        "status": "generating",
                        "revised_prompt": revisedPrompt,
                        "result": imagePayload,
                    ],
                    timestamp: "2026-06-19T08:10:05.000Z"
                ),
            ],
            startingSeq: 47
        )

        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .toolUse(let generation) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ig_begin_end")
        #expect(result.messages.first?.seq == 47)
        #expect(result.messages.first?.timestamp == Date(timeIntervalSince1970: 1_781_856_605))
        #expect(generation.toolName == "image_generation")
        #expect(generation.output == nil)
        #expect(generation.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg image_generation_end without a pending begin still renders a completed tool")
    func eventMessageImageGenerationEndFallbackRendersCompletedTool() {
        let revisedPrompt = "A small blue app icon on a neutral background"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "image_generation_end",
                        "call_id": "ig_end_only",
                        "status": "completed",
                        "revised_prompt": revisedPrompt,
                        "saved_path": "/tmp/cmux-icon.png",
                    ],
                    timestamp: "2026-06-19T08:10:07.000Z"
                ),
            ],
            startingSeq: 49
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let generation) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "ig_end_only")
        #expect(result.messages.first?.seq == 49)
        #expect(generation.toolName == "image_generation")
        #expect(generation.summary == "Generate image A small blue app icon on a neutral background")
        #expect(generation.output == nil)
        #expect(generation.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg patch_apply_end completes a pending custom tool")
    func eventMessagePatchApplyEndCompletesPendingTool() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let first = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "custom_tool_call",
                        "status": "completed",
                        "call_id": "call_patch_end",
                        "name": "apply_patch",
                        "input": patch,
                    ],
                    timestamp: "2026-06-19T08:05:00.000Z"
                ),
            ],
            startingSeq: 18
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "patch_apply_end",
                        "call_id": "call_patch_end",
                        "stdout": "Success. Updated the following files:\nM /repo/Sources/App.swift\n",
                        "stderr": "",
                        "success": true,
                    ],
                    timestamp: "2026-06-19T08:05:02.000Z"
                ),
            ],
            startingSeq: 19,
            state: first.state
        )

        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let tool) = second.updatedMessages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "apply_patch")
        #expect(tool.output == "Success. Updated the following files:\nM /repo/Sources/App.swift\n")
        #expect(tool.status == .succeeded)
    }

    @Test("event_msg patch_apply_begin starts a pending custom tool")
    func eventMessagePatchApplyBeginStartsPendingTool() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "patch_apply_begin",
                        "call_id": "call_patch_begin",
                        "input": patch,
                    ],
                    timestamp: "2026-06-19T08:05:00.000Z"
                ),
            ],
            startingSeq: 24
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "call_patch_begin")
        #expect(result.messages.first?.seq == 24)
        #expect(tool.toolName == "apply_patch")
        #expect(tool.summary == "apply_patch /repo/Sources/App.swift")
        #expect(tool.inputDetail == patch)
        #expect(tool.status == .running)
        #expect(result.state.pendingToolUses["call_patch_begin"]?.count == 1)
    }

    @Test("event_msg patch_apply_begin pairs with patch_apply_end in the same batch")
    func eventMessagePatchApplyBeginPairsWithEndInSameBatch() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "patch_apply_begin",
                        "call_id": "call_patch_begin_end",
                        "input": patch,
                    ],
                    timestamp: "2026-06-19T08:05:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "patch_apply_end",
                        "call_id": "call_patch_begin_end",
                        "stdout": "Success. Updated the following files:\nM /repo/Sources/App.swift\n",
                        "success": true,
                    ],
                    timestamp: "2026-06-19T08:05:02.000Z"
                ),
            ],
            startingSeq: 26
        )

        #expect(result.messages.count == 1)
        #expect(result.updatedMessages.isEmpty)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "call_patch_begin_end")
        #expect(result.messages.first?.seq == 26)
        #expect(result.messages.first?.timestamp == Date(timeIntervalSince1970: 1_781_856_302))
        #expect(tool.toolName == "apply_patch")
        #expect(tool.summary == "apply_patch /repo/Sources/App.swift")
        #expect(tool.output == "Success. Updated the following files:\nM /repo/Sources/App.swift\n")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg patch_apply_end without a pending begin still renders a completed tool")
    func eventMessagePatchApplyEndFallbackRendersCompletedTool() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "patch_apply_end",
                        "call_id": "call_patch_end_only",
                        "input": patch,
                        "stdout": "Success. Updated the following files:\nM /repo/Sources/App.swift\n",
                        "success": true,
                    ],
                    timestamp: "2026-06-19T08:05:08.000Z"
                ),
            ],
            startingSeq: 29
        )

        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(result.messages.first?.id == "call_patch_end_only")
        #expect(result.messages.first?.seq == 29)
        #expect(tool.toolName == "apply_patch")
        #expect(tool.summary == "apply_patch /repo/Sources/App.swift")
        #expect(tool.inputDetail == patch)
        #expect(tool.output == "Success. Updated the following files:\nM /repo/Sources/App.swift\n")
        #expect(tool.status == .succeeded)
        #expect(result.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg patch_apply_end normalizes failure status strings with spaces")
    func eventMessagePatchApplyEndNormalizesFailureStatusStringsWithSpaces() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let first = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "custom_tool_call",
                        "status": "completed",
                        "call_id": "call_patch_status_spaces",
                        "name": "apply_patch",
                        "input": patch,
                    ],
                    timestamp: "2026-06-19T08:05:03.000Z"
                ),
            ],
            startingSeq: 20
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "patch_apply_end",
                        "call_id": "call_patch_status_spaces",
                        "stdout": "",
                        "stderr": "Patch timed out\n",
                        "status": "timed out",
                    ],
                    timestamp: "2026-06-19T08:05:04.000Z"
                ),
            ],
            startingSeq: 21,
            state: first.state
        )

        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let tool) = second.updatedMessages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "apply_patch")
        #expect(tool.output == "Patch timed out\n")
        #expect(tool.status == .failed)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg patch_apply_end parses string code aliases")
    func eventMessagePatchApplyEndParsesStringCodeAliases() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let first = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "custom_tool_call",
                        "status": "completed",
                        "call_id": "call_patch_string_code",
                        "name": "apply_patch",
                        "input": patch,
                    ],
                    timestamp: "2026-06-19T08:05:05.000Z"
                ),
            ],
            startingSeq: 22
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "patch_apply_end",
                        "call_id": "call_patch_string_code",
                        "stderr": "Patch failed\n",
                        "code": "1",
                    ],
                    timestamp: "2026-06-19T08:05:06.000Z"
                ),
            ],
            startingSeq: 23,
            state: first.state
        )

        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let tool) = second.updatedMessages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "apply_patch")
        #expect(tool.output == "Patch failed\n")
        #expect(tool.status == .failed)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("request_user_input maps to question cards and resolves answers by prompt")
    func requestUserInputQuestions() {
        let requestArguments = """
            {
              "questions": [
                {
                  "question": "Which path?",
                  "options": [
                    {"label": "Fast", "description": "Quick but rough"},
                    {"label": "Slow", "description": "Thorough"}
                  ]
                },
                {
                  "question": "Which env?",
                  "options": [
                    {"label": "Dev", "description": "Local"},
                    {"label": "Prod", "description": "Live"}
                  ]
                }
              ]
            }
            """
        let answerOutput =
            #"Your questions have been answered: "Which path?"="Slow", "#
            + #""Which env?"="Dev". Continue."#
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: requestArguments,
                    callID: "call_questions"
                ),
            ],
            startingSeq: 20
        )
        let pendingQuestions = first.messages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(pendingQuestions.count == 2)
        #expect(pendingQuestions.first?.prompt == "Which path?")
        #expect(pendingQuestions.first?.options.map(\.label) == ["Fast", "Slow"])
        #expect(pendingQuestions.first?.options[0].detail == "Quick but rough")
        #expect(pendingQuestions.first?.selectedOptionLabel == nil)
        #expect(first.messages.map(\.id) == ["call_questions", "call_questions#1"])
        #expect(first.state.pendingToolUses["call_questions"]?.count == 2)
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: first.messages)
                == first.messages[0].timestamp
        )

        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call_questions",
                    output: answerOutput
                ),
            ],
            startingSeq: 21,
            state: first.state
        )
        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 2)
        #expect(
            answered.first(where: { $0.prompt == "Which path?" })?.selectedOptionLabel == "Slow"
        )
        #expect(
            answered.first(where: { $0.prompt == "Which env?" })?.selectedOptionLabel == "Dev"
        )
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages) != nil)
    }

    @Test("request_user_input aliases map to question cards")
    func requestUserInputAliasesMapToQuestionCards() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "REQUEST-USER-INPUT",
                    arguments: #"{"prompt":"Which Codex path?","options":["Inspect","Patch"]}"#,
                    callID: "call_question_alias"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "ASK-QUESTION",
                        "call_id": "call_event_question_alias",
                        "prompt": "Which event path?",
                        "options": ["Inspect", "Patch"],
                    ]
                ),
            ],
            startingSeq: 22
        )

        #expect(result.messages.count == 2)
        guard case .question(let functionQuestion) = result.messages[0].kind,
              case .question(let eventQuestion) = result.messages[1].kind else {
            Issue.record("expected question kinds")
            return
        }
        #expect(result.messages[0].id == "call_question_alias")
        #expect(result.messages[0].seq == 22)
        #expect(functionQuestion.prompt == "Which Codex path?")
        #expect(functionQuestion.options.map(\.label) == ["Inspect", "Patch"])
        #expect(result.messages[1].id == "call_event_question_alias")
        #expect(result.messages[1].seq == 23)
        #expect(eventQuestion.prompt == "Which event path?")
        #expect(eventQuestion.options.map(\.label) == ["Inspect", "Patch"])
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages)
                == result.messages[0].timestamp
        )
    }

    @Test("request_user_input resolves prompt-keyed JSON answers")
    func requestUserInputPromptKeyedJSONAnswers() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: """
                        {
                          "questions": [
                            {
                              "question": "Which path?",
                              "options": ["Fast", "Slow"]
                            },
                            {
                              "question": "Which env?",
                              "options": ["Dev", "Prod"]
                            }
                          ]
                        }
                        """,
                    callID: "call_json_questions"
                ),
            ],
            startingSeq: 24
        )

        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call_json_questions",
                    output: #"{"answers":{"Which path?":"Slow","Which env?":"Dev"}}"#
                ),
            ],
            startingSeq: 25,
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

    @Test("request_user_input resolves inline object answers")
    func requestUserInputInlineObjectAnswers() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: """
                        {
                          "questions": [
                            {
                              "question": "Which inline path?",
                              "options": ["Plan", "Ship"]
                            }
                          ]
                        }
                        """,
                    callID: "call_inline_object_answers"
                ),
            ],
            startingSeq: 26
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "function_call_output",
                        "call_id": "call_inline_object_answers",
                        "output": [
                            "answers": ["Which inline path?": "Ship"],
                        ],
                    ]
                ),
            ],
            startingSeq: 27,
            state: first.state
        )

        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 1)
        #expect(answered.first?.selectedOptionLabel == "Ship")
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages) != nil)
    }

    @Test("request_user_input resolves wrapped object answers")
    func requestUserInputWrappedObjectAnswers() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: """
                        {
                          "questions": [
                            {
                              "question": "Which wrapped path?",
                              "options": ["Plan", "Ship"]
                            }
                          ]
                        }
                        """,
                    callID: "call_wrapped_object_answers"
                ),
            ],
            startingSeq: 28
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "function_call_output",
                        "call_id": "call_wrapped_object_answers",
                        "output": [
                            "data": [
                                "answers": ["Which wrapped path?": "Ship"],
                            ],
                        ],
                    ]
                ),
            ],
            startingSeq: 29,
            state: first.state
        )

        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 1)
        #expect(answered.first?.selectedOptionLabel == "Ship")
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages) != nil)
    }

    @Test("request_user_input resolves object question answers")
    func requestUserInputObjectQuestionAnswers() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: """
                        {
                          "questions": [
                            {
                              "question": "Which object path?",
                              "options": ["Plan", "Ship"]
                            }
                          ]
                        }
                        """,
                    callID: "call_object_question_answers"
                ),
            ],
            startingSeq: 30
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "function_call_output",
                        "call_id": "call_object_question_answers",
                        "output": [
                            "questions": [
                                [
                                    "question": "Which object path?",
                                    "answer": "Ship",
                                ],
                            ],
                        ],
                    ]
                ),
            ],
            startingSeq: 31,
            state: first.state
        )

        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 1)
        #expect(answered.first?.selectedOptionLabel == "Ship")
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages) != nil)
    }

    @Test("request_user_input resolves scalar JSON answers")
    func requestUserInputScalarJSONAnswers() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: """
                        {
                          "questions": [
                            {
                              "question": "How many agents?",
                              "options": ["1", "2"]
                            },
                            {
                              "question": "Enable pilot?",
                              "options": ["true", "false"]
                            }
                          ]
                        }
                        """,
                    callID: "call_scalar_json_answers"
                ),
            ],
            startingSeq: 32
        )

        let second = parser.parse(
            lines: [
                line(
                    type: "response_item",
                    payload: [
                        "type": "function_call_output",
                        "call_id": "call_scalar_json_answers",
                        "output": [
                            "answers": [
                                "How many agents?": 2,
                                "Enable pilot?": true,
                            ],
                        ],
                    ]
                ),
            ],
            startingSeq: 33,
            state: first.state
        )

        let answered = second.updatedMessages.compactMap { message -> ChatQuestion? in
            if case .question(let question) = message.kind { return question }
            return nil
        }
        #expect(answered.count == 2)
        #expect(answered.first(where: { $0.prompt == "How many agents?" })?.selectedOptionLabel == "2")
        #expect(answered.first(where: { $0.prompt == "Enable pilot?" })?.selectedOptionLabel == "true")
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages) != nil)
    }

    @Test("request_user_input ignores prompt-less JSON answers")
    func requestUserInputIgnoresPromptlessJSONAnswer() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: #"{"prompt":"Which path?","options":["Plan","Ship"]}"#,
                    callID: "call_promptless_json"
                ),
            ],
            startingSeq: 26
        )

        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call_promptless_json",
                    output: #"{"answer":"Ship"}"#
                ),
            ],
            startingSeq: 27,
            state: first.state
        )

        #expect(second.updatedMessages.isEmpty)
    }

    @Test("request_user_input accepts a flat prompt with string options")
    func requestUserInputFlatQuestion() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: #"""
                    {
                      "prompt": "Which Codex path?",
                      "options": [
                        "Plan",
                        {"title": "Ship", "detail": "Open a PR"}
                      ]
                    }
                    """#,
                    callID: "call_flat_question"
                ),
            ],
            startingSeq: 28
        )

        #expect(first.messages.count == 1)
        guard case .question(let question) = first.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(first.messages[0].id == "call_flat_question")
        #expect(question.prompt == "Which Codex path?")
        #expect(question.options.map(\.label) == ["Plan", "Ship"])
        #expect(question.options[1].detail == "Open a PR")
        #expect(first.state.pendingToolUses["call_flat_question"]?.count == 1)

        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call_flat_question",
                    output: #"Your questions have been answered: "Which Codex path?"="Ship". Continue."#
                ),
            ],
            startingSeq: 29,
            state: first.state
        )

        guard case .question(let answered) = second.updatedMessages.first?.kind else {
            Issue.record("expected updated question")
            return
        }
        #expect(answered.selectedOptionLabel == "Ship")
    }

    @Test("request_user_input accepts scalar JSON options")
    func requestUserInputScalarOptions() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: #"""
                    {
                      "prompt": "How many Codex agents?",
                      "options": [
                        1,
                        2,
                        true,
                        {"value": false, "description": "Disable pilot mode"}
                      ]
                    }
                    """#,
                    callID: "call_scalar_options"
                ),
            ],
            startingSeq: 30
        )

        #expect(first.messages.count == 1)
        guard case .question(let question) = first.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(question.prompt == "How many Codex agents?")
        #expect(question.options.map(\.label) == ["1", "2", "true", "false"])
        if question.options.count > 3 {
            #expect(question.options[3].detail == "Disable pilot mode")
        }
        #expect(first.state.pendingToolUses["call_scalar_options"]?.count == 1)
    }

    @Test("request_user_input accepts nested input question payloads")
    func requestUserInputNestedInputQuestionPayloads() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: #"""
                    {
                      "input": {
                        "prompt": "Which nested Codex path?",
                        "options": ["Inspect", "Patch"]
                      }
                    }
                    """#,
                    callID: "call_nested_input_question"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "request_user_input",
                        "call_id": "call_event_nested_input_question",
                        "input": [
                            "prompt": "Which nested event path?",
                            "options": ["Plan", "Ship"],
                        ],
                    ]
                ),
            ],
            startingSeq: 30
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        guard case .question(let functionQuestion) = result.messages[0].kind,
              case .question(let eventQuestion) = result.messages[1].kind else {
            Issue.record("expected question kinds")
            return
        }
        #expect(result.messages[0].id == "call_nested_input_question")
        #expect(functionQuestion.prompt == "Which nested Codex path?")
        #expect(functionQuestion.options.map(\.label) == ["Inspect", "Patch"])
        #expect(result.messages[1].id == "call_event_nested_input_question")
        #expect(eventQuestion.prompt == "Which nested event path?")
        #expect(eventQuestion.options.map(\.label) == ["Plan", "Ship"])
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages)
                == result.messages[0].timestamp
        )
    }

    @Test("request_user_input accepts object options keyed by text, value, or name")
    func requestUserInputObjectOptionFallbackLabels() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: #"""
                    {
                      "prompt": "Which Codex action?",
                      "options": [
                        {"text": "Inspect first"},
                        {"value": "Patch now", "description": "Edit immediately"},
                        {"name": "Chat about this"}
                      ]
                    }
                    """#,
                    callID: "call_fallback_option_labels"
                ),
            ],
            startingSeq: 30
        )

        #expect(first.messages.count == 1)
        guard case .question(let question) = first.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(question.prompt == "Which Codex action?")
        #expect(question.options.map(\.label) == ["Inspect first", "Patch now", "Chat about this"])
        if question.options.count > 1 {
            #expect(question.options[1].detail == "Edit immediately")
        }
    }

    @Test("event_msg request_user_input maps to question cards and resolves answers by prompt")
    func eventMessageRequestUserInputQuestions() {
        let first = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "request_user_input",
                        "call_id": "call_event_questions",
                        "questions": [[
                            "question": "Which demo path should I use?",
                            "options": [
                                ["label": "Plan", "description": "Show plan mode"],
                                ["label": "Ship", "description": "Open a PR"],
                            ],
                        ]],
                    ]
                ),
            ],
            startingSeq: 30
        )
        #expect(first.messages.count == 1)
        guard first.messages.count == 1 else { return }
        guard case .question(let question) = first.messages[0].kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(first.messages[0].id == "call_event_questions")
        #expect(question.prompt == "Which demo path should I use?")
        #expect(question.options.map(\.label) == ["Plan", "Ship"])
        #expect(question.options[0].detail == "Show plan mode")
        #expect(question.selectedOptionLabel == nil)
        #expect(first.state.pendingToolUses["call_event_questions"]?.count == 1)
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: first.messages)
                == first.messages[0].timestamp
        )

        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call_event_questions",
                    output:
                        #"Your questions have been answered: "#
                        + #""Which demo path should I use?"="Plan". Continue."#
                ),
            ],
            startingSeq: 31,
            state: first.state
        )
        guard case .question(let answered) = second.updatedMessages.first?.kind else {
            Issue.record("expected updated question")
            return
        }
        #expect(answered.selectedOptionLabel == "Plan")
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages) != nil)
    }

    @Test("event_msg error preserves the visible Codex error message as agent prose")
    func eventMessageError() throws {
        let timestamp = "2026-06-11T21:38:09.381Z"
        let dateParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let error = line(
            type: "event_msg",
            payload: [
                "type": "error",
                "message": "You've hit your usage limit.",
                "codex_error_info": "usage_limit_exceeded",
            ],
            timestamp: timestamp
        )
        let result = parser.parse(lines: [error], startingSeq: 40)
        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "line-40")
        #expect(result.messages[0].role == .agent)
        #expect(result.messages[0].kind == .prose(
            ChatProse(text: "You've hit your usage limit.")
        ))
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 40,
                timestamp: try dateParser.parse(timestamp)
            ),
        ])
    }

    @Test("event_msg stream_error preserves the visible Codex stream failure as agent prose")
    func eventMessageStreamError() throws {
        let timestamp = "2026-06-11T21:38:10.381Z"
        let dateParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let error = line(
            type: "event_msg",
            payload: [
                "type": "stream_error",
                "message": "Stream disconnected before completion.",
                "codex_error_info": "response_stream_disconnected",
            ],
            timestamp: timestamp
        )
        let result = parser.parse(lines: [error], startingSeq: 41)
        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].id == "line-41")
        #expect(result.messages[0].role == .agent)
        #expect(result.messages[0].kind == .prose(
            ChatProse(text: "Stream disconnected before completion.")
        ))
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 41,
                timestamp: try dateParser.parse(timestamp)
            ),
        ])
    }

    @Test("turn_aborted fails running tools and expires pending permission requests")
    func turnAbortedClearsPendingToolAndPermissionRows() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"npm test"}"#,
                    callID: "call-aborted"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_request",
                        "call_id": "call-aborted",
                        "name": "exec_command",
                        "command": "npm test",
                    ],
                    timestamp: "2026-06-19T08:18:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "turn_aborted",
                        "reason": "interrupted",
                    ],
                    timestamp: "2026-06-19T08:18:01.000Z"
                ),
            ],
            startingSeq: 94
        )

        #expect(result.messages.count == 3)
        guard result.messages.count == 3 else { return }
        guard case .terminal(let terminal) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(terminal.command == "npm test")
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

    @Test("stream_error fails carried pending tool rows from a previous parse")
    func streamErrorClearsCarriedPendingToolRows() {
        let first = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "web_search_begin",
                        "call_id": "ws-interrupted",
                        "action": [
                            "type": "search",
                            "query": "Swift Testing docs",
                        ],
                    ],
                    timestamp: "2026-06-19T08:19:00.000Z"
                ),
            ],
            startingSeq: 98
        )
        #expect(first.state.pendingToolUses["ws-interrupted"]?.count == 1)

        let second = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "stream_error",
                        "message": "Stream disconnected before completion.",
                    ],
                    timestamp: "2026-06-19T08:19:01.000Z"
                ),
            ],
            startingSeq: 99,
            state: first.state
        )

        #expect(second.messages.count == 1)
        #expect(second.updatedMessages.count == 1)
        guard case .toolUse(let search) = second.updatedMessages.first?.kind else {
            Issue.record("expected updated toolUse kind")
            return
        }
        #expect(search.toolName == "web_search")
        #expect(search.status == .failed)
        #expect(search.output == "Stream disconnected before completion.")
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg aliases normalize approval and stream error event names")
    func eventMessageAliasesNormalizeApprovalAndStreamError() throws {
        let approvalTimestamp = "2026-06-11T21:38:11.381Z"
        let errorTimestamp = "2026-06-11T21:38:12.381Z"
        let dateParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let approvalDate = try dateParser.parse(approvalTimestamp)
        let errorDate = try dateParser.parse(errorTimestamp)
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "EXEC-APPROVAL-REQUEST",
                        "id": "approval-alias",
                        "command": "npm test",
                    ],
                    timestamp: approvalTimestamp
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "STREAM-ERROR",
                        "message": "Stream disconnected before completion.",
                    ],
                    timestamp: errorTimestamp
                ),
            ],
            startingSeq: 42
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].id == "permission-approval-alias")
        #expect(approvalDate < errorDate)
        #expect(result.messages[0].timestamp == errorDate)
        #expect(result.messages[0].kind == .permissionRequest(
            ChatPermissionRequest(
                title: "Codex wants to run:",
                subject: "npm test",
                resolution: .expired
            )
        ))
        #expect(result.messages[1].id == "line-43")
        #expect(result.messages[1].timestamp == errorDate)
        #expect(result.messages[1].role == .agent)
        #expect(result.messages[1].kind == .prose(
            ChatProse(text: "Stream disconnected before completion.")
        ))
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 43,
                timestamp: errorDate
            ),
        ])
    }

    @Test("root type aliases normalize event and response item rows")
    func rootTypeAliasesNormalizeEventAndResponseRows() throws {
        let messageTimestamp = "2026-06-11T21:38:13.381Z"
        let errorTimestamp = "2026-06-11T21:38:14.381Z"
        let dateParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let result = parser.parse(
            lines: [
                line(
                    type: "RESPONSE-ITEM",
                    payload: [
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            ["type": "output_text", "text": "Alias root response."],
                        ],
                    ],
                    timestamp: messageTimestamp
                ),
                line(
                    type: "EVENT-MSG",
                    payload: [
                        "type": "STREAM-ERROR",
                        "message": "Root alias stream disconnected.",
                    ],
                    timestamp: errorTimestamp
                ),
            ],
            startingSeq: 44
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        #expect(result.messages[0].kind == .prose(ChatProse(text: "Alias root response.")))
        #expect(result.messages[1].kind == .prose(ChatProse(text: "Root alias stream disconnected.")))
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 45,
                timestamp: try dateParser.parse(errorTimestamp)
            ),
        ])
    }

    @Test("custom_tool_call apply_patch maps to toolUse with the first patched file in the summary")
    func applyPatch() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let lines = [
            line(type: "response_item", payload: [
                "type": "custom_tool_call", "status": "completed",
                "call_id": "call_ap", "name": "apply_patch", "input": patch,
            ]),
            line(type: "response_item", payload: [
                "type": "custom_tool_call_output", "call_id": "call_ap",
                "output": "Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess.",
            ]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "apply_patch")
        #expect(tool.summary == "apply_patch /repo/Sources/App.swift")
        #expect(tool.status == .succeeded)
    }

    @Test("custom_tool_call_output marks apply_patch verification failures as failed")
    func applyPatchVerificationFailureOutput() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-missing\n+new\n*** End Patch"
        let lines = [
            line(type: "response_item", payload: [
                "type": "custom_tool_call", "status": "completed",
                "call_id": "call_ap_failed", "name": "apply_patch", "input": patch,
            ]),
            line(type: "response_item", payload: [
                "type": "custom_tool_call_output", "call_id": "call_ap_failed",
                "output": "apply_patch verification failed: Failed to find expected lines in /repo/Sources/App.swift",
            ]),
        ]

        let result = parser.parse(lines: lines, startingSeq: 0)

        guard case .toolUse(let tool) = result.messages[0].kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "apply_patch")
        #expect(tool.summary == "apply_patch /repo/Sources/App.swift")
        #expect(tool.output?.hasPrefix("apply_patch verification failed:") == true)
        #expect(tool.status == .failed)
    }

    @Test("response_item payload aliases normalize custom tool call names")
    func responseItemPayloadAliasesNormalizeCustomToolCalls() {
        let patch = "*** Begin Patch\n*** Update File: /repo/Sources/App.swift\n@@\n-old\n+new\n*** End Patch"
        let lines = [
            line(type: "response_item", payload: [
                "type": "CUSTOM-TOOL-CALL", "status": "completed",
                "call_id": "call_alias_ap", "name": "apply_patch", "input": patch,
            ]),
            line(type: "response_item", payload: [
                "type": "CUSTOM-TOOL-CALL-OUTPUT", "call_id": "call_alias_ap",
                "output": "Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess.",
            ]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        #expect(result.messages.count == 1)
        guard case .toolUse(let tool) = result.messages.first?.kind else {
            Issue.record("expected toolUse kind")
            return
        }
        #expect(tool.toolName == "apply_patch")
        #expect(tool.summary == "apply_patch /repo/Sources/App.swift")
        #expect(tool.status == .succeeded)
    }

    @Test("event_msg exec_approval_request maps to a pending permission request")
    func execApprovalRequest() {
        let approval = line(
            type: "event_msg",
            payload: [
                "type": "exec_approval_request",
                "call_id": "call-approval-1",
                "name": "exec_command",
                "command": "rm file.txt",
            ]
        )
        let result = parser.parse(lines: [approval], startingSeq: 12)
        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }

        let message = result.messages[0]
        #expect(message.id == "permission-call-approval-1")
        #expect(message.seq == 12)
        #expect(message.role == .agent)
        guard case .permissionRequest(let request) = message.kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.title == "Codex wants to run:")
        #expect(request.subject == "rm file.txt")
        #expect(request.resolution == nil)
        #expect(result.state.pendingToolUses["call-approval-1"]?.count == 1)
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages)
                == message.timestamp
        )
    }

    @Test("event_msg exec_approval_request reads nested toolCall payloads")
    func execApprovalRequestReadsNestedToolCallPayloads() {
        let approval = line(
            type: "event_msg",
            payload: [
                "type": "exec_approval_request",
                "toolCall": [
                    "id": "call-approval-nested-request",
                    "name": "exec_command",
                    "args": ["cmd": "swift test --filter CodexTranscriptParserTests"],
                ],
            ],
            timestamp: "2026-06-19T08:15:30.000Z"
        )
        let result = parser.parse(lines: [approval], startingSeq: 13)

        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }

        let message = result.messages[0]
        #expect(message.id == "permission-call-approval-nested-request")
        #expect(message.seq == 13)
        #expect(message.role == .agent)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_781_856_930))
        guard case .permissionRequest(let request) = message.kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.title == "Codex wants to run:")
        #expect(request.subject == "swift test --filter CodexTranscriptParserTests")
        #expect(request.resolution == nil)
        #expect(result.state.pendingToolUses["call-approval-nested-request"]?.count == 1)
        #expect(
            ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages)
                == message.timestamp
        )
    }

    @Test("function_call_output resolves a matching approval request as approved")
    func execApprovalRequestResolvedByToolOutput() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"rm file.txt"}"#,
                    callID: "call-approval-1"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_request",
                        "call_id": "call-approval-1",
                        "name": "exec_command",
                        "command": "rm file.txt",
                    ]
                ),
            ],
            startingSeq: 0
        )
        #expect(first.messages.count == 2)
        #expect(first.state.pendingToolUses["call-approval-1"]?.count == 2)

        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call-approval-1",
                    output: "Process exited with code 0\nOutput:\nremoved"
                ),
            ],
            startingSeq: 2,
            state: first.state
        )
        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 2)
        #expect(second.state.pendingToolUses.isEmpty)

        let permission = second.updatedMessages.first { message in
            if case .permissionRequest = message.kind { return true }
            return false
        }
        guard let permission else {
            Issue.record("expected updated permissionRequest")
            return
        }
        guard case .permissionRequest(let request) = permission.kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.resolution == .approved)
        #expect(
            ChatTranscriptStateSignal.resolvedInputTimestamp(in: second.updatedMessages)
                == permission.timestamp
        )
    }

    @Test("event_msg exec_approval_response approves the permission while keeping the tool pending")
    func execApprovalResponseApprovesPermissionBeforeToolOutput() {
        let first = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"npm test"}"#,
                    callID: "call-approval-approved"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_request",
                        "call_id": "call-approval-approved",
                        "name": "exec_command",
                        "command": "npm test",
                    ],
                    timestamp: "2026-06-19T08:16:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_response",
                        "call_id": "call-approval-approved",
                        "decision": "approved",
                    ],
                    timestamp: "2026-06-19T08:16:01.000Z"
                ),
            ],
            startingSeq: 86
        )

        #expect(first.messages.count == 2)
        guard first.messages.count == 2 else { return }
        guard case .terminal(let runningTerminal) = first.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(runningTerminal.command == "npm test")
        #expect(runningTerminal.output == nil)
        #expect(runningTerminal.exitCode == nil)
        #expect(runningTerminal.isRunning == true)

        guard case .permissionRequest(let request) = first.messages[1].kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.resolution == .approved)
        #expect(first.state.pendingToolUses["call-approval-approved"]?.count == 1)
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: [first.messages[1]]) != nil)

        let second = parser.parse(
            lines: [
                outputLine(
                    callID: "call-approval-approved",
                    output: "Process exited with code 0\nOutput:\nok"
                ),
            ],
            startingSeq: 89,
            state: first.state
        )
        #expect(second.messages.isEmpty)
        #expect(second.updatedMessages.count == 1)
        guard case .terminal(let completedTerminal) = second.updatedMessages.first?.kind else {
            Issue.record("expected updated terminal kind")
            return
        }
        #expect(completedTerminal.command == "npm test")
        #expect(completedTerminal.output?.contains("ok") == true)
        #expect(completedTerminal.exitCode == 0)
        #expect(completedTerminal.isRunning == false)
        #expect(second.state.pendingToolUses.isEmpty)
    }

    @Test("event_msg exec_approval_response denial closes matching permission and tool rows")
    func execApprovalResponseDeniesPermissionAndTool() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"rm file.txt"}"#,
                    callID: "call-approval-denied"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_request",
                        "call_id": "call-approval-denied",
                        "name": "exec_command",
                        "command": "rm file.txt",
                    ],
                    timestamp: "2026-06-19T08:17:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_response",
                        "call_id": "call-approval-denied",
                        "approved": false,
                        "message": "User denied permission via cmux Feed.",
                    ],
                    timestamp: "2026-06-19T08:17:01.000Z"
                ),
            ],
            startingSeq: 90
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        guard case .terminal(let terminal) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(terminal.command == "rm file.txt")
        #expect(terminal.output == "User denied permission via cmux Feed.")
        #expect(terminal.exitCode == 1)
        #expect(terminal.isRunning == false)

        guard case .permissionRequest(let request) = result.messages[1].kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.resolution == .denied)
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: [result.messages[1]]) != nil)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 92,
                timestamp: Date(timeIntervalSince1970: 1_781_857_021)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 92,
                timestamp: Date(timeIntervalSince1970: 1_781_857_021)
            ),
        ])
    }

    @Test("event_msg exec_approval_response without a retained request still clears input wait")
    func execApprovalResponseWithoutPendingRequestEmitsInputResolvedStateUpdate() throws {
        let timestamp = "2026-06-19T08:18:00.000Z"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_response",
                        "call_id": "call-approval-backfill",
                        "decision": "approved",
                    ],
                    timestamp: timestamp
                ),
            ],
            startingSeq: 97
        )

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 97,
                timestamp: try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                    .parse(timestamp)
            ),
        ])
    }

    @Test("event_msg exec_approval_response denial without a retained request clears input and work")
    func execApprovalResponseDeniedWithoutPendingRequestEmitsInputResolvedAndIdleStateUpdates() throws {
        let timestamp = "2026-06-19T08:18:05.000Z"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_response",
                        "call_id": "call-approval-denied-backfill",
                        "decision": "denied",
                    ],
                    timestamp: timestamp
                ),
            ],
            startingSeq: 98
        )

        let parsedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(timestamp)
        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 98,
                timestamp: parsedTimestamp
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 98,
                timestamp: parsedTimestamp
            ),
        ])
    }

    @Test("event_msg exec_approval_response reads nested approval payloads")
    func execApprovalResponseReadsNestedApprovalPayloads() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"rm nested.txt"}"#,
                    callID: "call-approval-nested"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_request",
                        "call_id": "call-approval-nested",
                        "name": "exec_command",
                        "command": "rm nested.txt",
                    ],
                    timestamp: "2026-06-19T08:18:10.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_response",
                        "approval": [
                            "callId": "call-approval-nested",
                            "decision": "denied",
                            "message": "Nested approval denied.",
                        ],
                    ],
                    timestamp: "2026-06-19T08:18:11.000Z"
                ),
            ],
            startingSeq: 99
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        guard case .terminal(let terminal) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(terminal.command == "rm nested.txt")
        #expect(terminal.output == "Nested approval denied.")
        #expect(terminal.exitCode == 1)
        #expect(terminal.isRunning == false)

        guard case .permissionRequest(let request) = result.messages[1].kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.resolution == .denied)
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 101,
                timestamp: Date(timeIntervalSince1970: 1_781_857_091)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 101,
                timestamp: Date(timeIntervalSince1970: 1_781_857_091)
            ),
        ])
    }

    @Test("event_msg exec_approval_response reads nested toolCall results without retained requests")
    func execApprovalResponseNestedToolCallWithoutPendingRequestClearsInputAndWork() throws {
        let timestamp = "2026-06-19T08:18:12.000Z"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_response",
                        "toolCall": [
                            "id": "call-approval-nested-backfill",
                            "status": "timed_out",
                        ],
                    ],
                    timestamp: timestamp
                ),
            ],
            startingSeq: 102
        )

        let parsedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(timestamp)
        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 102,
                timestamp: parsedTimestamp
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 102,
                timestamp: parsedTimestamp
            ),
        ])
    }

    @Test("event_msg exec_approval_response timeout expires permission and clears work")
    func execApprovalResponseTimeoutExpiresPermissionAndClearsWork() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"deploy.sh"}"#,
                    callID: "call-approval-timeout"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_request",
                        "call_id": "call-approval-timeout",
                        "name": "exec_command",
                        "command": "deploy.sh",
                    ],
                    timestamp: "2026-06-19T08:19:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_response",
                        "call_id": "call-approval-timeout",
                        "status": "timed_out",
                        "message": "Approval request timed out.",
                    ],
                    timestamp: "2026-06-19T08:19:05.000Z"
                ),
            ],
            startingSeq: 98
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        guard case .terminal(let terminal) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(terminal.command == "deploy.sh")
        #expect(terminal.output == "Approval request timed out.")
        #expect(terminal.exitCode == 1)
        #expect(terminal.isRunning == false)

        guard case .permissionRequest(let request) = result.messages[1].kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(request.resolution == .expired)
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 100,
                timestamp: Date(timeIntervalSince1970: 1_781_857_145)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 100,
                timestamp: Date(timeIntervalSince1970: 1_781_857_145)
            ),
        ])
    }

    // MARK: - Robustness

    @Test("thread_name_updated publishes a non-rendered title update")
    func threadNameUpdatedPublishesTitleUpdate() throws {
        let timestamp = "2026-06-11T21:38:05.381Z"
        let result = parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "thread_name_updated",
                        "thread_name": "Codex Companion Task: Fix auth",
                    ],
                    timestamp: timestamp
                ),
            ],
            startingSeq: 42
        )
        let expectedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(timestamp)

        #expect(result.messages.isEmpty)
        #expect(result.updatedMessages.isEmpty)
        #expect(result.stateUpdates.isEmpty)
        #expect(result.titleUpdate == "Codex Companion Task: Fix auth")
        #expect(result.state.lastTimestamp == expectedTimestamp)
    }

    @Test("non-actionable event_msg, turn_context, and malformed lines are skipped; seq tracks line offsets")
    func noiseAndSeq() {
        let lines = [
            line(type: "event_msg", payload: ["type": "task_started", "turn_id": "t-1"]),
            line(type: "turn_context", payload: ["turn_id": "t-1", "cwd": "/repo"]),
            line(type: "event_msg", payload: ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 5]]]),
            "garbage {",
            messageLine(role: "user", texts: ["hello"]),
        ]
        let result = parser.parse(lines: lines, startingSeq: 100)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].seq == 104)
        #expect(result.messages[0].id == "line-104")
    }

    @Test("Codex task lifecycle events emit non-rendered transcript state updates")
    func taskLifecycleStateUpdates() throws {
        let firstTimestamp = "2026-06-11T21:38:05.381Z"
        let secondTimestamp = "2026-06-11T21:38:06.381Z"
        let thirdTimestamp = "2026-06-11T21:38:07.381Z"
        let fourthTimestamp = "2026-06-11T21:38:08.381Z"
        let parser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let result = self.parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: ["type": "task_started", "turn_id": "turn-1"],
                    timestamp: firstTimestamp
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "task_complete",
                        "turn_id": "turn-1",
                        "last_agent_message": NSNull(),
                    ],
                    timestamp: secondTimestamp
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "turn_complete",
                        "turn_id": "turn-1",
                    ],
                    timestamp: thirdTimestamp
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "turn_aborted",
                        "turn_id": "turn-2",
                        "reason": "interrupted",
                    ],
                    timestamp: fourthTimestamp
                ),
            ],
            startingSeq: 200
        )

        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(event: .interrupted, detail: "interrupted")
        ))
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .working,
                seq: 200,
                timestamp: try parser.parse(firstTimestamp)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 201,
                timestamp: try parser.parse(secondTimestamp)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 202,
                timestamp: try parser.parse(thirdTimestamp)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 203,
                timestamp: try parser.parse(fourthTimestamp)
            ),
        ])
    }

    @Test("Codex task_complete resolves pending tools and expires permission requests")
    func taskCompleteClearsPendingToolAndPermissionRows() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "exec_command",
                    arguments: #"{"cmd":"npm test"}"#,
                    callID: "call-complete",
                    timestamp: "2026-06-19T08:42:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "exec_approval_request",
                        "call_id": "call-complete",
                        "name": "exec_command",
                        "command": "npm test",
                    ],
                    timestamp: "2026-06-19T08:42:01.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "task_complete",
                        "turn_id": "turn-complete",
                        "last_agent_message": NSNull(),
                    ],
                    timestamp: "2026-06-19T08:42:02.000Z"
                ),
            ],
            startingSeq: 204
        )

        #expect(result.messages.count == 2)
        guard result.messages.count == 2 else { return }
        guard case .terminal(let terminal) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect(result.messages[0].timestamp == Date(timeIntervalSince1970: 1_781_858_522))
        #expect(terminal.command == "npm test")
        #expect(terminal.output == nil)
        #expect(terminal.exitCode == 0)
        #expect(terminal.isRunning == false)

        guard case .permissionRequest(let request) = result.messages[1].kind else {
            Issue.record("expected permissionRequest kind")
            return
        }
        #expect(result.messages[1].timestamp == Date(timeIntervalSince1970: 1_781_858_522))
        #expect(request.resolution == .expired)
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(result.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 206,
                timestamp: Date(timeIntervalSince1970: 1_781_858_522)
            ),
        ])
    }

    @Test("Codex task_complete expires pending question rows")
    func taskCompleteClearsPendingQuestionRows() {
        let result = parser.parse(
            lines: [
                functionCallLine(
                    name: "request_user_input",
                    arguments: #"{"prompt":"Continue Codex task?","options":["Yes","No"]}"#,
                    callID: "call-question-complete",
                    timestamp: "2026-06-19T08:44:00.000Z"
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "task_complete",
                        "turn_id": "turn-question-complete",
                        "last_agent_message": NSNull(),
                    ],
                    timestamp: "2026-06-19T08:44:01.000Z"
                ),
            ],
            startingSeq: 207
        )

        #expect(result.messages.count == 1)
        guard case .question(let question) = result.messages.first?.kind else {
            Issue.record("expected question kind")
            return
        }
        #expect(question.prompt == "Continue Codex task?")
        #expect(question.selectedOptionLabel == nil)
        #expect(question.resolution == .expired)
        #expect(result.messages.first?.timestamp == Date(timeIntervalSince1970: 1_781_858_641))
        #expect(result.state.pendingToolUses.isEmpty)
        #expect(ChatTranscriptStateSignal.needsInputTimestamp(in: result.messages) == nil)
        #expect(
            ChatTranscriptStateSignal.resolvedInputTimestamp(in: result.messages)
                == Date(timeIntervalSince1970: 1_781_858_641)
        )
    }

    @Test("Codex goal updates emit state transitions only when the mapped state changes")
    func goalUpdateStateTransitions() throws {
        let activeTimestamp = "2026-06-11T21:38:09.381Z"
        let repeatedActiveTimestamp = "2026-06-11T21:38:10.381Z"
        let completeTimestamp = "2026-06-11T21:38:11.381Z"
        let blockedTimestamp = "2026-06-11T21:38:12.381Z"
        let resumedTimestamp = "2026-06-11T21:38:13.381Z"
        let parser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        let first = self.parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "thread_goal_updated",
                        "threadId": "thread-1",
                        "goal": ["status": "active"],
                    ],
                    timestamp: activeTimestamp
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "thread_goal_updated",
                        "threadId": "thread-1",
                        "goal": ["status": "active"],
                    ],
                    timestamp: repeatedActiveTimestamp
                ),
            ],
            startingSeq: 210
        )
        #expect(first.messages.isEmpty)
        #expect(first.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .working,
                seq: 210,
                timestamp: try parser.parse(activeTimestamp)
            ),
        ])

        let second = self.parser.parse(
            lines: [
                line(
                    type: "event_msg",
                    payload: [
                        "type": "thread_goal_updated",
                        "threadId": "thread-1",
                        "goal": ["status": "complete"],
                    ],
                    timestamp: completeTimestamp
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "thread_goal_updated",
                        "threadId": "thread-1",
                        "goal": ["status": "blocked"],
                    ],
                    timestamp: blockedTimestamp
                ),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "thread_goal_updated",
                        "threadId": "thread-1",
                        "goal": ["status": "active"],
                    ],
                    timestamp: resumedTimestamp
                ),
            ],
            startingSeq: 212,
            state: first.state
        )
        #expect(second.messages.isEmpty)
        #expect(second.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 212,
                timestamp: try parser.parse(completeTimestamp)
            ),
            ChatTranscriptStateUpdate(
                kind: .working,
                seq: 214,
                timestamp: try parser.parse(resumedTimestamp)
            ),
        ])
    }

    @Test("compacted lines map to a contextCompacted status")
    func compacted() {
        let result = parser.parse(
            lines: [line(type: "compacted", payload: ["message": "history replaced"])],
            startingSeq: 0
        )
        #expect(result.messages.count == 1)
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(event: .contextCompacted, detail: "history replaced")
        ))
    }

    @Test("top-level compacted lines preserve their status detail")
    func topLevelCompactedStatusDetail() {
        let rawLine = """
        {"timestamp":"2026-06-19T08:12:00.000Z","type":"compacted","message":"History was replaced after compaction.","replacement_history":[]}
        """
        let result = parser.parse(lines: [rawLine], startingSeq: 83)

        #expect(result.messages.count == 1)
        guard result.messages.count == 1 else { return }
        #expect(result.messages[0].seq == 83)
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(
                event: .contextCompacted,
                detail: "History was replaced after compaction."
            )
        ))
    }

    @Test("Codex lifecycle event messages map to durable status rows")
    func lifecycleEventMessages() {
        let result = parser.parse(
            lines: [
                line(type: "event_msg", payload: ["type": "context_compacted"]),
                line(
                    type: "event_msg",
                    payload: [
                        "type": "turn_aborted",
                        "turn_id": "turn-1",
                        "reason": "interrupted",
                        "duration_ms": 1200,
                    ]
                ),
                line(type: "event_msg", payload: ["type": "thread_rolled_back", "num_turns": 2]),
            ],
            startingSeq: 80
        )

        #expect(result.messages.count == 3)
        guard result.messages.count == 3 else { return }
        #expect(result.messages.map(\.seq) == [80, 81, 82])
        #expect(result.messages.allSatisfy { $0.role == .system })
        #expect(result.messages[0].kind == .status(
            ChatStatusTransition(event: .contextCompacted)
        ))
        #expect(result.messages[1].kind == .status(
            ChatStatusTransition(event: .interrupted, detail: "interrupted")
        ))
        #expect(result.messages[2].kind == .status(
            ChatStatusTransition(event: .threadRolledBack)
        ))
    }

    @Test("oversized tool output is truncated to the body budget")
    func truncation() {
        let huge = "Process exited with code 0\nOutput:\n" + String(repeating: "y", count: 40_000)
        let lines = [
            functionCallLine(name: "exec_command", arguments: #"{"cmd":"cat big"}"#),
            outputLine(output: huge),
        ]
        let result = parser.parse(lines: lines, startingSeq: 0)
        guard case .terminal(let capture) = result.messages[0].kind else {
            Issue.record("expected terminal kind")
            return
        }
        #expect((capture.output?.count ?? 0) <= 16_385)
        #expect(capture.output?.hasSuffix("…") == true)
    }
}
