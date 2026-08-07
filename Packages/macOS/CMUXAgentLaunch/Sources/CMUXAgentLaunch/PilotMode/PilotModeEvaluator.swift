import Foundation

/// A verdict plus how it was reached.
public struct PilotModeEvaluation: Sendable, Equatable {
    public let verdict: PilotModeVerdict
    public let source: PilotModeVerdictSource

    public init(verdict: PilotModeVerdict, source: PilotModeVerdictSource) {
        self.verdict = verdict
        self.source = source
    }
}

/// Turns a pending Feed item into a Pilot Mode verdict.
///
/// The evaluator is pure with respect to everything except the injected judge,
/// and it produces the same verdict in shadow and active mode — the run mode
/// only decides whether the caller replays the verdict. That equivalence is
/// what makes a shadow run a truthful rehearsal.
public struct PilotModeEvaluator: Sendable {
    /// Below this, an answer is treated as no answer. Set high on purpose: the
    /// cost of escalating is one click.
    public static let minimumConfidence = 0.7

    private let settings: PilotModeSettings
    private let guardrails: PilotModeGuardrails
    private let judge: PilotModeJudge

    public init(settings: PilotModeSettings, judge: PilotModeJudge) {
        let normalized = settings.normalized()
        self.settings = normalized
        self.guardrails = PilotModeGuardrails(extraDenyPatterns: normalized.denyPatterns)
        self.judge = judge
    }

    public func evaluate(
        payload: WorkstreamPayload,
        context: PilotModeJudgeContext
    ) async -> PilotModeEvaluation {
        guard settings.isEnabled else {
            return .init(verdict: .escalate(.disabled), source: .guardrail)
        }
        switch payload {
        case .permissionRequest(_, let toolName, let toolInputJSON, _):
            return await evaluatePermission(
                toolName: toolName,
                toolInputJSON: toolInputJSON,
                context: context
            )
        case .question(_, let questions):
            return await evaluateQuestion(questions: questions, context: context)
        default:
            // `.exitPlan` deliberately included: plan review is the user's
            // single highest-leverage checkpoint, so Pilot Mode never spends it.
            return .init(verdict: .escalate(.unsupportedKind), source: .guardrail)
        }
    }

    private func evaluatePermission(
        toolName: String,
        toolInputJSON: String,
        context: PilotModeJudgeContext
    ) async -> PilotModeEvaluation {
        guard settings.answersPermissionRequests else {
            return .init(verdict: .escalate(.disabled), source: .guardrail)
        }
        switch guardrails.evaluate(toolName: toolName, toolInputJSON: toolInputJSON) {
        case .blocked(let rule):
            return .init(verdict: .escalate(.guardrail(rule: rule)), source: .guardrail)
        case .readOnly where settings.autoAllowsReadOnly:
            return .init(
                verdict: .decide(
                    .permission(.once),
                    rationale: "Read-only tool call approved without a judge call."
                ),
                source: .readOnlyFastPath
            )
        case .readOnly, .judge:
            break
        }

        let input = PilotModeToolInput.parse(toolInputJSON: toolInputJSON)
        let prompt = PilotModePrompt.permissionPrompt(
            toolName: toolName,
            toolInput: input,
            instructions: settings.instructions,
            context: context
        )
        let verdict = await runJudge(prompt: prompt, context: context)
        switch verdict {
        case .failure(let escalation):
            return .init(verdict: .escalate(escalation), source: .judge)
        case .success(let judged):
            switch judged.call {
            case .approve:
                // Always `.once`, never `.always`/`.all`/`.bypass`. A persistent
                // grant would remove the request from both Pilot Mode's and the
                // user's view for every future call, converting one automatic
                // decision into an unbounded number of unreviewed ones.
                return .init(
                    verdict: .decide(.permission(.once), rationale: judged.reason),
                    source: .judge
                )
            case .deny:
                return .init(
                    verdict: .decide(.permission(.deny), rationale: judged.reason),
                    source: .judge
                )
            case .escalate:
                return .init(
                    verdict: .escalate(.judgeDeclined(reason: judged.reason)),
                    source: .judge
                )
            case .answer:
                return .init(verdict: .escalate(.unparseableJudgeOutput), source: .judge)
            }
        }
    }

    private func evaluateQuestion(
        questions: [WorkstreamQuestionPrompt],
        context: PilotModeJudgeContext
    ) async -> PilotModeEvaluation {
        guard settings.answersQuestions else {
            return .init(verdict: .escalate(.disabled), source: .guardrail)
        }
        guard !questions.isEmpty, questions.contains(where: { !$0.options.isEmpty }) else {
            return .init(verdict: .escalate(.unsupportedKind), source: .guardrail)
        }
        let prompt = PilotModePrompt.questionPrompt(
            questions: questions,
            instructions: settings.instructions,
            context: context
        )
        switch await runJudge(prompt: prompt, context: context) {
        case .failure(let escalation):
            return .init(verdict: .escalate(escalation), source: .judge)
        case .success(let judged):
            guard judged.call == .answer else {
                if judged.call == .escalate {
                    return .init(
                        verdict: .escalate(.judgeDeclined(reason: judged.reason)),
                        source: .judge
                    )
                }
                return .init(verdict: .escalate(.unparseableJudgeOutput), source: .judge)
            }
            guard let selections = Self.validate(
                selections: judged.selections,
                against: questions
            ) else {
                return .init(verdict: .escalate(.unparseableJudgeOutput), source: .judge)
            }
            return .init(
                verdict: .decide(.question(selections: selections), rationale: judged.reason),
                source: .judge
            )
        }
    }

    /// Accepts only selections that exactly match offered option labels, and
    /// only as many as each question allows. A judge that invents an option, or
    /// picks two where one was asked for, is treated as unparseable rather than
    /// silently coerced.
    static func validate(
        selections: [String],
        against questions: [WorkstreamQuestionPrompt]
    ) -> [String]? {
        guard !selections.isEmpty else { return nil }
        let offered = Set(questions.flatMap { $0.options.map(\.label) })
        guard selections.allSatisfy({ offered.contains($0) }) else { return nil }
        guard Set(selections).count == selections.count else { return nil }

        let allowsMultiple = questions.contains { $0.multiSelect }
        if !allowsMultiple && selections.count > questions.count {
            return nil
        }
        // Single-select questions must not receive two labels from the same
        // question.
        for question in questions where !question.multiSelect {
            let labels = Set(question.options.map(\.label))
            if selections.filter({ labels.contains($0) }).count > 1 { return nil }
        }
        return selections
    }

    private enum JudgeResult {
        case success(PilotModeJudgeVerdict)
        case failure(PilotModeEscalation)
    }

    private func runJudge(
        prompt: String,
        context: PilotModeJudgeContext
    ) async -> JudgeResult {
        let outcome = await judge.evaluate(
            prompt: prompt,
            timeout: settings.judgeTimeout,
            context: context
        )
        switch outcome {
        case .unavailable:
            return .failure(.judgeUnavailable)
        case .timedOut:
            return .failure(.judgeTimedOut)
        case .text(let text):
            guard let parsed = PilotModeJudgeParser.parse(text) else {
                return .failure(.unparseableJudgeOutput)
            }
            // An explicit escalation is honored at any confidence; only
            // affirmative answers must clear the bar.
            if parsed.call != .escalate, parsed.confidence < Self.minimumConfidence {
                return .failure(.lowConfidence(confidence: parsed.confidence))
            }
            return .success(parsed)
        }
    }
}
