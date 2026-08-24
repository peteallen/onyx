import Foundation

actor CodexRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private static let browserLoginMethod = RuntimeLoginMethod(
        id: "codex.chatgpt.browser",
        displayName: "Continue with ChatGPT",
        detail: "Sign in securely in your browser",
        ceremony: .browser
    )
    private static let deviceCodeLoginMethod = RuntimeLoginMethod(
        id: "codex.chatgpt.device-code",
        displayName: "Use a device code",
        detail: "Enter a one-time code at OpenAI",
        ceremony: .deviceCode
    )

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let client: any CodexAppServerTransport
    private let expectedCodexHomeURL: URL?
    private let modelProviderID: String?
    private let dynamicToolHandler: (any CodexDynamicToolHandler)?
    private var appServerTask: Task<Void, Never>?
    private var connectionAttempt: Task<RuntimeSession, any Error>?
    private var connectionGeneration: UInt64 = 0
    private var activeTransportGeneration: UInt64?
    private var activeTurnIDs: [String: String] = [:]
    private struct PendingTurnFailure {
        let turnID: String
        let message: String
    }

    private var pendingTurnFailuresByThreadID: [String: PendingTurnFailure] = [:]
    private var pendingUserInteractions: [RuntimeRequestID: AppServerRequest] = [:]
    private struct DynamicToolTask {
        let token: UUID
        let threadID: String?
        let task: Task<Void, Never>
    }

    private struct DynamicToolParentContext {
        var modelID: String?
        var workingDirectory: String?
    }

    private var dynamicToolTasks: [RuntimeRequestID: DynamicToolTask] = [:]
    private var dynamicToolParentContexts: [String: DynamicToolParentContext] = [:]
    /// App-server can emit `thread/started` before the matching `thread/fork`
    /// response reaches this actor. Keep every thread lifecycle notification
    /// behind this small classification barrier while an ephemeral fork is in
    /// flight, then either discard it for the returned fork ID or release it in
    /// original order for an unrelated durable task.
    private struct PendingEphemeralFork {
        let sourceThreadID: String
        var correlatedThreadIDs: Set<String> = []
    }

    private struct BufferedThreadLifecycleEvent {
        let threadID: String
        let event: AgentRuntimeEvent
    }

    private var nextEphemeralForkToken: UInt64 = 0
    private var pendingEphemeralForks: [UInt64: PendingEphemeralFork] = [:]
    /// Intentionally retained for the lifetime of this app-server connection.
    /// Ephemeral IDs must never be allowed to re-enter the durable task catalog
    /// through a late lifecycle notification after their side-chat UI closes.
    private var quarantinedEphemeralThreadIDs: Set<String> = []
    private var bufferedThreadLifecycleEvents: [BufferedThreadLifecycleEvent] = []
    private var cachedModels: [RuntimeModel] = []
    /// `account/updated` intentionally omits `requiresOpenaiAuth`; only
    /// `account/read` owns that provider-level contract. Retain the last
    /// authoritative value so a signed-in notification cannot make ChatGPT
    /// authentication look optional (or make a custom no-auth lane require it).
    private var cachedRequiresAuthentication: Bool?
    /// Older user-selected binaries can reject newer protocol methods even
    /// though the adapter knows how to call them. Remember that evidence for
    /// the life of this runtime so reconnect/account refresh does not re-offer a
    /// control that already proved unavailable.
    private var unavailableCapabilities: RuntimeCapabilities = []
    private var connected = false

    init(
        launchConfiguration: CodexRuntimeLaunchConfiguration,
        dynamicToolHandler: (any CodexDynamicToolHandler)? = nil
    ) {
        self.init(
            client: CodexAppServerClient(
                executableURL: launchConfiguration.executableURL,
                processArguments: launchConfiguration.processArguments,
                processEnvironment: launchConfiguration.processEnvironment,
                stateDirectoryPreparation: {
                    try launchConfiguration.prepareStateDirectory()
                }
            ),
            expectedCodexHomeURL: launchConfiguration.codexHomeURL,
            modelProviderID: launchConfiguration.modelProviderID,
            dynamicToolHandler: dynamicToolHandler
        )
    }

    init(
        client: any CodexAppServerTransport,
        expectedCodexHomeURL: URL? = nil,
        modelProviderID: String? = nil,
        dynamicToolHandler: (any CodexDynamicToolHandler)? = nil
    ) {
        self.client = client
        self.expectedCodexHomeURL = expectedCodexHomeURL
        self.modelProviderID = modelProviderID
        self.dynamicToolHandler = dynamicToolHandler
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        appServerTask?.cancel()
        for task in dynamicToolTasks.values {
            task.task.cancel()
        }
        eventContinuation.finish()
    }

    static func makeDefault(
        modelProvider: CodexRuntimeModelProviderBinding? = nil,
        dynamicToolHandler: (any CodexDynamicToolHandler)? = nil
    ) throws -> CodexRuntime {
        let configuration = try CodexRuntimeLaunchConfiguration.production(
            modelProvider: modelProvider
        )
        return CodexRuntime(
            launchConfiguration: configuration,
            dynamicToolHandler: dynamicToolHandler
        )
    }

    static func makeDevelopmentInstalled(
        explicitExecutableURL: URL? = nil,
        codexHomeURL: URL? = nil,
        modelProvider: CodexRuntimeModelProviderBinding? = nil,
        dynamicToolHandler: (any CodexDynamicToolHandler)? = nil
    ) throws -> CodexRuntime {
        let configuration = try CodexRuntimeLaunchConfiguration.developmentInstalled(
            explicitExecutableURL: explicitExecutableURL,
            codexHomeURL: codexHomeURL,
            modelProvider: modelProvider
        )
        return CodexRuntime(
            launchConfiguration: configuration,
            dynamicToolHandler: dynamicToolHandler
        )
    }

    func connect() async throws -> RuntimeSession {
        if connected {
            return try await sessionSnapshot()
        }
        if let connectionAttempt {
            return try await connectionAttempt.value
        }

        ensureEventPump()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        eventContinuation.yield(.connectionChanged(.connecting))
        let attempt = Task { [weak self] () throws -> RuntimeSession in
            guard let self else {
                throw AgentRuntimeError.protocolFailure("Codex runtime was released while connecting")
            }
            return try await self.establishConnection(generation: generation)
        }
        connectionAttempt = attempt
        return try await attempt.value
    }

    private func establishConnection(generation: UInt64) async throws -> RuntimeSession {
        do {
            let connection = try await client.start()
            try validateCodexHome(connection.initializeResponse)
            guard connectionGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            activeTransportGeneration = connection.generation
            let session = try await sessionSnapshot()
            guard connectionGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            connected = true
            connectionAttempt = nil
            eventContinuation.yield(.connectionChanged(.connected(session.accountLabel ?? "Codex")))
            return session
        } catch {
            guard connectionGeneration == generation else { throw error }
            connected = false
            activeTransportGeneration = nil
            cachedRequiresAuthentication = nil
            connectionAttempt = nil
            activeTurnIDs.removeAll()
            pendingTurnFailuresByThreadID.removeAll()
            pendingUserInteractions.removeAll()
            cancelDynamicToolTasks()
            resetEphemeralThreadBoundary()
            await client.stop()
            guard connectionGeneration == generation else { throw error }
            eventContinuation.yield(.connectionChanged(.failed(error.localizedDescription)))
            throw error
        }
    }

    private func validateCodexHome(_ initializeResponse: JSONValue) throws {
        guard let expectedCodexHomeURL else { return }
        guard let reportedCodexHome = initializeResponse["codexHome"]?.stringValue else {
            throw AgentRuntimeError.protocolFailure(
                "Codex app-server did not confirm Onyx's private data folder."
            )
        }
        guard Self.macOSAliasNormalizedPath(reportedCodexHome)
            == Self.macOSAliasNormalizedPath(expectedCodexHomeURL.path) else {
            throw AgentRuntimeError.protocolFailure(
                "Codex app-server refused Onyx's private data folder."
            )
        }
    }

    private static func macOSAliasNormalizedPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.path
        // `/tmp`, `/var`, and `/etc` are stable macOS aliases into `/private`.
        // Foundation does not resolve a missing descendant through those
        // aliases, which is exactly when app-server can report the canonical
        // spelling before Onyx's expected URL has been materialized.
        for alias in ["/tmp", "/var", "/etc"] {
            if standardized == alias || standardized.hasPrefix(alias + "/") {
                return "/private" + standardized
            }
        }
        return standardized
    }

    private func validateBoundProviderOwnership(
        in result: JSONValue,
        operation: String
    ) throws {
        guard let modelProviderID else { return }
        let thread = result["thread"] ?? result
        guard let returnedProviderID = thread["modelProvider"]?.stringValue,
              returnedProviderID == modelProviderID else {
            throw AgentRuntimeError.protocolFailure(
                "Codex app-server did not confirm the custom-provider task returned by \(operation)."
            )
        }
    }

    func disconnect() async {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionAttempt?.cancel()
        connectionAttempt = nil
        activeTransportGeneration = nil
        connected = false
        cachedRequiresAuthentication = nil
        activeTurnIDs.removeAll()
        pendingTurnFailuresByThreadID.removeAll()
        pendingUserInteractions.removeAll()
        cancelDynamicToolTasks()
        resetEphemeralThreadBoundary()
        await client.stop()
        guard connectionGeneration == generation else { return }
        eventContinuation.yield(.connectionChanged(.disconnected))
    }

    func startLogin(methodID: String) async throws -> RuntimeLoginStart {
        switch methodID {
        case Self.browserLoginMethod.id:
            try await startBrowserLogin()
        case Self.deviceCodeLoginMethod.id:
            try await startDeviceCodeLogin()
        default:
            throw AgentRuntimeError.unsupported("login method \(methodID)")
        }
    }

    private func startBrowserLogin() async throws -> RuntimeLoginStart {
        let result = try await client.request(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("codex"),
            ])
        )
        guard let loginID = result["loginId"]?.stringValue,
              let rawURL = result["authUrl"]?.stringValue,
              let authURL = URL(string: rawURL) else {
            throw AgentRuntimeError.missingField("account/login/start.authUrl")
        }
        return RuntimeLoginStart(
            method: Self.browserLoginMethod,
            loginID: loginID,
            authURL: authURL,
            verificationURL: nil,
            userCode: nil
        )
    }

    private func startDeviceCodeLogin() async throws -> RuntimeLoginStart {
        let result = try await client.request(
            method: "account/login/start",
            params: .object(["type": .string("chatgptDeviceCode")])
        )
        guard let loginID = result["loginId"]?.stringValue,
              let rawURL = result["verificationUrl"]?.stringValue,
              let verificationURL = URL(string: rawURL),
              let userCode = result["userCode"]?.stringValue else {
            throw AgentRuntimeError.missingField("account/login/start.deviceCode")
        }
        return RuntimeLoginStart(
            method: Self.deviceCodeLoginMethod,
            loginID: loginID,
            authURL: nil,
            verificationURL: verificationURL,
            userCode: userCode
        )
    }

    func cancelLogin(id: String) async throws {
        _ = try await client.request(
            method: "account/login/cancel",
            params: .object(["loginId": .string(id)])
        )
    }

    func logout() async throws {
        _ = try await client.request(method: "account/logout", params: .null)
    }

    func refreshAccount() async throws -> RuntimeSession {
        try await sessionSnapshot()
    }

    func listThreads(limit: Int = 100, archived: Bool = false) async throws -> [RuntimeThread] {
        guard limit > 0 else { return [] }
        return try await listThreadPage(
            limit: limit,
            archived: archived,
            cursor: nil
        ).threads
    }

    func listAllThreads(archived: Bool) async throws -> [RuntimeThread] {
        let pageSize = 100
        var cursor: String?
        var seenCursors: Set<String> = []
        var threadsByID: [String: RuntimeThread] = [:]

        repeat {
            let page = try await listThreadPage(
                limit: pageSize,
                archived: archived,
                cursor: cursor
            )
            for thread in page.threads {
                if let current = threadsByID[thread.id], current.updatedAt > thread.updatedAt {
                    continue
                }
                threadsByID[thread.id] = thread
            }
            guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else {
                cursor = nil
                break
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw AgentRuntimeError.protocolFailure(
                    "thread/list repeated a pagination cursor"
                )
            }
            cursor = nextCursor
        } while cursor != nil

        return threadsByID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func listThreadPage(
        limit: Int,
        archived: Bool,
        cursor: String?
    ) async throws -> (threads: [RuntimeThread], nextCursor: String?) {
        var params: [String: JSONValue] = [
            "limit": .integer(limit),
            "archived": .bool(archived),
            "sourceKinds": .array([.string("appServer"), .string("cli"), .string("vscode")]),
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        if let modelProviderID {
            params["modelProviders"] = .array([.string(modelProviderID)])
        }
        let result = try await client.request(
            method: "thread/list",
            params: .object(params)
        )
        let values = result["data"]?.arrayValue ?? result["threads"]?.arrayValue ?? result.arrayValue ?? []
        var threads: [RuntimeThread] = []
        for value in values where value["ephemeral"]?.boolValue != true {
            try validateBoundProviderOwnership(in: value, operation: "thread/list")
            if let thread = CodexProjection.thread(from: value) {
                threads.append(thread)
            }
        }
        threads.sort { $0.updatedAt > $1.updatedAt }
        return (threads, result["nextCursor"]?.stringValue)
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        let result = try await client.request(
            method: "thread/read",
            params: .object([
                "threadId": .string(id),
                "includeTurns": .bool(true),
            ])
        )
        try validateBoundProviderOwnership(in: result, operation: "thread/read")
        let conversation = try CodexProjection.conversation(from: result)
        rememberDynamicToolParentContext(from: conversation.thread)
        return conversation
    }

    /// Reads a recent turn page without attaching this window as the task's
    /// active writer. Ordinary sidebar navigation uses this path; reconnect
    /// and sending continue to use `thread/resume` explicitly.
    func readThread(
        id: String,
        initialHistoryPage request: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        try validateHistoryPageLimit(request.limit)
        let metadataResult = try await requestPaginatedHistory(
            method: "thread/read",
            params: .object([
                "threadId": .string(id),
                "includeTurns": .bool(false),
            ])
        )
        try validateBoundProviderOwnership(in: metadataResult, operation: "thread/read")
        var conversation = try CodexProjection.conversation(from: metadataResult)
        rememberDynamicToolParentContext(from: conversation.thread)
        let page = try await listThreadHistory(id: id, page: request)
        conversation.items = page.chronologicalItems
        return RuntimeThreadResumeResult(
            conversation: conversation,
            initialHistoryPage: page,
            turnsBackwardsCursor: metadataResult["turnsBackwardsCursor"]?.stringValue,
            itemsBackwardsCursor: metadataResult["itemsBackwardsCursor"]?.stringValue
        )
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        let result = try await client.request(
            method: "thread/resume",
            params: .object(["threadId": .string(id)])
        )
        try validateBoundProviderOwnership(in: result, operation: "thread/resume")
        let threadValue = result["thread"] ?? result
        let activeTurnID = threadValue["turns"]?.arrayValue?.last(where: { turn in
            turn["status"]?.stringValue?.lowercased() == "inprogress"
        })?["id"]?.stringValue
        if let activeTurnID {
            activeTurnIDs[id] = activeTurnID
            eventContinuation.yield(.turnStarted(threadID: id, turnID: activeTurnID))
        } else {
            activeTurnIDs.removeValue(forKey: id)
        }
        let conversation = try CodexProjection.conversation(from: result)
        rememberDynamicToolParentContext(from: conversation.thread)
        return conversation
    }

    func resumeThread(
        id: String,
        initialHistoryPage request: RuntimeInitialThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        try validateHistoryPageLimit(request.limit)
        let result = try await requestPaginatedHistory(
            method: "thread/resume",
            params: .object([
                "threadId": .string(id),
                "excludeTurns": .bool(true),
                "initialTurnsPage": .object([
                    "limit": .integer(request.limit),
                    "sortDirection": .string(codexHistoryDirection(request.direction)),
                    "itemsView": .string(try codexTurnItemDetail(request.itemDetail)),
                ]),
            ])
        )
        try validateBoundProviderOwnership(in: result, operation: "thread/resume")

        var conversation = try CodexProjection.conversation(from: result)
        rememberDynamicToolParentContext(from: conversation.thread)
        let initialHistoryPage: RuntimeThreadHistoryPage?
        if let pageValue = result["initialTurnsPage"], pageValue != .null {
            let page = try CodexProjection.historyPage(
                from: pageValue,
                direction: request.direction
            )
            initialHistoryPage = page
            conversation.items = page.chronologicalItems
            synchronizeActiveTurn(threadID: id, turns: page.turns)
        } else {
            initialHistoryPage = nil
            activeTurnIDs.removeValue(forKey: id)
        }

        return RuntimeThreadResumeResult(
            conversation: conversation,
            initialHistoryPage: initialHistoryPage,
            turnsBackwardsCursor: result["turnsBackwardsCursor"]?.stringValue,
            itemsBackwardsCursor: result["itemsBackwardsCursor"]?.stringValue
        )
    }

    func listThreadHistory(
        id: String,
        page request: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadHistoryPage {
        try validateHistoryPageLimit(request.limit)
        var params: [String: JSONValue] = [
            "threadId": .string(id),
            "limit": .integer(request.limit),
            "sortDirection": .string(codexHistoryDirection(request.direction)),
            "itemsView": .string(try codexTurnItemDetail(request.itemDetail)),
        ]
        if let cursor = request.cursor {
            params["cursor"] = .string(cursor)
        }
        let result = try await requestPaginatedHistory(
            method: "thread/turns/list",
            params: .object(params)
        )
        return try CodexProjection.historyPage(from: result, direction: request.direction)
    }

    func revertThread(id: String, beforeTurnID: String) async throws -> RuntimeThreadRevertResult {
        guard !unavailableCapabilities.contains(.threadHistoryRevert) else {
            throw AgentRuntimeError.unsupported("native history editing in this Codex version")
        }
        let result: JSONValue
        do {
            result = try await client.request(
                method: "thread/revert",
                params: .object([
                    "threadId": .string(id),
                    "beforeTurnId": .string(beforeTurnID),
                ])
            )
        } catch {
            if Self.isProtocolCompatibilityFailure(error) {
                unavailableCapabilities.insert(.threadHistoryRevert)
                throw AgentRuntimeError.unsupported("native history editing in this Codex version")
            }
            throw error
        }
        try validateBoundProviderOwnership(in: result, operation: "thread/revert")
        guard let thread = CodexProjection.thread(from: result["thread"] ?? result) else {
            throw AgentRuntimeError.missingField("thread/revert.thread.id")
        }
        activeTurnIDs.removeValue(forKey: id)
        return RuntimeThreadRevertResult(
            thread: thread,
            turnsBackwardsCursor: result["turnsBackwardsCursor"]?.stringValue,
            itemsBackwardsCursor: result["itemsBackwardsCursor"]?.stringValue
        )
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        var params: [String: JSONValue] = [
            "cwd": .string(request.cwd),
            "ephemeral": .bool(request.ephemeral),
            "serviceName": .string("onyx"),
            "sandbox": .string(codexSandboxMode(request.sandboxMode)),
            "approvalPolicy": .string(codexApprovalPolicy(request.approvalPolicy)),
        ]
        if let model = request.model { params["model"] = .string(model) }
        if let modelProviderID { params["modelProvider"] = .string(modelProviderID) }
        if let dynamicToolHandler {
            let definition = await dynamicToolHandler.dynamicToolDefinition()
            params["dynamicTools"] = .array([Self.dynamicToolSpecification(definition)])
        }
        let result = try await client.request(method: "thread/start", params: .object(params))
        try validateBoundProviderOwnership(in: result, operation: "thread/start")
        guard let thread = CodexProjection.thread(from: result["thread"] ?? result) else {
            throw AgentRuntimeError.missingField("thread.id")
        }
        if dynamicToolHandler != nil {
            dynamicToolParentContexts[thread.id] = DynamicToolParentContext(
                modelID: request.model ?? thread.model,
                workingDirectory: request.cwd
            )
        }
        return thread
    }

    func forkThread(id: String) async throws -> RuntimeThread {
        let result = try await client.request(
            method: "thread/fork",
            params: .object(["threadId": .string(id)])
        )
        try validateBoundProviderOwnership(in: result, operation: "thread/fork")
        guard let thread = CodexProjection.thread(from: result["thread"] ?? result) else {
            throw AgentRuntimeError.missingField("thread.id")
        }
        if dynamicToolHandler != nil {
            dynamicToolParentContexts[thread.id] = dynamicToolParentContexts[id]
                ?? DynamicToolParentContext(
                    modelID: thread.model,
                    workingDirectory: thread.cwd
                )
        }
        return thread
    }

    func forkEphemeralThread(id: String) async throws -> RuntimeConversation {
        // `ThreadForkParams.ephemeral` is part of the installed app-server's
        // generated v2 schema. Ephemeral forks use the paginated fork shape,
        // which requires `excludeTurns: true`; the response therefore carries
        // metadata/live state but no `thread.turns`. The app-owned side-chat
        // UI keeps its parent snapshot as the visible inherited context. The
        // app-server intentionally does not allow `thread/turns/list` for an
        // ephemeral thread, so do not issue a follow-up history request here.
        nextEphemeralForkToken &+= 1
        let token = nextEphemeralForkToken
        pendingEphemeralForks[token] = PendingEphemeralFork(sourceThreadID: id)

        let result: JSONValue
        do {
            result = try await client.request(
                method: "thread/fork",
                params: .object([
                    "threadId": .string(id),
                    "ephemeral": .bool(true),
                    "excludeTurns": .bool(true),
                ])
            )
        } catch {
            let correlatedIDs = pendingEphemeralForks[token]?.correlatedThreadIDs ?? []
            quarantineEphemeralThreads(correlatedIDs)
            await deleteThreadsBestEffort(correlatedIDs)
            finishEphemeralFork(token)
            throw error
        }

        let threadValue = result["thread"] ?? result
        do {
            try validateBoundProviderOwnership(in: result, operation: "thread/fork")
        } catch {
            var correlatedIDs = pendingEphemeralForks[token]?.correlatedThreadIDs ?? []
            if let returnedThreadID = threadValue["id"]?.stringValue {
                correlatedIDs.insert(returnedThreadID)
            }
            quarantineEphemeralThreads(correlatedIDs)
            await deleteThreadsBestEffort(correlatedIDs)
            finishEphemeralFork(token)
            throw error
        }
        guard let threadID = threadValue["id"]?.stringValue else {
            let correlatedIDs = pendingEphemeralForks[token]?.correlatedThreadIDs ?? []
            quarantineEphemeralThreads(correlatedIDs)
            await deleteThreadsBestEffort(correlatedIDs)
            finishEphemeralFork(token)
            throw AgentRuntimeError.missingField("thread.id")
        }

        let wasCorrelatedBeforeResponse = pendingEphemeralForks[token]?
            .correlatedThreadIDs.contains(threadID) == true
        if !wasCorrelatedBeforeResponse {
            // A `thread/started` event can arrive without lineage or an
            // ephemeral flag. The fork response is the authoritative join key;
            // drop that provisional catalog update once its ID is known.
            bufferedThreadLifecycleEvents.removeAll { entry in
                guard entry.threadID == threadID else { return false }
                guard case .threadUpdated = entry.event else { return false }
                return true
            }
        }
        pendingEphemeralForks[token]?.correlatedThreadIDs.insert(threadID)
        let correlatedIDs = pendingEphemeralForks[token]?.correlatedThreadIDs ?? []
        quarantineEphemeralThreads(correlatedIDs.union([threadID]))

        guard threadValue["ephemeral"]?.boolValue == true else {
            var cleanupFailure: (any Error)?
            do {
                _ = try await client.request(
                    method: "thread/delete",
                    params: .object(["threadId": .string(threadID)])
                )
            } catch {
                cleanupFailure = error
            }
            finishEphemeralFork(token)

            var detail = "Codex app-server returned thread \(threadID) without explicit ephemeral confirmation. Onyx rejected the side chat and requested deletion of the accidental durable fork."
            if let cleanupFailure {
                detail += " Cleanup also failed: \(cleanupFailure.localizedDescription)"
            }
            throw AgentRuntimeError.protocolFailure(detail)
        }

        do {
            let conversation = try CodexProjection.conversation(from: result)
            if dynamicToolHandler != nil {
                dynamicToolParentContexts[threadID] = dynamicToolParentContexts[id]
                    ?? DynamicToolParentContext(
                        modelID: conversation.thread.model,
                        workingDirectory: conversation.thread.cwd
                    )
            }
            finishEphemeralFork(token)
            return conversation
        } catch {
            // A malformed response can still identify a newly created thread.
            // Keep it quarantined and remove it rather than allowing a partial
            // projection to leave an invisible provider-side fork behind.
            await deleteThreadsBestEffort(Set([threadID]))
            finishEphemeralFork(token)
            throw error
        }
    }

    func compactThread(id: String) async throws {
        _ = try await client.request(
            method: "thread/compact/start",
            params: .object(["threadId": .string(id)])
        )
    }

    func deleteThread(id: String) async throws {
        _ = try await client.request(
            method: "thread/delete",
            params: .object(["threadId": .string(id)])
        )
        dynamicToolParentContexts.removeValue(forKey: id)
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        try Task.checkCancellation()
        var params: [String: JSONValue] = [
            "threadId": .string(request.threadID),
            "input": .array(request.inputs.map(codexTurnInput)),
        ]
        if let model = request.model { params["model"] = .string(model) }
        if let cwd = request.cwd { params["cwd"] = .string(cwd) }
        if let reasoningEffort = request.reasoningEffort { params["effort"] = .string(reasoningEffort) }
        if dynamicToolParentContexts[request.threadID] != nil {
            if let model = request.model {
                dynamicToolParentContexts[request.threadID]?.modelID = model
            }
            if let cwd = request.cwd {
                dynamicToolParentContexts[request.threadID]?.workingDirectory = cwd
            }
        }
        params["approvalPolicy"] = .string(codexApprovalPolicy(request.approvalPolicy))
        params["sandboxPolicy"] = codexSandboxPolicy(request.sandboxMode, cwd: request.cwd)
        let result = try await client.request(method: "turn/start", params: .object(params))
        if let turnID = result["turn"]?["id"]?.stringValue {
            activeTurnIDs[request.threadID] = turnID
        }
        guard !Task.isCancelled else {
            // Closing a side chat cancels the task that submitted its turn. The
            // app-server request itself may already have crossed the process
            // boundary, so cancellation alone cannot guarantee that no work is
            // running. Once the response exposes the turn ID, interrupt that
            // accepted work before reporting cancellation to the caller.
            let turnID = result["turn"]?["id"]?.stringValue
                ?? activeTurnIDs[request.threadID]
            if let turnID {
                do {
                    try await interruptAcceptedTurn(threadID: request.threadID, turnID: turnID)
                } catch {
                    throw AgentRuntimeError.protocolFailure(
                        "The turn was accepted after its caller cancelled, and cleanup failed: \(error.localizedDescription)"
                    )
                }
            } else {
                throw AgentRuntimeError.protocolFailure(
                    "The turn was accepted after its caller cancelled, but app-server returned no turn ID for cleanup."
                )
            }
            throw CancellationError()
        }
    }

    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun {
        // `thread/read` is deliberately read-only. Acquire this app-server's
        // writer before starting the non-steerable review turn, matching the
        // preparation used for an ordinary turn on an existing task.
        _ = try await client.request(
            method: "thread/resume",
            params: .object(["threadId": .string(request.threadID)])
        )
        let target: JSONValue = switch request.target {
        case .uncommittedChanges:
            .object(["type": .string("uncommittedChanges")])
        }
        let delivery: String = switch request.delivery {
        case .inline: "inline"
        case .detached: "detached"
        }
        let result = try await client.request(
            method: "review/start",
            params: .object([
                "threadId": .string(request.threadID),
                "delivery": .string(delivery),
                "target": target,
            ])
        )
        guard let reviewThreadID = result["reviewThreadId"]?.stringValue else {
            throw AgentRuntimeError.missingField("review/start.reviewThreadId")
        }
        guard let turnID = result["turn"]?["id"]?.stringValue else {
            throw AgentRuntimeError.missingField("review/start.turn.id")
        }
        activeTurnIDs[reviewThreadID] = turnID
        if request.delivery == .inline {
            activeTurnIDs[request.threadID] = turnID
        }
        return RuntimeReviewRun(threadID: reviewThreadID, turnID: turnID)
    }

    func steer(threadID: String, text: String) async throws {
        try await steer(threadID: threadID, inputs: [.text(text)])
    }

    func steer(threadID: String, inputs: [RuntimeTurnInput]) async throws {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(inputs.map(codexTurnInput)),
        ]
        guard let turnID = activeTurnIDs[threadID] else {
            throw AgentRuntimeError.protocolFailure("No active turn is available to steer")
        }
        params["expectedTurnId"] = .string(turnID)
        _ = try await client.request(method: "turn/steer", params: .object(params))
    }

    private func codexTurnInput(_ input: RuntimeTurnInput) -> JSONValue {
        switch input {
        case let .text(text):
            .object(["type": .string("text"), "text": .string(text)])
        case let .localImagePath(path):
            .object(["type": .string("localImage"), "path": .string(path)])
        case let .imageURL(url):
            .object(["type": .string("image"), "url": .string(url)])
        }
    }

    func interrupt(threadID: String) async throws {
        guard let turnID = activeTurnIDs[threadID] else {
            throw AgentRuntimeError.protocolFailure("No active turn is available to interrupt")
        }
        let params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "turnId": .string(turnID),
        ]
        // The parent interrupt is still attempted first so a local cancellation
        // cannot leave Codex running after Onyx reports a failed stop. The
        // delegated child must nevertheless be cancelled when that request
        // throws; otherwise it can continue for the full provider timeout.
        defer { cancelDynamicToolTasks(threadID: threadID) }
        _ = try await client.request(method: "turn/interrupt", params: .object(params))
    }

    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {
        guard let request = pendingUserInteractions[interactionID] else {
            throw AgentRuntimeError.protocolFailure("This interaction is no longer pending")
        }
        let result = try codexInteractionResponse(response, for: request)
        try await client.respond(id: interactionID, result: result)
        pendingUserInteractions.removeValue(forKey: interactionID)
    }

    func renameThread(id: String, name: String) async throws {
        _ = try await client.request(
            method: "thread/name/set",
            params: .object([
                "threadId": .string(id),
                "name": .string(name),
            ])
        )
    }

    func archiveThread(id: String) async throws {
        _ = try await client.request(
            method: "thread/archive",
            params: .object(["threadId": .string(id)])
        )
    }

    func unarchiveThread(id: String) async throws {
        _ = try await client.request(
            method: "thread/unarchive",
            params: .object(["threadId": .string(id)])
        )
    }

    private func sessionSnapshot() async throws -> RuntimeSession {
        async let accountResult = client.request(
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )
        async let modelResult = client.request(
            method: "model/list",
            params: .object(["limit": .integer(100)])
        )

        let account = try await accountResult
        let models = try? await modelResult
        let accountValue = account["account"]
        let requiresAuthentication = account["requiresOpenaiAuth"]?.boolValue ?? true
        cachedRequiresAuthentication = requiresAuthentication
        let auth = authState(from: accountValue, requiresAuthentication: requiresAuthentication)
        let projectedModels = (models?["data"]?.arrayValue ?? models?["models"]?.arrayValue ?? []).compactMap { value -> RuntimeModel? in
            guard let id = value["id"]?.stringValue ?? value["model"]?.stringValue else { return nil }
            let efforts = value["supportedReasoningEfforts"]?.arrayValue?.compactMap { option in
                option.stringValue ?? option["reasoningEffort"]?.stringValue
            }
                ?? value["reasoningEfforts"]?.arrayValue?.compactMap(\.stringValue)
                ?? []
            return RuntimeModel(
                id: id,
                displayName: value["displayName"]?.stringValue ?? value["name"]?.stringValue ?? id,
                description: value["description"]?.stringValue,
                isDefault: value["isDefault"]?.boolValue ?? false,
                defaultReasoningEffort: value["defaultReasoningEffort"]?.stringValue,
                reasoningEfforts: efforts
            )
        }
        if models != nil { cachedModels = projectedModels }
        let availableModels = models == nil ? cachedModels : projectedModels

        var capabilities: RuntimeCapabilities = [
            .streaming, .steering, .interruption, .approvals, .threadForking,
            .threadArchiving, .threadCompaction, .threadDeletion, .reasoning,
            .tools, .diffs, .codeReview, .terminal, .images, .usage,
            .ephemeralThreadForking, .threadHistoryPagination, .threadHistoryRevert,
        ]
        capabilities.subtract(unavailableCapabilities)

        return RuntimeSession(
            runtime: .codex,
            displayName: "Codex app-server",
            accountLabel: auth.email ?? auth.mode?.displayName,
            planLabel: auth.planLabel,
            auth: auth,
            availableLoginMethods: [Self.browserLoginMethod, Self.deviceCodeLoginMethod],
            availableModels: availableModels,
            capabilities: capabilities
        )
    }

    private static func isProtocolCompatibilityFailure(_ error: any Error) -> Bool {
        guard let runtimeError = error as? AgentRuntimeError,
              case let .requestFailed(code, _) = runtimeError else { return false }
        return code == -32_601 || code == -32_602
    }

    /// A user-selected older app-server can reject any one of the pagination
    /// entry points. One such protocol response proves the whole cursor
    /// capability unavailable for this runtime and prevents repeated retries
    /// through read, resume, or older-page loading.
    private func requestPaginatedHistory(
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        guard !unavailableCapabilities.contains(.threadHistoryPagination) else {
            throw AgentRuntimeError.unsupported("paginated thread history in this Codex version")
        }
        do {
            return try await client.request(method: method, params: params)
        } catch {
            if Self.isProtocolCompatibilityFailure(error) {
                unavailableCapabilities.insert(.threadHistoryPagination)
            }
            throw error
        }
    }

    private func authState(from account: JSONValue?, requiresAuthentication: Bool) -> RuntimeAuthState {
        guard let account, account != .null else {
            return RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: requiresAuthentication
            )
        }

        let rawType = account["type"]?.stringValue
        let mode: RuntimeAuthMode? = switch rawType {
        case "apiKey": .apiKey
        case "chatgpt": .chatgpt
        case "amazonBedrock": .bedrockApiKey
        default: RuntimeAuthMode.from(raw: rawType)
        }
        return RuntimeAuthState(
            mode: mode,
            email: account["email"]?.stringValue,
            planLabel: account["planType"]?.stringValue,
            requiresAuthentication: requiresAuthentication
        )
    }

    private func handle(_ event: AppServerEvent) async {
        switch event {
        case let .notification(generation, notification):
            guard generation == activeTransportGeneration else { return }
            handle(notification)
        case let .request(generation, request):
            guard generation == activeTransportGeneration else { return }
            if let interaction = CodexProjection.userInteraction(from: request) {
                pendingUserInteractions[request.id] = request
                eventContinuation.yield(.userInteractionRequested(interaction))
            } else if request.method == "item/tool/call",
                      request.params["tool"]?.stringValue == Self.delegationToolName,
                      dynamicToolHandler != nil {
                handleDynamicToolCall(request, generation: generation)
            } else {
                await rejectUnsupportedServerRequest(request)
            }
        case let .stderr(generation, message):
            guard generation == activeTransportGeneration else { return }
            if message.localizedCaseInsensitiveContains("error") {
                eventContinuation.yield(.runtimeNotice(title: "Codex runtime", detail: message))
            }
        case let .stopped(generation, reason):
            guard generation == activeTransportGeneration else { return }
            connectionGeneration &+= 1
            connectionAttempt?.cancel()
            connectionAttempt = nil
            connected = false
            activeTransportGeneration = nil
            cachedRequiresAuthentication = nil
            activeTurnIDs.removeAll()
            pendingTurnFailuresByThreadID.removeAll()
            pendingUserInteractions.removeAll()
            cancelDynamicToolTasks()
            resetEphemeralThreadBoundary()
            eventContinuation.yield(.connectionChanged(.failed(reason)))
        }
    }

    private func ensureEventPump() {
        guard appServerTask == nil else { return }
        appServerTask = Task { [weak self, appServerEvents = client.events] in
            for await event in appServerEvents {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
            await self?.eventPumpFinished()
        }
    }

    private func eventPumpFinished() {
        appServerTask = nil
    }

    private func handle(_ notification: AppServerNotification) {
        let params = notification.params
        let threadID = params["threadId"]?.stringValue ?? params["thread"]?["id"]?.stringValue ?? ""

        switch notification.method {
        case "account/updated":
            let authMode = params["authMode"]?.stringValue.map(RuntimeAuthMode.from(raw:))
            let auth = RuntimeAuthState(
                mode: authMode,
                email: nil,
                planLabel: params["planType"]?.stringValue,
                requiresAuthentication: cachedRequiresAuthentication ?? true
            )
            eventContinuation.yield(.accountUpdated(auth))
            return
        case "account/login/completed":
            eventContinuation.yield(
                .loginCompleted(
                    RuntimeLoginCompletion(
                        loginID: params["loginId"]?.stringValue,
                        success: params["success"]?.boolValue ?? false,
                        error: params["error"]?.stringValue
                    )
                )
            )
            return
        default:
            break
        }

        if let lifecycleEvent = CodexProjection.threadLifecycleEvent(from: notification) {
            if case let .threadDeleted(threadID) = lifecycleEvent {
                activeTurnIDs.removeValue(forKey: threadID)
                pendingTurnFailuresByThreadID.removeValue(forKey: threadID)
                dynamicToolParentContexts.removeValue(forKey: threadID)
            }
            publishOrBufferThreadLifecycleEvent(lifecycleEvent, threadID: threadID)
            return
        }

        switch notification.method {
        case "thread/started":
            let threadValue = params["thread"] ?? params
            guard let startedThreadID = threadValue["id"]?.stringValue else { return }
            let isExplicitlyEphemeral = threadValue["ephemeral"]?.boolValue == true
            if isExplicitlyEphemeral {
                quarantinedEphemeralThreadIDs.insert(startedThreadID)
            }
            correlateStartedThread(
                startedThreadID,
                forkedFromID: threadValue["forkedFromId"]?.stringValue,
                isExplicitlyEphemeral: isExplicitlyEphemeral
            )
            guard let thread = CodexProjection.thread(from: threadValue) else { return }
            publishOrBufferThreadLifecycleEvent(.threadUpdated(thread), threadID: startedThreadID)
        case "turn/started":
            if let turnID = params["turn"]?["id"]?.stringValue, !threadID.isEmpty {
                pendingTurnFailuresByThreadID.removeValue(forKey: threadID)
                activeTurnIDs[threadID] = turnID
                eventContinuation.yield(.turnStarted(threadID: threadID, turnID: turnID))
            }
        case "item/started":
            guard !threadID.isEmpty, let item = params["item"] else { return }
            eventContinuation.yield(
                .itemStarted(
                    threadID: threadID,
                    item: CodexProjection.timelineItem(from: item, defaultStatus: .running)
                )
            )
        case "item/completed":
            guard !threadID.isEmpty, let item = params["item"] else { return }
            eventContinuation.yield(.itemCompleted(threadID: threadID, item: CodexProjection.timelineItem(from: item)))
        case "turn/plan/updated":
            guard !threadID.isEmpty,
                  let plan = CodexProjection.plan(from: params),
                  activeTurnIDs[threadID] == plan.turnID else { return }
            eventContinuation.yield(.planUpdated(threadID: threadID, plan: plan))
        case "item/agentMessage/delta",
             "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta",
             "item/commandExecution/outputDelta":
            guard !threadID.isEmpty,
                  let itemID = params["itemId"]?.stringValue,
                  let delta = params["delta"]?.stringValue else { return }
            eventContinuation.yield(.itemDelta(threadID: threadID, itemID: itemID, delta: delta))
        case "turn/completed":
            let turn = params["turn"] ?? .null
            let turnID = turn["id"]?.stringValue ?? activeTurnIDs[threadID]
            let pendingFailure = pendingTurnFailuresByThreadID.removeValue(forKey: threadID)
            activeTurnIDs.removeValue(forKey: threadID)
            cancelDynamicToolTasks(threadID: threadID)
            let rawStatus = turn["status"]?.stringValue ?? "idle"
            let status: RuntimeThreadStatus = rawStatus == "failed" ? .failed : .idle
            let fallbackMessage: String? = if rawStatus == "failed",
                                              pendingFailure?.turnID == turnID {
                pendingFailure?.message
            } else {
                nil
            }
            if !threadID.isEmpty,
               let failure = CodexProjection.turnFailureTimelineItem(
                   from: turn,
                   fallbackTurnID: turnID,
                   fallbackMessage: fallbackMessage
               ) {
                eventContinuation.yield(.itemCompleted(threadID: threadID, item: failure))
            }
            eventContinuation.yield(.turnCompleted(threadID: threadID, status: status))
        case "serverRequest/resolved":
            if let requestID = runtimeRequestID(from: params["requestId"]) {
                pendingUserInteractions.removeValue(forKey: requestID)
                eventContinuation.yield(.userInteractionResolved(requestID))
            }
        case "error":
            let detail = CodexProjection.turnFailureMessage(from: params)
            if !threadID.isEmpty,
               let turnID = params["turnId"]?.stringValue ?? activeTurnIDs[threadID],
               let detail {
                if params["willRetry"]?.boolValue != true,
                   activeTurnIDs[threadID] == turnID {
                    pendingTurnFailuresByThreadID[threadID] = PendingTurnFailure(
                        turnID: turnID,
                        message: detail
                    )
                }
                // Turn failures are represented by the stable transcript row
                // emitted with `turn/completed`; do not also interrupt the user
                // with a modal notice for this same provider-owned failure.
                return
            }
            eventContinuation.yield(
                .runtimeNotice(
                    title: "Codex runtime error",
                    detail: detail ?? "Codex reported an error."
                )
            )
        default:
            break
        }
    }

    private func correlateStartedThread(
        _ threadID: String,
        forkedFromID: String?,
        isExplicitlyEphemeral: Bool
    ) {
        guard !pendingEphemeralForks.isEmpty else { return }

        if let forkedFromID {
            let matchingTokens = pendingEphemeralForks.compactMap { token, pending in
                pending.sourceThreadID == forkedFromID ? token : nil
            }
            guard matchingTokens.count == 1, let token = matchingTokens.first else { return }
            pendingEphemeralForks[token]?.correlatedThreadIDs.insert(threadID)
            return
        }

        // Older app-server builds can omit lineage from `thread/started`. An
        // explicitly ephemeral start is still safe to correlate when only one
        // ephemeral fork request is outstanding. Unknown/non-ephemeral starts
        // remain buffered until the response supplies a definitive thread ID.
        guard isExplicitlyEphemeral,
              pendingEphemeralForks.count == 1,
              let token = pendingEphemeralForks.keys.first else { return }
        pendingEphemeralForks[token]?.correlatedThreadIDs.insert(threadID)
    }

    private func publishOrBufferThreadLifecycleEvent(
        _ event: AgentRuntimeEvent,
        threadID: String
    ) {
        guard !quarantinedEphemeralThreadIDs.contains(threadID) else { return }
        guard !pendingEphemeralForks.isEmpty else {
            eventContinuation.yield(event)
            return
        }
        bufferedThreadLifecycleEvents.append(
            BufferedThreadLifecycleEvent(threadID: threadID, event: event)
        )
    }

    private func quarantineEphemeralThreads(_ threadIDs: Set<String>) {
        guard !threadIDs.isEmpty else { return }
        quarantinedEphemeralThreadIDs.formUnion(threadIDs)
        bufferedThreadLifecycleEvents.removeAll { threadIDs.contains($0.threadID) }
    }

    private func finishEphemeralFork(_ token: UInt64) {
        let pending = pendingEphemeralForks.removeValue(forKey: token)
        if let pending {
            quarantineEphemeralThreads(pending.correlatedThreadIDs)
        }
        guard pendingEphemeralForks.isEmpty else { return }

        let buffered = bufferedThreadLifecycleEvents
        bufferedThreadLifecycleEvents.removeAll(keepingCapacity: true)
        for entry in buffered where !quarantinedEphemeralThreadIDs.contains(entry.threadID) {
            eventContinuation.yield(entry.event)
        }
    }

    private func deleteThreadsBestEffort(_ threadIDs: Set<String>) async {
        for threadID in threadIDs {
            try? await deleteThread(id: threadID)
        }
    }

    private func resetEphemeralThreadBoundary() {
        pendingEphemeralForks.removeAll()
        quarantinedEphemeralThreadIDs.removeAll()
        bufferedThreadLifecycleEvents.removeAll()
    }

    private func interruptAcceptedTurn(threadID: String, turnID: String) async throws {
        _ = try await client.request(
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        activeTurnIDs.removeValue(forKey: threadID)
    }

    private func codexInteractionResponse(
        _ response: RuntimeUserInteractionResponse,
        for request: AppServerRequest
    ) throws -> JSONValue {
        switch (request.method, response) {
        case ("item/commandExecution/requestApproval", let .approval(decision)),
             ("item/fileChange/requestApproval", let .approval(decision)):
            return .object(["decision": .string(decision.rawValue)])

        case ("item/permissions/requestApproval", let .approval(decision)):
            let permissions: JSONValue = switch decision {
            case .accept, .acceptForSession:
                request.params["permissions"] ?? .object([:])
            case .decline, .cancel:
                .object([:])
            }
            return .object([
                "permissions": permissions,
                "scope": .string(decision == .acceptForSession ? "session" : "turn"),
            ])

        case ("item/tool/requestUserInput", let .answers(answers)):
            let wireAnswers = answers.mapValues { values in
                JSONValue.object(["answers": .strings(values)])
            }
            return .object(["answers": .object(wireAnswers)])

        case ("mcpServer/elicitation/request", let .form(action, values)):
            var result: [String: JSONValue] = [
                "action": .string(action.rawValue),
                "content": action == .accept
                    ? .object(values.mapValues(codexFormValue(from:)))
                    : .null,
            ]
            copyObjectMetadata(from: request, into: &result)
            return .object(result)

        case ("mcpServer/elicitation/request", let .externalLink(action)):
            var result: [String: JSONValue] = [
                "action": .string(action.rawValue),
                "content": action == .accept ? .object([:]) : .null,
            ]
            copyObjectMetadata(from: request, into: &result)
            return .object(result)

        case ("execCommandApproval", let .approval(decision)),
             ("applyPatchApproval", let .approval(decision)):
            let legacyDecision: JSONValue = switch decision {
            case .accept:
                .string("approved")
            case .acceptForSession:
                .string("approved_for_session")
            case .decline:
                .object([
                    "denied": .object([
                        "rejection": .string("User declined the request."),
                    ]),
                ])
            case .cancel:
                .string("abort")
            }
            return .object(["decision": legacyDecision])

        default:
            throw AgentRuntimeError.protocolFailure(
                "Response type does not match \(request.method)"
            )
        }
    }

    private func copyObjectMetadata(
        from request: AppServerRequest,
        into result: inout [String: JSONValue]
    ) {
        guard case let .object(metadata)? = request.params["_meta"] else { return }
        result["_meta"] = .object(metadata)
    }

    private func codexFormValue(from value: RuntimeFormValue) -> JSONValue {
        switch value {
        case let .string(value): .string(value)
        case let .number(value): .number(value)
        case let .integer(value): .integer(value)
        case let .boolean(value): .bool(value)
        case let .strings(values): .strings(values)
        }
    }

    private func rejectUnsupportedServerRequest(_ request: AppServerRequest) async {
        let detail = "Onyx does not support the app-server request \(request.method)."
        do {
            if request.method == "item/tool/call" {
                try await client.respond(
                    id: request.id,
                    result: .object([
                        "contentItems": .array([
                            .object([
                                "type": .string("inputText"),
                                "text": .string(detail),
                            ]),
                        ]),
                        "success": .bool(false),
                    ])
                )
            } else {
                try await client.respondError(id: request.id, code: -32601, message: detail)
            }
        } catch {
            eventContinuation.yield(
                .runtimeNotice(
                    title: "Codex requested an unsupported capability",
                    detail: "\(detail) \(error.localizedDescription)"
                )
            )
            return
        }
        eventContinuation.yield(
            .runtimeNotice(
                title: "Codex requested an unsupported capability",
                detail: detail
            )
        )
    }

    private static let delegationToolName = "onyx_delegate"

    private static func dynamicToolSpecification(
        _ definition: CodexDynamicToolDefinition
    ) -> JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(delegationToolName),
            "description": .string(definition.description),
            "inputSchema": definition.inputSchema,
        ])
    }

    private func handleDynamicToolCall(
        _ request: AppServerRequest,
        generation: UInt64
    ) {
        guard let dynamicToolHandler else { return }
        // DynamicToolCallRequest supplies the owning turn, not a thread id.
        // Resolve that turn through state captured from turn/start or
        // turn/started so model-authored input cannot choose another parent.
        guard let turnID = request.params["turnId"]?.stringValue,
              !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let threadID = activeTurnIDs.first(where: { $0.value == turnID })?.key,
              let callID = request.params["callId"]?.stringValue,
              !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let arguments = request.params["arguments"],
              arguments.objectValue != nil else {
            startDynamicToolResponseTask(
                requestID: request.id,
                generation: generation,
                threadID: nil,
                operation: {
                    .failed("The onyx_delegate request is missing a valid turnId, callId, or arguments object.")
                }
            )
            return
        }

        let parentContext = dynamicToolParentContexts[threadID]
        let call = CodexDynamicToolCall(
            threadID: threadID,
            callID: callID,
            arguments: arguments,
            parentModelID: parentContext?.modelID ?? "codex",
            workingDirectory: parentContext?.workingDirectory
        )
        startDynamicToolResponseTask(
            requestID: request.id,
            generation: generation,
            threadID: threadID,
            operation: {
                do {
                    return try await dynamicToolHandler.handleDynamicToolCall(call)
                } catch {
                    // Handler errors can contain provider endpoints or request
                    // details. Keep the app-server response deliberately
                    // generic; the handler can return an explicit sanitized
                    // failure result when it has safe user-facing context.
                    return .failed("Onyx could not complete this delegation.")
                }
            }
        )
    }

    private func startDynamicToolResponseTask(
        requestID: RuntimeRequestID,
        generation: UInt64,
        threadID: String?,
        operation: @escaping @Sendable () async -> CodexDynamicToolResult
    ) {
        dynamicToolTasks[requestID]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            let result = await operation()
            guard !Task.isCancelled else { return }
            await self?.completeDynamicToolCall(
                requestID: requestID,
                generation: generation,
                token: token,
                result: result
            )
        }
        dynamicToolTasks[requestID] = DynamicToolTask(
            token: token,
            threadID: threadID,
            task: task
        )
    }

    private func completeDynamicToolCall(
        requestID: RuntimeRequestID,
        generation: UInt64,
        token: UUID,
        result: CodexDynamicToolResult
    ) async {
        guard dynamicToolTasks[requestID]?.token == token else { return }
        dynamicToolTasks.removeValue(forKey: requestID)
        guard generation == activeTransportGeneration else { return }

        do {
            try await client.respond(
                id: requestID,
                result: .object([
                    "contentItems": .array([
                        .object([
                            "type": .string("inputText"),
                            "text": .string(result.text),
                        ]),
                    ]),
                    "success": .bool(result.success),
                ])
            )
        } catch {
            guard generation == activeTransportGeneration else { return }
            eventContinuation.yield(
                .runtimeNotice(
                    title: "Codex delegation response failed",
                    detail: "Onyx could not return the delegation result to Codex."
                )
            )
        }
    }

    private func cancelDynamicToolTasks() {
        let tasks = dynamicToolTasks.values.map(\.task)
        dynamicToolTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    private func cancelDynamicToolTasks(threadID: String) {
        let requestIDs = dynamicToolTasks.compactMap { requestID, entry in
            entry.threadID == threadID ? requestID : nil
        }
        let tasks = requestIDs.compactMap { dynamicToolTasks.removeValue(forKey: $0)?.task }
        for task in tasks { task.cancel() }
    }

    private func rememberDynamicToolParentContext(from thread: RuntimeThread) {
        guard dynamicToolHandler != nil else { return }
        dynamicToolParentContexts[thread.id] = DynamicToolParentContext(
            modelID: thread.model,
            workingDirectory: thread.cwd
        )
    }

    private func runtimeRequestID(from value: JSONValue?) -> RuntimeRequestID? {
        guard let value else { return nil }
        switch value {
        case let .integer(id): return .integer(id)
        case let .string(id): return .string(id)
        default: return nil
        }
    }

    private func codexSandboxMode(_ mode: RuntimeSandboxMode) -> String {
        switch mode {
        case .readOnly: "read-only"
        case .workspaceWrite: "workspace-write"
        case .fullAccess: "danger-full-access"
        }
    }

    private func validateHistoryPageLimit(_ limit: Int) throws {
        guard limit > 0 else {
            throw AgentRuntimeError.protocolFailure("Thread history page limit must be greater than zero")
        }
    }

    private func codexHistoryDirection(_ direction: RuntimeHistoryDirection) -> String {
        switch direction {
        case .ascending: "asc"
        case .descending: "desc"
        }
    }

    private func codexTurnItemDetail(_ detail: RuntimeTurnItemDetail) throws -> String {
        switch detail {
        case .notLoaded: "notLoaded"
        case .summary: "summary"
        case .full: "full"
        case let .unknown(value):
            throw AgentRuntimeError.unsupported("thread history item detail \(value)")
        }
    }

    private func synchronizeActiveTurn(threadID: String, turns: [RuntimeConversationTurn]) {
        if let activeTurnID = turns.first(where: { $0.status == .inProgress })?.id {
            activeTurnIDs[threadID] = activeTurnID
            eventContinuation.yield(.turnStarted(threadID: threadID, turnID: activeTurnID))
        } else {
            activeTurnIDs.removeValue(forKey: threadID)
        }
    }

    private func codexSandboxPolicy(_ mode: RuntimeSandboxMode, cwd: String?) -> JSONValue {
        switch mode {
        case .readOnly:
            .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false),
            ])
        case .workspaceWrite:
            .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array(cwd.map { [.string($0)] } ?? []),
                "networkAccess": .bool(false),
            ])
        case .fullAccess:
            .object(["type": .string("dangerFullAccess")])
        }
    }

    private func codexApprovalPolicy(_ policy: RuntimeApprovalPolicy) -> String {
        switch policy {
        case .untrusted: "untrusted"
        case .onRequest: "on-request"
        case .never: "never"
        }
    }
}
