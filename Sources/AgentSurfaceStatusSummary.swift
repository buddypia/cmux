import Foundation

/// Resolves the human-facing CLI name behind an agent status key.
///
/// The status keys the agent hooks report (`claude_code`, `rovodev`, …) are
/// wire identifiers, not display text. Every surface that shows "which CLI is
/// this" — the tab title, the sidebar badge tooltip — routes through here so a
/// rename lands in one place instead of three hand-written switch statements.
enum AgentStatusKeyDisplayName {
    /// Status keys whose spelling differs from the coding-agent definition id
    /// they describe. Everything else matches its definition id verbatim.
    private static let definitionIdOverrides: [String: String] = [
        "claude_code": "claude",
    ]

    /// Key namespaces cmux writes *in front of* a CLI id instead of behind it.
    ///
    /// `AgentChatTranscriptService` mirrors chat-session state onto a surface
    /// under `agentchat.<cli>` so it cannot clobber the hook writer's key. For
    /// those keys the CLI is the tail, so the plain "everything before the
    /// first dot" rule would name the writer (`Agentchat`) instead of the CLI.
    private static let writerNamespaces: Set<String> = ["agentchat"]

    /// The bare status key for a PID/lifecycle key, dropping the
    /// `<statusKey>.<discriminator>` suffix the agent hooks append to PID keys
    /// and unwrapping the writer namespaces above.
    static func normalized(_ key: String) -> String {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard let head = segments.first, !head.isEmpty else { return key }
        guard writerNamespaces.contains(String(head)) else { return String(head) }
        guard segments.count > 1, !segments[1].isEmpty else { return String(head) }
        return String(segments[1])
    }

    /// Display names indexed by definition id. Built once: the tab-title path
    /// resolves a name on every title update, and a linear scan of the built-in
    /// list per call would put ~20 string compares on that path for nothing.
    private static let displayNamesByDefinitionId: [String: String] = Dictionary(
        CmuxTaskManagerCodingAgentDefinition.builtIns.map { ($0.id, $0.displayName) },
        uniquingKeysWith: { first, _ in first }
    )

    /// The coding-agent definition id behind a status key — the identity two
    /// writers of the same CLI agree on.
    ///
    /// `claude_code` (hook), `claude_code.4821` (PID) and `agentchat.claude`
    /// (chat mirror) all canonicalize to `claude`, so grouping on this cannot
    /// split one CLI into several buckets. Unknown keys canonicalize to
    /// themselves, which is what keeps user-registered vault agents working.
    static func canonicalDefinitionId(forStatusKey key: String) -> String {
        let normalizedKey = normalized(key)
        return definitionIdOverrides[normalizedKey] ?? normalizedKey
    }

    /// Display name for `key`, e.g. `claude_code` → `Claude Code`.
    ///
    /// Falls back to a title-cased form of the key so a CLI that ships a status
    /// key before it has a coding-agent definition still reads as a name rather
    /// than as a raw identifier.
    static func displayName(forStatusKey key: String) -> String {
        let definitionId = canonicalDefinitionId(forStatusKey: key)
        return displayNamesByDefinitionId[definitionId] ?? titleCased(definitionId)
    }

    /// A short name for tight spaces (the tab title). Uses the first word of the
    /// display name so `Claude Code` reads as `Claude` in a narrow tab.
    static func shortDisplayName(forStatusKey key: String) -> String {
        let full = displayName(forStatusKey: key)
        guard let firstWord = full.split(separator: " ").first else { return full }
        return String(firstWord)
    }

    /// Abbreviations for the sidebar's agent-status strip, where a pill has to
    /// fit a CLI name *and* its per-status counts inside a sidebar row.
    ///
    /// Only CLIs whose short form is already how people write them are listed;
    /// inventing an abbreviation for the rest would cost more legibility than
    /// the width it buys, so everything else falls back to the first word of
    /// the display name.
    private static let badgeDisplayNameOverrides: [String: String] = [
        "antigravity": "Agy",
        "claude": "CC",
        "codex": "Cdx",
    ]

    /// The name the sidebar status pill draws, e.g. `claude_code` → `CC`.
    ///
    /// Deliberately separate from ``shortDisplayName(forStatusKey:)``: a tab
    /// title has room to say `Claude`, and tooltips and the accessibility label
    /// still say `Claude Code`, so the abbreviation never becomes the only
    /// place the CLI is named.
    static func badgeDisplayName(forStatusKey key: String) -> String {
        let definitionId = canonicalDefinitionId(forStatusKey: key)
        return badgeDisplayNameOverrides[definitionId] ?? shortDisplayName(forStatusKey: key)
    }

