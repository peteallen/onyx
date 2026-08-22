import Foundation
import XCTest
@testable import Onyx

final class ConversationCatalogStoreTests: XCTestCase {
    func testBindingsScopeOpaqueRemoteIDsToAConnection() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = ConversationCatalogStore(fileURL: location.file)
        let remoteID = "provider-thread-42"
        let codex = makeRecord(
            id: "local-codex",
            connectionID: .codexDefault,
            remoteID: remoteID,
            title: "Codex conversation"
        )
        let anotherProvider = makeRecord(
            id: "local-claude",
            connectionID: ProviderConnectionID("anthropic.claude.primary"),
            remoteID: remoteID,
            title: "Claude conversation"
        )

        try await store.upsert(codex)
        try await store.upsert(anotherProvider)

        let records = try await store.conversations()
        XCTAssertEqual(records, [codex, anotherProvider])
        XCTAssertNotEqual(codex.binding, anotherProvider.binding)
        let resolvedCodex = try await store.conversation(boundTo: codex.binding)
        let resolvedOther = try await store.conversation(boundTo: anotherProvider.binding)
        XCTAssertEqual(resolvedCodex?.id, codex.id)
        XCTAssertEqual(resolvedOther?.id, anotherProvider.id)
    }

    func testCatalogPersistsMetadataAndExplicitCrossProviderLineage() async throws {
        let location = temporaryCatalogLocation(nested: true)
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let source = makeRecord(
            id: "source",
            connectionID: .codexDefault,
            remoteID: "codex-thread",
            title: "Original",
            project: ConversationProject(path: "/tmp/project", displayName: "Project"),
            isPinned: true
        )
        let continuation = ConversationContinuation(
            sourceConversationID: source.id,
            sourceBinding: source.binding,
            kind: .crossProvider,
            continuedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let destination = ConversationCatalogRecord(
            id: ConversationID("destination"),
            binding: ProviderConversationBinding(
                connectionID: ProviderConnectionID("openrouter.primary"),
                opaqueRemoteThreadID: "openrouter-thread"
            ),
            lineage: .continuation(continuation),
            title: "Continued elsewhere",
            project: source.project,
            isPinned: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_020),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_030)
        )

        let store = ConversationCatalogStore(fileURL: location.file)
        try await store.upsert(source)
        try await store.upsert(destination)

        let reopened = ConversationCatalogStore(fileURL: location.file)
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.schemaVersion, ConversationCatalogSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.conversations, [source, destination])
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.file.path))

        let persistedText = try String(contentsOf: location.file, encoding: .utf8)
        XCTAssertTrue(persistedText.contains("crossProvider"))
        XCTAssertFalse(persistedText.contains("transcript"))
        XCTAssertFalse(persistedText.contains("credential"))
    }

    func testUpsertAllowsMetadataChangesButRejectsBindingCollisionsAndRebinding() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let original = makeRecord(
            id: "local-one",
            connectionID: .codexDefault,
            remoteID: "remote-one",
            title: "Before"
        )
        let store = ConversationCatalogStore(fileURL: location.file)
        try await store.upsert(original)

        var updated = original
        updated.title = "After"
        updated.project = ConversationProject(path: "/tmp/after")
        updated.isPinned = true
        updated.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        try await store.upsert(updated)
        let storedUpdate = try await store.conversation(id: original.id)
        XCTAssertEqual(storedUpdate, updated)

        let alias = makeRecord(
            id: "local-two",
            connectionID: .codexDefault,
            remoteID: "remote-one",
            title: "Alias"
        )
        do {
            try await store.upsert(alias)
            XCTFail("Expected a provider-binding collision")
        } catch {
            XCTAssertEqual(
                error as? ConversationCatalogError,
                .bindingCollision(
                    original.binding,
                    existingConversationID: original.id,
                    incomingConversationID: alias.id
                )
            )
        }

        let rebound = ConversationCatalogRecord(
            id: original.id,
            binding: ProviderConversationBinding(
                connectionID: ProviderConnectionID("another.connection"),
                opaqueRemoteThreadID: "another-remote"
            ),
            title: "Rebound",
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        do {
            try await store.upsert(rebound)
            XCTFail("Expected an explicit rebind conflict")
        } catch {
            XCTAssertEqual(
                error as? ConversationCatalogError,
                .rebindConflict(
                    original.id,
                    existingBinding: original.binding,
                    incomingBinding: rebound.binding
                )
            )
        }

        let reopened = ConversationCatalogStore(fileURL: location.file)
        let reopenedRecords = try await reopened.conversations()
        XCTAssertEqual(reopenedRecords, [updated])
    }

    func testLineageValidationRejectsProviderKindMismatchesAndCycles() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let store = ConversationCatalogStore(fileURL: location.file)
        let first = makeRecord(
            id: "first",
            connectionID: .codexDefault,
            remoteID: "first-remote",
            title: "First"
        )
        let second = ConversationCatalogRecord(
            id: ConversationID("second"),
            binding: ProviderConversationBinding(
                connectionID: .codexDefault,
                opaqueRemoteThreadID: "second-remote"
            ),
            lineage: .continuation(
                ConversationContinuation(
                    sourceConversationID: first.id,
                    sourceBinding: first.binding,
                    kind: .sameProvider,
                    continuedAt: Date(timeIntervalSince1970: 1_700_000_010)
                )
            ),
            title: "Second",
            createdAt: Date(timeIntervalSince1970: 1_700_000_020),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_020)
        )
        try await store.upsert(first)
        try await store.upsert(second)

        let falseCrossProvider = ConversationCatalogRecord(
            id: ConversationID("false-cross-provider"),
            binding: ProviderConversationBinding(
                connectionID: .codexDefault,
                opaqueRemoteThreadID: "third-remote"
            ),
            lineage: .continuation(
                ConversationContinuation(
                    sourceConversationID: first.id,
                    sourceBinding: first.binding,
                    kind: .crossProvider
                )
            ),
            title: "Invalid"
        )
        await assertThrowsCatalogError(
            { try await store.upsert(falseCrossProvider) },
            matching: { error in
                guard case .invalidLineage(falseCrossProvider.id, _) = error else { return false }
                return true
            }
        )

        let falseSameProvider = ConversationCatalogRecord(
            id: ConversationID("false-same-provider"),
            binding: ProviderConversationBinding(
                connectionID: ProviderConnectionID("openrouter.primary"),
                opaqueRemoteThreadID: "openrouter-thread"
            ),
            lineage: .continuation(
                ConversationContinuation(
                    sourceConversationID: first.id,
                    sourceBinding: first.binding,
                    kind: .sameProvider
                )
            ),
            title: "Invalid"
        )
        await assertThrowsCatalogError(
            { try await store.upsert(falseSameProvider) },
            matching: { error in
                guard case .invalidLineage(falseSameProvider.id, let reason) = error else {
                    return false
                }
                return reason.contains("same-provider")
            }
        )

        var cyclicFirst = first
        cyclicFirst.lineage = .continuation(
            ConversationContinuation(
                sourceConversationID: second.id,
                sourceBinding: second.binding,
                kind: .sameProvider
            )
        )
        await assertThrowsCatalogError(
            { try await store.upsert(cyclicFirst) },
            matching: { error in
                guard case .invalidLineage(_, let reason) = error else { return false }
                return reason.contains("cycle")
            }
        )

        let validRecords = try await store.conversations()
        XCTAssertEqual(validRecords, [first, second])
    }

    func testStoreInstancesReloadBeforeInterleavedMutationsAndReads() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let firstStore = ConversationCatalogStore(fileURL: location.file)
        let secondStore = ConversationCatalogStore(fileURL: location.file)
        let initialFirst = try await firstStore.conversations()
        let initialSecond = try await secondStore.conversations()
        XCTAssertEqual(initialFirst, [])
        XCTAssertEqual(initialSecond, [])

        let first = makeRecord(
            id: "first",
            connectionID: .codexDefault,
            remoteID: "first-remote",
            title: "First"
        )
        let second = makeRecord(
            id: "second",
            connectionID: .codexDefault,
            remoteID: "second-remote",
            title: "Second"
        )

        try await firstStore.upsert(first)
        let observedBySecond = try await secondStore.conversations()
        XCTAssertEqual(observedBySecond, [first])

        try await secondStore.upsert(second)
        let observedByFirst = try await firstStore.conversations()
        XCTAssertEqual(observedByFirst, [first, second])
    }

    func testConcurrentStoreInstancesPreserveEveryUpdate() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let records = (0 ..< 20).map { index in
            makeRecord(
                id: "local-\(index)",
                connectionID: .codexDefault,
                remoteID: "remote-\(index)",
                title: "Conversation \(index)"
            )
        }
        let stores = records.map { _ in ConversationCatalogStore(fileURL: location.file) }

        // Prime every actor before any write. A per-actor snapshot cache would
        // otherwise make every concurrent upsert replace the same empty state.
        for store in stores {
            let initial = try await store.conversations()
            XCTAssertEqual(initial, [])
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (store, record) in zip(stores, records) {
                group.addTask {
                    try await store.upsert(record)
                }
            }
            try await group.waitForAll()
        }

        let reopened = ConversationCatalogStore(fileURL: location.file)
        let persisted = try await reopened.conversations()
        XCTAssertEqual(persisted.count, records.count)
        XCTAssertEqual(Set(persisted.map(\.id)), Set(records.map(\.id)))
    }

    func testVersionZeroMigrationBindsLegacyThreadsToDefaultCodexConnection() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )

        let legacy = LegacyDocument(
            schemaVersion: 0,
            conversations: [
                LegacyRecord(
                    id: ConversationID("legacy"),
                    remoteThreadID: "legacy-thread",
                    title: "Legacy title",
                    projectPath: "/tmp/legacy-project",
                    isPinned: true,
                    createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_600_000_100)
                ),
            ]
        )
        try encodeLegacy(legacy).write(to: location.file, options: .atomic)

        let store = ConversationCatalogStore(fileURL: location.file)
        let snapshot = try await store.snapshot()
        let migrated = try XCTUnwrap(snapshot.conversations.first)
        XCTAssertEqual(snapshot.schemaVersion, ConversationCatalogSnapshot.currentSchemaVersion)
        XCTAssertEqual(migrated.id, ConversationID("legacy"))
        XCTAssertEqual(migrated.binding.connectionID, .codexDefault)
        XCTAssertEqual(migrated.binding.opaqueRemoteThreadID, "legacy-thread")
        XCTAssertEqual(migrated.lineage, .root)
        XCTAssertEqual(migrated.project, ConversationProject(path: "/tmp/legacy-project"))
        XCTAssertTrue(migrated.isPinned)

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: location.file))
        let object = try XCTUnwrap(persisted as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)

        let reopened = ConversationCatalogStore(fileURL: location.file)
        let reopenedSnapshot = try await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot, snapshot)
    }

    func testFailedMigrationLeavesLegacyFileUntouched() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )

        let legacy = LegacyDocument(
            schemaVersion: 0,
            conversations: [
                LegacyRecord(id: ConversationID("one"), remoteThreadID: "duplicate"),
                LegacyRecord(id: ConversationID("two"), remoteThreadID: "duplicate"),
            ]
        )
        let originalData = try encodeLegacy(legacy)
        try originalData.write(to: location.file, options: .atomic)

        let store = ConversationCatalogStore(fileURL: location.file)
        do {
            _ = try await store.snapshot()
            XCTFail("Expected migration to reject the duplicate provider binding")
        } catch {
            guard case .bindingCollision = error as? ConversationCatalogError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: location.file), originalData)
    }

    func testNewerSchemaVersionFailsWithoutOverwritingTheFile() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
        let originalData = try XCTUnwrap("{\"schemaVersion\":999,\"conversations\":[]}".data(using: .utf8))
        try originalData.write(to: location.file)

        let store = ConversationCatalogStore(fileURL: location.file)
        do {
            _ = try await store.snapshot()
            XCTFail("Expected a newer schema to be rejected")
        } catch {
            XCTAssertEqual(error as? ConversationCatalogError, .unsupportedSchemaVersion(999))
        }
        XCTAssertEqual(try Data(contentsOf: location.file), originalData)
    }
}

