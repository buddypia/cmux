import CryptoKit
import Foundation

extension CMUXCLI {
    enum AgentAutoNamingSource: Equatable {
        case antigravityTranscript
        case codexRollout
        case grokHistory
        case hookMessageCache
    }

    func autoNamingSource(for def: AgentHookDef) -> AgentAutoNamingSource? {
        switch def.name {
        case "codex":
            return .codexRollout
        case "antigravity":
            return .antigravityTranscript
        case "grok":
            return .grokHistory
        case "opencode", "pi", "omp":
            return .hookMessageCache
        default:
            return nil
        }
    }

    func usesHookMessageCacheForAutoNaming(_ def: AgentHookDef) -> Bool {
        autoNamingSource(for: def) == .hookMessageCache
    }

    func autoNamingMessages(
        for def: AgentHookDef,
        parsedInput: ClaudeHookParsedInput,
        client: SocketClient,
        workspaceId: String,
        engine: AutoNamingEngine = AutoNamingEngine()
    ) -> [AutoNamingTranscriptMessage] {
        guard usesHookMessageCacheForAutoNaming(def),
              let object = parsedInput.rawObject ?? parsedInput.object else {
            return []
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true,
           probe["workspace_user_owned"] as? Bool != true else {
            return []
        }
        return engine.extractHookMessages(fromPayloadObjects: [object])
    }

    /// Detached naming pass for non-Codex generic agents.
    func runGenericAgentAutoNameHook(
        def: AgentHookDef,
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        env: [String: String]
    ) {
        guard let source = autoNamingSource(for: def) else { return }
        if case .codexRollout = source { return }
        guard let sessionId = optionValue(commandArgs, name: "--session"),
              let workspaceId = optionValue(commandArgs, name: "--workspace"),
              let surfaceId = optionValue(commandArgs, name: "--surface") else {
            return
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.disabled")
            return
        }
        guard probe["workspace_user_owned"] as? Bool != true else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.user-owned")
            return
        }

        let sessionStore = ClaudeHookSessionStore(processEnv: env)
        let mapped = try? sessionStore.lookup(sessionId: sessionId)
        guard (try? sessionStore.isCurrent(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)) ?? false else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.stale")
            return
        }