    private static func titleCased(_ key: String) -> String {
        key
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// One surface's agent status, resolved from either the live runtime maps or
/// the status persisted with the last session snapshot.
///
/// `isRestored` is the load-bearing distinction: after an app restart the agent
/// process is gone, so the status is the *last known* one rather than a live
/// reading. Callers dim it and say so in the tooltip instead of claiming a dead
/// process is still working.
struct AgentSurfaceStatusSummary: Equatable, Sendable {
    let status: AgentTabTitleStatus
    /// The agent status key that won the surface (`claude_code`, `codex`, …).
    let agentKey: String
    /// Whether this came from a restored session snapshot rather than a live agent.
    let isRestored: Bool
    /// The agent's last conversation output on this surface, if one was captured.
    /// `var` so a restored summary can adopt a fresher live message without
    /// rebuilding every other field.
    var lastMessage: String?

    var agentDisplayName: String { AgentStatusKeyDisplayName.displayName(forStatusKey: agentKey) }
    var agentShortDisplayName: String { AgentStatusKeyDisplayName.shortDisplayName(forStatusKey: agentKey) }

    /// Resolves the summary for one surface from its lifecycle map.
    ///
    /// - Parameters:
    ///   - lifecycleStates: The surface's per-agent lifecycle entries. Manual
    ///     `cmux workspace loading` keys are ignored — they are script-driven
    ///     progress spinners, not coding agents.
    ///   - hasBeenActive: Whether any agent on this surface reached `.running`
    ///     since the surface was created.
    ///   - lastMessage: The agent's last conversation output on this surface.
    /// - Returns: `nil` when no coding agent is bound to the surface.
    static func resolve(
        lifecycleStates: [String: AgentHibernationLifecycleState],
        hasBeenActive: Bool,
        lastMessage: String? = nil
    ) -> AgentSurfaceStatusSummary? {
        guard let status = AgentTabTitleStatus.resolve(
            lifecycleStates: lifecycleStates,
            hasBeenActive: hasBeenActive
        ) else { return nil }
        let agentStates = lifecycleStates.filter {
            !AgentHibernationLifecycleStatusKeys.isManualKey($0.key)
        }
        guard let agentKey = winningAgentKey(agentStates: agentStates, status: status) else { return nil }
        return AgentSurfaceStatusSummary(
            status: status,
            agentKey: agentKey,
            isRestored: false,
            lastMessage: lastMessage
        )
    }

    /// The key whose state produced `status`, so a surface hosting two agents
    /// names the one the marker is actually about. Ties break on the key so the
    /// answer is stable across dictionary orderings.
    private static func winningAgentKey(
        agentStates: [String: AgentHibernationLifecycleState],
        status: AgentTabTitleStatus
    ) -> String? {
        if status == .running {
            let actionable = agentStates
                .filter { $0.value == .running || $0.value == .needsInput }
                .keys
                .sorted()
            if let first = actionable.first { return first }
        }
        return agentStates.keys.sorted().first
    }
}

/// The agent status a surface had when the session snapshot was written.
///
/// Restored verbatim on the next launch: the process is gone, but "Claude Code
/// finished, and this is what it said" is the answer the user came back for.
/// Kept separate from the live map so a resumed agent's first real lifecycle
/// report replaces it rather than merging with it.
struct RestoredAgentSurfaceStatus: Equatable, Sendable {
    let status: AgentTabTitleStatus
    let agentKey: String
    let lastMessage: String?

    var summary: AgentSurfaceStatusSummary {
        AgentSurfaceStatusSummary(
            status: status,
            agentKey: agentKey,
            isRestored: true,
            lastMessage: lastMessage
        )
    }
}

/// One `<marker><count>` segment inside a CLI's pill in the sidebar's
/// agent-status strip, e.g. the `⚡2` of `Claude ⚡2 ✅1`.
struct AgentStatusBadgeCount: Equatable, Sendable, Identifiable {
    let status: AgentTabTitleStatus
    let count: Int
    /// Whether every surface behind this count came from a restored session.
    let isRestored: Bool

    var id: String { status.rawValue }
}

/// One CLI's pill in the sidebar's agent-status strip: which CLI, and how many
/// of its surfaces sit in each state.
///
/// A workspace running Codex in two terminals and Claude Code in a third draws
/// `Codex ⚡1 ✅1` next to `Claude ⚡1` rather than one merged `⚡2 ✅1`, so
/// "has Claude finished?" is answerable without opening the workspace.
struct AgentStatusBadgeGroup: Equatable, Sendable, Identifiable {
    /// Canonical coding-agent id (`claude`, `codex`, …). The PID discriminator
    /// and any writer namespace are already gone, so the hook lane and the chat
    /// mirror of one CLI land in the same group instead of reading as two CLIs.
    let agentKey: String
    /// This CLI's per-status surface counts, ordered Working → Done → Idle.
    let badges: [AgentStatusBadgeCount]

    var id: String { agentKey }
    var displayName: String { AgentStatusKeyDisplayName.displayName(forStatusKey: agentKey) }
    /// Abbreviated name for the pill itself (`CC`, `Cdx`, `Agy`), so the name
    /// and the counts both fit a sidebar row. The full name still leads the
    /// tooltip and the accessibility label.
    var badgeDisplayName: String { AgentStatusKeyDisplayName.badgeDisplayName(forStatusKey: agentKey) }
    /// How many of the workspace's surfaces this CLI owns.
    var surfaceCount: Int { badges.reduce(0) { $0 + $1.count } }
    /// The same rule the per-status pills use, one level up: the group reads as
    /// history only when every surface behind it came from a restored session.
    var isRestored: Bool { !badges.isEmpty && badges.allSatisfy(\.isRestored) }
    /// The most actionable state this CLI is in, or `nil` when it has no
    /// surfaces. Drives group ordering and the "is anything still running?"
    /// read of the strip.
    var leadingStatus: AgentTabTitleStatus? { badges.first?.status }
}

/// Aggregates per-surface statuses into the badge strip the sidebar renders.
enum AgentStatusBadgeSummary {
    /// Counts surfaces per status, ordered Working → Done → Idle so the most
    /// actionable pill is always leftmost regardless of how many exist.
    ///
    /// A pill is marked restored only when *every* surface it counts is
    /// restored: one live agent in the group means the count is live data.
    static func badges(from summaries: [AgentSurfaceStatusSummary]) -> [AgentStatusBadgeCount] {
        var countsByStatus: [AgentTabTitleStatus: Int] = [:]
        var liveStatuses: Set<AgentTabTitleStatus> = []
        for summary in summaries {
            countsByStatus[summary.status, default: 0] += 1
            if !summary.isRestored { liveStatuses.insert(summary.status) }
        }
        return AgentTabTitleStatus.displayOrder.compactMap { status in
            guard let count = countsByStatus[status], count > 0 else { return nil }
            return AgentStatusBadgeCount(
                status: status,
                count: count,
                isRestored: !liveStatuses.contains(status)
            )
        }
    }

    /// Splits the surfaces per CLI, so a workspace whose terminals run Codex,
    /// Claude Code and Antigravity draws one pill per CLI instead of one merged
    /// count that cannot say which of them is still working.
    ///
    /// Grouping is on the canonical coding-agent id, never the raw lifecycle
    /// key: a raw key carries the agent's PID, so an agent restart would mint a
    /// second "Claude Code" group and make the sidebar snapshot compare unequal
    /// on a tick where nothing user-visible changed.
    static func cliGroups(from summaries: [AgentSurfaceStatusSummary]) -> [AgentStatusBadgeGroup] {
        var summariesByAgentKey: [String: [AgentSurfaceStatusSummary]] = [:]
        for summary in summaries {
            let key = AgentStatusKeyDisplayName.canonicalDefinitionId(forStatusKey: summary.agentKey)
            summariesByAgentKey[key, default: []].append(summary)
        }
        return summariesByAgentKey
            .map { AgentStatusBadgeGroup(agentKey: $0.key, badges: badges(from: $0.value)) }
            .sorted(by: isOrderedBefore)
    }

    /// Most actionable CLI first, so "no `⚡` in the leading pill" means nothing
    /// is running anywhere in the workspace.
    ///
    /// Ties break on surface count and then on the canonical id, never on
    /// dictionary order: an unstable order would make every sidebar snapshot
    /// compare unequal and thrash the row-height cache on every refresh.
    private static func isOrderedBefore(_ lhs: AgentStatusBadgeGroup, _ rhs: AgentStatusBadgeGroup) -> Bool {
        let lhsRank = statusRank(lhs.leadingStatus)
        let rhsRank = statusRank(rhs.leadingStatus)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.surfaceCount != rhs.surfaceCount { return lhs.surfaceCount > rhs.surfaceCount }
        return lhs.agentKey < rhs.agentKey
    }

    private static func statusRank(_ status: AgentTabTitleStatus?) -> Int {
        guard let status,
              let index = AgentTabTitleStatus.displayOrder.firstIndex(of: status) else {
            return AgentTabTitleStatus.displayOrder.count
        }
        return index
    }

    /// The conversation output to show for the workspace, preferring a working
    /// surface and then a finished one: while an agent is mid-turn, its output
    /// is what the user is waiting on, and a finished sibling's text would bury
    /// it. Within a status, the first surface in the caller's order wins.
    static func latestOutput(from summaries: [AgentSurfaceStatusSummary]) -> String? {
        let withMessages = summaries.filter { ($0.lastMessage?.isEmpty == false) }
        guard !withMessages.isEmpty else { return nil }
        let preferred = withMessages.first { $0.status == .running }
            ?? withMessages.first { $0.status == .done }
            ?? withMessages[0]
        return preferred.lastMessage
    }
}
