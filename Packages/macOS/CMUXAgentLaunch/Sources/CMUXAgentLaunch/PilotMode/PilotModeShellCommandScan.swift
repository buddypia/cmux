import Foundation

/// Static analysis of a proposed shell command, used as Pilot Mode's absolute
/// safety valve.
///
/// This runs *before* the judge and its `blocked` result cannot be overturned
/// by user instructions or by judge output. The asymmetry is deliberate: a
/// wrongly-escalated command costs one click, while a wrongly-approved `git
/// push --force` or `rm -rf` cannot be taken back.
///
/// The scanner is intentionally crude and biased toward escalation. It splits
/// on shell metacharacters without honoring quoting, so a separator inside a
/// string literal over-splits the command. That direction is safe: it can only
/// surface more command heads for inspection, never fewer. `echo "rm -rf /"` is
/// escalated even though it is harmless, and that is the trade this scanner
/// accepts.
/// lint:allow namespace-type — stateless command-inspection table.
public enum PilotModeShellCommandScan {
    public enum Result: Sendable, Equatable {
        /// Never auto-answer. `rule` is the audit-trail label.
        case blocked(rule: String)
        /// Every segment observes without mutating; safe to answer without the
        /// judge.
        case readOnly
        /// Not obviously dangerous and not obviously inert; let the judge and
        /// the user's instructions decide.
        case judge
    }

    /// Substrings that condemn a command wherever they appear. Matched against
    /// the whitespace-collapsed, lowercased command.
    private static let dangerousSubstrings: [(pattern: String, rule: String)] = [
        ("| sh", "pipe-to-shell"),
        ("| bash", "pipe-to-shell"),
        ("| zsh", "pipe-to-shell"),
        ("|sh ", "pipe-to-shell"),
        ("|bash", "pipe-to-shell"),
        ("chmod 777", "world-writable-permissions"),
        ("chmod -r 777", "world-writable-permissions"),
        ("> /dev/", "device-write"),
        ("> /etc/", "system-file-write"),
        (":(){", "fork-bomb"),
        ("history -c", "history-erasure"),
        ("/.ssh", "ssh-credentials"),
        ("/.aws/credentials", "cloud-credentials"),
        ("/.config/gh/hosts.yml", "cloud-credentials"),
        ("id_rsa", "ssh-credentials"),
        ("id_ed25519", "ssh-credentials"),
        ("find-generic-password", "keychain-access"),
        ("find-internet-password", "keychain-access"),
        ("/etc/passwd", "system-credentials"),
        ("/etc/shadow", "system-credentials"),
    ]

    /// Command heads that are never auto-approved, whatever their arguments.
    private static let dangerousCommands: [String: String] = [
        "rm": "irreversible-delete",
        "rmdir": "irreversible-delete",
        "shred": "irreversible-delete",
        "unlink": "irreversible-delete",
        "sudo": "privilege-escalation",
        "doas": "privilege-escalation",
        "su": "privilege-escalation",
        "dd": "raw-disk-write",
        "mkfs": "filesystem-format",
        "diskutil": "disk-administration",
        "fdisk": "disk-administration",
        "parted": "disk-administration",
        "shutdown": "host-power",
        "reboot": "host-power",
        "halt": "host-power",
        "launchctl": "system-daemon-control",
        "systemctl": "system-daemon-control",
        "chown": "ownership-change",
        "visudo": "privilege-escalation",
        "passwd": "credential-change",
        "security": "keychain-access",
        "defaults": "system-preferences-write",
        "crontab": "scheduled-job-change",
        "nc": "raw-network-listener",
        "ncat": "raw-network-listener",
        "telnet": "raw-network-listener",
        "ssh": "remote-host-execution",
        "scp": "remote-host-transfer",
        "rsync": "bulk-file-transfer",
        "ftp": "remote-host-transfer",
        "sftp": "remote-host-transfer",
    ]

