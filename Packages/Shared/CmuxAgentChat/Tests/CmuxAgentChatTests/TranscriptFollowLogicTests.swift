import Foundation
import Testing

@testable import CmuxAgentChat

@Suite struct TranscriptFollowLogicTests {
    // MARK: isAtBottom

    @Test func atBottomWhenWithinThreshold() {
        // distance = 1000 - (660 + 300) = 40 ≤ 40
        #expect(TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 660))
    }

    @Test func notAtBottomWhenScrolledAway() {
        // distance = 1000 - (500 + 300) = 200 > 40
        #expect(!TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 500))
    }

    @Test func atBottomExactlyAtEnd() {
        // distance = 1000 - (700 + 300) = 0
        #expect(TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 700))
    }

    @Test func overscrollStaysAtBottom() {
        // distance = 1000 - (720 + 300) = -20 ≤ 40
        #expect(TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 720))
    }

    @Test func contentShorterThanViewportIsAtBottom() {
        #expect(TranscriptFollowLogic.isAtBottom(contentHeight: 120, viewportHeight: 300, scrollOffsetY: 0))
    }

    @Test func bottomInsetShiftsBoundary() {
        // effective bottom = offset + (300 - 60). content 1000.
        // offset 720 → distance = 1000 - (720 + 240) = 40 ≤ 40 (at bottom)
        #expect(TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 720, bottomInset: 60))
        // offset 700 → distance = 1000 - (700 + 240) = 60 > 40 (not at bottom)
        #expect(!TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 700, bottomInset: 60))
    }

    @Test func customThreshold() {
        // distance = 1000 - (600 + 300) = 100
        #expect(TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 600, threshold: 120))
        #expect(!TranscriptFollowLogic.isAtBottom(contentHeight: 1000, viewportHeight: 300, scrollOffsetY: 600, threshold: 80))
    }

    // MARK: shouldAutoFollow

    @Test func followsWhenWasAtBottom() {
        #expect(TranscriptFollowLogic.shouldAutoFollow(wasAtBottom: true))
    }

    @Test func doesNotFollowWhenScrolledAway() {
        #expect(!TranscriptFollowLogic.shouldAutoFollow(wasAtBottom: false))
    }

    @Test func explicitRequestOverridesScrolledAway() {
        #expect(TranscriptFollowLogic.shouldAutoFollow(wasAtBottom: false, explicitScrollToBottomRequested: true))
    }
}
