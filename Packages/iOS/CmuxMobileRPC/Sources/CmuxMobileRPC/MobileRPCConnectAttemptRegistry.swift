import Foundation

/// Tracks connection attempts for one owner.
///
/// `MobileCoreRPCSession` instances are short-lived around pairing and route
/// retries. This actor lets a larger owner, such as `MobileShellComposite`,
/// reserve a route before connect starts, then release that exact reservation
/// when connect succeeds, fails, or its abandoned task cleanup finishes.
/// If cleanup gives up its retained task handle at the bounded cleanup deadline,
/// the registry allows only one bounded retry for that route; a second
/// still-stuck cleanup gates the route briefly, then clears on the next begin
/// attempt after the reset window. That keeps repeated scans from piling up
/// unclosed transports without making a stuck task permanently poison a route.
public actor MobileRPCConnectAttemptRegistry {
    private static let maximumAbandonedAttemptsBeforeHardGate = 2

    private let hardGateResetNanoseconds: UInt64
    private var activeLeaseIDs: [String: UUID] = [:]
    private var releasedLeaseIDs: [String: UUID] = [:]
    private var abandonedAttemptCounts: [String: Int] = [:]
    private var hardGateExpiresAt: [String: UInt64] = [:]

    /// Creates an empty registry.
    public init(hardGateResetNanoseconds: UInt64 = 30_000_000_000) {
        self.hardGateResetNanoseconds = hardGateResetNanoseconds
    }

    func beginConnect(key: String?) -> MobileRPCConnectAttemptLease? {
        guard let key else { return .untracked }
        expireHardGateIfNeeded(key: key)
        guard activeLeaseIDs[key] == nil else { return nil }
        let id = UUID()
        activeLeaseIDs[key] = id
        releasedLeaseIDs[key] = nil
        hardGateExpiresAt[key] = nil
        return MobileRPCConnectAttemptLease(key: key, id: id)
    }

    func markAbandoned(lease: MobileRPCConnectAttemptLease?) {
        guard let key = validKey(for: lease) else { return }
        abandonedAttemptCounts[key, default: 0] += 1
    }

    func clearFinishedConnect(lease: MobileRPCConnectAttemptLease?) {
        guard let key = finishableKey(for: lease) else { return }
        activeLeaseIDs[key] = nil
        releasedLeaseIDs[key] = nil
        abandonedAttemptCounts[key] = nil
        hardGateExpiresAt[key] = nil
    }

    func clearTimedOutAbandonedCleanup(lease: MobileRPCConnectAttemptLease?) {
        guard let key = validKey(for: lease) else { return }
        guard abandonedAttemptCounts[key, default: 0] < Self.maximumAbandonedAttemptsBeforeHardGate else {
            hardGateExpiresAt[key] = DispatchTime.now().uptimeNanoseconds &+ hardGateResetNanoseconds
            return
        }
        activeLeaseIDs[key] = nil
        releasedLeaseIDs[key] = lease?.id
        hardGateExpiresAt[key] = nil
    }

    func recordSuccessfulConnect(lease: MobileRPCConnectAttemptLease?) {
        clearFinishedConnect(lease: lease)
    }

    private func validKey(for lease: MobileRPCConnectAttemptLease?) -> String? {
        guard let lease else { return nil }
        guard let key = lease.key else { return nil }
        guard activeLeaseIDs[key] == lease.id else { return nil }
        return key
    }

    private func finishableKey(for lease: MobileRPCConnectAttemptLease?) -> String? {
        guard let lease else { return nil }
        guard let key = lease.key else { return nil }
        if activeLeaseIDs[key] == lease.id {
            return key
        }
        guard activeLeaseIDs[key] == nil, releasedLeaseIDs[key] == lease.id else {
            return nil
        }
        return key
    }

    private func expireHardGateIfNeeded(key: String) {
        guard let expiry = hardGateExpiresAt[key] else { return }
        guard DispatchTime.now().uptimeNanoseconds >= expiry else { return }
        activeLeaseIDs[key] = nil
        releasedLeaseIDs[key] = nil
        abandonedAttemptCounts[key] = nil
        hardGateExpiresAt[key] = nil
    }
}
