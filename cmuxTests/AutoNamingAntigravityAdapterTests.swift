import Foundation
import Testing

/// Behavior tests for Antigravity transcript extraction. Antigravity is a
/// source adapter here: cmux reads its transcript, but still requires a
/// supported safe summarizer override rather than invoking `agy --print`.
@Suite struct AutoNamingAntigravityAdapterTests {
    private let engine = AutoNamingEngine()

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    @Test func extractsCurrentJsonlMessageShapes() {
        let lines = [
            jsonLine(["type": "info", "content": "loading"]),
            jsonLine(["type": "user", "content": "Fix Antigravity workspace naming"]),
            jsonLine(["type": "gemini", "content": [["type": "text", "text": "I will inspect the transcript source."]]]),
            jsonLine(["role": "model", "parts": [["text": "The source adapter is ready."]]]),
            jsonLine(["type": "tool_call", "name": "shell"]),
            "not json"
        ]

        let messages = engine.extractAntigravityMessages(fromTranscriptLines: lines)
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Fix Antigravity workspace naming"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I will inspect the transcript source."),
            AutoNamingTranscriptMessage(role: "assistant", text: "The source adapter is ready.")
        ])
    }

    @Test func extractsSingleObjectSessionJson() {
        let object: [String: Any] = [
            "id": "agy-session",
            "messages": [
                ["role": "user", "parts": [["text": "Name workspaces from Antigravity transcripts"]]],
                ["role": "model", "parts": [["text": "I can summarize that safely with a supported override."]]],
                ["role": "tool", "parts": [["text": "ignored"]]]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let session = String(data: data, encoding: .utf8)!

        let messages = engine.extractAntigravityMessages(fromTranscriptLines: session.components(separatedBy: "\n"))
        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Name workspaces from Antigravity transcripts"),
            AutoNamingTranscriptMessage(role: "assistant", text: "I can summarize that safely with a supported override.")
        ])
    }

    @Test func stripsInjectedMetadataFromUserContent() {
        let userContent = """
        <user_info>
        OS Version: macos 26.4
        </user_info>
        <user_query>
        Add Antigravity transcript-backed naming
        </user_query>
        """
        let messages = engine.extractAntigravityMessages(fromTranscriptLines: [
            jsonLine(["type": "user", "content": userContent])
        ])

        #expect(messages == [
            AutoNamingTranscriptMessage(role: "user", text: "Add Antigravity transcript-backed naming")
        ])
    }

    @Test func sharedEnginePipelineParityWithAntigravityContent() throws {
        let lines = [
            jsonLine(["type": "user", "content": "Use Codex to name an Antigravity tab"]),
            jsonLine(["type": "gemini", "content": "I will keep agy out of the summarizer path."])
        ]
        let messages = engine.extractAntigravityMessages(fromTranscriptLines: lines)
        let context = try #require(engine.buildContext(from: messages))
        let prompt = engine.buildPrompt(currentTitle: "Old title", context: context)
        #expect(prompt.contains("Use Codex to name an Antigravity tab"))
        #expect(prompt.contains("The current title is: Old title"))

        let decision = engine.throttleDecision(
            snapshot: AutoNamingSessionSnapshot(),
            transcriptLineCount: engine.config.minTranscriptLines,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(decision == .proceed(baseline: engine.config.minTranscriptLines))
    }
}
