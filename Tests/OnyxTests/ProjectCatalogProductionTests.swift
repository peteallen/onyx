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
        let conversations = OpenAICompatibleConversationStore(fileURL: conversationFile)
        for index in 0 ..< 125 {
            _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
                id: "local-" + String(index),
                connectionID: providerID,
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
    private var allCalls: [Bool] = []

    init(
        active: [RuntimeThread],
        archived: [RuntimeThread],
        failArchived: Bool
    ) {
        self.active = active
        self.archived = archived
        self.failArchived = failArchived
        let pair = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = pair.stream
        eventContinuation = pair.continuation
    }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
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
