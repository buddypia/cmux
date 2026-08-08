internal import Foundation

/// The main-actor feed domain (`feed.jump`, `feed.list`), lifted byte-faithfully
/// from the former `TerminalController.v2Feed*` bodies. Each payload is built
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries); the resulting Foundation object is identical, so the encoded
/// wire bytes match.
///
/// The worker-lane feed methods (`feed.push`, `feed.permission.reply`,
/// `feed.question.reply`, `feed.exit_plan.reply`) block or await on the socket
/// worker and remain on the app-side worker path — they are deliberately NOT
/// dispatched here.
extension ControlCommandCoordinator {
    /// Dispatches the feed methods this coordinator owns; returns `nil` for
    /// anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a feed method.
    func handleFeed(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "feed.jump":
            return feedJump(request.params)
        case "feed.list":
            return feedList(request.params)
        case "feed.pilot.status":
            return feedPilotStatus(request.params)
        case "feed.pilot.disable":
            return feedPilotDisable(request.params)
        default:
            return nil
        }
    }

    /// `feed.pilot.status` — report Pilot Mode configuration, optionally for one
    /// surface.
    func feedPilotStatus(_ params: [String: JSONValue]) -> ControlCallResult {
        switch pilotScope(params) {
        case .invalidSurface:
            return Self.invalidPilotSurface
        case .global:
            return .ok(context?.controlFeedPilotStatus(surfaceID: nil) ?? .object([:]))
        case .surface(let surfaceID):
            return .ok(context?.controlFeedPilotStatus(surfaceID: surfaceID) ?? .object([:]))
        }
    }

    /// `feed.pilot.disable` — turn Pilot Mode off globally or for one surface.
    /// There is no enable counterpart; see ``ControlFeedContext``.
    func feedPilotDisable(_ params: [String: JSONValue]) -> ControlCallResult {
        switch pilotScope(params) {
        case .invalidSurface:
            return Self.invalidPilotSurface
        case .global:
            return .ok(context?.controlFeedPilotDisable(surfaceID: nil) ?? .object([:]))
        case .surface(let surfaceID):
            return .ok(context?.controlFeedPilotDisable(surfaceID: surfaceID) ?? .object([:]))
        }
    }

    enum PilotScope {
        case global
        case surface(UUID)
        case invalidSurface
    }

    /// An absent `surface` means "global". A present but unparseable one is an
    /// error rather than a silent fall back to global: quietly widening the
    /// scope of a *disable* from one tab to the whole app is the opposite of
    /// what the caller asked for.
    func pilotScope(_ params: [String: JSONValue]) -> PilotScope {
        guard let raw = rawString(params, "surface") else { return .global }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let surfaceID = UUID(uuidString: trimmed) else { return .invalidSurface }
        return .surface(surfaceID)
    }

    static var invalidPilotSurface: ControlCallResult {
        .err(code: "invalid_params", message: "surface must be a surface UUID", data: nil)
    }

    /// `feed.jump` — resolve whether a workstream id maps to a known surface.
    func feedJump(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let workstreamID = rawString(params, "workstream_id") else {
            return .err(
                code: "invalid_params",
                message: "feed.jump requires workstream_id",
                data: nil
            )
        }
        // MVP: resolve to a cmux surface via `SessionIndexStore` lands in
        // the UI PR; for now we return whether the id is known so callers
        // can show a toast.
        let matched = context?.controlFeedResolvePossibleSurface(workstreamID: workstreamID) ?? false
        return .ok(.object([
            "workstream_id": .string(workstreamID),
            "matched": .bool(matched),
        ]))
    }

    /// `feed.list` — snapshot the workstream feed items.
    func feedList(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy used a plain `params["pending_only"] as? Bool`, so only a real
        // JSON boolean counts; anything else (including coercible strings/numbers)
        // falls back to `false`.
        let pendingOnly: Bool
        if case .bool(let value)? = params["pending_only"] {
            pendingOnly = value
        } else {
            pendingOnly = false
        }
        let items = context?.controlFeedSnapshotItems(pendingOnly: pendingOnly) ?? []
        return .ok(.object(["items": .array(items)]))
    }
}
