import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatTranscriptStateSignal")
struct ChatTranscriptStateSignalTests {
    private static let baseTime = Date(timeIntervalSince1970: 1_781_006_400)

    @Test("pending permission requests require input")
    func pendingPermissionRequiresInput() {
        let messages = [
            Self.message(
                seq: 1,
                kind: .permissionRequest(
                    ChatPermissionRequest(title: "Antigravity wants to run:", subject: "npm test")
                )
            ),
        ]

        #expect(ChatTranscriptStateSignal.needsInputTimestamp(in: messages) == Self.baseTime.addingTimeInterval(1))
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: messages) == nil)
    }

    @Test("pending questions require input")
    func pendingQuestionRequiresInput() {
        let messages = [
            Self.message(
                seq: 2,
                kind: .question(
                    ChatQuestion(
                        prompt: "Continue?",
                        options: [ChatQuestion.Option(label: "Yes")]
                    )
                )
            ),
        ]

        #expect(ChatTranscriptStateSignal.needsInputTimestamp(in: messages) == Self.baseTime.addingTimeInterval(2))
    }

    @Test("resolved permission requests and questions clear input waits")
    func resolvedInputClearsWait() {
        let messages = [
            Self.message(
                seq: 3,
                kind: .permissionRequest(
                    ChatPermissionRequest(
                        title: "Codex wants to run:",
                        subject: "git status",
                        resolution: .approved
                    )
                )
            ),
            Self.message(
                seq: 4,
                kind: .question(
                    ChatQuestion(
                        prompt: "Pick one",
                        options: [ChatQuestion.Option(label: "A")],
                        selectedOptionLabel: "A"
                    )
                )
            ),
            Self.message(
                seq: 5,
                kind: .question(
                    ChatQuestion(
                        prompt: "Continue?",
                        options: [ChatQuestion.Option(label: "Yes")],
                        resolution: .expired
                    )
                )
            ),
        ]

        #expect(ChatTranscriptStateSignal.needsInputTimestamp(in: messages) == nil)
        #expect(ChatTranscriptStateSignal.resolvedInputTimestamp(in: messages) == Self.baseTime.addingTimeInterval(5))
    }

    @Test("running tool and terminal rows mark transcript working")
    func runningRowsMarkWorking() {
        let messages = [
            Self.message(
                seq: 5,
                kind: .toolUse(ChatToolUse(toolName: "Read", summary: "Read file"))
            ),
            Self.message(
                seq: 6,
                kind: .terminal(ChatTerminalCapture(command: "npm test", isRunning: true))
            ),
        ]

        #expect(ChatTranscriptStateSignal.workingTimestamp(in: messages) == Self.baseTime.addingTimeInterval(6))
        #expect(ChatTranscriptStateSignal.completedAssistantTurnTimestamp(in: messages) == nil)
    }

    @Test("completed tool and terminal rows do not mark transcript working")
    func completedRowsDoNotMarkWorking() {
        let messages = [
            Self.message(
                seq: 7,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "Read",
                        summary: "Read file",
                        output: "done",
                        status: .succeeded
                    )
                )
            ),
            Self.message(
                seq: 8,
                kind: .terminal(
                    ChatTerminalCapture(
                        command: "npm test",
                        exitCode: 0,
                        isRunning: false
                    )
                )
            ),
        ]

        #expect(ChatTranscriptStateSignal.workingTimestamp(in: messages) == nil)
    }

    @Test("completed tool and terminal rows mark transcript work resolved")
    func completedRowsMarkWorkResolved() {
        let messages = [
            Self.message(
                seq: 9,
                kind: .toolUse(
                    ChatToolUse(
                        toolName: "Read",
                        summary: "Read file",
                        output: "done",
                        status: .succeeded
                    )
                )
            ),
            Self.message(
                seq: 10,
                kind: .terminal(
                    ChatTerminalCapture(
                        command: "npm test",
                        exitCode: 0,
                        isRunning: false
                    )
                )
            ),
        ]

        #expect(ChatTranscriptStateSignal.completedWorkTimestamp(in: messages) == Self.baseTime.addingTimeInterval(10))
    }

    @Test("completed assistant prose ignores status and attachment rows")
    func completedAssistantTurnTimestamp() {
        let messages = [
            Self.message(
                seq: 0,
                kind: .status(ChatStatusTransition(event: .sessionStarted, detail: "Started"))
            ),
            Self.message(seq: 5, kind: .prose(ChatProse(text: "Done"))),
        ]

        #expect(ChatTranscriptStateSignal.completedAssistantTurnTimestamp(in: messages) == Self.baseTime.addingTimeInterval(5))
    }

    @Test("tool and pending input rows keep assistant turn incomplete")
    func actionableRowsKeepAssistantTurnIncomplete() {
        #expect(
            ChatTranscriptStateSignal.completedAssistantTurnTimestamp(
                in: [
                    Self.message(seq: 6, kind: .prose(ChatProse(text: "Need approval"))),
                    Self.message(
                        seq: 7,
                        kind: .permissionRequest(
                            ChatPermissionRequest(title: "Codex wants to run:", subject: "npm test")
                        )
                    ),
                ]
            ) == nil
        )
        #expect(
            ChatTranscriptStateSignal.completedAssistantTurnTimestamp(
                in: [
                    Self.message(seq: 8, kind: .prose(ChatProse(text: "Need an answer"))),
                    Self.message(
                        seq: 9,
                        kind: .question(
                            ChatQuestion(
                                prompt: "Continue?",
                                options: [ChatQuestion.Option(label: "Yes")]
                            )
                        )
                    ),
                ]
            ) == nil
        )
    }

    @Test("resolved input rows do not keep assistant turn incomplete")
    func resolvedInputRowsDoNotKeepAssistantTurnIncomplete() {
        let messages = [
            Self.message(seq: 10, kind: .prose(ChatProse(text: "Done"))),
            Self.message(
                seq: 11,
                kind: .permissionRequest(
                    ChatPermissionRequest(
                        title: "Codex wants to run:",
                        subject: "npm test",
                        resolution: .approved
                    )
                )
            ),
            Self.message(
                seq: 12,
                kind: .question(
                    ChatQuestion(
                        prompt: "Continue?",
                        options: [ChatQuestion.Option(label: "Yes")],
                        resolution: .expired
                    )
                )
            ),
        ]

        #expect(
            ChatTranscriptStateSignal.completedAssistantTurnTimestamp(in: messages)
                == Self.baseTime.addingTimeInterval(10)
        )
    }

    @Test("state updates sort in transcript application order")
    func stateUpdatesSortInTranscriptApplicationOrder() {
        let updates = [
            ChatTranscriptStateUpdate(
                kind: .idle,
                seq: 3,
                timestamp: Self.baseTime.addingTimeInterval(30)
            ),
            ChatTranscriptStateUpdate(
                kind: .needsInput,
                seq: 1,
                timestamp: Self.baseTime.addingTimeInterval(10)
            ),
            ChatTranscriptStateUpdate(
                kind: .inputResolved,
                seq: 2,
                timestamp: Self.baseTime.addingTimeInterval(20)
            ),
            ChatTranscriptStateUpdate(
                kind: .working,
                seq: 2,
                timestamp: Self.baseTime.addingTimeInterval(19)
            ),
        ]

        #expect(ChatTranscriptStateUpdate.applicationOrder(updates).map(\.kind) == [
            .needsInput,
            .working,
            .inputResolved,
            .idle,
        ])
        #expect(ChatTranscriptStateUpdate.latest(in: updates)?.kind == .idle)
    }

    @Test("state updates with identical seq and timestamp use semantic order")
    func stateUpdatesWithIdenticalSeqAndTimestampUseSemanticOrder() {
        let timestamp = Self.baseTime.addingTimeInterval(40)
        let updates = [
            ChatTranscriptStateUpdate(kind: .idle, seq: 4, timestamp: timestamp),
            ChatTranscriptStateUpdate(kind: .inputResolved, seq: 4, timestamp: timestamp),
            ChatTranscriptStateUpdate(kind: .needsInput, seq: 4, timestamp: timestamp),
            ChatTranscriptStateUpdate(kind: .working, seq: 4, timestamp: timestamp),
        ]

        #expect(ChatTranscriptStateUpdate.applicationOrder(updates).map(\.kind) == [
            .working,
            .needsInput,
            .inputResolved,
            .idle,
        ])
        #expect(ChatTranscriptStateUpdate.latest(in: updates)?.kind == .idle)
    }

    @Test("initial state prefers pending input over completed work")
    func initialStatePrefersPendingInputOverCompletedWork() {
        let updates = ChatTranscriptStateSignal.initialStateUpdates(
            messages: [
                Self.message(
                    seq: 20,
                    kind: .question(
                        ChatQuestion(
                            prompt: "Continue?",
                            options: [ChatQuestion.Option(label: "Yes")]
                        )
                    )
                ),
                Self.message(
                    seq: 21,
                    kind: .terminal(
                        ChatTerminalCapture(
                            command: "npm test",
                            exitCode: 0,
                            isRunning: false
                        )
                    )
                ),
            ],
            stateUpdates: [
                ChatTranscriptStateUpdate(
                    kind: .idle,
                    seq: 21,
                    timestamp: Self.baseTime.addingTimeInterval(21)
                ),
            ],
            hasPendingTranscriptWork: false
        )

        #expect(updates.map(\.kind) == [.needsInput])
        #expect(updates.first?.seq == 20)
    }

    @Test("initial resolved input clears wait before idle")
    func initialResolvedInputClearsWaitBeforeIdle() {
        let updates = ChatTranscriptStateSignal.initialStateUpdates(
            messages: [
                Self.message(
                    seq: 30,
                    kind: .question(
                        ChatQuestion(
                            prompt: "Continue?",
                            options: [ChatQuestion.Option(label: "Yes")],
                            resolution: .expired
                        )
                    )
                ),
                Self.message(
                    seq: 31,
                    kind: .terminal(
                        ChatTerminalCapture(
                            command: "npm test",
                            exitCode: 0,
                            isRunning: false
                        )
                    )
                ),
            ],
            stateUpdates: [],
            hasPendingTranscriptWork: false
        )

        #expect(updates.map(\.kind) == [.inputResolved, .idle])
        #expect(updates.map(\.seq) == [30, 31])
    }

    @Test("initial resolved input is retained without work transition")
    func initialResolvedInputIsRetainedWithoutWorkTransition() {
        let updates = ChatTranscriptStateSignal.initialStateUpdates(
            messages: [
                Self.message(
                    seq: 32,
                    kind: .permissionRequest(
                        ChatPermissionRequest(
                            title: "Codex wants to run:",
                            subject: "npm test",
                            resolution: .denied
                        )
                    )
                ),
            ],
            stateUpdates: [],
            hasPendingTranscriptWork: false
        )

        #expect(updates.map(\.kind) == [.inputResolved])
        #expect(updates.first?.seq == 32)
    }

    @Test("initial resolved row supersedes stale needs input update")
    func initialResolvedRowSupersedesStaleNeedsInputUpdate() {
        let updates = ChatTranscriptStateSignal.initialStateUpdates(
            messages: [
                Self.message(
                    seq: 35,
                    kind: .question(
                        ChatQuestion(
                            prompt: "Continue?",
                            options: [ChatQuestion.Option(label: "Yes")],
                            selectedOptionLabel: "Yes"
                        )
                    )
                ),
            ],
            stateUpdates: [
                ChatTranscriptStateUpdate(
                    kind: .needsInput,
                    seq: 34,
                    timestamp: Self.baseTime.addingTimeInterval(34)
                ),
            ],
            hasPendingTranscriptWork: false
        )

        #expect(updates.map(\.kind) == [.inputResolved])
        #expect(updates.first?.seq == 35)
    }

    @Test("initial state preserves generated resolution order")
    func initialStatePreservesGeneratedResolutionOrder() {
        let timestamp = Self.baseTime.addingTimeInterval(41)
        let updates = ChatTranscriptStateSignal.initialStateUpdates(
            messages: [],
            stateUpdates: [
                ChatTranscriptStateUpdate(
                    kind: .needsInput,
                    seq: 40,
                    timestamp: Self.baseTime.addingTimeInterval(40)
                ),
                ChatTranscriptStateUpdate(kind: .inputResolved, seq: 41, timestamp: timestamp),
                ChatTranscriptStateUpdate(kind: .idle, seq: 41, timestamp: timestamp),
            ],
            hasPendingTranscriptWork: false
        )

        #expect(updates.map(\.kind) == [.inputResolved, .idle])
        #expect(updates.map(\.seq) == [41, 41])
    }

    private static func message(seq: Int, role: ChatRole = .agent, kind: ChatMessageKind) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: role,
            timestamp: baseTime.addingTimeInterval(TimeInterval(seq)),
            kind: kind
        )
    }
}
