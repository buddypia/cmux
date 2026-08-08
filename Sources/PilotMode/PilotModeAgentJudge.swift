import CMUXAgentLaunch
import Foundation

/// Runs the Pilot Mode judge by invoking an agent CLI headlessly.
///
/// The process is launched with tools, network, MCP, session persistence, and
/// user config disabled (see ``PilotModeJudgeInvocationBuilder``), in a
/// throwaway working directory, with a scrubbed environment
/// (``PilotModeJudgeEnvironment``). It reads the pending request as data and
/// returns text; it cannot act on what it reads.
struct PilotModeAgentJudge: PilotModeJudge {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func evaluate(
        prompt: String,
        timeout: TimeInterval,
        context: PilotModeJudgeContext
    ) async -> PilotModeJudgeOutcome {
        let searchPath = environment["PATH"]
        guard let agent = PilotModeJudgeInvocationBuilder.resolveJudgeAgent(
            sessionAgent: context.agentSlug,
            isInstalled: { Self.resolveExecutable($0, searchPath: searchPath) != nil }
        ) else {
            return .unavailable
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pilot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let promptFile = root.appendingPathComponent("prompt.txt", isDirectory: false)
        let outputFile = root.appendingPathComponent("verdict.txt", isDirectory: false)
        guard let promptData = prompt.data(using: .utf8),
              FileManager.default.createFile(
                atPath: promptFile.path,
                contents: promptData,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
              ) else {
            return .unavailable
        }

        guard let invocation = PilotModeJudgeInvocationBuilder.invocation(
            agentSlug: agent,
            promptFilePath: promptFile.path,
            outputFilePath: outputFile.path,
            scratchDirectory: root.path,
            claudeModel: PilotModeJudgeEnvironment.claudeModel(from: environment)
        ), let executable = Self.resolveExecutable(
            invocation.executableName,
            searchPath: searchPath
        ) else {
            return .unavailable
        }

        let outcome = await Self.run(
            executable: executable,
            invocation: invocation,
            prompt: prompt,
            environment: PilotModeJudgeEnvironment.judgeEnvironment(from: environment),
            workingDirectory: root,
            timeout: timeout
        )
        guard case .text(let stdout) = outcome else { return outcome }

        // Codex reports its answer in a file rather than on stdout.
        if let outputFilePath = invocation.outputFilePath {
            let contents = (try? String(contentsOfFile: outputFilePath, encoding: .utf8)) ?? ""
            return .text(contents.isEmpty ? stdout : contents)
        }
        return .text(stdout)
    }

    /// Launches the judge and collects stdout.
    ///
    /// stdout goes to a file rather than a pipe, so a chatty judge cannot fill
    /// a pipe buffer and deadlock while we wait on the deadline. On timeout the
    /// process is signalled by pid — never by process group, which would target
    /// cmux's own group, since `Process` does not put children in a group of
    /// their own.
    private static func run(
        executable: String,
        invocation: PilotModeJudgeInvocation,
        prompt: String,
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async -> PilotModeJudgeOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let stdoutURL = workingDirectory.appendingPathComponent("stdout.txt", isDirectory: false)
                guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
                      let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL) else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                defer { try? stdoutHandle.close() }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = invocation.arguments
                process.environment = environment
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = stdoutHandle
                process.standardError = FileHandle.nullDevice

                let stdinPipe = Pipe()
                process.standardInput = invocation.deliversPromptOnStdin
                    ? stdinPipe
                    : FileHandle.nullDevice

                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .unavailable)
                    return
                }

                if invocation.deliversPromptOnStdin {
                    let handle = stdinPipe.fileHandleForWriting
                    if let data = prompt.data(using: .utf8) {
                        // A judge that exits early leaves us writing into a
                        // closed pipe; that is a timeout/parse failure, not a
                        // crash.
                        try? handle.write(contentsOf: data)
                    }
                    try? handle.close()
                }

                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                        _ = finished.wait(timeout: .now() + 1)
                    }
                    continuation.resume(returning: .timedOut)
                    return
                }

                try? stdoutHandle.close()
                let data = (try? Data(contentsOf: stdoutURL)) ?? Data()
                continuation.resume(
                    returning: .text(String(data: data, encoding: .utf8) ?? "")
                )
            }
        }
    }

    private static func resolveExecutable(_ name: String, searchPath: String?) -> String? {
        let fileManager = FileManager.default
        let directories = (searchPath ?? "")
            .split(separator: ":")
            .map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false).path
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
