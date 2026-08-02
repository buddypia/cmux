import CmuxSidebar
import Foundation

extension Workspace {
    func sidebarStatusEntriesVisibleForDisplay() -> [SidebarStatusEntry] {
        let visibleStructuredStatusKeys = visibleStructuredAgentStatusKeysByPanel()
        return statusEntries.values.filter { entry in
            shouldDisplaySidebarStatusEntry(entry, visibleStructuredStatusKeys: visibleStructuredStatusKeys)
        }
    }

    private func shouldDisplaySidebarStatusEntry(
        _ entry: SidebarStatusEntry,
        visibleStructuredStatusKeys: Set<String>
    ) -> Bool {
        guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key) else {
            return true
        }
        return visibleStructuredStatusKeys.contains(entry.key)
    }

    private func visibleStructuredAgentStatusKeysByPanel() -> Set<String> {
        var statusKeysByPanelId: [UUID: Set<String>] = [:]
        for (key, panelId) in agentPIDPanelIdsByKey
        where panels[panelId] != nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            statusKeysByPanelId[panelId, default: []].insert(statusKey)
        }
        var visibleStatusKeys = Set<String>()
        for statusKeys in statusKeysByPanelId.values {
            let winningEntry = statusKeys.compactMap { statusEntries[$0] }.max {
                isSidebarStatusEntryLessCurrent($0, than: $1)
            }
            if let winningEntry {
                visibleStatusKeys.insert(winningEntry.key)
            }
        }

        for key in agentPIDs.keys where agentPIDPanelIdsByKey[key] == nil {
            let statusKey = agentStatusKey(forAgentPIDKey: key)
            guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey),
                  statusEntries[statusKey] != nil else {
                continue
            }
            visibleStatusKeys.insert(statusKey)
        }

        return visibleStatusKeys
    }

    private func isSidebarStatusEntryLessCurrent(
        _ lhs: SidebarStatusEntry,
        than rhs: SidebarStatusEntry
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        return lhs.key > rhs.key
    }
}

/// Drops the agent hooks' generic "stopped" status row from a sidebar row that
/// already carries the per-CLI badge strip.
///
/// Both hook lanes clear a running status by overwriting it with a placeholder
/// row (`set_status <key> Idle --icon=pause.circle.fill --color=#8E8E93` in
/// `CLI/cmux.swift`). That write exists to erase the previous status, so the row
/// it leaves behind carries no news: it does not name the CLI, does not say how
/// many of its surfaces stopped, and its wording collides with the strip's —
/// `Idle` there means "ran and stopped", which the strip draws as `✅`, while
/// the strip's own `💤 Idle` means "never ran".
///
/// Applied where the snapshot is built rather than inside
/// ``Workspace/sidebarStatusEntriesVisibleForDisplay()``: the rule is about two
/// presentations sitting next to each other in one sidebar row, so `get_status`,
/// the control sidebar, and the CLI keep reporting the entry unchanged.
enum SidebarAgentIdleStatusEntry {
    /// The icon/colour pair every idle-clearing write carries.
    ///
    /// Matched on instead of the label because the hook renders its text with
    /// the *hook process's* locale, which need not be the app's — a text match
    /// would silently stop filtering for anyone whose shell runs under a
    /// different `LANG`. No status writer in `Sources/` emits this pair, and the
    /// SSH-suspended row uses `pause.circle` (no `.fill`) under a key that is
    /// not an agent lane, so it is not caught here.
    static let placeholderIcon = "pause.circle.fill"
    static let placeholderColorHex = "#8e8e93"

    /// - Parameters:
    ///   - entries: The workspace's visible status rows, in display order.
    ///   - badgedAgentKeys: Canonical definition ids the badge strip is drawing
    ///     (``AgentStatusBadgeGroup/agentKey``). Empty — no agents, or the
    ///     user's "title only" mode hid the strip — keeps every row, because
    ///     then the placeholder is the only agent status the row has left.
    static func hidingRedundantPlaceholders(
        in entries: [SidebarStatusEntry],
        badgedAgentKeys: Set<String>
    ) -> [SidebarStatusEntry] {
        guard !badgedAgentKeys.isEmpty else { return entries }
        return entries.filter { !isRedundantPlaceholder($0, badgedAgentKeys: badgedAgentKeys) }
    }

    private static func isRedundantPlaceholder(
        _ entry: SidebarStatusEntry,
        badgedAgentKeys: Set<String>
    ) -> Bool {
        guard entry.icon == placeholderIcon,
              entry.color?.lowercased() == placeholderColorHex,
              // A row that opens something is a destination, never a cleanup write.
              entry.url == nil,
              AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key) else {
            return false
        }
        // The strip groups by definition id, so `claude_code` has to be folded
        // to `claude` before asking whether its CLI is on the strip.
        return badgedAgentKeys.contains(
            AgentStatusKeyDisplayName.canonicalDefinitionId(forStatusKey: entry.key)
        )
    }
}
