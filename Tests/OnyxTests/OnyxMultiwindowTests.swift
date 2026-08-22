import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxMultiwindowTests: XCTestCase {
    func testWindowIdentityRoundTripsWithStableDistinctNamespaces() throws {
        let first = WorkspaceWindowID(
            rawValue: try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        )
        let second = WorkspaceWindowID(
            rawValue: try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        )

        let encoded = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceWindowID.self, from: encoded), first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.preferenceKeyPrefix, "Onyx.window.11111111-1111-4111-8111-111111111111")
        XCTAssertNotEqual(first.preferenceKeyPrefix, second.preferenceKeyPrefix)
        XCTAssertNotEqual(first.frameAutosaveName, second.frameAutosaveName)
    }

    func testHostCreatesDistinctWindowModelsOnOneRuntimeAndBroadcastsEveryEvent() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let runtime = MultiwindowFakeRuntime(threads: Self.threads)
        let factoryProbe = MultiwindowFactoryProbe()
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: .init("test.multiwindow"), displayName: "Test") { _ in
                    factoryProbe.record()
                    return runtime
                },
            ],
            connections: [
                RuntimeConnectionRegistration(
                    id: .init("test.multiwindow.primary"),
                    adapterID: .init("test.multiwindow")
                ),
            ]
        )
        let host = OnyxApplicationHost(
            registry: registry,
            connectionID: .init("test.multiwindow.primary"),
            defaults: suite.defaults
        )
        let first = host.makeWindowModel(for: WorkspaceWindowID())
        let second = host.makeWindowModel(for: WorkspaceWindowID())

        XCTAssertFalse(first === second)
        XCTAssertFalse(first === host.settingsModel)
        XCTAssertEqual(factoryProbe.count, 1)

        first.start()
        second.start()
        await waitUntil("Both windows did not connect") {
            first.connectionState == .connected("Test runtime")
                && second.connectionState == .connected("Test runtime")
                && !first.isLoadingThreadList
                && !second.isLoadingThreadList
        }

        let connectCount = await runtime.connectCount()
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(runtime.eventStreamAccessCount, 1)

        await runtime.emit(.runtimeNotice(title: "Shared event", detail: "Delivered to every window"))
        await waitUntil("The shared event did not reach both windows") {
            first.notice?.title == "Shared event" && second.notice?.title == "Shared event"
        }
        XCTAssertEqual(first.notice?.detail, "Delivered to every window")
        XCTAssertEqual(second.notice?.detail, "Delivered to every window")
    }

    func testWindowModelsRestoreSelectionDraftWorkspaceAndPanelsIndependently() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let firstID = WorkspaceWindowID(
            rawValue: try XCTUnwrap(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        )
        let secondID = WorkspaceWindowID(
            rawValue: try XCTUnwrap(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        )
        let firstNamespace = OnyxPreferenceNamespace(prefix: firstID.preferenceKeyPrefix)
        let secondNamespace = OnyxPreferenceNamespace(prefix: secondID.preferenceKeyPrefix)

        seedWindow(
            defaults: suite.defaults,
            namespace: firstNamespace,
            selectedThreadID: Self.threadA.id,
            draft: "Draft in window A",
            workspace: "/projects/a",
            sidebarVisible: false,
            inspectorVisible: true,
            bottomPanelVisible: true
        )
        seedWindow(
            defaults: suite.defaults,
            namespace: secondNamespace,
            selectedThreadID: Self.threadB.id,
            draft: "Draft in window B",
            workspace: "/projects/b",
            sidebarVisible: true,
            inspectorVisible: false,
            bottomPanelVisible: false
        )
        suite.defaults.set([Self.threadA.id], forKey: "Onyx.pinnedThreadIDs")

        let coordinator = SharedRuntimeCoordinator(runtime: MultiwindowFakeRuntime(threads: Self.threads))
        let first = OnyxAppModel(
            runtime: coordinator,
            defaults: suite.defaults,
            preferenceKeyPrefix: firstID.preferenceKeyPrefix
        )
        let second = OnyxAppModel(
            runtime: coordinator,
            defaults: suite.defaults,
            preferenceKeyPrefix: secondID.preferenceKeyPrefix
        )
        first.start()
        second.start()

        await waitUntil("Window-specific selections and drafts were not restored") {
            first.selectedThreadID == Self.threadA.id
                && second.selectedThreadID == Self.threadB.id
                && first.composerText == "Draft in window A"
                && second.composerText == "Draft in window B"
        }

        XCTAssertEqual(first.draftWorkspacePath, "/projects/a")
        XCTAssertEqual(second.draftWorkspacePath, "/projects/b")
        XCTAssertFalse(first.isSidebarVisible)
        XCTAssertTrue(second.isSidebarVisible)
        XCTAssertTrue(first.isInspectorVisible)
        XCTAssertFalse(second.isInspectorVisible)
        XCTAssertTrue(first.isBottomPanelVisible)
        XCTAssertFalse(second.isBottomPanelVisible)
        XCTAssertEqual(first.threads.first(where: { $0.id == Self.threadA.id })?.isPinned, true)
        XCTAssertEqual(second.threads.first(where: { $0.id == Self.threadA.id })?.isPinned, true)
    }

    func testSharedPinnedThreadStorePublishesEveryWindowMutationWithoutLostPins() async {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let pinnedThreadStore = OnyxPinnedThreadStore(defaults: suite.defaults)
        let coordinator = SharedRuntimeCoordinator(runtime: MultiwindowFakeRuntime(threads: Self.threads))
        let first = OnyxAppModel(
            runtime: coordinator,
            defaults: suite.defaults,
            preferenceKeyPrefix: WorkspaceWindowID().preferenceKeyPrefix,
            pinnedThreadStore: pinnedThreadStore
        )
        let second = OnyxAppModel(
            runtime: coordinator,
            defaults: suite.defaults,
            preferenceKeyPrefix: WorkspaceWindowID().preferenceKeyPrefix,
            pinnedThreadStore: pinnedThreadStore
        )
        first.start()
        second.start()

        await waitUntil("Both windows did not load the shared task list") {
            first.threads.contains(where: { $0.id == Self.threadA.id })
                && second.threads.contains(where: { $0.id == Self.threadB.id })
        }

        first.togglePin(Self.threadA.id)
        await waitUntil("Window B did not observe window A's pin") {
            first.threads.first(where: { $0.id == Self.threadA.id })?.isPinned == true
                && second.threads.first(where: { $0.id == Self.threadA.id })?.isPinned == true
        }

        second.togglePin(Self.threadB.id)
        await waitUntil("The second pin overwrote the first pin in one of the windows") {
            [first, second].allSatisfy { model in
                model.threads.first(where: { $0.id == Self.threadA.id })?.isPinned == true
                    && model.threads.first(where: { $0.id == Self.threadB.id })?.isPinned == true
            }
        }

        XCTAssertEqual(pinnedThreadStore.ids, Set([Self.threadA.id, Self.threadB.id]))
        XCTAssertEqual(
            Set(suite.defaults.stringArray(forKey: "Onyx.pinnedThreadIDs") ?? []),
            Set([Self.threadA.id, Self.threadB.id])
        )
    }

    func testFlushWindowStateImmediatelyPersistsNewestComposerDraft() {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let windowID = WorkspaceWindowID()
        let namespace = OnyxPreferenceNamespace(prefix: windowID.preferenceKeyPrefix)
        let draftsKey = namespace.key("Onyx.composerDrafts")
        suite.defaults.set(["onyx:welcome": "Older draft"], forKey: draftsKey)
        let model = OnyxAppModel(
            runtime: nil,
            defaults: suite.defaults,
            preferenceKeyPrefix: windowID.preferenceKeyPrefix
        )

        let newestDraft = "Newest text typed immediately before closing"
        model.composerText = newestDraft
        model.flushWindowState()

        let persistedDrafts = suite.defaults.dictionary(forKey: draftsKey) as? [String: String]
        XCTAssertEqual(persistedDrafts?["onyx:welcome"], newestDraft)
        let restored = OnyxAppModel(
            runtime: nil,
            defaults: suite.defaults,
            preferenceKeyPrefix: windowID.preferenceKeyPrefix
        )
        XCTAssertEqual(restored.composerText, newestDraft)
    }

    func testTerminalDrawerLayoutClampsCorruptRestoredHeights() {
        XCTAssertEqual(
            TerminalDrawerLayout.clampedHeight(-10_000),
            TerminalDrawerLayout.minimumHeight
        )
        XCTAssertEqual(
            TerminalDrawerLayout.clampedHeight(10_000),
            TerminalDrawerLayout.maximumHeight
        )
    }

    func testSuccessfulLoginCompletionRefreshesEveryWindowNotOnlyTheSettingsOwner() async {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let signedIn = RuntimeAuthState(
            mode: .chatgpt,
            email: "person@example.com",
            planLabel: "plus",
            requiresAuthentication: true
        )
        let runtime = MultiwindowFakeRuntime(
            threads: [],
            connectAuth: .signedOut,
            refreshAuth: signedIn
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let first = OnyxAppModel(
            runtime: coordinator,
            defaults: suite.defaults,
            preferenceKeyPrefix: WorkspaceWindowID().preferenceKeyPrefix
        )
        let second = OnyxAppModel(
            runtime: coordinator,
            defaults: suite.defaults,
            preferenceKeyPrefix: WorkspaceWindowID().preferenceKeyPrefix
        )
        first.start()
        second.start()
        await waitUntil("Both windows did not reach the signed-out state") {
            first.connectionState == .connected("Test runtime")
                && second.connectionState == .connected("Test runtime")
                && !first.authState.isSignedIn
                && !second.authState.isSignedIn
        }

        await runtime.emit(
            .loginCompleted(
                RuntimeLoginCompletion(loginID: "settings-login", success: true, error: nil)
            )
        )
        await waitUntil("The successful login did not refresh every window") {
            first.authState == signedIn && second.authState == signedIn
        }
    }

    func testFocusedWindowCommandOnlyMutatesItsWindowModel() {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let first = OnyxAppModel(
            runtime: nil,
            defaults: suite.defaults,
            preferenceKeyPrefix: WorkspaceWindowID().preferenceKeyPrefix
        )
        let second = OnyxAppModel(
            runtime: nil,
            defaults: suite.defaults,
            preferenceKeyPrefix: WorkspaceWindowID().preferenceKeyPrefix
        )
        let firstCommands = OnyxWindowCommandContext.workspace(
            model: first,
            windowProvider: { nil },
            focusTaskSearch: {}
        )

        XCTAssertFalse(first.isBottomPanelVisible)
        XCTAssertFalse(second.isBottomPanelVisible)
        firstCommands.toggleTerminal()
        XCTAssertTrue(first.isBottomPanelVisible)
        XCTAssertFalse(second.isBottomPanelVisible)
    }

    private func seedWindow(
        defaults: UserDefaults,
        namespace: OnyxPreferenceNamespace,
        selectedThreadID: String,
        draft: String,
        workspace: String,
        sidebarVisible: Bool,
        inspectorVisible: Bool,
        bottomPanelVisible: Bool
    ) {
        defaults.set(selectedThreadID, forKey: namespace.key("Onyx.selectedThreadID"))
        defaults.set([selectedThreadID: draft], forKey: namespace.key("Onyx.composerDrafts"))
        defaults.set(workspace, forKey: namespace.key("Onyx.lastWorkspacePath"))
        defaults.set(sidebarVisible, forKey: namespace.key("Onyx.sidebarVisible"))
        defaults.set(inspectorVisible, forKey: namespace.key("Onyx.inspectorVisible"))
        defaults.set(bottomPanelVisible, forKey: namespace.key("Onyx.bottomPanelVisible"))
    }

    private func makeDefaults() -> (defaults: UserDefaults, cleanUp: () -> Void) {
        let suiteName = "OnyxMultiwindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private static let threadA = RuntimeThread(
        id: "thread-a",
        title: "Window A task",
        preview: "A",
        cwd: "/projects/a",
        updatedAt: Date(timeIntervalSince1970: 2),
        status: .idle,
        isPinned: false,
        runtime: .local,
        model: nil,
        branch: nil
    )

    private static let threadB = RuntimeThread(
        id: "thread-b",
        title: "Window B task",
        preview: "B",
        cwd: "/projects/b",
        updatedAt: Date(timeIntervalSince1970: 1),
        status: .idle,
        isPinned: false,
        runtime: .local,
        model: nil,
        branch: nil
    )

    private static let threads = [threadA, threadB]
}

private final class MultiwindowFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}

