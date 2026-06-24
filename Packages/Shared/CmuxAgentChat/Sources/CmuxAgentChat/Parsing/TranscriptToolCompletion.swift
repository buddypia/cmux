import Foundation

/// A tool result observed in the transcript, applied to the pending
/// running-state message that the matching tool invocation produced.
struct TranscriptToolCompletion: Sendable {
    /// The result text, already extracted from the transcript shape.
    let output: String?

    /// Whether the transcript flagged the result as an error.
    let isError: Bool

    /// The exit code, when one was parseable from the result.
    let exitCode: Int?

    /// Wall-clock duration in seconds, when one was parseable.
    let durationSeconds: Double?

    /// Timestamp of the result row that completed the tool, when known.
    let timestamp: Date?

    /// Permission decision, when a transcript result resolves an actionable
    /// permission card instead of a normal tool invocation.
    let permissionResolution: ChatPermissionRequest.Resolution?

    /// Question settlement, when a transcript lifecycle event closes an
    /// unanswered question card.
    let questionResolution: ChatQuestion.Resolution?

    /// Whether a terminal output row reports a still-running process.
    let terminalIsRunning: Bool

    /// Creates a completion.
    ///
    /// - Parameters:
    ///   - output: The extracted result text.
    ///   - isError: Whether the result was flagged as an error.
    ///   - exitCode: The parsed exit code, when available.
    ///   - durationSeconds: The parsed duration, when available.
    init(
        output: String?,
        isError: Bool,
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        timestamp: Date? = nil,
        permissionResolution: ChatPermissionRequest.Resolution? = nil,
        questionResolution: ChatQuestion.Resolution? = nil,
        terminalIsRunning: Bool = false
    ) {
        self.output = output
        self.isError = isError
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.timestamp = timestamp
        self.permissionResolution = permissionResolution
        self.questionResolution = questionResolution
        self.terminalIsRunning = terminalIsRunning
    }

    /// Produces the completed copy of a pending tool message.
    ///
    /// - Parameters:
    ///   - message: The pending message in its running form.
    ///   - budget: The text budget for stored output.
    /// - Returns: The completed message, or `nil` when the result does not
    ///   change how the message renders (file edits, unanswered questions).
    func applied(to message: ChatMessage, budget: TranscriptTextBudget) -> ChatMessage? {
        switch message.kind {
        case .terminal(let capture):
            let completed = ChatTerminalCapture(
                command: capture.command,
                output: output.map { budget.body($0) },
                exitCode: terminalIsRunning ? exitCode : exitCode ?? (isError ? 1 : 0),
                durationSeconds: durationSeconds,
                isRunning: terminalIsRunning
            )
            return message.replacingKind(.terminal(completed), timestamp: timestamp)
        case .toolUse(let toolUse):
            let failed = isError || (exitCode ?? 0) != 0
            let completed = ChatToolUse(
                toolName: toolUse.toolName,
                summary: toolUse.summary,
                inputDetail: toolUse.inputDetail,
                output: output.map { budget.body($0) },
                status: failed ? .failed : .succeeded
            )
            return message.replacingKind(.toolUse(completed), timestamp: timestamp)
        case .question(let question):
            guard let answer = answer(forPrompt: question.prompt) else {
                guard let questionResolution else { return nil }
                let resolved = ChatQuestion(
                    prompt: question.prompt,
                    options: question.options,
                    resolution: questionResolution
                )
                return message.replacingKind(.question(resolved), timestamp: timestamp)
            }
            let answered = ChatQuestion(
                prompt: question.prompt,
                options: question.options,
                selectedOptionLabel: answer
            )
            return message.replacingKind(.question(answered), timestamp: timestamp)
        case .permissionRequest(let request):
            guard let permissionResolution else { return nil }
            let resolved = ChatPermissionRequest(
                title: request.title,
                subject: request.subject,
                resolution: permissionResolution
            )
            return message.replacingKind(.permissionRequest(resolved), timestamp: timestamp)
        default:
            return nil
        }
    }

    /// Extracts the chosen answer for a question prompt from completion text.
    ///
    /// - Parameter prompt: The question prompt to look up.
    /// - Returns: The answer text, or `nil` when not extractable.
    private func answer(forPrompt prompt: String) -> String? {
        guard let output else { return nil }
        if let proseAnswer = Self.proseAnswer(forPrompt: prompt, in: output) {
            return proseAnswer
        }

        guard let json = Self.jsonValue(fromText: output) else { return nil }
        return Self.jsonAnswer(forPrompt: prompt, in: json)
    }

