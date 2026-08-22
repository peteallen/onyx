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

    func testProviderWindowIdentityPersistsConnectionAndScopesTaskPreferences() throws {
        let providerID = ProviderConnectionID("local.qwen.primary")
        let window = WorkspaceWindowID(
            rawValue: try XCTUnwrap(UUID(uuidString: "33333333-3333-4333-8333-333333333333")),
            providerConnectionID: providerID
        )

        let encoded = try JSONEncoder().encode(window)
        let restored = try JSONDecoder().decode(WorkspaceWindowID.self, from: encoded)

        XCTAssertEqual(restored.providerConnectionID, providerID)
        XCTAssertEqual(
            restored.providerPreferenceKeyPrefix(),
            "Onyx.window.33333333-3333-4333-8333-333333333333.provider.bG9jYWwucXdlbi5wcmltYXJ5"
        )
        XCTAssertNotEqual(restored.providerPreferenceKeyPrefix(), restored.preferenceKeyPrefix)

        let legacy = try JSONEncoder().encode(window.rawValue)
        let migrated = try JSONDecoder().decode(WorkspaceWindowID.self, from: legacy)
        XCTAssertEqual(migrated.rawValue, window.rawValue)
        XCTAssertNil(migrated.providerConnectionID)
    }

    func testProviderModelUsageRanksFrequencyThenRecency() throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let host = OnyxApplicationHost(defaults: suite.defaults)
        let connection = OnyxApplicationHost.WorkspaceConnection(
            id: ProviderConnectionID("local.qwen.primary"),
            displayName: "Qwen",
            isCodex: false
        )
        let first = RuntimeModel(
            id: "first",
            displayName: "First",
            description: nil,
            isDefault: true,
            defaultReasoningEffort: nil,
            reasoningEfforts: []
        )
        let second = RuntimeModel(
            id: "second",
            displayName: "Second",
            description: nil,
            isDefault: false,
            defaultReasoningEffort: nil,
            reasoningEfforts: []
        )

        host.recordModelUsage(connectionID: connection.id, modelID: first.id)
        host.recordModelUsage(connectionID: connection.id, modelID: second.id)
        host.recordModelUsage(connectionID: connection.id, modelID: second.id)
        let ranked = host.rankedModelChoices(connection: connection, models: [first, second])

        XCTAssertEqual(ranked.map(\.model.id), ["second", "first"])
        XCTAssertEqual(ranked.map(\.usageCount), [2, 1])
        let firstUsage = host.modelUsage(connectionID: connection.id, modelID: first.id)
        let secondUsage = host.modelUsage(connectionID: connection.id, modelID: second.id)
        XCTAssertEqual(firstUsage.count, 1)
        XCTAssertEqual(secondUsage.count, 2)
        XCTAssertNotNil(firstUsage.lastUsedAt)
        XCTAssertNotNil(secondUsage.lastUsedAt)
        let restoredHost = OnyxApplicationHost(defaults: suite.defaults)
        XCTAssertEqual(
            restoredHost.rankedModelChoices(connection: connection, models: [first, second])
                .map(\.model.id),
            ["second", "first"]
        )
    }

    func testWindowRecordsAcceptedSendAgainstItsProviderAndSelectedModel() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let connectionID = ProviderConnectionID("test.usage.primary")
        let modelID = "usage-model"
        let runtime = MultiwindowFakeRuntime(
            threads: Self.threads,
            availableModels: [
                RuntimeModel(
                    id: modelID,
                    displayName: "Usage model",
                    description: nil,
                    isDefault: true,
                    defaultReasoningEffort: nil,
                    reasoningEfforts: []
                ),
            ]
        )
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: .init("test.usage"), displayName: "Usage test") { _ in runtime },
            ],
            connections: [
                RuntimeConnectionRegistration(id: connectionID, adapterID: .init("test.usage")),
            ]
        )
        let host = OnyxApplicationHost(
            registry: registry,
            connectionID: connectionID,
            defaults: suite.defaults
        )
        let windowModel = host.makeWindowModel(for: WorkspaceWindowID())

        windowModel.start()
        await waitUntil("The provider task did not load") {
            windowModel.canRunAgent
                && windowModel.selectedThreadID == Self.threadA.id
                && windowModel.selectedModelID == modelID
        }
        windowModel.selectModel(modelID)
        XCTAssertEqual(host.modelUsage(connectionID: connectionID, modelID: modelID).count, 0)

        windowModel.composerText = "Use the selected model"
        windowModel.sendComposer()
        await waitUntilAsync("The provider did not receive the turn") {
            await runtime.startTurnRequests().count == 1
        }
        await waitUntil("The send was not attributed to its provider and model") {
            host.modelUsage(connectionID: connectionID, modelID: modelID).count == 1
        }
    }

    func testHostLoadsSavedProviderCatalogsWithCapabilityMetadataBeforeConnect() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let descriptor = try ProviderModelDescriptor(
            id: "Qwen/Qwen3.8-VL",
            displayName: "Qwen 3.8 VL",
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(
                inputModalities: [.text, .image],
                supportedParameters: [.reasoningEffort],
                reasoningEfforts: ["low", "high"]
            )
        )
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("local.qwen.primary"),
            displayName: "Local Qwen",
            baseURL: URL(string: "https://qwen.example.test/v1")!,
            selectedModelID: descriptor.id,
            authMode: .none,
            discovery: ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: Date(timeIntervalSince1970: 10),
                lastSucceededAt: Date(timeIntervalSince1970: 11),
                discoveredModels: [descriptor]
            )
        )
        try await connectionStore.upsert(connection)
        let host = OnyxApplicationHost(
            defaults: suite.defaults,
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore()
        )

        let connections = await host.workspaceConnections()
        let catalogs = await host.cachedProviderModelCatalogs()
        let cached = try XCTUnwrap(catalogs[connection.id]?.first)

        XCTAssertTrue(connections.contains { $0.id == connection.id })
        XCTAssertEqual(cached.id, descriptor.id)
        XCTAssertEqual(cached.displayName, "Qwen 3.8 VL")
        XCTAssertTrue(cached.isDefault)
        XCTAssertEqual(cached.inputModalities, [.text, .image])
        XCTAssertEqual(cached.supportedRequestParameters, [.reasoningEffort])
        XCTAssertEqual(cached.reasoningEfforts, ["low", "high"])
    }

    func testHostExposesManuallySavedModelBeforeDiscovery() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let modelID = "Qwen/Qwen3.8-27B-FP8"
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("local.vllm.manual"),
            displayName: "Local vLLM",
            baseURL: URL(string: "http://192.168.2.170:8002/v1")!,
            selectedModelID: modelID,
            authMode: .none,
            transportSecurity: .allowInsecureHTTP,
            discovery: .init()
        )
        try await connectionStore.upsert(connection)

        let host = OnyxApplicationHost(
            defaults: suite.defaults,
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore()
        )

        let catalogs = await host.cachedProviderModelCatalogs()
        let cached = try XCTUnwrap(catalogs[connection.id]?.first)
        XCTAssertEqual(cached.id, modelID)
        XCTAssertEqual(cached.displayName, modelID)
        XCTAssertTrue(cached.isDefault)
        XCTAssertTrue(cached.capabilityEvidence.isUnknown)
        XCTAssertEqual(cached.pickerCapabilitySummary, "Capabilities unknown")
    }

    func testDisconnectedEmptyLiveCatalogDoesNotEraseCachedModels() throws {
        let cached = RuntimeModel(
            id: "cached-model",
            displayName: "Cached model",
            description: nil,
            isDefault: true,
            defaultReasoningEffort: nil,
            reasoningEfforts: [],
            inputModalities: [.text],
            capabilityEvidence: .unknown
        )

        XCTAssertEqual(
            OnyxApplicationHost.modelCatalog(retaining: [cached], preferring: []),
            [cached]
        )
        XCTAssertEqual(
            OnyxApplicationHost.modelCatalog(retaining: [cached], preferring: nil),
            [cached]
        )

        let live = RuntimeModel(
            id: "live-model",
            displayName: "Live model",
            description: nil,
            isDefault: true,
            defaultReasoningEffort: nil,
            reasoningEfforts: []
        )
        XCTAssertEqual(
            OnyxApplicationHost.modelCatalog(retaining: [cached], preferring: [live]),
            [live]
        )
    }

    func testProviderSettingsEditAndDeleteEvictCachedRuntimeCoordinator() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let connectionID = ProviderConnectionID("local.runtime-eviction")
        try await connectionStore.upsert(ProviderConnectionRecord(
            id: connectionID,
            displayName: "Original endpoint",
            baseURL: URL(string: "https://original.example.test/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            transportCapabilities: [.streaming]
        ))
        let host = OnyxApplicationHost(
            defaults: suite.defaults,
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore()
        )
        let providerWindow = WorkspaceWindowID(providerConnectionID: connectionID)

        _ = host.makeWindowModel(for: providerWindow)
        let original = try XCTUnwrap(host.cachedRuntimeCoordinatorForTesting(connectionID))

        await host.providerSettingsModel.reload()
        host.providerSettingsModel.draft.displayName = "Edited endpoint"
        let saved = await host.providerSettingsModel.saveDraft()
        XCTAssertTrue(saved)
        XCTAssertNil(host.cachedRuntimeCoordinatorForTesting(connectionID))

        _ = host.makeWindowModel(for: providerWindow)
        let replacement = try XCTUnwrap(host.cachedRuntimeCoordinatorForTesting(connectionID))
        XCTAssertNotEqual(ObjectIdentifier(original), ObjectIdentifier(replacement))

        let deleted = await host.providerSettingsModel.delete(connectionID)
        XCTAssertTrue(deleted)
        XCTAssertNil(host.cachedRuntimeCoordinatorForTesting(connectionID))
    }

    func testHostSeedsUnvisitedProviderTasksFromLocalStoreByScope() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxProviderTaskSeed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let providerID = ProviderConnectionID("local.vllm.unvisited")
        try await connectionStore.upsert(ProviderConnectionRecord(
            id: providerID,
            displayName: "Local vLLM",
            baseURL: URL(string: "https://vllm.example.test/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none
        ))
        let conversations = OpenAICompatibleConversationStore(fileURL: fileURL)
        _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
            id: "active-task",
            connectionID: providerID,
            title: "Active provider task",
            cwd: "/work/active",
            modelID: "fixture-model"
        ))
        _ = try await conversations.upsert(OpenAICompatibleStoredConversation(
            id: "archived-task",
            connectionID: providerID,
            title: "Archived provider task",
            cwd: "/work/archived",
            modelID: "fixture-model",
            isArchived: true
        ))
        let host = OnyxApplicationHost(
            defaults: suite.defaults,
            providerConnectionStore: connectionStore,
            providerCredentialStore: InMemoryCredentialStore(),
            providerConversationStore: conversations
        )

        let connections = await host.workspaceConnections()
        let lists = await host.cachedProviderTaskLists(connections: connections)
        let active = try XCTUnwrap(lists.first {
            $0.providerConnectionID == providerID && $0.scope == .active
        })
        let archived = try XCTUnwrap(lists.first {
            $0.providerConnectionID == providerID && $0.scope == .archived
        })

        XCTAssertEqual(active.threads.map(\.id), ["active-task"])
        XCTAssertEqual(archived.threads.map(\.id), ["archived-task"])
        XCTAssertEqual(active.providerDisplayName, "Local vLLM")
    }

    func testHostSeedsCodexTasksEvenWhenAnotherProviderWindowRestoresFirst() async throws {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let codexConnectionID = ProviderConnectionID("test.codex.seed")
        let runtime = MultiwindowFakeRuntime(threads: Self.threads)
        let registry = try RuntimeRegistry(
            providers: [
                RuntimeProviderDescriptor(id: .init("test.codex"), displayName: "Codex") { _ in runtime },
            ],
            connections: [
                RuntimeConnectionRegistration(id: codexConnectionID, adapterID: .init("test.codex")),
            ]
        )
        let host = OnyxApplicationHost(
            registry: registry,
            connectionID: codexConnectionID,
            defaults: suite.defaults,
            providerConnectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            providerCredentialStore: InMemoryCredentialStore()
        )

        let connections = await host.workspaceConnections()
        let lists = await host.cachedProviderTaskLists(connections: connections)
        let active = try XCTUnwrap(lists.first {
            $0.providerConnectionID == codexConnectionID && $0.scope == .active
        })

        XCTAssertEqual(active.threads.map(\.id), Self.threads.map(\.id))
        XCTAssertEqual(active.providerDisplayName, "Codex")
    }

    func testProviderScopedPinsKeepLegacyCodexPinsAndCollidingProviderIDsSeparate() {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let collidingID = "same-thread-id"
        suite.defaults.set([collidingID], forKey: "Onyx.pinnedThreadIDs")

        let codex = OnyxPinnedThreadStore(
            defaults: suite.defaults,
            connectionID: .codexDefault
        )
        let local = OnyxPinnedThreadStore(
            defaults: suite.defaults,
            connectionID: ProviderConnectionID("local.vllm")
        )

        XCTAssertEqual(codex.ids, Set([collidingID]))
        XCTAssertTrue(local.ids.isEmpty)
        local.toggle(collidingID)
        codex.remove(collidingID)
        XCTAssertTrue(codex.ids.isEmpty)
        XCTAssertEqual(local.ids, Set([collidingID]))
        XCTAssertTrue(suite.defaults.stringArray(forKey: "Onyx.pinnedThreadIDs")?.isEmpty == true)
    }

    func testHostPersistsWindowProviderSelectionAndKeepsProviderPreferencesSeparate() {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let host = OnyxApplicationHost(defaults: suite.defaults)
        let window = WorkspaceWindowID()
        let providerID = ProviderConnectionID("local.qwen.primary")

        XCTAssertEqual(host.selectedConnectionID(for: window), .codexDefault)
        host.selectConnection(providerID, for: window)

        XCTAssertEqual(host.selectedConnectionID(for: window), providerID)
        XCTAssertEqual(
            host.providerPreferenceKeyPrefix(windowID: window, connectionID: providerID),
            "\(window.preferenceKeyPrefix).provider.bG9jYWwucXdlbi5wcmltYXJ5"
        )
        XCTAssertEqual(
            host.providerPreferenceKeyPrefix(windowID: window, connectionID: .codexDefault),
            window.preferenceKeyPrefix
        )
        XCTAssertEqual(
            host.validatedSelection(
                for: window,
                availableConnections: [
                    .init(id: .codexDefault, displayName: "Codex", isCodex: true),
                    .init(id: providerID, displayName: "Qwen", isCodex: false),
                ]
            ),
            providerID
        )
        XCTAssertEqual(
            host.validatedSelection(
                for: window,
                availableConnections: [
                    .init(id: .codexDefault, displayName: "Codex", isCodex: true),
                ]
            ),
            .codexDefault,
            "A removed provider must not be silently composed as an arbitrary OpenAI runtime"
        )
    }

    func testProviderSwitchStartsNewTaskWithoutLosingProviderScopedDraft() async {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let prefix = "Onyx.window.provider-switch.provider.qwen"
        let namespace = OnyxPreferenceNamespace(prefix: prefix)
        suite.defaults.set(Self.threadA.id, forKey: namespace.key("Onyx.selectedThreadID"))
        suite.defaults.set(
            ["onyx:welcome": "Draft already written for Qwen"],
            forKey: namespace.key("Onyx.composerDrafts")
        )
        let model = OnyxAppModel(
            runtime: SharedRuntimeCoordinator(runtime: MultiwindowFakeRuntime(threads: Self.threads)),
            defaults: suite.defaults,
            preferenceKeyPrefix: prefix,
            startsWithNewTask: true
        )

        model.start()
        await waitUntil("Provider switch restored an existing task instead of the new-task composer") {
            model.selectedThreadID == "onyx:welcome"
                && !model.isLoadingThreadList
                && model.threads.contains(where: { $0.id == Self.threadA.id })
        }

        XCTAssertEqual(model.composerText, "Draft already written for Qwen")
        XCTAssertTrue(model.threads.contains(where: { $0.id == "onyx:welcome" }))
        XCTAssertTrue(model.threads.contains(where: { $0.id == Self.threadA.id }))
    }

    func testDirectTaskOpenReadsTaskMissingFromCappedListSnapshot() async {
        let suite = makeDefaults()
        defer { suite.cleanUp() }
        let runtime = MultiwindowFakeRuntime(
            threads: Self.threads,
            listedThreads: [Self.threadA]
        )
        let model = OnyxAppModel(
            runtime: SharedRuntimeCoordinator(runtime: runtime),
            defaults: suite.defaults
        )
        model.start()
        await waitUntil("The capped provider list did not load") {
            !model.isLoadingThreadList
                && model.threads.contains(where: { $0.id == Self.threadA.id })
                && !model.threads.contains(where: { $0.id == Self.threadB.id })
        }

        model.selectThread(Self.threadB.id)

        await waitUntil("Opening by ID did not recover the task missing from the list") {
            model.selectedThreadID == Self.threadB.id
                && !model.isLoadingThread
                && model.threads.contains(where: { $0.id == Self.threadB.id })
        }
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

    private func waitUntilAsync(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let didMeetCondition = await condition()
        XCTAssertTrue(didMeetCondition, failureMessage)
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
    private let listedThreads: [RuntimeThread]
    private let availableModels: [RuntimeModel]
    private let connectAuth: RuntimeAuthState
    private let refreshAuth: RuntimeAuthState
    private var recordedConnectCount = 0
    private var recordedStartTurns: [StartTurnRequest] = []

    init(
        threads: [RuntimeThread],
        connectAuth: RuntimeAuthState? = nil,
        refreshAuth: RuntimeAuthState? = nil,
        availableModels: [RuntimeModel] = [],
        listedThreads: [RuntimeThread]? = nil
    ) {
        let fallbackAuth = RuntimeAuthState(
            mode: nil,
            email: nil,
            planLabel: nil,
            requiresAuthentication: false
        )
        self.threads = threads
        self.listedThreads = listedThreads ?? threads
        self.availableModels = availableModels
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
            availableModels: availableModels,
            capabilities: []
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : listedThreads
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

    func startTurn(_ request: StartTurnRequest) async throws {
        recordedStartTurns.append(request)
    }
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(to _: RuntimeRequestID, with _: RuntimeUserInteractionResponse) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
    func startTurnRequests() -> [StartTurnRequest] { recordedStartTurns }
}
