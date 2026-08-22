import Foundation

enum DelegationCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case invalidMaxConcurrentJobs(Int)
    case invalidMaxRetainedTerminalJobs(Int)
    case duplicateExecutorConnection(ProviderConnectionID)
    case noExecutor(ProviderConnectionID)
    case unsupportedModel(connectionID: ProviderConnectionID, modelID: String)
    case invalidJobID
    case duplicateJobID(DelegationJobID)
    case invalidParentIdentity
    case invalidTargetIdentity
    case emptyPrompt
    case invalidLineage
    case unknownJob(DelegationJobID)
    case parentJobUnavailable(DelegationJobID)

    var errorDescription: String? {
        switch self {
        case let .invalidMaxConcurrentJobs(value):
            "Delegation concurrency must be at least one (received \(value))."
        case let .invalidMaxRetainedTerminalJobs(value):
            "Delegation terminal-job retention must be at least one (received \(value))."
        case let .duplicateExecutorConnection(id):
            "More than one delegation executor is registered for \(id)."
        case let .noExecutor(id):
            "No delegation executor is registered for provider connection \(id)."
        case let .unsupportedModel(connectionID, modelID):
            "Provider connection \(connectionID) does not support model \(modelID)."
        case .invalidJobID:
            "Delegation job ID cannot be empty."
        case let .duplicateJobID(id):
            "A delegated job already exists for \(id)."
        case .invalidParentIdentity:
            "Delegation parent identity is invalid or provider-scoped inconsistently."
        case .invalidTargetIdentity:
            "Delegation target identity is invalid or provider-scoped inconsistently."
        case .emptyPrompt:
            "Delegation prompt cannot be empty."
        case .invalidLineage:
            "Delegation lineage does not identify the request's parent agent."
        case let .unknownJob(id):
            "No delegated job exists for \(id)."
        case let .parentJobUnavailable(id):
            "The parent delegated job \(id) is not available for child delegation."
        }
    }
}

enum DelegationCancellationDisposition: String, Sendable, Equatable {
    case queuedCancelled
    case runningCancellationRequested
    case alreadyTerminal
}

