import Foundation

/// An arbitrary provider error has to cross an unstructured task boundary in
/// the setup timeout race.  The provider protocols intentionally expose
/// `any Error`, so retain it behind an explicitly unchecked Sendable wrapper
/// and unwrap it before returning to the caller.
private struct DelegationThrownError: Error, @unchecked Sendable {
    let underlying: any Error
}

/// Resolves exactly once without requiring the losing setup operation to
/// honor cancellation.  A structured task group is unsuitable here because
/// Swift waits for every child before leaving the group; a provider that is
/// stuck in a non-cooperative await would therefore defeat the timeout.
private final class DelegationFirstResult<Value: Sendable>: @unchecked Sendable {
    typealias Outcome = Result<Value, DelegationThrownError>

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Outcome? in
                if let outcome {
                    return outcome
                }
                waiter = continuation
                return nil
            }
            immediate.map { continuation.resume(returning: $0) }
        }
    }

    /// Returns `true` when this call won the race.  A late success is still
    /// useful to the caller for cleanup (notably a child thread created after
    /// the setup deadline), so callers must not simply discard a `false`.
    @discardableResult
    func resolve(_ outcome: Outcome) -> Bool {
        let resolution = lock.withLock {
            () -> (won: Bool, waiter: CheckedContinuation<Outcome, Never>?) in
            guard self.outcome == nil else { return (false, nil) }
            self.outcome = outcome
            let waiter = self.waiter
            self.waiter = nil
            return (true, waiter)
        }
        resolution.waiter?.resume(returning: outcome)
        return resolution.won
    }
}

/// Serializes every cleanup request for one delegated child. A setup timeout
/// can return before the provider call does, so the ordinary failure path and
/// a late-success reconciliation may both ask to remove the same child. Keep
/// those requests ordered and stop after the first confirmed deletion instead
/// of assuming repeated provider delete/interrupt calls are harmless.
private final class DelegationChildCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var deletionSucceeded = false
    private var tail: Task<Void, Never>?

    func run(
        interruptFirst: Bool,
        interrupt: @escaping @Sendable () async -> Void,
        delete: @escaping @Sendable () async -> Bool
    ) async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard !deletionSucceeded else { return nil }
            let previous = tail
            let task = Task.detached(priority: .utility) { [self] in
                await previous?.value
                guard !hasDeletedChild else { return }
                if interruptFirst { await interrupt() }
                if await delete() { markChildDeleted() }
            }
            tail = task
            return task
        }
        await task?.value
    }

    private var hasDeletedChild: Bool {
        lock.withLock { deletionSucceeded }
    }

    private func markChildDeleted() {
        lock.withLock { deletionSucceeded = true }
    }
}

/// Bridges an existing provider runtime into the provider-neutral delegation
/// scheduler.
///
/// The runtime remains responsible for credentials, wire encoding, and
/// provider lifecycle. This adapter only owns the child conversation created
/// for one delegation request and translates its streamed, provider-neutral
/// events into one bounded `DelegationOutput`. In production the runtime
/// passed here should normally be a `SharedRuntimeCoordinator`, so listening
/// for the child events does not steal the app model's subscription from a
/// single-consumer provider stream.
struct AgentRuntimeDelegationExecutor: DelegationExecutor {
    let connectionID: ProviderConnectionID
    let runtime: any AgentRuntime
    private let supportedModelIDs: Set<String>?
    private let defaultWorkingDirectory: String
    private let startsEphemeralThreads: Bool
    private let deletesThreadAfterExecution: Bool
    private let sandboxMode: RuntimeSandboxMode
    private let approvalPolicy: RuntimeApprovalPolicy
    private let setupTimeout: Duration
    private let terminalTimeout: Duration

