import CMUXAgentLaunch
import CmuxSettings
import Foundation

/// Resolves ``PilotModeSettings`` from `UserDefaults` (written by Settings and
/// by `~/.config/cmux/cmux.json`) and applies per-surface overrides.
///
/// Two-level on/off by design: the stored value is the default for every
/// surface, and a surface may opt in or out on its own. cmux runs many agents
/// side by side, so a single global switch would force the same delegation
/// policy onto a throwaway scratch tab and a production release tab alike.
///
/// Overrides live in memory only. A per-tab toggle is a statement about the
/// task in front of you, not a preference worth resurrecting days later on a
/// tab whose contents have moved on — and the safe direction on restart is back
/// to the stored default.
final class PilotModeSettingsStore: @unchecked Sendable {
    static let shared = PilotModeSettingsStore()

    static let didChangeNotification = Notification.Name("cmux.pilotModeSettingsDidChange")

    private let defaults: UserDefaults
    private let catalog = AutomationCatalogSection()
    private let lock = NSLock()
    private var surfaceOverrides: [UUID: Bool] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reading

    /// Settings as they apply to `surfaceId`. Passing `nil` yields the stored
    /// defaults with no override applied.
    func settings(forSurface surfaceId: UUID?) -> PilotModeSettings {
        var resolved = storedSettings()
        if let surfaceId, let override = override(forSurface: surfaceId) {
            resolved.isEnabled = override
        }
        return resolved.normalized()
    }

    /// The stored (global) configuration, before per-surface overrides.
    func storedSettings() -> PilotModeSettings {
        PilotModeSettings(
            isEnabled: bool(catalog.pilotMode),
            runMode: PilotModeRunMode(rawValue: string(catalog.pilotModeRunMode)) ?? .shadow,
            instructions: string(catalog.pilotModeInstructions),
            answersPermissionRequests: bool(catalog.pilotModeAnswersPermissionRequests),
            answersQuestions: bool(catalog.pilotModeAnswersQuestions),
            autoAllowsReadOnly: bool(catalog.pilotModeAutoAllowReadOnly),
            denyPatterns: Self.parseDenyPatterns(string(catalog.pilotModeDenyPatterns)),
            maxConsecutiveDecisions: int(catalog.pilotModeMaxConsecutiveDecisions),
            judgeTimeout: double(catalog.pilotModeJudgeTimeout)
        )
    }

    func isEnabled(forSurface surfaceId: UUID?) -> Bool {
        settings(forSurface: surfaceId).isEnabled
    }

    func override(forSurface surfaceId: UUID) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return surfaceOverrides[surfaceId]
    }

    // MARK: - Writing

    /// Sets the global switch. Surfaces with their own override keep it.
    func setGloballyEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: catalog.pilotMode.userDefaultsKey)
        notifyDidChange()
    }

    func setRunMode(_ mode: PilotModeRunMode) {
        defaults.set(mode.rawValue, forKey: catalog.pilotModeRunMode.userDefaultsKey)
        notifyDidChange()
    }

    func setInstructions(_ instructions: String) {
        defaults.set(instructions, forKey: catalog.pilotModeInstructions.userDefaultsKey)
        notifyDidChange()
    }

    func setOverride(_ enabled: Bool?, forSurface surfaceId: UUID) {
        lock.lock()
        if let enabled {
            surfaceOverrides[surfaceId] = enabled
        } else {
            surfaceOverrides.removeValue(forKey: surfaceId)
        }
        lock.unlock()
        notifyDidChange()
    }

    /// Flips `surfaceId` relative to whatever currently applies to it, and
    /// returns the new state.
    @discardableResult
    func toggle(forSurface surfaceId: UUID) -> Bool {
        let next = !isEnabled(forSurface: surfaceId)
        setOverride(next, forSurface: surfaceId)
        return next
    }

    func clearOverrides() {
        lock.lock()
        surfaceOverrides.removeAll()
        lock.unlock()
        notifyDidChange()
    }

    /// Drops the override for a surface that no longer exists, so a recycled
    /// UUID cannot inherit a stale opt-in.
    func forgetSurface(_ surfaceId: UUID) {
        lock.lock()
        surfaceOverrides.removeValue(forKey: surfaceId)
        lock.unlock()
    }

    // MARK: - Helpers

    static func parseDenyPatterns(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func bool(_ key: DefaultsKey<Bool>) -> Bool {
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

    private func int(_ key: DefaultsKey<Int>) -> Int {
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.integer(forKey: key.userDefaultsKey)
    }

    private func double(_ key: DefaultsKey<Double>) -> Double {
        guard defaults.object(forKey: key.userDefaultsKey) != nil else { return key.defaultValue }
        return defaults.double(forKey: key.userDefaultsKey)
    }

    private func string(_ key: DefaultsKey<String>) -> String {
        defaults.string(forKey: key.userDefaultsKey) ?? key.defaultValue
    }
}
