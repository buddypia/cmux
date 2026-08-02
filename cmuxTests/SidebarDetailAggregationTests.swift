import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A workspace running several terminals used to grow one sidebar chip per
/// listening port and show only the newest of N identical notification lines.
/// These cover the capped/aggregated replacements.
final class SidebarDetailAggregationTests: XCTestCase {
    func testPortsUnderTheLimitAreAllVisible() {
        let display = SidebarDetailAggregation.portDisplay(ports: [3000, 3001], limit: 3)

        XCTAssertEqual(display.visible, [3000, 3001])
        XCTAssertTrue(display.overflow.isEmpty)
        XCTAssertFalse(display.hasOverflow)
    }

    func testPortsAtExactlyTheLimitDoNotOverflow() {
        let display = SidebarDetailAggregation.portDisplay(ports: [3000, 3001, 3002], limit: 3)

        XCTAssertEqual(display.visible, [3000, 3001, 3002])
        XCTAssertFalse(display.hasOverflow)
    }

    func testExcessPortsCollapseIntoTheOverflowChip() {
        let display = SidebarDetailAggregation.portDisplay(
            ports: [3000, 3001, 3002, 4000, 5173, 8080],
            limit: 3
        )

        XCTAssertEqual(display.visible, [3000, 3001, 3002])
        XCTAssertEqual(display.overflow, [4000, 5173, 8080])
        XCTAssertEqual(display.overflowCount, 3)
    }

    func testZeroLimitCollapsesEveryPort() {
        let display = SidebarDetailAggregation.portDisplay(ports: [3000, 3001], limit: 0)

        XCTAssertTrue(display.visible.isEmpty)
        XCTAssertEqual(display.overflow, [3000, 3001])
    }

    func testOverflowLabelResolvesTheCatalogPlaceholder() {
        let label = SidebarDetailAggregation.portOverflowLabel(count: 5)

        XCTAssertEqual(label, "+5")
        XCTAssertFalse(label.contains("%lld"))
    }

    func testOverflowTooltipListsEveryHiddenPort() {
        let tooltip = SidebarDetailAggregation.portOverflowTooltip(ports: [4000, 5173])

        XCTAssertFalse(tooltip.contains("%lld"))
        XCTAssertFalse(tooltip.contains("%@"))
        XCTAssertTrue(tooltip.contains("4000, 5173"))
    }

    func testSingleSurfaceNotificationTextIsUnchanged() {
        let text = SidebarDetailAggregation.notificationText("CLI is ready for input", surfaceCount: 1)

        XCTAssertEqual(text, "CLI is ready for input")
    }

    func testAbsentSurfaceCountLeavesTheTextBare() {
        // The displayed line can be a read notification with no unread peers;
        // that must not render as "×0".
        let text = SidebarDetailAggregation.notificationText("CLI is ready for input", surfaceCount: 0)

        XCTAssertEqual(text, "CLI is ready for input")
    }

    func testRepeatedNotificationGainsAMultiplier() {
        let text = SidebarDetailAggregation.notificationText("CLI is ready for input", surfaceCount: 3)

        XCTAssertEqual(text, "CLI is ready for input ×3")
        XCTAssertFalse(text.contains("%"))
    }
}
