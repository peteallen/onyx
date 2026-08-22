import Foundation

/// Errors owned by the chat-style adapter. The adapter deliberately reports
/// provider capabilities that it actually implements; it never presents a
/// remote chat endpoint as if it had Codex's local tools, approvals, or
/// sandbox.
enum OpenAICompatibleRuntimeError: LocalizedError, Equatable, Sendable {
    case connectionNotFound(ProviderConnectionID)
    case notConnected
    case discoveryFailed(String)
    case modelNotFound(String)
    case noModelsAvailable
    case authenticationRequired
    case emptyTurnInput
    case emptyConversationName
    case conversationNotFound(String)
    case activeTurn(String)

    var errorDescription: String? {
        switch self {
        case let .connectionNotFound(id):
            "No OpenAI-compatible connection is configured for \(id)."
        case .notConnected:
            "The OpenAI-compatible provider is not connected."
        case let .discoveryFailed(detail):
            "The provider model catalog could not be loaded: \(detail)"
        case let .modelNotFound(model):
            "The selected provider model is unavailable: \(model)"
        case .noModelsAvailable:
            "The provider did not advertise any models. Select a model in provider settings."
        case .authenticationRequired:
            "Provider authentication is required before starting a conversation."
        case .emptyTurnInput:
            "A provider turn must contain text or an image."
        case .emptyConversationName:
            "A provider conversation name cannot be empty."
        case let .conversationNotFound(id):
            "The provider conversation could not be found: \(id)"
        case let .activeTurn(id):
            "Conversation \(id) already has a response in progress."
        }
    }
}

