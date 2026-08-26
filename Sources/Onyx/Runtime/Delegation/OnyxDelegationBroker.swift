import Foundation

/// App-server call IDs are only unique within one provider/thread stream.
/// Onyx can host several provider runtimes behind one broker, so every
/// internal cancellation, capacity, and coordinator identity must retain the
/// parent scope instead of trusting a model-authored call ID globally.
private struct OnyxDelegationCallKey: Hashable, Sendable {
    let parentConnectionID: ProviderConnectionID
    let parentThreadID: String
    let callID: String
}

/// Credential-free provider and model snapshot consumed by the delegation
/// broker. Production composition should build this from the current saved
/// connections and cached/live model catalogs. Endpoints, headers, and
/// credentials have no representation here.
struct DelegationProviderConfiguration: Hashable, Sendable {
    let connectionID: ProviderConnectionID
    let displayName: String
    let models: [RuntimeModel]

    init(
        connectionID: ProviderConnectionID,
        displayName: String,
        models: [RuntimeModel]
    ) {
        self.connectionID = connectionID
        self.displayName = displayName
        self.models = models
    }
}

enum OnyxDelegationBrokerErrorCode: String, Codable, Equatable, Sendable {
    case invalidArguments = "invalid_arguments"
    case duplicateCall = "duplicate_call"
    case providerNotConfigured = "provider_not_configured"
    case codexTargetNotAllowed = "codex_target_not_allowed"
    case sameProviderTargetNotAllowed = "same_provider_target_not_allowed"
    case modelNotAvailable = "model_not_available"
    case textInputNotSupported = "text_input_not_supported"
    case reasoningEffortNotSupported = "reasoning_effort_not_supported"
    case providerUnavailable = "provider_unavailable"
    case executionFailed = "execution_failed"
    case cancelled
}

/// Stable structured content encoded into the dynamic tool's one text item.
/// The snake-case keys form the contract consumed by transcript/collaboration
/// projection; all identity values are provider-scoped but credential-free.
struct OnyxDelegationToolPayload: Equatable, Sendable {
    static let type = "onyx_delegation_result"
    static let version = 1

    let success: Bool
    let jobID: String
    let providerConnectionID: String?
    let model: String?
    let reasoningEffort: String?
    let childConversationID: String?
    let text: String?
    let truncated: Bool
    let errorCode: OnyxDelegationBrokerErrorCode?
    let errorMessage: String?

    var jsonValue: JSONValue {
        var value: [String: JSONValue] = [
            "type": .string(Self.type),
            "version": .integer(Self.version),
            "success": .bool(success),
            "job_id": .string(jobID),
            "truncated": .bool(truncated),
        ]
        if let providerConnectionID {
            value["provider_connection_id"] = .string(providerConnectionID)
        }
        if let model { value["model"] = .string(model) }
        if let reasoningEffort {
            value["reasoning_effort"] = .string(reasoningEffort)
        }
        if let childConversationID {
            value["child_conversation_id"] = .string(childConversationID)
        }
        if let text { value["text"] = .string(text) }
        if let errorCode, let errorMessage {
            value["error_code"] = .string(errorCode.rawValue)
            value["error_message"] = .string(errorMessage)
        }
        return .object(value)
    }

