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

    private var connection: ProviderConnectionRecord?
    private var transport: OpenAICompatibleChatTransport?
    private var bearerToken: String?
    private var discoveredModels: [ProviderModelDescriptor] = []
    private var connected = false
    private var connectionGeneration: UInt64 = 0
    private var connectionAttempt: Task<RuntimeSession, any Error>?
    private var activeTurns: [String: ActiveTurn] = [:]
    private var startingTurns: Set<String> = []
    private var interruptedThreads: Set<String> = []

    private struct ActiveTurn: Sendable {
        let turnID: String
        let assistantMessageID: String
        let generation: UInt64
        var task: Task<Void, Never>?
    }

    init(
        connectionID: ProviderConnectionID,
        connectionStore: ProviderConnectionStore = ProviderConnectionStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        conversationStore: OpenAICompatibleConversationStore = OpenAICompatibleConversationStore(),
        session: URLSession? = nil
    ) {
        self.connectionID = connectionID
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.conversationStore = conversationStore
        self.session = session ?? Self.makeDefaultSession()
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        connectionAttempt?.cancel()
        for active in activeTurns.values { active.task?.cancel() }
        eventContinuation.finish()
    }

    func connect() async throws -> RuntimeSession {
        if connected { return sessionSnapshot() }
        if let connectionAttempt { return try await connectionAttempt.value }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        eventContinuation.yield(.connectionChanged(.connecting))
        let attempt = Task { [weak self] () throws -> RuntimeSession in
            guard let self else { throw OpenAICompatibleRuntimeError.notConnected }
            return try await self.establishConnection(generation: generation)
        }
        connectionAttempt = attempt
        do {
            return try await attempt.value
        } catch {
            if connectionAttempt != nil { connectionAttempt = nil }
            throw error
        }
    }

    private func establishConnection(generation: UInt64) async throws -> RuntimeSession {
        do {
            guard let configured = try await connectionStore.connection(id: connectionID) else {
                throw OpenAICompatibleRuntimeError.connectionNotFound(connectionID)
            }
            var record = configured
            let credential = try await readBearerCredential(for: record)
            guard connectionGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }

            connection = record
            bearerToken = credential
            transport = try OpenAICompatibleChatTransport(
                endpoint: record.baseURL,
                bearerToken: credential,
                allowsInsecureHTTP: record.transportSecurity == .allowInsecureHTTP,
                session: session
            )

            // A missing bearer is a valid disconnected-account state. Keep
            // cached model names available to settings without making a
            // request that cannot authenticate.
            let shouldDiscover = record.authMode == .none || credential != nil
            var models: [ProviderModelDescriptor] = []
            if shouldDiscover {
                let attemptedAt = Date()
                do {
                    models = try await discoverModels(record: record, bearerToken: credential)
                    record.discovery = ProviderConnectionDiscoveryMetadata(
                        lastAttemptedAt: attemptedAt,
                        lastSucceededAt: Date(),
                        discoveredModelIDs: models.map(\.id)
                    )
                    try await connectionStore.upsert(record)
                } catch {
                    record.discovery = ProviderConnectionDiscoveryMetadata(
                        lastAttemptedAt: attemptedAt,
                        lastSucceededAt: record.discovery.lastSucceededAt,
                        discoveredModelIDs: record.discovery.discoveredModelIDs
                    )
                    _ = try? await connectionStore.upsert(record)
                    if record.discovery.discoveredModelIDs.isEmpty {
                        throw error
                    }
                    models = record.discovery.discoveredModelIDs.compactMap(Self.cachedModel)
                    eventContinuation.yield(
                        .runtimeNotice(
                            title: "Using cached provider models",
                            detail: Self.safeErrorDetail(error)
                        )
                    )
                }
            } else {
                models = record.discovery.discoveredModelIDs.compactMap(Self.cachedModel)
            }

            guard connectionGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            discoveredModels = models
            connection = record
            connected = true
            _ = try? await conversationStore.recoverInterruptedTurns(connectionID: connectionID)
            let snapshot = sessionSnapshot()
            connectionAttempt = nil
            eventContinuation.yield(.accountUpdated(snapshot.auth))
            eventContinuation.yield(.connectionChanged(.connected(record.displayName)))
            return snapshot
        } catch {
            guard connectionGeneration == generation else { throw error }
            connected = false
            transport = nil
            connection = nil
            bearerToken = nil
            connectionAttempt = nil
            eventContinuation.yield(.connectionChanged(.failed(Self.safeErrorDetail(error))))
            throw error
        }
    }

    func disconnect() async {
        let running = activeTurns.values.compactMap(\.task)
        interruptedThreads.formUnion(activeTurns.keys)
        for task in running { task.cancel() }
        for task in running { await task.value }

        connectionGeneration &+= 1
        connectionAttempt?.cancel()
        connectionAttempt = nil
        connected = false
        transport = nil
        connection = nil
        bearerToken = nil
        activeTurns.removeAll()
        interruptedThreads.removeAll()
        eventContinuation.yield(.connectionChanged(.disconnected))
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
        let credential = try await readBearerCredential(for: record)
        guard connected, generation == connectionGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
        let refreshedTransport = try OpenAICompatibleChatTransport(
            endpoint: record.baseURL,
            bearerToken: credential,
            allowsInsecureHTTP: record.transportSecurity == .allowInsecureHTTP,
            session: session
        )
        if record.authMode == .bearer, credential == nil {
            bearerToken = nil
            transport = refreshedTransport
            return sessionSnapshot()
        }
        let models = try await discoverModels(record: record, bearerToken: credential)
        guard connected, generation == connectionGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
        bearerToken = credential
        transport = refreshedTransport
        discoveredModels = models
        var updated = record
        updated.discovery = ProviderConnectionDiscoveryMetadata(
            lastAttemptedAt: Date(),
            lastSucceededAt: Date(),
            discoveredModelIDs: models.map(\.id)
        )
        try await connectionStore.upsert(updated)
        guard connected, generation == connectionGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
        connection = updated
        let snapshot = sessionSnapshot()
        eventContinuation.yield(.accountUpdated(snapshot.auth))
        return snapshot
    }

    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread] {
        try await ensureConnected()
        return try await conversationStore.conversations(
            connectionID: connectionID,
            archived: archived,
            limit: limit
        ).map { $0.runtimeThread(kind: kind) }
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        try await ensureConnected()
        guard let conversation = try await conversationStore.conversation(
            connectionID: connectionID,
            id: id
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
        guard connection?.authMode != .bearer || bearerToken != nil else {
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
            modelID: model.id
        )
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
        guard !startingTurns.contains(id) else {
            throw OpenAICompatibleRuntimeError.activeTurn(id)
        }
        activeTurns[id]?.task?.cancel()
        activeTurns.removeValue(forKey: id)
        guard try await conversationStore.remove(connectionID: connectionID, id: id) != nil else {
            throw OpenAICompatibleRuntimeError.conversationNotFound(id)
        }
        eventContinuation.yield(.threadDeleted(threadID: id))
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        try await ensureConnected()
        guard !request.inputs.isEmpty else { throw OpenAICompatibleRuntimeError.emptyTurnInput }
        guard activeTurns[request.threadID] == nil,
              !startingTurns.contains(request.threadID) else {
            throw OpenAICompatibleRuntimeError.activeTurn(request.threadID)
        }
        startingTurns.insert(request.threadID)
        defer { startingTurns.remove(request.threadID) }
        let generation = connectionGeneration
        guard let record = connection else { throw OpenAICompatibleRuntimeError.notConnected }
        guard record.authMode != .bearer || bearerToken != nil else {
            throw OpenAICompatibleRuntimeError.authenticationRequired
        }
        guard let existing = try await conversationStore.conversation(
            connectionID: connectionID,
            id: request.threadID
        ) else {
            throw OpenAICompatibleRuntimeError.conversationNotFound(request.threadID)
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
            && request.inputs.contains(where: { if case .imageURL = $0 { true } else { false } })
            ? "[Image attachment]"
            : rawUserText
        let userMessage = OpenAICompatibleStoredMessage(
            role: .user,
            text: userText,
            status: .completed
        )
        let assistantMessage = OpenAICompatibleStoredMessage(
            role: .assistant,
            text: "",
            status: .running
        )
        var updated = existing
        updated.modelID = model.id
        updated.status = .running
        updated.updatedAt = .now
        if updated.title == "New conversation", !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.title = Self.title(from: userText)
        }
        updated.messages.append(userMessage)
        updated.messages.append(assistantMessage)
        try await conversationStore.upsert(updated)

        guard connected, generation == connectionGeneration, let transport else {
            updated.status = .failed
            updated.updatedAt = .now
            if let index = updated.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                updated.messages[index].status = .failed
                updated.messages[index].detail = "The provider disconnected before this response started."
            }
            _ = try? await conversationStore.upsert(updated)
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
        guard var conversation = try await conversationStore.conversation(
            connectionID: connectionID,
            id: id
        ) else { throw OpenAICompatibleRuntimeError.conversationNotFound(id) }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw OpenAICompatibleRuntimeError.emptyConversationName }
        conversation.title = String(normalized.prefix(200))
        conversation.updatedAt = .now
        try await conversationStore.upsert(conversation)
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
        guard var conversation = try await conversationStore.conversation(
            connectionID: connectionID,
            id: id
        ) else { throw OpenAICompatibleRuntimeError.conversationNotFound(id) }
        conversation.isArchived = archived
        conversation.updatedAt = .now
        try await conversationStore.upsert(conversation)
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
        generation: UInt64
    ) async {
        var assistantText = ""
        var lastPersist = Date.distantPast
        var usage: OpenAICompatibleChatUsage?
        do {
            for try await event in transport.stream(request) {
                try Task.checkCancellation()
                guard generation == connectionGeneration, connected else { return }
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
                            assistantMessageID: assistantMessageID,
                            text: assistantText,
                            status: .running,
                            detail: usageDetail(usage),
                            updatedAt: .now
                        )
                        lastPersist = .now
                    }
                case .completed:
                    break
                }
            }
            try Task.checkCancellation()
            guard generation == connectionGeneration, connected else { return }
            try await finishTurn(
                threadID: threadID,
                turnID: turnID,
                assistantMessageID: assistantMessageID,
                text: assistantText,
                status: .completed,
                detail: usageDetail(usage)
            )
        } catch is CancellationError {
            guard generation == connectionGeneration, connected else { return }
            let interrupted = interruptedThreads.remove(threadID) != nil
            try? await finishTurn(
                threadID: threadID,
                turnID: turnID,
                assistantMessageID: assistantMessageID,
                text: assistantText,
                status: .failed,
                detail: interrupted
                    ? "Response interrupted."
                    : "Response cancelled."
            )
        } catch {
            guard generation == connectionGeneration, connected else { return }
            _ = interruptedThreads.remove(threadID)
            let detail = Self.safeErrorDetail(error)
            try? await finishTurn(
                threadID: threadID,
                turnID: turnID,
                assistantMessageID: assistantMessageID,
                text: assistantText,
                status: .failed,
                detail: detail
            )
            eventContinuation.yield(.runtimeNotice(title: "Provider response failed", detail: detail))
        }
    }

    private func updateAssistant(
        threadID: String,
        assistantMessageID: String,
        text: String,
        status: TimelineItemStatus,
        detail: String?,
        updatedAt: Date
    ) async throws {
        guard var conversation = try await conversationStore.conversation(
            connectionID: connectionID,
            id: threadID
        ) else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) else {
            return
        }
        conversation.messages[index].text = text
        conversation.messages[index].status = status
        conversation.messages[index].detail = detail
        conversation.updatedAt = updatedAt
        try await conversationStore.upsert(conversation)
    }

    private func finishTurn(
        threadID: String,
        turnID: String,
        assistantMessageID: String,
        text: String,
        status: TimelineItemStatus,
        detail: String?
    ) async throws {
        guard var conversation = try await conversationStore.conversation(
            connectionID: connectionID,
            id: threadID
        ) else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) else {
            return
        }
        conversation.messages[index].text = text
        conversation.messages[index].status = status
        conversation.messages[index].detail = detail
        conversation.status = status == .completed ? .idle : .failed
        conversation.updatedAt = .now
        try await conversationStore.upsert(conversation)

        activeTurns.removeValue(forKey: threadID)
        let item = conversation.messages[index].timelineItem
        eventContinuation.yield(.itemCompleted(threadID: threadID, item: item))
        eventContinuation.yield(.threadUpdated(conversation.runtimeThread(kind: kind)))
        eventContinuation.yield(.turnCompleted(
            threadID: threadID,
            status: conversation.status
        ))
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
        if record?.transportCapabilities.contains(.streaming) == true {
            capabilities.insert(.streaming)
            capabilities.insert(.interruption)
        }
        if record?.transportCapabilities.contains(.streamUsage) == true { capabilities.insert(.usage) }
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
                reasoningEfforts: model.capabilities.reasoningEfforts
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
        var request = URLRequest(url: Self.modelsURL(from: record.baseURL))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw OpenAICompatibleRuntimeError.discoveryFailed("The provider returned a non-HTTP response.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw OpenAICompatibleRuntimeError.discoveryFailed("The provider returned HTTP \(http.statusCode).")
            }
            let root = try JSONDecoder().decode(JSONValue.self, from: data)
            let values = root["data"]?.arrayValue ?? root.arrayValue ?? []
            let descriptors = values.compactMap { Self.decodeModel($0) }
            guard !descriptors.isEmpty else { throw OpenAICompatibleRuntimeError.noModelsAvailable }
            return descriptors
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAICompatibleRuntimeError {
            throw error
        } catch {
            throw OpenAICompatibleRuntimeError.discoveryFailed(Self.safeErrorDetail(error))
        }
    }

    private static func decodeModel(_ value: JSONValue) -> ProviderModelDescriptor? {
        guard let id = value["id"]?.stringValue else { return nil }
        if let projected = try? ProviderModelDescriptor.openRouter(from: value) {
            return projected
        }
        return try? ProviderModelDescriptor(
            id: id,
            displayName: value["name"]?.stringValue ?? id,
            description: value["description"]?.stringValue,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(),
            contextLength: value["context_length"]?.intValue,
            maxCompletionTokens: value["max_completion_tokens"]?.intValue
        )
    }

    private static func modelsURL(from baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent("models")
        }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        }
        components.percentEncodedPath = path.isEmpty || path == "/"
            ? "/models"
            : path + "/models"
        return components.url ?? baseURL.appendingPathComponent("models")
    }

    private static func cachedModel(_ id: String) -> ProviderModelDescriptor? {
        try? ProviderModelDescriptor(
            id: id,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet()
        )
    }

    private func effectiveTransportCapabilities(
        _ record: ProviderConnectionRecord
    ) -> Set<ProviderTransportCapability> {
        record.transportCapabilities
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
