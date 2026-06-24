import Foundation

/// Computes Feed permission-action capabilities for source-specific approval protocols.
public struct WorkstreamPermissionActionPolicy: Sendable {
    /// Creates a stateless permission-action policy evaluator.
    public init() {}

    /// Returns supported permission actions for a known workstream source.
    /// - Parameters:
    ///   - source: The source that produced the permission request.
    ///   - toolInputJSON: Optional tool-input JSON used by Codex app-server requests.
    /// - Returns: A capability snapshot for the source and request.
    public func capabilities(
        source: WorkstreamSource,
        toolInputJSON: String?
    ) -> WorkstreamPermissionActionCapabilities {
        capabilities(sourceWireName: source.rawValue, toolInputJSON: toolInputJSON)
    }

    /// Returns supported permission actions for a raw wire source.
    /// - Parameters:
    ///   - sourceWireName: The raw `_source` value from a feed event.
    ///   - toolInputJSON: Optional tool-input JSON used by Codex app-server requests.
    /// - Returns: A capability snapshot for the source and request.
    public func capabilities(
        sourceWireName: String,
        toolInputJSON: String?
    ) -> WorkstreamPermissionActionCapabilities {
        let source = normalizedSourceWireName(sourceWireName)
        let supportsPersistentModes = supportsPersistentPermissionModes(sourceWireName: source)
        let supportsBypass = supportsBypassPermissions(sourceWireName: source)
        guard source == WorkstreamSource.codex.rawValue else {
            return WorkstreamPermissionActionCapabilities(
                supportsPersistentModes: supportsPersistentModes,
                supportsOnce: true,
                supportsAlways: supportsPersistentModes,
                supportsAll: supportsPersistentModes,
                supportsBypass: supportsBypass
            )
        }

        return codexCapabilities(
            toolInputJSON: toolInputJSON,
            supportsPersistentModes: supportsPersistentModes,
            supportsBypass: supportsBypass
        )
    }

    /// Returns a compact Codex tool-input JSON snapshot that preserves approval capability controls.
    /// - Parameters:
    ///   - source: The source that produced the permission request.
    ///   - toolInputJSON: The full tool-input JSON.
    /// - Returns: A compact JSON string, or `nil` for non-Codex sources or malformed JSON.
    public func codexCapabilityToolInputJSON(
        source: WorkstreamSource,
        toolInputJSON: String
    ) -> String? {
        codexCapabilityToolInputJSON(sourceWireName: source.rawValue, toolInputJSON: toolInputJSON)
    }

    /// Returns a compact Codex tool-input JSON snapshot that preserves approval capability controls.
    /// - Parameters:
    ///   - sourceWireName: The raw `_source` value from a feed event.
    ///   - toolInputJSON: The full tool-input JSON.
    /// - Returns: A compact JSON string, or `nil` for non-Codex sources or malformed JSON.
    public func codexCapabilityToolInputJSON(
        sourceWireName: String,
        toolInputJSON: String
    ) -> String? {
        guard normalizedSourceWireName(sourceWireName) == WorkstreamSource.codex.rawValue else {
            return nil
        }
        return codexCapabilityToolInputJSON(toolInputJSON: toolInputJSON)
    }

    private func normalizedSourceWireName(_ sourceWireName: String) -> String {
        WorkstreamSource(wireName: sourceWireName)?.rawValue ?? sourceWireName
    }

    private func supportsPersistentPermissionModes(sourceWireName: String) -> Bool {
        sourceWireName != WorkstreamSource.antigravity.rawValue
            && sourceWireName != WorkstreamSource.kiro.rawValue
            && sourceWireName != WorkstreamSource.hermesAgent.rawValue
    }

    private func supportsBypassPermissions(sourceWireName: String) -> Bool {
        sourceWireName != WorkstreamSource.codex.rawValue
            && sourceWireName != WorkstreamSource.claude.rawValue
            && sourceWireName != WorkstreamSource.antigravity.rawValue
            && sourceWireName != WorkstreamSource.kiro.rawValue
            && sourceWireName != WorkstreamSource.hermesAgent.rawValue
    }

