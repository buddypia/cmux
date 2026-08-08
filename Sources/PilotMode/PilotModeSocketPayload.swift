import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// Wire payloads for `feed.pilot.status` and `feed.pilot.disable`.
///
/// Kept out of the seam conformance so the shape is testable on its own and so
/// both the socket and any future caller read Pilot Mode through the one store
/// that Settings, `cmux.json`, and the command palette already use.
enum PilotModeSocketPayload {
    static func status(
        forSurface surfaceID: UUID?,
        store: PilotModeSettingsStore = .shared
    ) -> JSONValue {
        let stored = store.storedSettings().normalized()
        let resolved = store.settings(forSurface: surfaceID)
        var payload: [String: JSONValue] = [
            "enabled": .bool(resolved.isEnabled),
            "run_mode": .string(resolved.runMode.rawValue),
            "global_enabled": .bool(stored.isEnabled),
            "answers_permission_requests": .bool(resolved.answersPermissionRequests),
            "answers_questions": .bool(resolved.answersQuestions),
            "auto_allows_read_only": .bool(resolved.autoAllowsReadOnly),
            "max_consecutive_decisions": .int(Int64(resolved.maxConsecutiveDecisions)),
            "judge_timeout_seconds": .int(Int64(resolved.judgeTimeout.rounded())),
            "deny_pattern_count": .int(Int64(resolved.denyPatterns.count)),
            "has_instructions": .bool(!resolved.instructions.isEmpty),
        ]
        if let surfaceID {
            payload["scope"] = .string("surface")
            payload["surface"] = .string(surfaceID.uuidString)
            // Distinguishes "this tab was set to off" from "this tab is off
            // because everything is". Only the first is undone by clearing the
            // override, and a caller that cannot tell them apart cannot tell
            // the user what to do next.
            payload["surface_override"] = store.override(forSurface: surfaceID)
                .map { JSONValue.bool($0) } ?? .null
        } else {
            payload["scope"] = .string("global")
        }
        return .object(payload)
    }

    /// Turning Pilot Mode off is the only mutation the socket exposes; see
    /// ``ControlFeedContext/controlFeedPilotDisable(surfaceID:)`` for why there
    /// is no enable counterpart.
    static func disable(
        forSurface surfaceID: UUID?,
        store: PilotModeSettingsStore = .shared
    ) -> JSONValue {
        let wasEnabled = store.isEnabled(forSurface: surfaceID)
        if let surfaceID {
            store.setOverride(false, forSurface: surfaceID)
        } else {
            store.setGloballyEnabled(false)
        }
        var payload: [String: JSONValue] = [
            "enabled": .bool(store.isEnabled(forSurface: surfaceID)),
            "changed": .bool(wasEnabled),
        ]
        if let surfaceID {
            payload["scope"] = .string("surface")
            payload["surface"] = .string(surfaceID.uuidString)
        } else {
            payload["scope"] = .string("global")
        }
        return .object(payload)
    }
}