private extension ConversationCatalogStoreTests {
    struct TemporaryLocation {
        let directory: URL
        let file: URL
    }

    struct LegacyDocument: Encodable {
        let schemaVersion: Int
        let conversations: [LegacyRecord]
    }

    struct LegacyRecord: Encodable {
        let id: ConversationID
        let remoteThreadID: String
        let title: String
        let projectPath: String?
        let isPinned: Bool
        let createdAt: Date
        let updatedAt: Date

        init(
            id: ConversationID,
            remoteThreadID: String,
            title: String = "Legacy",
            projectPath: String? = nil,
            isPinned: Bool = false,
            createdAt: Date = Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date = Date(timeIntervalSince1970: 1_600_000_000)
        ) {
            self.id = id
            self.remoteThreadID = remoteThreadID
            self.title = title
            self.projectPath = projectPath
            self.isPinned = isPinned
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    func temporaryCatalogLocation(nested: Bool = false) -> TemporaryLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        let parent = nested
            ? directory.appendingPathComponent("nested/catalog", isDirectory: true)
            : directory
        return TemporaryLocation(
            directory: directory,
            file: parent.appendingPathComponent("conversations.json")
        )
    }

    func makeRecord(
        id: String,
        connectionID: ProviderConnectionID,
        remoteID: String,
        title: String,
        project: ConversationProject? = nil,
        isPinned: Bool = false
    ) -> ConversationCatalogRecord {
        ConversationCatalogRecord(
            id: ConversationID(id),
            binding: ProviderConversationBinding(
                connectionID: connectionID,
                opaqueRemoteThreadID: remoteID
            ),
            title: title,
            project: project,
            isPinned: isPinned,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func encodeLegacy(_ legacy: LegacyDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(legacy)
    }

    func assertThrowsCatalogError<T>(
        _ expression: () async throws -> T,
        matching predicate: (ConversationCatalogError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected a ConversationCatalogError", file: file, line: line)
        } catch let error as ConversationCatalogError {
            XCTAssertTrue(predicate(error), "Unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
