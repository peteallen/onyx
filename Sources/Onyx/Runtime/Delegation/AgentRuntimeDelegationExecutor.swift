import Foundation

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
    init(
        connectionID: ProviderConnectionID,
        runtime: any AgentRuntime,
        supportedModelIDs: Set<String>? = nil,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        startsEphemeralThreads: Bool = false,
        deletesThreadAfterExecution: Bool = false,
        sandboxMode: RuntimeSandboxMode = .readOnly,
        approvalPolicy: RuntimeApprovalPolicy = .never,
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

        let session = try await runtime.connect()
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
        let child = try await runtime.startThread(
            StartThreadRequest(
                cwd: workingDirectory,
                model: request.targetModel.modelID,
                ephemeral: startsEphemeralThreads,
                sandboxMode: sandboxMode,
                approvalPolicy: approvalPolicy
            )
        )
        guard DelegationSafeText.boundedIdentifier(child.id) != nil else {
            _ = try? await runtime.deleteThread(id: child.id)
            throw DelegationExecutorError.execution(
                "The provider returned an invalid child conversation identity."
            )
        }
        var turnMayHaveBeenAccepted = false
        var collector: Task<DelegationOutput, any Error>?
        do {
            try Task.checkCancellation()
            await reportProgress(
                DelegationProgressUpdate(
                    phase: "started",
                    message: Self.nonBlank(child.title)
                )
            )

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
            let output = try await collector!.value
            collector = nil
            await reportProgress(.init(phase: "completed", fraction: 1))
            await cleanupThreadIfNeeded(child.id, interruptFirst: false)
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
            if turnMayHaveBeenAccepted { await interruptBestEffort(threadID: child.id) }
            _ = try? await collector?.value
            await deleteAbandonedThreadBestEffort(child.id)
            throw CancellationError()
        } catch {
            collector?.cancel()
            if turnMayHaveBeenAccepted { await interruptBestEffort(threadID: child.id) }
            _ = try? await collector?.value
            await deleteAbandonedThreadBestEffort(child.id)
            throw error
        }
    }

    private func interruptBestEffort(threadID: String) async {
        _ = try? await runtime.interrupt(threadID: threadID)
    }

    private func resolvedWorkingDirectory(for request: DelegationRequest) -> String {
        guard let requested = request.workingDirectory,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return defaultWorkingDirectory }
        return requested
    }

    private func cleanupThreadIfNeeded(_ threadID: String, interruptFirst: Bool) async {
        guard deletesThreadAfterExecution else { return }
        if interruptFirst { await interruptBestEffort(threadID: threadID) }
        _ = try? await runtime.deleteThread(id: threadID)
    }

    /// A child that never produced a successful delegation result has no UI
    /// join key. Remove that app-created orphan even when successful children
    /// are configured to remain durable and clickable.
    private func deleteAbandonedThreadBestEffort(_ threadID: String) async {
        _ = try? await runtime.deleteThread(id: threadID)
    }

    private static func collectOutput(
        from stream: AsyncStream<AgentRuntimeEvent>,
        threadID: String,
        timeout: Duration,
        reportProgress: @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput {
        try await withThrowingTaskGroup(of: DelegationOutput.self) { group in
            group.addTask {
                try await collectOutputUntilTerminal(
                    from: stream,
                    threadID: threadID,
                    reportProgress: reportProgress
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DelegationExecutorError.provider(
                    "The delegated turn did not reach a terminal state before the timeout."
                )
            }

            guard let output = try await group.next() else {
                throw DelegationExecutorError.provider(
                    "The delegated turn ended without a terminal result."
                )
            }
            group.cancelAll()
            return output
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