    private func codexCapabilities(
        toolInputJSON: String?,
        supportsPersistentModes: Bool,
        supportsBypass: Bool
    ) -> WorkstreamPermissionActionCapabilities {
        guard let toolInputJSON else {
            return WorkstreamPermissionActionCapabilities(
                supportsPersistentModes: supportsPersistentModes,
                supportsOnce: true,
                supportsAlways: true,
                supportsAll: true,
                supportsBypass: supportsBypass
            )
        }
        guard let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return WorkstreamPermissionActionCapabilities(
                supportsPersistentModes: supportsPersistentModes,
                supportsOnce: false,
                supportsAlways: false,
                supportsAll: false,
                supportsBypass: supportsBypass
            )
        }

        let method = object["app_server_method"] as? String
        let decisions = codexAvailableDecisions(in: object)
        let acceptsOnce = decisions?.contains("accept") ?? true
        let acceptsSession = decisions?.contains("acceptForSession") ?? true

        switch method {
        case "item/permissions/requestApproval":
            return WorkstreamPermissionActionCapabilities(
                supportsPersistentModes: supportsPersistentModes,
                supportsOnce: true,
                supportsAlways: true,
                supportsAll: true,
                supportsBypass: supportsBypass
            )
        case "item/commandExecution/requestApproval":
            return WorkstreamPermissionActionCapabilities(
                supportsPersistentModes: supportsPersistentModes,
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: codexSupportsAmendmentDecision(object: object, decisions: decisions),
                supportsBypass: supportsBypass
            )
        case "item/fileChange/requestApproval":
            return WorkstreamPermissionActionCapabilities(
                supportsPersistentModes: supportsPersistentModes,
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: false,
                supportsBypass: supportsBypass
            )
        default:
            return WorkstreamPermissionActionCapabilities(
                supportsPersistentModes: supportsPersistentModes,
                supportsOnce: acceptsOnce,
                supportsAlways: acceptsSession,
                supportsAll: false,
                supportsBypass: supportsBypass
            )
        }
    }

    private func codexSupportsAmendmentDecision(object: [String: Any], decisions: Set<String>?) -> Bool {
        if let amendment = object["proposed_execpolicy_amendment"],
           codexDecisionAvailableOrUnspecified("acceptWithExecpolicyAmendment", decisions: decisions),
           !(amendment is NSNull) {
            return true
        }
        if let amendments = object["proposed_network_policy_amendments"] as? [Any],
           !amendments.isEmpty,
           codexDecisionAvailableOrUnspecified("applyNetworkPolicyAmendment", decisions: decisions) {
            return true
        }
        return false
    }

    private func codexCapabilityToolInputJSON(toolInputJSON: String) -> String? {
        guard let data = toolInputJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }

        var snapshot: [String: Any] = [:]
        if let method = object["app_server_method"] as? String {
            snapshot["app_server_method"] = method
        }
        if let decisions = codexAvailableDecisions(in: object) {
            snapshot["available_decisions"] = decisions.sorted()
        }
        if let amendment = object["proposed_execpolicy_amendment"],
           !(amendment is NSNull) {
            snapshot["proposed_execpolicy_amendment"] = true
        }
        if let amendments = object["proposed_network_policy_amendments"] as? [Any],
           !amendments.isEmpty {
            snapshot["proposed_network_policy_amendments"] = [true]
        }

        guard let snapshotData = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: snapshotData, encoding: .utf8)
    }

    private func codexAvailableDecisions(in object: [String: Any]) -> Set<String>? {
        guard let raw = object["available_decisions"] ?? object["availableDecisions"] else {
            return nil
        }
        return Set(decisionNames(raw))
    }

    private func decisionNames(_ raw: Any) -> [String] {
        let values = raw as? [Any] ?? []
        return values.compactMap { value in
            if let string = value as? String {
                return string
            }
            if let object = value as? [String: Any],
               let key = object.keys.first {
                return key
            }
            return nil
        }
    }

    private func codexDecisionAvailableOrUnspecified(_ decision: String, decisions: Set<String>?) -> Bool {
        decisions?.contains(decision) ?? true
    }
}
