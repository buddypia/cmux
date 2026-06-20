import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatAgentKind")
struct ChatAgentKindTests {
    @Test("known sources normalize to first-class agent kinds")
    func knownSources() {
        #expect(ChatAgentKind(source: "claude") == .claude)
        #expect(ChatAgentKind(source: "codex") == .codex)
        #expect(ChatAgentKind(source: "antigravity") == .antigravity)
        #expect(ChatAgentKind(source: "agy") == .antigravity)
    }

    @Test("Antigravity uses the canonical hook source and display name")
    func antigravityCanonicalName() throws {
        let kind = ChatAgentKind(source: "agy")
        #expect(kind.sourceName == "antigravity")
        #expect(kind.displayName == "Antigravity")

        let data = try JSONEncoder().encode(kind)
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(encoded == #""antigravity""#)

        let decoded = try JSONDecoder().decode(ChatAgentKind.self, from: Data(#""agy""#.utf8))
        #expect(decoded == .antigravity)
    }

    @Test("unknown sources still round-trip as other")
    func unknownSource() {
        let kind = ChatAgentKind(source: "hermes-agent")
        #expect(kind == .other("hermes-agent"))
        #expect(kind.sourceName == "hermes-agent")
        #expect(kind.displayName == "Hermes-Agent")
    }
}