    var compactJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(jsonValue) else {
            return #"{"type":"onyx_delegation_result","version":1,"success":false,"job_id":"unknown","truncated":false,"error_code":"execution_failed","error_message":"Onyx could not encode the delegation result."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

}

/// App-lifetime bridge between Codex's `onyx_delegate` dynamic tool and the
/// provider-neutral delegation runtime. It re-resolves the credential-free
/// provider catalog for every call and resolves the shared runtime only after
/// validation, so Settings edits take effect without retaining endpoints or
/// credentials in this layer.
actor OnyxDelegationBroker: CodexDynamicToolHandler {
    typealias ProviderCatalogResolver =
        @Sendable () async throws -> [DelegationProviderConfiguration]
    typealias RuntimeResolver =
        @Sendable (ProviderConnectionID) async throws -> any AgentRuntime

    static let maximumPromptCharacters = 100_000
    static let defaultMaximumResponseCharacters = 32_000
    static let maximumRememberedCallIDs = 4_096
    static let maximumAdvertisedProviders = 64
    static let maximumAdvertisedModels = 256
    static let maximumDefinitionDescriptionCharacters = 4_000

    private struct ActiveJob: Sendable {
        let coordinator: DelegationCoordinator
        let jobID: DelegationJobID
    }

    private let providerCatalogResolver: ProviderCatalogResolver
    private let runtimeResolver: RuntimeResolver
    private let maximumResponseCharacters: Int
    private let maxConcurrentJobs: Int
    private let capacity: DelegationCapacityLimiter

    private var coordinator: DelegationCoordinator?
    private var coordinatorConfiguration: [DelegationProviderConfiguration] = []
    private var activeJobs: [OnyxDelegationCallKey: ActiveJob] = [:]
    /// A call can wait for the app-wide capacity gate before a coordinator
    /// handle exists. Retain its opaque scheduler token for that interval so
    /// cancellation can address exactly one scoped invocation.
    private var jobIDsByCallKey: [OnyxDelegationCallKey: DelegationJobID] = [:]
    /// Duplicate-call history is deliberately bounded, but an invocation that
    /// is still resolving its catalog or waiting for capacity must remain
    /// reserved for its exact parent scope. Without this separate reservation,
    /// evicting an old key could admit a second call and overwrite the first
    /// call's cancellation mapping while its provider work was still running.
    private var inFlightCallKeys: Set<OnyxDelegationCallKey> = []
    private var acceptedCallIDs: Set<OnyxDelegationCallKey> = []
    private var acceptedCallIDOrder: [OnyxDelegationCallKey] = []

    init(
        maxConcurrentJobs: Int = 2,
        maximumResponseCharacters: Int = defaultMaximumResponseCharacters,
        providerCatalogResolver: @escaping ProviderCatalogResolver,
        runtimeResolver: @escaping RuntimeResolver
    ) {
        let boundedConcurrency = max(1, maxConcurrentJobs)
        self.maxConcurrentJobs = boundedConcurrency
        self.maximumResponseCharacters = max(1, maximumResponseCharacters)
        self.providerCatalogResolver = providerCatalogResolver
        self.runtimeResolver = runtimeResolver
        capacity = DelegationCapacityLimiter(limit: boundedConcurrency)
    }

    /// Returns a lightweight provider-scoped facade suitable for runtime
    /// construction from a synchronous composition root. Creating the facade
    /// does not read broker state; its async calls hop to this actor later.
    nonisolated func scopedHandler(
        parentConnectionID: ProviderConnectionID
    ) -> any CodexDynamicToolHandler {
        OnyxScopedDelegationHandler(
            broker: self,
            parentConnectionID: parentConnectionID
        )
    }

    func handleDynamicToolCall(
        _ call: CodexDynamicToolCall
    ) async throws -> CodexDynamicToolResult {
        try await handleDynamicToolCall(
            call,
            parentConnectionID: .codexDefault
        )
    }

    /// Executes a dynamic-tool call on behalf of a provider-scoped parent.
    /// The app-server wire call intentionally remains provider-neutral; the
    /// composition root supplies this identity when it installs the handler
    /// into a non-Codex runtime. Keeping the parent outside model-authored
    /// arguments prevents a child from impersonating another provider.
    func handleDynamicToolCall(
        _ call: CodexDynamicToolCall,
        parentConnectionID: ProviderConnectionID
    ) async throws -> CodexDynamicToolResult {
        let payload = await handle(
            call,
            parentConnectionID: parentConnectionID
        )
        return CodexDynamicToolResult(
            text: payload.compactJSONString,
            success: payload.success
        )
    }

    func dynamicToolDefinition() async -> CodexDynamicToolDefinition {
        // The unscoped handler is the native Codex parent. Never advertise a
        // Codex target to Codex itself; generic parents use the scoped facade
        // below to expose Codex as a valid cross-provider destination.
        await dynamicToolDefinition(excluding: .codexDefault)
    }

    /// Builds a definition for one provider-scoped parent. A parent must not
    /// be offered itself as a target: recursive self-delegation would consume
    /// the same runtime's capacity without crossing a provider boundary.
    func dynamicToolDefinition(
        excluding parentConnectionID: ProviderConnectionID?
    ) async -> CodexDynamicToolDefinition {
        let configurations: [DelegationProviderConfiguration]
        do {
            configurations = try normalizedConfigurations(
                await providerCatalogResolver()
            )
        } catch {
            return .onyxDelegate
        }

        let advertisedProviders = Array(
            configurations
                .filter { $0.connectionID != parentConnectionID }
                .prefix(Self.maximumAdvertisedProviders)
        )
        let providerIDs = advertisedProviders.map(\.connectionID.rawValue)
        var seenModels: Set<String> = []
        let models = advertisedProviders.flatMap(\.models).filter { model in
            seenModels.insert(model.id).inserted
        }
        let modelIDs = Array(
            models.prefix(Self.maximumAdvertisedModels).map(\.id)
        )
        let reasoningEfforts = Array(
            Set(models.flatMap(\.reasoningEfforts)).sorted().prefix(32)
        )

        var providerSchema: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string("Configured Onyx provider connection ID."),
        ]
        var modelSchema: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string("Model ID advertised by the selected provider."),
        ]
        if providerIDs.isEmpty {
            providerSchema["description"] = .string(
                "No non-Codex provider is currently configured in Onyx."
            )
        } else {
            providerSchema["enum"] = .strings(providerIDs)
        }
        if modelIDs.isEmpty {
            modelSchema["description"] = .string(
                "No delegated model is currently available in Onyx."
            )
        } else {
            modelSchema["enum"] = .strings(modelIDs)
        }
        var reasoningSchema: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(
                "Optional reasoning effort supported by the selected model."
            ),
        ]
        if !reasoningEfforts.isEmpty {
            reasoningSchema["enum"] = .strings(reasoningEfforts)
        }

        let summary = advertisedProviders.map { provider in
            let modelSummary = provider.models.prefix(12).map(\.id).joined(separator: ", ")
            let omitted = provider.models.count > 12 ? ", …" : ""
            return "\(provider.displayName) (\(provider.connectionID.rawValue)): \(modelSummary)\(omitted)"
        }.joined(separator: "; ")
        let description = boundedDefinitionDescription(
            summary.isEmpty
                ? "Delegate a bounded, read-only text task to another model configured in Onyx. No non-Codex model is currently available."
                : "Delegate a bounded, read-only text task to another model configured in Onyx. Include all context the child needs because it cannot inspect local files. Available targets: \(summary)"
        )

        return CodexDynamicToolDefinition(
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "provider": .object(providerSchema),
                    "model": .object(modelSchema),
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Self-contained task and all context needed to complete it."
                        ),
                        "maxLength": .integer(Self.maximumPromptCharacters),
                    ]),
                    "reasoningEffort": .object(reasoningSchema),
                ]),
                "required": .strings(["provider", "model", "prompt"]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    /// Clears the immutable executor catalog used for subsequent submissions.
    /// Execution still resolves a current shared runtime per call; this hook is
    /// useful when production Settings already emits a connection mutation.
    func invalidate(connectionID _: ProviderConnectionID? = nil) {
        coordinator = nil
        coordinatorConfiguration = []
    }

    /// Cancels queued or running work associated with a Codex tool call. The
    /// dynamic-tool task's own cancellation also reaches this path.
    @discardableResult
    func cancel(
        callID: String,
        reason: DelegationCancellationReason = .parent
    ) async -> Bool {
        // Compatibility convenience for callers that only have the legacy
        // Codex call ID. If multiple provider scopes share that ID, fail
        // closed rather than cancelling an arbitrary parent's work.
        let candidates = jobIDsByCallKey.compactMap { key, jobID in
            key.callID == callID ? (key, jobID) : nil
        }
        guard candidates.count == 1 else { return false }
        let (key, jobID) = candidates[0]
        return await cancel(callKey: key, jobID: jobID, reason: reason)
    }

    @discardableResult
    func cancel(
        call: CodexDynamicToolCall,
        parentConnectionID: ProviderConnectionID,
        reason: DelegationCancellationReason = .parent
    ) async -> Bool {
        let key = OnyxDelegationCallKey(
            parentConnectionID: parentConnectionID,
            parentThreadID: call.threadID,
            callID: call.callID
        )
        guard let jobID = jobIDsByCallKey[key] else { return false }
        return await cancel(callKey: key, jobID: jobID, reason: reason)
    }

    private func cancel(
        callKey: OnyxDelegationCallKey,
        jobID: DelegationJobID,
        reason: DelegationCancellationReason
    ) async -> Bool {
        let cancelledFromCapacity = await capacity.cancel(jobID: jobID)
        guard let active = activeJobs[callKey], active.jobID == jobID else {
            return cancelledFromCapacity
        }
        do {
            let disposition = try await active.coordinator.cancel(
                jobID,
                reason: reason
            )
            return disposition != .alreadyTerminal || cancelledFromCapacity
        } catch {
            return cancelledFromCapacity
        }
    }

    private func handle(
        _ call: CodexDynamicToolCall,
        parentConnectionID: ProviderConnectionID
    ) async -> OnyxDelegationToolPayload {
        let jobID = boundedIdentifier(call.callID) ?? "invalid"
        guard let arguments = parseArguments(call.arguments) else {
            return failure(
                jobID: jobID,
                code: .invalidArguments,
                message: "Provide a configured provider, model, and non-empty prompt."
            )
        }
        guard jobID == call.callID else {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .invalidArguments,
                message: "The delegation call identity is invalid."
            )
        }
        let callKey = OnyxDelegationCallKey(
            parentConnectionID: parentConnectionID,
            parentThreadID: call.threadID,
            callID: call.callID
        )
        guard !inFlightCallKeys.contains(callKey),
              acceptedCallIDs.insert(callKey).inserted
        else {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .duplicateCall,
                message: "This delegation call was already submitted."
            )
        }
        // Reserve the exact scoped invocation before the first await. The
        // bounded historical ledger may evict this key while it is queued or
        // running, but the reservation remains until this handle returns.
        inFlightCallKeys.insert(callKey)
        defer { inFlightCallKeys.remove(callKey) }
        acceptedCallIDOrder.append(callKey)
        if acceptedCallIDOrder.count > Self.maximumRememberedCallIDs {
            let evicted = acceptedCallIDOrder.removeFirst()
            acceptedCallIDs.remove(evicted)
        }

        let configurations: [DelegationProviderConfiguration]
        do {
            configurations = try normalizedConfigurations(
                await providerCatalogResolver()
            )
        } catch {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .providerUnavailable,
                message: "Onyx could not read the configured provider catalog."
            )
        }

        let connectionID = ProviderConnectionID(arguments.provider)
        guard connectionID != .codexDefault || parentConnectionID != .codexDefault else {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .codexTargetNotAllowed,
                message: "Select a configured non-Codex provider for this delegation."
            )
        }
        guard connectionID != parentConnectionID else {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .sameProviderTargetNotAllowed,
                message: "Choose a different provider for this delegation."
            )
        }
        guard let provider = configurations.first(where: {
            $0.connectionID == connectionID
        }) else {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .providerNotConfigured,
                message: "That provider connection is not configured in Onyx."
            )
        }
        guard let model = provider.models.first(where: {
            $0.id == arguments.model
        }) else {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .modelNotAvailable,
                message: "That model is not available on the selected provider connection."
            )
        }
        guard model.inputModalities.contains(.text) else {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .textInputNotSupported,
                message: "The selected model does not support text input."
            )
        }

        let reasoningEffort = arguments.reasoningEffort ?? model.defaultReasoningEffort
        if let reasoningEffort,
           !model.reasoningEfforts.contains(reasoningEffort)
        {
            return failure(
                jobID: jobID,
                arguments: arguments,
                code: .reasoningEffortNotSupported,
                message: "The requested reasoning level is not supported by the selected model."
            )
        }

        let internalJobID = DelegationJobID()
        jobIDsByCallKey[callKey] = internalJobID
        do {
            try await capacity.acquire(jobID: internalJobID)
        } catch {
            jobIDsByCallKey.removeValue(forKey: callKey)
            return failure(
                jobID: jobID,
                arguments: arguments,
                reasoningEffort: reasoningEffort,
                code: .cancelled,
                message: "The delegated task was cancelled."
            )
        }

        let payload = await withTaskCancellationHandler {
            await execute(
                call: call,
                parentConnectionID: parentConnectionID,
                callKey: callKey,
                internalJobID: internalJobID,
                arguments: arguments,
                reasoningEffort: reasoningEffort,
                configurations: configurations
            )
        } onCancel: {
            Task {
                await self.cancel(
                    callKey: callKey,
                    jobID: internalJobID,
                    reason: .parent
                )
            }
        }
        await capacity.release()
        return payload
    }

    private func execute(
        call: CodexDynamicToolCall,
        parentConnectionID: ProviderConnectionID,
        callKey: OnyxDelegationCallKey,
        internalJobID: DelegationJobID,
        arguments: Arguments,
        reasoningEffort: String?,
        configurations: [DelegationProviderConfiguration]
    ) async -> OnyxDelegationToolPayload {
        defer { jobIDsByCallKey.removeValue(forKey: callKey) }
        if Task.isCancelled {
            return failure(
                jobID: call.callID,
                arguments: arguments,
                reasoningEffort: reasoningEffort,
                code: .cancelled,
                message: "The delegated task was cancelled."
            )
        }

        let selectedCoordinator: DelegationCoordinator
        do {
            selectedCoordinator = try delegationCoordinator(
                configurations: configurations
            )
        } catch {
            return failure(
                jobID: call.callID,
                arguments: arguments,
                reasoningEffort: reasoningEffort,
                code: .providerUnavailable,
                message: "The selected provider connection is unavailable."
            )
        }

        let parentModelID = boundedIdentifier(call.parentModelID) ?? "codex"
        let request = DelegationRequest(
            // Provider call IDs are not globally unique. Keep an opaque
            // Onyx-owned job ID for coordinator lineage/cancellation and use
            // the original call ID only in the sanitized tool payload.
            id: internalJobID,
            parentAgent: DelegationAgentIdentity(
                connectionID: parentConnectionID,
                modelID: parentModelID,
                agentID: "parent"
            ),
            target: DelegationTarget(
                connectionID: ProviderConnectionID(arguments.provider),
                modelID: arguments.model,
                agentID: "delegated"
            ),
            prompt: arguments.prompt,
            reasoningEffort: reasoningEffort,
            workingDirectory: boundedWorkingDirectory(call.workingDirectory)
        )

        do {
            let handle = try await selectedCoordinator.submit(request)
            activeJobs[callKey] = ActiveJob(
                coordinator: selectedCoordinator,
                jobID: handle.jobID
            )
            if Task.isCancelled {
                _ = try? await selectedCoordinator.cancel(handle.jobID, reason: .parent)
            }
            defer {
                activeJobs.removeValue(forKey: callKey)
            }
            let result = try await selectedCoordinator.result(for: handle.jobID)
            return success(
                result,
                externalJobID: call.callID,
                arguments: arguments,
                reasoningEffort: reasoningEffort
            )
        } catch let error as DelegationResultError {
            switch error {
            case .cancelled:
                return failure(
                    jobID: call.callID,
                    arguments: arguments,
                    reasoningEffort: reasoningEffort,
                    code: .cancelled,
                    message: "The delegated task was cancelled."
                )
            case let .failed(delegationFailure):
                return failure(
                    jobID: call.callID,
                    arguments: arguments,
                    reasoningEffort: reasoningEffort,
                    code: delegationFailure.code == .unavailable
                        ? .providerUnavailable
                        : .executionFailed,
                    message: delegationFailure.code == .unavailable
                        ? "The selected provider connection is unavailable."
                        : "The delegated model could not complete the request."
                )
            }
        } catch is CancellationError {
            return failure(
                jobID: call.callID,
                arguments: arguments,
                reasoningEffort: reasoningEffort,
                code: .cancelled,
                message: "The delegated task was cancelled."
            )
        } catch {
            return failure(
                jobID: call.callID,
                arguments: arguments,
                reasoningEffort: reasoningEffort,
                code: .executionFailed,
                message: "Onyx could not complete this delegation."
            )
        }
    }

    private func delegationCoordinator(
        configurations: [DelegationProviderConfiguration]
    ) throws -> DelegationCoordinator {
        if configurations == coordinatorConfiguration, let coordinator {
            return coordinator
        }
        let executors: [any DelegationExecutor] = configurations.map { provider in
            ResolvingAgentRuntimeDelegationExecutor(
                connectionID: provider.connectionID,
                supportedModelIDs: Set(provider.models.map(\.id)),
                runtimeResolver: runtimeResolver
            )
        }
        let replacement = try DelegationCoordinator(
            executors: executors,
            maxConcurrentJobs: maxConcurrentJobs
        )
        coordinatorConfiguration = configurations
        coordinator = replacement
        return replacement
    }

    private struct Arguments: Sendable {
        let provider: String
        let model: String
        let prompt: String
        let reasoningEffort: String?
    }

    private func parseArguments(_ value: JSONValue) -> Arguments? {
        guard let object = value.objectValue,
              let provider = boundedIdentifier(object["provider"]?.stringValue),
              let model = boundedIdentifier(object["model"]?.stringValue),
              let prompt = object["prompt"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty,
              prompt.count <= Self.maximumPromptCharacters
        else { return nil }

        let reasoning: String?
        if let rawReasoning = object["reasoningEffort"] {
            guard let value = boundedIdentifier(rawReasoning.stringValue) else {
                return nil
            }
            reasoning = value
        } else {
            reasoning = nil
        }
        return Arguments(
            provider: provider,
            model: model,
            prompt: prompt,
            reasoningEffort: reasoning
        )
    }

    private func normalizedConfigurations(
        _ values: [DelegationProviderConfiguration]
    ) throws -> [DelegationProviderConfiguration] {
        var seenConnections: Set<ProviderConnectionID> = []
        var normalized: [DelegationProviderConfiguration] = []
        for provider in values {
            guard boundedIdentifier(provider.connectionID.rawValue) != nil,
                  seenConnections.insert(provider.connectionID).inserted
            else { throw BrokerCatalogError.invalid }
            var seenModels: Set<String> = []
            let models = provider.models.filter { model in
                boundedIdentifier(model.id) != nil && seenModels.insert(model.id).inserted
            }.sorted { $0.id < $1.id }
            normalized.append(
                DelegationProviderConfiguration(
                    connectionID: provider.connectionID,
                    displayName: boundedIdentifier(provider.displayName) ?? "Provider",
                    models: models
                )
            )
        }
        return normalized.sorted {
            $0.connectionID.rawValue < $1.connectionID.rawValue
        }
    }

    private func success(
        _ result: DelegationResult,
        externalJobID: String,
        arguments: Arguments,
        reasoningEffort: String?
    ) -> OnyxDelegationToolPayload {
        let requiresBounding = result.text.count > maximumResponseCharacters
        let text: String
        if requiresBounding {
            text = maximumResponseCharacters == 1
                ? "…"
                : String(result.text.prefix(maximumResponseCharacters - 1)) + "…"
        } else {
            text = result.text
        }
        return OnyxDelegationToolPayload(
            success: true,
            jobID: externalJobID,
            providerConnectionID: arguments.provider,
            model: arguments.model,
            reasoningEffort: reasoningEffort,
            childConversationID: result.output.childConversationID,
            text: text,
            truncated: result.isTruncated || requiresBounding,
            errorCode: nil,
            errorMessage: nil
        )
    }

    private func failure(
        jobID: String,
        arguments: Arguments? = nil,
        reasoningEffort: String? = nil,
        code: OnyxDelegationBrokerErrorCode,
        message: String
    ) -> OnyxDelegationToolPayload {
        OnyxDelegationToolPayload(
            success: false,
            jobID: jobID,
            providerConnectionID: arguments?.provider,
            model: arguments?.model,
            reasoningEffort: reasoningEffort ?? arguments?.reasoningEffort,
            childConversationID: nil,
            text: nil,
            truncated: false,
            errorCode: code,
            errorMessage: message
        )
    }

    private func boundedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        return DelegationSafeText.boundedIdentifier(value)
    }

    private func boundedWorkingDirectory(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 4_096
        else { return nil }
        return value
    }

    private func boundedDefinitionDescription(_ value: String) -> String {
        guard value.count > Self.maximumDefinitionDescriptionCharacters else {
            return value
        }
        return String(value.prefix(Self.maximumDefinitionDescriptionCharacters - 1)) + "…"
    }

    private enum BrokerCatalogError: Error { case invalid }
}

