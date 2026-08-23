import Foundation
import XCTest
@testable import Onyx

final class OnyxDelegationBrokerTests: XCTestCase {
    private let connectionID = ProviderConnectionID("local.qwen")
    private let modelID = "Qwen/Qwen3.8-27B-FP8"

    func testDynamicDefinitionUsesCurrentCredentialFreeProviderAndModelCatalog() async throws {
        let runtime = BrokerScriptedRuntime()
        let state = BrokerTestState(
            configurations: [configuration()],
            runtime: runtime
        )
        let broker = makeBroker(state: state)

        let definition = await broker.dynamicToolDefinition()
        let properties = try XCTUnwrap(
            definition.inputSchema["properties"]?.objectValue
        )

        XCTAssertEqual(
            properties["provider"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
            [connectionID.rawValue]
        )
        XCTAssertEqual(
            properties["model"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
            [modelID]
        )
        XCTAssertEqual(
            properties["reasoningEffort"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
            ["low", "xhigh"]
        )
        XCTAssertTrue(definition.description.contains("Home Qwen"))
        XCTAssertFalse(definition.description.contains("http"))
        XCTAssertLessThanOrEqual(
            definition.description.count,
            OnyxDelegationBroker.maximumDefinitionDescriptionCharacters
        )
    }

    func testSuccessfulCallRunsReadOnlyWithoutApprovalsAndReturnsClickableMetadata() async throws {
        let runtime = BrokerScriptedRuntime(response: "A concise delegated answer.")
        let state = BrokerTestState(
            configurations: [configuration()],
            runtime: runtime
        )
        let broker = makeBroker(state: state)

        let result = try await broker.handleDynamicToolCall(
            call(
                id: "delegate-1",
                reasoningEffort: "low",
                workingDirectory: "/tmp/onyx-project"
            )
        )
        let payload = try decodePayload(result)
        let starts = await runtime.startedRequests()

        XCTAssertTrue(result.success)
        XCTAssertEqual(payload["type"]?.stringValue, OnyxDelegationToolPayload.type)
        XCTAssertEqual(payload["job_id"]?.stringValue, "delegate-1")
        XCTAssertEqual(payload["provider_connection_id"]?.stringValue, connectionID.rawValue)
        XCTAssertEqual(payload["model"]?.stringValue, modelID)
        XCTAssertEqual(payload["reasoning_effort"]?.stringValue, "low")
        XCTAssertEqual(payload["child_conversation_id"]?.stringValue, "child-1")
        XCTAssertEqual(payload["text"]?.stringValue, "A concise delegated answer.")
        XCTAssertEqual(payload["truncated"]?.boolValue, false)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].model, modelID)
        XCTAssertEqual(starts[0].reasoningEffort, "low")
        XCTAssertEqual(starts[0].cwd, "/tmp/onyx-project")
        XCTAssertEqual(starts[0].sandboxMode, .readOnly)
        XCTAssertEqual(starts[0].approvalPolicy, .never)
        XCTAssertEqual(starts[0].inputs, [.text("Check the proposed approach.")])
    }

    func testModelPairingAndReasoningAreRejectedBeforeRuntimeResolution() async throws {
        let runtime = BrokerScriptedRuntime()
        let state = BrokerTestState(
            configurations: [configuration()],
            runtime: runtime
        )
        let broker = makeBroker(state: state)

        let wrongModel = try await broker.handleDynamicToolCall(
            call(id: "wrong-model", model: "not-on-this-provider")
        )
        let wrongModelPayload = try decodePayload(wrongModel)
        let wrongReasoning = try await broker.handleDynamicToolCall(
            call(id: "wrong-reasoning", reasoningEffort: "max")
        )
        let wrongReasoningPayload = try decodePayload(wrongReasoning)

        XCTAssertFalse(wrongModel.success)
        XCTAssertEqual(
            wrongModelPayload["error_code"]?.stringValue,
            OnyxDelegationBrokerErrorCode.modelNotAvailable.rawValue
        )
        XCTAssertNil(wrongModelPayload["error"])
        XCTAssertFalse(wrongReasoning.success)
        XCTAssertEqual(
            wrongReasoningPayload["error_code"]?.stringValue,
            OnyxDelegationBrokerErrorCode.reasoningEffortNotSupported.rawValue
        )
        let resolutionCount = await state.runtimeResolutionCount()
        let startedRequests = await runtime.startedRequests()
        XCTAssertEqual(resolutionCount, 0)
        XCTAssertTrue(startedRequests.isEmpty)
    }

    func testSettingsCatalogChangesAreObservedByTheNextCall() async throws {
        let runtime = BrokerScriptedRuntime(response: "updated model response")
        let state = BrokerTestState(
            configurations: [configuration()],
            runtime: runtime
        )
        let broker = makeBroker(state: state)

        let first = try await broker.handleDynamicToolCall(call(id: "before-edit"))
        XCTAssertTrue(first.success)

        let replacementModel = runtimeModel(id: "Qwen/replacement", efforts: ["medium"])
        await state.setConfigurations([
            DelegationProviderConfiguration(
                connectionID: connectionID,
                displayName: "Edited Qwen",
                models: [replacementModel]
            ),
        ])
        let staleSelection = try await broker.handleDynamicToolCall(call(id: "stale-selection"))
        let replacement = try await broker.handleDynamicToolCall(
            call(
                id: "after-edit",
                model: replacementModel.id,
                reasoningEffort: "medium"
            )
        )

        XCTAssertFalse(staleSelection.success)
        XCTAssertTrue(replacement.success)
        let starts = await runtime.startedRequests()
        XCTAssertEqual(starts.map(\.model), [modelID, replacementModel.id])
        XCTAssertEqual(starts.map(\.reasoningEffort), ["xhigh", "medium"])
    }

    func testResponseTextIsBoundedAndProviderErrorsDoNotLeakDiagnostics() async throws {
        let runtime = BrokerScriptedRuntime(response: String(repeating: "r", count: 100))
        let state = BrokerTestState(
            configurations: [configuration()],
            runtime: runtime
        )
        let broker = makeBroker(state: state, maximumResponseCharacters: 12)

        let bounded = try await broker.handleDynamicToolCall(call(id: "bounded"))
        let boundedPayload = try decodePayload(bounded)
        XCTAssertEqual(boundedPayload["text"]?.stringValue?.count, 12)
        XCTAssertTrue(boundedPayload["text"]?.stringValue?.hasSuffix("…") == true)
        XCTAssertEqual(boundedPayload["truncated"]?.boolValue, true)

        await state.failRuntimeResolution(
            "https://private-host.invalid/v1 Authorization: Bearer secret-token"
        )
        let unavailable = try await broker.handleDynamicToolCall(call(id: "unavailable"))

        XCTAssertFalse(unavailable.success)
        XCTAssertFalse(unavailable.text.contains("private-host"))
        XCTAssertFalse(unavailable.text.lowercased().contains("bearer"))
        XCTAssertFalse(unavailable.text.contains("secret-token"))
    }

    func testGlobalCapacityAndCancellationSurviveCoordinatorInvalidation() async throws {
        let runtime = BrokerScriptedRuntime(behavior: .blockUntilCancelled)
        let state = BrokerTestState(
            configurations: [configuration()],
            runtime: runtime
        )
        let broker = makeBroker(state: state, maxConcurrentJobs: 1)

        let firstCall = call(id: "capacity-first")
        let first = Task {
            try await broker.handleDynamicToolCall(firstCall)
        }
        try await waitForStartedRequestCount(1, runtime: runtime)

        await state.setConfigurations([
            DelegationProviderConfiguration(
                connectionID: connectionID,
                displayName: "Renamed Qwen",
                models: [runtimeModel(id: modelID, efforts: ["low", "xhigh"])]
            ),
        ])
        await broker.invalidate(connectionID: connectionID)
        let secondCall = call(id: "capacity-second")
        let second = Task {
            try await broker.handleDynamicToolCall(secondCall)
        }
        try await Task.sleep(for: .milliseconds(40))
        let startedBeforeCancellation = await runtime.startedRequests().count
        XCTAssertEqual(startedBeforeCancellation, 1)

        let cancelledFirst = await broker.cancel(callID: "capacity-first")
        XCTAssertTrue(cancelledFirst)
        let firstResult = try await first.value
        XCTAssertFalse(firstResult.success)
        try await waitForStartedRequestCount(2, runtime: runtime)

        let cancelledSecond = await broker.cancel(callID: "capacity-second")
        XCTAssertTrue(cancelledSecond)
        let secondResult = try await second.value
        XCTAssertFalse(secondResult.success)
        let maximumConcurrentTurns = await runtime.maximumConcurrentTurns()
        XCTAssertEqual(maximumConcurrentTurns, 1)
    }

    func testLiveQwenDelegationThroughProductionBrokerIsOptIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ONYX_LIVE_QWEN_DELEGATION_TEST"] == "1",
            "Set ONYX_LIVE_QWEN_DELEGATION_TEST=1 to run the production broker against a configured vLLM/Qwen endpoint."
        )

