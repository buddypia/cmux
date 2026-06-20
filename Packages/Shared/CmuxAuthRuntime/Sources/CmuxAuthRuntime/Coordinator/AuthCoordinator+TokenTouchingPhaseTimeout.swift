import Foundation

@MainActor
extension AuthCoordinator {
    func runTokenTouchingPhase<T: Sendable>(
        _ phase: AuthPhase,
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let phaseID = UUID()
        let generation = sessionGeneration
        let signOutEpoch = signOutEpoch
        let signInAttemptCounter = signInAttemptCounter
        let storeWriteHighWater = tokenStoreWriteHighWater
        let phaseTask = Task {
            do {
                let value = try await operation()
                let refreshTokenAfterOperation = await client.refreshToken()
                try await finishTokenTouchingPhase(
                    generation: generation,
                    signOutEpoch: signOutEpoch,
                    signInAttemptCounter: signInAttemptCounter,
                    storeWriteHighWater: storeWriteHighWater,
                    refreshTokenAfterOperation: refreshTokenAfterOperation
                )
                return value
            } catch {
                let refreshTokenAfterOperation = await client.refreshToken()
                try await finishTokenTouchingPhase(
                    generation: generation,
                    signOutEpoch: signOutEpoch,
                    signInAttemptCounter: signInAttemptCounter,
                    storeWriteHighWater: storeWriteHighWater,
                    refreshTokenAfterOperation: refreshTokenAfterOperation
                )
                throw error
            }
        }
        activeTokenTouchingPhaseCancels[phaseID] = { phaseTask.cancel() }

        Task { [weak self, phaseID] in
            _ = await phaseTask.result
            await MainActor.run {
                self?.activeTokenTouchingPhaseCancels[phaseID] = nil
            }
        }

        return try await waitForTokenTouchingPhase(
            phaseTask,
            id: phaseID,
            phase: phase,
            timeout: timeout
        )
    }

    private func waitForTokenTouchingPhase<T: Sendable>(
        _ phaseTask: Task<T, any Error>,
        id: UUID,
        phase: AuthPhase,
        timeout: Duration
    ) async throws -> T {
        try Task.checkCancellation()
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<T, any Error> { continuation in
            let phaseWaiter = Task {
                do {
                    let value = try await phaseTask.value
                    guard await race.winOperation() else { return }
                    continuation.yield(value)
                    continuation.finish()
                } catch {
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
                log.log("auth.phase=\(phase.rawValue) timed out after \(timeout)")
                phaseTask.cancel()
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                phaseWaiter.cancel()
                deadline.cancel()
            }
        }

        do {
            for try await value in stream {
                return value
            }
        } catch AuthError.timedOut {
            activeTokenTouchingPhaseCancels[id] = nil
            throw AuthError.timedOut
        } catch {
            activeTokenTouchingPhaseCancels[id] = nil
            throw error
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw AuthError.timedOut
    }

    private func finishTokenTouchingPhase(
        generation: UInt64,
        signOutEpoch: UInt64,
        signInAttemptCounter: UInt64,
        storeWriteHighWater: UInt64,
        refreshTokenAfterOperation: String?
    ) async throws {
        guard signOutEpoch != self.signOutEpoch else { return }
        guard self.signInAttemptCounter == signInAttemptCounter,
              tokenStoreWriteHighWater == storeWriteHighWater else {
            throw CancellationError()
        }
        guard !isCapturingSignOutCredentials else {
            throw CancellationError()
        }
        if let refreshTokenAfterOperation {
            await client.clearLocalSession(ifRefreshTokenMatches: refreshTokenAfterOperation)
        }
        guard generation == sessionGeneration,
              self.signInAttemptCounter == signInAttemptCounter,
              tokenStoreWriteHighWater == storeWriteHighWater else {
            throw CancellationError()
        }
        throw CancellationError()
    }
}
