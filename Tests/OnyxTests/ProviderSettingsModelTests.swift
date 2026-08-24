import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ProviderSettingsModelTests: XCTestCase {
    func testPrivateIPHTTPRequiresAcknowledgementAndQwenBehaviorPersistsWithoutSecret() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentialStore = InMemoryCredentialStore()
        let discovery = StubProviderModelDiscovery()
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: discovery
        )

        model.beginAdd()
        model.draft.displayName = "Qwen LAN"
        model.draft.baseURL = "http://192.168.2.170:8002/v1/"
        model.draft.selectedModelID = "Qwen/Qwen3.8-27B-FP8"
        model.draft.enableThinking = true

        XCTAssertFalse(model.draft.description.contains("192.168.2.170"))
        let rejected = await model.saveDraft()
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("acknowledge") == true)

        model.draft.allowInsecureHTTP = true
        let savedSuccessfully = await model.saveDraft()
        XCTAssertTrue(savedSuccessfully)

        let saved = try await connectionStore.connections()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].baseURL.absoluteString, "http://192.168.2.170:8002/v1")
        XCTAssertEqual(saved[0].transportSecurity, .allowInsecureHTTP)
        XCTAssertEqual(saved[0].transportCapabilities, [.streaming, .streamUsage])
        XCTAssertEqual(saved[0].requestBehavior.enableThinking, false)
        XCTAssertEqual(saved[0].selectedModelID, "Qwen/Qwen3.8-27B-FP8")

        let json = String(decoding: try XCTUnwrap(storage.storedData()), as: UTF8.self)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("authorization"))
    }

    func testHostnameAndPublicIPHTTPRemainBlockedEvenAfterAcknowledgement() async throws {
        let model = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            credentialStore: InMemoryCredentialStore(),
            discovery: StubProviderModelDiscovery()
        )
        model.beginAdd()
        model.draft.displayName = "Unsafe"
        model.draft.allowInsecureHTTP = true

        for endpoint in [
            "http://provider.example.test/v1",
            "http://8.8.8.8/v1",
        ] {
            model.draft.baseURL = endpoint
            let saved = await model.saveDraft()
            XCTAssertFalse(saved)
            XCTAssertTrue(
                model.errorMessage?.localizedCaseInsensitiveContains("hostnames") == true
                    || model.errorMessage?.localizedCaseInsensitiveContains("public") == true,
                "Unexpected validation message: \(model.errorMessage ?? "nil")"
            )
        }
    }

    func testLoopbackHTTPAlsoNeedsAcknowledgementAndCannotUseBearerAuth() async throws {
        let model = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            credentialStore: InMemoryCredentialStore(),
            discovery: StubProviderModelDiscovery()
        )
        model.beginAdd()
        model.draft.displayName = "Local"
        model.draft.baseURL = "http://127.0.0.1:8000/v1"

        let firstSave = await model.saveDraft()
        XCTAssertFalse(firstSave)
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("acknowledge") == true)

        model.draft.allowInsecureHTTP = true
        model.draft.authMode = .bearer
        model.draft.bearerToken = "local-secret"
        let secondSave = await model.saveDraft()
        XCTAssertFalse(secondSave)
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("bearer") == true)
    }

    func testBearerCredentialIsWrittenToKeychainSeamAndNeverJSON() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentialStore = InMemoryCredentialStore()
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: StubProviderModelDiscovery()
        )
        let secret = "sk-test-provider-secret"

        model.beginAdd()
        model.draft.displayName = "Remote API"
        model.draft.baseURL = "https://api.example.test/v1"
        model.draft.authMode = .bearer
        model.draft.bearerToken = secret
        let savedSuccessfully = await model.saveDraft()
        XCTAssertTrue(savedSuccessfully)

        let records = try await connectionStore.connections()
        let record = try XCTUnwrap(records.first)
        let credential = await credentialStore.credential(for: record.credentialKey)
        let savedCredential = try XCTUnwrap(credential)
        XCTAssertEqual(try savedCredential.withValue { $0 }, secret)
        let json = String(decoding: try XCTUnwrap(storage.storedData()), as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("ProviderBearerCredential"))
    }

    func testInjectedDiscoveryIsDeterministicAndDoesNotRequireNetwork() async throws {
        let discovery = StubProviderModelDiscovery(
            models: [
                try ProviderModelDescriptor(
                    id: "Qwen/Qwen3.8-27B-FP8",
                    wireProtocol: .openAIChatCompletions,
                    capabilities: .init()
                )
            ]
        )
        let model = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            credentialStore: InMemoryCredentialStore(),
            discovery: discovery
        )

        model.beginAdd()
        model.draft.displayName = "Local Qwen"
        model.draft.baseURL = "http://127.0.0.1:8002/v1"
        model.draft.allowInsecureHTTP = true

        let models = await model.discoverModels()
        XCTAssertEqual(models?.map(\.id), ["Qwen/Qwen3.8-27B-FP8"])
        XCTAssertEqual(model.draft.selectedModelID, "Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(model.draft.discovery.discoveredModelIDs, ["Qwen/Qwen3.8-27B-FP8"])
        let calls = await discovery.callCount
        XCTAssertEqual(calls, 1)
    }

    func testSavingNewConnectionAutomaticallyDiscoversPersistsAndSelectsModels() async throws {
        let descriptor = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("Qwen/Qwen3.8-27B-FP8"),
            "owned_by": .string("vllm"),
        ]))
        let discovery = StubProviderModelDiscovery(models: [descriptor])
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            discovery: discovery
        )

        model.beginAdd()
        model.draft.displayName = "Local vLLM"
        model.draft.baseURL = "http://127.0.0.1:8000/v1"
        model.draft.allowInsecureHTTP = true

        let savedSuccessfully = await model.saveDraft()
        XCTAssertTrue(savedSuccessfully)

        let records = try await connectionStore.connections()
        let saved = try XCTUnwrap(records.first)
        XCTAssertEqual(saved.selectedModelID, descriptor.id)
        XCTAssertEqual(saved.discovery.discoveredModels, [descriptor])
        XCTAssertEqual(model.currentDraftDiscoveredModelIDs, [descriptor.id])
        let calls = await discovery.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.statusMessage?.contains("with 1 model") == true)
    }

    func testAutomaticDiscoveryFailureStillSavesManualModel() async throws {
        let discovery = StubProviderModelDiscovery(error: ProviderModelDiscoveryError.networkFailure)
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            discovery: discovery
        )

        model.beginAdd()
        model.draft.displayName = "Offline vLLM"
        model.draft.baseURL = "http://127.0.0.1:8000/v1"
        model.draft.allowInsecureHTTP = true
        model.draft.selectedModelID = "manual-model"

        let savedSuccessfully = await model.saveDraft()
        XCTAssertTrue(savedSuccessfully)
        let records = try await connectionStore.connections()
        let saved = try XCTUnwrap(records.first)
        XCTAssertEqual(saved.selectedModelID, "manual-model")
        XCTAssertTrue(saved.discovery.discoveredModelIDs.isEmpty)
        XCTAssertTrue(model.statusMessage?.contains("Models were not available") == true)
    }

    func testLateDiscoveryDoesNotOverwriteNewerDraftScope() async throws {
        let descriptor = try ProviderModelDescriptor(
            id: "stale-model",
            wireProtocol: .openAIChatCompletions,
            capabilities: .init()
        )
        let discovery = ControllableProviderModelDiscovery(models: [descriptor])
        let model = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            credentialStore: InMemoryCredentialStore(),
            discovery: discovery
        )
        model.beginAdd()
        model.draft.displayName = "Draft"
        model.draft.baseURL = "https://old.example.test/v1"

        let task = Task { await model.discoverModels() }
        await discovery.waitUntilStarted()
        model.draft.baseURL = "https://new.example.test/v1"
        model.updateDraftDiscoveryScope()
        await discovery.release()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(model.currentDraftDiscoveredModelIDs.isEmpty)
        XCTAssertTrue(model.draft.discovery.discoveredModelIDs.isEmpty)
        XCTAssertNotEqual(model.draft.selectedModelID, descriptor.id)
    }

    func testChangingEndpointHidesAndDoesNotPersistOldCatalogWhenRefreshFails() async throws {
        let oldDescriptor = try ProviderModelDescriptor(
            id: "old-model",
            wireProtocol: .openAIChatCompletions,
            capabilities: .init()
        )
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let original = try ProviderConnectionRecord(
            id: ProviderConnectionID("endpoint-change"),
            displayName: "Provider",
            baseURL: URL(string: "https://old.example.test/v1")!,
            selectedModelID: oldDescriptor.id,
            authMode: .none,
            discovery: ProviderConnectionDiscoveryMetadata(discoveredModels: [oldDescriptor])
        )
        try await connectionStore.upsert(original)
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            discovery: StubProviderModelDiscovery(error: ProviderModelDiscoveryError.networkFailure)
        )
        await model.start()
        XCTAssertEqual(model.currentDraftDiscoveredModelIDs, [oldDescriptor.id])

        model.draft.baseURL = "https://new.example.test/v1"
        model.updateDraftDiscoveryScope()
        model.draft.selectedModelID = "new-manual-model"
        XCTAssertTrue(model.currentDraftDiscoveredModelIDs.isEmpty)
        let savedSuccessfully = await model.saveDraft()
        XCTAssertTrue(savedSuccessfully)

        let stored = try await connectionStore.connection(id: original.id)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.baseURL.absoluteString, "https://new.example.test/v1")
        XCTAssertEqual(saved.selectedModelID, "new-manual-model")
        XCTAssertTrue(saved.discovery.discoveredModelIDs.isEmpty)
    }

    func testEndpointOrBearerChangeRotatesConversationScopeButCosmeticEditDoesNot() async throws {
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let credentialStore = InMemoryCredentialStore()
        let descriptor = try ProviderModelDescriptor(
            id: "model",
            wireProtocol: .openAIChatCompletions,
            capabilities: .init()
        )
        let original = try ProviderConnectionRecord(
            id: ProviderConnectionID("scoped-provider"),
            displayName: "Provider",
            baseURL: URL(string: "https://one.example.test/v1")!,
            selectedModelID: descriptor.id,
            authMode: .bearer,
            discovery: ProviderConnectionDiscoveryMetadata(discoveredModels: [descriptor]),
            conversationScopeID: "scope.original"
        )
        try await connectionStore.upsert(original)
        try await credentialStore.setCredential(
            ProviderBearerCredential("old-token"),
            for: original.credentialKey
        )
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: StubProviderModelDiscovery(models: [descriptor])
        )
        await model.start()

        model.draft.displayName = "Renamed Provider"
        var saveResult = await model.saveDraft()
        XCTAssertTrue(saveResult)
        var stored = try await connectionStore.connection(id: original.id)
        var saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.conversationScopeID, "scope.original")

        model.draft.bearerToken = "new-token"
        model.updateDraftDiscoveryScope()
        saveResult = await model.saveDraft()
        XCTAssertTrue(saveResult)
        stored = try await connectionStore.connection(id: original.id)
        saved = try XCTUnwrap(stored)
        let credentialScope = saved.conversationScopeID
        XCTAssertNotEqual(credentialScope, "scope.original")

        model.draft.baseURL = "https://two.example.test/v1"
        model.updateDraftDiscoveryScope()
        saveResult = await model.saveDraft()
        XCTAssertTrue(saveResult)
        stored = try await connectionStore.connection(id: original.id)
        saved = try XCTUnwrap(stored)
        XCTAssertNotEqual(saved.conversationScopeID, credentialScope)
    }

    func testDiscoveryResponseCannotOverwriteAChangedDraft() async throws {
        let discoveredModel = try ProviderModelDescriptor(
            id: "stale-model",
            wireProtocol: .openAIChatCompletions,
            capabilities: .init()
        )
        let discovery = SuspendedProviderModelDiscovery(models: [discoveredModel])
        let model = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            credentialStore: InMemoryCredentialStore(),
            discovery: discovery
        )
        model.beginAdd()
        model.draft.displayName = "Local model"
        model.draft.baseURL = "https://old-provider.example/v1"

        let request = Task { await model.discoverModels() }
        await discovery.waitUntilStarted()
        model.draft.baseURL = "https://new-provider.example/v1"
        await discovery.resume()

        let result = await request.value
        XCTAssertNil(result)
        XCTAssertEqual(model.draft.baseURL, "https://new-provider.example/v1")
        XCTAssertTrue(model.draft.discovery.discoveredModels.isEmpty)
        XCTAssertTrue(model.lastDiscoveredModels.isEmpty)
    }

    func testRemovingBearerModeDeletesSavedCredential() async throws {
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let credentialStore = InMemoryCredentialStore()
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: StubProviderModelDiscovery()
        )

        model.beginAdd()
        model.draft.displayName = "API"
        model.draft.baseURL = "https://api.example.test/v1"
        model.draft.authMode = .bearer
        model.draft.bearerToken = "temporary-secret"
        let savedSuccessfully = await model.saveDraft()
        XCTAssertTrue(savedSuccessfully)

        model.draft.authMode = .none
        model.draft.bearerToken = ""
        let removedSuccessfully = await model.saveDraft()
        XCTAssertTrue(removedSuccessfully)

        let records = try await connectionStore.connections()
        let record = try XCTUnwrap(records.first)
        let removedCredential = await credentialStore.credential(for: record.credentialKey)
        XCTAssertNil(removedCredential)
        XCTAssertEqual(record.authMode, .none)
    }

    func testRemoveStoredBearerKeySignsOutWithoutDiscoveryAndRotatesScope() async throws {
        let descriptor = try ProviderModelDescriptor(
            id: "model",
            wireProtocol: .openAIChatCompletions,
            capabilities: .init()
        )
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let credentialStore = InMemoryCredentialStore()
        let original = try ProviderConnectionRecord(
            id: ProviderConnectionID("remove-key-signed-out"),
            displayName: "Provider",
            baseURL: URL(string: "https://api.example.test/v1")!,
            selectedModelID: descriptor.id,
            authMode: .bearer,
            discovery: ProviderConnectionDiscoveryMetadata(
                discoveredModels: [descriptor]
            ),
            conversationScopeID: "scope.before-remove"
        )
        try await connectionStore.upsert(original)
        try await credentialStore.setCredential(
            ProviderBearerCredential("old-token"),
            for: original.credentialKey
        )
        let discovery = StubProviderModelDiscovery(models: [descriptor])
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: discovery
        )
        await model.start()

        XCTAssertTrue(model.draft.hasStoredCredential)
        model.draft.removeStoredCredential = true
        model.draft.bearerToken = ""
        model.updateDraftDiscoveryScope()

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)

        let signedOutValue = try await connectionStore.connection(id: original.id)
        let signedOut = try XCTUnwrap(signedOutValue)
        XCTAssertEqual(signedOut.authMode, .bearer)
        XCTAssertNotEqual(signedOut.conversationScopeID, original.conversationScopeID)
        XCTAssertTrue(signedOut.discovery.discoveredModelIDs.isEmpty)
        let removedCredential = await credentialStore.credential(for: signedOut.credentialKey)
        XCTAssertNil(removedCredential)
        let discoveryCallsAfterRemoval = await discovery.callCount
        XCTAssertEqual(discoveryCallsAfterRemoval, 0)

        // A signed-out bearer connection remains editable. Cosmetic changes
        // must not force a replacement key or probe the endpoint with none.
        model.draft.displayName = "Renamed while signed out"
        let renamedSave = await model.saveDraft()
        XCTAssertTrue(renamedSave, model.errorMessage ?? "no error")
        let discoveryCallsAfterRename = await discovery.callCount
        XCTAssertEqual(discoveryCallsAfterRename, 0)
        let renamedValue = try await connectionStore.connection(id: original.id)
        let renamed = try XCTUnwrap(renamedValue)
        XCTAssertEqual(renamed.displayName, "Renamed while signed out")
        XCTAssertEqual(renamed.authMode, .bearer)
        let renamedCredential = await credentialStore.credential(for: renamed.credentialKey)
        XCTAssertNil(renamedCredential)
    }

    func testNewBearerConnectionStillRequiresCredential() async throws {
        let model = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(
                storage: InMemoryProviderConnectionStorage()
            ),
            credentialStore: InMemoryCredentialStore(),
            discovery: StubProviderModelDiscovery()
        )
        model.beginAdd()
        model.draft.displayName = "New API"
        model.draft.baseURL = "https://api.example.test/v1"
        model.draft.authMode = .bearer

        let saved = await model.saveDraft()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.errorMessage, ProviderSettingsError.missingBearerCredential.localizedDescription)
    }

    func testSaveWaitsForPreMutationBarrierAndRejectsOverlappingDelete() async throws {
        let descriptor = try ProviderModelDescriptor(
            id: "model",
            wireProtocol: .openAIChatCompletions,
            capabilities: .init()
        )
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let credentialStore = InMemoryCredentialStore()
        let original = try ProviderConnectionRecord(
            id: ProviderConnectionID("save-mutation-barrier"),
            displayName: "Original Provider",
            baseURL: URL(string: "https://old.example.test/v1")!,
            selectedModelID: descriptor.id,
            authMode: .bearer,
            discovery: ProviderConnectionDiscoveryMetadata(discoveredModels: [descriptor])
        )
        try await connectionStore.upsert(original)
        try await credentialStore.setCredential(
            ProviderBearerCredential("old-token"),
            for: original.credentialKey
        )

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: StubProviderModelDiscovery(models: [descriptor])
        )
        await model.start()
        model.draft.baseURL = "https://new.example.test/v1"
        model.draft.bearerToken = "new-token"
        model.updateDraftDiscoveryScope()

        let barrier = SuspendedProviderMutationBarrier()
        var didFinishMutation = false
        model.onConnectionWillMutate = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            await barrier.suspend()
        }
        model.onConnectionMutation = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            didFinishMutation = true
        }

        let saveTask = Task { await model.saveDraft() }
        await barrier.waitUntilStarted()

        let recordWhileSuspendedValue = try await connectionStore.connection(id: original.id)
        let recordWhileSuspended = try XCTUnwrap(recordWhileSuspendedValue)
        XCTAssertEqual(recordWhileSuspended.baseURL, original.baseURL)
        let credentialWhileSuspendedValue = await credentialStore.credential(for: original.credentialKey)
        let credentialWhileSuspended = try XCTUnwrap(credentialWhileSuspendedValue)
        XCTAssertEqual(try credentialWhileSuspended.withValue { $0 }, "old-token")
        XCTAssertFalse(didFinishMutation)

        let errorBeforeRejectedDelete = model.errorMessage
        let statusBeforeRejectedDelete = model.statusMessage
        let deleteResult = await model.delete(original.id)
        XCTAssertFalse(deleteResult)
        XCTAssertEqual(model.errorMessage, errorBeforeRejectedDelete)
        XCTAssertEqual(model.statusMessage, statusBeforeRejectedDelete)

        let recordAfterRejectedDeleteValue = try await connectionStore.connection(id: original.id)
        let recordAfterRejectedDelete = try XCTUnwrap(recordAfterRejectedDeleteValue)
        XCTAssertEqual(recordAfterRejectedDelete.baseURL, original.baseURL)
        let credentialAfterRejectedDeleteValue = await credentialStore.credential(for: original.credentialKey)
        let credentialAfterRejectedDelete = try XCTUnwrap(credentialAfterRejectedDeleteValue)
        XCTAssertEqual(try credentialAfterRejectedDelete.withValue { $0 }, "old-token")

        await barrier.resume()
        let saveResult = await saveTask.value
        XCTAssertTrue(saveResult)
        XCTAssertTrue(didFinishMutation)

        let savedRecordValue = try await connectionStore.connection(id: original.id)
        let savedRecord = try XCTUnwrap(savedRecordValue)
        XCTAssertEqual(savedRecord.baseURL.absoluteString, "https://new.example.test/v1")
        XCTAssertNotNil(savedRecord.credentialSlotID)
        let savedCredentialValue = await credentialStore.credential(for: savedRecord.credentialKey)
        let savedCredential = try XCTUnwrap(savedCredentialValue)
        XCTAssertEqual(try savedCredential.withValue { $0 }, "new-token")
        let oldCredentialAfterSave = await credentialStore.credential(for: original.credentialKey)
        XCTAssertNil(oldCredentialAfterSave)
    }

    func testDeleteWaitsForPreMutationBarrierAndRejectsOverlappingSave() async throws {
        let descriptor = try ProviderModelDescriptor(
            id: "model",
            wireProtocol: .openAIChatCompletions,
            capabilities: .init()
        )
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        let credentialStore = InMemoryCredentialStore()
        let original = try ProviderConnectionRecord(
            id: ProviderConnectionID("delete-mutation-barrier"),
            displayName: "Original Provider",
            baseURL: URL(string: "https://old.example.test/v1")!,
            selectedModelID: descriptor.id,
            authMode: .bearer,
            discovery: ProviderConnectionDiscoveryMetadata(discoveredModels: [descriptor])
        )
        try await connectionStore.upsert(original)
        try await credentialStore.setCredential(
            ProviderBearerCredential("old-token"),
            for: original.credentialKey
        )

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: StubProviderModelDiscovery(models: [descriptor])
        )
        await model.start()
        model.draft.baseURL = "https://new.example.test/v1"
        model.draft.bearerToken = "new-token"
        model.updateDraftDiscoveryScope()

        let barrier = SuspendedProviderMutationBarrier()
        var didFinishMutation = false
        model.onConnectionWillMutate = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            await barrier.suspend()
        }
        model.onConnectionMutation = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            didFinishMutation = true
        }

        let deleteTask = Task { await model.delete(original.id) }
        await barrier.waitUntilStarted()

        let recordWhileSuspendedValue = try await connectionStore.connection(id: original.id)
        let recordWhileSuspended = try XCTUnwrap(recordWhileSuspendedValue)
        XCTAssertEqual(recordWhileSuspended, original)
        let credentialWhileSuspendedValue = await credentialStore.credential(for: original.credentialKey)
        let credentialWhileSuspended = try XCTUnwrap(credentialWhileSuspendedValue)
        XCTAssertEqual(try credentialWhileSuspended.withValue { $0 }, "old-token")
        XCTAssertFalse(didFinishMutation)

        let errorBeforeRejectedSave = model.errorMessage
        let statusBeforeRejectedSave = model.statusMessage
        let saveResult = await model.saveDraft()
        XCTAssertFalse(saveResult)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.errorMessage, errorBeforeRejectedSave)
        XCTAssertEqual(model.statusMessage, statusBeforeRejectedSave)

        let recordAfterRejectedSaveValue = try await connectionStore.connection(id: original.id)
        let recordAfterRejectedSave = try XCTUnwrap(recordAfterRejectedSaveValue)
        XCTAssertEqual(recordAfterRejectedSave, original)
        let credentialAfterRejectedSaveValue = await credentialStore.credential(for: original.credentialKey)
        let credentialAfterRejectedSave = try XCTUnwrap(credentialAfterRejectedSaveValue)
        XCTAssertEqual(try credentialAfterRejectedSave.withValue { $0 }, "old-token")

        await barrier.resume()
        let deleteResult = await deleteTask.value
        XCTAssertTrue(deleteResult)
        XCTAssertTrue(didFinishMutation)
        let deletedRecord = try await connectionStore.connection(id: original.id)
        let deletedCredential = await credentialStore.credential(for: original.credentialKey)
        XCTAssertNil(deletedRecord)
        XCTAssertNil(deletedCredential)
    }

    func testDeleteCredentialFailureLeavesRecordAndCredentialIntact() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentialStore = ControllableCredentialStore()
        let original = try ProviderConnectionRecord(
            id: ProviderConnectionID("credential-delete-failure"),
            displayName: "Provider",
            baseURL: URL(string: "https://api.example.test/v1")!,
            authMode: .bearer
        )
        let credential = try ProviderBearerCredential("original-token")
        try await connectionStore.upsert(original)
        await credentialStore.setCredential(credential, for: original.credentialKey)
        await credentialStore.failRemovals()

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: StubProviderModelDiscovery()
        )
        await model.start()

        var mutationStarted = false
        var mutationFinished = false
        model.onConnectionWillMutate = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            mutationStarted = true
        }
        model.onConnectionMutation = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            mutationFinished = true
        }

        let deleteResult = await model.delete(original.id)
        XCTAssertTrue(deleteResult)
        XCTAssertTrue(mutationStarted)
        XCTAssertTrue(mutationFinished)
        let retainedRecord = try await connectionStore.connection(id: original.id)
        XCTAssertNil(retainedRecord)
        let retainedCredentialValue = await credentialStore.credential(for: original.credentialKey)
        let retainedCredential = try XCTUnwrap(retainedCredentialValue)
        XCTAssertEqual(retainedCredential, credential)
        XCTAssertEqual(model.connections, [])
        let operationCounts = await credentialStore.operationCounts()
        XCTAssertEqual(operationCounts.sets, 1)
        XCTAssertEqual(operationCounts.removals, 1)
    }

    func testDeleteRecordWriteFailureRestoresCredentialAndKeepsRecord() async throws {
        let storage = FailingProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentialStore = ControllableCredentialStore()
        let original = try ProviderConnectionRecord(
            id: ProviderConnectionID("record-delete-failure"),
            displayName: "Provider",
            baseURL: URL(string: "https://api.example.test/v1")!,
            authMode: .bearer
        )
        let credential = try ProviderBearerCredential("original-token")
        try await connectionStore.upsert(original)
        await credentialStore.setCredential(credential, for: original.credentialKey)
        storage.failWrites()

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            discovery: StubProviderModelDiscovery()
        )
        await model.start()

        var mutationStarted = false
        var mutationFinished = false
        model.onConnectionWillMutate = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            mutationStarted = true
        }
        model.onConnectionMutation = { connectionID in
            XCTAssertEqual(connectionID, original.id)
            mutationFinished = true
        }

        let deleteResult = await model.delete(original.id)
        XCTAssertFalse(deleteResult)
        XCTAssertTrue(mutationStarted)
        XCTAssertTrue(mutationFinished)
        let retainedRecord = try await connectionStore.connection(id: original.id)
        XCTAssertEqual(retainedRecord, original)
        let restoredCredentialValue = await credentialStore.credential(for: original.credentialKey)
        let restoredCredential = try XCTUnwrap(restoredCredentialValue)
        XCTAssertEqual(restoredCredential, credential)
        XCTAssertEqual(model.connections, [original])
        let operationCounts = await credentialStore.operationCounts()
        XCTAssertEqual(operationCounts.sets, 1)
        XCTAssertEqual(operationCounts.removals, 0)
    }

    func testInvalidURLFeedbackDoesNotEchoQuerySecrets() {
        var draft = ProviderConnectionDraft.new()
        draft.baseURL = "https://provider.example/v1?api_key=do-not-echo"
        XCTAssertFalse(draft.urlValidationMessage?.contains("do-not-echo") == true)
        XCTAssertTrue(draft.urlValidationMessage?.contains("query") == true)
    }

}

