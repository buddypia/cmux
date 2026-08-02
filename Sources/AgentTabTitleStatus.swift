import Foundation

/// The at-a-glance agent status cmux stamps onto a surface tab title.
///
/// Port of Agent Studio's `agentStatusEmoji` (`server/src/statusUtils.ts`).
/// Only three states exist on purpose: a tab title that flips through every
/// intermediate FSM state churns the tab bar many times per turn, so
/// `needsInput` folds into ``running`` exactly as Agent Studio folds
/// `permissionPending` into `⚡`.
///
/// The marker is a *prefix* because cmux truncates long tab titles from the
/// right — a suffix would be the first thing to disappear on a narrow tab.
enum AgentTabTitleStatus: String, CaseIterable, Sendable {
    /// The agent is mid-turn: running a tool, or blocked on a permission
    /// prompt it needs the user to answer.
    case running = "⚡"
    /// The turn finished and the agent has done work at least once in this
    /// session — the "you can read the result now" state.
    case done = "✅"
    /// An agent is bound to the surface but has never been active in this
    /// session (fresh launch, or everything was cleared).
    case idle = "💤"

    /// Most actionable first. The sidebar badge strip and any other ordered
    /// presentation reads this rather than `allCases`, whose order is an
    /// accident of declaration.
    static let displayOrder: [AgentTabTitleStatus] = [.running, .done, .idle]

    /// Marker plus the separating space, ready to prepend to a title.
    var titlePrefix: String { "\(rawValue) " }

    /// Separator between the CLI name and the surface's own title. Also the
    /// token ``undecorated(_:)`` looks for when peeling a stamped CLI name
    /// back off.
    static let agentNameSeparator = " · "

    /// Short word for the state, used by badge tooltips and accessibility.
    var badgeLabel: String {
        switch self {
        case .running:
            return String(localized: "agentStatus.label.working", defaultValue: "Working")
        case .done:
            return String(localized: "agentStatus.label.done", defaultValue: "Done")
        case .idle:
            return String(localized: "agentStatus.label.idle", defaultValue: "Idle")
        }
    }

    /// Resolves the marker for one surface.
    ///
    /// - Parameters:
    ///   - lifecycleStates: The panel's per-agent lifecycle entries. Manual
    ///     workspace-loading keys are ignored: they are progress spinners
    ///     driven by `cmux set-workspace-loading`, not coding agents, and
    ///     marking a plain shell tab `⚡` because a script raised a loader
    ///     would be wrong.
    ///   - hasBeenActive: Whether any agent on this surface has reached
    ///     `.running` since the surface was created. Without it a never-run
    ///     agent and a finished agent are indistinguishable, and every fresh
    ///     tab would claim `✅ Done`.
    /// - Returns: `nil` when no coding agent is bound to the surface, so a
    ///   plain shell tab keeps its bare title.
    static func resolve(
        lifecycleStates: [String: AgentHibernationLifecycleState],
        hasBeenActive: Bool
    ) -> AgentTabTitleStatus? {
        let agentStates = lifecycleStates.filter {
            !AgentHibernationLifecycleStatusKeys.isManualKey($0.key)
        }
        guard !agentStates.isEmpty else { return nil }
        // Priority mirrors statusUtils.ts: anything actionable outranks a
        // finished turn, and a finished turn outranks "never started".
        if agentStates.values.contains(where: { $0 == .running || $0 == .needsInput }) {
            return .running
        }
        return hasBeenActive ? .done : .idle
    }

    /// Prepends the marker (and, when given, the CLI's name) to `title`, or
    /// returns `title` unchanged when the surface has no agent. Idempotent:
    /// re-decorating an already-decorated title replaces the old marker and
    /// name rather than stacking a second one.
    ///
    /// - Parameter agentName: Short CLI name (`Claude`, `Codex`) to stamp
    ///   between the marker and the title. Dropped when the title already says
    ///   it, so an agent whose process title is its own name renders
    ///   `✅ codex`, not `✅ Codex · codex`.
    static func decorate(title: String, status: AgentTabTitleStatus?, agentName: String? = nil) -> String {
        let undecorated = undecorated(title)
        guard let status else { return undecorated }
        guard let agentName, !agentName.isEmpty, !titleAlreadyNames(agentName, in: undecorated) else {
            return status.titlePrefix + undecorated
        }
        return status.titlePrefix + agentName + Self.agentNameSeparator + undecorated
    }

    /// Strips a leading status marker (and the CLI-name segment behind it), so
    /// a decorated title can round-trip back through rename/persistence paths
    /// without accumulating markers.
    static func undecorated(_ title: String) -> String {
        for status in AgentTabTitleStatus.allCases where title.hasPrefix(status.titlePrefix) {
            return strippingAgentNameSegment(String(title.dropFirst(status.titlePrefix.count)))
        }
        // Tolerate a marker written without its trailing space (e.g. a title
        // hand-typed by the user or set through the socket).
        for status in AgentTabTitleStatus.allCases where title.hasPrefix(status.rawValue) {
            return strippingAgentNameSegment(
                String(title.dropFirst(status.rawValue.count))
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        return title
    }

    /// True when `title` already carries the CLI's name, so stamping it again
    /// would only cost tab width.
    private static func titleAlreadyNames(_ agentName: String, in title: String) -> Bool {
        title.lowercased().contains(agentName.lowercased())
    }

    /// Drops a leading `<CLI name> · ` segment — but only when the head is a
    /// name cmux itself stamps. A user title such as `api · staging` keeps
    /// both halves; only cmux-owned segments are cmux's to remove.
    private static func strippingAgentNameSegment(_ title: String) -> String {
        guard let separatorRange = title.range(of: agentNameSeparator) else { return title }
        let head = String(title[title.startIndex..<separatorRange.lowerBound])
        guard knownAgentTitleNames.contains(head.lowercased()) else { return title }
        return String(title[separatorRange.upperBound...])
    }

    /// Every CLI name ``decorate(title:status:agentName:)`` can stamp, lowercased.
    /// Both the full display name and its first word are included because the
    /// tab title uses the short form while other surfaces use the full one.
    private static let knownAgentTitleNames: Set<String> = {
        var names: Set<String> = []
        for definition in CmuxTaskManagerCodingAgentDefinition.builtIns {
            let displayName = definition.displayName.lowercased()
            names.insert(displayName)
            if let firstWord = displayName.split(separator: " ").first {
                names.insert(String(firstWord))
            }
        }
        return names
    }()
}