    /// Extracts the chosen answer from the
    /// `Your questions have been answered: "Q"="A"...` result text.
    private static func proseAnswer(forPrompt prompt: String, in output: String) -> String? {
        let needle = "\"\(prompt)\"=\""
        guard let start = output.range(of: needle) else { return nil }
        let tail = output[start.upperBound...]
        guard let end = tail.range(of: "\"") else { return nil }
        let answer = String(tail[..<end.lowerBound])
        return Self.nonEmpty(answer)
    }

    private static func jsonAnswer(forPrompt prompt: String, in value: TranscriptJSONValue) -> String? {
        if let object = value.object {
            if promptsMatch(object, prompt), let answer = answerString(in: object) {
                return answer
            }

            for mappingKey in mappingKeys {
                guard let mapped = object[mappingKey] else { continue }
                if let mappedObject = mapped.object {
                    for (mappedPrompt, answerValue) in mappedObject where promptsMatch(mappedPrompt, prompt) {
                        if let answer = answerString(from: answerValue) {
                            return answer
                        }
                    }
                }
                if let answer = jsonAnswer(forPrompt: prompt, in: mapped) {
                    return answer
                }
            }

            for (mappedPrompt, answerValue) in object where promptsMatch(mappedPrompt, prompt) {
                if let answer = answerString(from: answerValue) {
                    return answer
                }
            }

            for nestedKey in nestedKeys {
                guard let nested = object[nestedKey],
                      let answer = jsonAnswer(forPrompt: prompt, in: nested)
                else { continue }
                return answer
            }
        }

        if let array = value.array {
            for item in array {
                if let answer = jsonAnswer(forPrompt: prompt, in: item) {
                    return answer
                }
            }
        }

        if let string = value.string {
            if let answer = proseAnswer(forPrompt: prompt, in: string) {
                return answer
            }
            if let nested = jsonValue(fromText: string) {
                return jsonAnswer(forPrompt: prompt, in: nested)
            }
        }

        return nil
    }

    private static func answerString(in object: [String: TranscriptJSONValue]) -> String? {
        for key in answerKeys {
            guard let value = object[key], let answer = answerString(from: value) else { continue }
            return answer
        }
        return nil
    }

    private static func answerString(from value: TranscriptJSONValue) -> String? {
        if let string = value.string {
            return nonEmpty(string)
        }

        if value.double != nil || value.bool != nil {
            return nonEmpty(value.compactJSONString())
        }

        if let array = value.array {
            let answers = array.compactMap(answerString(from:))
            guard !answers.isEmpty else { return nil }
            return answers.joined(separator: ", ")
        }

        if let object = value.object {
            return answerString(in: object)
        }

        return nil
    }

    private static func promptsMatch(_ object: [String: TranscriptJSONValue], _ prompt: String) -> Bool {
        for key in promptKeys {
            guard let candidate = object[key]?.string, promptsMatch(candidate, prompt) else { continue }
            return true
        }
        return false
    }

    private static func promptsMatch(_ candidate: String, _ prompt: String) -> Bool {
        nonEmpty(candidate) == nonEmpty(prompt)
    }

    private static func jsonValue(fromText text: String) -> TranscriptJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        return TranscriptJSONValue(jsonString: trimmed)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let promptKeys = ["question", "prompt", "header"]
    private static let answerKeys = [
        "answer",
        "response",
        "selected",
        "selection",
        "selectedOption",
        "selected_option",
        "selectedOptionLabel",
        "selected_option_label",
        "value",
        "label",
        "title",
    ]
    private static let mappingKeys = [
        "answers",
        "responses",
        "selections",
        "selectedOptions",
        "selected_options",
        "questions",
        "results",
    ]
    private static let nestedKeys = ["output", "result", "data", "payload", "response", "functionResponse"]
}

extension ChatMessage {
    /// Copies the message with a different payload, keeping identity,
    /// position and author, optionally replacing the timestamp.
    ///
    /// - Parameter kind: The replacement payload.
    /// - Returns: The copied message.
    func replacingKind(_ kind: ChatMessageKind, timestamp replacementTimestamp: Date? = nil) -> ChatMessage {
        ChatMessage(id: id, seq: seq, role: role, timestamp: replacementTimestamp ?? timestamp, kind: kind)
    }
}
