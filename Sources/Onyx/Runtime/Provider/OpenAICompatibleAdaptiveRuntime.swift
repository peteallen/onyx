import Foundation

/// One provider-facing runtime that keeps chat and app-server task histories
/// separate while presenting one task catalog to the Onyx workspace. New tasks
/// choose a lane from durable compatibility evidence; every later operation is
/// routed by the task's persisted owner.
actor OpenAICompatibleAdaptiveRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind = .local
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let connectionID: ProviderConnectionID
    private let connectionStore: ProviderConnectionStore
    private let chatRuntime: any AgentRuntime
    private let resolver: OpenAICompatibleAdaptiveRuntimeResolver
    private let stateStore: OpenAICompatibleAdaptiveStateStore
    private let agentFactory: OpenAICompatibleAgentRuntimeFactory
    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation

    private var connection: ProviderConnectionRecord?
    private var session: RuntimeSession?
    private var agentRuntime: OpenAICompatiblePreparedAgentRuntime?
    private var agentRuntimeID: UUID?
    private var agentEventTask: Task<Void, Never>?
    private struct PendingAgentPreparation: Sendable {
        let id: UUID
        let scope: RuntimeScope
        let task: Task<OpenAICompatiblePreparedAgentRuntime, any Error>
    }
    private var agentPreparation: PendingAgentPreparation?
    /// Keep the reusable chat stream and the resolver subscription separate.
    /// The chat iterator must remain alive until `chatRuntime.disconnect()` has
    /// emitted its terminal boundary; otherwise that buffered disconnect can
    /// be replayed into the next generation. The probe iterator, by contrast,
    /// can be cancelled and explicitly unsubscribed as soon as a generation is
    /// retired.
    private var chatEventTask: Task<Void, Never>?
#if DEBUG
    private var chatEventPumpStartCount = 0
