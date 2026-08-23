import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleConversationStoreTests: XCTestCase {
    func testConnectionScopedIDsAndAtomicTranscriptRoundTrip() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = OpenAICompatibleConversationStore(fileURL: location.file)
        let firstConnection = ProviderConnectionID("provider.first")
        let secondConnection = ProviderConnectionID("provider.second")

        var first = try await store.create(
            connectionID: firstConnection,
            title: "First",
            cwd: "/tmp/first",
            modelID: "same-model",
            now: Date(timeIntervalSince1970: 100)
        )
        let second = try await store.create(
            connectionID: secondConnection,
            title: "Second",
            cwd: "/tmp/second",
            modelID: "same-model",
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.contains(Self.base64URL(firstConnection.rawValue)))
        XCTAssertTrue(second.id.contains(Self.base64URL(secondConnection.rawValue)))

        first.messages = [
            OpenAICompatibleStoredMessage(
                id: "user-1",
                role: .user,
                text: "Hello",
                createdAt: Date(timeIntervalSince1970: 101)
            ),
            OpenAICompatibleStoredMessage(
                id: "assistant-1",
                role: .assistant,
                text: "Hi there",
                createdAt: Date(timeIntervalSince1970: 102),
                detail: "Token usage: total 4"
            ),
        ]
        first.updatedAt = Date(timeIntervalSince1970: 102)
        try await store.upsert(first)

        let reopened = OpenAICompatibleConversationStore(fileURL: location.file)
        let firstThreads = try await reopened.conversations(
            connectionID: firstConnection,
            archived: false
        )
        let secondThreads = try await reopened.conversations(
            connectionID: secondConnection,
            archived: false
        )
        XCTAssertEqual(firstThreads, [first])
        XCTAssertEqual(secondThreads, [second])
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.file.path))
        let persisted = try String(contentsOf: location.file, encoding: .utf8)
        XCTAssertTrue(persisted.contains("Hi there"))
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("bearer"))
    }

    func testInterleavedStoreActorsDoNotLoseUpdates() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let connection = ProviderConnectionID("provider.concurrent")
        let stores = (0 ..< 20).map { _ in
            OpenAICompatibleConversationStore(fileURL: location.file)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, store) in stores.enumerated() {
                group.addTask {
                    _ = try await store.create(
                        connectionID: connection,
                        title: "Conversation \(index)",
                        cwd: nil,
                        modelID: "fixture-model",
                        now: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                }
            }
            try await group.waitForAll()
        }

        let reopened = OpenAICompatibleConversationStore(fileURL: location.file)
        let records = try await reopened.conversations(
            connectionID: connection,
            archived: false,
            limit: 100
        )
        XCTAssertEqual(records.count, 20)
        XCTAssertEqual(Set(records.map(\.title)).count, 20)
    }

    func testLegacyTextOnlyMessageDecodesWithoutContentParts() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let conversation = OpenAICompatibleStoredConversation(
            id: "legacy-conversation",
            connectionID: ProviderConnectionID("provider.legacy"),
            title: "Legacy",
            modelID: "fixture-model",
            messages: [
                OpenAICompatibleStoredMessage(
                    id: "legacy-message",
                    role: .user,
                    text: "Legacy text"
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(
            OpenAICompatibleConversationSnapshot(conversations: [conversation])
        )
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var conversations = try XCTUnwrap(document["conversations"] as? [[String: Any]])
        var messages = try XCTUnwrap(conversations[0]["messages"] as? [[String: Any]])
        messages[0].removeValue(forKey: "contentParts")
        conversations[0]["messages"] = messages
        document["conversations"] = conversations
        try JSONSerialization.data(withJSONObject: document).write(
            to: location.file,
            options: .atomic
        )

        let decoded = try await OpenAICompatibleConversationStore(fileURL: location.file)
            .snapshot()
        let message = try XCTUnwrap(decoded.conversations.first?.messages.first)
        XCTAssertEqual(message.contentParts, [.text("Legacy text")])
        XCTAssertEqual(message.chatMessage?.parts, [.text("Legacy text")])
        XCTAssertTrue(message.timelineItem.attachments.isEmpty)
    }

    func testOrderedImagePartsRoundTripAndProjectStableAttachments() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = OpenAICompatibleConversationStore(fileURL: location.file)
        let connectionID = ProviderConnectionID("provider.images")
        var conversation = try await store.create(
            connectionID: connectionID,
            title: "Images",
            cwd: nil,
            modelID: "vision-model"
        )
        let dataURL = "data:image/png;base64,AA=="
        let remoteURL = "https://images.example/reference.png"
        conversation.messages = [
            OpenAICompatibleStoredMessage(
                id: "ordered-user-message",
                role: .user,
                text: "Before\nAfter",
                contentParts: [
                    .text("Before"),
                    .imageURL(dataURL),
                    .text("After"),
                    .imageURL(remoteURL),
                ]
            ),
        ]
        try await store.upsert(conversation)

        let reopened = OpenAICompatibleConversationStore(fileURL: location.file)
        let persisted = try await reopened.conversation(
            connectionID: connectionID,
            id: conversation.id
        )
        let reloaded = try XCTUnwrap(persisted)
        XCTAssertEqual(reloaded.messages[0].contentParts, conversation.messages[0].contentParts)
        XCTAssertEqual(
            reloaded.messages[0].chatMessage?.parts,
            [
                .text("Before"),
                .imageURL(dataURL),
                .text("After"),
                .imageURL(remoteURL),
            ]
        )

        let item = reloaded.runtimeConversation(kind: .local).items[0]
        XCTAssertEqual(item.body, "Before\nAfter")
        XCTAssertEqual(item.attachments.map(\.id), [
            "ordered-user-message:image:1",
            "ordered-user-message:image:3",
        ])
        XCTAssertEqual(item.attachments.map(\.source), [
            .dataURL(dataURL),
            .remoteURL(try XCTUnwrap(URL(string: remoteURL))),
        ])
        XCTAssertEqual(item.attachments.map(\.cacheIdentity), item.attachments.map(\.id))
    }

    func testAtomicUpdateAppliesMessageMutationWithoutDroppingConversationMetadata() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = OpenAICompatibleConversationStore(fileURL: location.file)
        let connection = ProviderConnectionID("provider.atomic-update")
        let created = try await store.create(
            connectionID: connection,
            title: "Keep this title",
            cwd: "/tmp/project",
            modelID: "fixture-model"
        )
        let seeded = try await store.update(connectionID: connection, id: created.id) { record in
            record.isArchived = true
            record.messages.append(OpenAICompatibleStoredMessage(
                id: "assistant-1",
                role: .assistant,
                text: "before"
            ))
        }
        XCTAssertTrue(seeded.isArchived)

        let updated = try await store.update(connectionID: connection, id: created.id) { record in
            record.messages[0].text = "after"
            record.messages[0].status = .completed
        }
        XCTAssertEqual(updated.title, "Keep this title")
        XCTAssertEqual(updated.cwd, "/tmp/project")
        XCTAssertTrue(updated.isArchived)
        XCTAssertEqual(updated.messages[0].text, "after")
    }

    func testRecoveryMarksPersistedRunningTurnFailedWithoutDroppingText() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let connection = ProviderConnectionID("provider.recovery")
        let store = OpenAICompatibleConversationStore(fileURL: location.file)
        var conversation = try await store.create(
            connectionID: connection,
            title: "Recovery",
            cwd: nil,
            modelID: "fixture-model"
        )
        conversation.status = .running
        conversation.messages = [
            OpenAICompatibleStoredMessage(
                id: "assistant-running",
                role: .assistant,
                text: "Partial text",
                status: .running
            ),
        ]
        try await store.upsert(conversation)

        let recovered = try await store.recoverInterruptedTurns(
            connectionID: connection,
            now: Date(timeIntervalSince1970: 999)
        )
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].status, .failed)
        XCTAssertEqual(recovered[0].messages[0].status, .failed)
        XCTAssertEqual(recovered[0].messages[0].text, "Partial text")
        XCTAssertEqual(
            recovered[0].messages[0].detail,
            "The app closed before this response finished."
        )
    }

    func testScopedRecoveryRepairsCompletedEmptyAssistantWithoutGuessingUnscopedHistory() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let connection = ProviderConnectionID("provider.empty-repair")
        let scope = "scope.provider-empty-repair"
        let otherScope = "scope.other-provider"
        let store = OpenAICompatibleConversationStore(fileURL: location.file)

        var scoped = try await store.create(
            connectionID: connection,
            title: "Empty response",
            cwd: "/tmp/project",
            modelID: "Qwen/Qwen3.8-27B-FP8",
            scopeID: scope
        )
        scoped.messages = [
            OpenAICompatibleStoredMessage(role: .user, text: "Build the page"),
            OpenAICompatibleStoredMessage(
                role: .assistant,
                text: " \n",
                status: .completed,
                detail: "Token usage: prompt 66, response 2048, total 2114"
            ),
        ]
        try await store.upsert(scoped)

        var other = try await store.create(
            connectionID: connection,
            title: "Other endpoint",
            cwd: "/tmp/other",
            modelID: "same-model",
            scopeID: otherScope
        )
        other.messages = [
            OpenAICompatibleStoredMessage(role: .user, text: "Keep this history"),
            OpenAICompatibleStoredMessage(role: .assistant, text: "", status: .completed),
        ]
        try await store.upsert(other)

        let repaired = try await store.recoverInterruptedTurns(
            connectionID: connection,
            scopeID: scope,
            now: Date(timeIntervalSince1970: 999)
        )
        XCTAssertEqual(repaired.map(\.id), [scoped.id])
        XCTAssertEqual(repaired[0].status, .failed)
        XCTAssertEqual(repaired[0].updatedAt, Date(timeIntervalSince1970: 999))
        let repairedMessage = try XCTUnwrap(repaired[0].messages.last)
        XCTAssertEqual(repairedMessage.status, .failed)
        XCTAssertTrue(repairedMessage.detail?.contains("without returning an answer") == true)
        XCTAssertTrue(repairedMessage.detail?.contains("lower reasoning level") == true)
        XCTAssertFalse(repairedMessage.detail?.contains("Token usage") == true)

        let reloadedRecord = try await store.conversation(
            connectionID: connection,
            id: scoped.id,
            scopeID: scope
        )
        let reloaded = try XCTUnwrap(reloadedRecord)
        XCTAssertEqual(reloaded.runtimeConversation(kind: .local).items.map(\.kind), [
            .userMessage,
            .error,
        ])
        XCTAssertEqual(
            reloaded.runtimeConversation(kind: .local).items.last?.body,
            repairedMessage.detail
        )

        // The repair is idempotent and does not rewrite an unrelated scope.
        let secondRepair = try await store.recoverInterruptedTurns(
            connectionID: connection,
            scopeID: scope,
            now: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertTrue(secondRepair.isEmpty)
        let untouchedRecord = try await store.conversation(
            connectionID: connection,
            id: other.id,
            scopeID: otherScope
        )
        let untouched = try XCTUnwrap(untouchedRecord)
        XCTAssertEqual(untouched.status, .idle)
        XCTAssertEqual(untouched.messages.last?.status, .completed)
        XCTAssertNil(untouched.messages.last?.detail)
    }

    func testEmptyAssistantRepairRequiresExplicitScope() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let connection = ProviderConnectionID("provider.empty-repair-unscoped")
        let store = OpenAICompatibleConversationStore(fileURL: location.file)
        var conversation = try await store.create(
            connectionID: connection,
            title: "Legacy empty response",
            cwd: nil,
            modelID: "fixture-model"
        )
        conversation.messages = [
            OpenAICompatibleStoredMessage(role: .assistant, text: "", status: .completed),
        ]
        try await store.upsert(conversation)

        let unscopedRepair = try await store.recoverInterruptedTurns(connectionID: connection)
        XCTAssertTrue(unscopedRepair.isEmpty)
        let unchangedRecord = try await store.conversation(
            connectionID: connection,
            id: conversation.id
        )
        let unchanged = try XCTUnwrap(unchangedRecord)
        XCTAssertEqual(unchanged.status, .idle)
        XCTAssertEqual(unchanged.messages[0].status, .completed)
    }

    func testValidationRejectsFutureSchemaAndDuplicateScopedIDs() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(
            at: location.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"schemaVersion\":99,\"conversations\":[]}".utf8)
            .write(to: location.file, options: .atomic)
        let future = OpenAICompatibleConversationStore(fileURL: location.file)
        do {
            _ = try await future.snapshot()
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleConversationStoreError,
                .unsupportedSchemaVersion(99)
            )
        }

        let connection = ProviderConnectionID("provider.duplicate")
        let duplicate = OpenAICompatibleStoredConversation(
            id: "same-id",
            connectionID: connection,
            title: "Duplicate",
            modelID: "fixture-model"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(
            OpenAICompatibleConversationSnapshot(conversations: [duplicate, duplicate])
        ).write(to: location.file, options: .atomic)
        let duplicateStore = OpenAICompatibleConversationStore(fileURL: location.file)
        do {
            _ = try await duplicateStore.snapshot()
            XCTFail("Expected duplicate conversation")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleConversationStoreError,
                .duplicateConversation(connectionID: connection, id: "same-id")
            )
        }
    }

    private func temporaryLocation() -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAICompatibleConversationStoreTests-\(UUID().uuidString)")
        return (directory, directory.appendingPathComponent("nested/conversations.json"))
    }

    private static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
