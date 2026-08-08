import Foundation
import Testing
@testable import CmuxControlSocket

/// `feed.pilot.status` / `feed.pilot.disable` scope handling.
///
/// The payload shape is the app's business; what the coordinator owns is which
/// switch a request is aimed at, and that is where a mistake is dangerous:
/// silently widening a *disable* from one tab to the whole app turns a narrow
/// request into a global one.
@MainActor
@Suite("ControlCommandCoordinator Pilot Mode")
struct ControlCommandCoordinatorPilotTests {
    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .string("1"), method: method, params: params)
    }

    private func coordinator() -> (ControlCommandCoordinator, FakePilotControlCommandContext) {
        let context = FakePilotControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    @Test("No surface means the global switch")
    func absentSurfaceIsGlobal() {
        let (coordinator, context) = self.coordinator()

        _ = coordinator.handleFeed(request("feed.pilot.status"))
        #expect(context.statusCalls == [nil])

        _ = coordinator.handleFeed(request("feed.pilot.disable"))
        #expect(context.disableCalls == [nil])
    }

    @Test("A surface uuid scopes the request to that tab")
    func surfaceScopesRequest() {
        let (coordinator, context) = self.coordinator()
        let surfaceID = UUID()

        _ = coordinator.handleFeed(
            request("feed.pilot.status", ["surface": .string(surfaceID.uuidString)])
        )
        #expect(context.statusCalls == [surfaceID])

        // Surrounding whitespace is a shell artifact, not a different tab.
        _ = coordinator.handleFeed(
            request("feed.pilot.disable", ["surface": .string("  \(surfaceID.uuidString)\n")])
        )
        #expect(context.disableCalls == [surfaceID])
    }

    @Test("An unparseable surface is rejected, never widened to global")
    func invalidSurfaceIsRejected() {
        let (coordinator, context) = self.coordinator()

        for bad in ["surface:1", "", "not-a-uuid"] {
            guard case .err(let code, let message, _)? = coordinator.handleFeed(
                request("feed.pilot.disable", ["surface": .string(bad)])
            ) else {
                Issue.record("`surface: \(bad)` must be rejected")
                continue
            }
            #expect(code == "invalid_params")
            #expect(message.contains("surface must be a surface UUID"))
        }
        // The whole point: nothing was disabled on the way to those errors.
        #expect(context.disableCalls.isEmpty)
    }

    @Test("There is no enable verb on the wire")
    func noEnableMethod() {
        let (coordinator, _) = self.coordinator()
        // An agent in a cmux terminal holds the socket credentials, so an enable
        // method would let it grant itself auto-approval.
        #expect(coordinator.handleFeed(request("feed.pilot.enable")) == nil)
        #expect(coordinator.handleFeed(request("feed.pilot.set")) == nil)
    }
}

@MainActor
final class FakePilotControlCommandContext: ControlCommandContext {
    var statusCalls: [UUID?] = []
    var disableCalls: [UUID?] = []

    func controlFeedPilotStatus(surfaceID: UUID?) -> JSONValue {
        statusCalls.append(surfaceID)
        return .object(["enabled": .bool(false)])
    }

    func controlFeedPilotDisable(surfaceID: UUID?) -> JSONValue {
        disableCalls.append(surfaceID)
        return .object(["enabled": .bool(false), "changed": .bool(true)])
    }

    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        MainActor.assumeIsolated { body(self) }
    }
}
