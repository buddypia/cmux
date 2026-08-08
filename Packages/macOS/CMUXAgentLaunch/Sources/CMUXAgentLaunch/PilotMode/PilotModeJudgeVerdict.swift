import Foundation

/// The judge's own answer, parsed out of its raw text.
public struct PilotModeJudgeVerdict: Sendable, Equatable {
    public enum Call: String, Sendable, Equatable {
        case approve
        case deny
        case escalate
        case answer
    }

    public let call: Call
    /// Absent or unparseable confidence reads as `0`, which fails the
    /// evaluator's threshold and escalates. A judge that cannot state its
    /// confidence has not earned an automatic decision.
    public let confidence: Double
    public let reason: String
    public let selections: [String]

    public init(call: Call, confidence: Double, reason: String, selections: [String] = []) {
        self.call = call
        self.confidence = confidence
        self.reason = reason
        self.selections = selections
    }
}

/// Parses judge output into a ``PilotModeJudgeVerdict``.
///
/// Real CLIs wrap JSON in code fences, prefix it with a sentence, or trail it
/// with a summary, so the parser scans for the first balanced JSON object
/// rather than requiring the whole output to be JSON. Anything it cannot read
/// returns `nil`, which the evaluator turns into an escalation.
/// lint:allow namespace-type — stateless parser.
public enum PilotModeJudgeParser {
    public static func parse(_ text: String) -> PilotModeJudgeVerdict? {
        guard let json = firstJSONObject(in: text),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let rawDecision = (object["decision"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            let call = PilotModeJudgeVerdict.Call(rawValue: rawDecision) else {
            return nil
        }
        let confidence: Double = {
            if let value = object["confidence"] as? Double { return value }
            if let value = object["confidence"] as? Int { return Double(value) }
            if let value = object["confidence"] as? String { return Double(value) ?? 0 }
            return 0
        }()
        let selections: [String] = {
            guard let raw = object["selections"] as? [Any] else { return [] }
            return raw.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }()
        return PilotModeJudgeVerdict(
            call: call,
            confidence: min(max(confidence, 0), 1),
            reason: (object["reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            selections: selections
        )
    }

    /// Returns the first brace-balanced object in `text`, ignoring braces that
    /// appear inside JSON string literals.
    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" && inString {
                isEscaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
