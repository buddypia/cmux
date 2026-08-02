import SwiftUI

/// SwiftUI counterpart to ``SidebarRowAgentStatusPill`` for the legacy
/// (non-AppKit-list) sidebar row.
///
/// Both rows read the same ``AgentStatusBadgeGroup`` values and the same
/// ``SidebarAgentStatusBadgeText`` strings, so switching the
/// `appkit-sidebar-list` flag cannot change what the strip says.
struct SidebarWorkspaceAgentStatusBadges: View {
    let groups: [AgentStatusBadgeGroup]
    let fontSize: CGFloat
    let textColor: Color
    let fillColor: Color

    var body: some View {
        if groups.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(groups) { group in
                    Text(verbatim: SidebarAgentStatusBadgeText.pillText(for: group))
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(fillColor))
                        .opacity(group.isRestored ? 0.62 : 1.0)
                        .safeHelp(SidebarAgentStatusBadgeText.tooltip(for: group))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SidebarAgentStatusBadgeText.accessibilityLabel(for: groups))
        }
    }
}