#endif
    private var probeUpdateTask: Task<Void, Never>?
    private var probeUpdateSubscriptionID: UUID?
    private struct PendingTaskEvent: Sendable {
        let event: AgentRuntimeEvent
        let scope: RuntimeScope
        let agentRuntimeID: UUID?
    }
    /// App-server may emit the initial task event before the ownership write
    /// in `startThread` has committed. Quarantine those events briefly so a
    /// newly-created task never appears to have lost its first output.
    private var pendingTaskEvents: [String: [PendingTaskEvent]] = [:]
    private static let maximumPendingTaskEventsPerThread = 256
    private struct RuntimeScope: Equatable, Hashable, Sendable {
        let generation: UInt64
        let connectionID: ProviderConnectionID
        let conversationScopeID: String
    }

    /// A task operation carries the exact provider scope and runtime handle it
    /// was admitted against.  Actor reentrancy means the connection can rotate
    /// while a provider call is suspended; validating this lease prevents a
    /// stale read/mutation from being dispatched to the replacement runtime.
    private struct TaskLease: Sendable {
        let scope: RuntimeScope
        let owner: OpenAICompatibleTaskLaneOwnership
        let runtime: any AgentRuntime
        let runtimeThreadID: String
    }

    private struct InteractionOrigin: Equatable, Hashable, Sendable {
        let scope: RuntimeScope
        let agentRuntimeID: UUID?
        let lane: OpenAICompatibleTaskLane
        let runtimeID: RuntimeRequestID
    }

    private struct InteractionResolutionEntry: Equatable, Sendable {
        let token: UUID
        let publicID: RuntimeRequestID
    }

    private struct SettledInteraction: Equatable, Sendable {
        let origin: InteractionOrigin
        let token: UUID
    }

    private struct PendingInteraction: Sendable {
        let token: UUID
        let scope: RuntimeScope
        let agentRuntimeID: UUID?
        let lane: OpenAICompatibleTaskLane
        let runtimeID: RuntimeRequestID
        var responseAttemptID: UUID?
    }

    private struct PendingCreation: Equatable, Sendable {
        let token: UUID
        let scope: RuntimeScope
        let lane: OpenAICompatibleTaskLane
        var publicThreadID: String?
    }

    private var pendingInteractions: [RuntimeRequestID: PendingInteraction] = [:]
    private var interactionResolutionOrder: [
        InteractionOrigin: [InteractionResolutionEntry]
    ] = [:]
    private var settledInteractionOrder: [SettledInteraction] = []
    private static let maximumSettledInteractionTombstones = 1_024
    private var activeAgentThreadIDs: Set<String> = []
    /// Ephemeral side chats are deliberately absent from durable ownership,
    /// but need lane routing for the lifetime of this runtime generation.
    private var ephemeralAgentThreadIDs: Set<String> = []
    /// Public agent task IDs hydrated once per connection generation. The
    /// transcript event hot path must not decode the state file for every
    /// token or tool update; durable lookup is only a race fallback.
    private var agentOwnedThreadIDs: Set<String> = []
    private var chatOwnedThreadIDs: Set<String> = []
    /// A first missing-owner lookup is remembered for this connection
    /// generation. Creation commits clear it and replay the bounded buffer.
    private var unownedEventThreadIDs: Set<String> = []
    private static let maximumUnownedEventThreadIDs = 1_024
    private static let maximumPendingEventThreads = 64
    private var pendingCreations: [UUID: PendingCreation] = [:]
    private var connected = false
    private var generation: UInt64 = 0
    /// Distinguishes account/model snapshots within one connection generation.
    /// A background probe can outlive a refresh without changing `generation`;
    /// this revision prevents that older probe from overwriting newer account
    /// metadata when it publishes its catalog.
    private var sessionRevision: UInt64 = 0
    /// A disconnect detaches the old runtimes synchronously, then finishes
    /// their potentially slow shutdown out of line.  New connects wait for
    /// this task so a replacement generation can never share a live proxy or
    /// provider session with the retiring one.
    private struct PendingTeardown: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var teardownTask: PendingTeardown?

    /// `SharedRuntimeCoordinator` normally coalesces connection handshakes,
    /// but the facade is also exercised directly by tests and development
    /// integrations. Keep that boundary safe in its own right: one connect
    /// owns the chat iterator and resolver subscription, while every caller
    /// awaits the same result.
    private struct ConnectAttempt: Sendable {
        let id: UUID
        let task: Task<RuntimeSession, any Error>
    }
    private var connectAttempt: ConnectAttempt?

    private struct DisconnectContext: Sendable {
        let retiringGeneration: UInt64
        let pendingConnect: ConnectAttempt?
        let pendingRefresh: RefreshAttempt?
        let awaitRefreshAttempt: Bool
    }
    private struct DisconnectAttempt: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var disconnectAttempt: DisconnectAttempt?

    private struct RefreshAttempt: Sendable {
        let id: UUID
        let generation: UInt64
        let task: Task<RuntimeSession, any Error>
    }
    private var refreshAttempt: RefreshAttempt?

    /// A terminal app-server event detaches its generation synchronously, then
    /// retires the credential proxy out of line. Agent preparation, refresh,
    /// and disconnect must all await this boundary so the replacement can
    /// never overlap the old listener.
    private struct PendingAgentShutdown: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var agentShutdownTask: PendingAgentShutdown?

    private static let chatTaskCapabilities: RuntimeCapabilities = [
        .streaming, .interruption, .threadArchiving, .threadDeletion,
        .threadHistoryRevert, .reasoning, .images, .usage,
    ]
    private static let agentTaskCapabilities: RuntimeCapabilities = [
        .streaming, .steering, .interruption, .approvals, .threadForking,
        .threadArchiving, .threadCompaction, .threadDeletion, .reasoning,
        .tools, .diffs, .codeReview, .terminal, .images, .usage,
        .ephemeralThreadForking, .threadHistoryPagination, .threadHistoryRevert,
    ]

    init(
        connectionID: ProviderConnectionID,
        connectionStore: ProviderConnectionStore = ProviderConnectionStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        conversationStore: OpenAICompatibleConversationStore = OpenAICompatibleConversationStore(),
        stateStore: OpenAICompatibleAdaptiveStateStore = OpenAICompatibleAdaptiveStateStore(),
        resolver: OpenAICompatibleAdaptiveRuntimeResolver? = nil,
        dynamicToolHandler: (any CodexDynamicToolHandler)? = nil,
        agentFactory: OpenAICompatibleAgentRuntimeFactory? = nil,
        chatRuntime: (any AgentRuntime)? = nil
    ) {
        self.connectionID = connectionID
        self.connectionStore = connectionStore
        self.stateStore = stateStore
        self.chatRuntime = chatRuntime ?? OpenAICompatibleRuntime(
            connectionID: connectionID,
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            conversationStore: conversationStore
        )
        self.resolver = resolver ?? OpenAICompatibleAdaptiveRuntimeResolver(
            probe: OpenAICompatibleResponsesCompatibilityProbe(
                credentialStore: credentialStore
            ),
            stateStore: stateStore
        )
        self.agentFactory = agentFactory ?? OpenAICompatibleAgentRuntimeFactory(
            credentialStore: credentialStore,
            dynamicToolHandler: dynamicToolHandler
        )
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        chatEventTask?.cancel()
        probeUpdateTask?.cancel()
        if let probeUpdateSubscriptionID {
            let resolver = resolver
            Task { await resolver.cancelProbeUpdates(probeUpdateSubscriptionID) }
        }
        agentEventTask?.cancel()
        connectAttempt?.task.cancel()
        disconnectAttempt?.task.cancel()
        refreshAttempt?.task.cancel()
        teardownTask?.task.cancel()
        agentShutdownTask?.task.cancel()
        eventContinuation.finish()
    }

    /// Retires one generation's providers in a deterministic order.  The chat
    /// runtime owns a reusable AsyncStream, so its iterator stays alive until
    /// `disconnect()` has emitted the terminal boundary.  Every other pump is
    /// generation-scoped and can be cancelled first.  Keeping this sequence in
    /// one helper prevents connect-failure, explicit-disconnect, and scope
    /// rotation paths from drifting apart.
    private func makeGenerationTeardown(
        chatEventTask: Task<Void, Never>?,
        probeUpdateTask: Task<Void, Never>?,
        probeUpdateSubscriptionID: UUID?,
        agentEventTask: Task<Void, Never>?,
        agentRuntime: OpenAICompatiblePreparedAgentRuntime?,
        agentPreparation: PendingAgentPreparation?,
        disconnectChat: Bool
    ) -> Task<Void, Never> {
        let resolver = resolver
        let chatRuntime = chatRuntime
        return Task {
            probeUpdateTask?.cancel()
            if let probeUpdateSubscriptionID {
                await resolver.cancelProbeUpdates(probeUpdateSubscriptionID)
            }
            if let probeUpdateTask { await probeUpdateTask.value }

            // Stop the old app-server/proxy before replacing it. Its runtime
            // may emit a final terminal event during shutdown; keep the pump
            // alive until shutdown returns so that event is consumed and
            // quarantined by the generation guard.
            if let agentRuntime { await agentRuntime.shutdown() }
            if let agentPreparation,
               let prepared = try? await agentPreparation.task.value {
                await prepared.shutdown()
            }
            agentEventTask?.cancel()
            if let agentEventTask { await agentEventTask.value }

            // Do this before cancelling the chat pump. OpenAICompatibleRuntime
            // publishes `.disconnected` from its disconnect method; consuming
            // that event here prevents it from remaining buffered for the next
            // iterator. Scope rotation uses the same boundary even though the
            // adaptive facade will immediately reconnect the chat lane.
            if disconnectChat {
                await chatRuntime.disconnect()
            }
            chatEventTask?.cancel()
            if let chatEventTask { await chatEventTask.value }
            await resolver.invalidateProbeCache()
        }
    }

    func connect() async throws -> RuntimeSession {
        if let pendingDisconnect = disconnectAttempt {
            await pendingDisconnect.task.value
            if disconnectAttempt?.id == pendingDisconnect.id {
                disconnectAttempt = nil
            }
            guard !Task.isCancelled else { throw CancellationError() }
        }
        if let session, connected { return session }
        // A scope-changing refresh owns the replacement handshake. Direct
        // callers join it instead of opening a second iterator after the old
        // generation's teardown completes.
        if let refreshAttempt {
            return try await refreshAttempt.task.value
        }
        if let connectAttempt {
            return try await connectAttempt.task.value
        }
        let id = UUID()
        let task = Task { [weak self] () throws -> RuntimeSession in
            guard let self else { throw CancellationError() }
            return try await self.performConnect()
        }
        let attempt = ConnectAttempt(id: id, task: task)
        connectAttempt = attempt
        do {
            let result = try await task.value
            if connectAttempt?.id == id { connectAttempt = nil }
            return result
        } catch {
            if connectAttempt?.id == id { connectAttempt = nil }
            throw error
        }
    }

    private func performConnect() async throws -> RuntimeSession {
        if let pendingTeardown = teardownTask {
            await pendingTeardown.task.value
            if teardownTask?.id == pendingTeardown.id {
                teardownTask = nil
            }
        }
        if let pendingAgentShutdown = agentShutdownTask {
            await pendingAgentShutdown.task.value
            if agentShutdownTask?.id == pendingAgentShutdown.id {
                agentShutdownTask = nil
            }
        }
        guard !Task.isCancelled else { throw CancellationError() }
        if let session, connected { return session }
        generation &+= 1
        let currentGeneration = generation
        // The reusable chat stream buffers handshake events.  Start its pump
        // only after the complete session/ownership snapshot is committed so
        // legitimate connection lifecycle events emitted by the provider
        // during `connect()` are not dropped while `connected` is false. A
        // prior generation is drained by `makeGenerationTeardown` before this
        // method can begin, so stale disconnect boundaries cannot leak here.
        let chatSession: RuntimeSession
        do {
            chatSession = try await chatRuntime.connect()
        } catch {
            if generation == currentGeneration {
                connected = false
                connection = nil
                session = nil
                sessionRevision &+= 1
                agentOwnedThreadIDs.removeAll()
                chatOwnedThreadIDs.removeAll()
                // `connect()` may have emitted a failed/connecting event into
                // the reusable stream before throwing. Consume that terminal
                // boundary before the next generation subscribes; forwarding
                // is harmless because `connected` is already false.
                let detachedChatEventTask = chatEventTask
                    ?? startEventPump(
                        from: chatRuntime,
                        lane: .chat,
                        generation: currentGeneration,
                        agentRuntimeID: nil
                    )
                chatEventTask = nil
                let cleanup = makeGenerationTeardown(
                    chatEventTask: detachedChatEventTask,
                    probeUpdateTask: nil,
                    probeUpdateSubscriptionID: nil,
                    agentEventTask: nil,
                    agentRuntime: nil,
                    agentPreparation: nil,
                    disconnectChat: true
                )
                let pendingCleanup = PendingTeardown(id: UUID(), task: cleanup)
                teardownTask = pendingCleanup
                await pendingCleanup.task.value
                if teardownTask?.id == pendingCleanup.id { teardownTask = nil }
            }
            throw error
        }
        do {
            guard let connection = try await connectionStore.connection(id: connectionID) else {
                throw OpenAICompatibleRuntimeError.connectionNotFound(connectionID)
            }
            guard currentGeneration == generation else { throw CancellationError() }
            let owners = try await stateStore.taskOwnerships(
                connectionID: connection.id,
                conversationScopeID: connection.conversationScopeID
            )
            let probeUpdates = await resolver.probeUpdatesSubscription()
            // Retain the subscription before any projection can suspend. If a
            // catalog read or compatibility lookup fails, the catch path must
            // still be able to finish this continuation rather than leaking a
            // resolver observer into the next generation.
            probeUpdateSubscriptionID = probeUpdates.id
            var projected = try await models(
                chatSession.availableModels,
                for: connection,
                startMissingProbes: true
            )
            if projected.isEmpty { projected = chatSession.availableModels }
            guard currentGeneration == generation,
                  let latestConnection = try await connectionStore.connection(id: connectionID),
                  latestConnection.id == connection.id,
                  latestConnection.conversationScopeID == connection.conversationScopeID else {
                throw CancellationError()
            }

            self.connection = connection
            agentOwnedThreadIDs = Set(owners.lazy.filter { $0.lane == .agent }.map(\.threadID))
            chatOwnedThreadIDs = Set(owners.lazy.filter { $0.lane == .chat }.map(\.threadID))
            connected = true
            let snapshot = sessionSnapshot(base: chatSession, models: projected)
            session = snapshot
            sessionRevision &+= 1
            // Hydrate ownership and commit the complete session before
            // subscribing to events. A failed projection cannot leave a
            // half-connected facade visible to another window.
            startEventPumps(generation: currentGeneration, probeUpdates: probeUpdates)
            return snapshot
        } catch {
            if generation == currentGeneration {
                connected = false
                connection = nil
                session = nil
                sessionRevision &+= 1
                agentOwnedThreadIDs.removeAll()
                chatOwnedThreadIDs.removeAll()
                let detachedChatEventTask = chatEventTask
                    ?? startEventPump(
                        from: chatRuntime,
                        lane: .chat,
                        generation: currentGeneration,
                        agentRuntimeID: nil
                    )
                chatEventTask = nil
                let detachedProbeUpdateTask = probeUpdateTask
                probeUpdateTask = nil
                let detachedProbeSubscriptionID = probeUpdateSubscriptionID
                probeUpdateSubscriptionID = nil
                let cleanup = makeGenerationTeardown(
                    chatEventTask: detachedChatEventTask,
                    probeUpdateTask: detachedProbeUpdateTask,
                    probeUpdateSubscriptionID: detachedProbeSubscriptionID,
                    agentEventTask: nil,
                    agentRuntime: nil,
                    agentPreparation: nil,
                    disconnectChat: true
                )
                let pendingCleanup = PendingTeardown(id: UUID(), task: cleanup)
                teardownTask = pendingCleanup
                await pendingCleanup.task.value
                if teardownTask?.id == pendingCleanup.id { teardownTask = nil }
            }
            throw error
        }
    }

    func disconnect() async {
        await coordinateDisconnect(awaitRefreshAttempt: true)
    }

    private func coordinateDisconnect(awaitRefreshAttempt: Bool) async {
        if let pendingDisconnect = disconnectAttempt {
            await pendingDisconnect.task.value
            if disconnectAttempt?.id == pendingDisconnect.id {
                disconnectAttempt = nil
            }
            return
        }

        // Fence synchronously before publishing the task that performs slow
        // provider shutdown. `connect()` can now observe and join this exact
        // boundary; there is no reentrant gap where it can start a late
        // handshake while disconnect is waiting for an older one to settle.
        let context = beginDisconnect(awaitRefreshAttempt: awaitRefreshAttempt)
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finishDisconnect(context)
        }
        let attempt = DisconnectAttempt(id: id, task: task)
        disconnectAttempt = attempt
        await task.value
        if disconnectAttempt?.id == id { disconnectAttempt = nil }
    }

    private func beginDisconnect(awaitRefreshAttempt: Bool) -> DisconnectContext {
        // Advance the facade generation before any potentially slow provider
        // teardown. Operations admitted after this point fail closed. Keep the
        // retiring value for the rare fallback chat pump below.
        let retiringGeneration = generation
        let pendingConnect = connectAttempt
        let pendingRefresh = refreshAttempt
        generation &+= 1
        pendingConnect?.task.cancel()
        connectAttempt = nil
        pendingRefresh?.task.cancel()
        refreshAttempt = nil
        connected = false
        session = nil
        sessionRevision &+= 1
        connection = nil
        resolveAndClearPendingInteractions()
        activeAgentThreadIDs.removeAll()
        ephemeralAgentThreadIDs.removeAll()
        agentOwnedThreadIDs.removeAll()
        chatOwnedThreadIDs.removeAll()
        unownedEventThreadIDs.removeAll()
        pendingTaskEvents.removeAll()
        pendingCreations.removeAll()

        return DisconnectContext(
            retiringGeneration: retiringGeneration,
            pendingConnect: pendingConnect,
            pendingRefresh: pendingRefresh,
            awaitRefreshAttempt: awaitRefreshAttempt
        )
    }

    private func finishDisconnect(_ context: DisconnectContext) async {
        // A provider connect is not required to react to cancellation. Wait
        // for any admitted handshake to leave the actor boundary before
        // disconnecting the reusable chat lane, otherwise a late connect can
        // resurrect it after this method returns. The refresh failure path is
        // itself running inside `pendingRefresh`, so it explicitly skips that
        // one self-wait below.
        if let pendingConnect = context.pendingConnect {
            _ = await pendingConnect.task.result
        }
        if context.awaitRefreshAttempt, let pendingRefresh = context.pendingRefresh {
            _ = await pendingRefresh.task.result
        }

        // A second disconnect may arrive while the first one is awaiting a
        // provider shutdown. Do not create another iterator for the reusable
        // chat stream: it would outlive this call and leak a subscriber. The
        // first teardown already owns every detached pump.
        if let pendingTeardown = teardownTask {
            await pendingTeardown.task.value
            if teardownTask?.id == pendingTeardown.id {
                teardownTask = nil
            }
            if let pendingAgentShutdown = agentShutdownTask {
                await pendingAgentShutdown.task.value
                if agentShutdownTask?.id == pendingAgentShutdown.id {
                    agentShutdownTask = nil
                }
            }
            return
        }

        if let pendingAgentShutdown = agentShutdownTask {
            await pendingAgentShutdown.task.value
            if agentShutdownTask?.id == pendingAgentShutdown.id {
                agentShutdownTask = nil
            }
        }

        // Another disconnect can take ownership while this call waits for a
        // terminal agent shutdown. Join that teardown rather than creating a
        // second chat iterator.
        if let pendingTeardown = teardownTask {
            await pendingTeardown.task.value
            if teardownTask?.id == pendingTeardown.id {
                teardownTask = nil
            }
            return
        }

        let detachedChatEventTask = chatEventTask
            ?? startEventPump(
                from: chatRuntime,
                lane: .chat,
                generation: context.retiringGeneration,
                agentRuntimeID: nil
            )
        chatEventTask = nil
        let detachedProbeUpdateTask = probeUpdateTask
        probeUpdateTask = nil
        let detachedProbeSubscriptionID = probeUpdateSubscriptionID
        probeUpdateSubscriptionID = nil
        let detachedAgentEventTask = agentEventTask
        agentEventTask = nil
        agentRuntimeID = nil
        let detachedAgentRuntime = agentRuntime
        agentRuntime = nil
        let detachedAgentPreparation = agentPreparation
        agentPreparation = nil

        // The reusable chat iterator is intentionally not cancelled yet.  The
        // provider emits its `.disconnected` boundary from `disconnect()`;
        // leaving this iterator alive lets it consume and quarantine that
        // event before the task is cancelled. Probe/agent iterators are tied
        // to the retiring generation and can be cancelled immediately.
        detachedProbeUpdateTask?.cancel()
        detachedAgentEventTask?.cancel()
        detachedAgentPreparation?.task.cancel()

        let teardown = makeGenerationTeardown(
            chatEventTask: detachedChatEventTask,
            probeUpdateTask: detachedProbeUpdateTask,
            probeUpdateSubscriptionID: detachedProbeSubscriptionID,
            agentEventTask: detachedAgentEventTask,
            agentRuntime: detachedAgentRuntime,
            agentPreparation: detachedAgentPreparation,
            disconnectChat: true
        )
        let pendingTeardown = PendingTeardown(id: UUID(), task: teardown)
        teardownTask = pendingTeardown
        await pendingTeardown.task.value
        if teardownTask?.id == pendingTeardown.id { teardownTask = nil }
    }

    func startLogin(methodID: String) async throws -> RuntimeLoginStart {
        try await chatRuntime.startLogin(methodID: methodID)
    }

    func cancelLogin(id: String) async throws {
        try await chatRuntime.cancelLogin(id: id)
    }

    func logout() async throws {
        try await chatRuntime.logout()
    }

    func refreshAccount() async throws -> RuntimeSession {
        if let refreshAttempt {
            return try await refreshAttempt.task.value
        }
        guard connected else { return try await connect() }
        let refreshGeneration = generation
        let id = UUID()
        let task = Task { [weak self] () throws -> RuntimeSession in
            guard let self else { throw CancellationError() }
            return try await self.performRefresh(generation: refreshGeneration)
        }
        refreshAttempt = RefreshAttempt(id: id, generation: refreshGeneration, task: task)
        do {
            let result = try await task.value
            if refreshAttempt?.id == id { refreshAttempt = nil }
            return result
        } catch {
            if refreshAttempt?.id == id { refreshAttempt = nil }
            throw error
        }
    }

    private func performRefresh(generation refreshGeneration: UInt64) async throws -> RuntimeSession {
        let previousConnection = try currentConnection()
        let refreshed = try await chatRuntime.refreshAccount()
        do {
            guard let nextConnection = try await connectionStore.connection(id: connectionID)
            else { throw OpenAICompatibleRuntimeError.connectionNotFound(connectionID) }
            guard connected, generation == refreshGeneration else { throw CancellationError() }

            let scopeChanged = previousConnection.id != nextConnection.id
                || previousConnection.conversationScopeID != nextConnection.conversationScopeID

            // The common path keeps the existing pumps and generation. Validate
            // the persisted record again immediately before publishing so a
            // settings save that wins during discovery cannot become stale UI.
            if !scopeChanged {
                let owners = try await stateStore.taskOwnerships(
                    connectionID: nextConnection.id,
                    conversationScopeID: nextConnection.conversationScopeID
                )
                var projected = try await models(
                    refreshed.availableModels,
                    for: nextConnection,
                    startMissingProbes: true
                )
                if projected.isEmpty { projected = refreshed.availableModels }
                guard connected, generation == refreshGeneration,
                      let latest = try await connectionStore.connection(id: connectionID),
                      latest.id == nextConnection.id,
                      latest.conversationScopeID == nextConnection.conversationScopeID else {
                    throw CancellationError()
                }
                let snapshot = sessionSnapshot(base: refreshed, models: projected)
                connection = nextConnection
                agentOwnedThreadIDs = Set(owners.lazy.filter { $0.lane == .agent }.map(\.threadID))
                chatOwnedThreadIDs = Set(owners.lazy.filter { $0.lane == .chat }.map(\.threadID))
                session = snapshot
                sessionRevision &+= 1
                return snapshot
            }

            // Capture replacement ownership before fencing. It is only used
            // after the new runtime has connected and passed the latest-record
            // check below.
            let owners = try await stateStore.taskOwnerships(
                connectionID: nextConnection.id,
                conversationScopeID: nextConnection.conversationScopeID
            )
            guard connected, generation == refreshGeneration else { throw CancellationError() }

            if let pendingAgentShutdown = agentShutdownTask {
                await pendingAgentShutdown.task.value
                if agentShutdownTask?.id == pendingAgentShutdown.id {
                    agentShutdownTask = nil
                }
                guard connected, generation == refreshGeneration else {
                    throw CancellationError()
                }
            }

            let detachedChatEventTask = chatEventTask
            chatEventTask = nil
            let detachedProbeUpdateTask = probeUpdateTask
            probeUpdateTask = nil
            let detachedProbeSubscriptionID = probeUpdateSubscriptionID
            probeUpdateSubscriptionID = nil
            let detachedAgentEventTask = agentEventTask
            agentEventTask = nil
            let retiredAgent = agentRuntime
            agentRuntime = nil
            let retiredPreparation = agentPreparation
            agentPreparation = nil
            retiredPreparation?.task.cancel()

            // Fence before awaiting teardown. New operations now fail closed;
            // they cannot pair this generation with the old connection.
            generation &+= 1
            let replacementGeneration = generation
            connected = false
            connection = nil
            session = nil
            sessionRevision &+= 1
            agentRuntimeID = nil
            resolveAndClearPendingInteractions()
            activeAgentThreadIDs.removeAll()
            ephemeralAgentThreadIDs.removeAll()
            unownedEventThreadIDs.removeAll()
            pendingTaskEvents.removeAll()
            pendingCreations.removeAll()

            let teardown = makeGenerationTeardown(
                chatEventTask: detachedChatEventTask,
                probeUpdateTask: detachedProbeUpdateTask,
                probeUpdateSubscriptionID: detachedProbeSubscriptionID,
                agentEventTask: detachedAgentEventTask,
                agentRuntime: retiredAgent,
                agentPreparation: retiredPreparation,
                disconnectChat: true
            )
            let pendingTeardown = PendingTeardown(id: UUID(), task: teardown)
            teardownTask = pendingTeardown
            await pendingTeardown.task.value
            if teardownTask?.id == pendingTeardown.id { teardownTask = nil }
            guard generation == replacementGeneration, !Task.isCancelled else {
                throw CancellationError()
            }

            // Leave the reusable stream unconsumed during the replacement
            // handshake. Once the replacement snapshot is committed below,
            // `startEventPumps` drains the buffered handshake events under the
            // new generation instead of silently dropping them while the
            // facade is disconnected.
            var replacementSubscription: OpenAICompatibleAdaptiveRuntimeResolver.ProbeUpdateSubscription?
            do {
                let replacementChatSession = try await chatRuntime.connect()
                guard generation == replacementGeneration, !Task.isCancelled,
                      let latest = try await connectionStore.connection(id: connectionID),
                      latest.id == nextConnection.id,
                      latest.conversationScopeID == nextConnection.conversationScopeID else {
                    throw CancellationError()
                }
                let subscription = await resolver.probeUpdatesSubscription()
                replacementSubscription = subscription
                var projected = try await models(
                    replacementChatSession.availableModels,
                    for: nextConnection,
                    startMissingProbes: true
                )
                if projected.isEmpty { projected = replacementChatSession.availableModels }
                guard generation == replacementGeneration, !Task.isCancelled,
                      let finalRecord = try await connectionStore.connection(id: connectionID),
                      finalRecord.id == nextConnection.id,
                      finalRecord.conversationScopeID == nextConnection.conversationScopeID else {
                    throw CancellationError()
                }

                let snapshot = sessionSnapshot(base: replacementChatSession, models: projected)
                connection = nextConnection
                agentOwnedThreadIDs = Set(owners.lazy.filter { $0.lane == .agent }.map(\.threadID))
                chatOwnedThreadIDs = Set(owners.lazy.filter { $0.lane == .chat }.map(\.threadID))
                session = snapshot
                sessionRevision &+= 1
                connected = true
                startEventPumps(generation: replacementGeneration, probeUpdates: subscription)
                return snapshot
            } catch {
                // Replacement failure must leave a genuinely disconnected
                // facade and must not strand a probe subscription or iterator.
                if generation == replacementGeneration {
                    let failedChatPump = chatEventTask
                        ?? startEventPump(
                            from: chatRuntime,
                            lane: .chat,
                            generation: replacementGeneration,
                            agentRuntimeID: nil
                        )
                    chatEventTask = nil
                    let failedProbeTask = probeUpdateTask
                    probeUpdateTask = nil
                    let failedProbeID = probeUpdateSubscriptionID
                    probeUpdateSubscriptionID = nil
                    let failedCleanup = makeGenerationTeardown(
                        chatEventTask: failedChatPump,
                        probeUpdateTask: failedProbeTask,
                        probeUpdateSubscriptionID: failedProbeID ?? replacementSubscription?.id,
                        agentEventTask: nil,
                        agentRuntime: nil,
                        agentPreparation: nil,
                        disconnectChat: true
                    )
                    let pendingFailedTeardown = PendingTeardown(id: UUID(), task: failedCleanup)
                    teardownTask = pendingFailedTeardown
                    await pendingFailedTeardown.task.value
                    if teardownTask?.id == pendingFailedTeardown.id {
                        teardownTask = nil
                    }
                    connected = false
                    connection = nil
                    session = nil
                } else if let replacementSubscription {
                    await resolver.cancelProbeUpdates(replacementSubscription.id)
                }
                throw error
            }
        } catch {
            // `chatRuntime.refreshAccount()` commits its provider snapshot
            // before returning. If projection fails before the scope fence,
            // retire the old facade rather than retaining a mixed scope.
            if connected, generation == refreshGeneration {
                await coordinateDisconnect(awaitRefreshAttempt: false)
            }
            throw error
        }
    }

    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread] {
        let all = try await mergedThreads(archived: archived, complete: false, limit: limit)
        return Array(all.prefix(max(0, limit)))
    }

    func listAllThreads(archived: Bool) async throws -> [RuntimeThread] {
        try await mergedThreads(archived: archived, complete: true, limit: Int.max)
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        let conversation = try await lease.runtime.readThread(id: lease.runtimeThreadID)
        try validate(scope)
        let projected = try await publicConversation(
            conversation,
            lane: lease.owner.lane,
            modelID: lease.owner.modelID
        )
        try validate(scope)
        return projected
    }

    func readThread(
        id: String,
        initialHistoryPage: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        guard lease.owner.lane == .agent else {
            let conversation = try await lease.runtime.readThread(id: lease.runtimeThreadID)
            try validate(scope)
            let projected = try await publicConversation(
                conversation,
                lane: .chat,
                modelID: lease.owner.modelID
            )
            try validate(scope)
            return RuntimeThreadResumeResult(
                conversation: projected,
                initialHistoryPage: nil,
                turnsBackwardsCursor: nil,
                itemsBackwardsCursor: nil
            )
        }
        var result = try await lease.runtime.readThread(
            id: lease.runtimeThreadID,
            initialHistoryPage: initialHistoryPage
        )
        try validate(scope)
        result.conversation = try await publicConversation(
            result.conversation,
            lane: lease.owner.lane,
            modelID: lease.owner.modelID
        )
        if var page = result.initialHistoryPage {
            page.turns = try await publicTurns(page.turns, lane: lease.owner.lane)
            result.initialHistoryPage = page
        }
        try validate(scope)
        return result
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        let conversation = try await lease.runtime.resumeThread(id: lease.runtimeThreadID)
        try validate(scope)
        let projected = try await publicConversation(
            conversation,
            lane: lease.owner.lane,
            modelID: lease.owner.modelID
        )
        try validate(scope)
        return projected
    }

    func resumeThread(
        id: String,
        initialHistoryPage: RuntimeInitialThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        guard lease.owner.lane == .agent else {
            let conversation = try await lease.runtime.resumeThread(id: lease.runtimeThreadID)
            try validate(scope)
            let projected = try await publicConversation(
                conversation,
                lane: .chat,
                modelID: lease.owner.modelID
            )
            try validate(scope)
            return RuntimeThreadResumeResult(
                conversation: projected,
                initialHistoryPage: nil,
                turnsBackwardsCursor: nil,
                itemsBackwardsCursor: nil
            )
        }
        var result = try await lease.runtime.resumeThread(
            id: lease.runtimeThreadID,
            initialHistoryPage: initialHistoryPage
        )
        try validate(scope)
        result.conversation = try await publicConversation(
            result.conversation,
            lane: lease.owner.lane,
            modelID: lease.owner.modelID
        )
        if var page = result.initialHistoryPage {
            page.turns = try await publicTurns(page.turns, lane: lease.owner.lane)
            result.initialHistoryPage = page
        }
        try validate(scope)
        return result
    }

    func listThreadHistory(
        id: String,
        page: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadHistoryPage {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        guard lease.owner.lane == .agent else {
            throw AgentRuntimeError.unsupported("paginated chat history")
        }
        var history = try await lease.runtime.listThreadHistory(
            id: lease.runtimeThreadID,
            page: page
        )
        try validate(scope)
        history.turns = try await publicTurns(history.turns, lane: .agent)
        try validate(scope)
        return history
    }

    func revertThread(id: String, beforeTurnID: String) async throws -> RuntimeThreadRevertResult {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        var result = try await lease.runtime.revertThread(
            id: lease.runtimeThreadID,
            beforeTurnID: beforeTurnID
        )
        try validate(scope)
        result.thread = publicThread(
            result.thread,
            lane: lease.owner.lane,
            modelID: result.thread.model ?? lease.owner.modelID
        )
        result.thread.taskCapabilities = taskCapabilities(
            for: lease.owner.lane,
            modelID: result.thread.model ?? lease.owner.modelID
        )
        return result
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        let connection = try currentConnection()
        let scope = try currentScope()
        let modelID = try selectedModelID(request.model)
        let decision = try await resolver.resolveNewTaskAwaitingProbe(
            connection: connection,
            modelID: modelID
        )
        try validate(scope)
        let laneRuntime = try await runtime(for: decision.lane)
        try validate(scope)
        let creationToken = try beginPendingCreation(in: decision.lane, scope: scope)
        // The resolver's selected model is the durable task identity. Pass it
        // through to the provider even when the caller omitted `model`; an
        // omitted field would let a lane runtime choose a different default
        // than the model recorded in Onyx ownership metadata.
        var routedRequest = request
        routedRequest.model = modelID
        var createdThread: RuntimeThread?
        var persistedOwnership = false
        do {
            let runtimeThread = try await laneRuntime.startThread(routedRequest)
            createdThread = runtimeThread
            var thread = publicThread(
                runtimeThread,
                lane: decision.lane,
                modelID: modelID
            )
            let publicThreadID = thread.id
            associatePendingCreation(creationToken, with: publicThreadID)
            try validate(scope)

            _ = try await stateStore.recordTaskOwnership(
                connectionID: scope.connectionID,
                conversationScopeID: scope.conversationScopeID,
                threadID: publicThreadID,
                lane: decision.lane,
                modelID: modelID,
                updatedAt: thread.updatedAt
            )
            persistedOwnership = true
            try validate(scope)

            rememberOwnedThread(publicThreadID, lane: decision.lane)
            await flushPendingTaskEvents(
                for: publicThreadID,
                lane: decision.lane,
                scope: scope
            )
            try validate(scope)
            finishPendingCreation(creationToken, discardAssociatedEvents: false)
            // A lane proves the execution semantics (chat vs. Responses
            // agent), but the selected model still owns input/reasoning
            // capability projection.  Do not let an agent-capable text-only
            // model inherit image or reasoning controls from the lane.
            thread.taskCapabilities = taskCapabilities(
                for: decision.lane,
                modelID: modelID
            )
            return thread
        } catch {
            if persistedOwnership, let createdThread {
                _ = try? await stateStore.removeTaskOwnership(
                    connectionID: scope.connectionID,
                    conversationScopeID: scope.conversationScopeID,
                    threadID: publicThread(createdThread, lane: decision.lane).id
                )
            }
            if let createdThread, isCurrent(scope) {
                try? await laneRuntime.deleteThread(id: createdThread.id)
            }
            finishPendingCreation(creationToken, discardAssociatedEvents: true)
            throw error
        }
    }

    func forkThread(id: String) async throws -> RuntimeThread {
        let scope = try currentScope()
        let owner = try await ownership(threadID: id)
        try validate(scope)
        guard owner.connectionID == scope.connectionID,
              owner.conversationScopeID == scope.conversationScopeID else {
            throw OpenAICompatibleAdaptiveRuntimeResolverError.taskScopeMismatch
        }
        let laneRuntime = try await runtime(for: owner.lane)
        try validate(scope)
        let creationToken = try beginPendingCreation(in: owner.lane, scope: scope)
        var createdThread: RuntimeThread?
        var persistedOwnership = false
        do {
            let runtimeThread = try await laneRuntime.forkThread(
                id: try Self.runtimeThreadID(id, for: owner.lane)
            )
            createdThread = runtimeThread
            var thread = publicThread(
                runtimeThread,
                lane: owner.lane,
                modelID: owner.modelID
            )
            let publicThreadID = thread.id
            associatePendingCreation(creationToken, with: publicThreadID)
            try validate(scope)

            _ = try await stateStore.recordTaskOwnership(
                connectionID: scope.connectionID,
                conversationScopeID: scope.conversationScopeID,
                threadID: publicThreadID,
                lane: owner.lane,
                modelID: thread.model ?? owner.modelID,
                updatedAt: thread.updatedAt
            )
            persistedOwnership = true
            try validate(scope)

            rememberOwnedThread(publicThreadID, lane: owner.lane)
            await flushPendingTaskEvents(
                for: publicThreadID,
                lane: owner.lane,
                scope: scope
            )
            try validate(scope)
            finishPendingCreation(creationToken, discardAssociatedEvents: false)
            thread.taskCapabilities = taskCapabilities(
                for: owner.lane,
                modelID: thread.model ?? owner.modelID
            )
            return thread
        } catch {
            if persistedOwnership, let createdThread {
                _ = try? await stateStore.removeTaskOwnership(
                    connectionID: scope.connectionID,
                    conversationScopeID: scope.conversationScopeID,
                    threadID: publicThread(createdThread, lane: owner.lane).id
                )
            }
            if let createdThread, isCurrent(scope) {
                try? await laneRuntime.deleteThread(id: createdThread.id)
            }
            finishPendingCreation(creationToken, discardAssociatedEvents: true)
            throw error
        }
    }

    func forkEphemeralThread(id: String) async throws -> RuntimeConversation {
        let scope = try currentScope()
        guard try await existingLane(threadID: id) == .agent else {
            throw AgentRuntimeError.unsupported("side chat for chat-only provider tasks")
        }
        try validate(scope)
        let agentRuntime = try await agent()
        try validate(scope)
        let creationToken = try beginPendingCreation(in: .agent, scope: scope)
        var createdRawThreadID: String?
        do {
            var conversation = try await agentRuntime.forkEphemeralThread(
                id: try Self.rawAgentThreadID(id)
            )
            createdRawThreadID = conversation.thread.id
            let publicThreadID = Self.publicAgentThreadID(conversation.thread.id)
            associatePendingCreation(creationToken, with: publicThreadID)
            try validate(scope)

            // The ephemeral fork has no durable lane record, but every
            // operation still reaches this facade with its qualified public
            // ID. Keep this identity process-local only.
            rememberOwnedThread(publicThreadID, lane: .agent)
            ephemeralAgentThreadIDs.insert(publicThreadID)
            await flushPendingTaskEvents(for: publicThreadID, lane: .agent, scope: scope)
            try validate(scope)
            conversation = try await publicConversation(
                conversation,
                lane: .agent,
                modelID: conversation.thread.model ?? selectedModelID(nil)
            )
            try validate(scope)
            finishPendingCreation(creationToken, discardAssociatedEvents: false)
            return conversation
        } catch {
            if let createdRawThreadID, isCurrent(scope) {
                try? await agentRuntime.interrupt(threadID: createdRawThreadID)
            }
            finishPendingCreation(creationToken, discardAssociatedEvents: true)
            throw error
        }
    }

    func compactThread(id: String) async throws {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        try await lease.runtime.compactThread(id: lease.runtimeThreadID)
        try validate(scope)
    }

    func deleteThread(id: String) async throws {
        let scope = try currentScope()
        let wasEphemeral = ephemeralAgentThreadIDs.contains(id)
        let owner = try await ownership(threadID: id)
        // `ownership` may suspend while another window rotates this runtime.
        // Never send a delete through the replacement lane for an owner read
        // that belonged to the previous connection scope.
        try validate(scope)
        guard owner.connectionID == scope.connectionID,
              owner.conversationScopeID == scope.conversationScopeID else {
            throw CancellationError()
        }
        let laneRuntime = try await runtime(for: owner.lane)
        try validate(scope)
        try await laneRuntime.deleteThread(
            id: try Self.runtimeThreadID(id, for: owner.lane)
        )
        // The provider deletion is the commit point. Local routing metadata
        // is cleanup and must not turn a successful delete into a user-facing
        // failure (or invite a retry against an already-deleted task).
        if !wasEphemeral {
            _ = try? await stateStore.removeTaskOwnership(
                connectionID: owner.connectionID,
                conversationScopeID: owner.conversationScopeID,
                threadID: id
            )
        }
        // A reconnect can install a new cache while the provider delete is in
        // flight. Only mutate cache/quarantine state if this exact generation
        // is still current; the durable cleanup above is scoped by owner key.
        if isCurrent(scope) {
            forgetOwnedThread(id, lane: owner.lane)
            pendingTaskEvents[id] = nil
            ephemeralAgentThreadIDs.remove(id)
        }
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        let scope = try currentScope()
        let connection = try currentConnection()
        // Side-chat forks are deliberately process-local. Capture this before
        // any suspension so a reconnect cannot make an in-flight ephemeral
        // turn look like a durable task that should be persisted.
        let isEphemeral = ephemeralAgentThreadIDs.contains(request.threadID)
        let owner = try await ownership(threadID: request.threadID)
        try validate(scope)
        guard owner.connectionID == scope.connectionID,
              owner.conversationScopeID == scope.conversationScopeID else {
            throw CancellationError()
        }
        let requestedModelID = request.model
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let requestedModelID,
           requestedModelID != owner.modelID,
           owner.lane == .agent {
            let decision = try await resolver.resolveNewTaskAwaitingProbe(
                connection: connection,
                modelID: requestedModelID
            )
            try validate(scope)
            guard decision.lane == .agent else {
                throw AgentRuntimeError.unsupported(
                    "switching this agent task to a model without verified agent tools"
                )
            }
        }
        try validateModelInputs(
            request.inputs,
            reasoningEffort: request.reasoningEffort,
            modelID: requestedModelID ?? owner.modelID
        )
        var routedRequest = request
        routedRequest.model = requestedModelID
        routedRequest.threadID = try Self.runtimeThreadID(request.threadID, for: owner.lane)
        let laneRuntime = try await runtime(for: owner.lane)
        try validate(scope)
        try await laneRuntime.startTurn(routedRequest)
        // Once the lane runtime returns, the provider has accepted the turn.
        // A local metadata write cannot be rolled back atomically with that
        // provider operation, so never report its failure as a failed send.
        if !isEphemeral,
           let modelID = requestedModelID,
           modelID != owner.modelID {
            _ = try? await stateStore.recordTaskOwnership(
                connectionID: owner.connectionID,
                conversationScopeID: owner.conversationScopeID,
                threadID: owner.threadID,
                lane: owner.lane,
                modelID: modelID
            )
        }
    }

    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun {
        let scope = try currentScope()
        let lease = try await taskLease(for: request.threadID, scope: scope)
        var routedRequest = request
        routedRequest.threadID = lease.runtimeThreadID
        let result = try await lease.runtime.startReview(routedRequest)
        try validate(scope)
        return RuntimeReviewRun(
            threadID: lease.owner.lane == .agent
                ? Self.publicAgentThreadID(result.threadID)
                : Self.publicChatThreadID(result.threadID),
            turnID: result.turnID
        )
    }

    func steer(threadID: String, text: String) async throws {
        let scope = try currentScope()
        let lease = try await taskLease(for: threadID, scope: scope)
        try await lease.runtime.steer(
            threadID: lease.runtimeThreadID,
            text: text
        )
        try validate(scope)
    }

    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws {
        let scope = try currentScope()
        let lease = try await taskLease(for: threadID, scope: scope)
        try validateModelInputs(
            inputs,
            reasoningEffort: nil,
            modelID: lease.owner.modelID
        )
        try await lease.runtime.steer(
            threadID: lease.runtimeThreadID,
            inputs: inputs
        )
        try validate(scope)
    }

    func interrupt(threadID: String) async throws {
        let scope = try currentScope()
        let lease = try await taskLease(for: threadID, scope: scope)
        try await lease.runtime.interrupt(threadID: lease.runtimeThreadID)
        try validate(scope)
    }

    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {
        guard var pending = pendingInteractions[interactionID] else {
            throw AgentRuntimeError.protocolFailure("This provider interaction is no longer pending")
        }
        try validate(pending.scope)
        guard pending.responseAttemptID == nil else {
            throw AgentRuntimeError.protocolFailure(
                "A response to this provider interaction is already in progress"
            )
        }

        let targetRuntime: any AgentRuntime
        switch pending.lane {
        case .chat:
            targetRuntime = chatRuntime
        case .agent:
            guard pending.agentRuntimeID == agentRuntimeID,
                  let agentRuntime else {
                throw AgentRuntimeError.protocolFailure(
                    "This provider interaction belongs to a retired agent session"
                )
            }
            targetRuntime = agentRuntime.runtime
        }

        let responseAttemptID = UUID()
        pending.responseAttemptID = responseAttemptID
        pendingInteractions[interactionID] = pending
        do {
            try await targetRuntime.respond(to: pending.runtimeID, with: response)
        } catch {
            if var current = pendingInteractions[interactionID],
               current.token == pending.token,
               current.responseAttemptID == responseAttemptID {
                current.responseAttemptID = nil
                pendingInteractions[interactionID] = current
            }
            throw error
        }

        // The provider may publish its resolved event before `respond`
        // returns. Only settle the exact request token if it is still pending;
        // a reused provider request ID has a different public identity.
        if let current = pendingInteractions[interactionID],
           current.token == pending.token,
           current.responseAttemptID == responseAttemptID {
            settlePendingInteraction(
                publicID: interactionID,
                pending: current,
                keepResolutionTombstone: true
            )
        }
    }

    func renameThread(id: String, name: String) async throws {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        try await lease.runtime.renameThread(
            id: lease.runtimeThreadID,
            name: name
        )
        try validate(scope)
    }

    func archiveThread(id: String) async throws {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        try await lease.runtime.archiveThread(id: lease.runtimeThreadID)
        try validate(scope)
    }

    func unarchiveThread(id: String) async throws {
        let scope = try currentScope()
        let lease = try await taskLease(for: id, scope: scope)
        try await lease.runtime.unarchiveThread(id: lease.runtimeThreadID)
        try validate(scope)
    }

    private func mergedThreads(
        archived: Bool,
        complete: Bool,
        limit: Int
    ) async throws -> [RuntimeThread] {
        let scope = try currentScope()
        let connection = try currentConnection()
        let requestedLimit = complete ? Int.max : max(0, limit)
        async let chat = complete
            ? chatRuntime.listAllThreads(archived: archived)
            : chatRuntime.listThreads(limit: requestedLimit, archived: archived)
        let agentOwners = try await stateStore.taskOwnerships(
            connectionID: connection.id,
            conversationScopeID: connection.conversationScopeID,
            lane: .agent
        )
        try validate(scope)
        for owner in agentOwners { rememberOwnedThread(owner.threadID, lane: .agent) }
        let agentThreads: [RuntimeThread]
        if agentOwners.isEmpty {
            agentThreads = []
        } else {
            let runtime = try await agent()
            try validate(scope)
            agentThreads = complete
                ? try await runtime.listAllThreads(archived: archived)
                : try await runtime.listThreads(limit: requestedLimit, archived: archived)
            try validate(scope)
        }
        let ownersByThread = Dictionary(uniqueKeysWithValues: agentOwners.map { ($0.threadID, $0) })
        var byID: [String: RuntimeThread] = [:]
        for thread in try await chat {
            try validate(scope)
            let projectedThread = publicThread(thread, lane: .chat)
            // Listing a legacy chat task is sufficient process-local evidence
            // that this exact raw ID belongs to the chat lane. Keep its live
            // events flowing even before the first explicit read persists the
            // ownership migration.
            rememberOwnedThread(projectedThread.id, lane: .chat)
            byID[projectedThread.id] = projectedThread
        }
        for var thread in agentThreads {
            thread = publicThread(thread, lane: .agent)
            guard ownersByThread[thread.id] != nil else { continue }
            byID[thread.id] = thread
        }
        let sorted = byID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        try validate(scope)
        return complete ? sorted : Array(sorted.prefix(requestedLimit))
    }

    private func ownership(threadID: String) async throws -> OpenAICompatibleTaskLaneOwnership {
        let connection = try currentConnection()
        let scope = try currentScope()
        if ephemeralAgentThreadIDs.contains(threadID) {
            return OpenAICompatibleTaskLaneOwnership(
                connectionID: scope.connectionID,
                conversationScopeID: scope.conversationScopeID,
                threadID: threadID,
                lane: .agent,
                modelID: try selectedModelID(nil),
                updatedAt: .now
            )
        }
        if let owner = try await stateStore.taskOwnership(
            connectionID: connection.id,
            conversationScopeID: connection.conversationScopeID,
            threadID: threadID
        ) {
            try validate(scope)
            _ = try await resolver.resolveExistingTask(connection: connection, ownership: owner)
            try validate(scope)
            rememberOwnedThread(owner.threadID, lane: owner.lane)
            return owner
        }
        try validate(scope)
        // Every task created before the adaptive runtime was chat-owned. Claim
        // that legacy task lazily only if the chat store can actually read it.
        // The reserved agent namespace is never claimed by a legacy chat row.
        guard !threadID.hasPrefix(Self.publicAgentThreadPrefix) else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        let conversation = try await chatRuntime.readThread(
            id: try Self.runtimeThreadID(threadID, for: .chat)
        )
        try validate(scope)
        let modelID = try conversation.thread.model ?? selectedModelID(nil)
        let owner = try await stateStore.recordTaskOwnership(
            connectionID: scope.connectionID,
            conversationScopeID: scope.conversationScopeID,
            threadID: threadID,
            lane: .chat,
            modelID: modelID,
            updatedAt: conversation.thread.updatedAt
        )
        try validate(scope)
        rememberOwnedThread(owner.threadID, lane: owner.lane)
        await flushPendingTaskEvents(for: owner.threadID, lane: owner.lane, scope: scope)
        try validate(scope)
        return owner
    }

    private func existingLane(threadID: String) async throws -> OpenAICompatibleTaskLane {
        try await ownership(threadID: threadID).lane
    }

    private func taskLease(
        for threadID: String,
        scope: RuntimeScope
    ) async throws -> TaskLease {
        let owner = try await ownership(threadID: threadID)
        try validate(scope)
        guard owner.connectionID == scope.connectionID,
              owner.conversationScopeID == scope.conversationScopeID else {
            throw OpenAICompatibleAdaptiveRuntimeResolverError.taskScopeMismatch
        }
        let targetRuntime = try await runtime(for: owner.lane)
        try validate(scope)
        return TaskLease(
            scope: scope,
            owner: owner,
            runtime: targetRuntime,
            runtimeThreadID: try Self.runtimeThreadID(threadID, for: owner.lane)
        )
    }

    private func rememberOwnedThread(
        _ publicThreadID: String,
        lane: OpenAICompatibleTaskLane
    ) {
        unownedEventThreadIDs.remove(publicThreadID)
        switch lane {
        case .agent:
            chatOwnedThreadIDs.remove(publicThreadID)
            agentOwnedThreadIDs.insert(publicThreadID)
        case .chat:
            agentOwnedThreadIDs.remove(publicThreadID)
            chatOwnedThreadIDs.insert(publicThreadID)
        }
    }

    private func forgetOwnedThread(
        _ publicThreadID: String,
        lane: OpenAICompatibleTaskLane
    ) {
        switch lane {
        case .agent: agentOwnedThreadIDs.remove(publicThreadID)
        case .chat: chatOwnedThreadIDs.remove(publicThreadID)
        }
        unownedEventThreadIDs.insert(publicThreadID)
    }

    private func resolveAndClearPendingInteractions() {
        for id in pendingInteractions.keys {
            eventContinuation.yield(.userInteractionResolved(id))
        }
        pendingInteractions.removeAll()
        interactionResolutionOrder.removeAll()
        settledInteractionOrder.removeAll()
    }

    private func resolvePendingInteractions(
        in lane: OpenAICompatibleTaskLane,
        agentRuntimeID retiredAgentRuntimeID: UUID? = nil
    ) {
        let matching = pendingInteractions.filter { _, pending in
            guard pending.lane == lane else { return false }
            return retiredAgentRuntimeID == nil
                || pending.agentRuntimeID == retiredAgentRuntimeID
        }
        for (publicID, pending) in matching {
            pendingInteractions[publicID] = nil
            eventContinuation.yield(.userInteractionResolved(publicID))
            removeInteractionResolutionEntry(
                origin: interactionOrigin(for: pending),
                token: pending.token
            )
        }

        interactionResolutionOrder = interactionResolutionOrder.filter { origin, _ in
            guard origin.lane == lane else { return true }
            return retiredAgentRuntimeID != nil
                && origin.agentRuntimeID != retiredAgentRuntimeID
        }
        settledInteractionOrder.removeAll { settled in
            guard settled.origin.lane == lane else { return false }
            return retiredAgentRuntimeID == nil
                || settled.origin.agentRuntimeID == retiredAgentRuntimeID
        }
    }

    private func interactionOrigin(for pending: PendingInteraction) -> InteractionOrigin {
        InteractionOrigin(
            scope: pending.scope,
            agentRuntimeID: pending.agentRuntimeID,
            lane: pending.lane,
            runtimeID: pending.runtimeID
        )
    }

    private func emitInteractionRequested(
        _ interaction: RuntimeUserInteraction,
        lane: OpenAICompatibleTaskLane,
        generation eventGeneration: UInt64,
        agentRuntimeID eventAgentRuntimeID: UUID?
    ) {
        guard let scope = try? currentScope(),
              scope.generation == eventGeneration else { return }
        let origin = InteractionOrigin(
            scope: scope,
            agentRuntimeID: eventAgentRuntimeID,
            lane: lane,
            runtimeID: interaction.id
        )

        // Provider request IDs may be reused after a response. Retire any
        // older visible request while retaining its place in the raw-resolution
        // queue, so a late callback cannot dismiss the replacement request.
        let superseded = pendingInteractions.filter { _, pending in
            interactionOrigin(for: pending) == origin
        }
        for (publicID, pending) in superseded {
            settlePendingInteraction(
                publicID: publicID,
                pending: pending,
                keepResolutionTombstone: true
            )
        }

        let token = UUID()
        let publicID = Self.publicInteractionID(
            interaction.id,
            lane: lane,
            token: token
        )
        let pending = PendingInteraction(
            token: token,
            scope: scope,
            agentRuntimeID: eventAgentRuntimeID,
            lane: lane,
            runtimeID: interaction.id,
            responseAttemptID: nil
        )
        pendingInteractions[publicID] = pending
        interactionResolutionOrder[origin, default: []].append(
            InteractionResolutionEntry(token: token, publicID: publicID)
        )
        eventContinuation.yield(.userInteractionRequested(
            Self.publicInteraction(interaction, publicID: publicID, lane: lane)
        ))
    }

    private func emitInteractionResolved(
        _ runtimeID: RuntimeRequestID,
        lane: OpenAICompatibleTaskLane,
        generation eventGeneration: UInt64,
        agentRuntimeID eventAgentRuntimeID: UUID?
    ) {
        guard let scope = try? currentScope(),
              scope.generation == eventGeneration else { return }
        let origin = InteractionOrigin(
            scope: scope,
            agentRuntimeID: eventAgentRuntimeID,
            lane: lane,
            runtimeID: runtimeID
        )
        guard var entries = interactionResolutionOrder[origin], !entries.isEmpty else { return }
        let resolved = entries.removeFirst()
        interactionResolutionOrder[origin] = entries.isEmpty ? nil : entries
        settledInteractionOrder.removeAll {
            $0.origin == origin && $0.token == resolved.token
        }
        guard let pending = pendingInteractions[resolved.publicID],
              pending.token == resolved.token else { return }
        pendingInteractions[resolved.publicID] = nil
        eventContinuation.yield(.userInteractionResolved(resolved.publicID))
    }

    private func settlePendingInteraction(
        publicID: RuntimeRequestID,
        pending: PendingInteraction,
        keepResolutionTombstone: Bool
    ) {
        guard pendingInteractions[publicID]?.token == pending.token else { return }
        pendingInteractions[publicID] = nil
        eventContinuation.yield(.userInteractionResolved(publicID))
        let origin = interactionOrigin(for: pending)
        if keepResolutionTombstone {
            settledInteractionOrder.append(SettledInteraction(
                origin: origin,
                token: pending.token
            ))
            trimSettledInteractionTombstones()
        } else {
            removeInteractionResolutionEntry(origin: origin, token: pending.token)
        }
    }

    private func removeInteractionResolutionEntry(
        origin: InteractionOrigin,
        token: UUID
    ) {
        guard var entries = interactionResolutionOrder[origin] else { return }
        entries.removeAll { $0.token == token }
        interactionResolutionOrder[origin] = entries.isEmpty ? nil : entries
        settledInteractionOrder.removeAll { $0.origin == origin && $0.token == token }
    }

    private func trimSettledInteractionTombstones() {
        while settledInteractionOrder.count > Self.maximumSettledInteractionTombstones {
            let oldest = settledInteractionOrder.removeFirst()
            guard var entries = interactionResolutionOrder[oldest.origin] else { continue }
            entries.removeAll { $0.token == oldest.token }
            interactionResolutionOrder[oldest.origin] = entries.isEmpty ? nil : entries
        }
    }

    private func beginPendingCreation(
        in lane: OpenAICompatibleTaskLane,
        scope: RuntimeScope
    ) throws -> UUID {
        try validate(scope)
        let token = UUID()
        pendingCreations[token] = PendingCreation(
            token: token,
            scope: scope,
            lane: lane,
            publicThreadID: nil
        )
        return token
    }

    private func associatePendingCreation(_ token: UUID, with publicThreadID: String) {
        guard var creation = pendingCreations[token] else { return }
        creation.publicThreadID = publicThreadID
        pendingCreations[token] = creation
    }

    private func finishPendingCreation(_ token: UUID, discardAssociatedEvents: Bool) {
        guard let creation = pendingCreations.removeValue(forKey: token) else { return }
        if discardAssociatedEvents, let publicThreadID = creation.publicThreadID {
            pendingTaskEvents[publicThreadID] = nil
        }

        let hasAnotherCreation = pendingCreations.values.contains {
            $0.scope == creation.scope && $0.lane == creation.lane
        }
        guard !hasAnotherCreation else { return }

        // No operation in this exact runtime scope can still claim these
        // unowned rows. Drop only this lane's quarantine; another lane or a
        // replacement generation owns an independent buffer lifecycle.
        pendingTaskEvents = pendingTaskEvents.filter { publicThreadID, _ in
            let eventLane: OpenAICompatibleTaskLane = publicThreadID.hasPrefix(
                Self.publicAgentThreadPrefix
            ) ? .agent : .chat
            return eventLane != creation.lane
        }
    }

    private func runtime(for lane: OpenAICompatibleTaskLane) async throws -> any AgentRuntime {
        switch lane {
        case .chat: chatRuntime
        case .agent: try await agent()
        }
    }

    private func agent() async throws -> any AgentRuntime {
        if let pendingAgentShutdown = agentShutdownTask {
            await pendingAgentShutdown.task.value
            if agentShutdownTask?.id == pendingAgentShutdown.id {
                agentShutdownTask = nil
            }
        }
        if let agentRuntime { return agentRuntime.runtime }
        let currentConnection = try currentConnection()
        let currentGeneration = generation
        let preparation: PendingAgentPreparation
        if let existing = agentPreparation {
            preparation = existing
        } else {
            let agentFactory = agentFactory
            let task = Task {
                let prepared = try await agentFactory.prepare(connection: currentConnection)
                do {
                    _ = try await prepared.runtime.connect()
                    return prepared
                } catch {
                    await prepared.shutdown()
                    throw error
                }
            }
            preparation = PendingAgentPreparation(
                id: UUID(),
                scope: RuntimeScope(
                    generation: currentGeneration,
                    connectionID: currentConnection.id,
                    conversationScopeID: currentConnection.conversationScopeID
                ),
                task: task
            )
            agentPreparation = preparation
        }
        let prepared: OpenAICompatiblePreparedAgentRuntime
        do {
            prepared = try await preparation.task.value
        } catch {
            if agentPreparation?.id == preparation.id { agentPreparation = nil }
            throw error
        }
        if agentPreparation?.id == preparation.id { agentPreparation = nil }
        guard connected, generation == currentGeneration,
              connection?.id == currentConnection.id,
              connection?.conversationScopeID == currentConnection.conversationScopeID else {
            await prepared.shutdown()
            throw CancellationError()
        }
        if let agentRuntime {
            // Another waiter installed the shared runtime while this actor was
            // suspended. The completed preparation is redundant.
            if agentRuntime.identity != prepared.identity { await prepared.shutdown() }
            return agentRuntime.runtime
        }
        agentRuntime = prepared
        let runtimeID = UUID()
        agentRuntimeID = runtimeID
        agentEventTask?.cancel()
        agentEventTask = startEventPump(
            from: prepared.runtime,
            lane: .agent,
            generation: currentGeneration,
            agentRuntimeID: runtimeID
        )
        return prepared.runtime
    }

    private func currentConnection() throws -> ProviderConnectionRecord {
        guard connected, let connection else { throw OpenAICompatibleRuntimeError.notConnected }
        return connection
    }

    private func currentScope() throws -> RuntimeScope {
        let connection = try currentConnection()
        return RuntimeScope(
            generation: generation,
            connectionID: connection.id,
            conversationScopeID: connection.conversationScopeID
        )
    }

    private func isCurrent(_ scope: RuntimeScope) -> Bool {
        connected
            && generation == scope.generation
            && connection?.id == scope.connectionID
            && connection?.conversationScopeID == scope.conversationScopeID
    }

    private func validate(_ scope: RuntimeScope) throws {
        guard isCurrent(scope) else { throw CancellationError() }
    }

    private func selectedModelID(_ requested: String?) throws -> String {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        if let modelID = connection?.selectedModelID { return modelID }
        if let modelID = session?.availableModels.first(where: \.isDefault)?.id
            ?? session?.availableModels.first?.id {
            return modelID
        }
        throw OpenAICompatibleRuntimeError.noModelsAvailable
    }

    private func models(
        _ baseModels: [RuntimeModel],
        for connection: ProviderConnectionRecord,
        startMissingProbes: Bool
    ) async throws -> [RuntimeModel] {
        var values: [RuntimeModel] = []
        let selectedProbeModelID = startMissingProbes
            ? (connection.selectedModelID
                ?? baseModels.first(where: \.isDefault)?.id
                ?? baseModels.first?.id)
            : nil
        let decisions = try await resolver.resolveNewTasks(
            connection: connection,
            modelIDs: baseModels.map(\.id),
            modelIDToProbe: selectedProbeModelID
        )
        for (model, decision) in zip(baseModels, decisions) {
            let mode: RuntimeModelExecutionMode
            let capabilities: RuntimeCapabilities
            switch decision.basis {
            case .advertisedToolUse, .compatibleProbe:
                mode = .agent
                capabilities = Self.capabilities(for: .agent, model: model)
            case .failedProbe:
                mode = .chat
                capabilities = Self.capabilities(for: .chat, model: model)
            case .unavailableProbe:
                let shouldStartProbe = model.id == selectedProbeModelID
                mode = shouldStartProbe ? .checkingAgent : .chat
                capabilities = Self.capabilities(for: .chat, model: model)
            case .existingTask:
                mode = decision.lane == .agent ? .agent : .chat
                capabilities = Self.capabilities(for: decision.lane, model: model)
            }
            values.append(model.withExecutionMode(mode, taskCapabilities: capabilities))
        }
        return values
    }

    private func sessionSnapshot(base: RuntimeSession, models: [RuntimeModel]) -> RuntimeSession {
        RuntimeSession(
            runtime: base.runtime,
            displayName: base.displayName,
            accountLabel: base.accountLabel,
            planLabel: base.planLabel,
            auth: base.auth,
            availableLoginMethods: base.availableLoginMethods,
            availableModels: models,
            capabilities: base.capabilities
        )
    }

    private func startChatEventPump(generation: UInt64) {
        guard chatEventTask == nil else { return }
        chatEventTask = startEventPump(
            from: chatRuntime,
            lane: .chat,
            generation: generation,
            agentRuntimeID: nil
        )
    }

    private func startEventPumps(
        generation: UInt64,
        probeUpdates: OpenAICompatibleAdaptiveRuntimeResolver.ProbeUpdateSubscription
    ) {
        startChatEventPump(generation: generation)
        probeUpdateSubscriptionID = probeUpdates.id
        let updateTask = Task { [weak self] in
            for await _ in probeUpdates.stream {
                guard let self else { return }
                await self.publishModelsAfterProbe(generation: generation)
            }
        }
        probeUpdateTask = updateTask
    }

    private func startEventPump(
        from runtime: any AgentRuntime,
        lane: OpenAICompatibleTaskLane,
        generation: UInt64,
        agentRuntimeID: UUID?
    ) -> Task<Void, Never> {
#if DEBUG
        if lane == .chat { chatEventPumpStartCount += 1 }
#endif
        return Task { [weak self] in
            for await event in runtime.events {
                guard let self else { return }
                await self.forward(
                    event,
                    from: lane,
                    generation: generation,
                    agentRuntimeID: agentRuntimeID
                )
            }
        }
    }

#if DEBUG
    func chatEventPumpStartsForTesting() -> Int {
        chatEventPumpStartCount
    }
#endif

    private func forward(
        _ event: AgentRuntimeEvent,
        from lane: OpenAICompatibleTaskLane,
        generation eventGeneration: UInt64,
        agentRuntimeID eventAgentRuntimeID: UUID?
    ) async {
        guard connected, generation == eventGeneration else { return }
        if lane == .agent {
            guard let eventAgentRuntimeID,
                  agentRuntimeID == eventAgentRuntimeID else { return }
        }
        if let rawThreadID = Self.threadID(from: event) {
            let publicThreadID = lane == .agent
                ? Self.publicAgentThreadID(rawThreadID)
                : Self.publicChatThreadID(rawThreadID)
            let isOwned = lane == .agent
                ? agentOwnedThreadIDs.contains(publicThreadID)
                : chatOwnedThreadIDs.contains(publicThreadID)
            if !isOwned {
                if unownedEventThreadIDs.contains(publicThreadID) {
                    bufferPendingEvent(
                        event,
                        threadID: publicThreadID,
                        generation: eventGeneration,
                        agentRuntimeID: eventAgentRuntimeID
                    )
                    return
                }
                guard let connection else { return }
                let owner: OpenAICompatibleTaskLaneOwnership?
                do {
                    owner = try await stateStore.taskOwnership(
                        connectionID: connection.id,
                        conversationScopeID: connection.conversationScopeID,
                        threadID: publicThreadID
                    )
                } catch {
                    return
                }
                guard connected, generation == eventGeneration else { return }
                // The ownership write can commit while the lookup above is
                // suspended. In-memory ownership is authoritative for this
                // generation once that transaction completes.
                let becameOwned = lane == .agent
                    ? agentOwnedThreadIDs.contains(publicThreadID)
                    : chatOwnedThreadIDs.contains(publicThreadID)
                if becameOwned {
                    await emit(
                        event,
                        lane: lane,
                        generation: eventGeneration,
                        agentRuntimeID: eventAgentRuntimeID
                    )
                    return
                }
                guard owner?.lane == lane,
                      connected else {
                    if unownedEventThreadIDs.count < Self.maximumUnownedEventThreadIDs {
                        unownedEventThreadIDs.insert(publicThreadID)
                    }
                    bufferPendingEvent(
                        event,
                        threadID: publicThreadID,
                        generation: eventGeneration,
                        agentRuntimeID: eventAgentRuntimeID
                    )
                    return
                }
                rememberOwnedThread(publicThreadID, lane: lane)
            }
        }
        await emit(
            event,
            lane: lane,
            generation: eventGeneration,
            agentRuntimeID: eventAgentRuntimeID
        )
        if lane == .agent,
           let eventAgentRuntimeID,
           Self.isTerminalConnectionEvent(event) {
            await retireDeadAgentRuntime(id: eventAgentRuntimeID)
        }
    }

    private func retireDeadAgentRuntime(id: UUID) async {
        guard agentRuntimeID == id else { return }
        let retired = agentRuntime
        agentRuntime = nil
        agentRuntimeID = nil
        agentEventTask?.cancel()
        agentEventTask = nil
        guard let retired else { return }
        let shutdown = PendingAgentShutdown(
            id: UUID(),
            task: Task { await retired.shutdown() }
        )
        agentShutdownTask = shutdown
        await shutdown.task.value
        if agentShutdownTask?.id == shutdown.id { agentShutdownTask = nil }
    }

    private func bufferPendingEvent(
        _ event: AgentRuntimeEvent,
        threadID: String,
        generation eventGeneration: UInt64,
        agentRuntimeID eventAgentRuntimeID: UUID?
    ) {
        let lane: OpenAICompatibleTaskLane = threadID.hasPrefix(Self.publicAgentThreadPrefix)
            ? .agent
            : .chat
        guard let scope = try? currentScope(),
              scope.generation == eventGeneration,
              pendingCreations.values.contains(where: {
                  $0.lane == lane && $0.scope == scope
              }) else { return }
        if pendingTaskEvents[threadID] == nil,
           pendingTaskEvents.count >= Self.maximumPendingEventThreads {
            return
        }
        var pending = pendingTaskEvents[threadID, default: []]
        guard pending.count < Self.maximumPendingTaskEventsPerThread else { return }
        pending.append(PendingTaskEvent(
            event: event,
            scope: scope,
            agentRuntimeID: eventAgentRuntimeID
        ))
        pendingTaskEvents[threadID] = pending
    }

    /// Deliver an event after it has crossed the lane ownership boundary.
    /// This is also used to replay events quarantined while a new task's
    /// ownership record was being persisted.
    private func emit(
        _ event: AgentRuntimeEvent,
        lane: OpenAICompatibleTaskLane,
        generation eventGeneration: UInt64,
        agentRuntimeID eventAgentRuntimeID: UUID?
    ) async {
        guard connected, generation == eventGeneration else { return }
        if lane == .agent {
            guard let eventAgentRuntimeID,
                  agentRuntimeID == eventAgentRuntimeID else { return }
        }
        switch event {
        case let .userInteractionRequested(interaction):
            emitInteractionRequested(
                interaction,
                lane: lane,
                generation: eventGeneration,
                agentRuntimeID: eventAgentRuntimeID
            )
            return
        case let .userInteractionResolved(runtimeID):
            emitInteractionResolved(
                runtimeID,
                lane: lane,
                generation: eventGeneration,
                agentRuntimeID: eventAgentRuntimeID
            )
            return
        default:
            break
        }
        let projected = await publicEvent(event, lane: lane)
        if lane == .agent {
            switch projected {
            case let .turnStarted(threadID, _):
                activeAgentThreadIDs.insert(threadID)
            case let .threadStatusChanged(threadID, status):
                if status.isBusy {
                    activeAgentThreadIDs.insert(threadID)
                } else {
                    activeAgentThreadIDs.remove(threadID)
                }
            case let .turnCompleted(threadID, _):
                activeAgentThreadIDs.remove(threadID)
            case .connectionChanged(.failed), .connectionChanged(.disconnected):
                for threadID in activeAgentThreadIDs {
                    eventContinuation.yield(
                        .threadStatusChanged(threadID: threadID, status: .failed)
                    )
                    eventContinuation.yield(.turnCompleted(threadID: threadID, status: .failed))
                }
                activeAgentThreadIDs.removeAll()
                resolvePendingInteractions(
                    in: .agent,
                    agentRuntimeID: eventAgentRuntimeID
                )
            default:
                break
            }
            switch projected {
            case .connectionChanged, .accountUpdated, .loginCompleted,
                 .runtimeCapabilitiesDowngraded, .runtimeModelsUpdated,
                 .runtimeNotice:
                // Provider-wide state belongs to the chat facade. The private
                // app-server lane contributes only task-scoped events.
                return
            default:
                break
            }
        }
        eventContinuation.yield(projected)
    }

    private func flushPendingTaskEvents(
        for publicThreadID: String,
        lane: OpenAICompatibleTaskLane,
        scope: RuntimeScope
    ) async {
        guard isCurrent(scope) else { return }
        guard let events = pendingTaskEvents.removeValue(forKey: publicThreadID) else {
            return
        }
        for buffered in events {
            guard isCurrent(scope) else { return }
            guard buffered.scope == scope else { continue }
            await emit(
                buffered.event,
                lane: lane,
                generation: buffered.scope.generation,
                agentRuntimeID: buffered.agentRuntimeID
            )
        }
    }

    private func publicEvent(
        _ event: AgentRuntimeEvent,
        lane: OpenAICompatibleTaskLane
    ) async -> AgentRuntimeEvent {
        guard lane == .agent else { return publicChatEvent(event) }
        let publicID: (String) -> String = Self.publicAgentThreadID
        return switch event {
        case let .threadUpdated(thread):
            .threadUpdated(publicThread(thread, lane: .agent))
        case let .threadNameChanged(threadID, name):
            .threadNameChanged(threadID: publicID(threadID), name: name)
        case let .threadStatusChanged(threadID, status):
            .threadStatusChanged(threadID: publicID(threadID), status: status)
        case let .threadArchived(threadID):
            .threadArchived(threadID: publicID(threadID))
        case let .threadUnarchived(threadID):
            .threadUnarchived(threadID: publicID(threadID))
        case let .threadDeleted(threadID):
            .threadDeleted(threadID: publicID(threadID))
        case let .threadRefreshRequested(threadID):
            .threadRefreshRequested(threadID: publicID(threadID))
        case let .itemStarted(threadID, item):
            .itemStarted(
                threadID: publicID(threadID),
                item: await publicItem(item, lane: .agent)
            )
        case let .itemDelta(threadID, itemID, delta):
            .itemDelta(threadID: publicID(threadID), itemID: itemID, delta: delta)
        case let .itemCompleted(threadID, item):
            .itemCompleted(
                threadID: publicID(threadID),
                item: await publicItem(item, lane: .agent)
            )
        case let .turnStarted(threadID, turnID):
            .turnStarted(threadID: publicID(threadID), turnID: turnID)
        case let .planUpdated(threadID, plan):
            .planUpdated(threadID: publicID(threadID), plan: plan)
        case let .turnCompleted(threadID, status):
            .turnCompleted(threadID: publicID(threadID), status: status)
        case let .userInteractionRequested(interaction):
            .userInteractionRequested(Self.publicInteraction(interaction, lane: .agent))
        case let .userInteractionResolved(id):
            .userInteractionResolved(Self.publicInteractionID(id, lane: .agent))
        default:
            event
        }
    }

    /// Chat IDs stay stable unless they occupy an adaptive reserved namespace.
    /// Escaping that rare case keeps raw app-owned IDs from colliding with an
    /// app-server task or with another already-escaped chat task.
    private func publicChatEvent(_ event: AgentRuntimeEvent) -> AgentRuntimeEvent {
        let publicID: (String) -> String = Self.publicChatThreadID
        return switch event {
        case let .threadUpdated(thread):
            .threadUpdated(publicThread(thread, lane: .chat))
        case let .threadNameChanged(threadID, name):
            .threadNameChanged(threadID: publicID(threadID), name: name)
        case let .threadStatusChanged(threadID, status):
            .threadStatusChanged(threadID: publicID(threadID), status: status)
        case let .threadArchived(threadID):
            .threadArchived(threadID: publicID(threadID))
        case let .threadUnarchived(threadID):
            .threadUnarchived(threadID: publicID(threadID))
        case let .threadDeleted(threadID):
            .threadDeleted(threadID: publicID(threadID))
        case let .threadRefreshRequested(threadID):
            .threadRefreshRequested(threadID: publicID(threadID))
        case let .itemStarted(threadID, item):
            .itemStarted(threadID: publicID(threadID), item: item)
        case let .itemDelta(threadID, itemID, delta):
            .itemDelta(threadID: publicID(threadID), itemID: itemID, delta: delta)
        case let .itemCompleted(threadID, item):
            .itemCompleted(threadID: publicID(threadID), item: item)
        case let .turnStarted(threadID, turnID):
            .turnStarted(threadID: publicID(threadID), turnID: turnID)
        case let .planUpdated(threadID, plan):
            .planUpdated(threadID: publicID(threadID), plan: plan)
        case let .turnCompleted(threadID, status):
            .turnCompleted(threadID: publicID(threadID), status: status)
        case let .userInteractionRequested(interaction):
            .userInteractionRequested(Self.publicInteraction(interaction, lane: .chat))
        case let .userInteractionResolved(id):
            .userInteractionResolved(Self.publicInteractionID(id, lane: .chat))
        default:
            event
        }
    }

    private func publishModelsAfterProbe(generation updateGeneration: UInt64) async {
        guard connected,
              generation == updateGeneration,
              let connection,
              let session else { return }
        let updateRevision = sessionRevision
        let baseModels = session.availableModels.map { model in
            model.withExecutionMode(
                .chat,
                taskCapabilities: Self.capabilities(for: .chat, model: model)
            )
        }
        guard let projected = try? await models(
            baseModels,
            for: connection,
            startMissingProbes: false
        ), generation == updateGeneration,
              sessionRevision == updateRevision,
              self.connection?.id == connection.id,
              self.connection?.conversationScopeID == connection.conversationScopeID else { return }
        self.session = sessionSnapshot(base: session, models: projected)
        sessionRevision &+= 1
        eventContinuation.yield(.runtimeModelsUpdated(projected))
    }

    private func publicConversation(
        _ conversation: RuntimeConversation,
        lane: OpenAICompatibleTaskLane,
        modelID: String? = nil
    ) async throws -> RuntimeConversation {
        let effectiveModelID = modelID ?? conversation.thread.model
        var value = conversation.withTaskCapabilities(
            taskCapabilities(for: lane, modelID: effectiveModelID)
        )
        value.thread = publicThread(value.thread, lane: lane, modelID: effectiveModelID)
        value.items = await publicItems(value.items, lane: lane)
        value.turns = try await publicTurns(value.turns, lane: lane)
        return value
    }

    private func publicTurns(
        _ turns: [RuntimeConversationTurn],
        lane: OpenAICompatibleTaskLane
    ) async throws -> [RuntimeConversationTurn] {
        var projected: [RuntimeConversationTurn] = []
        projected.reserveCapacity(turns.count)
        for turn in turns {
            var value = turn
            value.items = await publicItems(value.items, lane: lane)
            projected.append(value)
        }
        return projected
    }

    private func publicItems(
        _ items: [TimelineItem],
        lane: OpenAICompatibleTaskLane
    ) async -> [TimelineItem] {
        var projected: [TimelineItem] = []
        projected.reserveCapacity(items.count)
        for item in items {
            projected.append(await publicItem(item, lane: lane))
        }
        return projected
    }

    private func publicItem(
        _ item: TimelineItem,
        lane: OpenAICompatibleTaskLane
    ) async -> TimelineItem {
        guard lane == .agent, let collaboration = item.collaboration else { return item }
        let projectionScope = try? currentScope()
        var value = item
        var agents: [RuntimeCollaborationAgent] = []
        agents.reserveCapacity(collaboration.agents.count)
        for agent in collaboration.agents {
            guard let destination = agent.destination else {
                agents.append(agent)
                continue
            }
            var projectedAgent = agent
            if destination.inheritsParentConnection,
               destination.connectionID == .codexDefault {
                // Native app-server subagents inherit the adaptive provider.
                // Record them before exposing a clickable destination so a
                // subsequent read or restart always reaches the same lane.
                let publicThreadID = Self.publicAgentThreadID(destination.threadID)
                if let projectionScope,
                   let connection,
                   connection.id == projectionScope.connectionID,
                   connection.conversationScopeID == projectionScope.conversationScopeID,
                   let modelID = try? selectedModelID(nil),
                   (try? await stateStore.ensureTaskOwnership(
                        connectionID: projectionScope.connectionID,
                        conversationScopeID: projectionScope.conversationScopeID,
                        threadID: publicThreadID,
                        lane: .agent,
                        modelID: modelID
                   )) != nil {
                    // The durable adoption is safe to complete against the
                    // captured scope, but a reconnect must not mutate the new
                    // generation's in-memory routing or expose a stale link.
                    if isCurrent(projectionScope) {
                        rememberOwnedThread(publicThreadID, lane: .agent)
                        projectedAgent.destination = RuntimeCollaborationAgentDestination(
                            connectionID: connectionID,
                            threadID: publicThreadID,
                            lane: .agent,
                            inheritsParentConnection: false
                        )
                    } else {
                        projectedAgent.destination = nil
                    }
                } else {
                    // Keep the activity visible, but do not expose a link that
                    // cannot be routed durably and safely.
                    projectedAgent.destination = nil
                }
            }
            // Every absolute Onyx-owned delegation destination already carries
            // its complete public identity. Preserve it verbatim, including a
            // generic-provider delegation whose actual target is Codex.
            agents.append(projectedAgent)
        }
        value.collaboration = RuntimeCollaborationActivity(
            action: collaboration.action,
            agents: agents
        )
        return value
    }

    private func publicThread(
        _ thread: RuntimeThread,
        lane: OpenAICompatibleTaskLane,
        modelID: String? = nil
    ) -> RuntimeThread {
        let effectiveModelID = modelID ?? thread.model
        var value = thread
        if lane == .agent { value = RuntimeThread(
            id: Self.publicAgentThreadID(thread.id),
            title: thread.title,
            preview: thread.preview,
            cwd: thread.cwd,
            updatedAt: thread.updatedAt,
            status: thread.status,
            isPinned: thread.isPinned,
            runtime: thread.runtime,
            model: thread.model,
            branch: thread.branch,
            taskCapabilities: taskCapabilities(for: lane, modelID: effectiveModelID)
        ) } else {
            value = RuntimeThread(
                id: Self.publicChatThreadID(thread.id),
                title: thread.title,
                preview: thread.preview,
                cwd: thread.cwd,
                updatedAt: thread.updatedAt,
                status: thread.status,
                isPinned: thread.isPinned,
                runtime: thread.runtime,
                model: thread.model,
                branch: thread.branch,
            taskCapabilities: taskCapabilities(for: lane, modelID: effectiveModelID)
            )
        }
        return value
    }

    private static func publicInteraction(
        _ interaction: RuntimeUserInteraction,
        lane: OpenAICompatibleTaskLane
    ) -> RuntimeUserInteraction {
        publicInteraction(
            interaction,
            publicID: publicInteractionID(interaction.id, lane: lane),
            lane: lane
        )
    }

    private static func publicInteraction(
        _ interaction: RuntimeUserInteraction,
        publicID: RuntimeRequestID,
        lane: OpenAICompatibleTaskLane
    ) -> RuntimeUserInteraction {
        return RuntimeUserInteraction(
            id: publicID,
            threadID: interaction.threadID.map { threadID in
                lane == .agent
                    ? publicAgentThreadID(threadID)
                    : publicChatThreadID(threadID)
            },
            providerMethod: interaction.providerMethod,
            title: interaction.title,
            detail: interaction.detail,
            kind: interaction.kind
        )
    }

    /// Extracts the provider-owned task identity for events that can mutate a
    /// transcript or task row. Account/model notices and interaction-resolved
    /// events have no task identity at this boundary.
    private static func threadID(from event: AgentRuntimeEvent) -> String? {
        switch event {
        case let .threadUpdated(thread): thread.id
        case let .threadNameChanged(threadID, _),
             let .threadStatusChanged(threadID, _),
             let .threadArchived(threadID),
             let .threadUnarchived(threadID),
             let .threadDeleted(threadID),
             let .threadRefreshRequested(threadID),
             let .itemStarted(threadID, _),
             let .itemDelta(threadID, _, _),
             let .itemCompleted(threadID, _),
             let .turnStarted(threadID, _),
             let .planUpdated(threadID, _),
             let .turnCompleted(threadID, _):
            threadID
        case let .userInteractionRequested(interaction): interaction.threadID
        case .connectionChanged, .runtimeCapabilitiesDowngraded,
             .runtimeModelsUpdated, .accountUpdated, .loginCompleted,
             .userInteractionResolved, .runtimeNotice:
            nil
        }
    }

    private static func isTerminalConnectionEvent(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case .connectionChanged(.failed), .connectionChanged(.disconnected): true
        default: false
        }
    }

    private static let publicInteractionPrefix = "onyx.interaction."

    private static func publicInteractionID(
        _ runtimeID: RuntimeRequestID,
        lane: OpenAICompatibleTaskLane,
        token: UUID? = nil
    ) -> RuntimeRequestID {
        let typeTag: String
        let value: String
        switch runtimeID {
        case let .integer(id):
            typeTag = "i"
            value = String(id)
        case let .string(id):
            typeTag = "s"
            value = id
        }
        var encoded = publicInteractionPrefix
            + lane.rawValue + "." + typeTag + "." + encodeOpaqueID(value)
        if let token { encoded += "." + token.uuidString.lowercased() }
        return .string(encoded)
    }

    private static func publicInteractionID(
        _ runtimeID: RuntimeRequestID,
        lane: OpenAICompatibleTaskLane,
        token: UUID
    ) -> RuntimeRequestID {
        guard case let .string(base) = publicInteractionID(runtimeID, lane: lane) else {
            preconditionFailure("Adaptive interaction IDs are always strings")
        }
        return .string(base + "." + token.uuidString.lowercased())
    }

    private static let publicAgentThreadPrefix = "onyx.agent."
    private static let publicChatThreadPrefix = "onyx.chat."

    private static func publicChatThreadID(_ rawID: String) -> String {
        guard rawID.hasPrefix(publicAgentThreadPrefix)
                || rawID.hasPrefix(publicChatThreadPrefix) else { return rawID }
        return publicChatThreadPrefix + encodeOpaqueID(rawID)
    }

    private static func rawChatThreadID(_ publicID: String) throws -> String {
        guard publicID.hasPrefix(publicChatThreadPrefix) else { return publicID }
        let rawID = try decodeOpaqueID(
            String(publicID.dropFirst(publicChatThreadPrefix.count))
        )
        guard publicChatThreadID(rawID) == publicID else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return rawID
    }

    private static func encodeOpaqueID(_ rawID: String) -> String {
        Data(rawID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeOpaqueID(_ encodedValue: String) throws -> String {
        var encoded = encodedValue
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        let remainder = encoded.count % 4
        if remainder != 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: encoded),
              let rawID = String(data: data, encoding: .utf8),
              !rawID.isEmpty else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return rawID
    }

    private static func publicAgentThreadID(_ rawID: String) -> String {
        publicAgentThreadPrefix + encodeOpaqueID(rawID)
    }

    private static func rawAgentThreadID(_ publicID: String) throws -> String {
        guard publicID.hasPrefix(publicAgentThreadPrefix) else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        let rawID = try decodeOpaqueID(
            String(publicID.dropFirst(publicAgentThreadPrefix.count))
        )
        guard publicAgentThreadID(rawID) == publicID else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return rawID
    }

    private static func runtimeThreadID(
        _ publicID: String,
        for lane: OpenAICompatibleTaskLane
    ) throws -> String {
        lane == .agent ? try rawAgentThreadID(publicID) : try rawChatThreadID(publicID)
    }

    /// Projects the lane's execution semantics onto the selected model's
    /// actual input/reasoning metadata.  Agent probing proves that the
    /// Responses lane can run; it does not make every model in that lane
    /// multimodal or reasoning-capable.
    private static func capabilities(
        for lane: OpenAICompatibleTaskLane,
        model: RuntimeModel?
    ) -> RuntimeCapabilities {
        var projected = lane == .agent ? agentTaskCapabilities : chatTaskCapabilities
        guard let model else {
            // This facade serves a generic provider, so a missing catalog row
            // is not permission to inherit native Codex's richer controls.
            // Text remains usable; image/reasoning requests must be rejected
            // until the provider supplies model evidence.
            projected.remove(.images)
            projected.remove(.reasoning)
            return projected
        }

        // Unknown model metadata is intentionally conservative.  A generic
        // provider row with no modality evidence must not grow an image
        // control merely because the lane supports images for another model.
        let supportsImages = !model.capabilityMetadataIsUnknown
            && model.inputModalities.contains(.image)
        if !supportsImages { projected.remove(.images) }
        if model.reasoningEfforts.isEmpty { projected.remove(.reasoning) }
        return projected
    }

    private func taskCapabilities(
        for lane: OpenAICompatibleTaskLane,
        modelID: String?
    ) -> RuntimeCapabilities {
        let normalizedID = modelID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let model = normalizedID.flatMap { id in
            session?.availableModels.first { $0.id == id }
        }
        return Self.capabilities(for: lane, model: model)
    }

    private func modelMetadata(for modelID: String?) -> RuntimeModel? {
        let normalizedID = modelID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let normalizedID, !normalizedID.isEmpty else { return nil }
        return session?.availableModels.first { $0.id == normalizedID }
    }

    private func validateModelInputs(
        _ inputs: [RuntimeTurnInput],
        reasoningEffort: String?,
        modelID: String?
    ) throws {
        let hasText = inputs.contains { input in
            if case .text = input { return true }
            return false
        }
        let hasImage = inputs.contains { input in
            switch input {
            case .localImagePath, .imageURL: true
            case .text: false
            }
        }
        let model = modelMetadata(for: modelID)
        if hasText {
            // Text is the conservative baseline for an OpenAI-compatible
            // model.  A missing/unknown catalog row must remain usable for
            // ordinary chat; only explicit, trusted modality metadata that
            // omits text can reject the request.
            if let model,
               !model.capabilityMetadataIsUnknown,
               !model.inputModalities.contains(.text) {
                throw AgentRuntimeError.unsupported(
                    "text input for model \(modelID ?? "the selected model")"
                )
            }
        }
        if hasImage {
            guard let model,
                  !model.capabilityMetadataIsUnknown,
                  model.inputModalities.contains(.image) else {
                throw AgentRuntimeError.unsupported(
                    "image input for model \(modelID ?? "the selected model")"
                )
            }
        }
        guard let reasoningEffort else { return }
        guard let model,
              model.reasoningEfforts.contains(reasoningEffort) else {
            throw AgentRuntimeError.unsupported(
                "reasoning effort \(reasoningEffort) for model \(modelID ?? "the selected model")"
            )
        }
    }
}

private extension RuntimeModel {
    func withExecutionMode(
        _ mode: RuntimeModelExecutionMode,
        taskCapabilities: RuntimeCapabilities
    ) -> RuntimeModel {
        RuntimeModel(
            id: id,
            displayName: displayName,
            description: description,
            isDefault: isDefault,
            defaultReasoningEffort: defaultReasoningEffort,
            reasoningEfforts: reasoningEfforts,
            inputModalities: inputModalities,
            serverAdvertisedRequestParameters: serverAdvertisedRequestParameters,
            supportedRequestParameters: supportedRequestParameters,
            serverAdvertisedCapabilities: serverAdvertisedCapabilities,
            capabilityEvidence: capabilityEvidence,
            executionMode: mode,
            taskCapabilities: taskCapabilities
        )
    }
}

private extension RuntimeConversation {
    func withTaskCapabilities(_ capabilities: RuntimeCapabilities) -> RuntimeConversation {
        var value = self
        value.thread.taskCapabilities = capabilities
        return value
    }
}