private actor StubProviderModelDiscovery: ProviderModelDiscovery {
    let models: [ProviderModelDescriptor]
    let error: (any Error)?
    private(set) var callCount = 0

    init(models: [ProviderModelDescriptor] = [], error: (any Error)? = nil) {
        self.models = models
        self.error = error
    }

    func discoverModels(
        for connection: ProviderConnectionRecord,
        credential: ProviderBearerCredential?
    ) async throws -> [ProviderModelDescriptor] {
        callCount += 1
        if let error { throw error }
        return models
    }
}

private actor ControllableProviderModelDiscovery: ProviderModelDiscovery {
    let models: [ProviderModelDescriptor]
    private var started = false
    private var released = false

    init(models: [ProviderModelDescriptor]) {
        self.models = models
    }

    func discoverModels(
        for connection: ProviderConnectionRecord,
        credential: ProviderBearerCredential?
    ) async throws -> [ProviderModelDescriptor] {
        started = true
        while !released { await Task.yield() }
        return models
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        released = true
    }
}

private actor SuspendedProviderModelDiscovery: ProviderModelDiscovery {
    let models: [ProviderModelDescriptor]
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<Void, Never>?

    init(models: [ProviderModelDescriptor]) {
        self.models = models
    }

    func discoverModels(
        for connection: ProviderConnectionRecord,
        credential: ProviderBearerCredential?
    ) async throws -> [ProviderModelDescriptor] {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { responseContinuation = $0 }
        return models
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        responseContinuation?.resume()
        responseContinuation = nil
    }
}

