import CryptoKit
import Foundation

struct OpenAICompatibleRuntimeLaneDecision: Equatable, Sendable {
    enum Basis: Equatable, Sendable {
        /// The provider's current model catalog explicitly advertises a
        /// tool/function-call capability. This starts an app-server agent
        /// attempt immediately; the app-server sandbox, approval, and
        /// malformed-call handling remain the safety boundary.
        case advertisedToolUse
        case compatibleProbe
        case failedProbe(OpenAICompatibleResponsesProbeFailure)
        case unavailableProbe
        case existingTask
    }

    let lane: OpenAICompatibleTaskLane
    let modelID: String
    let ownership: OpenAICompatibleTaskLaneOwnership?
    let basis: Basis
}

enum OpenAICompatibleAdaptiveRuntimeResolverError: LocalizedError, Equatable, Sendable {
    case invalidModel
    case taskScopeMismatch

    var errorDescription: String? {
        switch self {
        case .invalidModel:
            "The selected provider model is invalid."
        case .taskScopeMismatch:
            "This task belongs to an older provider configuration and cannot be moved automatically."
        }
    }
}

/// Publishes a cached new-task lane decision and runs bounded behavioral probes
/// independently. New Task and history loading never await the network: absent
/// evidence fails closed to chat, while a completed probe affects only tasks
/// created after its result is published.
actor OpenAICompatibleAdaptiveRuntimeResolver {
    struct ProbeUpdateSubscription: Sendable {
        let id: UUID
        let stream: AsyncStream<(String, OpenAICompatibleResponsesProbeRecord)>
    }
    private struct ProbeAttempt: Sendable {
        let id: UUID
        let task: Task<OpenAICompatibleResponsesProbeRecord, any Error>
    }

    private let probe: any OpenAICompatibleResponsesCompatibilityProbing
    private let stateStore: OpenAICompatibleAdaptiveStateStore
    private let now: @Sendable () -> Date
    private var cachedRecords: [
        OpenAICompatibleResponsesProbeFingerprint: OpenAICompatibleResponsesProbeRecord
    ] = [:]
    private var attempts: [
        OpenAICompatibleResponsesProbeFingerprint: ProbeAttempt
    ] = [:]
    private var probeUpdateContinuations: [UUID: AsyncStream<(String, OpenAICompatibleResponsesProbeRecord)>.Continuation] = [:]

    init(
        probe: any OpenAICompatibleResponsesCompatibilityProbing,
        stateStore: OpenAICompatibleAdaptiveStateStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.probe = probe
        self.stateStore = stateStore
        self.now = now
    }

    /// Returns only currently reusable evidence. This may await the local state
    /// actor/disk read, but never starts or joins a provider request.
    func resolveNewTask(
        connection: ProviderConnectionRecord,
        modelID rawModelID: String
    ) async throws -> OpenAICompatibleRuntimeLaneDecision {
        guard let result = try await resolveNewTasks(
            connection: connection,
            modelIDs: [rawModelID]
        ).first else {
            throw OpenAICompatibleAdaptiveRuntimeResolverError.invalidModel
        }
        return result
    }

    /// Projects a complete provider catalog with at most one durable-state
    /// read. `modelIDToProbe` is deliberately explicit and singular: catalog
    /// display never fans out network probes, while the user's selected model
    /// can begin its bounded check after the same snapshot proves evidence is
    /// absent.
    func resolveNewTasks(
        connection: ProviderConnectionRecord,
        modelIDs rawModelIDs: [String],
        modelIDToProbe rawModelIDToProbe: String? = nil
    ) async throws -> [OpenAICompatibleRuntimeLaneDecision] {
        let modelIDs = try rawModelIDs.map(Self.validatedModelID)
        let modelIDToProbe = try rawModelIDToProbe.map(Self.validatedModelID)
        let queryDate = now()
        let fingerprints = modelIDs.map {
            OpenAICompatibleResponsesProbeFingerprint(connection: connection, modelID: $0)
        }

        var records: [
            OpenAICompatibleResponsesProbeFingerprint: OpenAICompatibleResponsesProbeRecord
        ] = [:]
        var missing: Set<OpenAICompatibleResponsesProbeFingerprint> = []
        for fingerprint in fingerprints {
            if let cached = cachedRecords[fingerprint],
               cached.isReusable(for: fingerprint, at: queryDate) {
                records[fingerprint] = cached
            } else {
                cachedRecords[fingerprint] = nil
                missing.insert(fingerprint)
            }
        }
        if !missing.isEmpty {
            let persisted = try? await stateStore.probeRecords(for: missing, at: queryDate)
            // The state-store read is an actor suspension. A live probe can
            // finish while it is in flight, so process-local evidence that is
            // present now always wins over the older disk snapshot.
            for fingerprint in missing {
                if let current = cachedRecords[fingerprint],
                   current.isReusable(for: fingerprint, at: queryDate) {
                    records[fingerprint] = current
                } else if let record = persisted?[fingerprint] {
                    cachedRecords[fingerprint] = record
                    records[fingerprint] = record
                }
            }
        }

        let decisions = zip(modelIDs, fingerprints).map { modelID, fingerprint in
            decision(
                modelID: modelID,
                connection: connection,
                record: records[fingerprint]
            )
        }
        if let modelIDToProbe,
           let selected = decisions.first(where: { $0.modelID == modelIDToProbe }),
           selected.basis == .unavailableProbe {
            startProbeWithoutPersistedLookup(
                connection: connection,
                modelID: modelIDToProbe,
                fingerprint: OpenAICompatibleResponsesProbeFingerprint(
                    connection: connection,
                    modelID: modelIDToProbe
                )
            )
        }
        return decisions
    }

    /// Starts one background check per exact connection/scope/model. The caller
    /// returns immediately and can observe `probeUpdates`; no existing task is
    /// reclassified when the result arrives.
    func beginProbe(
        connection: ProviderConnectionRecord,
        modelID rawModelID: String
    ) async throws {
        let modelID = try Self.validatedModelID(rawModelID)
        let fingerprint = OpenAICompatibleResponsesProbeFingerprint(
            connection: connection,
            modelID: modelID
        )
        if cachedRecords[fingerprint]?.isReusable(for: fingerprint, at: now()) == true
            || attempts[fingerprint] != nil {
            return
        }
        if let persisted = try? await stateStore.probeRecord(for: fingerprint, at: now()) {
            cachedRecords[fingerprint] = persisted
            return
        }
        // The state-store read above is an actor suspension. Another caller
        // may have installed or completed this exact probe while we waited.
        guard cachedRecords[fingerprint]?.isReusable(for: fingerprint, at: now()) != true,
              attempts[fingerprint] == nil else { return }

        startProbeWithoutPersistedLookup(
            connection: connection,
            modelID: modelID,
            fingerprint: fingerprint
        )
    }

    private func startProbeWithoutPersistedLookup(
        connection: ProviderConnectionRecord,
        modelID: String,
        fingerprint: OpenAICompatibleResponsesProbeFingerprint
    ) {
        guard cachedRecords[fingerprint]?.isReusable(for: fingerprint, at: now()) != true,
              attempts[fingerprint] == nil else { return }
        let probe = self.probe
        let id = UUID()
        let task = Task {
            try await probe.probe(connection: connection, modelID: modelID)
        }
        attempts[fingerprint] = ProbeAttempt(id: id, task: task)
        Task { [weak self] in
            guard let self else { return }
            await self.finishProbe(
                id: id,
                fingerprint: fingerprint,
                modelID: modelID,
                task: task
            )
        }
    }

    func probeUpdatesSubscription() -> ProbeUpdateSubscription {
        let id = UUID()
        let stream = AsyncStream<(String, OpenAICompatibleResponsesProbeRecord)> { continuation in
            probeUpdateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeProbeUpdateContinuation(id) }
            }
        }
        return ProbeUpdateSubscription(id: id, stream: stream)
    }

    /// Backwards-compatible convenience for callers that only need a stream.
    /// New lifecycle owners should retain the subscription ID and cancel it
    /// explicitly when their runtime generation retires.
    func probeUpdates() -> AsyncStream<(String, OpenAICompatibleResponsesProbeRecord)> {
        probeUpdatesSubscription().stream
    }

    func cancelProbeUpdates(_ id: UUID) {
        guard let continuation = probeUpdateContinuations.removeValue(forKey: id) else {
            return
        }
        continuation.finish()
    }

