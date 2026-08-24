import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ProjectCatalogProductionTests: XCTestCase {
    func testHostLoadsCompleteCodexCatalogWithoutImportingTaskFolders() async throws {
        let defaults = try makeDefaults()
        defer { defaults.cleanUp() }
        let location = temporaryLocation("codex")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let active = makeThreads(count: 125, path: "/work/onyx")
        let archived = [makeThread(id: "archived-task", path: "/work/onyx")]
        let runtime = CatalogRuntime(
            active: active,
            archived: archived,
            failArchived: true
        )
        let adapterID = RuntimeAdapterID("test.catalog.codex")
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: adapterID, displayName: "Catalog test") { _ in
                    runtime
                },
            ],
            connections: [
                RuntimeConnectionRegistration(
                    id: .codexDefault,
                    adapterID: adapterID
                ),
            ]
        )
        let host = OnyxApplicationHost(
            registry: registry,
            defaults: defaults.defaults,
            projectCatalogStore: ProjectCatalogStore(fileURL: location.file),
            providerCredentialStore: InMemoryCredentialStore()
        )
        let connections = [
            OnyxApplicationHost.WorkspaceConnection(
                id: .codexDefault,
                displayName: "Codex",
                isCodex: true
            ),
        ]

        let incomplete = await host.loadProviderTaskCatalog(connections: connections)
        XCTAssertFalse(incomplete.sourceComplete)
        XCTAssertEqual(
            incomplete.lists.first(where: { $0.scope == .active })?.threads.count,
            active.count,
            "A successful Codex page must not be capped at the old 100-row UI limit"
        )
        let incompleteSnapshot = try await ProjectCatalogStore(fileURL: location.file).snapshot()
        XCTAssertTrue(incompleteSnapshot.projects.isEmpty)

        await runtime.setFailArchived(false)
        let complete = await host.loadProviderTaskCatalog(connections: connections)
        XCTAssertTrue(complete.sourceComplete)
        XCTAssertEqual(
            complete.lists.first(where: { $0.scope == .archived })?.threads.count,
            archived.count
        )
        XCTAssertTrue(host.projectCatalogModel.projects.isEmpty)
        let calls = await runtime.listAllCalls()
        XCTAssertEqual(calls, [false, true, false, true])

        // Repeated complete history loads still cannot turn task working
        // directories into app-owned projects.
        _ = await host.loadProviderTaskCatalog(connections: connections)
        XCTAssertTrue(host.projectCatalogModel.projects.isEmpty)
        let finalSnapshot = try await ProjectCatalogStore(fileURL: location.file).snapshot()
        XCTAssertTrue(finalSnapshot.projects.isEmpty)
        XCTAssertFalse(finalSnapshot.didBootstrapConversationProjects)
    }

    func testHostLoadsEveryLocalConversationWithoutImportingTaskFolders() async throws {
        let defaults = try makeDefaults()
        defer { defaults.cleanUp() }
        let location = temporaryLocation("local")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let conversationFile = location.directory.appendingPathComponent("conversations.json")
        let providerID = ProviderConnectionID("local.catalog")
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let providerRecord = try ProviderConnectionRecord(
            id: providerID,
            displayName: "Local catalog",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            discovery: ProviderConnectionDiscoveryMetadata(
                discoveredModelIDs: ["fixture-model"]
            )
        )
        try await connectionStore.upsert(providerRecord)
        let conversations = OpenAICompatibleConversationStore(fileURL: conversationFile)
        for index in 0 ..< 125 {
            _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
                id: "local-" + String(index),
                connectionID: providerID,
                conversationScopeID: providerRecord.conversationScopeID,
                title: "Local " + String(index),
                cwd: "/work/local",
                modelID: "fixture-model",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            ))
        }
        let directConversationCount = try await conversations.conversations(
            connectionID: providerID,
            archived: false,
            limit: Int.max
        ).count
        XCTAssertEqual(directConversationCount, 125)

        let host = OnyxApplicationHost(
            registry: try RuntimeRegistry(providers: [], connections: []),
            defaults: defaults.defaults,
            projectCatalogStore: ProjectCatalogStore(fileURL: location.file),
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: conversations
        )
        let connection = OnyxApplicationHost.WorkspaceConnection(
            id: providerID,
            displayName: "Local catalog",
            isCodex: false
        )

        let catalog = await host.loadProviderTaskCatalog(connections: [connection])
        XCTAssertTrue(catalog.sourceComplete)
        XCTAssertEqual(
            catalog.lists.first(where: { $0.scope == .active })?.threads.count,
            125
        )
        XCTAssertTrue(host.projectCatalogModel.projects.isEmpty)
    }

    func testHostLoadsMergedAdaptiveCatalogInsteadOfReplacingAgentTasksWithChatOnlyHistory() async throws {
        let defaults = try makeDefaults()
        defer { defaults.cleanUp() }
        let location = temporaryLocation("adaptive-provider")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let providerID = ProviderConnectionID("local.catalog.adaptive")
        let modelID = "fixture-model"
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let connection = try ProviderConnectionRecord(
            id: providerID,
            displayName: "Adaptive catalog",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: modelID,
            authMode: .none,
            discovery: ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: Date(timeIntervalSince1970: 10),
                lastSucceededAt: Date(timeIntervalSince1970: 11),
                discoveredModelIDs: [modelID]
            )
        )
        try await connectionStore.upsert(connection)

        let conversations = OpenAICompatibleConversationStore(
            fileURL: location.directory.appendingPathComponent("conversations.json")
        )
        _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
            id: "chat-task",
            connectionID: providerID,
            conversationScopeID: connection.conversationScopeID,
            title: "Chat task",
            cwd: "/work/chat",
            modelID: modelID,
            updatedAt: Date(timeIntervalSince1970: 20)
        ))
        let stateStore = OpenAICompatibleAdaptiveStateStore(
            fileURL: location.directory.appendingPathComponent("adaptive-state.json")
        )
        _ = try await stateStore.recordTaskOwnership(
            connectionID: providerID,
            conversationScopeID: connection.conversationScopeID,
            threadID: "chat-task",
            lane: .chat,
            modelID: modelID,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        _ = try await stateStore.recordTaskOwnership(
            connectionID: providerID,
            conversationScopeID: connection.conversationScopeID,
            threadID: "agent-task",
            lane: .agent,
            modelID: modelID,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let adaptiveRuntime = CatalogRuntime(
            active: [
                makeThread(id: "chat-task", path: "/work/chat"),
                makeThread(id: "agent-task", path: "/work/agent"),
            ],
            archived: [],
            failArchived: false
        )
        let adapterID = RuntimeAdapterID("test.catalog.adaptive")
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: adapterID, displayName: "Adaptive catalog") { _ in
                    adaptiveRuntime
                },
            ],
            connections: [
                RuntimeConnectionRegistration(id: providerID, adapterID: adapterID),
            ]
        )

        let host = OnyxApplicationHost(
            registry: registry,
            defaults: defaults.defaults,
            projectCatalogStore: ProjectCatalogStore(fileURL: location.file),
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: conversations,
            providerAdaptiveStateStore: stateStore
        )
        let catalog = await host.loadProviderTaskCatalog(connections: [
            .init(id: providerID, displayName: "Adaptive catalog", isCodex: false),
        ])

        XCTAssertTrue(catalog.sourceComplete)
        XCTAssertEqual(
            catalog.lists.first(where: { $0.scope == .active })?.threads.map(\.id),
            ["chat-task", "agent-task"]
        )
        XCTAssertNotNil(
            host.cachedRuntimeCoordinatorForTesting(providerID),
            "Provider catalog refresh must read through the shared adaptive coordinator"
        )
    }

    func testAdaptiveCatalogFailureKeepsScopedChatRowsVisibleAsPartialSnapshot() async throws {
        let defaults = try makeDefaults()
        defer { defaults.cleanUp() }
        let location = temporaryLocation("adaptive-offline-fallback")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let providerID = ProviderConnectionID("local.catalog.offline")
        let modelID = "fixture-model"
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let connection = try ProviderConnectionRecord(
            id: providerID,
            displayName: "Offline adaptive catalog",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: modelID,
            authMode: .none,
            discovery: ProviderConnectionDiscoveryMetadata(
                discoveredModelIDs: [modelID]
            )
        )
        try await connectionStore.upsert(connection)

        let conversations = OpenAICompatibleConversationStore(
            fileURL: location.directory.appendingPathComponent("conversations.json")
        )
        _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
            id: "offline-chat",
            connectionID: providerID,
            conversationScopeID: connection.conversationScopeID,
            title: "Offline chat remains available",
            cwd: "/work/offline",
            modelID: modelID,
            updatedAt: Date(timeIntervalSince1970: 20)
        ))
        _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
            id: "offline-archived-chat",
            connectionID: providerID,
            conversationScopeID: connection.conversationScopeID,
            title: "Offline archived chat remains available",
            cwd: "/work/offline",
            modelID: modelID,
            updatedAt: Date(timeIntervalSince1970: 19),
            isArchived: true
        ))
        let stateStore = OpenAICompatibleAdaptiveStateStore(
            fileURL: location.directory.appendingPathComponent("adaptive-state.json")
        )
        _ = try await stateStore.recordTaskOwnership(
            connectionID: providerID,
            conversationScopeID: connection.conversationScopeID,
            threadID: "agent-task",
            lane: .agent,
            modelID: modelID,
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        // The provider has already entered the adaptive era, but its merged
        // runtime is unavailable. The local chat transcript must remain
        // visible while the catalog truthfully reports that agent rows are
        // missing and should be retried later.
        let unavailableRuntime = CatalogRuntime(
            active: [],
            archived: [],
            failArchived: false,
            failConnect: true
        )
        let adapterID = RuntimeAdapterID("test.catalog.offline")
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: adapterID, displayName: "Offline adaptive") { _ in
                    unavailableRuntime
                },
            ],
            connections: [
                RuntimeConnectionRegistration(id: providerID, adapterID: adapterID),
            ]
        )
        let host = OnyxApplicationHost(
            registry: registry,
            defaults: defaults.defaults,
            projectCatalogStore: ProjectCatalogStore(fileURL: location.file),
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: conversations,
            providerAdaptiveStateStore: stateStore
        )

        let catalog = await host.loadProviderTaskCatalog(connections: [
            .init(id: providerID, displayName: "Offline adaptive", isCodex: false),
        ])

        XCTAssertFalse(catalog.sourceComplete)
        XCTAssertEqual(
            catalog.lists.first(where: { $0.scope == .active })?.threads.map(\.id),
            ["offline-chat"]
        )
        XCTAssertTrue(
            catalog.lists.allSatisfy { $0.threads.allSatisfy { $0.id != "agent-task" } },
            "Agent rows are unavailable, but their absence must not erase local chat history"
        )

        // A reconnect can succeed while one merged scope fails. The failed
        // scope gets the same bounded local fallback without duplicating the
        // successful scope's app-server rows.
        await unavailableRuntime.setFailConnect(false)
        await unavailableRuntime.setFailArchived(true)
        let partial = await host.loadProviderTaskCatalog(connections: [
            .init(id: providerID, displayName: "Offline adaptive", isCodex: false),
        ])
        XCTAssertFalse(partial.sourceComplete)
        XCTAssertEqual(
            partial.lists.first(where: { $0.scope == .archived })?.threads.map(\.id),
            ["offline-archived-chat"]
        )
    }

    func testUnreadableAdaptiveOwnershipKeepsScopedChatRowsVisibleAsPartialSnapshot() async throws {
        let defaults = try makeDefaults()
        defer { defaults.cleanUp() }
        let location = temporaryLocation("adaptive-unreadable-state")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let providerID = ProviderConnectionID("local.catalog.unreadable-state")
        let modelID = "fixture-model"
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let connection = try ProviderConnectionRecord(
            id: providerID,
            displayName: "Unreadable adaptive state",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: modelID,
            authMode: .none
        )
        try await connectionStore.upsert(connection)

        let conversations = OpenAICompatibleConversationStore(
            fileURL: location.directory.appendingPathComponent("conversations.json")
        )
        _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
            id: "preserved-chat",
            connectionID: providerID,
            conversationScopeID: connection.conversationScopeID,
            title: "Preserved chat",
            cwd: "/work/preserved",
            modelID: modelID,
            updatedAt: Date(timeIntervalSince1970: 20)
        ))

        let stateURL = location.directory.appendingPathComponent("adaptive-state.json")
        try Data("not valid adaptive state".utf8).write(to: stateURL)
        let host = OnyxApplicationHost(
            registry: try RuntimeRegistry(providers: [], connections: []),
            defaults: defaults.defaults,
            projectCatalogStore: ProjectCatalogStore(fileURL: location.file),
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: conversations,
            providerAdaptiveStateStore: OpenAICompatibleAdaptiveStateStore(fileURL: stateURL)
        )

        let catalog = await host.loadProviderTaskCatalog(connections: [
            .init(id: providerID, displayName: "Unreadable adaptive state", isCodex: false),
        ])

        XCTAssertFalse(catalog.sourceComplete)
        XCTAssertEqual(
            catalog.lists.first(where: { $0.scope == .active })?.threads.map(\.id),
            ["preserved-chat"]
        )
    }

    func testWorkspaceModelListsAndOpensTaskBeyondFormerHundredRowCap() async throws {
        let defaults = try makeDefaults()
        defer { defaults.cleanUp() }
        let tasks = makeThreads(count: 125, path: "/work/large-project")
        let runtime = CatalogRuntime(active: tasks, archived: [], failArchived: false)
        let model = OnyxAppModel(
            runtime: SharedRuntimeCoordinator(runtime: runtime),
            defaults: defaults.defaults
        )

        model.start()
        await waitUntil {
            !model.isLoadingThreadList
                && model.threads.contains(where: { $0.id == "task-124" })
        }
        XCTAssertEqual(model.threads.filter { $0.id != "onyx:welcome" }.count, 125)

        model.selectThread("task-124")
        await waitUntil {
            model.selectedThreadID == "task-124" && !model.isLoadingThread
        }
        XCTAssertEqual(model.selectedThread?.cwd, "/work/large-project")
    }

    func testUnreadableProviderConfigurationCannotCommitMigrationMarker() async throws {
        let defaults = try makeDefaults()
        defer { defaults.cleanUp() }
        let location = temporaryLocation("unreadable-connections")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let runtime = CatalogRuntime(
            active: [makeThread(id: "codex-task", path: "/work/codex")],
            archived: [],
            failArchived: false
        )
        let adapterID = RuntimeAdapterID("test.catalog.connection-source")
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: adapterID, displayName: "Catalog test") { _ in
                    runtime
                },
            ],
            connections: [
                RuntimeConnectionRegistration(id: .codexDefault, adapterID: adapterID),
            ]
        )
        let host = OnyxApplicationHost(
            registry: registry,
            defaults: defaults.defaults,
            projectCatalogStore: ProjectCatalogStore(fileURL: location.file),
            providerConnectionStore: ProviderConnectionStore(
                storage: FailingProviderConnectionStorage()
            ),
            providerCredentialStore: InMemoryCredentialStore()
        )

        let connections = await host.workspaceConnectionCatalog()
        XCTAssertFalse(connections.sourceComplete)
        XCTAssertEqual(connections.connections.map(\.id), [.codexDefault])

        let tasks = await host.loadProviderTaskCatalog(
            connections: connections.connections,
            connectionSourceComplete: connections.sourceComplete
        )
        let snapshot = try await ProjectCatalogStore(fileURL: location.file).snapshot()
        XCTAssertFalse(tasks.sourceComplete)
        XCTAssertFalse(snapshot.didBootstrapConversationProjects)
        XCTAssertTrue(snapshot.projects.isEmpty)
    }
}