private actor SuspendedProviderMutationBarrier {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private enum ProviderSettingsModelInjectedFailure: Error {
    case credentialRemoval
    case connectionWrite
}

private actor ControllableCredentialStore: CredentialStore {
    private var values: [ProviderCredentialKey: ProviderBearerCredential] = [:]
    private var shouldFailRemovals = false
    private var setCount = 0
    private var removalCount = 0

    func credential(for key: ProviderCredentialKey) -> ProviderBearerCredential? {
        values[key]
    }

    func setCredential(
        _ credential: ProviderBearerCredential,
        for key: ProviderCredentialKey
    ) {
        setCount += 1
        values[key] = credential
    }

    func removeCredential(for key: ProviderCredentialKey) throws {
        removalCount += 1
        if shouldFailRemovals {
            throw ProviderSettingsModelInjectedFailure.credentialRemoval
        }
        values.removeValue(forKey: key)
    }

    func failRemovals() {
        shouldFailRemovals = true
    }

    func operationCounts() -> (sets: Int, removals: Int) {
        (setCount, removalCount)
    }
}

private final class FailingProviderConnectionStorage: ProviderConnectionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var shouldFailWrites = false

    func read() -> Data? {
        lock.withLock { data }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            if shouldFailWrites {
                throw ProviderSettingsModelInjectedFailure.connectionWrite
            }
            self.data = data
        }
    }

    func failWrites() {
        lock.withLock { shouldFailWrites = true }
    }
}
