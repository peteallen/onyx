import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleAdaptiveRuntimeResolverTests: XCTestCase {
    func testAdvertisedToolModelStartsAgenticallyDespitePersistedProbeFailure() async throws {
        let modelID = "acme/agent-17"
        let descriptor = try ProviderModelDescriptor(
            id: modelID,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(
                serverAdvertisedCapabilities: ["tool_use"]
            )
        )
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("adaptive-provider"),
            displayName: "Adaptive provider",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: modelID,
            authMode: .none,
            transportCapabilities: [.streaming],
            discovery: ProviderConnectionDiscoveryMetadata(
                discoveredModels: [descriptor]
            ),
            conversationScopeID: "scope-before"
        )
        let now = Date(timeIntervalSince1970: 50_000)
        let stateStore = makeAdaptiveStateStore()
        let failedRecord = OpenAICompatibleResponsesProbeRecord(
            fingerprint: OpenAICompatibleResponsesProbeFingerprint(
                connection: connection,
                modelID: modelID
            ),
            testedAt: now,
            expiresAt: now.addingTimeInterval(3_600),
            outcome: .failed(.malformedEventStream)
        )
        try await stateStore.storeProbeRecord(failedRecord, at: now)
        let probe = AdaptiveLaneProbe(
            outcomes: [modelID: .failed(.malformedEventStream)],
            testedAt: now
        )
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: stateStore,
            now: { now }
        )

        let decisions = try await resolver.resolveNewTasks(
            connection: connection,
            modelIDs: [modelID],
            modelIDToProbe: modelID
        )

        XCTAssertEqual(decisions.first?.lane, .agent)
        XCTAssertEqual(decisions.first?.basis, .advertisedToolUse)
        try await Task.sleep(for: .milliseconds(20))
        let probedModels = await probe.modelsProbed()
        XCTAssertEqual(probedModels, [])
    }

    func testNewTaskLaneIsResolvedPerModelAndReusableProbeEvidenceIsCached() async throws {
        let connection = try makeAdaptiveConnection()
        let now = Date(timeIntervalSince1970: 100)
        let probe = AdaptiveLaneProbe(outcomes: [
            "agent-model": .compatible(Self.compatibleEvidence),
            "chat-model": .failed(.missingFunctionCall),
        ], testedAt: now)
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: makeAdaptiveStateStore(),
            now: { now }
        )

        let beforeProbe = try await resolver.resolveNewTask(
            connection: connection,
            modelID: "agent-model"
        )
        XCTAssertEqual(beforeProbe.lane, .chat)
        XCTAssertEqual(beforeProbe.basis, .unavailableProbe)
        let callsBeforeProbe = await probe.modelsProbed()
        XCTAssertEqual(callsBeforeProbe.count, 0)

        let agent = try await resolveAfterProbe(
            resolver: resolver,
            connection: connection,
            modelID: "agent-model"
        )
        let cachedAgent = try await resolver.resolveNewTask(
            connection: connection,
            modelID: "agent-model"
        )
        let chat = try await resolveAfterProbe(
            resolver: resolver,
            connection: connection,
            modelID: "chat-model"
        )

        XCTAssertEqual(agent.lane, .agent)
        XCTAssertEqual(agent.basis, .compatibleProbe)
        XCTAssertEqual(cachedAgent, agent)
        XCTAssertEqual(chat.lane, .chat)
        XCTAssertEqual(chat.basis, .failedProbe(.missingFunctionCall))
        XCTAssertEqual(agent.modelID, "agent-model")
        XCTAssertEqual(chat.modelID, "chat-model")
        let probedModels = await probe.modelsProbed()
        XCTAssertEqual(probedModels, ["agent-model", "chat-model"])
    }

    func testConcurrentSameModelResolutionSharesOneProbe() async throws {
        let connection = try makeAdaptiveConnection()
        let probe = AdaptiveLaneProbe(
            outcomes: ["agent-model": .compatible(Self.compatibleEvidence)],
            delay: .milliseconds(50)
        )
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: makeAdaptiveStateStore()
        )

        async let first: Void = resolver.beginProbe(
            connection: connection,
            modelID: "agent-model"
        )
        async let second: Void = resolver.beginProbe(
            connection: connection,
            modelID: "agent-model"
        )
        _ = try await (first, second)
        let decision = try await waitForResolvedProbe(
            resolver: resolver,
            connection: connection,
            modelID: "agent-model"
        )

        XCTAssertEqual(decision.lane, .agent)
        let probedModels = await probe.modelsProbed()
        XCTAssertEqual(probedModels, ["agent-model"])
    }

    func testCatalogProjectionStartsOnlyTheExplicitlySelectedModelProbe() async throws {
        let connection = try makeAdaptiveConnection()
        let now = Date(timeIntervalSince1970: 500)
        let probe = AdaptiveLaneProbe(
            outcomes: ["agent-model": .compatible(Self.compatibleEvidence)],
            testedAt: now
        )
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: makeAdaptiveStateStore(),
            now: { now }
        )

        let initial = try await resolver.resolveNewTasks(
            connection: connection,
            modelIDs: ["agent-model", "large-catalog-model-1", "large-catalog-model-2"],
            modelIDToProbe: "agent-model"
        )

        XCTAssertEqual(initial.map(\.lane), [.chat, .chat, .chat])
        XCTAssertEqual(initial.map(\.basis), [
            .unavailableProbe, .unavailableProbe, .unavailableProbe,
        ])
        try await waitForProbeCalls(probe, count: 1)
        _ = try await waitForResolvedProbe(
            resolver: resolver,
            connection: connection,
            modelID: "agent-model"
        )
        try await Task.sleep(for: .milliseconds(10))
        let probedModels = await probe.modelsProbed()
        XCTAssertEqual(probedModels, ["agent-model"])
    }

    func testProbeUpdateStreamBuffersImmediateResultBeforeIterationBegins() async throws {
        let connection = try makeAdaptiveConnection()
        let now = Date(timeIntervalSince1970: 625)
        let probe = AdaptiveLaneProbe(
            outcomes: ["agent-model": .compatible(Self.compatibleEvidence)],
            testedAt: now
        )
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: makeAdaptiveStateStore(),
            now: { now }
        )

        // `connect()` obtains this stream before asking the resolver to start
        // the selected-model probe, but its listener task begins afterwards.
        // Finish the immediate probe before creating an iterator to prove the
        // update is buffered at stream registration rather than lost.
        let updates = await resolver.probeUpdates()
        let initial = try await resolver.resolveNewTasks(
            connection: connection,
            modelIDs: ["agent-model"],
            modelIDToProbe: "agent-model"
        )
        XCTAssertEqual(initial.first?.basis, .unavailableProbe)
        let resolved = try await waitForResolvedProbe(
            resolver: resolver,
            connection: connection,
            modelID: "agent-model"
        )
        XCTAssertEqual(resolved.basis, .compatibleProbe)

        var iterator = updates.makeAsyncIterator()
        let update = await iterator.next()
        XCTAssertEqual(update?.0, "agent-model")
        XCTAssertEqual(update?.1.outcome, .compatible(Self.compatibleEvidence))
    }

    func testProbeFailureFailsClosedToChatWithoutCachingAnException() async throws {
        let connection = try makeAdaptiveConnection()
        let probe = AdaptiveLaneProbe(
            outcomes: [:],
            throwingModels: ["unavailable"],
            delay: .milliseconds(10)
        )
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: makeAdaptiveStateStore()
        )

        try await resolver.beginProbe(
            connection: connection,
            modelID: "unavailable"
        )
        try await waitForProbeCalls(probe, count: 1)
        try await Task.sleep(for: .milliseconds(30))
        let first = try await resolver.resolveNewTask(
            connection: connection,
            modelID: "unavailable"
        )
        try await resolver.beginProbe(
            connection: connection,
            modelID: "unavailable"
        )
        try await waitForProbeCalls(probe, count: 2)
        let second = try await resolver.resolveNewTask(
            connection: connection,
            modelID: "unavailable"
        )

        XCTAssertEqual(first.lane, .chat)
        XCTAssertEqual(first.basis, .unavailableProbe)
        XCTAssertEqual(second.lane, .chat)
        let probedModels = await probe.modelsProbed()
        XCTAssertEqual(probedModels, ["unavailable", "unavailable"])
    }

    func testCompatibleProbePublishesInProcessWithoutPersistenceAndFreshResolverProbesAgain() async throws {
        let connection = try makeAdaptiveConnection()
        let now = Date(timeIntervalSince1970: 10_000)
        let probe = AdaptiveLaneProbe(
            outcomes: ["agent-model": .compatible(Self.compatibleEvidence)],
            testedAt: now
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "onyx-adaptive-resolver-persistence-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let blockingFile = temporaryDirectory.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: blockingFile.path,
            contents: Data()
        ))
        let stateFile = blockingFile.appendingPathComponent("adaptive-state.json")
        let stateStore = OpenAICompatibleAdaptiveStateStore(
            fileURL: stateFile
        )
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: stateStore,
            now: { now }
        )
        let updates = await resolver.probeUpdates()
        var updateIterator = updates.makeAsyncIterator()

        let currentProcessDecision = try await resolveAfterProbe(
            resolver: resolver,
            connection: connection,
            modelID: "agent-model"
        )
        XCTAssertEqual(currentProcessDecision.lane, .agent)
        XCTAssertEqual(currentProcessDecision.basis, .compatibleProbe)
        let update = await updateIterator.next()
        XCTAssertEqual(update?.0, "agent-model")
        XCTAssertEqual(update?.1.outcome, .compatible(Self.compatibleEvidence))
        let firstCalls = await probe.modelsProbed()
        XCTAssertEqual(firstCalls, ["agent-model"])

        let fingerprint = OpenAICompatibleResponsesProbeFingerprint(
            connection: connection,
            modelID: "agent-model"
        )
        let persisted = try await stateStore.probeRecord(for: fingerprint, at: now)
        XCTAssertNil(persisted)

        let freshProbe = AdaptiveLaneProbe(
            outcomes: ["agent-model": .compatible(Self.compatibleEvidence)],
            testedAt: now
        )
        let freshResolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: freshProbe,
            stateStore: OpenAICompatibleAdaptiveStateStore(fileURL: stateFile),
            now: { now }
        )
        let beforeFreshProbe = try await freshResolver.resolveNewTask(
            connection: connection,
            modelID: "agent-model"
        )
        XCTAssertEqual(beforeFreshProbe.lane, .chat)
        XCTAssertEqual(beforeFreshProbe.basis, .unavailableProbe)
        let callsBeforeFreshProbe = await freshProbe.modelsProbed()
        XCTAssertEqual(callsBeforeFreshProbe, [])

        let freshDecision = try await resolveAfterProbe(
            resolver: freshResolver,
            connection: connection,
            modelID: "agent-model"
        )
        XCTAssertEqual(freshDecision.lane, .agent)
        XCTAssertEqual(freshDecision.basis, .compatibleProbe)
        let freshCalls = await freshProbe.modelsProbed()
        XCTAssertEqual(freshCalls, ["agent-model"])

        await resolver.invalidateProbeCache()
        await freshResolver.invalidateProbeCache()
    }

    func testExistingTasksKeepDurableLanesWithoutUnlockingNewTasks() async throws {
        let connection = try makeAdaptiveConnection()
        let probe = AdaptiveLaneProbe(
            outcomes: ["later-compatible": .compatible(Self.compatibleEvidence)]
        )
        let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
            probe: probe,
            stateStore: makeAdaptiveStateStore()
        )
        let chatOwner = OpenAICompatibleTaskLaneOwnership(
            connectionID: connection.id,
            conversationScopeID: connection.conversationScopeID,
            threadID: "chat-thread",
            lane: .chat,
            modelID: "later-compatible",
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let agentOwner = OpenAICompatibleTaskLaneOwnership(
            connectionID: connection.id,
            conversationScopeID: connection.conversationScopeID,
            threadID: "agent-thread",
            lane: .agent,
            modelID: "previously-compatible",
            updatedAt: Date(timeIntervalSince1970: 60)
        )

        let existingChat = try await resolver.resolveExistingTask(
            connection: connection,
            ownership: chatOwner
        )
        let existingAgent = try await resolver.resolveExistingTask(
            connection: connection,
            ownership: agentOwner
        )
        let freshTaskWithOwnedAgentModel = try await resolver.resolveNewTask(
            connection: connection,
            modelID: agentOwner.modelID
        )

        XCTAssertEqual(existingChat.lane, .chat)
        XCTAssertEqual(existingChat.basis, .existingTask)
        XCTAssertEqual(existingAgent.lane, .agent)
        XCTAssertEqual(existingAgent.basis, .existingTask)
        XCTAssertEqual(freshTaskWithOwnedAgentModel.lane, .chat)
        XCTAssertEqual(freshTaskWithOwnedAgentModel.basis, .unavailableProbe)
        let probedModels = await probe.modelsProbed()
        XCTAssertEqual(probedModels, [])
        XCTAssertEqual(
            try JSONDecoder().decode(
                OpenAICompatibleTaskLaneOwnership.self,
                from: JSONEncoder().encode(chatOwner)
            ),
            chatOwner
        )

        let rotated = try makeAdaptiveConnection(scopeID: "scope-after")
        do {
            _ = try await resolver.resolveExistingTask(
                connection: rotated,
                ownership: chatOwner
            )
            XCTFail("A task from another provider scope must not be replayed")
        } catch let error as OpenAICompatibleAdaptiveRuntimeResolverError {
            XCTAssertEqual(error, .taskScopeMismatch)
        }
    }

    func testAgentRuntimeIdentityUsesOnlyConnectionAndConversationScope() throws {
        let first = try makeAdaptiveConnection(
            displayName: "Before",
            baseURL: URL(string: "https://before.example.test/v1")!
        )
        let settingsChanged = try makeAdaptiveConnection(
            displayName: "After",
            baseURL: URL(string: "https://after.example.test/api/v1")!
        )
        let scopeChanged = try makeAdaptiveConnection(scopeID: "scope-after")

        let firstIdentity = OpenAICompatibleAgentRuntimeIdentity(connection: first)
        XCTAssertEqual(
            OpenAICompatibleAgentRuntimeIdentity(connection: settingsChanged),
            firstIdentity
        )
        XCTAssertNotEqual(
            OpenAICompatibleAgentRuntimeIdentity(connection: scopeChanged),
            firstIdentity
        )
        XCTAssertTrue(firstIdentity.modelProviderID.hasPrefix("onyx-openai-compatible-"))
        XCTAssertTrue(firstIdentity.stateIdentifier.hasPrefix("provider_"))
        XCTAssertFalse(firstIdentity.stateIdentifier.contains(first.id.rawValue))
        XCTAssertFalse(firstIdentity.stateIdentifier.contains(first.conversationScopeID))
    }

    func testAgentFactoryGivesAppServerOnlyDisposableProxyCredentialAndOwnsShutdown() async throws {
        let connection = try makeAdaptiveConnection(authMode: .bearer)
        let credentialStore = InMemoryCredentialStore()
        try await credentialStore.setCredential(
            ProviderBearerCredential("upstream-provider-secret"),
            for: connection.credentialKey
        )
        let recorder = AdaptiveFactoryRecorder()
        let runtime = AdaptiveFactoryRuntime(
            recorder: recorder,
            blocksDisconnect: true
        )
        let delegationHandler = AdaptiveFactoryDynamicToolHandler()
        let factory = OpenAICompatibleAgentRuntimeFactory(
            credentialStore: credentialStore,
            dynamicToolHandler: delegationHandler,
            proxyFactory: { _, credential in
                let upstream = try credential?.withValue { $0 }
                recorder.recordUpstreamCredential(upstream)
                return OpenAICompatibleAgentProxyLease(
                    baseURL: URL(string: "http://127.0.0.1:54321/v1")!,
                    disposableAPIKey: "disposable-proxy-token",
                    stop: { recorder.recordProxyStop() }
                )
            },
            runtimeFactory: { binding, handler in
                recorder.recordBinding(binding)
                recorder.recordDynamicToolHandler(handler)
                return runtime
            }
        )

        let prepared = try await factory.prepare(connection: connection)
        let binding = try XCTUnwrap(recorder.binding)

        XCTAssertEqual(recorder.upstreamCredential, "upstream-provider-secret")
        XCTAssertEqual(binding.apiKey, "disposable-proxy-token")
        XCTAssertNotEqual(binding.apiKey, recorder.upstreamCredential)
        XCTAssertEqual(binding.baseURL.absoluteString, "http://127.0.0.1:54321/v1")
        XCTAssertEqual(binding.id, prepared.identity.modelProviderID)
        XCTAssertEqual(binding.stateIdentifier, prepared.identity.stateIdentifier)
        XCTAssertTrue(
            recorder.dynamicToolHandlerWasPassed,
            "The generic agent factory must install Onyx's provider-neutral delegation handler"
        )

        let shutdownTask = Task { await prepared.shutdown() }
        for _ in 0..<100 where recorder.events != ["proxy.stop"] {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            recorder.events,
            ["proxy.stop"],
            "The credential-injecting proxy must stop before a potentially hung app-server disconnect"
        )
        await runtime.releaseDisconnect()
        await shutdownTask.value
        await prepared.shutdown()
        XCTAssertEqual(recorder.proxyStopCount, 1)
        let disconnectCount = await runtime.disconnectCount()
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(recorder.events, ["proxy.stop", "runtime.disconnect"])
    }

    func testAgentFactoryRejectsProxyCredentialReuseAndStopsLease() async throws {
        let connection = try makeAdaptiveConnection(authMode: .bearer)
        let credentialStore = InMemoryCredentialStore()
        try await credentialStore.setCredential(
            ProviderBearerCredential("provider-secret"),
            for: connection.credentialKey
        )
        let recorder = AdaptiveFactoryRecorder()
        let factory = OpenAICompatibleAgentRuntimeFactory(
            credentialStore: credentialStore,
            proxyFactory: { _, _ in
                OpenAICompatibleAgentProxyLease(
                    baseURL: URL(string: "http://127.0.0.1:54321/v1")!,
                    disposableAPIKey: "provider-secret",
                    stop: { recorder.recordProxyStop() }
                )
            },
            runtimeFactory: { binding, _ in
                recorder.recordBinding(binding)
                return AdaptiveFactoryRuntime()
            }
        )

        do {
            _ = try await factory.prepare(connection: connection)
            XCTFail("App-server must never receive the provider credential")
        } catch let error as OpenAICompatibleAgentRuntimeFactoryError {
            XCTAssertEqual(error, .proxyCredentialReuse)
        }
        XCTAssertNil(recorder.binding)
        XCTAssertEqual(recorder.proxyStopCount, 1)
    }

    func testAgentFactoryIgnoresStaleStoredCredentialForUnauthenticatedConnection() async throws {
        let connection = try makeAdaptiveConnection(authMode: .none)
        let credentialStore = InMemoryCredentialStore()
        try await credentialStore.setCredential(
            ProviderBearerCredential("stale-secret-must-not-be-used"),
            for: connection.credentialKey
        )
        let recorder = AdaptiveFactoryRecorder()
        let runtime = AdaptiveFactoryRuntime()
        let factory = OpenAICompatibleAgentRuntimeFactory(
            credentialStore: credentialStore,
            proxyFactory: { _, credential in
                recorder.recordUpstreamCredential(try credential?.withValue { $0 })
                return OpenAICompatibleAgentProxyLease(
                    baseURL: URL(string: "http://127.0.0.1:54321/v1")!,
                    disposableAPIKey: "disposable-proxy-token",
                    stop: { recorder.recordProxyStop() }
                )
            },
            runtimeFactory: { _, _ in runtime }
        )

        let prepared = try await factory.prepare(connection: connection)
        XCTAssertNil(recorder.upstreamCredential)
        await prepared.shutdown()
    }

    private func resolveAfterProbe(
        resolver: OpenAICompatibleAdaptiveRuntimeResolver,
        connection: ProviderConnectionRecord,
        modelID: String
    ) async throws -> OpenAICompatibleRuntimeLaneDecision {
        try await resolver.beginProbe(connection: connection, modelID: modelID)
        return try await waitForResolvedProbe(
            resolver: resolver,
            connection: connection,
            modelID: modelID
        )
    }

    private func waitForResolvedProbe(
        resolver: OpenAICompatibleAdaptiveRuntimeResolver,
        connection: ProviderConnectionRecord,
        modelID: String
    ) async throws -> OpenAICompatibleRuntimeLaneDecision {
        for _ in 0..<100 {
            let decision = try await resolver.resolveNewTask(
                connection: connection,
                modelID: modelID
            )
            if decision.basis != .unavailableProbe { return decision }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try await resolver.resolveNewTask(connection: connection, modelID: modelID)
    }

    private func waitForProbeCalls(
        _ probe: AdaptiveLaneProbe,
        count: Int
    ) async throws {
        for _ in 0..<100 {
            let calls = await probe.modelsProbed()
            if calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(count) probe calls")
    }

    private static let compatibleEvidence = OpenAICompatibleResponsesProbeEvidence(
        usedServerSentEvents: true,
        receivedFunctionCall: true,
        submittedCorrelatedOutput: true,
        completedAfterFunctionOutput: true
    )
}

private func makeAdaptiveConnection(
    displayName: String = "Adaptive provider",
    baseURL: URL = URL(string: "https://provider.example.test/v1")!,
    authMode: ProviderConnectionAuthMode = .none,
    scopeID: String = "scope-before"
) throws -> ProviderConnectionRecord {
    try ProviderConnectionRecord(
        id: ProviderConnectionID("adaptive-provider"),
        displayName: displayName,
        baseURL: baseURL,
        selectedModelID: "agent-model",
        authMode: authMode,
        transportCapabilities: [.streaming],
        conversationScopeID: scopeID
    )
}

private func makeAdaptiveStateStore() -> OpenAICompatibleAdaptiveStateStore {
    OpenAICompatibleAdaptiveStateStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-adaptive-resolver-\(UUID().uuidString).json")
    )
}

