import Foundation

/// Classifies an Antigravity CLI turn from its rendered terminal screen.
///
/// Antigravity is the one supported CLI that publishes neither a resolvable
/// transcript path nor a stable session id to the process table, so the
/// transcript-tail path other agents use has nothing to read. Its TUI does
/// state its own status, though: a spinner line while a turn runs, and an empty
/// `>` prompt above the shortcuts hint once it is waiting for you.
///
/// Port of Agent Studio's `isAntigravityLiveBusyScreen` /
/// `isAntigravityLiveIdlePromptScreen` (`server/src/statusUtils.ts`), kept
/// byte-compatible with the patterns proven there.
public enum AntigravityLiveScreenState: Sendable, Equatable {
    /// A turn is in flight (spinner line present).
    case busy
    /// The prompt is empty and waiting for input.
    case idle
    /// Neither pattern matched — the screen says nothing about the turn (e.g.
    /// mid-scroll, a pager, or a non-Antigravity screen).
    case unknown

    /// Classifies `screen`, the rendered rows top to bottom.
    public static func classify(screenRows: [String]) -> AntigravityLiveScreenState {
        if isBusy(screenRows: screenRows) { return .busy }
        if isIdlePrompt(screenRows: screenRows) { return .idle }
        return .unknown
    }

    /// Whether any row carries Antigravity's in-turn spinner line.
    public static func isBusy(screenRows: [String]) -> Bool {
        screenRows.contains { busyLine.matches($0) }
    }

    /// Whether the tail of the screen shows an empty prompt followed by the
    /// shortcuts hint — Antigravity's "waiting for you" shape.
    ///
    /// A busy screen is never idle, even if a stale prompt row is still in the
    /// scrollback: the spinner is the stronger signal.
    public static func isIdlePrompt(screenRows: [String]) -> Bool {
        if isBusy(screenRows: screenRows) { return false }
        let tail = screenRows
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(tailRowsInspected)
        let rows = Array(tail)
        for (index, row) in rows.enumerated() where emptyPromptLine.matches(row) {
            if rows[(index + 1)...].contains(where: { shortcutsLine.matches($0) }) {
                return true
            }
        }
        return false
    }

    /// How far up from the bottom the idle-prompt shape is looked for. Matches
    /// Agent Studio's window; large enough to survive a status line or two
    /// below the prompt, small enough that scrollback can't produce a match.
    private static let tailRowsInspected = 6

    /// `⠿ Working…` / `* Loading` — an optional braille/bullet spinner glyph,
    /// then the status word.
    private static let busyLine = ScreenLinePattern(
        #"^\s*(?:[⠀-⣿✦✧*•-]\s+)?(?:Working|Loading)(?:\b|[.…]).*$"#
    )
    /// A prompt row with nothing typed into it.
    private static let emptyPromptLine = ScreenLinePattern(#"^\s*>\s*$"#)
    /// The `? for shortcuts` hint Antigravity parks under an idle prompt.
    private static let shortcutsLine = ScreenLinePattern(#"^\s*\?\s+for shortcuts\b"#)
}

/// A case-insensitive whole-line regex, compiled once.
private struct ScreenLinePattern: Sendable {
    private let regex: NSRegularExpression?

    init(_ pattern: String) {
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    func matches(_ line: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }
}
