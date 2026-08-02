import CmuxAgentChat
import CmuxFoundation
import Foundation

/// Tails one agent session's transcript file: initial bounded backfill,
/// incremental parsing on file growth, an in-memory message cache for
/// history paging, and append/update batches for live push.
///
/// Seq stability: `seq` equals the absolute transcript line index. The
/// initial backfill may skip a long head (bounded memory), in which case
/// pages before the cache report `hasMore` honestly.
actor AgentChatTranscriptTailer {
    private enum StorageFormat: Sendable, Equatable {
        case jsonLines
        case antigravitySessionJSON
        case antigravityGeneratedMessagesDirectory
    }

    private struct GeneratedMessageFile {
        let url: URL
        let raw: String
        let timestamp: Date?
        let modified: Date
    }

    /// A live transcript change: newly appended messages and in-place
    /// updates (tool results that completed earlier messages).
    struct Batch: Sendable {
        /// Messages newly appended, ascending seq.
        let appended: [ChatMessage]
        /// Earlier messages re-emitted with their results filled in.
        let updated: [ChatMessage]
        /// Non-rendered live state transitions observed in this batch.
        let stateUpdates: [ChatTranscriptStateUpdate]
        /// First user prompt text, when it just became known.
        let discoveredTitle: String?
        /// Explicit transcript title update, when the agent runtime provides one.
        let titleUpdate: String?
        /// Whether the parser still carries unresolved running work after this
        /// batch; used to avoid clearing "working" while another tool is active.
        var hasPendingTranscriptWork = false
        /// The transcript was truncated/replaced and the seq space
        /// restarted; clients must re-anchor.
        var didReset = false

        init(
            appended: [ChatMessage],
            updated: [ChatMessage],
            stateUpdates: [ChatTranscriptStateUpdate] = [],
            discoveredTitle: String?,
            titleUpdate: String? = nil,
            hasPendingTranscriptWork: Bool = false,
            didReset: Bool = false
        ) {
            self.appended = appended
            self.updated = updated
            self.stateUpdates = stateUpdates
            self.discoveredTitle = discoveredTitle
            self.titleUpdate = titleUpdate
            self.hasPendingTranscriptWork = hasPendingTranscriptWork
            self.didReset = didReset
        }
    }

    private let sessionID: String
    private let agentKind: ChatAgentKind
    private let path: String
    private let storageFormat: StorageFormat
    private let onBatch: @Sendable (Batch) async -> Void

    private let maxInitialLines: Int
    private let maxCachedMessages: Int

    private var cache: [ChatMessage] = []
    private var parseState = ChatTranscriptParseState()
    private var byteOffset: UInt64 = 0
    private var lineCount = 0
    /// Identity (inode) of the file last read, so an atomic replace /
    /// rotation is detected even when the new file is the same size or
    /// larger (seeking to the old offset would otherwise skip its head).
    private var fileInode: UInt64?
    private var pendingFragment = Data()
    private var wholeJSONMessagesByID: [String: ChatMessage] = [:]
    private var wholeJSONStateUpdates: [ChatTranscriptStateUpdate] = []
    private var headTruncated = false
    private var watchTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var started = false
    private var reportedTitle = false
    /// First user prompt reported by a transcript row that produces no message
    /// (Codex `event_msg`/`user_message`). Used only when the cache has no user
    /// prose to take the title from.
    private var promptTitleCandidate: String?

    /// Creates a tailer.
    ///
    /// - Parameters:
    ///   - sessionID: The session this transcript belongs to.
    ///   - agentKind: Selects the parser for the agent runtime.
    ///   - path: Absolute transcript path.
    ///   - maxInitialLines: Backfill bound for the first read.
    ///   - maxCachedMessages: In-memory cache cap; oldest fall out.
    ///   - onBatch: Receives live change batches after the initial load.
    init(
        sessionID: String,
        agentKind: ChatAgentKind,
        path: String,
        maxInitialLines: Int = 2000,
        maxCachedMessages: Int = 4000,
        onBatch: @escaping @Sendable (Batch) async -> Void
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.path = path
        self.storageFormat = Self.storageFormat(agentKind: agentKind, path: path)
        self.maxInitialLines = maxInitialLines
        self.maxCachedMessages = maxCachedMessages
        self.onBatch = onBatch
    }

    /// Performs the initial backfill (idempotent) and starts watching for
    /// growth.
    func start() async {
        guard !started else { return }
        started = true
        if let outcome = loadInitialTail(),
           let batch = initialSnapshotBatch(from: outcome) {
            await onBatch(batch)
        }
        let watcher = FileWatcher(path: path, throttle: .milliseconds(200))
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in watcher.events {
                guard let self else { return }
                await self.drainNewContent()
            }
        }
    }

    /// Stops watching and releases resources.
    func stop() async {
        watchTask?.cancel()
        watchTask = nil
        if let watcher {
            await watcher.stop()
        }
        watcher = nil
    }

    /// Serves one history page from the cache, keeping equal-seq groups
    /// whole at page boundaries.
    ///
    /// - Parameters:
    ///   - beforeSeq: Strict upper bound, or `nil` for the newest page.
    ///   - limit: Maximum messages per page.
    /// - Returns: The page, ascending seq.
    func history(beforeSeq: Int?, limit: Int) -> ChatHistoryPage {
        let eligible: ArraySlice<ChatMessage>
        if let beforeSeq {
            let end = cache.firstIndex { $0.seq >= beforeSeq } ?? cache.endIndex
            eligible = cache[..<end]
        } else {
            eligible = cache[...]
        }
        var start = max(eligible.startIndex, eligible.endIndex - limit)
        // Never split an equal-seq group across the boundary: extend back to
        // include every message sharing the boundary line's seq.
        while start > eligible.startIndex, cache[start - 1].seq == cache[start].seq {
            start -= 1
        }
        let page = Array(eligible[start...])
        // At the cache head, `headTruncated` keeps `hasMore` honest: older
        // transcript exists on disk that this tailer will never serve. The
        // client recognizes the resulting empty page and shows its "earlier
        // history is on your Mac" cell instead of looping.
        return ChatHistoryPage(
            messages: page,
            hasMore: start > eligible.startIndex || headTruncated
        )
    }

    /// Latches the first message-less prompt a parse call reported.
    /// First write wins, mirroring `title`'s "first prompt" rule.
    private func notePromptTitleCandidate(_ candidate: String?) {
        guard promptTitleCandidate == nil, let candidate else { return }
        promptTitleCandidate = candidate
    }

    /// First user prompt in the cache, for the session title.
    ///
    /// Falls back to a prompt the transcript stated without producing a
    /// message, so a Codex session whose head is still only telemetry rows
    /// still gets a title instead of showing as untitled.
    var title: String? {
        for message in cache {
            if message.role == .user, case .prose(let prose) = message.kind {
                return String(prose.text.prefix(80))
            }
        }
        return promptTitleCandidate
    }

    // MARK: - Reading

    private func loadInitialTail() -> ChatTranscriptParseResult? {
        if storageFormat == .antigravitySessionJSON {
            return loadInitialSessionJSON()
        }
        if storageFormat == .antigravityGeneratedMessagesDirectory {
            return loadInitialGeneratedMessagesDirectory()
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Memory-mapped read: newline scanning walks the file without
        // copying it; only the bounded tail is decoded into strings.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return nil
        }
        var lineStarts: [Int] = [0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count where raw[index] == 0x0A {
                lineStarts.append(index + 1)
            }
        }
        // A trailing partial line (no terminating newline) is carried as the
        // pending fragment; only complete lines are parsed and counted.
        let completeLineCount = lineStarts.count - 1
        let lastCompleteEnd = lineStarts[completeLineCount]
        if lastCompleteEnd < data.count {
            pendingFragment = Data(data[lastCompleteEnd...])
        }
        byteOffset = UInt64(data.count)
        lineCount = completeLineCount
        fileInode = Self.inode(ofPath: path)

        let parseStartLine = max(0, completeLineCount - maxInitialLines)
        headTruncated = parseStartLine > 0
        var lines: [String] = []
        lines.reserveCapacity(completeLineCount - parseStartLine)
        for lineIndex in parseStartLine..<completeLineCount {
            let range = lineStarts[lineIndex]..<(lineStarts[lineIndex + 1] - 1)
            lines.append(String(decoding: data[range], as: UTF8.self))
        }
        let outcome = parse(lines: lines, startingSeq: parseStartLine)
        cache = outcome.messages
        parseState = outcome.state
        notePromptTitleCandidate(outcome.promptTitleCandidate)
        trimCacheIfNeeded()
        return outcome
    }

    private func drainNewContent() async {
        if storageFormat == .antigravitySessionJSON {
            await drainSessionJSONContent()
            return
        }
        if storageFormat == .antigravityGeneratedMessagesDirectory {
            await drainGeneratedMessagesDirectoryContent()
            return
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let currentInode = Self.inode(ofPath: path)
        let rotated = fileInode != nil && currentInode != nil && currentInode != fileInode
        if size < byteOffset || rotated {
            // Truncated, or atomically replaced/rotated (new inode even at
            // equal/larger size — seeking to the old offset would skip the
            // new file's head). Reset, re-read from scratch, and tell
            // clients explicitly: the seq space restarted, and id-based
            // heuristics can't always detect that (codex line-N ids repeat).
            byteOffset = 0
            lineCount = 0
            pendingFragment = Data()
            cache = []
            parseState = ChatTranscriptParseState()
            headTruncated = false
            // A rotated/replaced transcript (e.g. `claude --resume` rewriting
            // the file) carries a new first prompt; allow it to be rediscovered
            // and re-emitted as the title instead of keeping the stale one.
            reportedTitle = false
            promptTitleCandidate = nil
            let outcome = loadInitialTail()
            let initialBatch = outcome.flatMap { initialSnapshotBatch(from: $0, didReset: true) }
            await onBatch(initialBatch ?? Batch(appended: [], updated: [], discoveredTitle: nil, didReset: true))
            return
        }
        guard size > byteOffset else { return }
        try? handle.seek(toOffset: byteOffset)
        guard let newData = try? handle.readToEnd(), !newData.isEmpty else { return }
        byteOffset += UInt64(newData.count)

        var buffer = pendingFragment
        buffer.append(newData)
        var lines: [String] = []
        var sliceStart = buffer.startIndex
        for index in buffer.indices where buffer[index] == 0x0A {
            lines.append(String(decoding: buffer[sliceStart..<index], as: UTF8.self))
            sliceStart = buffer.index(after: index)
        }
        pendingFragment = Data(buffer[sliceStart...])
        guard !lines.isEmpty else { return }

        let startingSeq = lineCount
        lineCount += lines.count
        let outcome = parse(lines: lines, startingSeq: startingSeq)
        let hasPendingTranscriptWork = Self.hasPendingTranscriptWork(outcome.state)
        parseState = outcome.state
        notePromptTitleCandidate(outcome.promptTitleCandidate)
        let stateUpdates = outcome.stateUpdates
        let titleUpdate = outcome.titleUpdate
        var updated = outcome.updatedMessages
        for update in updated {
            if let index = cache.firstIndex(where: { $0.id == update.id }) {
                cache[index] = update
            }
        }
        cache.append(contentsOf: outcome.messages)
        trimCacheIfNeeded()
        // Updates for messages that already fell out of the cache are still
        // pushed: a live client may hold them in its window.
        guard !outcome.messages.isEmpty || !updated.isEmpty || !stateUpdates.isEmpty || titleUpdate != nil else {
            return
        }
        var discoveredTitle: String?
        if !reportedTitle, let title {
            reportedTitle = true
            discoveredTitle = title
        }
        updated = outcome.updatedMessages
        await onBatch(
            Batch(
                appended: outcome.messages,
                updated: updated,
                stateUpdates: stateUpdates,
                discoveredTitle: discoveredTitle,
                titleUpdate: titleUpdate,
                hasPendingTranscriptWork: hasPendingTranscriptWork
            )
        )
    }

    private func loadInitialSessionJSON() -> ChatTranscriptParseResult? {
        fileInode = Self.inode(ofPath: path)
        guard let outcome = parseSessionJSONFile() else { return nil }
        cache = outcome.messages
        parseState = outcome.state
        notePromptTitleCandidate(outcome.promptTitleCandidate)
        lineCount = (outcome.messages.map(\.seq).max() ?? -1) + 1
        wholeJSONMessagesByID = Self.messagesByID(outcome.messages)
        wholeJSONStateUpdates = outcome.stateUpdates
        headTruncated = false
        byteOffset = Self.fileSize(ofPath: path) ?? 0
        trimCacheIfNeeded()
        return outcome
    }

    private func loadInitialGeneratedMessagesDirectory() -> ChatTranscriptParseResult? {
        fileInode = Self.inode(ofPath: path)
        guard let outcome = parseGeneratedMessagesDirectory() else { return nil }
        cache = outcome.messages
        parseState = outcome.state
        notePromptTitleCandidate(outcome.promptTitleCandidate)
        lineCount = (outcome.messages.map(\.seq).max() ?? -1) + 1
        wholeJSONMessagesByID = Self.messagesByID(outcome.messages)
        wholeJSONStateUpdates = outcome.stateUpdates
        headTruncated = false
        byteOffset = 0
        trimCacheIfNeeded()
        return outcome
    }

    private func drainSessionJSONContent() async {
        let currentInode = Self.inode(ofPath: path)
        let rotated = fileInode != nil && currentInode != nil && currentInode != fileInode
        if rotated || (Self.fileSize(ofPath: path) ?? 0) < byteOffset {
            cache = []
            parseState = ChatTranscriptParseState()
            lineCount = 0
            wholeJSONMessagesByID = [:]
            wholeJSONStateUpdates = []
            headTruncated = false
            reportedTitle = false
            promptTitleCandidate = nil
            let outcome = loadInitialSessionJSON()
            let initialBatch = outcome.flatMap { initialSnapshotBatch(from: $0, didReset: true) }
            await onBatch(initialBatch ?? Batch(appended: [], updated: [], discoveredTitle: nil, didReset: true))
            return
        }

        guard let outcome = parseSessionJSONFile() else { return }
        fileInode = currentInode
        byteOffset = Self.fileSize(ofPath: path) ?? byteOffset
        lineCount = (outcome.messages.map(\.seq).max() ?? -1) + 1
        let hasPendingTranscriptWork = Self.hasPendingTranscriptWork(outcome.state)
        parseState = outcome.state
        notePromptTitleCandidate(outcome.promptTitleCandidate)
        let stateUpdates = Self.newStateUpdates(
            in: outcome.stateUpdates,
            previous: wholeJSONStateUpdates
        )
        let titleUpdate = outcome.titleUpdate

        let previousByID = wholeJSONMessagesByID
        var appended: [ChatMessage] = []
        var updated: [ChatMessage] = []
        for message in outcome.messages {
            if let previous = previousByID[message.id] {
                if previous != message {
                    updated.append(message)
                }
            } else {
                appended.append(message)
            }
        }

        wholeJSONMessagesByID = Self.messagesByID(outcome.messages)
        wholeJSONStateUpdates = outcome.stateUpdates
        cache = outcome.messages
        headTruncated = false
        trimCacheIfNeeded()

        guard !appended.isEmpty || !updated.isEmpty || !stateUpdates.isEmpty || titleUpdate != nil else { return }
        var discoveredTitle: String?
        if !reportedTitle, let title {
            reportedTitle = true
            discoveredTitle = title
        }
        await onBatch(
            Batch(
                appended: appended,
                updated: updated,
                stateUpdates: stateUpdates,
                discoveredTitle: discoveredTitle,
                titleUpdate: titleUpdate,
                hasPendingTranscriptWork: hasPendingTranscriptWork
            )
        )
    }

    private func drainGeneratedMessagesDirectoryContent() async {
        let currentInode = Self.inode(ofPath: path)
        let rotated = fileInode != nil && currentInode != nil && currentInode != fileInode
        if rotated {
            cache = []
            parseState = ChatTranscriptParseState()
            lineCount = 0
            wholeJSONMessagesByID = [:]
            wholeJSONStateUpdates = []
            headTruncated = false
            reportedTitle = false
            promptTitleCandidate = nil
            let outcome = loadInitialGeneratedMessagesDirectory()
            let initialBatch = outcome.flatMap { initialSnapshotBatch(from: $0, didReset: true) }
            await onBatch(initialBatch ?? Batch(appended: [], updated: [], discoveredTitle: nil, didReset: true))
            return
        }

        guard let outcome = parseGeneratedMessagesDirectory() else { return }
        fileInode = currentInode
        lineCount = (outcome.messages.map(\.seq).max() ?? -1) + 1
        let hasPendingTranscriptWork = Self.hasPendingTranscriptWork(outcome.state)
        parseState = outcome.state
        notePromptTitleCandidate(outcome.promptTitleCandidate)
        let stateUpdates = Self.newStateUpdates(
            in: outcome.stateUpdates,
            previous: wholeJSONStateUpdates
        )
        let titleUpdate = outcome.titleUpdate

        let previousByID = wholeJSONMessagesByID
        var appended: [ChatMessage] = []
        var updated: [ChatMessage] = []
        for message in outcome.messages {
            if let previous = previousByID[message.id] {
                if previous != message {
                    updated.append(message)
                }
            } else {
                appended.append(message)
            }
        }

        wholeJSONMessagesByID = Self.messagesByID(outcome.messages)
        wholeJSONStateUpdates = outcome.stateUpdates
        cache = outcome.messages
        headTruncated = false
        trimCacheIfNeeded()

        guard !appended.isEmpty || !updated.isEmpty || !stateUpdates.isEmpty || titleUpdate != nil else { return }
        var discoveredTitle: String?
        if !reportedTitle, let title {
            reportedTitle = true
            discoveredTitle = title
        }
        await onBatch(
            Batch(
                appended: appended,
                updated: updated,
                stateUpdates: stateUpdates,
                discoveredTitle: discoveredTitle,
                titleUpdate: titleUpdate,
                hasPendingTranscriptWork: hasPendingTranscriptWork
            )
        )
    }

    private func parseSessionJSONFile() -> ChatTranscriptParseResult? {
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return nil
        }
        return AntigravityTranscriptParser(sessionID: sessionID)
            .parseSessionJSON(raw, state: ChatTranscriptParseState())
    }

    private func parseGeneratedMessagesDirectory() -> ChatTranscriptParseResult? {
        guard Self.isDirectory(path) else { return nil }
        let files = generatedMessageFiles()
            .sorted { lhs, rhs in
                let lhsDate = lhs.timestamp ?? lhs.modified
                let rhsDate = rhs.timestamp ?? rhs.modified
                if lhsDate == rhsDate {
                    return lhs.url.lastPathComponent < rhs.url.lastPathComponent
                }
                return lhsDate < rhsDate
            }
        var state = ChatTranscriptParseState()
        var messages: [ChatMessage] = []
        var updatedMessages: [ChatMessage] = []
        var stateUpdates: [ChatTranscriptStateUpdate] = []
        var titleUpdate: String?
        let parser = AntigravityTranscriptParser(
            sessionID: Self.generatedMessagesRootSessionID(from: sessionID)
        )
        for (index, file) in files.enumerated() {
            guard let outcome = parser.parseSessionJSON(file.raw, startingSeq: index, state: state) else {
                continue
            }
            messages.append(contentsOf: outcome.messages)
            updatedMessages.append(
                contentsOf: Self.applyUpdatedMessages(outcome.updatedMessages, to: &messages)
            )
            stateUpdates.append(contentsOf: outcome.stateUpdates)
            titleUpdate = outcome.titleUpdate ?? titleUpdate
            state = outcome.state
        }
        return ChatTranscriptParseResult(
            messages: messages,
            updatedMessages: updatedMessages,
            stateUpdates: stateUpdates,
            titleUpdate: titleUpdate,
            state: state
        )
    }

    private func generatedMessageFiles() -> [GeneratedMessageFile] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false),
                  let raw = try? String(contentsOf: url, encoding: .utf8),
                  let object = Self.generatedMessageObject(in: raw),
                  Self.isVisibleGeneratedMessageObject(object) else {
                return nil
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return GeneratedMessageFile(
                url: url,
                raw: raw,
                timestamp: Self.generatedMessageTimestamp(in: object),
                modified: modified
            )
        }
    }

    private func parse(lines: [String], startingSeq: Int) -> ChatTranscriptParseResult {
        switch agentKind {
        case .codex:
            return CodexTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: parseState)
        case .antigravity:
            return AntigravityTranscriptParser(sessionID: sessionID)
                .parse(lines: lines, startingSeq: startingSeq, state: parseState)
        case .claude, .other:
            return ClaudeTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: parseState)
        }
    }

    private static func hasPendingTranscriptWork(_ state: ChatTranscriptParseState) -> Bool {
        let pendingMessages = state.pendingToolUses.values.flatMap { $0 }
        return ChatTranscriptStateSignal.workingTimestamp(in: pendingMessages) != nil
    }

    private func initialSnapshotBatch(
        from outcome: ChatTranscriptParseResult,
        didReset: Bool = false
    ) -> Batch? {
        let hasPendingTranscriptWork = Self.hasPendingTranscriptWork(outcome.state)
        let stateUpdates = ChatTranscriptStateSignal.initialStateUpdates(
            messages: outcome.messages,
            stateUpdates: outcome.stateUpdates,
            hasPendingTranscriptWork: hasPendingTranscriptWork
        )
        let titleUpdate = outcome.titleUpdate
        let discoveredTitle = unreportedTitle()
        guard !stateUpdates.isEmpty || discoveredTitle != nil || titleUpdate != nil else {
            return didReset
                ? Batch(appended: [], updated: [], discoveredTitle: nil, didReset: true)
                : nil
        }
        return Batch(
            appended: [],
            updated: [],
            stateUpdates: stateUpdates,
            discoveredTitle: discoveredTitle,
            titleUpdate: titleUpdate,
            hasPendingTranscriptWork: hasPendingTranscriptWork,
            didReset: didReset
        )
    }

    private func unreportedTitle() -> String? {
        guard !reportedTitle, let title else { return nil }
        reportedTitle = true
        return title
    }

    private static func applyUpdatedMessages(
        _ updates: [ChatMessage],
        to messages: inout [ChatMessage]
    ) -> [ChatMessage] {
        var unapplied: [ChatMessage] = []
        for update in updates {
            if let index = messages.firstIndex(where: { $0.id == update.id }) {
                messages[index] = update
            } else {
                unapplied.append(update)
            }
        }
        return unapplied
    }

    private static func newStateUpdates(
        in updates: [ChatTranscriptStateUpdate],
        previous: [ChatTranscriptStateUpdate]
    ) -> [ChatTranscriptStateUpdate] {
        var remainingPrevious = previous
        return updates.filter { update in
            if let index = remainingPrevious.firstIndex(of: update) {
                remainingPrevious.remove(at: index)
                return false
            }
            return true
        }
    }

    /// The inode of a path, or nil when it can't be stat'd. Used to spot
    /// an atomic file replacement that size alone would miss.
    private static func inode(ofPath path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.systemFileNumber] as? UInt64 else {
            return nil
        }
        return number
    }

    private static func fileSize(ofPath path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        if let size = attrs[.size] as? NSNumber {
            return size.uint64Value
        }
        return nil
    }

    private static func storageFormat(agentKind: ChatAgentKind, path: String) -> StorageFormat {
        guard agentKind == .antigravity else {
            return .jsonLines
        }
        if isDirectory(path) {
            return .antigravityGeneratedMessagesDirectory
        }
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "json" else {
            return .jsonLines
        }
        return .antigravitySessionJSON
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func generatedMessageObject(in raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func isVisibleGeneratedMessageObject(_ object: [String: Any]) -> Bool {
        guard object["hideFromUser"] as? Bool != true,
              object["sender"] as? String != nil,
              object["recipient"] as? String != nil,
              let content = object["content"] as? String else {
            return false
        }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func generatedMessageTimestamp(in object: [String: Any]) -> Date? {
        for key in ["timestamp", "created_at", "createdAt"] {
            if let date = date(from: object[key]) {
                return date
            }
        }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        if let string = value as? String {
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                return date
            }
            return try? Date.ISO8601FormatStyle().parse(string)
        }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func generatedMessagesRootSessionID(from sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else {
            return trimmed
        }
        return String(trimmed[..<slash])
    }

    private static func messagesByID(_ messages: [ChatMessage]) -> [String: ChatMessage] {
        var result: [String: ChatMessage] = [:]
        for message in messages {
            result[message.id] = message
        }
        return result
    }

    private func trimCacheIfNeeded() {
        guard cache.count > maxCachedMessages else { return }
        cache.removeFirst(cache.count - maxCachedMessages)
        headTruncated = true
    }
}