/// App-owned runtime for OpenAI-compatible `/models` and `/chat/completions`
/// endpoints. Unlike CodexRuntime, this actor does not claim remote tools,
/// approvals, sandboxing, fork, compact, review, or active-turn steering.
actor OpenAICompatibleRuntime: AgentRuntime {
    /// `.local` keeps the existing provider-neutral enum source-compatible;
    /// the session's display name remains the configured connection name.
    nonisolated let kind: AgentRuntimeKind = .local
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    let connectionID: ProviderConnectionID

    private let connectionStore: ProviderConnectionStore
    private let credentialStore: any CredentialStore
    private let conversationStore: OpenAICompatibleConversationStore
    private let session: URLSession
    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let beforeDisconnectedTurnCleanup: (@Sendable () async -> Void)?

    private var connection: ProviderConnectionRecord?
    private var transport: OpenAICompatibleChatTransport?
    private var bearerToken: String?
    private var discoveredModels: [ProviderModelDescriptor] = []
    private var connected = false
    private var connectionGeneration: UInt64 = 0
    private var connectionAttempt: ConnectionAttempt?
    private var activeTurns: [String: ActiveTurn] = [:]
    private var startingTurns: Set<String> = []
    private var interruptedThreads: Set<String> = []

    private struct ActiveTurn: Sendable {
        let turnID: String
        let assistantMessageID: String
        let conversationScopeID: String
        let generation: UInt64
        var task: Task<Void, Never>?
    }

    private struct ConnectionAttempt: Sendable {
        let generation: UInt64
        let task: Task<RuntimeSession, any Error>
    }

    /// A model catalog is valid only for the endpoint/auth/transport scope
    /// that produced it. Settings can change while `/models` is in flight, so
    /// this value lets the runtime detect that race before committing either a
    /// stale catalog or a transport built from different settings.
    private struct ModelDiscoveryScope: Equatable, Sendable {
        let baseURL: URL
        let authMode: ProviderConnectionAuthMode
        let transportSecurity: ProviderConnectionTransportSecurity
        let credential: String?

        init(_ record: ProviderConnectionRecord, credential: String?) {
            baseURL = record.baseURL
            authMode = record.authMode
            transportSecurity = record.transportSecurity
            self.credential = credential
        }

        func contains(
            _ record: ProviderConnectionRecord,
            credential: String?
        ) -> Bool {
            baseURL == record.baseURL
                && authMode == record.authMode
                && transportSecurity == record.transportSecurity
                && self.credential == credential
        }
    }

    private struct ResolvedProviderConfiguration: Sendable {
        let record: ProviderConnectionRecord
        let credential: String?
        let models: [ProviderModelDescriptor]
        let transport: OpenAICompatibleChatTransport
        let cachedDiscoveryNotice: String?
    }

    init(
        connectionID: ProviderConnectionID,
        connectionStore: ProviderConnectionStore = ProviderConnectionStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        conversationStore: OpenAICompatibleConversationStore = OpenAICompatibleConversationStore(),
        session: URLSession? = nil,
        beforeDisconnectedTurnCleanup: (@Sendable () async -> Void)? = nil
    ) {
        self.connectionID = connectionID
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.conversationStore = conversationStore
        self.session = session ?? Self.makeDefaultSession()
        self.beforeDisconnectedTurnCleanup = beforeDisconnectedTurnCleanup
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        connectionAttempt?.task.cancel()
        for active in activeTurns.values { active.task?.cancel() }
        eventContinuation.finish()
    }

    func connect() async throws -> RuntimeSession {
        if connected { return sessionSnapshot() }
        if let connectionAttempt { return try await connectionAttempt.task.value }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        eventContinuation.yield(.connectionChanged(.connecting))
        let attempt = Task { [weak self] () throws -> RuntimeSession in
            guard let self else { throw OpenAICompatibleRuntimeError.notConnected }
            return try await self.establishConnection(generation: generation)
        }
        connectionAttempt = ConnectionAttempt(generation: generation, task: attempt)
        do {
            return try await attempt.value
        } catch {
            if connectionAttempt?.generation == generation { connectionAttempt = nil }
            throw error
        }
    }

    private func establishConnection(generation: UInt64) async throws -> RuntimeSession {
        do {
            guard let configured = try await connectionStore.connection(id: connectionID) else {
                throw OpenAICompatibleRuntimeError.connectionNotFound(connectionID)
            }
            let resolved = try await resolveProviderConfiguration(
                startingFrom: configured,
                generation: generation
            )
            // Upgrade transcripts written before scope isolation before any
            // recovery or list operation. Once assigned, these records stay
            // with this endpoint and are excluded automatically if settings
            // later rotate the scope.
            _ = try? await conversationStore.migrateLegacyConversations(
                connectionID: connectionID,
                to: resolved.record.conversationScopeID
            )
            _ = try? await conversationStore.recoverInterruptedTurns(
                connectionID: connectionID,
                scopeID: resolved.record.conversationScopeID
            )
            // Recovery is an actor hop and may include disk I/O. A disconnect
            // that wins while it is in flight must remain the final visible
            // state; the stale attempt cannot publish a connected event.
            guard connectionGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            discoveredModels = resolved.models
            connection = resolved.record
            bearerToken = resolved.credential
            transport = resolved.transport
            connected = true
            let snapshot = sessionSnapshot()
            if connectionAttempt?.generation == generation { connectionAttempt = nil }
            if let cachedDiscoveryNotice = resolved.cachedDiscoveryNotice {
                eventContinuation.yield(
                    .runtimeNotice(
                        title: "Using cached provider models",
                        detail: cachedDiscoveryNotice
                    )
                )
            }
            eventContinuation.yield(.accountUpdated(snapshot.auth))
            eventContinuation.yield(.connectionChanged(.connected(resolved.record.displayName)))
            return snapshot
        } catch {
            guard connectionGeneration == generation else { throw error }
            connected = false
            transport = nil
            connection = nil
            bearerToken = nil
            if connectionAttempt?.generation == generation { connectionAttempt = nil }
            eventContinuation.yield(.connectionChanged(.failed(Self.safeErrorDetail(error))))
            throw error
        }
    }

    func disconnect() async {
        // Invalidate first. Actor reentrancy otherwise lets a start/connect
        // operation commit new state while disconnect waits for a stream task.
        connectionGeneration &+= 1
        let attempt = connectionAttempt?.task
        connectionAttempt?.task.cancel()
        connectionAttempt = nil
        // Keep the durable identifiers until any in-flight store transaction
        // has settled. Clearing the actor reservation first is important for
        // rejecting new work, but a stream can otherwise finish an
        // `updateAssistant` write after the reservation is gone and leave the
        // conversation permanently marked as running.
        let interruptedTurns = activeTurns
        activeTurns.removeAll()
        interruptedThreads.removeAll()
        connected = false
        transport = nil
        connection = nil
        bearerToken = nil
        attempt?.cancel()
        for task in interruptedTurns.values.compactMap(\.task) { task.cancel() }
        eventContinuation.yield(.connectionChanged(.disconnected))
        for task in interruptedTurns.values.compactMap(\.task) { await task.value }
        await beforeDisconnectedTurnCleanup?()
        await self.markDisconnectedTurnsFailed(interruptedTurns)
    }

    /// Finalizes any provider conversations whose stream was invalidated by a
    /// disconnect. The stream task may have completed a persistence transaction
    /// just before cancellation won the generation race, so only a still-live
    /// record is changed here; a terminal successful/failure write is left
    /// intact.
    private func markDisconnectedTurnsFailed(
        _ turns: [String: ActiveTurn]
    ) async {
        for (threadID, turn) in turns {
            do {
                _ = try await conversationStore.update(
                    connectionID: connectionID,
                    id: threadID,
                    scopeID: turn.conversationScopeID
                ) { conversation in
                    guard conversation.status == .running,
                          let index = conversation.messages.firstIndex(where: {
                              $0.id == turn.assistantMessageID
                                  && $0.status == .running
                          })
                    else { return }
                    conversation.messages[index].status = .failed
                    conversation.messages[index].detail =
                        "The provider disconnected before this response finished."
                    conversation.status = .failed
                    conversation.updatedAt = .now
                }
            } catch {
                // The conversation may have been deleted while the stream was
                // being cancelled. There is no durable record left to repair.
            }
        }
    }

    func startLogin(methodID _: String) async throws -> RuntimeLoginStart {
        throw AgentRuntimeError.unsupported("provider login; add a bearer key in provider settings")
    }

    func cancelLogin(id _: String) async throws {
        throw AgentRuntimeError.unsupported("provider login")
    }

    func logout() async throws {
        throw AgentRuntimeError.unsupported("provider logout")
    }

    func refreshAccount() async throws -> RuntimeSession {
        if !connected { return try await connect() }
        guard let record = connection else { throw OpenAICompatibleRuntimeError.notConnected }
        let generation = connectionGeneration
        let resolved = try await resolveProviderConfiguration(
            startingFrom: record,
            generation: generation,
            previousCredential: bearerToken,
            comparePreviousCredential: true
        )
        guard connected, generation == connectionGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
        bearerToken = resolved.credential
        transport = resolved.transport
        discoveredModels = resolved.models
        connection = resolved.record
        let snapshot = sessionSnapshot()
        if let cachedDiscoveryNotice = resolved.cachedDiscoveryNotice {
            eventContinuation.yield(
                .runtimeNotice(
                    title: "Using cached provider models",
                    detail: cachedDiscoveryNotice
                )
            )
        }
        eventContinuation.yield(.accountUpdated(snapshot.auth))
        return snapshot
    }

    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread] {
        try await ensureConnected()
        guard let scopeID = connection?.conversationScopeID else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        return try await conversationStore.conversations(
            connectionID: connectionID,
            scopeID: scopeID,
            archived: archived,
            limit: limit
        ).map { $0.runtimeThread(kind: kind) }
    }

    func listAllThreads(archived: Bool) async throws -> [RuntimeThread] {
        try await ensureConnected()
        guard let scopeID = connection?.conversationScopeID else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        return try await conversationStore.conversations(
            connectionID: connectionID,
            scopeID: scopeID,
            archived: archived,
            limit: Int.max
        ).map { $0.runtimeThread(kind: kind) }
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        try await ensureConnected()
        guard let scopeID = connection?.conversationScopeID else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        guard let conversation = try await conversationStore.conversation(
            connectionID: connectionID,
            id: id,
            scopeID: scopeID
        ) else {
            throw OpenAICompatibleRuntimeError.conversationNotFound(id)
        }
        return conversation.runtimeConversation(kind: kind)
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await readThread(id: id)
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        try await ensureConnected()
        let generation = connectionGeneration
        guard let record = connection else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        guard record.authMode != .bearer || bearerToken != nil else {
            throw OpenAICompatibleRuntimeError.authenticationRequired
        }
        reportUnsupportedPolicies(sandbox: request.sandboxMode, approval: request.approvalPolicy)
        guard !request.ephemeral else {
            throw AgentRuntimeError.unsupported("ephemeral conversations")
        }
        let model = try selectedModel(request.model)
        let title = "New conversation"
        let conversation = try await conversationStore.create(
            connectionID: connectionID,
            title: title,
            cwd: request.cwd,
            modelID: model.id,
            scopeID: record.conversationScopeID
        )
        guard connected, connectionGeneration == generation else {
            _ = try? await conversationStore.remove(
                connectionID: connectionID,
                id: conversation.id,
                scopeID: record.conversationScopeID
            )
            throw OpenAICompatibleRuntimeError.notConnected
        }
        let thread = conversation.runtimeThread(kind: kind)
        eventContinuation.yield(.threadUpdated(thread))
        return thread
    }

    func forkThread(id _: String) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("thread forking; use a new provider conversation")
    }

    func compactThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("thread compaction")
    }

    func deleteThread(id: String) async throws {
        try await ensureConnected()
        let generation = connectionGeneration
        guard let scopeID = connection?.conversationScopeID else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        guard !startingTurns.contains(id) else {
            throw OpenAICompatibleRuntimeError.activeTurn(id)
        }
        if let active = activeTurns.removeValue(forKey: id) {
            interruptedThreads.remove(id)
            active.task?.cancel()
        }
        guard connected, connectionGeneration == generation else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        guard try await conversationStore.remove(
            connectionID: connectionID,
            id: id,
            scopeID: scopeID
        ) != nil else {
            throw OpenAICompatibleRuntimeError.conversationNotFound(id)
        }
        guard connected, connectionGeneration == generation else { return }
        eventContinuation.yield(.threadDeleted(threadID: id))
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        try await ensureConnected()
        let generation = connectionGeneration
        guard !request.inputs.isEmpty else { throw OpenAICompatibleRuntimeError.emptyTurnInput }
        guard activeTurns[request.threadID] == nil,
              !startingTurns.contains(request.threadID) else {
            throw OpenAICompatibleRuntimeError.activeTurn(request.threadID)
        }
        startingTurns.insert(request.threadID)
        defer { startingTurns.remove(request.threadID) }
        guard let record = connection else { throw OpenAICompatibleRuntimeError.notConnected }
        guard record.authMode != .bearer || bearerToken != nil else {
            throw OpenAICompatibleRuntimeError.authenticationRequired
        }
        guard let existing = try await conversationStore.conversation(
            connectionID: connectionID,
            id: request.threadID,
            scopeID: record.conversationScopeID
        ) else {
            throw OpenAICompatibleRuntimeError.conversationNotFound(request.threadID)
        }
        guard connected, generation == connectionGeneration else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        let model = try selectedModel(request.model ?? existing.modelID)
        let history = existing.messages.compactMap(\.chatMessage)
        let capabilities = NegotiatedProviderCapabilities(
            model: model.capabilities,
            transport: effectiveTransportCapabilities(record)
        )
        let stream = capabilities.transport.contains(.streaming)
        guard stream else {
            throw AgentRuntimeError.unsupported("streaming responses for this connection")
        }
        let chatRequest = try OpenAICompatibleChatRequestBuilder.make(
            model: model,
            capabilities: capabilities,
            history: history,
            inputs: request.inputs,
            stream: true,
            reasoningEffort: request.reasoningEffort,
            includeStreamingUsage: capabilities.transport.contains(.streamUsage),
            requestBehavior: record.requestBehavior
        )

        let rawUserText = request.inputs.compactMap { input -> String? in
            guard case let .text(value) = input else { return nil }
            return value
        }.joined(separator: "\n")
        let userText = rawUserText.isEmpty
            && request.inputs.contains(where: {
                switch $0 {
                case .imageURL, .localImagePath: true
                case .text: false
                }
            })
            ? "[Image attachment]"
            : rawUserText
        let resolvedUserParts = chatRequest.messages.last?.parts.map(
            OpenAICompatibleStoredMessage.ContentPart.init
        ) ?? [.text(userText)]
        let userMessage = OpenAICompatibleStoredMessage(
            role: .user,
            text: userText,
            contentParts: resolvedUserParts,
            status: .completed
        )
        let assistantMessage = OpenAICompatibleStoredMessage(
            role: .assistant,
            text: "",
            status: .running
        )
        let updated = try await conversationStore.update(
            connectionID: connectionID,
            id: request.threadID,
            scopeID: record.conversationScopeID
        ) { latest in
            // `activeTurns` is the authoritative in-process reservation. A
            // prior process or a failed final persistence can leave the disk
            // record marked running; recover that stale marker transactionally
            // instead of trapping this conversation in `activeTurn` forever.
            if latest.status == .running {
                latest.status = .failed
                for index in latest.messages.indices
                where latest.messages[index].status == .running
                {
                    latest.messages[index].status = .failed
                    latest.messages[index].detail =
                        "The previous response did not finish saving."
                }
            }
            latest.modelID = model.id
            latest.status = .running
            latest.updatedAt = .now
            if latest.title == "New conversation",
               !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                latest.title = Self.title(from: userText)
            }
            latest.messages.append(userMessage)
            latest.messages.append(assistantMessage)
        }

        guard connected, generation == connectionGeneration, let transport else {
            try? await rollbackUnstartedTurn(
                threadID: request.threadID,
                userMessageID: userMessage.id,
                assistantMessageID: assistantMessage.id,
                conversationScopeID: record.conversationScopeID
            )
            throw OpenAICompatibleRuntimeError.notConnected
        }

        let turnID = "turn:\(UUID().uuidString.lowercased())"
        eventContinuation.yield(.threadUpdated(updated.runtimeThread(kind: kind)))
        eventContinuation.yield(.turnStarted(threadID: request.threadID, turnID: turnID))
        eventContinuation.yield(.itemStarted(
            threadID: request.threadID,
            item: userMessage.timelineItem
        ))
        eventContinuation.yield(.itemStarted(
            threadID: request.threadID,
            item: assistantMessage.timelineItem
        ))
        reportUnsupportedPolicies(sandbox: request.sandboxMode, approval: request.approvalPolicy)

        // Reserve the slot before creating the child task. If a test endpoint
        // completes synchronously, `finishTurn` can remove this placeholder;
        // the optional task handle then cannot resurrect it.
        activeTurns[request.threadID] = ActiveTurn(
            turnID: turnID,
            assistantMessageID: assistantMessage.id,
            conversationScopeID: record.conversationScopeID,
            generation: generation,
            task: nil
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(
                threadID: request.threadID,
                turnID: turnID,
                assistantMessageID: assistantMessage.id,
                request: chatRequest,
                transport: transport,
                conversationScopeID: record.conversationScopeID,
                generation: generation
            )
        }
        activeTurns[request.threadID]?.task = task
        if interruptedThreads.contains(request.threadID) {
            task.cancel()
        }
    }

    func startReview(_: StartReviewRequest) async throws -> RuntimeReviewRun {
        throw AgentRuntimeError.unsupported("code review")
    }

    func steer(threadID _: String, text _: String) async throws {
        throw AgentRuntimeError.unsupported("steering an active provider turn")
    }

    func interrupt(threadID: String) async throws {
        guard let active = activeTurns[threadID] else {
            throw AgentRuntimeError.unsupported("interrupting a conversation without an active turn")
        }
        interruptedThreads.insert(threadID)
        // The request slot is reserved before the child Task is scheduled;
        // retaining the intent here makes an immediate user cancellation
        // deterministic even when the task handle has not been assigned yet.
        active.task?.cancel()
    }

    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {
        throw AgentRuntimeError.unsupported("interactive approvals or questions")
    }

    func renameThread(id: String, name: String) async throws {
        try await ensureConnected()
        let generation = connectionGeneration
        guard let scopeID = connection?.conversationScopeID else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw OpenAICompatibleRuntimeError.emptyConversationName }
        let title = String(normalized.prefix(200))
        let conversation: OpenAICompatibleStoredConversation
        do {
            conversation = try await conversationStore.update(
                connectionID: connectionID,
                id: id,
                scopeID: scopeID
            ) { conversation in
                conversation.title = title
                conversation.updatedAt = .now
            }
        } catch let error as OpenAICompatibleConversationStoreError {
            if case .conversationNotFound = error {
                throw OpenAICompatibleRuntimeError.conversationNotFound(id)
            }
            throw error
        }
        guard connected, connectionGeneration == generation else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        eventContinuation.yield(.threadNameChanged(threadID: id, name: conversation.title))
        eventContinuation.yield(.threadUpdated(conversation.runtimeThread(kind: kind)))
    }

    func archiveThread(id: String) async throws {
        try await setArchived(id: id, archived: true)
    }

    func unarchiveThread(id: String) async throws {
        try await setArchived(id: id, archived: false)
    }

    private func setArchived(id: String, archived: Bool) async throws {
        try await ensureConnected()
        let generation = connectionGeneration
        guard let scopeID = connection?.conversationScopeID else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        let conversation: OpenAICompatibleStoredConversation
        do {
            conversation = try await conversationStore.update(
                connectionID: connectionID,
                id: id,
                scopeID: scopeID
            ) { conversation in
                conversation.isArchived = archived
                conversation.updatedAt = .now
            }
        } catch let error as OpenAICompatibleConversationStoreError {
            if case .conversationNotFound = error {
                throw OpenAICompatibleRuntimeError.conversationNotFound(id)
            }
            throw error
        }
        guard connected, connectionGeneration == generation else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
        let thread = conversation.runtimeThread(kind: kind)
        eventContinuation.yield(.threadUpdated(thread))
        eventContinuation.yield(
            archived ? .threadArchived(threadID: id) : .threadUnarchived(threadID: id)
        )
    }

    private func runTurn(
        threadID: String,
        turnID: String,
        assistantMessageID: String,
        request: OpenAICompatibleChatRequest,
        transport: OpenAICompatibleChatTransport,
        conversationScopeID: String,
        generation: UInt64
    ) async {
        var assistantText = ""
        var lastPersist = Date.distantPast
        var usage: OpenAICompatibleChatUsage?
        var completionStatus = TimelineItemStatus.completed
        var completionDetail: String?
        var responseFailureDetail: String?
        do {
            for try await event in transport.stream(request) {
                try Task.checkCancellation()
                guard isCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
                else { return }
                switch event {
                case let .chunk(chunk):
                    usage = chunk.usage ?? usage
                    let delta = chunk.choices.compactMap(\.delta.content).joined()
                    if !delta.isEmpty {
                        assistantText += delta
                        eventContinuation.yield(.itemDelta(
                            threadID: threadID,
                            itemID: assistantMessageID,
                            delta: delta
                        ))
                    }
                    // Keep crash recovery reasonably fresh without atomically
                    // rewriting a growing transcript on every token.
                    if Date().timeIntervalSince(lastPersist) >= 0.5 {
                        try await updateAssistant(
                            threadID: threadID,
                            turnID: turnID,
                            assistantMessageID: assistantMessageID,
                            text: assistantText,
                            status: .running,
                            detail: usageDetail(usage),
                            updatedAt: .now,
                            conversationScopeID: conversationScopeID,
                            generation: generation
                        )
                        lastPersist = .now
                    }
                case .completed:
                    break
                }
            }
            try Task.checkCancellation()
            guard isCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
            else { return }
            completionDetail = usageDetail(usage)
        } catch is CancellationError {
            guard isCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
            else { return }
            let interrupted = interruptedThreads.remove(threadID) != nil
            completionStatus = .failed
            completionDetail = interrupted
                ? "Response interrupted."
                : "Response cancelled."
        } catch {
            guard isCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
            else { return }
            _ = interruptedThreads.remove(threadID)
            let detail = Self.safeErrorDetail(error)
            completionStatus = .failed
            completionDetail = detail
            responseFailureDetail = detail
        }

        do {
            try await finishTurn(
                threadID: threadID,
                turnID: turnID,
                assistantMessageID: assistantMessageID,
                text: assistantText,
                status: completionStatus,
                detail: completionDetail,
                conversationScopeID: conversationScopeID,
                generation: generation
            )
        } catch {
            guard generation == connectionGeneration, connected else { return }
            eventContinuation.yield(
                .runtimeNotice(
                    title: "Provider response could not be saved",
                    detail: Self.safeErrorDetail(error)
                )
            )
        }
        if let responseFailureDetail,
           generation == connectionGeneration,
           connected
        {
            eventContinuation.yield(
                .runtimeNotice(title: "Provider response failed", detail: responseFailureDetail)
            )
        }
    }

    private func updateAssistant(
        threadID: String,
        turnID: String,
        assistantMessageID: String,
        text: String,
        status: TimelineItemStatus,
        detail: String?,
        updatedAt: Date,
        conversationScopeID: String,
        generation: UInt64
    ) async throws {
        guard isCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
        else { throw CancellationError() }
        _ = try await conversationStore.update(
            connectionID: connectionID,
            id: threadID,
            scopeID: conversationScopeID
        ) {
            conversation in
            guard let index = conversation.messages.firstIndex(where: {
                $0.id == assistantMessageID
            }) else { return }
            conversation.messages[index].text = text
            conversation.messages[index].status = status
            conversation.messages[index].detail = detail
            conversation.updatedAt = updatedAt
        }
        guard isCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
        else { throw CancellationError() }
    }

    private func finishTurn(
        threadID: String,
        turnID: String,
        assistantMessageID: String,
        text: String,
        status: TimelineItemStatus,
        detail: String?,
        conversationScopeID: String,
        generation: UInt64
    ) async throws {
        guard isCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
        else { return }
        let conversation: OpenAICompatibleStoredConversation
        do {
            conversation = try await conversationStore.update(
                connectionID: connectionID,
                id: threadID,
                scopeID: conversationScopeID
            ) { conversation in
                guard let index = conversation.messages.firstIndex(where: {
                    $0.id == assistantMessageID
                }) else { return }
                conversation.messages[index].text = text
                conversation.messages[index].status = status
                conversation.messages[index].detail = detail
                conversation.status = status == .completed ? .idle : .failed
                conversation.updatedAt = .now
            }
        } catch {
            if removeCurrentTurn(threadID: threadID, turnID: turnID, generation: generation) {
                let failureDetail = "The response finished, but its conversation could not be saved."
                eventContinuation.yield(.itemCompleted(
                    threadID: threadID,
                    item: TimelineItem(
                        id: assistantMessageID,
                        kind: .assistantMessage,
                        title: nil,
                        body: text,
                        status: .failed,
                        timestamp: .now,
                        detail: failureDetail
                    )
                ))
                eventContinuation.yield(.threadStatusChanged(threadID: threadID, status: .failed))
                eventContinuation.yield(.turnCompleted(threadID: threadID, status: .failed))
            }
            throw error
        }

        guard removeCurrentTurn(threadID: threadID, turnID: turnID, generation: generation)
        else { return }
        guard let item = conversation.messages.first(where: { $0.id == assistantMessageID })?
            .timelineItem
        else { return }
        eventContinuation.yield(.itemCompleted(threadID: threadID, item: item))
        eventContinuation.yield(.threadUpdated(conversation.runtimeThread(kind: kind)))
        eventContinuation.yield(.turnCompleted(
            threadID: threadID,
            status: conversation.status
        ))
    }

    private func rollbackUnstartedTurn(
        threadID: String,
        userMessageID: String,
        assistantMessageID: String,
        conversationScopeID: String
    ) async throws {
        _ = try await conversationStore.update(
            connectionID: connectionID,
            id: threadID,
            scopeID: conversationScopeID
        ) {
            conversation in
            guard conversation.messages.contains(where: {
                $0.id == userMessageID
            }), conversation.messages.contains(where: {
                $0.id == assistantMessageID && $0.status == .running
            }) else { return }
            conversation.messages.removeAll {
                $0.id == userMessageID || $0.id == assistantMessageID
            }
            if conversation.messages.contains(where: { $0.status == .running }) {
                conversation.status = .running
            } else if conversation.messages.last?.status == .failed {
                conversation.status = .failed
            } else {
                conversation.status = .idle
            }
            conversation.updatedAt = .now
        }
    }

    private func isCurrentTurn(
        threadID: String,
        turnID: String,
        generation: UInt64
    ) -> Bool {
        guard connected,
              connectionGeneration == generation,
              let active = activeTurns[threadID]
        else { return false }
        return active.turnID == turnID && active.generation == generation
    }

    @discardableResult
    private func removeCurrentTurn(
        threadID: String,
        turnID: String,
        generation: UInt64
    ) -> Bool {
        guard let active = activeTurns[threadID],
              active.turnID == turnID,
              active.generation == generation
        else { return false }
        activeTurns.removeValue(forKey: threadID)
        interruptedThreads.remove(threadID)
        return true
    }

    private func ensureConnected() async throws {
        if !connected { _ = try await connect() }
        guard connected, transport != nil, connection != nil else {
            throw OpenAICompatibleRuntimeError.notConnected
        }
    }

    private func selectedModel(_ requested: String?) throws -> ProviderModelDescriptor {
        guard let record = connection else { throw OpenAICompatibleRuntimeError.notConnected }
        let modelID = requested?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? record.selectedModelID
            ?? discoveredModels.first?.id
            ?? record.discovery.discoveredModelIDs.first
        guard let modelID else { throw OpenAICompatibleRuntimeError.noModelsAvailable }
        if let model = discoveredModels.first(where: { $0.id == modelID }) { return model }
        if discoveredModels.isEmpty, record.discovery.discoveredModelIDs.contains(modelID) {
            if let cached = Self.cachedModel(modelID) { return cached }
            throw OpenAICompatibleRuntimeError.modelNotFound(modelID)
        }
        throw OpenAICompatibleRuntimeError.modelNotFound(modelID)
    }

    private func sessionSnapshot() -> RuntimeSession {
        let record = connection
        let auth: RuntimeAuthState
        if record?.authMode == ProviderConnectionAuthMode.none {
            auth = RuntimeAuthState(mode: nil, email: nil, planLabel: nil, requiresAuthentication: false)
        } else {
            auth = RuntimeAuthState(
                mode: bearerToken == nil ? nil : .apiKey,
                email: nil,
                planLabel: nil,
                requiresAuthentication: bearerToken == nil
            )
        }
        var capabilities: RuntimeCapabilities = [.threadArchiving, .threadDeletion]
        let transportCapabilities = record.map(effectiveTransportCapabilities) ?? []
        if transportCapabilities.contains(.streaming) {
            capabilities.insert(.streaming)
            capabilities.insert(.interruption)
        }
        if transportCapabilities.contains(.streamUsage) { capabilities.insert(.usage) }
        if discoveredModels.contains(where: { $0.capabilities.inputModalities.contains(.image) }) {
            capabilities.insert(.images)
        }
        if discoveredModels.contains(where: { !$0.capabilities.reasoningEfforts.isEmpty }) {
            capabilities.insert(.reasoning)
        }
        let models = discoveredModels.enumerated().map { index, model in
            RuntimeModel(
                id: model.id,
                displayName: model.displayName,
                description: model.description,
                isDefault: model.id == record?.selectedModelID || (record?.selectedModelID == nil && index == 0),
                defaultReasoningEffort: model.capabilities.reasoningEfforts.first,
                reasoningEfforts: model.capabilities.reasoningEfforts,
                inputModalities: model.capabilities.inputModalities,
                supportedRequestParameters: model.capabilities.supportedParameters,
                capabilityEvidence: model.capabilityEvidence
            )
        }
        return RuntimeSession(
            runtime: kind,
            displayName: record?.displayName ?? "OpenAI-compatible provider",
            accountLabel: auth.displayLabel,
            planLabel: nil,
            auth: auth,
            availableLoginMethods: [],
            availableModels: models,
            capabilities: capabilities
        )
    }

    private func readBearerCredential(for record: ProviderConnectionRecord) async throws -> String? {
        guard record.authMode == .bearer,
              let credential = try await credentialStore.credential(for: record.credentialKey)
        else { return nil }
        return try credential.withValue { $0 }
    }

    private func discoverModels(
        record: ProviderConnectionRecord,
        bearerToken: String?
    ) async throws -> [ProviderModelDescriptor] {
        do {
            let credential = try bearerToken.map(ProviderBearerCredential.init)
            return try await URLSessionProviderModelDiscovery(session: session).discoverModels(
                for: record,
                credential: credential
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAICompatibleRuntimeError {
            throw error
        } catch {
            throw OpenAICompatibleRuntimeError.discoveryFailed(Self.safeErrorDetail(error))
        }
    }

    /// Resolves one internally consistent endpoint/catalog/transport snapshot.
    /// A settings save may finish while `/models` is in flight; in that case we
    /// discard the old response and retry against the newly saved connection
    /// instead of attaching old model IDs to the new endpoint.
    private func resolveProviderConfiguration(
        startingFrom initialRecord: ProviderConnectionRecord,
        generation: UInt64,
        previousCredential: String? = nil,
        comparePreviousCredential: Bool = false,
        maximumDiscoveryAttempts: Int = 3
    ) async throws -> ResolvedProviderConfiguration {
        var record = initialRecord

        if comparePreviousCredential {
            try ensureCurrentGeneration(generation)
            let currentCredential = try await readBearerCredential(for: record)
            try ensureCurrentGeneration(generation)
            if currentCredential != previousCredential {
                record = try await rotateConversationScopeIfStillOwned(
                    by: record.conversationScopeID,
                    clearingDiscoveryIfMatching: record.discovery
                )
            }
        }

        for _ in 0..<maximumDiscoveryAttempts {
            try ensureCurrentGeneration(generation)
            let credential = try await readBearerCredential(for: record)
            try ensureCurrentGeneration(generation)

            // A missing bearer is a valid signed-out state. It deliberately
            // uses only the catalog already associated with this exact record.
            guard record.authMode == .none || credential != nil else {
                let resolved = try await makeResolvedProviderConfiguration(
                    record: record,
                    models: Self.cachedModels(
                        from: record.discovery,
                        selectedModelID: record.selectedModelID
                    ),
                    cachedDiscoveryNotice: nil,
                    generation: generation
                )
                let validation = try await isCurrentResolvedProviderConfiguration(
                    resolved,
                    generation: generation
                )
                guard validation.isCurrent else {
                    record = validation.latest
                    continue
                }
                return resolved
            }

            let scope = ModelDiscoveryScope(record, credential: credential)
            let attemptedAt = Date()
            let discovered: [ProviderModelDescriptor]
            do {
                discovered = try await discoverModels(record: record, bearerToken: credential)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let discoveryError = error
                let metadata = ProviderConnectionDiscoveryMetadata(
                    lastAttemptedAt: attemptedAt,
                    lastSucceededAt: record.discovery.lastSucceededAt,
                    discoveredModelIDs: record.discovery.discoveredModelIDs,
                    discoveredModels: record.discovery.discoveredModels
                )
                let updated = try await connectionStore.update(id: connectionID) { latest in
                    guard scope.baseURL == latest.baseURL,
                          scope.authMode == latest.authMode,
                          scope.transportSecurity == latest.transportSecurity
                    else { return }
                    latest.discovery = metadata
                }
                try ensureCurrentGeneration(generation)
                let updatedCredential = try await readBearerCredential(for: updated)
                try ensureCurrentGeneration(generation)
                guard scope.contains(updated, credential: updatedCredential) else {
                    // The store transaction can validate only non-secret
                    // scope. If the Keychain value changed during discovery,
                    // erase the just-written old-credential catalog before
                    // retrying so no other window can consume it.
                    record = try await clearDiscoveryIfStillMatching(
                        updated,
                        metadata: metadata,
                        previousConversationScopeID: record.conversationScopeID
                    )
                    continue
                }

                let cachedModels = Self.cachedModels(
                    from: updated.discovery,
                    selectedModelID: updated.selectedModelID
                )
                guard !cachedModels.isEmpty else { throw discoveryError }
                let resolved = try await makeResolvedProviderConfiguration(
                    record: updated,
                    credential: updatedCredential,
                    models: cachedModels,
                    cachedDiscoveryNotice: Self.safeErrorDetail(discoveryError),
                    generation: generation
                )
                let validation = try await isCurrentResolvedProviderConfiguration(
                    resolved,
                    generation: generation
                )
                guard validation.isCurrent else {
                    record = validation.latest
                    continue
                }
                return resolved
            }

            try ensureCurrentGeneration(generation)
            let metadata = ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: attemptedAt,
                lastSucceededAt: Date(),
                discoveredModelIDs: discovered.map(\.id),
                discoveredModels: discovered
            )
            let updated = try await connectionStore.update(id: connectionID) { latest in
                guard scope.baseURL == latest.baseURL,
                      scope.authMode == latest.authMode,
                      scope.transportSecurity == latest.transportSecurity
                else { return }
                latest.discovery = metadata
            }
            try ensureCurrentGeneration(generation)
            let updatedCredential = try await readBearerCredential(for: updated)
            try ensureCurrentGeneration(generation)
            guard scope.contains(updated, credential: updatedCredential) else {
                record = try await clearDiscoveryIfStillMatching(
                    updated,
                    metadata: metadata,
                    previousConversationScopeID: record.conversationScopeID
                )
                continue
            }
            let availableModels = Self.cachedModels(
                from: updated.discovery,
                selectedModelID: updated.selectedModelID
            )
            let resolved = try await makeResolvedProviderConfiguration(
                record: updated,
                credential: updatedCredential,
                models: availableModels,
                cachedDiscoveryNotice: nil,
                generation: generation
            )
            let validation = try await isCurrentResolvedProviderConfiguration(
                resolved,
                generation: generation
            )
            guard validation.isCurrent else {
                record = validation.latest
                continue
            }
            return resolved
        }

        // Do not publish a catalog obtained for any of the rapidly changing
        // endpoints above. The last saved record is still usable with only its
        // own cached catalog; a later refresh can retry network discovery.
        guard let latest = try await connectionStore.connection(id: connectionID) else {
            throw OpenAICompatibleRuntimeError.connectionNotFound(connectionID)
        }
        let resolved = try await makeResolvedProviderConfiguration(
            record: latest,
            models: Self.cachedModels(
                from: latest.discovery,
                selectedModelID: latest.selectedModelID
            ),
            cachedDiscoveryNotice: "Provider settings changed while models were loading. Using the saved model catalog.",
            generation: generation
        )
        let validation = try await isCurrentResolvedProviderConfiguration(
            resolved,
            generation: generation
        )
        guard validation.isCurrent else {
            // Never pair a cached catalog or credential with a record that
            // changed after the final retry. The next refresh will start from
            // the latest persisted configuration.
            throw CancellationError()
        }
        return resolved
    }

    private func makeResolvedProviderConfiguration(
        record: ProviderConnectionRecord,
        credential resolvedCredential: String? = nil,
        models: [ProviderModelDescriptor],
        cachedDiscoveryNotice: String?,
        generation: UInt64
    ) async throws -> ResolvedProviderConfiguration {
        let credential: String?
        if record.authMode != .bearer {
            credential = nil
        } else if let resolvedCredential {
            credential = resolvedCredential
        } else {
            credential = try await readBearerCredential(for: record)
        }
        try ensureCurrentGeneration(generation)
        let transport = try OpenAICompatibleChatTransport(
            endpoint: record.baseURL,
            bearerToken: credential,
            allowsInsecureHTTP: record.transportSecurity == .allowInsecureHTTP,
            session: session
        )
        return ResolvedProviderConfiguration(
            record: record,
            credential: credential,
            models: models,
            transport: transport,
            cachedDiscoveryNotice: cachedDiscoveryNotice
        )
    }

    private func clearDiscoveryIfStillMatching(
        _ record: ProviderConnectionRecord,
        metadata: ProviderConnectionDiscoveryMetadata,
        previousConversationScopeID: String
    ) async throws -> ProviderConnectionRecord {
        try await connectionStore.update(id: connectionID) { latest in
            if latest.baseURL == record.baseURL,
               latest.authMode == record.authMode,
               latest.transportSecurity == record.transportSecurity,
               Self.isSamePersistedDiscovery(latest.discovery, metadata)
            {
                latest.discovery = .init()
            }
            if latest.conversationScopeID == previousConversationScopeID {
                latest.conversationScopeID = ProviderConnectionRecord.makeConversationScopeID()
            }
        }
    }

    /// Connection records pass through JSON between transactions. Date's
    /// binary value can move by a fraction of a microsecond during the
    /// milliseconds-since-1970 encode/decode round trip, so synthesized
    /// equality would fail to recognize the exact discovery write that this
    /// cleanup is meant to remove.
    private static func isSamePersistedDiscovery(
        _ lhs: ProviderConnectionDiscoveryMetadata,
        _ rhs: ProviderConnectionDiscoveryMetadata
    ) -> Bool {
        lhs.discoveredModelIDs == rhs.discoveredModelIDs
            && lhs.discoveredModels == rhs.discoveredModels
            && persistedDatesMatch(lhs.lastAttemptedAt, rhs.lastAttemptedAt)
            && persistedDatesMatch(lhs.lastSucceededAt, rhs.lastSucceededAt)
    }

    private static func persistedDatesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) <= 0.000_001
        default: false
        }
    }

    /// Closes the final settings-edit window after discovery and transport
    /// construction. Returning a resolved snapshot is safe only if both the
    /// persisted request scope and the transient credential still match.
    private func isCurrentResolvedProviderConfiguration(
        _ resolved: ResolvedProviderConfiguration,
        generation: UInt64
    ) async throws -> (isCurrent: Bool, latest: ProviderConnectionRecord) {
        try ensureCurrentGeneration(generation)
        guard let latest = try await connectionStore.connection(id: connectionID) else {
            throw OpenAICompatibleRuntimeError.connectionNotFound(connectionID)
        }
        let latestCredential = try await readBearerCredential(for: latest)
        try ensureCurrentGeneration(generation)
        let scope = ModelDiscoveryScope(
            resolved.record,
            credential: resolved.credential
        )
        guard scope.contains(latest, credential: latestCredential) else {
            let rotated = try await rotateConversationScopeIfStillOwned(
                by: resolved.record.conversationScopeID,
                clearingDiscoveryIfMatching: resolved.record.discovery
            )
            return (false, rotated)
        }
        return (true, latest)
    }

    private func rotateConversationScopeIfStillOwned(
        by previousConversationScopeID: String,
        clearingDiscoveryIfMatching previousDiscovery: ProviderConnectionDiscoveryMetadata? = nil
    ) async throws -> ProviderConnectionRecord {
        try await connectionStore.update(id: connectionID) { latest in
            guard latest.conversationScopeID == previousConversationScopeID else { return }
            latest.conversationScopeID = ProviderConnectionRecord.makeConversationScopeID()
            if let previousDiscovery,
               Self.isSamePersistedDiscovery(latest.discovery, previousDiscovery)
            {
                // The catalog was discovered in the same endpoint/credential
                // scope as the history we just isolated. Keeping it would let
                // a failed refresh under the replacement credential silently
                // re-advertise models owned by the previous account.
                latest.discovery = .init()
            }
        }
    }

    private func ensureCurrentGeneration(_ generation: UInt64) throws {
        guard connectionGeneration == generation, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private static func cachedModel(_ id: String) -> ProviderModelDescriptor? {
        try? ProviderModelDescriptor(
            id: id,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(),
            capabilityEvidence: .unknown
        )
    }

    private static func cachedModels(
        from metadata: ProviderConnectionDiscoveryMetadata,
        selectedModelID: String? = nil
    ) -> [ProviderModelDescriptor] {
        var models: [ProviderModelDescriptor]
        if !metadata.discoveredModels.isEmpty {
            models = metadata.discoveredModels
        } else {
            models = metadata.discoveredModelIDs.compactMap(Self.cachedModel)
        }

        // Discovery is optional and some OpenAI-compatible `/models` routes
        // expose only a partial catalog. Preserve a manually saved model ID
        // as a conservative text-only descriptor when it is omitted. This
        // keeps the model selectable and lets the normal chat request surface
        // any endpoint-specific error instead of hiding the provider model.
        if let selectedModelID = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedModelID.isEmpty,
           !models.contains(where: { $0.id == selectedModelID }),
           let fallback = Self.cachedModel(selectedModelID) {
            models.append(fallback)
        }
        return models
    }

    private func effectiveTransportCapabilities(
        _ record: ProviderConnectionRecord
    ) -> Set<ProviderTransportCapability> {
        // Early Onyx previews persisted an empty array before the Settings UI
        // began declaring the SSE capabilities required by this adapter. An
        // empty production record is therefore legacy/unspecified, not a
        // usable non-streaming mode (the runtime cannot run turns without
        // streaming). Keep those saved vLLM connections working in place.
        record.transportCapabilities.isEmpty
            ? [.streaming, .streamUsage]
            : record.transportCapabilities
    }

    private func reportUnsupportedPolicies(
        sandbox: RuntimeSandboxMode,
        approval: RuntimeApprovalPolicy
    ) {
        if sandbox != .workspaceWrite || approval != .onRequest {
            eventContinuation.yield(
                .runtimeNotice(
                    title: "Provider controls unavailable",
                    detail: "This chat provider does not execute local tools, sandbox commands, or approvals."
                )
            )
        }
    }

    private func usageDetail(_ usage: OpenAICompatibleChatUsage?) -> String? {
        guard let usage else { return nil }
        let fields = [
            usage.promptTokens.map { "prompt \($0)" },
            usage.completionTokens.map { "response \($0)" },
            usage.totalTokens.map { "total \($0)" },
        ].compactMap { $0 }
        return fields.isEmpty ? nil : "Token usage: \(fields.joined(separator: ", "))"
    }

    private static func title(from text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > 80 else { return collapsed }
        return String(collapsed.prefix(77)) + "…"
    }

    private static func safeErrorDetail(_ error: any Error) -> String {
        if let error = error as? OpenAICompatibleChatTransportError {
            return error.localizedDescription
        }
        if let error = error as? OpenAICompatibleRuntimeError {
            return error.localizedDescription
        }
        return error.localizedDescription
            .replacingOccurrences(of: "Authorization", with: "credential", options: .caseInsensitive)
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