#if DEBUG
    func activeProbeUpdateSubscriptionCount() -> Int {
        probeUpdateContinuations.count
    }
#endif

    /// Existing tasks use their persisted owner without opening the network or
    /// reconsidering a model. A scope mismatch is rejected instead of replaying
    /// one endpoint's history into another endpoint under the same friendly ID.
    func resolveExistingTask(
        connection: ProviderConnectionRecord,
        ownership: OpenAICompatibleTaskLaneOwnership
    ) throws -> OpenAICompatibleRuntimeLaneDecision {
        guard ownership.connectionID == connection.id,
              ownership.conversationScopeID == connection.conversationScopeID else {
            throw OpenAICompatibleAdaptiveRuntimeResolverError.taskScopeMismatch
        }
        return OpenAICompatibleRuntimeLaneDecision(
            lane: ownership.lane,
            modelID: ownership.modelID,
            ownership: ownership,
            basis: .existingTask
        )
    }

    func invalidateProbeCache() {
        cachedRecords.removeAll()
        for attempt in attempts.values { attempt.task.cancel() }
        attempts.removeAll()
    }

    private func finishProbe(
        id: UUID,
        fingerprint: OpenAICompatibleResponsesProbeFingerprint,
        modelID: String,
        task: Task<OpenAICompatibleResponsesProbeRecord, any Error>
    ) async {
        defer {
            if attempts[fingerprint]?.id == id { attempts[fingerprint] = nil }
        }
        guard let record = try? await task.value,
              attempts[fingerprint]?.id == id,
              record.fingerprint == fingerprint,
              !Task.isCancelled else { return }
        let completionDate = now()
        guard record.isReusable(for: fingerprint, at: completionDate) else { return }

        if case .failed = record.outcome {
            // Failed evidence is safe to retain in memory even if persistence
            // fails because it can only keep the model on the chat lane.
            try? await stateStore.storeProbeRecord(record, at: completionDate)
        }
        guard attempts[fingerprint]?.id == id, !Task.isCancelled else { return }
        // Compatible evidence is intentionally current-process only. The
        // durable state file is not authenticated, so persisted success could
        // otherwise be edited to unlock local tools on a later launch.
        cachedRecords[fingerprint] = record
        for continuation in probeUpdateContinuations.values {
            continuation.yield((modelID, record))
        }
    }

    private func removeProbeUpdateContinuation(_ id: UUID) {
        probeUpdateContinuations[id] = nil
    }

    private func decision(
        modelID: String,
        lane: OpenAICompatibleTaskLane,
        basis: OpenAICompatibleRuntimeLaneDecision.Basis
    ) -> OpenAICompatibleRuntimeLaneDecision {
        OpenAICompatibleRuntimeLaneDecision(
            lane: lane,
            modelID: modelID,
            ownership: nil,
            basis: basis
        )
    }

    private func decision(
        modelID: String,
        connection: ProviderConnectionRecord,
        record: OpenAICompatibleResponsesProbeRecord?
    ) -> OpenAICompatibleRuntimeLaneDecision {
        // A catalog-level tool/function-call declaration is enough to start
        // the real app-server agent path. It is intentionally model-agnostic:
        // model IDs are not a capability allow-list, and a stale synthetic
        // probe failure must not strand a provider that has already told us it
        // can make tool calls. The app-server sandbox, approval flow, and
        // malformed/rejected-call handling remain the runtime safety boundary.
        if connection.discovery.discoveredModels.first(where: { $0.id == modelID })?
            .capabilities.serverAdvertisesToolUse == true {
            return decision(
                modelID: modelID,
                lane: .agent,
                basis: .advertisedToolUse
            )
        }
        guard let record else {
            return decision(modelID: modelID, lane: .chat, basis: .unavailableProbe)
        }
        switch record.outcome {
        case .compatible:
            return decision(modelID: modelID, lane: .agent, basis: .compatibleProbe)
        case let .failed(failure):
            return decision(modelID: modelID, lane: .chat, basis: .failedProbe(failure))
        }
    }

    private static func validatedModelID(_ rawModelID: String) throws -> String {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, modelID.utf8.count <= 512 else {
            throw OpenAICompatibleAdaptiveRuntimeResolverError.invalidModel
        }
        return modelID
    }
}