/// Provider-scoped view of the app-owned delegation broker. The generic
/// OpenAI-compatible agent lane uses this wrapper when it constructs its
/// pinned app-server runtime; no provider identity is inferred from a model's
/// tool arguments or from the custom model-provider ID.
struct OnyxScopedDelegationHandler: CodexDynamicToolHandler {
    private let broker: OnyxDelegationBroker
    private let parentConnectionID: ProviderConnectionID

    init(
        broker: OnyxDelegationBroker,
        parentConnectionID: ProviderConnectionID
    ) {
        self.broker = broker
        self.parentConnectionID = parentConnectionID
    }

    func dynamicToolDefinition() async -> CodexDynamicToolDefinition {
        await broker.dynamicToolDefinition(excluding: parentConnectionID)
    }

    func handleDynamicToolCall(
        _ call: CodexDynamicToolCall
    ) async throws -> CodexDynamicToolResult {
        try await broker.handleDynamicToolCall(
            call,
            parentConnectionID: parentConnectionID
        )
    }
}

/// Resolves the current app-shared runtime at execution time, after the broker
/// has validated the request against a credential-free catalog snapshot.
private struct ResolvingAgentRuntimeDelegationExecutor: DelegationExecutor {
    let connectionID: ProviderConnectionID
    let supportedModelIDs: Set<String>
    let runtimeResolver: OnyxDelegationBroker.RuntimeResolver

