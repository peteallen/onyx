import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxApplicationHostDelegationCompositionTests: XCTestCase {
    func testHostInjectsBrokerIntoCodexAndBuildsDefinitionFromSavedProviderCatalog() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let handler = try XCTUnwrap(fixture.probe.codexHandler)
        XCTAssertEqual(fixture.probe.codexConnectionIDs, [.codexDefault])
        XCTAssertEqual(
            fixture.probe.providerConnectionIDs,
            [],
            "Composing Codex must not eagerly connect every configured provider"
        )

        let definition = await handler.dynamicToolDefinition()

        XCTAssertEqual(
            definition.inputSchema["properties"]?["provider"]?["enum"]?
                .arrayValue?.compactMap(\.stringValue),
            [fixture.providerID.rawValue]
        )
        XCTAssertEqual(
            definition.inputSchema["properties"]?["model"]?["enum"]?
                .arrayValue?.compactMap(\.stringValue),
            [fixture.modelID]
        )
        XCTAssertTrue(definition.description.contains(fixture.providerDisplayName))
        XCTAssertTrue(definition.description.contains(fixture.modelID))
        XCTAssertEqual(
            fixture.probe.providerConnectionIDs,
            [],
            "Reading the credential-free definition should use the saved model catalog"
        )
    }

    func testHostBrokerExecutesRegistryProviderAndReturnsDurableChildMetadata() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let handler = try XCTUnwrap(fixture.probe.codexHandler)
        let workingDirectory = "/tmp/onyx-composition"
        let prompt = "Answer this bounded delegated question."

        let result = try await handler.handleDynamicToolCall(
            CodexDynamicToolCall(
                threadID: "codex-parent-thread",
                callID: "composition-delegation-1",
                arguments: .object([
                    "provider": .string(fixture.providerID.rawValue),
                    "model": .string(fixture.modelID),
                    "prompt": .string(prompt),
                    "reasoningEffort": .string("medium"),
                ]),
                parentModelID: "gpt-5.6-codex",
                workingDirectory: workingDirectory
            )
        )
        let payload = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(result.text.utf8)
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(payload["type"]?.stringValue, OnyxDelegationToolPayload.type)
        XCTAssertEqual(payload["version"]?.intValue, OnyxDelegationToolPayload.version)
        XCTAssertEqual(payload["success"]?.boolValue, true)
        XCTAssertEqual(payload["job_id"]?.stringValue, "composition-delegation-1")
        XCTAssertEqual(payload["provider_connection_id"]?.stringValue, fixture.providerID.rawValue)
        XCTAssertEqual(payload["model"]?.stringValue, fixture.modelID)
        XCTAssertEqual(payload["reasoning_effort"]?.stringValue, "medium")
        XCTAssertEqual(payload["child_conversation_id"]?.stringValue, fixture.childThreadID)
        XCTAssertEqual(payload["text"]?.stringValue, fixture.response)
        XCTAssertEqual(payload["truncated"]?.boolValue, false)
        XCTAssertEqual(fixture.probe.providerConnectionIDs, [fixture.providerID])

        let threadRequests = await fixture.providerRuntime.startedThreadRequests()
        let turnRequests = await fixture.providerRuntime.startedTurnRequests()
        XCTAssertEqual(threadRequests.count, 1)
        XCTAssertEqual(threadRequests.first?.cwd, workingDirectory)
        XCTAssertEqual(threadRequests.first?.model, fixture.modelID)
        XCTAssertEqual(threadRequests.first?.ephemeral, false)
        XCTAssertEqual(threadRequests.first?.sandboxMode, .readOnly)
        XCTAssertEqual(threadRequests.first?.approvalPolicy, .never)
        XCTAssertEqual(turnRequests.count, 1)
        XCTAssertEqual(turnRequests.first?.threadID, fixture.childThreadID)
        XCTAssertEqual(turnRequests.first?.inputs, [.text(prompt)])
        XCTAssertEqual(turnRequests.first?.model, fixture.modelID)
        XCTAssertEqual(turnRequests.first?.cwd, workingDirectory)
        XCTAssertEqual(turnRequests.first?.reasoningEffort, "medium")
        XCTAssertEqual(turnRequests.first?.sandboxMode, .readOnly)
        XCTAssertEqual(turnRequests.first?.approvalPolicy, .never)
        let connectCount = await fixture.providerRuntime.connectCount()
        let deletedThreadIDs = await fixture.providerRuntime.deletedThreadIDs()
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(
            deletedThreadIDs,
            [],
            "A successful delegated child must remain durable so it can be opened from Onyx"
        )
    }

    private func makeFixture() async throws -> CompositionFixture {
        let providerID = ProviderConnectionID("local.vllm.qwen")
        let providerDisplayName = "Local Qwen"
        let modelID = "Qwen/Qwen3.8-27B-FP8"
        let childThreadID = "durable-qwen-child"
        let response = "Scripted Qwen response"
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let model = try ProviderModelDescriptor(
            id: modelID,
            displayName: "Qwen 3.8 27B",
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(
                inputModalities: [.text],
                supportedParameters: [.reasoningEffort],
                reasoningEfforts: ["none", "low", "medium", "xhigh"]
            )
        )
        try await connectionStore.upsert(ProviderConnectionRecord(
            id: providerID,
            displayName: providerDisplayName,
            baseURL: URL(string: "https://qwen.example.test/v1")!,
            selectedModelID: modelID,
            authMode: .none,
            transportCapabilities: [.streaming],
            discovery: ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: Date(timeIntervalSince1970: 10),
                lastSucceededAt: Date(timeIntervalSince1970: 11),
                discoveredModels: [model]
            )
        ))

        let probe = HostDelegationCompositionProbe()
        let providerRuntime = HostDelegationScriptedRuntime(
            modelID: modelID,
            childThreadID: childThreadID,
            response: response
        )
        let codexAdapterID = RuntimeAdapterID("test.host-composition.codex")
        let providerAdapterID = RuntimeAdapterID("test.host-composition.qwen")
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(
                    id: codexAdapterID,
                    displayName: "Scripted Codex",
                    dynamicToolFactory: { connectionID, handler in
                        probe.recordCodex(connectionID: connectionID, handler: handler)
                        return HostDelegationCodexRuntime()
                    }
                ),
                RuntimeProviderDescriptor(
                    id: providerAdapterID,
                    displayName: providerDisplayName,
                    factory: { connectionID in
                        probe.recordProvider(connectionID: connectionID)
                        return providerRuntime
                    }
                ),
            ],
            connections: [
                RuntimeConnectionRegistration(
                    id: .codexDefault,
                    adapterID: codexAdapterID
                ),
                RuntimeConnectionRegistration(
                    id: providerID,
                    adapterID: providerAdapterID
                ),
            ]
        )
        let suiteName = "OnyxApplicationHostDelegationCompositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let projectCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxHostDelegationProjects-\(UUID().uuidString).json")
        let conversationStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxHostDelegationConversations-\(UUID().uuidString).json")
        let host = OnyxApplicationHost(
            registry: registry,
            connectionID: .codexDefault,
            defaults: defaults,
            projectCatalogStore: ProjectCatalogStore(fileURL: projectCatalogURL),
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: OpenAICompatibleConversationStore(
                fileURL: conversationStoreURL
            )
        )

        return CompositionFixture(
            host: host,
            probe: probe,
            providerRuntime: providerRuntime,
            providerID: providerID,
            providerDisplayName: providerDisplayName,
            modelID: modelID,
            childThreadID: childThreadID,
            response: response,
            defaults: defaults,
            defaultsSuiteName: suiteName,
            temporaryFiles: [projectCatalogURL, conversationStoreURL]
        )
    }
}

