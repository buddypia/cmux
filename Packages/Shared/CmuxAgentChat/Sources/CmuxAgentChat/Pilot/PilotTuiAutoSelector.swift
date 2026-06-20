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

/// Caller-provided decision for one detected Pilot TUI menu.
public struct PilotTuiDecision: Sendable, Equatable {
    /// The rendered option number to choose.
    public let optionNumber: Int

    /// Confidence for this choice.
    public let confidence: Double

    /// Human-readable audit reason.
    public let reason: String

    public init(optionNumber: Int, confidence: Double, reason: String) {
        self.optionNumber = optionNumber
        self.confidence = confidence
        self.reason = reason
    }
}

/// Inputs for a multi-step Pilot TUI auto-selection loop.
public struct PilotTuiAutoSelectLoopRequest: Sendable, Equatable {
    /// Minimum confidence required before selecting an option.
    public let requiredConfidence: Double

    /// Number of trailing terminal lines to read per iteration.
    public let readLines: Int

    /// Maximum number of menu selections before stopping a stale submit-bar flow.
    public let maxMenuActions: Int

    /// Delay after a submit-bar step selection so the TUI can render the next step.
    public let settleDelayNanoseconds: UInt64

    public init(
        requiredConfidence: Double = 0.7,
        readLines: Int = 120,
        maxMenuActions: Int = 6,
        settleDelayNanoseconds: UInt64 = 120_000_000
    ) {
        self.requiredConfidence = requiredConfidence
        self.readLines = readLines
        self.maxMenuActions = maxMenuActions
        self.settleDelayNanoseconds = settleDelayNanoseconds
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

/// Outcome of a multi-step Pilot TUI auto-selection loop.
public enum PilotTuiAutoSelectLoopResult: Sendable, Equatable {
    /// No interactive menu was detected before any action was sent.
    case noMenu

    /// A non-submit-bar menu option was selected.
    case selected(targetNumber: Int, keys: [PilotTuiKey], optionNumbers: [Int])

    /// A submit-bar flow reached Submit and was confirmed.
    case submitted(keys: [PilotTuiKey], optionNumbers: [Int])

    /// Escape was pressed instead of guessing.
    case escaped(keys: [PilotTuiKey], reason: String)

    /// The loop stopped without sending more keys.
    case skipped(reason: String, keys: [PilotTuiKey], optionNumbers: [Int])
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

    /// Runs a multi-step Pilot TUI flow until a plain selection, Submit, Escape, or safety stop.
    public static func runLoop(
        driver: any PilotTuiSurfaceDriving,
        request: PilotTuiAutoSelectLoopRequest = PilotTuiAutoSelectLoopRequest(),
        decide: @Sendable (String, PilotTuiMenu) async throws -> PilotTuiDecision,
        sleep: (@Sendable (UInt64) async throws -> Void)? = nil
    ) async throws -> PilotTuiAutoSelectLoopResult {
        var keysSent: [PilotTuiKey] = []
        var optionNumbers: [Int] = []

        while true {
            let screen = try await driver.readScreen(
                options: PilotTuiSurfaceReadOptions(lines: request.readLines)
            )

            if let submitBar = PilotTuiMenuParser.parseSubmitBar(screen: screen),
               submitBar.isReadyToSubmit {
                let keys = PilotTuiMenuParser.keysToSubmit()
                try await send(keys: keys, driver: driver)
                keysSent.append(contentsOf: keys)
                return .submitted(keys: keysSent, optionNumbers: optionNumbers)
            }

            guard let menu = PilotTuiMenuParser.parseMenu(screen: screen) else {
                guard let lastOption = optionNumbers.last else {
                    return .noMenu
                }
                return .selected(
                    targetNumber: lastOption,
                    keys: keysSent,
                    optionNumbers: optionNumbers
                )
            }

            guard optionNumbers.count < request.maxMenuActions else {
                return .skipped(
                    reason: "submit-bar action limit \(request.maxMenuActions) reached",
                    keys: keysSent,
                    optionNumbers: optionNumbers
                )
            }

            let decision = try await decide(screen, menu)
            switch PilotTuiMenuParser.planSelection(
                menu: menu,
                targetNumber: decision.optionNumber,
                confidence: decision.confidence,
                requiredConfidence: request.requiredConfidence
            ) {
            case .select(let keys, let targetNumber):
                try await send(keys: keys, driver: driver)
                keysSent.append(contentsOf: keys)
                optionNumbers.append(targetNumber)
                guard menu.hasSubmitBar else {
                    return .selected(
                        targetNumber: targetNumber,
                        keys: keysSent,
                        optionNumbers: optionNumbers
                    )
                }
                if request.settleDelayNanoseconds > 0 {
                    try await (sleep ?? defaultSleep)(request.settleDelayNanoseconds)
                }
            case .escape(let keys, let reason):
                try await send(keys: keys, driver: driver)
                keysSent.append(contentsOf: keys)
                return .escaped(keys: keysSent, reason: reason)
            case .skip(let reason):
                return .skipped(reason: reason, keys: keysSent, optionNumbers: optionNumbers)
            }
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

    private static func defaultSleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
