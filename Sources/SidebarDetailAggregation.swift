import Foundation

/// Collapses repetitive per-surface sidebar detail rows into one bounded line.
///
/// A single workspace often hosts several terminals running the same kind of
/// work (three dev servers, three agent CLIs). Rendering one chip per listening
/// port and one subtitle per notification made the row grow without bound and
/// buried the signal. Both details are therefore capped: the first
/// ``portChipLimit`` ports stay individually clickable, the rest collapse into
/// a `+N` chip, and a notification body repeated across surfaces renders once
/// with a `×N` multiplier.
///
/// Pure value logic so the sidebar row (AppKit) and the SwiftUI fallback row
/// share one formatting path and unit tests can exercise it without a view.
enum SidebarDetailAggregation {
    /// Number of listening ports rendered as individually clickable chips
    /// before the remainder collapses into the overflow chip.
    static let portChipLimit = 3

    /// A capped port list: the chips to render plus whatever they hide.
    struct PortDisplay: Equatable {
        /// Ports rendered as individual clickable chips.
        let visible: [Int]
        /// Ports folded into the `+N` chip (empty when nothing overflowed).
        let overflow: [Int]

        var overflowCount: Int { overflow.count }
        var hasOverflow: Bool { !overflow.isEmpty }
    }

    /// Splits `ports` into the visible chips and the collapsed remainder.
    ///
    /// - Parameters:
    ///   - ports: Listening ports for the workspace, already de-duplicated and
    ///     sorted by the snapshot builder.
    ///   - limit: Visible chip budget. Values below `1` collapse everything.
    static func portDisplay(ports: [Int], limit: Int = portChipLimit) -> PortDisplay {
        guard limit > 0 else { return PortDisplay(visible: [], overflow: ports) }
        guard ports.count > limit else { return PortDisplay(visible: ports, overflow: []) }
        return PortDisplay(
            visible: Array(ports.prefix(limit)),
            overflow: Array(ports.dropFirst(limit))
        )
    }

    /// Label for the chip that stands in for the collapsed ports (`+5`).
    static func portOverflowLabel(count: Int) -> String {
        String(
            format: String(localized: "sidebar.port.overflowLabel", defaultValue: "+%lld"),
            Int64(count)
        )
    }

    /// Tooltip listing every port the overflow chip hides.
    static func portOverflowTooltip(ports: [Int]) -> String {
        String(
            format: String(
                localized: "sidebar.port.overflowTooltip",
                defaultValue: "%lld more listening ports: %@"
            ),
            Int64(ports.count),
            ports.map(String.init).joined(separator: ", ")
        )
    }

    /// Renders a notification body that several surfaces reported, appending a
    /// `×N` multiplier once more than one surface is waiting on the same text.
    ///
    /// `surfaceCount` at or below `1` returns `text` unchanged so the common
    /// single-terminal case reads exactly as before.
    static func notificationText(_ text: String, surfaceCount: Int) -> String {
        guard surfaceCount > 1 else { return text }
        return String(
            format: String(
                localized: "sidebar.notification.repeatFormat",
                defaultValue: "%1$@ ×%2$lld"
            ),
            text,
            Int64(surfaceCount)
        )
    }
}
