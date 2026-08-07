import Foundation

/// The static safety layer that runs before Pilot Mode's judge.
///
/// Guardrails are absolute. A ``Outcome/blocked(rule:)`` result is not advice
/// the judge may weigh against the user's instructions — it ends the evaluation
/// and the human answers. User instructions can only make Pilot Mode *more*
/// cautious (by pushing a would-be approval to the judge or to the human);
/// nothing in `~/.config/cmux/cmux.json` can unblock a guardrail.
public struct PilotModeGuardrails: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Never auto-answer; `rule` names the guardrail for the audit trail.
        case blocked(rule: String)
        /// Observes without mutating; answerable without spending a judge call.
        case readOnly
        /// Send to the judge with the user's instructions.
        case judge
    }

    /// Extra deny substrings from `automation.pilotMode.denyPatterns`. These
    /// only ever add blocks; they cannot remove built-in ones.
    private let extraDenyPatterns: [String]

    public init(extraDenyPatterns: [String] = []) {
        self.extraDenyPatterns = extraDenyPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Paths whose contents are secret or whose modification escapes the
    /// workspace. Matched against a lowercased path.
    private static let protectedPathFragments: [(fragment: String, rule: String)] = [
        ("/.ssh/", "ssh-credentials"),
        ("/.aws/", "cloud-credentials"),
        ("/.gnupg/", "gpg-credentials"),
        ("/.kube/", "cluster-credentials"),
        ("/.docker/config", "registry-credentials"),
        ("/.netrc", "stored-credentials"),
        ("/.git-credentials", "stored-credentials"),
        ("/etc/", "system-file"),
        ("/system/", "system-file"),
        ("/library/keychains/", "keychain-file"),
        ("id_rsa", "ssh-credentials"),
        ("id_ed25519", "ssh-credentials"),
        (".pem", "private-key"),
        (".p12", "private-key"),
        (".keystore", "private-key"),
    ]

    public func evaluate(toolName: String, toolInputJSON: String) -> Outcome {
        let input = PilotModeToolInput.parse(toolInputJSON: toolInputJSON)
        let haystack = "\(toolName) \(input.summary)".lowercased()
        for pattern in extraDenyPatterns where haystack.contains(pattern) {
            return .blocked(rule: "user-deny-pattern")
        }

        switch PilotModeToolClassification.classify(toolName: toolName) {
        case .readOnly:
            // A read tool still reaches secrets if pointed at one.
            if let path = input.path, let rule = protectedPathRule(path) {
                return .blocked(rule: rule)
            }
            return .readOnly

        case .shell:
            guard let command = input.command, !command.isEmpty else {
                // A shell tool whose command we could not read is the one case
                // where we know the least and risk the most.
                return .judge
            }
            return Self.outcome(for: PilotModeShellCommandScan.scan(command: command))

        case .write:
            if let path = input.path, let rule = protectedPathRule(path) {
                return .blocked(rule: rule)
            }
            return .judge

        case .network, .unknown:
            return .judge
        }
    }

    private func protectedPathRule(_ path: String) -> String? {
        let lowered = path.lowercased()
        for entry in Self.protectedPathFragments where lowered.contains(entry.fragment) {
            return entry.rule
        }
        // `.env` needs the same template-aware matching the shell scanner uses.
        if lowered.hasSuffix("/.env") || lowered == ".env" || lowered.hasSuffix("/.env.local") {
            return "environment-secrets"
        }
        return nil
    }

    private static func outcome(for scan: PilotModeShellCommandScan.Result) -> Outcome {
        switch scan {
        case .blocked(let rule): return .blocked(rule: rule)
        case .readOnly: return .readOnly
        case .judge: return .judge
        }
    }
}