    /// Publishing and deployment verbs, keyed by command head. Reaching any of
    /// these means the action leaves the machine and is effectively public.
    private static let externalEffectCommands: [String: Set<String>] = [
        "npm": ["publish", "deprecate", "unpublish", "adduser", "login", "token"],
        "pnpm": ["publish"],
        "yarn": ["publish"],
        "bun": ["publish"],
        "cargo": ["publish", "yank", "login"],
        "gem": ["push", "yank"],
        "twine": ["upload"],
        "poetry": ["publish"],
        "docker": ["push", "login"],
        "podman": ["push", "login"],
        "terraform": ["apply", "destroy", "import"],
        "tofu": ["apply", "destroy", "import"],
        "pulumi": ["up", "destroy"],
        "kubectl": ["apply", "delete", "drain", "cordon", "replace", "patch", "scale"],
        "helm": ["install", "upgrade", "uninstall", "rollback"],
        "vercel": ["deploy", "promote", "rollback", "alias", "remove"],
        "netlify": ["deploy"],
        "fly": ["deploy", "destroy", "scale"],
        "flyctl": ["deploy", "destroy", "scale"],
        "heroku": ["run", "releases:rollback", "apps:destroy"],
        "serverless": ["deploy", "remove"],
        "sls": ["deploy", "remove"],
        "eb": ["deploy", "terminate"],
        "convex": ["deploy"],
        "supabase": ["db", "link", "push"],
        "wrangler": ["publish", "deploy", "delete"],
        "expo": ["publish", "submit"],
        "eas": ["submit", "build"],
        "pod": ["trunk"],
        "aws": ["s3", "ec2", "iam", "rds", "lambda", "cloudformation"],
        "gcloud": ["compute", "run", "deploy", "sql", "iam"],
        "az": ["vm", "webapp", "group", "deployment"],
        "stripe": ["trigger", "subscriptions", "charges"],
    ]

    /// `gh` subcommands that publish, merge, or destroy.
    private static let dangerousGitHubSubcommands: Set<String> = [
        "release", "api", "secret", "auth", "ssh-key", "gpg-key",
    ]

    /// `gh <noun> <verb>` pairs that are destructive or outward-facing.
    private static let dangerousGitHubVerbs: [String: Set<String>] = [
        "pr": ["merge", "close", "ready"],
        "repo": ["delete", "archive", "rename", "create"],
        "issue": ["close", "delete", "transfer"],
        "workflow": ["run", "enable", "disable"],
        "run": ["cancel", "rerun"],
    ]

    /// `git` subcommands that publish history or destroy uncommitted work.
    private static let dangerousGitSubcommands: [String: String] = [
        "push": "publishes-history",
        "filter-branch": "rewrites-history",
        "filter-repo": "rewrites-history",
        "prune": "destroys-objects",
        "gc": "destroys-objects",
    ]

