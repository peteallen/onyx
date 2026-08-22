import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ProviderSettingsModelTests: XCTestCase {
    func testLANHTTPRequiresAcknowledgementAndQwenBehaviorPersistsWithoutSecret() async throws {
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
        model.draft.baseURL = "http://lan-provider.example.test:8002/v1/"
        model.draft.selectedModelID = "Qwen/Qwen3.8-27B-FP8"
        model.draft.enableThinking = true

        XCTAssertFalse(model.draft.description.contains("lan-provider.example.test"))
        let rejected = await model.saveDraft()
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.errorMessage?.localizedCaseInsensitiveContains("acknowledge") == true)

        model.draft.allowInsecureHTTP = true
        let savedSuccessfully = await model.saveDraft()
        XCTAssertTrue(savedSuccessfully)

        let saved = try await connectionStore.connections()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].baseURL.absoluteString, "http://lan-provider.example.test:8002/v1")
        XCTAssertEqual(saved[0].transportSecurity, .allowInsecureHTTP)
        XCTAssertEqual(saved[0].transportCapabilities, [.streaming, .streamUsage])
        XCTAssertEqual(saved[0].requestBehavior.enableThinking, false)
        XCTAssertEqual(saved[0].selectedModelID, "Qwen/Qwen3.8-27B-FP8")

        let json = String(decoding: try XCTUnwrap(storage.storedData()), as: UTF8.self)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("authorization"))
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
        model.draft.baseURL = "http://localhost:8002/v1"

        let models = await model.discoverModels()
        XCTAssertEqual(models?.map(\.id), ["Qwen/Qwen3.8-27B-FP8"])
        XCTAssertEqual(model.draft.selectedModelID, "Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(model.draft.discovery.discoveredModelIDs, ["Qwen/Qwen3.8-27B-FP8"])
        let calls = await discovery.callCount
        XCTAssertEqual(calls, 1)
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

    func testInvalidURLFeedbackDoesNotEchoQuerySecrets() {
        var draft = ProviderConnectionDraft.new()
        draft.baseURL = "https://provider.example/v1?api_key=do-not-echo"
        XCTAssertFalse(draft.urlValidationMessage?.contains("do-not-echo") == true)
        XCTAssertTrue(draft.urlValidationMessage?.contains("query") == true)
    }
}

private actor StubProviderModelDiscovery: ProviderModelDiscovery {
    let models: [ProviderModelDescriptor]
    private(set) var callCount = 0

    init(models: [ProviderModelDescriptor] = []) {
        self.models = models
    }

    func discoverModels(
        for connection: ProviderConnectionRecord,
        credential: ProviderBearerCredential?
    ) async throws -> [ProviderModelDescriptor] {
        callCount += 1
        return models
    }
}
