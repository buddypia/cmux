import Foundation

/// Pure, view-agnostic logic for "follow the live tail only while the user is
/// already at the bottom" — the product rule shared by the iOS transcript list
/// and the macOS desktop transcript panel.
///
/// Extracted so the follow/auto-scroll decision is unit-testable without a
/// `UITableView` / `NSScrollView` host. Mirrors the threshold semantics of the
/// iOS `ChatTranscriptTableView` coordinator (`atBottomThreshold = 40`), where
/// the behaviour currently lives coupled to UIKit geometry.
public enum TranscriptFollowLogic {
    /// Distance (in points) within which the viewport is treated as pinned to
    /// the bottom, absorbing sub-pixel drift and momentum overscroll.
    public static let defaultAtBottomThreshold: CGFloat = 40

    /// Whether the viewport is effectively at the bottom of the content.
    ///
    /// - Parameters:
    ///   - contentHeight: Total scrollable content height.
    ///   - viewportHeight: Visible viewport height.
    ///   - scrollOffsetY: Current vertical scroll offset (top of the viewport).
    ///   - bottomInset: Space reserved at the bottom (e.g. a composer). Default 0.
    ///   - threshold: At-bottom tolerance in points.
    /// - Returns: `true` when the last content is visible within `threshold`,
    ///   or when the content is shorter than the visible area.
    public static func isAtBottom(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        scrollOffsetY: CGFloat,
        bottomInset: CGFloat = 0,
        threshold: CGFloat = defaultAtBottomThreshold
    ) -> Bool {
        // Content shorter than the visible area can never scroll: treat as bottom.
        guard contentHeight > viewportHeight - bottomInset else { return true }
        let distanceFromBottom = contentHeight - (scrollOffsetY + viewportHeight - bottomInset)
        return distanceFromBottom <= threshold
    }

    /// Whether newly-arrived content should auto-scroll the viewport to the
    /// bottom.
    ///
    /// Follows only when the user was already at the bottom, unless an explicit
    /// "jump to latest" (pill tap / send) was requested — the transcript never
    /// steals scroll from a reading user.
    public static func shouldAutoFollow(
        wasAtBottom: Bool,
        explicitScrollToBottomRequested: Bool = false
    ) -> Bool {
        explicitScrollToBottomRequested || wasAtBottom
    }
}