@MainActor
private struct CompositionFixture {
    // Retaining the host matters: the credential-free delegation bridge keeps
    // only a weak reference back to the production composition root.
    let host: OnyxApplicationHost
    let probe: HostDelegationCompositionProbe
    let providerRuntime: HostDelegationScriptedRuntime
    let providerID: ProviderConnectionID
    let providerDisplayName: String
    let modelID: String
    let childThreadID: String
    let response: String
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let temporaryFiles: [URL]

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        for file in temporaryFiles {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private final class HostDelegationCompositionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCodexConnectionIDs: [ProviderConnectionID] = []
    private var recordedProviderConnectionIDs: [ProviderConnectionID] = []
    private var recordedCodexHandler: (any CodexDynamicToolHandler)?

    var codexConnectionIDs: [ProviderConnectionID] {
        lock.withLock { recordedCodexConnectionIDs }
    }

    var providerConnectionIDs: [ProviderConnectionID] {
        lock.withLock { recordedProviderConnectionIDs }
    }

    var codexHandler: (any CodexDynamicToolHandler)? {
        lock.withLock { recordedCodexHandler }
    }

    func recordCodex(
        connectionID: ProviderConnectionID,
        handler: (any CodexDynamicToolHandler)?
    ) {
        lock.withLock {
            recordedCodexConnectionIDs.append(connectionID)
            recordedCodexHandler = handler
        }
    }

    func recordProvider(connectionID: ProviderConnectionID) {
        lock.withLock { recordedProviderConnectionIDs.append(connectionID) }
    }
}

private struct HostDelegationCodexRuntime: AgentRuntime {
    let kind = AgentRuntimeKind.codex
    let events = AsyncStream<AgentRuntimeEvent> { continuation in
        continuation.finish()
    }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
            runtime: .codex,
            displayName: "Scripted Codex",
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
            capabilities: []
        )
    }

    func disconnect() async {}
    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] { [] }
    func readThread(id _: String) async throws -> RuntimeConversation {
        throw AgentRuntimeError.unsupported("scripted Codex thread reading")
    }
    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("scripted Codex thread creation")
    }
    func startTurn(_: StartTurnRequest) async throws {
        throw AgentRuntimeError.unsupported("scripted Codex turns")
    }
    func steer(threadID _: String, text _: String) async throws {
        throw AgentRuntimeError.unsupported("scripted Codex steering")
    }
    func interrupt(threadID _: String) async throws {}
    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {
        throw AgentRuntimeError.unsupported("scripted Codex responses")
    }
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
}

