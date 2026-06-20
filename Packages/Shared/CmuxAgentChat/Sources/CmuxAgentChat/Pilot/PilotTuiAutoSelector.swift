import Foundation

/// Inputs for one Pilot TUI auto-selection attempt.
public struct PilotTuiAutoSelectRequest: Sendable, Equatable {
    /// Target option number chosen by the caller, when a menu option should be selected.
    public let targetNumber: Int?

    /// Confidence for the target option choice.
    public let confidence: Double

    /// Minimum confidence required before selecting an option.
    public let requiredConfidence: Double

    /// Number of trailing terminal lines to read.
    public let readLines: Int

    /// Whether a ready submit bar may be confirmed even without a target option.
    public let submitIfReady: Bool

    public init(
        targetNumber: Int?,
        confidence: Double,
        requiredConfidence: Double = 0.7,
        readLines: Int = 120,
        submitIfReady: Bool = true
    ) {
        self.targetNumber = targetNumber
        self.confidence = confidence
        self.requiredConfidence = requiredConfidence
        self.readLines = readLines
        self.submitIfReady = submitIfReady
    }
}

/// Outcome of one Pilot TUI auto-selection attempt.
public enum PilotTuiAutoSelectResult: Sendable, Equatable {
    /// A ready submit bar was confirmed.
    case submitted(keys: [PilotTuiKey])

    /// A menu option was selected.
    case selected(targetNumber: Int, keys: [PilotTuiKey])

    /// Escape was pressed instead of guessing.
    case escaped(keys: [PilotTuiKey], reason: String)

    /// No keys were sent.
    case skipped(reason: String)
}

/// Runs one screen-read / parse / safe-key-send cycle for Pilot TUI menus.
public enum PilotTuiAutoSelector {
    public static func run(
        driver: any PilotTuiSurfaceDriving,
        request: PilotTuiAutoSelectRequest
    ) async throws -> PilotTuiAutoSelectResult {
        let screen = try await driver.readScreen(
            options: PilotTuiSurfaceReadOptions(lines: request.readLines)
        )

        if request.submitIfReady,
           let submitBar = PilotTuiMenuParser.parseSubmitBar(screen: screen),
           submitBar.isReadyToSubmit {
            let keys = PilotTuiMenuParser.keysToSubmit()
            try await send(keys: keys, driver: driver)
            return .submitted(keys: keys)
        }

        guard let menu = PilotTuiMenuParser.parseMenu(screen: screen) else {
            return .skipped(reason: "no Pilot TUI menu detected")
        }
        guard let targetNumber = request.targetNumber else {
            return .skipped(reason: "target option not provided")
        }

        switch PilotTuiMenuParser.planSelection(
            menu: menu,
            targetNumber: targetNumber,
            confidence: request.confidence,
            requiredConfidence: request.requiredConfidence
        ) {
        case .select(let keys, let targetNumber):
            try await send(keys: keys, driver: driver)
            return .selected(targetNumber: targetNumber, keys: keys)
        case .escape(let keys, let reason):
            try await send(keys: keys, driver: driver)
            return .escaped(keys: keys, reason: reason)
        case .skip(let reason):
            return .skipped(reason: reason)
        }
    }

    private static func send(
        keys: [PilotTuiKey],
        driver: any PilotTuiSurfaceDriving
    ) async throws {
        for key in keys {
            try await driver.sendKey(key)
        }
    }
}