private struct FailingProviderConnectionStorage: ProviderConnectionStorage {
    struct ReadFailure: Error {}

    func read() throws -> Data? { throw ReadFailure() }
    func write(_: Data) throws { throw ReadFailure() }
}

private actor CatalogRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind = .codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let active: [RuntimeThread]
    private let archived: [RuntimeThread]
    private var failArchived: Bool
    private var failConnect: Bool
    private var allCalls: [Bool] = []

    init(
        active: [RuntimeThread],
        archived: [RuntimeThread],
        failArchived: Bool,
        failConnect: Bool = false
    ) {
        self.active = active
        self.archived = archived
        self.failArchived = failArchived
        self.failConnect = failConnect
        let pair = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = pair.stream
        eventContinuation = pair.continuation
    }

    func connect() async throws -> RuntimeSession {
        if failConnect {
            throw AgentRuntimeError.protocolFailure("adaptive runtime unavailable")
        }
        return RuntimeSession(
            runtime: .codex,
            displayName: "Catalog test",
            accountLabel: "catalog@test",
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: .chatgpt,
                email: "catalog@test",
                planLabel: nil,
                requiresAuthentication: true
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )
    }

    func disconnect() async {}

    func listThreads(limit: Int, archived: Bool) async throws -> [RuntimeThread] {
        let source = archived ? self.archived : active
        return Array(source.prefix(max(0, min(limit, 100))))
    }

    func listAllThreads(archived: Bool) async throws -> [RuntimeThread] {
        allCalls.append(archived)
        if archived && failArchived {
            throw AgentRuntimeError.protocolFailure("archived source unavailable")
        }
        return archived ? self.archived : active
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        guard let thread = (active + archived).first(where: { $0.id == id }) else {
            throw AgentRuntimeError.missingField("thread")
        }
        return RuntimeConversation(thread: thread, items: [])
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("test thread creation")
    }

    func startTurn(_: StartTurnRequest) async throws {}
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(to _: RuntimeRequestID, with _: RuntimeUserInteractionResponse) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    func setFailArchived(_ value: Bool) {
        failArchived = value
    }

    func setFailConnect(_ value: Bool) {
        failConnect = value
    }

    func listAllCalls() -> [Bool] {
        allCalls
    }
}

private extension ProjectCatalogProductionTests {
    struct DefaultsFixture {
        let defaults: UserDefaults
        let suiteName: String

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func makeDefaults() throws -> DefaultsFixture {
        let suiteName = "OnyxProjectCatalogProduction-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "OnyxTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return DefaultsFixture(defaults: defaults, suiteName: suiteName)
    }

    func temporaryLocation(_ label: String) -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxProjectCatalog-\(label)-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("projects.json"))
    }

    func makeThreads(count: Int, path: String) -> [RuntimeThread] {
        (0 ..< count).map { index in
            makeThread(id: "task-\(index)", path: path, updatedAt: TimeInterval(index))
        }
    }

    func makeThread(
        id: String,
        path: String,
        updatedAt: TimeInterval = 1
    ) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: id,
            preview: "Preview for \(id)",
            cwd: path,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: nil,
            branch: nil
        )
    }

    func waitUntil(
        attempts: Int = 200,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0 ..< attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