private actor HostDelegationScriptedRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.local
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let continuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let modelID: String
    private let childThread: RuntimeThread
    private let response: String
    private var connects = 0
    private var threadRequests: [StartThreadRequest] = []
    private var turnRequests: [StartTurnRequest] = []
    private var deletedThreads: [String] = []

    init(modelID: String, childThreadID: String, response: String) {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        continuation = stream.continuation
        self.modelID = modelID
        childThread = RuntimeThread(
            id: childThreadID,
            title: "Delegated Qwen task",
            preview: "",
            cwd: "/tmp/onyx-composition",
            updatedAt: Date(timeIntervalSince1970: 20),
            status: .idle,
            isPinned: false,
            runtime: .local,
            model: modelID,
            branch: nil
        )
        self.response = response
    }

    func connect() async throws -> RuntimeSession {
        connects += 1
        return RuntimeSession(
            runtime: .local,
            displayName: "Scripted Qwen",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [
                RuntimeModel(
                    id: modelID,
                    displayName: "Qwen 3.8 27B",
                    description: nil,
                    isDefault: true,
                    defaultReasoningEffort: "xhigh",
                    reasoningEfforts: ["none", "low", "medium", "xhigh"],
                    inputModalities: [.text],
                    supportedRequestParameters: [.reasoningEffort]
                ),
            ],
            capabilities: [.streaming]
        )
    }

    func disconnect() async {}
    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] { [] }
    func readThread(id _: String) async throws -> RuntimeConversation {
        RuntimeConversation(thread: childThread, items: [])
    }
    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        threadRequests.append(request)
        return childThread
    }
    func startTurn(_ request: StartTurnRequest) async throws {
        turnRequests.append(request)
        let item = TimelineItem(
            id: "scripted-qwen-answer",
            kind: .assistantMessage,
            title: nil,
            body: response,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 21),
            detail: nil
        )
        continuation.yield(.itemStarted(
            threadID: childThread.id,
            item: TimelineItem(
                id: item.id,
                kind: item.kind,
                title: item.title,
                body: "",
                status: .running,
                timestamp: item.timestamp,
                detail: nil
            )
        ))
        continuation.yield(.itemDelta(
            threadID: childThread.id,
            itemID: item.id,
            delta: response
        ))
        continuation.yield(.itemCompleted(threadID: childThread.id, item: item))
        continuation.yield(.turnCompleted(threadID: childThread.id, status: .idle))
    }
    func steer(threadID _: String, text _: String) async throws {
        throw AgentRuntimeError.unsupported("scripted provider steering")
    }
    func interrupt(threadID _: String) async throws {}
    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {
        throw AgentRuntimeError.unsupported("scripted provider responses")
    }
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
    func deleteThread(id: String) async throws { deletedThreads.append(id) }

    func startedThreadRequests() -> [StartThreadRequest] { threadRequests }
    func startedTurnRequests() -> [StartTurnRequest] { turnRequests }
    func connectCount() -> Int { connects }
    func deletedThreadIDs() -> [String] { deletedThreads }
}
