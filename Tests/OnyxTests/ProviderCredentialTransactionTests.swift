import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ProviderCredentialTransactionTests: XCTestCase {
    func testNewBearerSaveCommitsASecretFreeVersionedSlotPointer() async throws {
        let connectionStorage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: connectionStorage)
        let credentials = FaultCredentialStore()
        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )

        model.beginAdd()
        model.draft.displayName = "Remote"
        model.draft.baseURL = "https://provider.example.test/v1"
        model.draft.authMode = .bearer
        model.draft.bearerToken = "new-secret"

        let saved = await model.saveDraft()
        XCTAssertTrue(saved)
        let recordValue = try await connectionStore.connection(id: model.draft.id)
        let record = try XCTUnwrap(recordValue)
        let slotID = try XCTUnwrap(record.credentialSlotID)
        XCTAssertNotEqual(slotID, record.id.rawValue)
        let storedValue = await credentials.credential(for: record.credentialKey)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(try stored.withValue { $0 }, "new-secret")
        let legacyValue = await credentials.credential(
            for: .legacy(connectionID: record.id)
        )
        XCTAssertNil(legacyValue)

        let json = String(
            decoding: try XCTUnwrap(connectionStorage.storedData()),
            as: UTF8.self
        )
        XCTAssertFalse(json.contains("new-secret"))
        XCTAssertTrue(json.contains("credentialSlotID"))
    }

    func testLegacyBearerKeyMigratesToVersionedSlotOnNextSave() async throws {
        let connectionStorage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: connectionStorage)
        let credentials = FaultCredentialStore()
        let original = try makeRecord(id: "legacy-provider", authMode: .bearer)
        try await connectionStore.upsert(original)
        let legacyKey = original.credentialKey
        try await credentials.setCredential(
            ProviderBearerCredential("legacy-secret"),
            for: legacyKey
        )

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )
        await model.start()
        model.draft.displayName = "Renamed"
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)

        let migratedValue = try await connectionStore.connection(id: original.id)
        let migrated = try XCTUnwrap(migratedValue)
        XCTAssertNotNil(migrated.credentialSlotID)
        let migratedCredentialValue = await credentials.credential(
            for: migrated.credentialKey
        )
        let migratedCredential = try XCTUnwrap(migratedCredentialValue)
        XCTAssertEqual(try migratedCredential.withValue { $0 }, "legacy-secret")
        let legacyAfterMigration = await credentials.credential(for: legacyKey)
        XCTAssertNil(legacyAfterMigration)
    }

    func testTokenReplacementLeavesNewSlotAndCleansOldSlotAfterCommit() async throws {
        let connectionStorage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: connectionStorage)
        let credentials = FaultCredentialStore()
        let oldSlot = ProviderConnectionRecord.makeCredentialSlotID()
        let original = try makeRecord(
            id: "replace-provider",
            authMode: .bearer,
            credentialSlotID: oldSlot
        )
        try await connectionStore.upsert(original)
        let oldKey = original.credentialKey
        try await credentials.setCredential(
            ProviderBearerCredential("old-secret"),
            for: oldKey
        )

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )
        await model.start()
        model.draft.bearerToken = "new-secret"
        model.updateDraftBearerToken()
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)

        let replacedValue = try await connectionStore.connection(id: original.id)
        let replaced = try XCTUnwrap(replacedValue)
        XCTAssertNotEqual(replaced.credentialSlotID, oldSlot)
        let newCredentialValue = await credentials.credential(for: replaced.credentialKey)
        let newCredential = try XCTUnwrap(newCredentialValue)
        XCTAssertEqual(try newCredential.withValue { $0 }, "new-secret")
        let oldAfterReplacement = await credentials.credential(for: oldKey)
        XCTAssertNil(oldAfterReplacement)
    }

    func testPrecommitJSONFailureLeavesOldPairAndRemovesNewSlot() async throws {
        let storage = FailingProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentials = FaultCredentialStore()
        let oldSlot = ProviderConnectionRecord.makeCredentialSlotID()
        let original = try makeRecord(
            id: "precommit-provider",
            authMode: .bearer,
            credentialSlotID: oldSlot
        )
        try await connectionStore.upsert(original)
        try await credentials.setCredential(
            ProviderBearerCredential("old-secret"),
            for: original.credentialKey
        )
        storage.failWrites()

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )
        await model.start()
        model.draft.bearerToken = "new-secret"
        model.updateDraftBearerToken()

        let saved = await model.saveDraft()
        XCTAssertFalse(saved)
        let retainedValue = try await connectionStore.connection(id: original.id)
        let retained = try XCTUnwrap(retainedValue)
        XCTAssertEqual(retained.credentialSlotID, oldSlot)
        let retainedCredentialValue = await credentials.credential(
            for: original.credentialKey
        )
        let retainedCredential = try XCTUnwrap(retainedCredentialValue)
        XCTAssertEqual(try retainedCredential.withValue { $0 }, "old-secret")
        let keys = await credentials.credentialKeys(
            forService: ProviderCredentialKey.defaultService
        )
        XCTAssertEqual(keys.map(\.account), [original.credentialKey.account])
    }

    func testPostcommitCleanupFailureStillReportsSuccessAndStartupSweepsOldSlot() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentials = FaultCredentialStore()
        let oldSlot = ProviderConnectionRecord.makeCredentialSlotID()
        let original = try makeRecord(
            id: "cleanup-provider",
            authMode: .bearer,
            credentialSlotID: oldSlot
        )
        try await connectionStore.upsert(original)
        try await credentials.setCredential(
            ProviderBearerCredential("old-secret"),
            for: original.credentialKey
        )
        await credentials.failRemovals()

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )
        await model.start()
        model.draft.bearerToken = "new-secret"
        model.updateDraftBearerToken()
        let saved = await model.saveDraft()
        XCTAssertTrue(saved)

        let committedValue = try await connectionStore.connection(id: original.id)
        let committed = try XCTUnwrap(committedValue)
        XCTAssertNotEqual(committed.credentialSlotID, oldSlot)
        let oldAfterCommit = await credentials.credential(for: original.credentialKey)
        XCTAssertNotNil(oldAfterCommit)

        await credentials.failRemovals(false)
        let reopened = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(storage: storage),
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )
        await reopened.start()
        let oldAfterRestart = await credentials.credential(for: original.credentialKey)
        let newAfterRestart = await credentials.credential(for: committed.credentialKey)
        XCTAssertNil(oldAfterRestart)
        XCTAssertNotNil(newAfterRestart)
    }

    func testDeleteCommitsRecordRemovalBeforeBestEffortCredentialCleanup() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentials = FaultCredentialStore()
        let slot = ProviderConnectionRecord.makeCredentialSlotID()
        let original = try makeRecord(
            id: "delete-provider",
            authMode: .bearer,
            credentialSlotID: slot
        )
        try await connectionStore.upsert(original)
        try await credentials.setCredential(
            ProviderBearerCredential("delete-secret"),
            for: original.credentialKey
        )
        await credentials.failRemovals()

        let model = ProviderSettingsModel(
            connectionStore: connectionStore,
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )
        await model.start()
        let deleted = await model.delete(original.id)
        XCTAssertTrue(deleted)
        let deletedRecord = try await connectionStore.connection(id: original.id)
        XCTAssertNil(deletedRecord)
        let retainedCredential = await credentials.credential(for: original.credentialKey)
        XCTAssertNotNil(retainedCredential)

        await credentials.failRemovals(false)
        let reopened = ProviderSettingsModel(
            connectionStore: ProviderConnectionStore(storage: storage),
            credentialStore: credentials,
            discovery: FailingProviderDiscovery()
        )
        await reopened.start()
        let deletedCredential = await credentials.credential(for: original.credentialKey)
        XCTAssertNil(deletedCredential)
    }

    func testCredentialEnumerationIsLimitedToExactServiceAndSorted() async throws {
        let store = InMemoryCredentialStore()
        let defaultKeys = [
            ProviderCredentialKey(service: ProviderCredentialKey.defaultService, account: "b"),
            ProviderCredentialKey(service: ProviderCredentialKey.defaultService, account: "a"),
        ]
        for (index, key) in defaultKeys.enumerated() {
            try await store.setCredential(
                ProviderBearerCredential("secret-\(index)"),
                for: key
            )
        }
        let other = ProviderCredentialKey(service: "other.service", account: "z")
        try await store.setCredential(ProviderBearerCredential("other"), for: other)

        let keys = try await store.credentialKeys(
            forService: ProviderCredentialKey.defaultService
        )
        XCTAssertEqual(keys.map(\.account), ["a", "b"])
    }

    private func makeRecord(
        id: String,
        authMode: ProviderConnectionAuthMode,
        credentialSlotID: String? = nil
    ) throws -> ProviderConnectionRecord {
        try ProviderConnectionRecord(
            id: ProviderConnectionID(id),
            displayName: id,
            baseURL: URL(string: "https://\(id).example.test/v1")!,
            authMode: authMode,
            transportCapabilities: [.streaming, .streamUsage],
            credentialSlotID: credentialSlotID
        )
    }
}