/// Stable, non-secret identity shared by every agent-capable model in one
/// connection scope. Endpoint, display name, credential, and model do not
/// influence the app-server state directory.
struct OpenAICompatibleAgentRuntimeIdentity: Equatable, Hashable, Sendable {
    let modelProviderID: String
    let stateIdentifier: String

    init(connection: ProviderConnectionRecord) {
        let material = [
            "onyx-openai-compatible-agent-runtime-v1",
            connection.id.rawValue,
            connection.conversationScopeID,
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        modelProviderID = "onyx-openai-compatible-\(digest)"
        stateIdentifier = "provider_\(digest)"
    }
}

struct OpenAICompatibleAgentProxyLease: Sendable {
    let baseURL: URL
    let disposableAPIKey: String
    private let stopAction: @Sendable () async -> Void

    init(
        baseURL: URL,
        disposableAPIKey: String,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.baseURL = baseURL
        self.disposableAPIKey = disposableAPIKey
        stopAction = stop
    }

    func stop() async {
        await stopAction()
    }
}

enum OpenAICompatibleAgentRuntimeFactoryError: LocalizedError, Equatable, Sendable {
    case credentialUnavailable
    case invalidProxyBinding
    case proxyCredentialReuse

    var errorDescription: String? {
        switch self {
        case .credentialUnavailable:
            "Provider authentication is unavailable."
        case .invalidProxyBinding:
            "The private Responses proxy returned an invalid launch binding."
        case .proxyCredentialReuse:
            "The private Responses proxy did not isolate the provider credential."
        }
    }
}

/// Owns the prepared runtime and proxy as one explicit lifecycle. The adaptive
/// runtime that consumes this seam must retain the prepared value and call
/// `shutdown()` when its shared coordinator retires; exposing a bare runtime
/// here would make it too easy to strand a credential-injecting listener.
struct OpenAICompatiblePreparedAgentRuntime: Sendable {
    let runtime: any AgentRuntime
    let identity: OpenAICompatibleAgentRuntimeIdentity
    private let shutdownGate: OpenAICompatibleAgentRuntimeShutdownGate