    /// - Parameters:
    ///   - supportedModelIDs: An optional snapshot of the provider catalog.
    ///     `nil` means the runtime may accept any model on this connection.
    ///   - startsEphemeralThreads: Use a provider's ephemeral child-thread
    ///     facility when available. Durable children are the default because
    ///     they can be opened from the collaboration UI after completion.
    ///   - deletesThreadAfterExecution: Remove the child after the response.
    ///     This is useful for private/background delegations and should be
    ///     paired with ephemeral starts where the provider supports them.
    ///   - setupTimeout: Bound provider connect, child creation, and turn-start
    ///     handshakes. Once a child identity is known, a timed-out setup is
    ///     interrupted and removed by the same cleanup path as a failed turn.
    init(
        connectionID: ProviderConnectionID,
        runtime: any AgentRuntime,
        supportedModelIDs: Set<String>? = nil,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        startsEphemeralThreads: Bool = false,
        deletesThreadAfterExecution: Bool = false,
        sandboxMode: RuntimeSandboxMode = .readOnly,
        approvalPolicy: RuntimeApprovalPolicy = .never,
        // Allow provider discovery plus one transport request on a cold
        // connection. Callers and tests may choose a shorter value for a
        // deliberately local runtime.
        setupTimeout: Duration = .seconds(180),
        terminalTimeout: Duration = .seconds(600)
    ) {
        self.connectionID = connectionID
        self.runtime = runtime
        self.supportedModelIDs = supportedModelIDs
        self.defaultWorkingDirectory = workingDirectory
        self.startsEphemeralThreads = startsEphemeralThreads
        self.deletesThreadAfterExecution = deletesThreadAfterExecution
        self.sandboxMode = sandboxMode
        self.approvalPolicy = approvalPolicy
        self.setupTimeout = setupTimeout > .zero
            ? setupTimeout
            : .seconds(180)
        self.terminalTimeout = terminalTimeout > .zero
            ? terminalTimeout
            : .seconds(600)
    }

    func supports(model: ModelRef) -> Bool {
        guard model.connectionID == connectionID else { return false }
        guard let supportedModelIDs else { return true }
        return supportedModelIDs.contains(model.modelID)
    }

