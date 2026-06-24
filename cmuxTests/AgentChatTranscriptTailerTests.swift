import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite struct AgentChatTranscriptTailerTests {
    @Test("Codex first prompt in the initial backfill publishes a title-only batch")
    func codexInitialPromptPublishesTitleOnlyBatch() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-codex-initial-title-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("rollout-initial-title.jsonl", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try (codexLine(
            type: "event_msg",
            payload: ["type": "user_message", "text": "Explain the release plan"],
            timestamp: "2026-06-19T10:00:00.000Z"
        ) + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "codex-initial-title-session",
            agentKind: .codex,
            path: transcript.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        await tailer.stop()

        guard let batch = await collector.firstTitleBatch() else {
            Issue.record("expected initial prompt to publish title-only batch")
            return
        }

        #expect(batch.appended.isEmpty)
        #expect(batch.updated.isEmpty)
        #expect(batch.stateUpdates.isEmpty)
        #expect(batch.discoveredTitle == "Explain the release plan")
    }

    @Test("Codex thread_name_updated in the initial backfill publishes a title update batch")
    func codexInitialThreadNameUpdatedPublishesTitleUpdateBatch() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-codex-thread-name-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("rollout-thread-name.jsonl", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try (codexLine(
            type: "event_msg",
            payload: [
                "type": "thread_name_updated",
                "thread_name": "Codex Companion Task: Fix auth",
            ],
            timestamp: "2026-06-19T10:00:00.000Z"
        ) + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "codex-thread-name-session",
            agentKind: .codex,
            path: transcript.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        await tailer.stop()

        guard let batch = await collector.firstTitleUpdateBatch() else {
            Issue.record("expected thread_name_updated to publish title update batch")
            return
        }

        #expect(batch.appended.isEmpty)
        #expect(batch.updated.isEmpty)
        #expect(batch.stateUpdates.isEmpty)
        #expect(batch.discoveredTitle == nil)
        #expect(batch.titleUpdate == "Codex Companion Task: Fix auth")
    }

    @Test("Codex task_started in the initial backfill publishes a state-only batch")
    func codexInitialTaskStartedPublishesStateOnlyBatch() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-codex-initial-state-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("rollout-initial-state.jsonl", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let timestamp = "2026-06-19T10:00:00.000Z"
        try (codexLine(
            type: "event_msg",
            payload: ["type": "task_started", "turn_id": "turn-initial"],
            timestamp: timestamp
        ) + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "codex-initial-state-session",
            agentKind: .codex,
            path: transcript.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        await tailer.stop()

        guard let batch = await collector.firstStateUpdateBatch() else {
            Issue.record("expected initial task_started to publish state-only batch")
            return
        }

        let expectedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(timestamp)
        #expect(batch.appended.isEmpty)
        #expect(batch.updated.isEmpty)
        #expect(batch.stateUpdates == [
            ChatTranscriptStateUpdate(kind: .working, seq: 0, timestamp: expectedTimestamp),
        ])
    }

    @Test("Initial pending transcript input wins over task lifecycle updates")
    func initialPendingInputWinsOverLifecycleUpdates() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-codex-initial-input-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("rollout-initial-input.jsonl", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let startTimestamp = "2026-06-19T10:00:00.000Z"
        let inputTimestamp = "2026-06-19T10:00:01.000Z"
        try [
            codexLine(
                type: "event_msg",
                payload: ["type": "task_started", "turn_id": "turn-input"],
                timestamp: startTimestamp
            ),
            codexLine(
                type: "event_msg",
                payload: [
                    "type": "exec_approval_request",
                    "call_id": "approval-initial",
                    "command": "git status",
                ],
                timestamp: inputTimestamp
            ),
        ].joined(separator: "\n").appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "codex-initial-input-session",
            agentKind: .codex,
            path: transcript.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        await tailer.stop()

        guard let batch = await collector.firstStateUpdateBatch() else {
            Issue.record("expected initial pending input to publish state-only batch")
            return
        }

        let expectedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(inputTimestamp)
        #expect(batch.appended.isEmpty)
        #expect(batch.updated.isEmpty)
        #expect(batch.stateUpdates == [
            ChatTranscriptStateUpdate(kind: .needsInput, seq: 1, timestamp: expectedTimestamp),
        ])
    }

    @Test("Codex task lifecycle events publish state-only live batches")
    func codexTaskLifecycleEventsPublishStateOnlyBatches() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-codex-state-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("rollout-state.jsonl", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try "".write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "codex-state-session",
            agentKind: .codex,
            path: transcript.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        defer { Task { await tailer.stop() } }
        await Task.yield()

        let timestamp = "2026-06-19T10:00:01.000Z"
        try appendLine(
            codexLine(
                type: "event_msg",
                payload: ["type": "task_started", "turn_id": "turn-1"],
                timestamp: timestamp
            ),
            to: transcript
        )

        guard let batch = await waitForStateUpdateBatch(in: collector) else {
            Issue.record("expected a state-only batch from task_started")
            return
        }

        let expectedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(timestamp)
        #expect(batch.appended.isEmpty)
        #expect(batch.updated.isEmpty)
        #expect(batch.stateUpdates == [
            ChatTranscriptStateUpdate(kind: .working, seq: 0, timestamp: expectedTimestamp),
        ])
    }

    @Test("Antigravity role task_started publishes state-only live batches")
    func antigravityRoleTaskStartedPublishesStateOnlyBatches() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-antigravity-state-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("agy-state.jsonl", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try "".write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "antigravity-state-session",
            agentKind: .antigravity,
            path: transcript.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        defer { Task { await tailer.stop() } }
        await Task.yield()

        let timestamp = "2026-06-19T10:00:02.000Z"
        try appendLine(
            antigravityLine([
                "role": "event",
                "name": "task_started",
                "timestamp": timestamp,
                "turn_id": "turn-1",
            ]),
            to: transcript
        )

        guard let batch = await waitForStateUpdateBatch(in: collector) else {
            Issue.record("expected a state-only batch from Antigravity task_started")
            return
        }

        let expectedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(timestamp)
        #expect(batch.appended.isEmpty)
        #expect(batch.updated.isEmpty)
        #expect(batch.stateUpdates == [
            ChatTranscriptStateUpdate(kind: .working, seq: 0, timestamp: expectedTimestamp),
        ])
    }

    @Test("Antigravity single-object JSON transcripts load through the tailer")
    func antigravitySessionJSONInitialHistory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-antigravity-json-\(UUID().uuidString)", isDirectory: true)
        let transcript = root.appendingPathComponent("session-2026-06-19T10-00-json.json", isDirectory: false)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "sessionId": "json-session",
          "projectHash": "project-hash",
          "messages": [
            {
              "type": "user",
              "id": "user-1",
              "timestamp": "2026-06-19T10:00:01Z",
              "content": "Read the session JSON"
            },
            {
              "type": "gemini",
              "id": "agent-1",
              "timestamp": "2026-06-19T10:00:02Z",
              "content": "I found the messages array.",
              "toolCalls": [
                {
                  "id": "tool-1",
                  "name": "list_directory",
                  "args": { "path": "." },
                  "status": "success",
                  "result": []
                }
              ]
            }
          ]
        }
        """.write(to: transcript, atomically: true, encoding: .utf8)

        let tailer = AgentChatTranscriptTailer(
            sessionID: "json-session",
            agentKind: .antigravity,
            path: transcript.path
        ) { _ in }

        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 10)
        await tailer.stop()

        #expect(page.hasMore == false)
        #expect(page.messages.count == 3)
        #expect(page.messages[0].id == "user-1")
        #expect(page.messages[0].kind == .prose(ChatProse(text: "Read the session JSON")))
        #expect(page.messages[1].id == "agent-1")
        #expect(page.messages[1].kind == .prose(ChatProse(text: "I found the messages array.")))
        #expect(page.messages[2].id == "tool-1")
        #expect(page.messages[2].kind == .toolUse(ChatToolUse(
            toolName: "list_directory",
            summary: "list_directory .",
            inputDetail: #"{"path":"."}"#,
            output: nil,
            status: .succeeded
        )))
        #expect(await tailer.title == "Read the session JSON")
    }

    @Test("Antigravity generated messages directories load through the tailer")
    func antigravityGeneratedMessagesDirectoryInitialHistory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("agentchat-tailer-antigravity-messages-\(UUID().uuidString)", isDirectory: true)
        let messages = root.appendingPathComponent("messages", isDirectory: true)
        try fm.createDirectory(at: messages, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let readMetadata = messages.appendingPathComponent("read.json", isDirectory: false)
        let cursorMetadata = messages.appendingPathComponent("cursor.json", isDirectory: false)
        try #"{"agent-message":true}"#.write(to: readMetadata, atomically: true, encoding: .utf8)
        try #"{"last_read_unix_nano":1780990889191580000}"#
            .write(to: cursorMetadata, atomically: true, encoding: .utf8)
        for metadata in [readMetadata, cursorMetadata] {
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: metadata.path
            )
        }

        try writeGeneratedMessageJSON(
            id: "agent-message",
            sender: "brain-session/task-1",
            recipient: "brain-session",
            timestamp: "2026-06-19T10:00:02Z",
            content: "I found the generated messages.",
            to: messages.appendingPathComponent("b-agent.json", isDirectory: false)
        )
        try writeGeneratedMessageJSON(
            id: "hidden-message",
            sender: "brain-session/task-1",
            recipient: "brain-session",
            timestamp: "2026-06-19T10:00:01.500Z",
            content: "Internal scratchpad",
            hideFromUser: true,
            to: messages.appendingPathComponent("c-hidden.json", isDirectory: false)
        )
        try writeGeneratedMessageJSON(
            id: "user-message",
            sender: "brain-session",
            recipient: "brain-session/task-1",
            timestamp: "2026-06-19T10:00:01Z",
            content: "Read the generated messages",
            to: messages.appendingPathComponent("a-user.json", isDirectory: false)
        )

        let tailer = AgentChatTranscriptTailer(
            sessionID: "brain-session/task-1",
            agentKind: .antigravity,
            path: messages.path
        ) { _ in }

        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 10)
        await tailer.stop()

        #expect(page.hasMore == false)
        #expect(page.messages.map(\.id) == ["user-message", "agent-message"])
        #expect(page.messages.map(\.seq) == [0, 1])
        #expect(page.messages[0].role == .user)
        #expect(page.messages[0].kind == .prose(ChatProse(text: "Read the generated messages")))
        #expect(page.messages[1].role == .agent)
        #expect(page.messages[1].kind == .prose(ChatProse(text: "I found the generated messages.")))
        #expect(await tailer.title == "Read the generated messages")
    }

    @Test("Antigravity generated command input prompts publish needsInput initial state")
    func antigravityGeneratedCommandInputPromptInitialState() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(
                "agentchat-tailer-antigravity-command-input-\(UUID().uuidString)",
                isDirectory: true
            )
        let messages = root.appendingPathComponent("messages", isDirectory: true)
        try fm.createDirectory(at: messages, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try writeGeneratedMessageJSON(
            id: "message-command-input",
            sender: "brain-session/task-1881",
            recipient: "brain-session",
            timestamp: "2026-06-19T11:10:00Z",
            content: """
            The command output has stabilized for 5s. The output delta since last check is:

            Build complete.

            The command appears to be waiting for input: Enter a control key.
            """,
            renderTitle: "Relaunch app: Command may require input",
            to: messages.appendingPathComponent("input.json", isDirectory: false)
        )

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "brain-session/task-1881",
            agentKind: .antigravity,
            path: messages.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 10)
        let batch = await waitForStateUpdateBatch(in: collector)
        await tailer.stop()

        #expect(page.messages.count == 1)
        guard let message = page.messages.first else { return }
        #expect(message.kind == .terminal(ChatTerminalCapture(
            command: "Relaunch app",
            output: """
            The command output has stabilized for 5s. The output delta since last check is:

            Build complete.

            The command appears to be waiting for input: Enter a control key.
            """,
            isRunning: true
        )))
        let stateUpdate = try #require(batch?.stateUpdates.first)
        #expect(stateUpdate.kind == .needsInput)
        #expect(stateUpdate.seq == 0)
        #expect(stateUpdate.timestamp == Date(timeIntervalSince1970: 1_781_867_400))
    }

    @Test("Antigravity generated command result updates initial directory history")
    func antigravityGeneratedCommandResultUpdatesInitialDirectoryHistory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(
                "agentchat-tailer-antigravity-command-result-initial-\(UUID().uuidString)",
                isDirectory: true
            )
        let messages = root.appendingPathComponent("messages", isDirectory: true)
        try fm.createDirectory(at: messages, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try writeGeneratedCommandInput(
            to: messages.appendingPathComponent("input.json", isDirectory: false)
        )
        try writeGeneratedCommandResult(
            to: messages.appendingPathComponent("result.json", isDirectory: false)
        )

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "brain-session/task-1881",
            agentKind: .antigravity,
            path: messages.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 10)
        let batch = await waitForStateUpdateBatch(in: collector)
        await tailer.stop()

        #expect(page.messages.count == 1)
        guard case .terminal(let terminal) = page.messages.first?.kind else {
            Issue.record("expected terminal message")
            return
        }
        #expect(terminal.command == "Relaunch app")
        #expect(terminal.output == "Build complete.\nApp relaunched.")
        #expect(terminal.exitCode == 0)
        #expect(terminal.isRunning == false)
        #expect(batch?.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 1,
                timestamp: Date(timeIntervalSince1970: 1_781_867_408)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 1,
                timestamp: Date(timeIntervalSince1970: 1_781_867_408)
            ),
        ])
    }

    @Test("Antigravity generated command result publishes an update batch")
    func antigravityGeneratedCommandResultPublishesUpdateBatch() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(
                "agentchat-tailer-antigravity-command-result-live-\(UUID().uuidString)",
                isDirectory: true
            )
        let messages = root.appendingPathComponent("messages", isDirectory: true)
        try fm.createDirectory(at: messages, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try writeGeneratedCommandInput(
            to: messages.appendingPathComponent("input.json", isDirectory: false)
        )

        let collector = BatchCollector()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "brain-session/task-1881",
            agentKind: .antigravity,
            path: messages.path
        ) { batch in
            await collector.append(batch)
        }

        await tailer.start()
        defer { Task { await tailer.stop() } }
        _ = await waitForStateUpdateBatch(in: collector)

        try writeGeneratedCommandResult(
            to: messages.appendingPathComponent("result.json", isDirectory: false)
        )

        guard let batch = await waitForUpdatedBatch(in: collector) else {
            Issue.record("expected result file to publish an updated terminal batch")
            return
        }

        #expect(batch.appended.isEmpty)
        #expect(batch.updated.count == 1)
        guard case .terminal(let terminal) = batch.updated.first?.kind else {
            Issue.record("expected updated terminal")
            return
        }
        #expect(terminal.command == "Relaunch app")
        #expect(terminal.output == "Build complete.\nApp relaunched.")
        #expect(terminal.exitCode == 0)
        #expect(terminal.isRunning == false)
        #expect(batch.stateUpdates == [
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 1,
                timestamp: Date(timeIntervalSince1970: 1_781_867_408)
            ),
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 1,
                timestamp: Date(timeIntervalSince1970: 1_781_867_408)
            ),
        ])
    }

    private actor BatchCollector {
        private var batches: [AgentChatTranscriptTailer.Batch] = []

        func append(_ batch: AgentChatTranscriptTailer.Batch) {
            batches.append(batch)
        }

        func firstStateUpdateBatch() -> AgentChatTranscriptTailer.Batch? {
            batches.first { !$0.stateUpdates.isEmpty }
        }

        func firstTitleBatch() -> AgentChatTranscriptTailer.Batch? {
            batches.first { $0.discoveredTitle != nil }
        }

        func firstTitleUpdateBatch() -> AgentChatTranscriptTailer.Batch? {
            batches.first { $0.titleUpdate != nil }
        }

        func firstUpdatedBatch() -> AgentChatTranscriptTailer.Batch? {
            batches.first { !$0.updated.isEmpty }
        }
    }

    private func waitForStateUpdateBatch(
        in collector: BatchCollector,
        timeout: Duration = .seconds(3)
    ) async -> AgentChatTranscriptTailer.Batch? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let batch = await collector.firstStateUpdateBatch() {
                return batch
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func waitForUpdatedBatch(
        in collector: BatchCollector,
        timeout: Duration = .seconds(3)
    ) async -> AgentChatTranscriptTailer.Batch? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let batch = await collector.firstUpdatedBatch() {
                return batch
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func codexLine(
        type: String,
        payload: [String: Any],
        timestamp: String
    ) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp,
            "type": type,
            "payload": payload,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func antigravityLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func writeGeneratedMessageJSON(
        id: String,
        sender: String,
        recipient: String,
        timestamp: String,
        content: String,
        hideFromUser: Bool = false,
        renderTitle: String? = nil,
        to url: URL
    ) throws {
        var object: [String: Any] = [
            "content": content,
            "id": id,
            "recipient": recipient,
            "sender": sender,
            "timestamp": timestamp,
        ]
        if hideFromUser {
            object["hideFromUser"] = true
        }
        if let renderTitle {
            object["renderDetails"] = ["messageTitle": renderTitle]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url)
    }

    private func writeGeneratedCommandInput(to url: URL) throws {
        try writeGeneratedMessageJSON(
            id: "message-command-input",
            sender: "brain-session/task-1881",
            recipient: "brain-session",
            timestamp: "2026-06-19T11:10:00Z",
            content: """
            The command output has stabilized for 5s. The output delta since last check is:

            Build complete.

            The command appears to be waiting for input: Enter a control key.
            """,
            renderTitle: "Relaunch app: Command may require input",
            to: url
        )
    }

    private func writeGeneratedCommandResult(to url: URL) throws {
        try writeGeneratedMessageJSON(
            id: "message-command-result",
            sender: "brain-session/task-1881",
            recipient: "brain-session",
            timestamp: "2026-06-19T11:10:08Z",
            content: """
            Task id "brain-session/task-1881" finished with result:

                            The command completed successfully.
                            Output:
                            Build complete.
                            App relaunched.
            """,
            renderTitle: "Relaunch app finished",
            to: url
        )
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