    fileprivate init(
        runtime: any AgentRuntime,
        identity: OpenAICompatibleAgentRuntimeIdentity,
        proxy: OpenAICompatibleAgentProxyLease
    ) {
        self.runtime = runtime
        self.identity = identity
        shutdownGate = OpenAICompatibleAgentRuntimeShutdownGate(
            runtime: runtime,
            proxy: proxy
        )
    }

    func shutdown() async {
        await shutdownGate.shutdown()
    }
}

private actor OpenAICompatibleAgentRuntimeShutdownGate {
    private let runtime: any AgentRuntime
    private let proxy: OpenAICompatibleAgentProxyLease
    private var isStopped = false

    init(runtime: any AgentRuntime, proxy: OpenAICompatibleAgentProxyLease) {
        self.runtime = runtime
        self.proxy = proxy
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        // Retire the credential-injecting listener first.  App-server
        // shutdown is normally quick, but it is an external process and can
        // become stuck while a request or child process is unwinding.  The
        // proxy must not remain reachable with the provider credential in
        // that case, so its lifetime cannot depend on `disconnect()`
        // completing.  Any in-flight request is cancelled by stopping the
        // proxy; app-server then observes the closed transport as it is
        // disconnected below.
        await proxy.stop()
        await runtime.disconnect()
    }
}

/// Production-capable construction boundary for the agent lane. The upstream
/// credential is supplied only to the loopback proxy. App-server receives the
/// proxy's separately generated disposable token through its launch binding.
struct OpenAICompatibleAgentRuntimeFactory: Sendable {
    typealias ProxyFactory = @Sendable (
        ProviderConnectionRecord,
        ProviderBearerCredential?
    ) async throws -> OpenAICompatibleAgentProxyLease
    typealias RuntimeFactory = @Sendable (
        CodexRuntimeModelProviderBinding,
        (any CodexDynamicToolHandler)?
    ) throws -> any AgentRuntime
    typealias LegacyRuntimeFactory = @Sendable (
        CodexRuntimeModelProviderBinding
    ) throws -> any AgentRuntime

    private let credentialStore: any CredentialStore
    private let dynamicToolHandler: (any CodexDynamicToolHandler)?
    private let proxyFactory: ProxyFactory
    private let runtimeFactory: RuntimeFactory

