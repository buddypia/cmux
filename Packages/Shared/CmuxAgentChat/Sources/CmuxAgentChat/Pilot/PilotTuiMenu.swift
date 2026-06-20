import Foundation

/// A `surface.send_key` token that can be sent to a terminal-backed agent UI.
public enum PilotTuiKey: String, Sendable, Equatable, Codable, CaseIterable {
    case up
    case down
    case left
    case right
    case enter
    case escape
    case tab
    case backspace
    case digit0 = "0"
    case digit1 = "1"
    case digit2 = "2"
    case digit3 = "3"
    case digit4 = "4"
    case digit5 = "5"
    case digit6 = "6"
    case digit7 = "7"
    case digit8 = "8"
    case digit9 = "9"
}

/// Options for reading trailing visible text from a terminal surface.
public struct PilotTuiSurfaceReadOptions: Sendable, Equatable {
    /// Number of trailing screen lines to read.
    public let lines: Int

    public init(lines: Int) {
        self.lines = lines
    }
}

/// A user-visible notification emitted while Pilot Mode is running.
public struct PilotTuiSurfaceNotification: Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Backend-neutral surface operations required by a Pilot TUI decision loop.
public protocol PilotTuiSurfaceDriving: Sendable {
    /// Reads a terminal screen snapshot.
    func readScreen(options: PilotTuiSurfaceReadOptions) async throws -> String

    /// Sends one canonical key token.
    func sendKey(_ key: PilotTuiKey) async throws

    /// Sends arbitrary text to the surface.
    func sendText(_ text: String) async throws

    /// Emits a user-visible Pilot notification.
    func notify(_ notification: PilotTuiSurfaceNotification) async throws
}

/// A numbered option rendered by a terminal selection menu.
public struct PilotTuiOption: Sendable, Equatable {
    /// The 1-based number shown by the TUI.
    public let number: Int

    /// The first-line option label after the `N. ` prefix.
    public let label: String

    /// Whether this is the free-form text entry, which must not be auto-selected.
    public let isFreeText: Bool

    /// Whether this is the conversational escape entry, which must not be auto-selected.
    public let isEscape: Bool

    /// Whether Pilot may safely auto-select this option.
    public var isAutoSelectable: Bool {
        !isFreeText && !isEscape
    }

    public init(number: Int, label: String, isFreeText: Bool = false, isEscape: Bool = false) {
        self.number = number
        self.label = label
        self.isFreeText = isFreeText
        self.isEscape = isEscape
    }
}

/// A parsed interactive TUI menu from a terminal screen snapshot.
public struct PilotTuiMenu: Sendable, Equatable {
    /// The nearest non-empty question line above the options.
    public let question: String

    /// Numbered menu options in display order.
    public let options: [PilotTuiOption]

    /// The 0-based option index where the cursor currently sits.
    public let cursorIndex: Int

    /// Whether a multi-step submit bar is visible near this menu.
    public let hasSubmitBar: Bool

    public init(
        question: String,
        options: [PilotTuiOption],
        cursorIndex: Int,
        hasSubmitBar: Bool
    ) {
        self.question = question
        self.options = options
        self.cursorIndex = cursorIndex
        self.hasSubmitBar = hasSubmitBar
    }
}

/// Progress information from a multi-select submit bar.
public struct PilotTuiSubmitBar: Sendable, Equatable {
    /// The raw submit-bar line.
    public let line: String

    /// Number of unchecked step markers.
    public let uncheckedCount: Int

    /// Number of step markers, including the submit marker.
    public let stepMarkerCount: Int

    /// True when at least one step and Submit are present, and no step is unchecked.
    public let isReadyToSubmit: Bool

    public init(
        line: String,
        uncheckedCount: Int,
        stepMarkerCount: Int,
        isReadyToSubmit: Bool
    ) {
        self.line = line
        self.uncheckedCount = uncheckedCount
        self.stepMarkerCount = stepMarkerCount
        self.isReadyToSubmit = isReadyToSubmit
    }
}

/// The safe key plan for handling a parsed TUI menu.
public enum PilotTuiPlan: Sendable, Equatable {
    /// Move to the target option and confirm.
    case select(keys: [PilotTuiKey], targetNumber: Int)

    /// Press Escape instead of guessing when confidence is too low.
    case escape(keys: [PilotTuiKey], reason: String)

    /// Do not send keys because the target is missing or unsafe.
    case skip(reason: String)
}
