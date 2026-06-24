import Testing

@testable import CmuxMobileShell

@Suite("MobileChatEventSource")
struct MobileChatEventSourceTests {
    @Test("submit sends the mobile chat submit action")
    @MainActor
    func submitSendsMobileChatSubmitAction() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let client = try #require(store.remoteClientForAgentChat)
        let source = MobileChatEventSource(client: client)

        try await source.submit(sessionID: "chat-session-1")

        #expect(await router.recordedChatAnswers() == [
            RoutingHostRouter.ChatAnswerRecord(
                sessionID: "chat-session-1",
                action: "submit",
                optionIndex: nil
            ),
        ])
    }
}
