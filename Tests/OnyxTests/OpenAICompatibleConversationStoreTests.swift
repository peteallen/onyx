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