private actor AdaptiveLaneProbe: OpenAICompatibleResponsesCompatibilityProbing {
    enum ProbeError: Error { case unavailable }

    private let outcomes: [String: OpenAICompatibleResponsesProbeOutcome]
    private let throwingModels: Set<String>
    private let delay: Duration?
    private let testedAt: Date
    private let cacheLifetime: TimeInterval
    private var calls: [String] = []

    init(
        outcomes: [String: OpenAICompatibleResponsesProbeOutcome],
        throwingModels: Set<String> = [],
        delay: Duration? = nil,
        testedAt: Date = Date(),
        cacheLifetime: TimeInterval = 60 * 60
    ) {
        self.outcomes = outcomes
        self.throwingModels = throwingModels
        self.delay = delay
        self.testedAt = testedAt
        self.cacheLifetime = cacheLifetime
    }

    func probe(
        connection: ProviderConnectionRecord,
        modelID: String
    ) async throws -> OpenAICompatibleResponsesProbeRecord {
        calls.append(modelID)
        if let delay { try await Task.sleep(for: delay) }
        if throwingModels.contains(modelID) { throw ProbeError.unavailable }
        return OpenAICompatibleResponsesProbeRecord(
            fingerprint: OpenAICompatibleResponsesProbeFingerprint(
                connection: connection,
                modelID: modelID
            ),
            testedAt: testedAt,
            expiresAt: testedAt.addingTimeInterval(cacheLifetime),
            outcome: outcomes[modelID] ?? .failed(.missingFunctionCall)
        )
    }

    func modelsProbed() -> [String] { calls }
}