        let engine = AutoNamingEngine()
        let sourceResult: (messages: [AutoNamingTranscriptMessage], lineCount: Int)? = {
            switch source {
            case .antigravityTranscript:
                let cwd = normalizedHookValue(optionValue(commandArgs, name: "--cwd")) ?? mapped?.cwd
                let transcriptPath = normalizedHookValue(optionValue(commandArgs, name: "--transcript"))
                    ?? normalizedHookValue(mapped?.transcriptPath)
                    ?? findAntigravityTranscriptPath(sessionId: sessionId, cwd: cwd, env: env)
                guard let transcriptPath else {
                    return nil
                }
                let messages: [AutoNamingTranscriptMessage]
                if URL(fileURLWithPath: transcriptPath).pathExtension == "json" {
                    guard let object = readAntigravityJSONTranscript(path: transcriptPath) else {
                        return nil
                    }
                    messages = engine.extractAntigravityMessages(fromTranscriptObject: object)
                } else {
                    guard let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024),
                          !lines.isEmpty else {
                        return nil
                    }
                    messages = engine.extractAntigravityMessages(fromTranscriptLines: lines)
                }
                return (
                    messages,
                    textFileGrowthMetric(path: transcriptPath, fallbackLineCount: messages.count)
                )
            case .codexRollout:
                return nil
            case .grokHistory:
                let cwd = normalizedHookValue(optionValue(commandArgs, name: "--cwd")) ?? mapped?.cwd
                guard let sessionURL = grokSessionDirectory(cwd: cwd, sessionId: sessionId, env: env) else {
                    return nil
                }
                let historyURL = sessionURL.appendingPathComponent("chat_history.jsonl", isDirectory: false)
                guard let lines = readRecentTextFileLines(path: historyURL.path, maxBytes: 512 * 1024),
                      !lines.isEmpty else {
                    return nil
                }
                let lineCount = textFileGrowthMetric(path: historyURL.path, fallbackLineCount: lines.count)
                return (engine.extractGrokMessages(fromChatHistoryLines: lines), lineCount)
            case .hookMessageCache:
                guard let snapshot = try? sessionStore.autoNamingRecentMessagesSnapshot(sessionId: sessionId),
                      !snapshot.messages.isEmpty else {
                    return nil
                }
                return (
                    snapshot.messages,
                    engine.hookMessageLineEquivalentCount(
                        snapshot.messages,
                        totalMessageCount: snapshot.totalMessageCount
                    )
                )
            }
        }()
        guard let sourceResult, !sourceResult.messages.isEmpty else { return }

        let resolution = resolvedSummarizerAgent(
            probe: probe, sessionAgent: def.name, env: env, telemetry: telemetry
        )
        runMessageBackedAutoName(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            messages: sourceResult.messages,
            lineCount: sourceResult.lineCount,
            sessionStore: sessionStore,
            client: client,
            missingOverride: resolution.missingOverride,
            telemetryKey: "\(def.name)-hook.auto-name",
            telemetry: telemetry
        ) { engine, outcome in
            guard let context = engine.buildContext(from: sourceResult.messages) else { return nil }
            let prompt = engine.buildPrompt(currentTitle: outcome.lastTitle, context: context)
            if def.name == "antigravity", resolution.agent == "antigravity" {
                telemetry.breadcrumb("antigravity-hook.auto-name.no-safe-summarizer")
                if let missing = resolution.missingOverride {
                    reportAutoNamingProblem("not_installed", agent: missing, workspaceId: workspaceId, client: client)
                }
                return nil
            }
            guard let raw = summarize(
                summarizerAgent: resolution.agent,
                prompt: prompt,
                env: env,
                timeout: engine.config.llmTimeout,
                telemetry: telemetry
            ) else {
                reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
                return nil
            }
            return raw
        }
    }

    func runFileBackedAutoName(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        lines: [String],
        lineCount: Int,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        missingOverride: String?,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> String?
    ) {
        guard !lines.isEmpty else { return }
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            missingOverride: missingOverride,
            telemetryKey: telemetryKey,
            telemetry: telemetry,
            rawResponse: rawResponse
        )
    }

    func runMessageBackedAutoName(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        messages: [AutoNamingTranscriptMessage],
        lineCount: Int,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        missingOverride: String?,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> String?
    ) {
        guard !messages.isEmpty else { return }
        runAutoNamingPass(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lineCount: lineCount,
            sessionStore: sessionStore,
            client: client,
            missingOverride: missingOverride,
            telemetryKey: telemetryKey,
            telemetry: telemetry,
            rawResponse: rawResponse
        )
    }

    private func runAutoNamingPass(
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        lineCount: Int,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        missingOverride: String?,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry,
        rawResponse: (AutoNamingEngine, ClaudeHookSessionStore.AutoNamingBeginOutcome) -> String?
    ) {
        let engine = AutoNamingEngine()
        guard let outcome = try? sessionStore.beginAutoNaming(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            transcriptLineCount: lineCount,
            now: Date(),
            engine: engine
        ) else { return }
        guard case .proceed(let baseline) = outcome.decision else {
            telemetry.breadcrumb("\(telemetryKey).throttled")
            return
        }

        var confirmedTitle: String?
        defer {
            try? sessionStore.finishAutoNaming(
                sessionId: sessionId,
                appliedTitle: confirmedTitle,
                baselineLineCount: confirmedTitle != nil ? baseline : nil,
                now: Date()
            )
        }
        guard let rawResponse = rawResponse(engine, outcome) else {
            telemetry.breadcrumb("\(telemetryKey).llm-failed")
            return
        }
        guard let sanitized = engine.sanitizeResponse(rawResponse, currentTitle: nil) else { return }
        confirmedTitle = applyAutoNamingTitle(
            sanitized,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            previousTitle: outcome.lastTitle,
            client: client,
            telemetryKey: telemetryKey,
            telemetry: telemetry
        )
        // Re-report a missing override only after the apply, so the app's
        // clear-on-apply doesn't immediately wipe the Settings note.
        if confirmedTitle != nil, let missing = missingOverride {
            reportAutoNamingProblem("not_installed", agent: missing, workspaceId: workspaceId, client: client)
        }
    }

    private func findAntigravityTranscriptPath(
        sessionId: String,
        cwd: String?,
        env: [String: String]
    ) -> String? {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty,
              let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else {
            return nil
        }
        let home = normalizedHookValue(env["HOME"]) ?? NSHomeDirectory()
        let homeURL = URL(fileURLWithPath: NSString(string: home).expandingTildeInPath, isDirectory: true)
        let fileManager = FileManager.default
        var matches: [(url: URL, date: Date)] = []
        for dir in antigravityCandidateChatDirs(homeURL: homeURL, cwd: cwd) {
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                guard isAntigravityTranscriptFile(url),
                      antigravityTranscript(url, matchesSessionId: normalizedSessionId) else {
                    continue
                }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                matches.append((url, date))
            }
        }
        return matches.max { $0.date < $1.date }?.url.path
    }

    private func readAntigravityJSONTranscript(
        path: String,
        maxBytes: UInt64 = 16 * 1024 * 1024
    ) -> [String: Any]? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size <= maxBytes else { return nil }
            try handle.seek(toOffset: 0)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func antigravityCandidateChatDirs(homeURL: URL, cwd: String) -> [URL] {
        var bucketNames: [String] = []
        var seenBuckets = Set<String>()
        func addBucket(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenBuckets.insert(trimmed).inserted else { return }
            bucketNames.append(trimmed)
        }

        for candidate in antigravityCWDCandidates(cwd) {
            addBucket(URL(fileURLWithPath: candidate).lastPathComponent)
            addBucket(Self.sha256Hex(candidate))
        }

        var dirs: [URL] = []
        var seenPaths = Set<String>()
        for rootName in [".gemini", ".antigravity"] {
            for bucket in bucketNames {
                let dir = homeURL
                    .appendingPathComponent(rootName, isDirectory: true)
                    .appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent(bucket, isDirectory: true)
                    .appendingPathComponent("chats", isDirectory: true)
                guard seenPaths.insert(dir.path).inserted else { continue }
                dirs.append(dir)
            }
        }
        return dirs
    }

    private func antigravityCWDCandidates(_ cwd: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            result.append(path)
        }
        let privateRoot = "/private"
        for base in [cwd, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path] {
            add(base)
            if base.hasPrefix(privateRoot + "/") {
                add(String(base.dropFirst(privateRoot.count)))
            } else if base.hasPrefix("/") {
                add(privateRoot + base)
            }
        }
        return result
    }

    private func isAntigravityTranscriptFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return (url.pathExtension == "jsonl" || url.pathExtension == "json") && !name.hasPrefix("__pending__")
    }

    private func antigravityTranscript(_ url: URL, matchesSessionId sessionId: String) -> Bool {
        let needle = sessionId.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if stem == needle || stem.contains(needle) {
            return true
        }
        return antigravitySessionId(inTranscript: url)?.lowercased() == needle
    }

    private func antigravitySessionId(inTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let id = Self.sessionIdField(in: String(line)) {
                return id
            }
        }
        return nil
    }

    private static func sessionIdField(in text: String) -> String? {
        for key in [#""sessionId""#, #""session_id""#] {
            guard let keyRange = text.range(of: key) else { continue }
            let afterKey = text[keyRange.upperBound...]
            guard let colon = afterKey.firstIndex(of: ":") else { continue }
            var cursor = afterKey.index(after: colon)
            while cursor < afterKey.endIndex, afterKey[cursor].isWhitespace {
                cursor = afterKey.index(after: cursor)
            }
            guard cursor < afterKey.endIndex, afterKey[cursor] == "\"" else { continue }
            cursor = afterKey.index(after: cursor)
            let valueStart = cursor
            var escaped = false
            while cursor < afterKey.endIndex {
                let character = afterKey[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return String(afterKey[valueStart..<cursor])
                }
                cursor = afterKey.index(after: cursor)
            }
        }
        return nil
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func applyAutoNamingTitle(
        _ title: String,
        workspaceId: String,
        surfaceId: String,
        previousTitle: String?,
        client: SocketClient,
        telemetryKey: String,
        telemetry: CLISocketSentryTelemetry
    ) -> String? {
        guard let payload = try? client.sendV2(method: "workspace.set_auto_title", params: [
            "workspace_id": workspaceId,
            "panel_id": surfaceId,
            "panel_only_if_multiple": true,
            "title": title
        ]) else {
            telemetry.breadcrumb("\(telemetryKey).socket-failed")
            return nil
        }
        if payload["workspace_applied"] as? Bool == true {
            telemetry.breadcrumb("\(telemetryKey).applied")
            return title
        }
        telemetry.breadcrumb("\(telemetryKey).rejected")
        return previousTitle
    }
}