    /// `git` subcommands that only report state.
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "diff", "log", "show", "blame", "describe", "shortlog",
        "rev-parse", "rev-list", "ls-files", "ls-remote", "ls-tree",
        "cat-file", "whatchanged", "reflog", "grep", "count-objects",
        "merge-base", "name-rev", "symbolic-ref", "var", "version",
    ]

    /// Command heads that observe without mutating. Anything absent from this
    /// set falls through to the judge, so omissions cost a judge call rather
    /// than safety.
    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "cat", "bat", "head", "tail", "wc", "nl", "tac",
        "echo", "printf", "date", "whoami", "hostname", "uname", "uptime",
        "which", "type", "command", "whereis", "file", "stat", "du", "df",
        "tree", "basename", "dirname", "realpath", "readlink",
        "grep", "egrep", "fgrep", "rg", "ag", "ack", "find", "fd",
        "jq", "yq", "column", "sort", "uniq", "cut", "tr", "paste", "join",
        "diff", "cmp", "comm", "md5", "md5sum", "shasum", "sha256sum", "cksum",
        "true", "false", "test", "seq", "yes", "sleep", "time",
        "ps", "top", "lsof", "id", "groups", "locale", "arch", "sw_vers",
        "man", "help", "tldr", "less", "more",
    ]

    public static func scan(command: String) -> Result {
        let collapsed = collapseWhitespace(command).lowercased()
        guard !collapsed.isEmpty else { return .judge }

        for entry in dangerousSubstrings where collapsed.contains(entry.pattern) {
            return .blocked(rule: entry.rule)
        }
        // `.env` is a secret file, but `.env.example` and `.envrc.sample` are
        // not. Match the real thing without condemning its templates.
        if mentionsDotEnvSecret(collapsed) {
            return .blocked(rule: "environment-secrets")
        }

        let segments = splitSegments(collapsed)
        guard !segments.isEmpty else { return .judge }

        var everySegmentIsReadOnly = true
        for segment in segments {
            switch scanSegment(segment) {
            case .blocked(let rule):
                return .blocked(rule: rule)
            case .judge:
                everySegmentIsReadOnly = false
            case .readOnly:
                continue
            }
        }
        return everySegmentIsReadOnly ? .readOnly : .judge
    }

    private static func scanSegment(_ segment: String) -> Result {
        let tokens = segment.split(separator: " ").map(String.init)
        guard let head = commandHead(tokens: tokens) else { return .judge }
        let arguments = Array(tokens.drop { $0 != head }.dropFirst())

        if let rule = dangerousCommands[head] {
            return .blocked(rule: rule)
        }
        // A redirection writes somewhere; only the read-only paths above are
        // exempt, so any surviving redirect goes to the judge.
        let redirects = segment.contains(">")

        switch head {
        case "git":
            return scanGit(arguments: arguments, redirects: redirects)
        case "gh":
            return scanGitHub(arguments: arguments)
        default:
            break
        }

        if let verbs = externalEffectCommands[head] {
            let subcommand = firstNonFlag(arguments)
            if let subcommand, verbs.contains(subcommand) {
                return .blocked(rule: "external-effect-\(head)")
            }
            // Unknown subcommand of a deploy-capable CLI: never a fast path.
            return .judge
        }

        if readOnlyCommands.contains(head) && !redirects {
            return .readOnly
        }
        return .judge
    }

    private static func scanGit(arguments: [String], redirects: Bool) -> Result {
        guard let subcommand = firstNonFlag(arguments) else { return .judge }
        if let rule = dangerousGitSubcommands[subcommand] {
            return .blocked(rule: "git-\(rule)")
        }
        // `reset --hard` and `clean -f` destroy uncommitted work; their
        // soft variants do not.
        if subcommand == "reset", arguments.contains("--hard") {
            return .blocked(rule: "git-destroys-working-tree")
        }
        if subcommand == "clean", arguments.contains(where: { $0.hasPrefix("-") && $0.contains("f") }) {
            return .blocked(rule: "git-destroys-untracked-files")
        }
        if subcommand == "branch", arguments.contains(where: { $0 == "-D" || $0 == "--delete" || $0 == "-d" }) {
            return .judge
        }
        if readOnlyGitSubcommands.contains(subcommand) && !redirects {
            return .readOnly
        }
        return .judge
    }

    private static func scanGitHub(arguments: [String]) -> Result {
        guard let noun = firstNonFlag(arguments) else { return .judge }
        if dangerousGitHubSubcommands.contains(noun) {
            return .blocked(rule: "github-\(noun)")
        }
        let rest = Array(arguments.drop { $0 != noun }.dropFirst())
        if let verb = firstNonFlag(rest), dangerousGitHubVerbs[noun]?.contains(verb) == true {
            return .blocked(rule: "github-\(noun)-\(verb)")
        }
        return .judge
    }

    /// Skips leading `FOO=bar` assignments and strips any directory prefix, so
    /// `/bin/rm` and `env FOO=1 rm` both resolve to `rm`.
    private static func commandHead(tokens: [String]) -> String? {
        for token in tokens {
            if token.isEmpty { continue }
            if token.contains("=") && !token.hasPrefix("-") && !token.contains("/") {
                continue
            }
            if token == "env" || token == "command" || token == "builtin" || token == "exec" {
                continue
            }
            if token.hasPrefix("-") { continue }
            let withoutPath = token.split(separator: "/").last.map(String.init) ?? token
            return withoutPath.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()"))
        }
        return nil
    }

    private static func firstNonFlag(_ arguments: [String]) -> String? {
        arguments.first { !$0.hasPrefix("-") && !$0.isEmpty }
    }

    /// Treats every shell control operator as a separator, including the
    /// command-substitution delimiters, so `$(rm -rf x)` exposes `rm` as a
    /// segment head rather than hiding it inside an argument.
    private static func splitSegments(_ command: String) -> [String] {
        var normalized = command
        for separator in ["&&", "||", ";", "|", "\n", "$(", "`", ")", "{", "}", "&"] {
            normalized = normalized.replacingOccurrences(of: separator, with: "\u{0001}")
        }
        return normalized
            .split(separator: "\u{0001}")
            .map { collapseWhitespace(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func mentionsDotEnvSecret(_ collapsed: String) -> Bool {
        var searchRange = collapsed.startIndex..<collapsed.endIndex
        while let found = collapsed.range(of: ".env", range: searchRange) {
            let suffix = collapsed[found.upperBound...]
            let nextCharacter = suffix.first
            let isTemplate = suffix.hasPrefix(".example")
                || suffix.hasPrefix(".sample")
                || suffix.hasPrefix(".template")
                || suffix.hasPrefix("rc")
            // `.environment`/`.envs` are not the secret file either; only a
            // path boundary right after `.env` makes this the real thing.
            let isBoundary = nextCharacter == nil
                || nextCharacter == " "
                || nextCharacter == "\""
                || nextCharacter == "'"
                || nextCharacter == "/"
                || nextCharacter == "."
            if isBoundary && !isTemplate {
                return true
            }
            searchRange = found.upperBound..<collapsed.endIndex
        }
        return false
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