private final class AdaptiveFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBinding: CodexRuntimeModelProviderBinding?
    private var storedUpstreamCredential: String?
    private var storedProxyStopCount = 0
    private var storedEvents: [String] = []
    private var storedDynamicToolHandlerWasPassed = false

    var binding: CodexRuntimeModelProviderBinding? {
        lock.withLock { storedBinding }
    }

    var upstreamCredential: String? {
        lock.withLock { storedUpstreamCredential }
    }

    var proxyStopCount: Int {
        lock.withLock { storedProxyStopCount }
    }

    var events: [String] {
        lock.withLock { storedEvents }
    }

    var dynamicToolHandlerWasPassed: Bool {
        lock.withLock { storedDynamicToolHandlerWasPassed }
    }

    func recordBinding(_ binding: CodexRuntimeModelProviderBinding) {
        lock.withLock { storedBinding = binding }
    }

    func recordUpstreamCredential(_ credential: String?) {
        lock.withLock { storedUpstreamCredential = credential }
    }

    func recordProxyStop() {
        lock.withLock {
            storedProxyStopCount += 1
            storedEvents.append("proxy.stop")
        }
    }

    func recordRuntimeDisconnect() {
        lock.withLock { storedEvents.append("runtime.disconnect") }
    }

    func recordDynamicToolHandler(_ handler: (any CodexDynamicToolHandler)?) {
        lock.withLock { storedDynamicToolHandlerWasPassed = handler != nil }
    }
}