    func execute(
        _ request: DelegationRequest,
        reportProgress: @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput {
        guard request.targetConnectionID == connectionID,
              supports(model: request.targetModel)
        else {
            throw DelegationExecutorError.unsupportedModel(request.targetModel.modelID)
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DelegationExecutorError.execution("Delegation prompt cannot be empty.")
        }
        try Task.checkCancellation()

        let childCleanup = DelegationChildCleanup()
        var childID: String?
        var turnMayHaveBeenAccepted = false
        var collector: Task<DelegationOutput, any Error>?
        do {
            // Setup is part of the delegated operation, not an unbounded
            // prelude. A provider can hang during connect or child creation
            // before the terminal collector ever gets a chance to enforce its
            // response timeout.
            let session = try await boundedSetup("connection") {
                try await runtime.connect()
            }
            try Task.checkCancellation()
            guard session.auth.canRun else {
                throw DelegationExecutorError.unavailable
            }
            if supportedModelIDs == nil,
               !session.availableModels.isEmpty,
               !session.availableModels.contains(where: { $0.id == request.targetModel.modelID })
            {
                throw DelegationExecutorError.unsupportedModel(request.targetModel.modelID)
            }
            try Task.checkCancellation()

            let workingDirectory = resolvedWorkingDirectory(for: request)
            let child = try await boundedSetup(
                "child creation",
                lateSuccess: { [self] child in
                    // The child can be created after the timeout if the
                    // provider ignores cancellation.  Delete it from the
                    // detached, independently bounded cleanup task so it
                    // cannot become an orphan. Keep the provider's exact ID
                    // here; the normal invalid-identity path also attempts a
                    // best-effort delete before surfacing the error.
                    await deleteAbandonedThreadBestEffort(
                        child.id,
                        cleanup: childCleanup
                    )
                }
            ) {
                try await runtime.startThread(
                    StartThreadRequest(
                        cwd: workingDirectory,
                        model: request.targetModel.modelID,
                        ephemeral: startsEphemeralThreads,
                        sandboxMode: sandboxMode,
                        approvalPolicy: approvalPolicy,
                        allowsDynamicTools: false
                    )
                )
            }
            childID = child.id
            guard DelegationSafeText.boundedIdentifier(child.id) != nil else {
                throw DelegationExecutorError.execution(
                    "The provider returned an invalid child conversation identity."
                )
            }

            try Task.checkCancellation()
            await reportProgress(
                DelegationProgressUpdate(
                    phase: "started",
                    message: Self.nonBlank(child.title)
                )
            )
            try Task.checkCancellation()

            // Obtain the stream before starting the turn. Shared coordinators
            // buffer events, but this ordering also protects runtimes whose
            // event stream can deliver the first item synchronously.
            let stream = runtime.events
            collector = Task {
                try await Self.collectOutput(
                    from: stream,
                    threadID: child.id,
                    timeout: terminalTimeout,
                    reportProgress: reportProgress
                )
            }

            // Reserve cancellation cleanup before crossing the provider
            // boundary. A runtime may accept a turn and then suspend before
            // returning from `startTurn`; an interrupt is harmless if the
            // request ultimately failed, but missing it can strand work.
            turnMayHaveBeenAccepted = true
            try await boundedSetup(
                "turn start",
                lateSuccess: { [self] _ in
                    // If startTurn ignores cancellation and returns after the
                    // timeout, reconcile it through the same serialized
                    // cleanup owner. A prior successful deletion suppresses
                    // duplicate provider mutations; a failed attempt may be
                    // retried now that the provider call has settled.
                    await deleteAbandonedThreadBestEffort(
                        child.id,
                        cleanup: childCleanup,
                        interruptFirst: true
                    )
                }
            ) {
                try await runtime.startTurn(
                    StartTurnRequest(
                        threadID: child.id,
                        inputs: [.text(request.prompt)],
                        model: request.targetModel.modelID,
                        cwd: workingDirectory,
                        reasoningEffort: request.reasoningEffort,
                        sandboxMode: sandboxMode,
                        approvalPolicy: approvalPolicy
                    )
                )
            }
            // A turn can complete at the same instant that its parent is
            // cancelled.  Do not publish a successful delegation after that
            // cancellation has become authoritative.
            try Task.checkCancellation()
            let output = try await collector!.value
            collector = nil
            try Task.checkCancellation()
            await reportProgress(.init(phase: "completed", fraction: 1))
            await cleanupThreadIfNeeded(
                child.id,
                cleanup: childCleanup,
                interruptFirst: false
            )
            // Cancellation can arrive while the progress sink or private
            // cleanup is awaiting. Re-check immediately before exposing a
            // successful result so the coordinator's cancellation wins.
            try Task.checkCancellation()
            guard startsEphemeralThreads || deletesThreadAfterExecution else {
                return output
            }
            // Ephemeral/private children cannot be reopened from the task UI.
            // Do not return a join key that is already gone (or deliberately
            // absent from the durable provider catalog).
            return DelegationOutput(
                text: output.text,
                usage: output.usage,
                childConversationID: nil,
                truncatedAtCharacterLimit: output.truncatedAtCharacterLimit
            )
        } catch is CancellationError {
            collector?.cancel()
            collector = nil
            if let childID {
                await deleteAbandonedThreadBestEffort(
                    childID,
                    cleanup: childCleanup,
                    interruptFirst: turnMayHaveBeenAccepted
                )
            }
            throw CancellationError()
        } catch {
            let cancellationRequested = Task.isCancelled
            collector?.cancel()
            collector = nil
            if let childID {
                await deleteAbandonedThreadBestEffort(
                    childID,
                    cleanup: childCleanup,
                    interruptFirst: turnMayHaveBeenAccepted
                )
            }
            if cancellationRequested { throw CancellationError() }
            throw error
        }
    }

    /// Race one provider setup operation against a timer without waiting for a
    /// cancellation-uncooperative provider task. A structured task group is
    /// unsuitable here because Swift waits for every child before leaving the
    /// group; a hung app-server call would otherwise defeat the timeout.
    private func boundedSetup<T: Sendable>(
        _ phase: String,
        lateSuccess: (@Sendable (T) async -> Void)? = nil,
        shieldCancellation: Bool = false,
        timeout: Duration? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if !shieldCancellation {
            try Task.checkCancellation()
        }
        let race = DelegationFirstResult<T>()
        let operationTask = Task.detached(priority: .utility) {
            do {
                let value = try await operation()
                let won = race.resolve(.success(value))
                if !won, let lateSuccess {
                    // The operation task inherits cancellation from the
                    // timeout defer. Launch cleanup independently so a late
                    // provider success cannot skip its orphan removal.
                    Task.detached(priority: .utility) {
                        await lateSuccess(value)
                    }
                }
            } catch {
                _ = race.resolve(.failure(DelegationThrownError(underlying: error)))
            }
        }
        let timerTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: timeout ?? self.setupTimeout)
            } catch {
                return
            }
            _ = race.resolve(.failure(DelegationThrownError(
                underlying: DelegationExecutorError.provider(
                    "The provider \(phase) did not complete before the setup timeout."
                )
            )))
        }
        defer {
            operationTask.cancel()
            timerTask.cancel()
        }

        let outcome: DelegationFirstResult<T>.Outcome
        if shieldCancellation {
            // Cleanup must still be attempted when the parent task is already
            // canceled. The detached operation and independent timer provide
            // their own bounded lifetime in this branch.
            outcome = await race.wait()
        } else {
            if Task.isCancelled {
                _ = race.resolve(.failure(DelegationThrownError(
                    underlying: CancellationError()
                )))
            }
            outcome = await withTaskCancellationHandler {
                await race.wait()
            } onCancel: {
                _ = race.resolve(.failure(DelegationThrownError(
                    underlying: CancellationError()
                )))
            }
        }

        switch outcome {
        case let .success(value):
            return value
        case let .failure(failure):
            throw failure.underlying
        }
    }

    private func interruptBestEffort(threadID: String) async {
        _ = try? await boundedSetup(
            "child interruption",
            shieldCancellation: true,
            timeout: .seconds(10)
        ) {
            try await runtime.interrupt(threadID: threadID)
        }
    }

    private func resolvedWorkingDirectory(for request: DelegationRequest) -> String {
        guard let requested = request.workingDirectory,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return defaultWorkingDirectory }
        return requested
    }

    private func cleanupThreadIfNeeded(
        _ threadID: String,
        cleanup: DelegationChildCleanup,
        interruptFirst: Bool
    ) async {
        guard deletesThreadAfterExecution else { return }
        await cleanup.run(
            interruptFirst: interruptFirst,
            interrupt: { await interruptBestEffort(threadID: threadID) },
            delete: { await deleteThreadBestEffort(threadID, phase: "child cleanup") }
        )
    }

    /// A child that never produced a successful delegation result has no UI
    /// join key. Remove that app-created orphan even when successful children
    /// are configured to remain durable and clickable.
    private func deleteAbandonedThreadBestEffort(
        _ threadID: String,
        cleanup: DelegationChildCleanup,
        interruptFirst: Bool = false
    ) async {
        await cleanup.run(
            interruptFirst: interruptFirst,
            interrupt: { await interruptBestEffort(threadID: threadID) },
            delete: { await deleteThreadBestEffort(threadID, phase: "orphan cleanup") }
        )
    }

    private func deleteThreadBestEffort(_ threadID: String, phase: String) async -> Bool {
        do {
            try await boundedSetup(
                phase,
                shieldCancellation: true,
                timeout: .seconds(10)
            ) {
                try await runtime.deleteThread(id: threadID)
            }
            return true
        } catch {
            return false
        }
    }

    private static func collectOutput(
        from stream: AsyncStream<AgentRuntimeEvent>,
        threadID: String,
        timeout: Duration,
        reportProgress: @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput {
        let race = DelegationFirstResult<DelegationOutput>()
        let collectorTask = Task.detached(priority: .utility) {
            do {
                let output = try await collectOutputUntilTerminal(
                    from: stream,
                    threadID: threadID,
                    reportProgress: reportProgress
                )
                _ = race.resolve(.success(output))
            } catch {
                _ = race.resolve(.failure(DelegationThrownError(underlying: error)))
            }
        }
        let timeoutTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            _ = race.resolve(.failure(DelegationThrownError(
                underlying: DelegationExecutorError.provider(
                    "The delegated turn did not reach a terminal state before the timeout."
                )
            )))
        }
        defer {
            collectorTask.cancel()
            timeoutTask.cancel()
        }

        if Task.isCancelled {
            _ = race.resolve(.failure(DelegationThrownError(
                underlying: CancellationError()
            )))
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            _ = race.resolve(.failure(DelegationThrownError(
                underlying: CancellationError()
            )))
        }
        switch outcome {
        case let .success(output):
            return output
        case let .failure(failure):
            throw failure.underlying
        }
    }

    private static func collectOutputUntilTerminal(
        from stream: AsyncStream<AgentRuntimeEvent>,
        threadID: String,
        reportProgress: @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput {
        let maximumTrackedItemCount = 256
        let maximumPendingCharacterCount = DelegationSafeText.outputCharacterLimit + 1
        var itemIsAssistant: [String: Bool] = [:]
        var pendingDeltas: [String: PendingDelta] = [:]
        var pendingCharacterCount = 0
        var output = BoundedOutputText()
        var terminalDetail: String?

        for await event in stream {
            try Task.checkCancellation()
            switch event {
            case let .itemStarted(eventThreadID, item) where eventThreadID == threadID:
                let itemID = try validatedStreamItemID(item.id)
                try registerItemClassification(
                    itemID: itemID,
                    isAssistant: item.kind == .assistantMessage,
                    classifications: &itemIsAssistant,
                    pendingDeltas: pendingDeltas,
                    maximumTrackedItemCount: maximumTrackedItemCount
                )
                if item.kind == .assistantMessage {
                    let pending = pendingDeltas.removeValue(forKey: itemID)
                    pendingCharacterCount -= pending?.text.count ?? 0
                    if !item.body.isEmpty {
                        output.replace(with: item.body)
                    } else if let pending {
                        output.append(pending.text)
                    }
                    await reportProgress(.init(phase: "responding"))
                } else if let pending = pendingDeltas.removeValue(forKey: itemID) {
                    pendingCharacterCount -= pending.text.count
                }

            case let .itemDelta(eventThreadID, itemID, delta) where eventThreadID == threadID:
                // A few adapters can emit the first delta before the item
                // start notification. Hold it until that item is identified
                // as assistant content; this avoids mistaking a future user
                // item for the answer if an adapter reorders notifications.
                guard !delta.isEmpty else { continue }
                let itemID = try validatedStreamItemID(itemID)
                if itemIsAssistant[itemID] == true {
                    output.append(delta)
                } else if itemIsAssistant[itemID] == false {
                    // Command, tool, reasoning, and file-change output can be
                    // enormous. Once classified, it is never candidate answer
                    // text and must not be retained by this collector.
                    continue
                } else {
                    try ensureCanTrack(
                        itemID: itemID,
                        classifications: itemIsAssistant,
                        pendingDeltas: pendingDeltas,
                        maximumTrackedItemCount: maximumTrackedItemCount
                    )
                    var pending = pendingDeltas[itemID] ?? PendingDelta()
                    guard !pending.wasTruncated else { continue }
                    let remaining = maximumPendingCharacterCount - pendingCharacterCount
                    guard remaining > 0 else {
                        throw DelegationExecutorError.provider(
                            "The provider emitted too much unclassified streamed output."
                        )
                    }
                    if delta.count <= remaining {
                        pending.text += delta
                        pendingCharacterCount += delta.count
                    } else {
                        pending.text += String(delta.prefix(remaining)) + "…"
                        pending.wasTruncated = true
                        pendingCharacterCount += remaining + 1
                    }
                    pendingDeltas[itemID] = pending
                }

            case let .itemCompleted(eventThreadID, item) where eventThreadID == threadID:
                let itemID = try validatedStreamItemID(item.id)
                try registerItemClassification(
                    itemID: itemID,
                    isAssistant: item.kind == .assistantMessage,
                    classifications: &itemIsAssistant,
                    pendingDeltas: pendingDeltas,
                    maximumTrackedItemCount: maximumTrackedItemCount
                )
                if item.kind == .assistantMessage || itemIsAssistant[itemID] == true {
                    let pending = pendingDeltas.removeValue(forKey: itemID)
                    pendingCharacterCount -= pending?.text.count ?? 0
                    if !item.body.isEmpty {
                        output.replace(with: item.body)
                    } else if let pending {
                        output.append(pending.text)
                    }
                    if item.status == .failed {
                        terminalDetail = DelegationSafeText.sanitizeDiagnostic(
                            item.detail ?? item.body
                        )
                    }
                } else if let pending = pendingDeltas.removeValue(forKey: itemID) {
                    pendingCharacterCount -= pending.text.count
                }

            case let .userInteractionRequested(interaction)
                where interaction.threadID == threadID:
                // Delegated work has no user-facing approval/elicitation
                // surface of its own. Fail explicitly instead of waiting
                // forever in a provider state that this adapter cannot answer.
                throw DelegationExecutorError.execution(
                    "The delegated turn requested user input: \(interaction.title)"
                )

            case let .turnCompleted(eventThreadID, status) where eventThreadID == threadID:
                if status == .waitingForInput || status == .waitingForApproval {
                    throw DelegationExecutorError.execution(
                        "The delegated turn requires user interaction."
                    )
                }
                if status == .failed || status == .unknown {
                    let detail = Self.nonBlank(terminalDetail)
                        ?? (status == .failed
                            ? "The delegated turn failed."
                            : "The delegated turn ended with an unknown status.")
                    throw DelegationExecutorError.execution(detail)
                }
                if status == .idle {
                    // A provider can spend the entire response allowance on
                    // hidden reasoning (or otherwise emit an empty assistant
                    // item) and still report an apparently successful idle
                    // turn.  Returning that as a successful delegation would
                    // make Codex receive a blank tool result and hide the
                    // actionable failure from the user.  Delegation is
                    // text-only, so fail closed when no answer text arrived.
                    guard Self.nonBlank(output.text) != nil else {
                        throw DelegationExecutorError.execution(
                            "The delegated turn completed without an answer."
                        )
                    }
                    return DelegationOutput(
                        text: output.text,
                        childConversationID: threadID,
                        truncatedAtCharacterLimit: output.truncatedAtCharacterLimit
                    )
                }
                // A running completion notification is advisory; continue
                // waiting for the terminal idle/failed boundary.
                continue

            case .connectionChanged(.disconnected):
                throw DelegationExecutorError.provider(
                    "The provider disconnected before the delegated turn completed."
                )

            case let .connectionChanged(.failed(message)):
                throw DelegationExecutorError.provider(
                    nonBlank(message).map { DelegationSafeText.sanitizeDiagnostic($0) }
                        ?? "The provider connection failed before the delegated turn completed."
                )

            case let .threadDeleted(deletedThreadID) where deletedThreadID == threadID:
                throw DelegationExecutorError.execution(
                    "The delegated child task was deleted before it completed."
                )

            case let .threadStatusChanged(eventThreadID, status)
                where eventThreadID == threadID && status == .failed:
                throw DelegationExecutorError.execution(
                    nonBlank(terminalDetail) ?? "The delegated child task failed."
                )

            default:
                continue
            }
        }

        throw DelegationExecutorError.provider(
            "The provider event stream ended before the delegated turn completed."
        )
    }

    private static func validatedStreamItemID(_ itemID: String) throws -> String {
        guard !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              itemID.count <= DelegationSafeText.identifierCharacterLimit
        else {
            throw DelegationExecutorError.provider(
                "The provider emitted an invalid streamed item identity."
            )
        }
        return itemID
    }

    private static func ensureCanTrack(
        itemID: String,
        classifications: [String: Bool],
        pendingDeltas: [String: PendingDelta],
        maximumTrackedItemCount: Int
    ) throws {
        guard classifications[itemID] == nil, pendingDeltas[itemID] == nil else { return }
        guard classifications.count + pendingDeltas.count < maximumTrackedItemCount else {
            throw DelegationExecutorError.provider(
                "The provider emitted too many streamed items for one delegated turn."
            )
        }
    }

    private static func registerItemClassification(
        itemID: String,
        isAssistant: Bool,
        classifications: inout [String: Bool],
        pendingDeltas: [String: PendingDelta],
        maximumTrackedItemCount: Int
    ) throws {
        if let existing = classifications[itemID], existing != isAssistant {
            throw DelegationExecutorError.provider(
                "The provider changed the type of a streamed item during the delegated turn."
            )
        }
        try ensureCanTrack(
            itemID: itemID,
            classifications: classifications,
            pendingDeltas: pendingDeltas,
            maximumTrackedItemCount: maximumTrackedItemCount
        )
        classifications[itemID] = isAssistant
    }

    private struct PendingDelta {
        var text = ""
        var wasTruncated = false
    }

    private struct BoundedOutputText {
        private(set) var text = ""
        private(set) var truncatedAtCharacterLimit: Int?

        mutating func replace(with value: String) {
            text = ""
            truncatedAtCharacterLimit = nil
            append(value)
        }

        mutating func append(_ value: String) {
            guard !value.isEmpty, truncatedAtCharacterLimit == nil else { return }
            let limit = DelegationSafeText.outputCharacterLimit
            let remaining = max(0, limit - text.count)
            if value.count <= remaining {
                text += value
                return
            }
            if remaining > 0 {
                text += String(value.prefix(remaining))
            }
            text += "…"
            truncatedAtCharacterLimit = limit
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