        guard let endpointText = environment["ONYX_LIVE_QWEN_ENDPOINT"],
              let endpoint = URL(string: endpointText) else {
            throw XCTSkip("Set ONYX_LIVE_QWEN_ENDPOINT to the vLLM-compatible base URL.")
        }
        let marker = "ONYX_QWEN_DELEGATION_LIVE_OK"
        let connection = try ProviderConnectionRecord(
            id: connectionID,
            displayName: "Live Qwen delegation",
            baseURL: endpoint,
            selectedModelID: modelID,
            authMode: .none,
            transportSecurity: .allowInsecureHTTP,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        try await connectionStore.upsert(connection)

        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxLiveDelegation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: location) }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connectionID,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: OpenAICompatibleConversationStore(fileURL: location)
        )
        let session = try await runtime.connect()
        let liveModel = try XCTUnwrap(
            session.availableModels.first { $0.id == modelID },
            "The live endpoint did not advertise \(modelID)."
        )
        XCTAssertTrue(
            liveModel.reasoningEfforts.contains("medium"),
            "The discovered Qwen model must advertise medium reasoning before delegation."
        )

        let configuration = DelegationProviderConfiguration(
            connectionID: connectionID,
            displayName: connection.displayName,
            models: [liveModel]
        )
        let broker = OnyxDelegationBroker(
            providerCatalogResolver: { [configuration] },
            runtimeResolver: { requestedConnectionID in
                guard requestedConnectionID == connection.id else {
                    throw OpenAICompatibleRuntimeError.connectionNotFound(
                        requestedConnectionID
                    )
                }
                return runtime
            }
        )
        let callID = "live-qwen-delegation-\(UUID().uuidString.lowercased())"
        let result = try await broker.handleDynamicToolCall(
            call(
                id: callID,
                reasoningEffort: "medium",
                workingDirectory: "/tmp/onyx-live-delegation",
                prompt: "Reply with the exact marker \(marker)."
            )
        )
        let payload = try decodePayload(result)

        XCTAssertTrue(result.success, "Live delegation failed: \(result.text)")
        XCTAssertEqual(payload["type"]?.stringValue, OnyxDelegationToolPayload.type)
        XCTAssertEqual(payload["success"]?.boolValue, true)
        XCTAssertEqual(payload["job_id"]?.stringValue, callID)
        XCTAssertEqual(
            payload["provider_connection_id"]?.stringValue,
            connectionID.rawValue
        )
        XCTAssertEqual(payload["model"]?.stringValue, modelID)
        XCTAssertEqual(payload["reasoning_effort"]?.stringValue, "medium")
        XCTAssertNil(payload["error_code"])
        let delegatedText = try XCTUnwrap(payload["text"]?.stringValue)
        XCTAssertTrue(
            delegatedText.contains(marker),
            "Expected the live result marker in: \(delegatedText)"
        )

        let childID = try XCTUnwrap(payload["child_conversation_id"]?.stringValue)
        let durableStore = OpenAICompatibleConversationStore(fileURL: location)
        let child = try await durableStore.conversation(
            connectionID: connectionID,
            id: childID,
            scopeID: connection.conversationScopeID
        )
        let durableChild = try XCTUnwrap(
            child,
            "The broker returned a child ID that was not durably persisted."
        )
        XCTAssertEqual(durableChild.connectionID, connectionID)
        XCTAssertEqual(durableChild.modelID, modelID)
        XCTAssertEqual(durableChild.status, .idle)
        XCTAssertTrue(
            durableChild.messages.contains {
                $0.role == .assistant && $0.text.contains(marker)
            },
            "The durable provider-scoped child did not retain the delegated result."
        )
    }

    private func makeBroker(
        state: BrokerTestState,
        maxConcurrentJobs: Int = 2,
        maximumResponseCharacters: Int = OnyxDelegationBroker.defaultMaximumResponseCharacters
    ) -> OnyxDelegationBroker {
        OnyxDelegationBroker(
            maxConcurrentJobs: maxConcurrentJobs,
            maximumResponseCharacters: maximumResponseCharacters,
            providerCatalogResolver: { try await state.catalog() },
            runtimeResolver: { try await state.resolve($0) }
        )
    }

    private func configuration() -> DelegationProviderConfiguration {
        DelegationProviderConfiguration(
            connectionID: connectionID,
            displayName: "Home Qwen",
            models: [runtimeModel(id: modelID, efforts: ["low", "xhigh"])]
        )
    }

    private func runtimeModel(id: String, efforts: [String]) -> RuntimeModel {
        RuntimeModel(
            id: id,
            displayName: id,
            description: nil,
            isDefault: true,
            defaultReasoningEffort: efforts.last,
            reasoningEfforts: efforts,
            inputModalities: [.text]
        )
    }

    private func call(
        id: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
        workingDirectory: String? = nil,
        prompt: String = "Check the proposed approach."
    ) -> CodexDynamicToolCall {
        var arguments: [String: JSONValue] = [
            "provider": .string(connectionID.rawValue),
            "model": .string(model ?? modelID),
            "prompt": .string(prompt),
        ]
        if let reasoningEffort {
            arguments["reasoningEffort"] = .string(reasoningEffort)
        }
        return CodexDynamicToolCall(
            threadID: "parent-thread",
            callID: id,
            arguments: .object(arguments),
            parentModelID: "gpt-5.6-codex",
            workingDirectory: workingDirectory
        )
    }

    private func decodePayload(
        _ result: CodexDynamicToolResult
    ) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
    }

    private func waitForStartedRequestCount(
        _ expected: Int,
        runtime: BrokerScriptedRuntime
    ) async throws {
        for _ in 0 ..< 200 {
            if await runtime.startedRequests().count >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(expected) delegated turns")
    }
}

