import CMUXAgentLaunch

enum FeedPermissionActionPolicy {
    static func supportsPersistentPermissionModes(source: WorkstreamSource) -> Bool {
        capabilities(source: source, toolInputJSON: nil).supportsPersistentModes
    }

    static func supportsOncePermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        capabilities(source: source, toolInputJSON: toolInputJSON).supportsOnce
    }

    static func supportsAlwaysPermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        capabilities(source: source, toolInputJSON: toolInputJSON).supportsAlways
    }

    static func supportsAllPermissionMode(source: WorkstreamSource, toolInputJSON: String?) -> Bool {
        capabilities(source: source, toolInputJSON: toolInputJSON).supportsAll
    }

    static func supportsBypassPermissions(source: WorkstreamSource) -> Bool {
        capabilities(source: source, toolInputJSON: nil).supportsBypass
    }

    static func codexCapabilityToolInputJSON(source: WorkstreamSource, toolInputJSON: String) -> String? {
        WorkstreamPermissionActionPolicy().codexCapabilityToolInputJSON(
            source: source,
            toolInputJSON: toolInputJSON
        )
    }

    private static func capabilities(
        source: WorkstreamSource,
        toolInputJSON: String?
    ) -> WorkstreamPermissionActionCapabilities {
        WorkstreamPermissionActionPolicy().capabilities(
            source: source,
            toolInputJSON: toolInputJSON
        )
    }
}