/// Actor-isolated scheduler for cross-provider work.
///
/// The coordinator owns queueing, lifecycle events, bounded concurrency, and
/// cancellation.  Provider executors remain independent and credential-aware;
/// they receive only `DelegationRequest` plus a progress sink.
actor DelegationCoordinator {
    private let maxConcurrentJobs: Int
    private let maxRetainedTerminalJobs: Int
    private let executors: [ProviderConnectionID: any DelegationExecutor]

    private enum ExecutorCompletion: Sendable {
        case success(DelegationOutput)
        case cancelled
        case failure(code: DelegationFailureCode, message: String)
    }

    private struct JobRecord {
        let request: DelegationRequest
        let submittedAt: Date
        var state: DelegationJobState
        var startedAt: Date?
        var finishedAt: Date?
        var latestProgress: DelegationProgressUpdate?
        var cancellationReason: DelegationCancellationReason?
        var task: Task<Void, Never>?
        var result: DelegationResult?
        var failure: DelegationFailure?
        var cancellation: DelegationCancellation?
        var history: [DelegationEvent]
        var subscribers: [UUID: DelegationEventBuffer]
        var waiters: [UUID: CheckedContinuation<DelegationResult, any Error>]
    }

    private var jobs: [DelegationJobID: JobRecord] = [:]
    /// Accepted IDs are reserved for the coordinator lifetime. Terminal
    /// record eviction must not make an ID reusable while an ignored
    /// cancellation can still deliver a late executor completion keyed to it.
    private var acceptedJobIDs: Set<DelegationJobID> = []
    private var queue: [DelegationJobID] = []
    private var running: Set<DelegationJobID> = []
    /// Tracks provider calls that have actually entered an executor. A job can
    /// be logically cancelled before a non-cooperative transport returns, so
    /// physical work needs its own concurrency budget.
    private var executorTasksInFlight: Set<DelegationJobID> = []
    private var terminalJobOrder: [DelegationJobID] = []
    private var isShutDown = false

    init(
        executors: [any DelegationExecutor],
        maxConcurrentJobs: Int = 2,
        maxRetainedTerminalJobs: Int = 256
    ) throws {
        guard maxConcurrentJobs > 0 else {
            throw DelegationCoordinatorError.invalidMaxConcurrentJobs(maxConcurrentJobs)
        }
        guard maxRetainedTerminalJobs > 0 else {
            throw DelegationCoordinatorError.invalidMaxRetainedTerminalJobs(
                maxRetainedTerminalJobs
            )
        }

        var byConnection: [ProviderConnectionID: any DelegationExecutor] = [:]
        byConnection.reserveCapacity(executors.count)
        for executor in executors {
            guard byConnection.updateValue(executor, forKey: executor.connectionID) == nil else {
                throw DelegationCoordinatorError.duplicateExecutorConnection(
                    executor.connectionID
                )
            }
        }

        self.maxConcurrentJobs = maxConcurrentJobs
        self.maxRetainedTerminalJobs = maxRetainedTerminalJobs
        self.executors = byConnection
    }

    init(
        executors: [ProviderConnectionID: any DelegationExecutor],
        maxConcurrentJobs: Int = 2,
        maxRetainedTerminalJobs: Int = 256
    ) throws {
        try self.init(
            executors: Array(executors.values),
            maxConcurrentJobs: maxConcurrentJobs,
            maxRetainedTerminalJobs: maxRetainedTerminalJobs
        )
    }

    /// Submits a job and starts it immediately when a concurrency slot is
    /// available.  The returned stream is hot and starts with `.queued`.
    func submit(_ rawRequest: DelegationRequest) throws -> DelegationJobHandle {
        guard !isShutDown else {
            throw DelegationExecutorError.unavailable
        }

        let request = rawRequest.assigningRootIfNeeded()
        try validate(request)
        guard !acceptedJobIDs.contains(request.id) else {
            // Reusing IDs would make lineage and cancellation ambiguous.  A
            // stable public error is preferable to silently replacing work,
            // including after terminal record retention evicts the old job.
            throw DelegationCoordinatorError.duplicateJobID(request.id)
        }
        guard let executor = executors[request.targetConnectionID] else {
            throw DelegationCoordinatorError.noExecutor(request.targetConnectionID)
        }
        guard executor.supports(model: request.targetModel) else {
            throw DelegationCoordinatorError.unsupportedModel(
                connectionID: request.targetConnectionID,
                modelID: request.targetModel.modelID
            )
        }

        let submittedAt = Date()
        let record = JobRecord(
            request: request,
            submittedAt: submittedAt,
            state: .queued,
            startedAt: nil,
            finishedAt: nil,
            latestProgress: nil,
            cancellationReason: nil,
            task: nil,
            result: nil,
            failure: nil,
            cancellation: nil,
            history: [],
            subscribers: [:],
            waiters: [:]
        )
        acceptedJobIDs.insert(request.id)
        jobs[request.id] = record
        queue.append(request.id)
        emit(.queued(makeSnapshot(for: request.id)))
        drain()

        return DelegationJobHandle(
            jobID: request.id,
            request: request,
            events: makeReplayStream(for: request.id)
        )
    }

    /// Creates a child request whose parent identity and lineage are derived
    /// from an accepted parent job.  This is the preferred seam for an agent
    /// that delegates again after receiving a result/progress event.
    func makeChildRequest(
        from parentJobID: DelegationJobID,
        target: DelegationTarget,
        prompt: String,
        id: DelegationJobID = DelegationJobID()
    ) throws -> DelegationRequest {
        guard let parent = jobs[parentJobID] else {
            throw DelegationCoordinatorError.parentJobUnavailable(parentJobID)
        }
        let parentAgent = parent.request.target.agent
        let lineage = parent.request.lineage.appending(
            parentAgent,
            parentJobID: parentJobID
        )
        return DelegationRequest(
            id: id,
            parentAgent: parentAgent,
            target: target,
            prompt: prompt,
            lineage: lineage
        )
    }

    /// Convenience that creates and submits a child in one actor turn.
    func submitChild(
        from parentJobID: DelegationJobID,
        target: DelegationTarget,
        prompt: String,
        id: DelegationJobID = DelegationJobID()
    ) throws -> DelegationJobHandle {
        let request = try makeChildRequest(
            from: parentJobID,
            target: target,
            prompt: prompt,
            id: id
        )
        return try submit(request)
    }

    /// Returns a replaying stream for a job.  The stream includes lifecycle
    /// events that happened before subscription, then remains live until the
    /// terminal event.
    func events(for jobID: DelegationJobID) throws -> DelegationEventStream {
        guard jobs[jobID] != nil else {
            throw DelegationCoordinatorError.unknownJob(jobID)
        }
        return makeReplayStream(for: jobID)
    }

    /// Waits for a terminal successful result.  Failed and cancelled jobs
    /// throw typed values that retain provider-aware identity and lineage.
    func result(for jobID: DelegationJobID) async throws -> DelegationResult {
        guard var record = jobs[jobID] else {
            throw DelegationCoordinatorError.unknownJob(jobID)
        }
        if let result = record.result { return result }
        if let failure = record.failure {
            throw DelegationResultError.failed(failure)
        }
        if let cancellation = record.cancellation {
            throw DelegationResultError.cancelled(cancellation)
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    record.waiters[waiterID] = continuation
                    jobs[jobID] = record
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(jobID: jobID, waiterID: waiterID) }
        }
    }

    /// Returns a current immutable snapshot for UI projection and diagnostics.
    func snapshot(for jobID: DelegationJobID) throws -> DelegationJobSnapshot {
        guard jobs[jobID] != nil else {
            throw DelegationCoordinatorError.unknownJob(jobID)
        }
        return makeSnapshot(for: jobID)
    }

    /// Exposes subscription pressure for diagnostics and leak regression
    /// tests without exposing subscriber objects or buffered event contents.
    func activeSubscriberCount(for jobID: DelegationJobID) throws -> Int {
        guard let record = jobs[jobID] else {
            throw DelegationCoordinatorError.unknownJob(jobID)
        }
        return record.subscribers.count
    }

    /// Requests cancellation.  Queued work transitions to `.cancelled`
    /// immediately; running work receives cooperative `Task.cancel()` and is
    /// makes cancellation authoritative when the adapter eventually exits, so
    /// a late provider success cannot overwrite the cancellation request.
    @discardableResult
    func cancel(
        _ jobID: DelegationJobID,
        reason: DelegationCancellationReason = .user
    ) throws -> DelegationCancellationDisposition {
        guard var record = jobs[jobID] else {
            throw DelegationCoordinatorError.unknownJob(jobID)
        }
        guard !record.state.isTerminal else { return .alreadyTerminal }
        if record.cancellationReason != nil {
            return .runningCancellationRequested
        }

        let now = Date()
        record.cancellationReason = reason
        if record.state == .queued {
            let stateBeforeCancellation = record.state
            queue.removeAll { $0 == jobID }
            record.state = .cancelled
            record.finishedAt = now
            let cancellation = makeCancellation(
                jobID: jobID,
                request: record.request,
                reason: reason,
                occurredAt: now
            )
            record.cancellation = cancellation
            jobs[jobID] = record
            emit(
                .cancellationRequested(
                    makeCancellationRequest(
                        jobID: jobID,
                        request: record.request,
                        reason: reason,
                        state: stateBeforeCancellation,
                        occurredAt: now
                    )
                )
            )
            emit(.cancelled(cancellation))
            resumeWaiters(record: record)
            retainTerminalJob(jobID)
            drain()
            return .queuedCancelled
        }

        // Cancellation is authoritative at the coordinator boundary even if
        // a provider transport is slow to observe cooperative Task.cancel().
        jobs[jobID] = record
        emit(
            .cancellationRequested(
                makeCancellationRequest(
                    jobID: jobID,
                    request: record.request,
                    reason: reason,
                    state: record.state,
                    occurredAt: now
                )
            )
        )
        record.task?.cancel()
        finishCancellation(jobID: jobID, reason: reason)
        return .runningCancellationRequested
    }

    /// Cancels all non-terminal work and closes the coordinator-wide stream.
    /// Adapters are still given cooperative cancellation; their eventual
    /// completion cannot turn a requested cancellation into success.
    func shutdown(
        reason: DelegationCancellationReason = .shutdown
    ) throws {
        guard !isShutDown else { return }
        isShutDown = true
        let activeIDs = jobs.values
            .filter { !$0.state.isTerminal }
            .map(\.request.id)
        for id in activeIDs {
            _ = try cancel(id, reason: reason)
        }
    }

    // MARK: Actor-private scheduler

    private func validate(_ request: DelegationRequest) throws {
        guard !request.id.isBlank else {
            throw DelegationCoordinatorError.invalidJobID
        }
        guard request.parentAgent.isValid else {
            throw DelegationCoordinatorError.invalidParentIdentity
        }
        guard request.target.isValid else {
            throw DelegationCoordinatorError.invalidTargetIdentity
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DelegationCoordinatorError.emptyPrompt
        }
        guard request.lineage.agents.last == request.parentAgent else {
            throw DelegationCoordinatorError.invalidLineage
        }

        if let parentJobID = request.lineage.parentJobID {
            guard let parent = jobs[parentJobID] else {
                throw DelegationCoordinatorError.invalidLineage
            }
            let expectedParentAgent = parent.request.target.agent
            let expectedRoot = parent.request.lineage.rootJobID ?? parent.request.id
            guard request.parentAgent == expectedParentAgent,
                  request.lineage.rootJobID == expectedRoot,
                  request.lineage.agents
                    == parent.request.lineage.agents + [expectedParentAgent],
                  request.lineage.depth == parent.request.lineage.depth + 1
            else {
                throw DelegationCoordinatorError.invalidLineage
            }
        } else {
            guard request.lineage.rootJobID == request.id,
                  request.lineage.agents == [request.parentAgent],
                  request.lineage.depth == 0
            else {
                throw DelegationCoordinatorError.invalidLineage
            }
        }
    }

    private func drain() {
        guard !isShutDown else { return }
        while executorTasksInFlight.count < maxConcurrentJobs, !queue.isEmpty {
            let jobID = queue.removeFirst()
            guard var record = jobs[jobID], record.state == .queued else { continue }

            let now = Date()
            record.state = .running
            record.startedAt = now
            jobs[jobID] = record
            running.insert(jobID)
            emit(.started(makeSnapshot(for: jobID)))

            guard let executor = executors[record.request.targetConnectionID] else {
                // This cannot normally happen because submit validates the
                // binding, but preserving a terminal event keeps the actor
                // resilient to future dynamic registry changes.
                finishFailure(
                    jobID: jobID,
                    code: .unavailable,
                    message: "The selected provider connection is unavailable."
                )
                continue
            }

            let request = record.request
            executorTasksInFlight.insert(jobID)
            let task = Task { [weak self, executor] in
                guard let self else { return }
                let reportProgress: DelegationProgressReporter = { [weak self] update in
                    guard let self else { return }
                    await self.receiveProgress(jobID: request.id, update: update)
                }

                let completion: ExecutorCompletion
                do {
                    let output = try await executor.execute(
                        request,
                        reportProgress: reportProgress
                    )
                    completion = .success(output)
                } catch is CancellationError {
                    completion = .cancelled
                } catch {
                    completion = .failure(
                        code: Self.failureCode(for: error),
                        message: DelegationSafeText.sanitizeDiagnostic(
                            error.localizedDescription
                        )
                    )
                }
                await self.completeExecutorTask(
                    jobID: request.id,
                    completion: completion
                )
            }
            jobs[jobID]?.task = task
        }
    }

    /// Releases the physical provider-work slot only when the executor really
    /// exits. Logical cancellation can therefore unblock UI immediately
    /// without letting ignored cancellation exceed the configured limit.
    private func completeExecutorTask(
        jobID: DelegationJobID,
        completion: ExecutorCompletion
    ) {
        executorTasksInFlight.remove(jobID)
        guard var record = jobs[jobID] else {
            drain()
            return
        }
        if record.state.isTerminal {
            record.task = nil
            jobs[jobID] = record
            running.remove(jobID)
            drain()
            return
        }

        switch completion {
        case let .success(output):
            finishSuccess(jobID: jobID, output: output)
        case .cancelled:
            finishCancellation(
                jobID: jobID,
                reason: record.cancellationReason ?? .unknown
            )
        case let .failure(code, message):
            finishFailure(jobID: jobID, code: code, message: message)
        }
    }

    private func receiveProgress(
        jobID: DelegationJobID,
        update: DelegationProgressUpdate
    ) {
        guard var record = jobs[jobID], record.state == .running else { return }
        let safeUpdate = DelegationProgressUpdate(
            phase: DelegationSafeText.sanitizeDiagnostic(update.phase, limit: 80),
            message: update.message.map { DelegationSafeText.sanitizeDiagnostic($0) },
            fraction: update.fraction
        )
        record.latestProgress = safeUpdate
        jobs[jobID] = record
        emit(
            .progress(
                DelegationProgress(
                    jobID: jobID,
                    target: record.request.target,
                    lineage: record.request.lineage,
                    update: safeUpdate,
                    emittedAt: Date()
                )
            )
        )
    }

    private func finishSuccess(jobID: DelegationJobID, output: DelegationOutput) {
        guard var record = jobs[jobID], !record.state.isTerminal else { return }
        if record.cancellationReason != nil {
            finishCancellation(
                jobID: jobID,
                reason: record.cancellationReason ?? .unknown
            )
            return
        }

        let now = Date()
        let coordinatorLimit = output.text.count > DelegationSafeText.outputCharacterLimit
            ? DelegationSafeText.outputCharacterLimit
            : nil
        let effectiveTruncationLimit = [
            output.truncatedAtCharacterLimit,
            coordinatorLimit,
        ].compactMap { $0 }.min()
        let safeOutput = DelegationOutput(
            text: DelegationSafeText.boundedOutput(output.text),
            usage: output.usage,
            truncatedAtCharacterLimit: effectiveTruncationLimit
        )
        let result = DelegationResult(
            jobID: jobID,
            parentAgent: record.request.parentAgent,
            target: record.request.target,
            lineage: record.request.lineage,
            output: safeOutput,
            completedAt: now
        )
        record.state = .succeeded
        record.finishedAt = now
        record.result = result
        record.task = nil
        jobs[jobID] = record
        running.remove(jobID)
        emit(.completed(result))
        resumeWaiters(record: record)
        retainTerminalJob(jobID)
        drain()
    }

    private func finishFailure(
        jobID: DelegationJobID,
        code: DelegationFailureCode,
        message: String
    ) {
        guard var record = jobs[jobID], !record.state.isTerminal else { return }
        if record.cancellationReason != nil {
            finishCancellation(
                jobID: jobID,
                reason: record.cancellationReason ?? .unknown
            )
            return
        }

        let now = Date()
        let failure = DelegationFailure(
            jobID: jobID,
            target: record.request.target,
            lineage: record.request.lineage,
            code: code,
            message: DelegationSafeText.sanitizeDiagnostic(message),
            occurredAt: now
        )
        record.state = .failed
        record.finishedAt = now
        record.failure = failure
        record.task = nil
        jobs[jobID] = record
        running.remove(jobID)
        emit(.failed(failure))
        resumeWaiters(record: record)
        retainTerminalJob(jobID)
        drain()
    }

    private func finishCancellation(
        jobID: DelegationJobID,
        reason: DelegationCancellationReason
    ) {
        guard var record = jobs[jobID], !record.state.isTerminal else { return }
        let now = Date()
        let cancellation = makeCancellation(
            jobID: jobID,
            request: record.request,
            reason: record.cancellationReason ?? reason,
            occurredAt: now
        )
        record.state = .cancelled
        record.finishedAt = now
        record.cancellation = cancellation
        record.task = nil
        jobs[jobID] = record
        running.remove(jobID)
        emit(.cancelled(cancellation))
        resumeWaiters(record: record)
        retainTerminalJob(jobID)
        drain()
    }

    private func resumeWaiters(record: JobRecord) {
        guard !record.waiters.isEmpty else { return }
        let waiters = record.waiters.values
        jobs[record.request.id]?.waiters.removeAll()
        for waiter in waiters {
            if let result = record.result {
                waiter.resume(returning: result)
            } else if let failure = record.failure {
                waiter.resume(throwing: DelegationResultError.failed(failure))
            } else if let cancellation = record.cancellation {
                waiter.resume(throwing: DelegationResultError.cancelled(cancellation))
            }
        }
    }

    private func cancelWaiter(jobID: DelegationJobID, waiterID: UUID) {
        guard var record = jobs[jobID],
              let waiter = record.waiters.removeValue(forKey: waiterID)
        else { return }
        jobs[jobID] = record
        waiter.resume(throwing: CancellationError())
    }

    private func makeSnapshot(for jobID: DelegationJobID) -> DelegationJobSnapshot {
        guard let record = jobs[jobID] else {
            // This helper is only called after a record exists.  Keeping a
            // precondition makes accidental future misuse obvious in tests.
            preconditionFailure("Missing delegation job \(jobID)")
        }
        return DelegationJobSnapshot(
            id: record.request.id,
            request: record.request,
            state: record.state,
            submittedAt: record.submittedAt,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            latestProgress: record.latestProgress
        )
    }

    private func emit(_ event: DelegationEvent) {
        guard var record = jobs[event.jobID] else { return }
        appendBounded(event, to: &record.history, limit: 256)
        for subscriber in record.subscribers.values {
            subscriber.publish(event)
        }
        if event.isTerminal {
            for subscriber in record.subscribers.values {
                subscriber.finish()
            }
            record.subscribers.removeAll()
        }
        jobs[event.jobID] = record
    }

    private func removeSubscriber(jobID: DelegationJobID, subscriberID: UUID) {
        jobs[jobID]?.subscribers.removeValue(forKey: subscriberID)
    }

    private func makeReplayStream(for jobID: DelegationJobID) -> DelegationEventStream {
        let id = UUID()
        let buffer = DelegationEventBuffer { [weak self] in
            Task { [weak self] in
                await self?.removeSubscriber(jobID: jobID, subscriberID: id)
            }
        }
        guard var record = jobs[jobID] else {
            buffer.finish()
            return DelegationEventStream(id: id, buffer: buffer)
        }
        for event in record.history {
            buffer.publish(event)
        }
        if record.state.isTerminal {
            buffer.finish()
        } else {
            record.subscribers[id] = buffer
            jobs[jobID] = record
        }
        return DelegationEventStream(id: id, buffer: buffer)
    }

    /// Keeps retained prompts, event history, and results bounded. A handle
    /// that already received its terminal event continues to own that buffered
    /// event after the coordinator record is evicted.
    private func retainTerminalJob(_ jobID: DelegationJobID) {
        guard jobs[jobID]?.state.isTerminal == true,
              !terminalJobOrder.contains(jobID)
        else { return }
        terminalJobOrder.append(jobID)
        while terminalJobOrder.count > maxRetainedTerminalJobs {
            let expired = terminalJobOrder.removeFirst()
            jobs.removeValue(forKey: expired)
            queue.removeAll { $0 == expired }
            running.remove(expired)
        }
    }

    private func appendBounded(
        _ event: DelegationEvent,
        to history: inout [DelegationEvent],
        limit: Int
    ) {
        history.append(event)
        while history.count > limit {
            if let progress = history.firstIndex(where: {
                if case .progress = $0 { return true }
                return false
            }) {
                history.remove(at: progress)
            } else if let removable = history.firstIndex(where: { !$0.isTerminal }) {
                history.remove(at: removable)
            } else {
                history.removeFirst()
            }
        }
    }

    private func makeCancellationRequest(
        jobID: DelegationJobID,
        request: DelegationRequest,
        reason: DelegationCancellationReason,
        state: DelegationJobState,
        occurredAt: Date
    ) -> DelegationCancellationRequest {
        DelegationCancellationRequest(
            jobID: jobID,
            target: request.target,
            lineage: request.lineage,
            reason: reason,
            state: state,
            occurredAt: occurredAt
        )
    }

    private func makeCancellation(
        jobID: DelegationJobID,
        request: DelegationRequest,
        reason: DelegationCancellationReason,
        occurredAt: Date
    ) -> DelegationCancellation {
        DelegationCancellation(
            jobID: jobID,
            target: request.target,
            lineage: request.lineage,
            reason: reason,
            occurredAt: occurredAt
        )
    }

    private static func failureCode(for error: any Error) -> DelegationFailureCode {
        switch error {
        case DelegationExecutorError.unavailable:
            .unavailable
        case DelegationExecutorError.unsupportedModel:
            .unsupportedModel
        case DelegationExecutorError.provider:
            .provider
        case DelegationExecutorError.execution:
            .execution
        default:
            .unknown
        }
    }
}
