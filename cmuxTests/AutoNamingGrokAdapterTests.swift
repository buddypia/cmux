import Foundation
import Testing

/// Behavior tests for the Grok chat-history adapter: extraction from native
/// `chat_history.jsonl`, injected metadata filtering, and shared-engine parity.
@Suite struct AutoNamingGrokAdapterTests {
    private let engine = AutoNamingEngine()

    private func historyLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @Test func extractsUserAndAssistantMessagesFromChatHistory() {
        let lines = [
            historyLine(["type": "system", "content": "You are Grok"]),
            historyLine(["type": "user", "content": "Fix the Grok session restore bug"]),
            historyLine(["type": "assistant", "content": "I will inspect the resume path."]),
            historyLine(["role": "assistant", "content": [["type": "text", "text": "The restore command is patched."]]]),
            "not json"
        ]

        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Fix the Grok session restore bug"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will inspect the resume path."),
            AutoNamingTranscriptMessage(role: "assistant", text: "The restore command is patched.")
        ])
    }

    @Test func userQueryTagWinsOverInjectedMetadata() {
        let userContent = """
        <user_info>
        OS Version: macos 26.4
        </user_info>
        <git_status>
        Current branch: feat/auto-name
        </git_status>
        <user_query>
        Add Grok workspace naming
        </user_query>
        """
        let lines = [
            historyLine(["type": "user", "content": userContent]),
            historyLine(["type": "assistant", "content": "Done."])
        ]

        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        #expect(messages.first == AutoNamingTranscriptMessage(role: "user", text: "Add Grok workspace naming"))
    }

    @Test func sharedEnginePipelineParityWithGrokContent() throws {
        let lines = [
            historyLine(["type": "user", "content": "Name workspaces from Grok history"]),
            historyLine(["type": "assistant", "content": "I will use chat_history.jsonl."])
        ]
        let messages = engine.extractGrokMessages(fromChatHistoryLines: lines)
        let context = try #require(engine.buildContext(from: messages))
        let prompt = engine.buildPrompt(currentTitle: "Old title", context: context)
        #expect(prompt.contains("Name workspaces from Grok history"))
        #expect(prompt.contains("The current title is: Old title"))

        let decision = engine.throttleDecision(
            snapshot: AutoNamingSessionSnapshot(),
            transcriptLineCount: engine.config.minTranscriptLines,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(decision == .proceed(baseline: engine.config.minTranscriptLines))
    }
}

/// Behavior tests for the Antigravity transcript source adapter: extraction
/// from current `agy` rows, role/parts rows, and injected-context filtering.
@Suite struct AutoNamingAntigravityAdapterTests {
    private let engine = AutoNamingEngine()

    private func transcriptLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @Test func extractsMessagesFromCurrentAgyShapes() {
        let lines = [
            transcriptLine([
                "sessionId": "agy-session",
                "projectHash": "project-hash",
            ]),
            transcriptLine([
                "type": "user",
                "content": "Add Antigravity workspace naming",
            ]),
            transcriptLine([
                "type": "gemini",
                "content": "I will inspect the transcript source.",
                "thoughts": [["description": "not title input"]],
                "toolCalls": [["name": "read_file"]],
            ]),
            "not json",
        ]

        let messages = engine.extractAntigravityMessages(fromTranscriptLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Add Antigravity workspace naming"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will inspect the transcript source."),
        ])
    }

    @Test func extractsMessagesFromRolePartsShapes() {
        let lines = [
            transcriptLine([
                "role": "user",
                "parts": [["text": "Name this agy session"]],
            ]),
            transcriptLine([
                "role": "model",
                "parts": [
                    ["thought": "hidden planning"],
                    ["text": "I will generate a concise title."],
                    ["functionCall": ["name": "read_file"]],
                ],
            ]),
            transcriptLine([
                "role": "tool",
                "parts": [["functionResponse": ["response": ["output": "noise"]]]],
            ]),
            transcriptLine([
                "role": "event",
                "name": "turn_complete",
            ]),
        ]

        let messages = engine.extractAntigravityMessages(fromTranscriptLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Name this agy session"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will generate a concise title."),
        ])
    }

    @Test func skipsInjectedContextAndLooseMessageRowsStillWork() {
        let lines = [
            transcriptLine([
                "type": "user",
                "content": "<environment_context>cwd: /tmp</environment_context>",
            ]),
            transcriptLine([
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": "Fix Antigravity stop notifications"]],
                ],
            ]),
            transcriptLine([
                "role": "assistant",
                "content": [["type": "output_text", "text": "The fallback path is ready."]],
            ]),
        ]

        let messages = engine.extractAntigravityMessages(fromTranscriptLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Fix Antigravity stop notifications"),
            AutoNamingTranscriptMessage(role: "assistant", text: "The fallback path is ready."),
        ])

        let context = engine.buildContext(from: messages)
        #expect(context?.contains("Fix Antigravity stop notifications") == true)
    }

    @Test func extractsMessagesFromSingleObjectJsonTranscript() {
        let transcript: [String: Any] = [
            "sessionId": "agy-json-session",
            "projectHash": "project-hash",
            "messages": [
                [
                    "type": "user",
                    "content": "<permissions>workspace-write</permissions>",
                ],
                [
                    "type": "user",
                    "content": "Make Antigravity JSON sessions auto-name",
                ],
                [
                    "type": "gemini",
                    "content": "I will add whole-file transcript support.",
                    "toolCalls": [["name": "read_file"]],
                ],
                [
                    "role": "model",
                    "parts": [["text": "The parser now reads both formats."]],
                ],
            ],
        ]

        let messages = engine.extractAntigravityMessages(fromTranscriptObject: transcript)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Make Antigravity JSON sessions auto-name"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will add whole-file transcript support."),
            AutoNamingTranscriptMessage(role: "assistant", text: "The parser now reads both formats."),
        ])
    }
}
