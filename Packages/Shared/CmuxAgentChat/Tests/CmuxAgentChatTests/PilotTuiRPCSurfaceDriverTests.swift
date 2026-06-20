import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("PilotTuiRPCSurfaceDriver")
struct PilotTuiRPCSurfaceDriverTests {
    @Test("readScreen maps to surface.read_text with target selectors and scrollback lines")
    func readScreen() async throws {
        let transport = RecordingPilotRPCTransport(responses: [
            "surface.read_text": ["text": .string("menu text")],
        ])
        let driver = PilotTuiRPCSurfaceDriver(
            target: PilotTuiSurfaceTarget(
                windowID: "win-1",
                workspaceID: "ws-1",
                surfaceID: "sf-1"
            ),
            transport: transport.send
        )

        let text = try await driver.readScreen(options: PilotTuiSurfaceReadOptions(lines: 80))

        #expect(text == "menu text")
        #expect(await transport.calls == [
            PilotRPCCall(method: "surface.read_text", params: [
                "window_id": .string("win-1"),
                "workspace_id": .string("ws-1"),
                "surface_id": .string("sf-1"),
                "lines": .int(80),
                "scrollback": .bool(true),
            ]),
        ])
    }

    @Test("sendKey maps canonical Pilot keys to surface.send_key")
    func sendKey() async throws {
        let transport = RecordingPilotRPCTransport()
        let driver = PilotTuiRPCSurfaceDriver(
            target: PilotTuiSurfaceTarget(workspaceID: "ws-1", surfaceID: "sf-1"),
            transport: transport.send
        )

        try await driver.sendKey(.escape)

        #expect(await transport.calls == [
            PilotRPCCall(method: "surface.send_key", params: [
                "workspace_id": .string("ws-1"),
                "surface_id": .string("sf-1"),
                "key": .string("escape"),
            ]),
        ])
    }

    @Test("sendText maps to surface.send_text without adding implicit newlines")
    func sendText() async throws {
        let transport = RecordingPilotRPCTransport()
        let driver = PilotTuiRPCSurfaceDriver(transport: transport.send)

        try await driver.sendText("continue\n")

        #expect(await transport.calls == [
            PilotRPCCall(method: "surface.send_text", params: [
                "text": .string("continue\n"),
            ]),
        ])
    }

    @Test("notify maps to notification.create and carries target selectors")
    func notify() async throws {
        let transport = RecordingPilotRPCTransport()
        let driver = PilotTuiRPCSurfaceDriver(
            target: PilotTuiSurfaceTarget(workspaceID: "ws-1", surfaceID: "sf-1"),
            transport: transport.send
        )

        try await driver.notify(PilotTuiSurfaceNotification(title: "Pilot Mode", body: "Done"))

        #expect(await transport.calls == [
            PilotRPCCall(method: "notification.create", params: [
                "workspace_id": .string("ws-1"),
                "surface_id": .string("sf-1"),
                "title": .string("Pilot Mode"),
                "body": .string("Done"),
            ]),
        ])
    }

    @Test("RPC values bridge to JSON objects for SocketClient params")
    func jsonObjectDictionary() throws {
        let params = PilotTuiRPCValue.jsonObjectDictionary(from: [
            "key": .string("enter"),
            "lines": .int(120),
            "scrollback": .bool(true),
            "empty": .null,
        ])

        #expect(JSONSerialization.isValidJSONObject(params))
        #expect(params["key"] as? String == "enter")
        #expect(params["lines"] as? Int == 120)
        #expect(params["scrollback"] as? Bool == true)
        #expect(params["empty"] is NSNull)
    }

    @Test("JSON objects bridge back to RPC values and skip unsupported payloads")
    func rpcDictionaryFromJSONObjects() {
        let values = PilotTuiRPCValue.dictionary(from: [
            "text": "screen",
            "lines": NSNumber(value: 80),
            "scrollback": NSNumber(value: true),
            "empty": NSNull(),
            "fraction": NSNumber(value: 1.25),
            "object": ["unsupported": true],
        ])

        #expect(values == [
            "text": .string("screen"),
            "lines": .int(80),
            "scrollback": .bool(true),
            "empty": .null,
        ])
    }

    @Test("auto selector can drive the RPC surface driver end to end")
    func autoSelectorIntegration() async throws {
        let screen = [
            "Choose:",
            "❯ 1. first",
            "  2. second",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ].joined(separator: "\n")
        let transport = RecordingPilotRPCTransport(responses: [
            "surface.read_text": ["text": .string(screen)],
        ])
        let driver = PilotTuiRPCSurfaceDriver(
            target: PilotTuiSurfaceTarget(workspaceID: "ws-1", surfaceID: "sf-1"),
            transport: transport.send
        )

        let result = try await PilotTuiAutoSelector.run(
            driver: driver,
            request: PilotTuiAutoSelectRequest(targetNumber: 2, confidence: 0.9)
        )

        #expect(result == .selected(targetNumber: 2, keys: [.down, .enter]))
        #expect(await transport.calls == [
            PilotRPCCall(method: "surface.read_text", params: [
                "workspace_id": .string("ws-1"),
                "surface_id": .string("sf-1"),
                "lines": .int(120),
                "scrollback": .bool(true),
            ]),
            PilotRPCCall(method: "surface.send_key", params: [
                "workspace_id": .string("ws-1"),
                "surface_id": .string("sf-1"),
                "key": .string("down"),
            ]),
            PilotRPCCall(method: "surface.send_key", params: [
                "workspace_id": .string("ws-1"),
                "surface_id": .string("sf-1"),
                "key": .string("enter"),
            ]),
        ])
    }
}

private struct PilotRPCCall: Sendable, Equatable {
    let method: String
    let params: [String: PilotTuiRPCValue]
}

private actor RecordingPilotRPCTransport {
    private var recordedCalls: [PilotRPCCall] = []
    private let responses: [String: [String: PilotTuiRPCValue]]

    init(responses: [String: [String: PilotTuiRPCValue]] = [:]) {
        self.responses = responses
    }

    var calls: [PilotRPCCall] {
        recordedCalls
    }

    func send(
        method: String,
        params: [String: PilotTuiRPCValue]
    ) async throws -> [String: PilotTuiRPCValue] {
        recordedCalls.append(PilotRPCCall(method: method, params: params))
        return responses[method] ?? [:]
    }
}