private struct FailingProviderDiscovery: ProviderModelDiscovery, Sendable {
    func discoverModels(
        for _: ProviderConnectionRecord,
        credential _: ProviderBearerCredential?
    ) async throws -> [ProviderModelDescriptor] {
        throw ProviderModelDiscoveryError.networkFailure
    }
}

private enum ProviderCredentialTransactionTestError: Error {
    case setFailed
    case removeFailed
    case writeFailed
}

private actor FaultCredentialStore: CredentialStore, CredentialStoreKeyListing {
    private var values: [ProviderCredentialKey: ProviderBearerCredential] = [:]
    private var shouldFailSets = false
    private var shouldFailRemovals = false

    func credential(for key: ProviderCredentialKey) -> ProviderBearerCredential? {
        values[key]
    }

    func setCredential(
        _ credential: ProviderBearerCredential,
        for key: ProviderCredentialKey
    ) throws {
        if shouldFailSets {
            throw ProviderCredentialTransactionTestError.setFailed
        }
        values[key] = credential
    }

    func removeCredential(for key: ProviderCredentialKey) throws {
        if shouldFailRemovals {
            throw ProviderCredentialTransactionTestError.removeFailed
        }
        values.removeValue(forKey: key)
    }

    func credentialKeys(forService service: String) -> [ProviderCredentialKey] {
        values.keys
            .filter { $0.service == service }
            .sorted { $0.account < $1.account }
    }

    func failSets(_ value: Bool = true) {
        shouldFailSets = value
    }

    func failRemovals(_ value: Bool = true) {
        shouldFailRemovals = value
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
                throw ProviderCredentialTransactionTestError.writeFailed
            }
            self.data = data
        }
    }

    func failWrites(_ value: Bool = true) {
        lock.withLock { shouldFailWrites = value }
    }
}
