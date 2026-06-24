/// Describes which Feed permission actions are valid for a workstream item.
public struct WorkstreamPermissionActionCapabilities: Sendable, Equatable {
    /// Whether the source supports session- or all-session-scoped permission choices in general.
    public let supportsPersistentModes: Bool
    /// Whether a one-time approval can be sent for this request.
    public let supportsOnce: Bool
    /// Whether a session-scoped approval can be sent for this request.
    public let supportsAlways: Bool
    /// Whether an all-tools or policy-amendment approval can be sent for this request.
    public let supportsAll: Bool
    /// Whether cmux can safely send a bypass-permissions decision for this source.
    public let supportsBypass: Bool

    /// Creates a permission-action capability snapshot.
    /// - Parameters:
    ///   - supportsPersistentModes: Whether persistent permission choices are source-supported.
    ///   - supportsOnce: Whether one-time approval is request-supported.
    ///   - supportsAlways: Whether session approval is request-supported.
    ///   - supportsAll: Whether all-tools or policy-amendment approval is request-supported.
    ///   - supportsBypass: Whether bypass-permissions approval is source-supported.
    public init(
        supportsPersistentModes: Bool,
        supportsOnce: Bool,
        supportsAlways: Bool,
        supportsAll: Bool,
        supportsBypass: Bool
    ) {
        self.supportsPersistentModes = supportsPersistentModes
        self.supportsOnce = supportsOnce
        self.supportsAlways = supportsAlways
        self.supportsAll = supportsAll
        self.supportsBypass = supportsBypass
    }
}
