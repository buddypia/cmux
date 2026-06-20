internal import CMUXMobileCore
import Foundation

extension MobileCoreRPCSession {
    func abandonConnectionTask(_ connecting: ConnectingTask) async {
        await connectAttemptRegistry.markAbandoned(lease: connecting.lease)
        startAbandonedConnectionCleanup(
            task: connecting.task,
            lease: connecting.lease,
            tracksRouteGate: true
        )
    }

    func startAbandonedConnectionCleanup(
        task: Task<any CmxByteTransport, any Error>,
        lease: MobileRPCConnectAttemptLease?,
        tracksRouteGate: Bool
    ) {
        Task.detached { [connectAttemptRegistry] in
            let taskTimeout = RPCTaskTimeout()
            let cleaner = MobileRPCAbandonedConnectCleaner(
                registry: connectAttemptRegistry,
                lease: lease,
                tracksRouteGate: tracksRouteGate
            )
            do {
                let candidate = try await taskTimeout.value(
                    task,
                    timeoutNanoseconds: Self.abandonedConnectCleanupTimeoutNanoseconds
                )
                await candidate.close()
                await cleaner.clearFinishedConnectGate()
            } catch MobileShellConnectionError.requestTimedOut {
                if tracksRouteGate {
                    await connectAttemptRegistry.clearTimedOutAbandonedCleanup(lease: lease)
                }
                cleaner.closeLateAbandonedCandidate(
                    task: task,
                    timeoutNanoseconds: Self.lateAbandonedConnectCloseTimeoutNanoseconds
                )
            } catch {
                await cleaner.clearFinishedConnectGate()
            }
        }
    }
}

private struct MobileRPCAbandonedConnectCleaner: Sendable {
    let registry: MobileRPCConnectAttemptRegistry
    let lease: MobileRPCConnectAttemptLease?
    let tracksRouteGate: Bool

    func closeLateAbandonedCandidate(
        task: Task<any CmxByteTransport, any Error>,
        timeoutNanoseconds: UInt64
    ) {
        Task.detached {
            let taskTimeout = RPCTaskTimeout()
            do {
                let candidate = try await taskTimeout.value(
                    task,
                    timeoutNanoseconds: timeoutNanoseconds
                )
                await candidate.close()
                await clearFinishedConnectGate()
            } catch {
            }
        }
    }

    func clearFinishedConnectGate() async {
        guard tracksRouteGate else { return }
        await registry.clearFinishedConnect(lease: lease)
    }
}
