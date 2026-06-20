import Foundation

@MainActor
extension AuthCoordinator {
    func runValidationPhase<T: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let validationID = UUID()
        guard await phaseTimeoutRegistry.begin(.validateSession, id: validationID) else {
            log.log("auth.phase=\(AuthPhase.validateSession.rawValue) previous timed-out validation still active")
            throw AuthError.timedOut
        }

        let generation = sessionGeneration
        let signOutEpoch = signOutEpoch
        let signInAttemptCounter = signInAttemptCounter
        let storeWriteHighWater = tokenStoreWriteHighWater
        let registry = phaseTimeoutRegistry
        let validation = Task {
            do {
                let value = try await operation()
                let refreshTokenAfterValidation = await client.refreshToken()
                try await finishValidationPhase(
                    generation: generation,
                    signOutEpoch: signOutEpoch,
                    signInAttemptCounter: signInAttemptCounter,
                    storeWriteHighWater: storeWriteHighWater,
                    refreshTokenAfterValidation: refreshTokenAfterValidation
                )
                return value
            } catch {
                let refreshTokenAfterValidation = await client.refreshToken()
                try await finishValidationPhase(
                    generation: generation,
                    signOutEpoch: signOutEpoch,
                    signInAttemptCounter: signInAttemptCounter,
                    storeWriteHighWater: storeWriteHighWater,
                    refreshTokenAfterValidation: refreshTokenAfterValidation
                )
                throw error
            }
        }
        activeSessionValidationCancels[validationID] = { validation.cancel() }

        Task { [weak self, registry, validationID] in
            _ = await validation.result
            await registry.end(.validateSession, id: validationID)
            await MainActor.run {
                self?.activeSessionValidationCancels[validationID] = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await waitForValidationPhase(validation, id: validationID, timeout: timeout)
        } onCancel: {
            validation.cancel()
        }
    }

    private func waitForValidationPhase<T: Sendable>(
        _ validation: Task<T, any Error>,
        id: UUID,
        timeout: Duration
    ) async throws -> T {
        try Task.checkCancellation()
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<T, any Error> { continuation in
            let validationWaiter = Task {
                do {
                    let value = try await validation.value
                    await phaseTimeoutRegistry.end(.validateSession, id: id)
                    guard await race.winOperation() else { return }
                    continuation.yield(value)
                    continuation.finish()
                } catch {
                    await phaseTimeoutRegistry.end(.validateSession, id: id)
                    guard await race.winOperation() else { return }
                    continuation.finish(throwing: error)
                }
            }
            let deadline = Task { [clock, log] in
                do {
                    try await clock.sleep(for: timeout, tolerance: nil)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await race.winTimeout() else { return }
                log.log("auth.phase=\(AuthPhase.validateSession.rawValue) timed out after \(timeout)")
                await phaseTimeoutRegistry.markTimedOut(.validateSession, id: id)
                validation.cancel()
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                validationWaiter.cancel()
                deadline.cancel()
            }
        }
        do {
            for try await value in stream {
                return value
            }
        } catch {
            throw error
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw AuthError.timedOut
    }

    private func finishValidationPhase(
        generation: UInt64,
        signOutEpoch: UInt64,
        signInAttemptCounter: UInt64,
        storeWriteHighWater: UInt64,
        refreshTokenAfterValidation: String?
    ) async throws {
        guard signOutEpoch != self.signOutEpoch else { return }
        guard self.signInAttemptCounter == signInAttemptCounter else {
            throw CancellationError()
        }
        guard tokenStoreWriteHighWater == storeWriteHighWater else {
            throw CancellationError()
        }
        guard !isCapturingSignOutCredentials else {
            throw CancellationError()
        }
        if let refreshTokenAfterValidation {
            await client.clearLocalSession(ifRefreshTokenMatches: refreshTokenAfterValidation)
        }
        guard generation == sessionGeneration,
              self.signInAttemptCounter == signInAttemptCounter,
              tokenStoreWriteHighWater == storeWriteHighWater else {
            throw CancellationError()
        }
        clearAuthState(preservePendingCode: true)
        throw CancellationError()
    }
}