    init(
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        dynamicToolHandler: (any CodexDynamicToolHandler)? = nil,
        proxyFactory: @escaping ProxyFactory = OpenAICompatibleAgentRuntimeFactory.productionProxy,
        runtimeFactory: @escaping RuntimeFactory = { binding, handler in
            try CodexRuntime.makeDefault(
                modelProvider: binding,
                dynamicToolHandler: handler
            )
        }
    ) {
        self.credentialStore = credentialStore
        self.dynamicToolHandler = dynamicToolHandler
        self.proxyFactory = proxyFactory
        self.runtimeFactory = runtimeFactory
    }

    /// Source-compatible seam for focused integrations that only need to
    /// capture the proxy binding. Such factories intentionally opt out of
    /// dynamic delegation; production uses the two-argument initializer
    /// above so the scoped broker reaches app-server.
    init(
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        proxyFactory: @escaping ProxyFactory = OpenAICompatibleAgentRuntimeFactory.productionProxy,
        runtimeFactory: @escaping LegacyRuntimeFactory
    ) {
        self.init(
            credentialStore: credentialStore,
            dynamicToolHandler: nil,
            proxyFactory: proxyFactory,
            runtimeFactory: { binding, _ in try runtimeFactory(binding) }
        )
    }

    func prepare(
        connection unvalidatedConnection: ProviderConnectionRecord
    ) async throws -> OpenAICompatiblePreparedAgentRuntime {
        let connection = try unvalidatedConnection.revalidated()
        let credential: ProviderBearerCredential?
        switch connection.authMode {
        case .none:
            credential = nil
        case .bearer:
            credential = try await credentialStore.credential(for: connection.credentialKey)
            guard credential != nil else {
                throw OpenAICompatibleAgentRuntimeFactoryError.credentialUnavailable
            }
        }

        let proxy = try await proxyFactory(connection, credential)
        do {
            try Self.validate(proxy: proxy, upstreamCredential: credential)
            let identity = OpenAICompatibleAgentRuntimeIdentity(connection: connection)
            let binding = CodexRuntimeModelProviderBinding(
                id: identity.modelProviderID,
                baseURL: proxy.baseURL,
                apiKey: proxy.disposableAPIKey,
                stateIdentifier: identity.stateIdentifier
            )
            let runtime = try runtimeFactory(binding, dynamicToolHandler)
            return OpenAICompatiblePreparedAgentRuntime(
                runtime: runtime,
                identity: identity,
                proxy: proxy
            )
        } catch {
            await proxy.stop()
            throw error
        }
    }

    private static func productionProxy(
        connection: ProviderConnectionRecord,
        credential: ProviderBearerCredential?
    ) async throws -> OpenAICompatibleAgentProxyLease {
        let proxy = try OpenAICompatibleResponsesProxy(
            connection: connection,
            upstreamCredential: credential
        )
        let binding = try await proxy.start()
        return OpenAICompatibleAgentProxyLease(
            baseURL: binding.baseURL,
            disposableAPIKey: binding.bearerToken,
            stop: { await proxy.stop() }
        )
    }

    private static func validate(
        proxy: OpenAICompatibleAgentProxyLease,
        upstreamCredential: ProviderBearerCredential?
    ) throws {
        guard proxy.baseURL.scheme?.lowercased() == "http",
              proxy.baseURL.host == "127.0.0.1",
              proxy.baseURL.port != nil,
              proxy.baseURL.user == nil,
              proxy.baseURL.password == nil,
              proxy.baseURL.query == nil,
              proxy.baseURL.fragment == nil,
              proxy.baseURL.path == "/v1",
              !proxy.disposableAPIKey.isEmpty,
              proxy.disposableAPIKey.utf8.count <= 1_024,
              !proxy.disposableAPIKey.contains(where: {
                  $0.isWhitespace || $0.isNewline || $0 == "\0"
              }) else {
            throw OpenAICompatibleAgentRuntimeFactoryError.invalidProxyBinding
        }
        let reusesCredential = try upstreamCredential?.withValue {
            $0 == proxy.disposableAPIKey
        } ?? false
        guard !reusesCredential else {
            throw OpenAICompatibleAgentRuntimeFactoryError.proxyCredentialReuse
        }
    }
}