private struct AdaptiveFactoryDynamicToolHandler: CodexDynamicToolHandler {
    func handleDynamicToolCall(
        _: CodexDynamicToolCall
    ) async throws -> CodexDynamicToolResult {
        .failed("fixture")
    }
}

private actor AdaptiveFactoryRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events = AsyncStream<AgentRuntimeEvent> { $0.finish() }
    private let recorder: AdaptiveFactoryRecorder?
    private let blocksDisconnect: Bool
    private var disconnectWaiter: CheckedContinuation<Void, Never>?
    private var disconnects = 0

    init(
        recorder: AdaptiveFactoryRecorder? = nil,
        blocksDisconnect: Bool = false
    ) {
        self.recorder = recorder
        self.blocksDisconnect = blocksDisconnect
    }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
            runtime: .codex,
            displayName: "Fixture agent runtime",
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

    func disconnect() async {
        disconnects += 1
        if blocksDisconnect {
            await withCheckedContinuation { continuation in
                disconnectWaiter = continuation
            }
        }
        recorder?.recordRuntimeDisconnect()
    }

    func releaseDisconnect() {
        disconnectWaiter?.resume()
        disconnectWaiter = nil
    }
    func disconnectCount() -> Int { disconnects }
    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] { [] }
    func readThread(id _: String) async throws -> RuntimeConversation {
        throw AgentRuntimeError.unsupported("fixture")
    }
    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("fixture")
    }
    func startTurn(_: StartTurnRequest) async throws {}
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
}
