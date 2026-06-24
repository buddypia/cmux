import Foundation
import Testing
import CMUXAgentLaunch

@Suite("WorkstreamPermissionActionPolicy")
struct WorkstreamPermissionActionPolicyTests {
    @Test func userOwnedSourcesHideBypassAndUnsupportedPersistentModes() {
        let policy = WorkstreamPermissionActionPolicy()

        let claude = policy.capabilities(source: .claude, toolInputJSON: nil)
        #expect(claude.supportsPersistentModes)
        #expect(!claude.supportsBypass)

        let codex = policy.capabilities(source: .codex, toolInputJSON: nil)
        #expect(codex.supportsPersistentModes)
        #expect(!codex.supportsBypass)

        let antigravity = policy.capabilities(source: .antigravity, toolInputJSON: nil)
        #expect(!antigravity.supportsPersistentModes)
        #expect(antigravity.supportsOnce)
        #expect(!antigravity.supportsAlways)
        #expect(!antigravity.supportsAll)
        #expect(!antigravity.supportsBypass)

        let opencode = policy.capabilities(sourceWireName: "opencode", toolInputJSON: nil)
        #expect(opencode.supportsPersistentModes)
        #expect(opencode.supportsBypass)
    }

    @Test func codexCapabilitiesFollowAvailableDecisionsAndAmendments() {
        let policy = WorkstreamPermissionActionPolicy()
        let oneShotOnly = #"""
        {"app_server_method":"item/commandExecution/requestApproval","available_decisions":["accept","decline"]}
        """#
        #expect(policy.capabilities(source: .codex, toolInputJSON: oneShotOnly) == WorkstreamPermissionActionCapabilities(
            supportsPersistentModes: true,
            supportsOnce: true,
            supportsAlways: false,
            supportsAll: false,
            supportsBypass: false
        ))

        let execPolicyAmendment = #"""
        {"app_server_method":"item/commandExecution/requestApproval","available_decisions":[{"acceptWithExecpolicyAmendment":{}}],"proposed_execpolicy_amendment":[{"kind":"prefix","value":"npm test"}]}
        """#
        let amendmentCapabilities = policy.capabilities(sourceWireName: "codex", toolInputJSON: execPolicyAmendment)
        #expect(!amendmentCapabilities.supportsOnce)
        #expect(!amendmentCapabilities.supportsAlways)
        #expect(amendmentCapabilities.supportsAll)
    }

    @Test func invalidCodexToolInputHidesApprovalModes() {
        let capabilities = WorkstreamPermissionActionPolicy().capabilities(
            source: .codex,
            toolInputJSON: #"{"app_server_method":"item/commandExecution/requestApproval","available_decisions":["accept"]"#
        )

        #expect(capabilities.supportsPersistentModes)
        #expect(!capabilities.supportsOnce)
        #expect(!capabilities.supportsAlways)
        #expect(!capabilities.supportsAll)
        #expect(!capabilities.supportsBypass)
    }

    @Test func codexCapabilitySnapshotPreservesControlsWhenDisplayInputIsLarge() throws {
        let toolInput: [String: Any] = [
            "app_server_method": "item/commandExecution/requestApproval",
            "available_decisions": ["accept", "acceptForSession", "decline"],
            "related_item": [
                "diff": String(repeating: "x", count: 12_000)
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys])
        let json = try #require(String(data: data, encoding: .utf8))

        let snapshot = try #require(WorkstreamPermissionActionPolicy().codexCapabilityToolInputJSON(
            source: .codex,
            toolInputJSON: json
        ))

        #expect(snapshot.count < json.count)
        #expect(WorkstreamPermissionActionPolicy().capabilities(source: .codex, toolInputJSON: snapshot).supportsOnce)
        #expect(WorkstreamPermissionActionPolicy().capabilities(source: .codex, toolInputJSON: snapshot).supportsAlways)
        #expect(!WorkstreamPermissionActionPolicy().capabilities(source: .codex, toolInputJSON: snapshot).supportsAll)
    }
}
