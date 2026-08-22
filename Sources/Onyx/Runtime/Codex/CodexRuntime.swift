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
    private var appServerTask: Task<Void, Never>?
    private var connectionAttempt: Task<RuntimeSession, any Error>?
    private var connectionGeneration: UInt64 = 0
    private var activeTransportGeneration: UInt64?
    private var activeTurnIDs: [String: String] = [:]
    private var pendingUserInteractions: [RuntimeRequestID: AppServerRequest] = [:]
    private var cachedModels: [RuntimeModel] = []
    private var connected = false

    init(executableURL: URL) {
        self.init(client: CodexAppServerClient(executableURL: executableURL))
    }

    init(client: any CodexAppServerTransport) {
        self.client = client
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        appServerTask?.cancel()
        eventContinuation.finish()
    }

    static func makeDefault() throws -> CodexRuntime {
        guard let url = resolveExecutable() else {
            throw AgentRuntimeError.executableNotFound
        }
        return CodexRuntime(executableURL: url)
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
            connectionAttempt = nil
            activeTurnIDs.removeAll()
            pendingUserInteractions.removeAll()
            await client.stop()
            guard connectionGeneration == generation else { throw error }
            eventContinuation.yield(.connectionChanged(.failed(error.localizedDescription)))
            throw error
        }
    }

    func disconnect() async {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionAttempt?.cancel()
        connectionAttempt = nil
        activeTransportGeneration = nil
        connected = false
        activeTurnIDs.removeAll()
        pendingUserInteractions.removeAll()
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
        let result = try await client.request(
            method: "thread/list",
            params: .object([
                "limit": .integer(limit),
                "archived": .bool(archived),
                "sourceKinds": .array([.string("appServer"), .string("cli"), .string("vscode")]),
            ])
        )
        let values = result["data"]?.arrayValue ?? result["threads"]?.arrayValue ?? result.arrayValue ?? []
        return values.compactMap(CodexProjection.thread(from:)).sorted { $0.updatedAt > $1.updatedAt }
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        let result = try await client.request(
            method: "thread/read",
            params: .object([
                "threadId": .string(id),
                "includeTurns": .bool(true),
            ])
        )
        return try CodexProjection.conversation(from: result)
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        let result = try await client.request(
            method: "thread/resume",
            params: .object(["threadId": .string(id)])
        )
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
        return try CodexProjection.conversation(from: result)
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
        let result = try await client.request(method: "thread/start", params: .object(params))
        guard let thread = CodexProjection.thread(from: result["thread"] ?? result) else {
            throw AgentRuntimeError.missingField("thread.id")
        }
        return thread
    }

    func forkThread(id: String) async throws -> RuntimeThread {
        let result = try await client.request(
            method: "thread/fork",
            params: .object(["threadId": .string(id)])
        )
        guard let thread = CodexProjection.thread(from: result["thread"] ?? result) else {
            throw AgentRuntimeError.missingField("thread.id")
        }
        return thread
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
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        var params: [String: JSONValue] = [
            "threadId": .string(request.threadID),
            "input": .array(request.inputs.map(codexTurnInput)),
        ]
        if let model = request.model { params["model"] = .string(model) }
        if let cwd = request.cwd { params["cwd"] = .string(cwd) }
        if let reasoningEffort = request.reasoningEffort { params["effort"] = .string(reasoningEffort) }
        params["approvalPolicy"] = .string(codexApprovalPolicy(request.approvalPolicy))
        params["sandboxPolicy"] = codexSandboxPolicy(request.sandboxMode, cwd: request.cwd)
        let result = try await client.request(method: "turn/start", params: .object(params))
        if let turnID = result["turn"]?["id"]?.stringValue {
            activeTurnIDs[request.threadID] = turnID
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

        return RuntimeSession(
            runtime: .codex,
            displayName: "Codex app-server",
            accountLabel: auth.email ?? auth.mode?.displayName,
            planLabel: auth.planLabel,
            auth: auth,
            availableLoginMethods: [Self.browserLoginMethod, Self.deviceCodeLoginMethod],
            availableModels: availableModels,
            capabilities: [
                .streaming, .steering, .interruption, .approvals, .threadForking,
                .threadArchiving, .threadCompaction, .threadDeletion, .reasoning,
                .tools, .diffs, .codeReview, .terminal, .images, .usage,
            ]
        )
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
            activeTurnIDs.removeAll()
            pendingUserInteractions.removeAll()
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
                requiresAuthentication: authMode == nil
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
            }
            eventContinuation.yield(lifecycleEvent)
            return
        }

        switch notification.method {
        case "thread/started":
            if let thread = CodexProjection.thread(from: params["thread"] ?? params) {
                eventContinuation.yield(.threadUpdated(thread))
            }
        case "turn/started":
            if let turnID = params["turn"]?["id"]?.stringValue, !threadID.isEmpty {
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
            activeTurnIDs.removeValue(forKey: threadID)
            let rawStatus = params["turn"]?["status"]?.stringValue ?? "idle"
            let status: RuntimeThreadStatus = rawStatus == "failed" ? .failed : .idle
            eventContinuation.yield(.turnCompleted(threadID: threadID, status: status))
        case "serverRequest/resolved":
            if let requestID = runtimeRequestID(from: params["requestId"]) {
                pendingUserInteractions.removeValue(forKey: requestID)
                eventContinuation.yield(.userInteractionResolved(requestID))
            }
        case "error":
            eventContinuation.yield(
                .runtimeNotice(
                    title: "Codex runtime error",
                    detail: params["error"]?["message"]?.stringValue
                        ?? params["message"]?.stringValue
                        ?? params.compactDescription
                )
            )
        default:
            break
        }
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

    private static func resolveExecutable() -> URL? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["ONYX_CODEX_PATH"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
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