private actor BrokerTestState {
    private var configurations: [DelegationProviderConfiguration]
    private let runtime: any AgentRuntime
    private var runtimeFailure: String?
    private var resolutions = 0

    init(
        configurations: [DelegationProviderConfiguration],
        runtime: any AgentRuntime
    ) {
        self.configurations = configurations
        self.runtime = runtime
    }

    func catalog() throws -> [DelegationProviderConfiguration] {
        configurations
    }

    func resolve(_ connectionID: ProviderConnectionID) throws -> any AgentRuntime {
        resolutions += 1
        guard configurations.contains(where: { $0.connectionID == connectionID }) else {
            throw TestFailure("connection unavailable")
        }
        if let runtimeFailure { throw TestFailure(runtimeFailure) }
        return runtime
    }

    func setConfigurations(_ configurations: [DelegationProviderConfiguration]) {
        self.configurations = configurations
    }

    func failRuntimeResolution(_ message: String) {
        runtimeFailure = message
    }

    func runtimeResolutionCount() -> Int { resolutions }

    private struct TestFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

private enum BrokerRuntimeBehavior: Sendable {
    case respond(String)
    case blockUntilCancelled
}

private actor BrokerScriptedRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind = .local
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let continuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let behavior: BrokerRuntimeBehavior
    private var starts: [StartTurnRequest] = []
    private var threadCounter = 0
    private var activeTurns = 0
    private var maximumActiveTurns = 0

    init(
        response: String = "broker response",
        behavior: BrokerRuntimeBehavior? = nil
    ) {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        continuation = stream.continuation
        self.behavior = behavior ?? .respond(response)
    }

    deinit { continuation.finish() }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
            runtime: .local,
            displayName: "Scripted broker provider",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming, .reasoning]
        )
    }

    func disconnect() async {}
    func startLogin(methodID _: String) async throws -> RuntimeLoginStart {
        throw AgentRuntimeError.unsupported("login")
    }
    func cancelLogin(id _: String) async throws {
        throw AgentRuntimeError.unsupported("login")
    }
    func logout() async throws {}
    func refreshAccount() async throws -> RuntimeSession { try await connect() }
    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] { [] }
    func listAllThreads(archived _: Bool) async throws -> [RuntimeThread] { [] }

    func readThread(id: String) async throws -> RuntimeConversation {
        RuntimeConversation(thread: thread(id: id), items: [])
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await readThread(id: id)
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        threadCounter += 1
        return thread(id: "child-\(threadCounter)", request: request)
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        starts.append(request)
        activeTurns += 1
        maximumActiveTurns = max(maximumActiveTurns, activeTurns)
        defer { activeTurns -= 1 }

        switch behavior {
        case .blockUntilCancelled:
            try await Task.sleep(for: .seconds(60))
        case let .respond(response):
            continuation.yield(.itemStarted(
                threadID: request.threadID,
                item: TimelineItem(
                    id: "assistant-\(request.threadID)",
                    kind: .assistantMessage,
                    title: nil,
                    body: "",
                    status: .running,
                    timestamp: .now,
                    detail: nil
                )
            ))
            continuation.yield(.itemCompleted(
                threadID: request.threadID,
                item: TimelineItem(
                    id: "assistant-\(request.threadID)",
                    kind: .assistantMessage,
                    title: nil,
                    body: response,
                    status: .completed,
                    timestamp: .now,
                    detail: nil
                )
            ))
            continuation.yield(.turnCompleted(threadID: request.threadID, status: .idle))
        }
    }

    func interrupt(threadID _: String) async throws {}
    func steer(threadID _: String, text _: String) async throws {
        throw AgentRuntimeError.unsupported("steer")
    }
    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {
        throw AgentRuntimeError.unsupported("respond")
    }
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
    func deleteThread(id _: String) async throws {}

    func startedRequests() -> [StartTurnRequest] { starts }
    func maximumConcurrentTurns() -> Int { maximumActiveTurns }

    private func thread(
        id: String,
        request: StartThreadRequest? = nil
    ) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: "Delegated child",
            preview: "",
            cwd: request?.cwd ?? "/tmp",
            updatedAt: .now,
            status: .idle,
            isPinned: false,
            runtime: .local,
            model: request?.model,
            branch: nil
        )
    }
}
