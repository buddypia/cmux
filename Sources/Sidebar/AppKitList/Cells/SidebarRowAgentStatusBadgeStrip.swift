import AppKit

/// One CLI's `Claude ⚡2 ✅1` pill in the sidebar row's agent-status strip.
@MainActor
final class SidebarRowAgentStatusPill: NSView {
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // Leading + tail truncation, because a pill now carries a CLI name that
        // can outgrow a narrow sidebar. Centred clipping would eat both ends and
        // leave `aude ⚡2 ✅`, which names neither the CLI nor the counts.
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        group: AgentStatusBadgeGroup,
        font: NSFont,
        textColor: NSColor,
        fillColor: NSColor,
        toolTip: String
    ) {
        label.stringValue = SidebarAgentStatusBadgeText.pillText(for: group)
        label.font = font
        label.textColor = textColor
        layer?.backgroundColor = fillColor.cgColor
        // A restored pill reports the status the surface had before the app
        // quit, so it reads as history rather than as a live process.
        alphaValue = group.isRestored ? 0.62 : 1.0
        self.toolTip = toolTip
        needsLayout = true
    }

    /// Intrinsic pill size: text plus the horizontal/vertical padding that
    /// makes the capsule read as a badge instead of as bare text.
    ///
    /// - Parameter maxWidth: The row's content width. The pill is clamped to it
    ///   so a long CLI name truncates inside the capsule instead of painting
    ///   past the row's trailing edge — the row does not clip its subviews.
    func fittingPillSize(maxWidth: CGFloat) -> NSSize {
        let textSize = label.sidebarNaturalCellSize
        let naturalWidth = ceil(textSize.width) + 10
        return NSSize(width: min(naturalWidth, max(maxWidth, 0)), height: ceil(textSize.height) + 3)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: 5, dy: 1.5)
    }
}

/// Background tint for one CLI's pill, keyed on the most actionable state that
/// CLI is in.
///
/// Colour is what makes the strip scannable: with every pill on the same grey a
/// row of five workspaces has to be *read* to answer "is anything still
/// running", and at 9pt the status emoji is too small to carry that alone. The
/// tint is a low-alpha wash rather than a solid fill so the pill still reads as
/// a badge on the row, and it never replaces the emoji — the marker and the
/// counts stay, so nothing is conveyed by colour alone.
///
/// Kept beside the text helpers, and derived only from values the caller passes
/// in, so the AppKit row and the SwiftUI fallback row cannot drift apart and no
/// colour is resolved against the current window appearance.
enum SidebarAgentStatusBadgeTint {
    /// - Parameters:
    ///   - status: The group's leading status, or `nil` for a group with no counts.
    ///   - isActive: Whether the row is selected. The selected row already has an
    ///     accent background, so the wash needs more alpha to survive on it.
    ///   - neutral: The row's ordinary badge fill, used for idle and unknown —
    ///     "launched but never ran" is the absence of news, not a state worth
    ///     colouring.
    static func fill(
        for status: AgentTabTitleStatus?,
        isActive: Bool,
        neutral: NSColor
    ) -> NSColor {
        let alpha: CGFloat = isActive ? 0.38 : 0.24
        switch status {
        case .running:
            return NSColor(srgbRed: 1.00, green: 0.72, blue: 0.16, alpha: alpha)
        case .done:
            return NSColor(srgbRed: 0.24, green: 0.76, blue: 0.44, alpha: alpha)
        case .idle, nil:
            return neutral
        }
    }
}

/// Formatting for the agent-status badge strip, kept out of the view so the
/// AppKit row and the SwiftUI fallback row render identical text and tooltips.
enum SidebarAgentStatusBadgeText {
    /// The pill's own text, e.g. `CC ⚡2 ✅1`.
    ///
    /// The abbreviated CLI name leads because the pill answers "which CLI, in
    /// what state" in that order, and because the markers are the part that must
    /// survive tail truncation intact — they carry the counts.
    static func pillText(for group: AgentStatusBadgeGroup) -> String {
        let counts = group.badges
            .map { "\($0.status.rawValue)\($0.count)" }
            .joined(separator: " ")
        return "\(group.badgeDisplayName) \(counts)"
    }

    /// Tooltip for one pill: which CLI, how many of its surfaces are in each
    /// state, and whether the reading is live or the last one before restart.
    static func tooltip(for group: AgentStatusBadgeGroup) -> String {
        let summary = summaryText(for: group)
        guard group.isRestored else { return summary }
        return String(
            format: String(
                localized: "sidebar.agentStatus.badge.agentSummary.restored",
                defaultValue: "%1$@ — %2$@ (last status before restore)"
            ),
            group.displayName,
            statusCountList(for: group)
        )
    }

    /// Accessibility label for the whole strip, e.g.
    /// "Agents: Claude Code — 2 Working, 1 Done; Codex — 3 Idle".
    static func accessibilityLabel(for groups: [AgentStatusBadgeGroup]) -> String {
        let separator = String(
            localized: "sidebar.agentStatus.badge.agentSeparator",
            defaultValue: "; "
        )
        return String(
            format: String(
                localized: "sidebar.agentStatus.badge.accessibilityLabel",
                defaultValue: "Agents: %@"
            ),
            groups.map(summaryText(for:)).joined(separator: separator)
        )
    }

    /// `Claude Code — 2 Working, 1 Done`, the phrasing both the tooltip and the
    /// accessibility label build on.
    private static func summaryText(for group: AgentStatusBadgeGroup) -> String {
        String(
            format: String(
                localized: "sidebar.agentStatus.badge.agentSummary",
                defaultValue: "%1$@ — %2$@"
            ),
            group.displayName,
            statusCountList(for: group)
        )
    }

    /// `2 Working, 1 Done` — the counts alone, in the strip's display order.
    private static func statusCountList(for group: AgentStatusBadgeGroup) -> String {
        let separator = String(
            localized: "sidebar.agentStatus.badge.itemSeparator",
            defaultValue: ", "
        )
        return group.badges.map { badge in
            String(
                format: String(
                    localized: "sidebar.agentStatus.badge.accessibilityItem",
                    defaultValue: "%1$lld %2$@"
                ),
                Int64(badge.count),
                badge.status.badgeLabel
            )
        }.joined(separator: separator)
    }
}