    func supports(model: ModelRef) -> Bool {
        model.connectionID == connectionID
            && supportedModelIDs.contains(model.modelID)
    }

    func execute(
        _ request: DelegationRequest,
        reportProgress: @escaping DelegationProgressReporter
    ) async throws -> DelegationOutput {
        let runtime: any AgentRuntime
        do {
            runtime = try await runtimeResolver(connectionID)
        } catch {
            throw DelegationExecutorError.unavailable
        }
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connectionID,
            runtime: runtime,
            supportedModelIDs: supportedModelIDs,
            startsEphemeralThreads: false,
            deletesThreadAfterExecution: false,
            sandboxMode: .readOnly,
            approvalPolicy: .never
        )
        return try await executor.execute(
            request,
            reportProgress: reportProgress
        )
    }
}

/// App-wide capacity gate retained even while an immutable coordinator is
/// replaced after a provider catalog edit. This prevents two coordinator
/// generations from exceeding the configured global concurrency limit.
private actor DelegationCapacityLimiter {
    private struct Waiter {
        let jobID: DelegationJobID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [UUID: Waiter] = [:]
    private var order: [UUID] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(jobID: DelegationJobID) async throws {
        if Task.isCancelled { throw CancellationError() }
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        jobID: jobID,
                        continuation: continuation
                    )
                    order.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        while let id = order.first {
            order.removeFirst()
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.resume()
            return
        }
        active = max(0, active - 1)
    }

    @discardableResult
    func cancel(jobID: DelegationJobID) -> Bool {
        guard let id = order.first(where: { waiters[$0]?.jobID == jobID }) else {
            return false
        }
        cancel(id: id)
        return true
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