private actor MultiwindowFakeRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.local
    nonisolated var events: AsyncStream<AgentRuntimeEvent> {
        eventProbe.record()
        return eventStream
    }
    nonisolated var eventStreamAccessCount: Int { eventProbe.count }

    private nonisolated let eventStream: AsyncStream<AgentRuntimeEvent>
    private nonisolated let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private nonisolated let eventProbe = MultiwindowFactoryProbe()
    private let threads: [RuntimeThread]
    private let connectAuth: RuntimeAuthState
    private let refreshAuth: RuntimeAuthState
    private var recordedConnectCount = 0

    init(
        threads: [RuntimeThread],
        connectAuth: RuntimeAuthState? = nil,
        refreshAuth: RuntimeAuthState? = nil
    ) {
        let fallbackAuth = RuntimeAuthState(
            mode: nil,
            email: nil,
            planLabel: nil,
            requiresAuthentication: false
        )
        self.threads = threads
        self.connectAuth = connectAuth ?? fallbackAuth
        self.refreshAuth = refreshAuth ?? connectAuth ?? fallbackAuth
        let pair = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func connectCount() -> Int { recordedConnectCount }

    func connect() async throws -> RuntimeSession {
        recordedConnectCount += 1
        return session(auth: connectAuth)
    }

    func refreshAccount() async throws -> RuntimeSession {
        session(auth: refreshAuth)
    }

    private func session(auth: RuntimeAuthState) -> RuntimeSession {
        return RuntimeSession(
            runtime: .local,
            displayName: "Test runtime",
            accountLabel: nil,
            planLabel: nil,
            auth: auth,
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : threads
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        guard let thread = threads.first(where: { $0.id == id }) else {
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
}
