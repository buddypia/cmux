import Foundation
import Testing

@testable import CmuxAgentChat

/// Fixture rows mirror what Antigravity CLI draws in a cmux terminal surface:
/// a braille spinner line while a turn runs, and an empty `>` prompt above the
/// shortcuts hint once it is waiting for input.
@Suite("AntigravityLiveScreenState")
struct AntigravityLiveScreenStateTests {
    @Test("spinner line classifies the turn as busy")
    func spinnerLineIsBusy() {
        let rows = [
            "some earlier output",
            "⠹ Working on your request…",
            "",
        ]
        #expect(AntigravityLiveScreenState.classify(screenRows: rows) == .busy)
    }

    @Test("busy detection accepts the bullet spinner and bare status word")
    func alternateSpinnerGlyphs() {
        #expect(AntigravityLiveScreenState.isBusy(screenRows: ["• Loading"]))
        #expect(AntigravityLiveScreenState.isBusy(screenRows: ["Working."]))
        #expect(AntigravityLiveScreenState.isBusy(screenRows: ["  ✦  working models"]))
    }

    @Test("prose that merely mentions working is not a spinner line")
    func proseIsNotBusy() {
        #expect(!AntigravityLiveScreenState.isBusy(screenRows: [
            "I am working on the refactor now",
            "Here is what I changed:",
        ]))
    }

    @Test("empty prompt above the shortcuts hint classifies as idle")
    func idlePromptShape() {
        let rows = [
            "Done — updated 3 files.",
            "",
            ">",
            "? for shortcuts",
        ]
        #expect(AntigravityLiveScreenState.classify(screenRows: rows) == .idle)
    }

    @Test("a spinner outranks a stale prompt row left in the scrollback")
    func busyOutranksStalePrompt() {
        let rows = [
            ">",
            "? for shortcuts",
            "⠋ Working…",
        ]
        #expect(AntigravityLiveScreenState.classify(screenRows: rows) == .busy)
    }

    @Test("a prompt the user already typed into is not idle")
    func typedPromptIsNotIdle() {
        let rows = [
            "> refactor the parser",
            "? for shortcuts",
        ]
        #expect(AntigravityLiveScreenState.classify(screenRows: rows) == .unknown)
    }

    @Test("the idle shape is only looked for near the bottom of the screen")
    func idleShapeIsTailScoped() {
        var rows = [">", "? for shortcuts"]
        rows.append(contentsOf: (0..<8).map { "output line \($0)" })
        #expect(AntigravityLiveScreenState.classify(screenRows: rows) == .unknown)
    }

    @Test("a screen with neither signal stays unknown")
    func unknownScreen() {
        #expect(AntigravityLiveScreenState.classify(screenRows: ["$ ls", "README.md"]) == .unknown)
        #expect(AntigravityLiveScreenState.classify(screenRows: []) == .unknown)
    }
}
