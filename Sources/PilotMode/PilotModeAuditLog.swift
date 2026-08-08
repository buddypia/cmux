import CMUXAgentLaunch
import Foundation

/// Append-only record of every verdict Pilot Mode reached, at
/// `~/.cmuxterm/pilot-mode.jsonl`.
///
/// This is the point of shadow mode. Because shadow and active runs evaluate
/// identically, a shadow log paired with the user's real decisions in
/// `workstream.jsonl` answers "how often would Pilot Mode have been right?"
/// before anything is delegated. `applied` distinguishes a verdict that was
/// actually sent from one that was only recorded.
struct PilotModeAuditLog: Sendable {
    struct Entry: Codable, Sendable {
        let timestamp: Date
        let requestId: String
        let workspaceId: String?
        let surfaceId: String?
        let agent: String
        let runMode: String
        let kind: String
        let toolName: String?
        /// `decide` or `escalate`.
        let outcome: String
        /// Permission mode or selections, when the verdict was a decision.
        let decision: String?
        /// Escalation reason, when the verdict was an escalation.
        let escalation: String?
        /// `guardrail`, `readOnlyFastPath`, or `judge`.
        let source: String
        let rationale: String
        /// Whether the verdict was actually delivered to the agent. False in
        /// shadow mode, and false in active mode when the user answered first.
        let applied: Bool
        let evaluationSeconds: Double
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "cmux.pilot.audit", qos: .utility)

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("pilot-mode.jsonl", isDirectory: false)
    }

    func append(_ entry: Entry) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)

            let directory = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// Renders a verdict into the flat fields the log stores.
    static func describe(
        _ evaluation: PilotModeEvaluation
    ) -> (outcome: String, decision: String?, escalation: String?, rationale: String) {
        switch evaluation.verdict {
        case .decide(let decision, let rationale):
            return ("decide", describe(decision), nil, rationale)
        case .escalate(let reason):
            return ("escalate", nil, describe(reason), "")
        }
    }

    static func describe(_ decision: WorkstreamDecision) -> String {
        switch decision {
        case .permission(let mode): return "permission:\(mode.rawValue)"
        case .question(let selections): return "question:\(selections.joined(separator: "|"))"
        case .exitPlan(let mode, _): return "exitPlan:\(mode.rawValue)"
        }
    }

    static func describe(_ escalation: PilotModeEscalation) -> String {
        switch escalation {
        case .guardrail(let rule): return "guardrail:\(rule)"
        case .unsupportedKind: return "unsupportedKind"
        case .judgeDeclined: return "judgeDeclined"
        case .lowConfidence(let confidence): return "lowConfidence:\(confidence)"
        case .unparseableJudgeOutput: return "unparseableJudgeOutput"
        case .judgeUnavailable: return "judgeUnavailable"
        case .judgeTimedOut: return "judgeTimedOut"
        case .rateLimited: return "rateLimited"
        case .disabled: return "disabled"
        }
    }
}
