import Foundation

enum OpenAICompatibleConversationStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformedDocument(String)
    case emptyConnectionID
    case emptyConversationID
    case emptyTitle
    case emptyModelID
    case duplicateConversation(connectionID: ProviderConnectionID, id: String)
    case duplicateMessageID(conversationID: String, messageID: String)
    case conversationNotFound(connectionID: ProviderConnectionID, id: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "OpenAI-compatible conversation schema version \(version) is not supported."
        case let .malformedDocument(detail):
            "OpenAI-compatible conversations could not be read: \(detail)"
        case .emptyConnectionID:
            "A provider conversation has an empty connection ID."
        case .emptyConversationID:
            "A provider conversation has an empty conversation ID."
        case .emptyTitle:
            "A provider conversation title cannot be empty."
        case .emptyModelID:
            "A provider conversation model cannot be empty."
        case let .duplicateConversation(connectionID, id):
            "Conversation \(id) appears more than once for provider connection \(connectionID)."
        case let .duplicateMessageID(conversationID, messageID):
            "Message \(messageID) appears more than once in conversation \(conversationID)."
        case let .conversationNotFound(connectionID, id):
            "Conversation \(id) does not exist for provider connection \(connectionID)."
        }
    }
}

/// Versioned, atomic persistence for chat-style providers whose APIs do not
/// supply durable thread storage. Every transaction reloads the file while a
/// process-local per-path lock is held, so separate runtime actors cannot
/// replace each other's connection-scoped histories with stale snapshots.
actor OpenAICompatibleConversationStore {
    let fileURL: URL

    private static let fileAccess = OpenAICompatibleConversationFileAccess.shared

    init(fileURL: URL = OpenAICompatibleConversationStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func snapshot() throws -> OpenAICompatibleConversationSnapshot {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk()
        }
    }

    func conversations(
        connectionID: ProviderConnectionID,
        archived: Bool,
        limit: Int = 100
    ) throws -> [OpenAICompatibleStoredConversation] {
        try Self.fileAccess.withLock(for: fileURL) {
            let maximum = max(0, limit)
            return Array(
                try loadFromDisk().conversations
                    .filter { $0.connectionID == connectionID && $0.isArchived == archived }
                    .sorted { lhs, rhs in
                        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                        return lhs.id < rhs.id
                    }
                    .prefix(maximum)
            )
        }
    }

    func conversation(
        connectionID: ProviderConnectionID,
        id: String
    ) throws -> OpenAICompatibleStoredConversation? {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk().conversations.first {
                $0.connectionID == connectionID && $0.id == id
            }
        }
    }

    @discardableResult
    func create(
        connectionID: ProviderConnectionID,
        title: String,
        cwd: String?,
        modelID: String,
        now: Date = .now
    ) throws -> OpenAICompatibleStoredConversation {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            let record = OpenAICompatibleStoredConversation(
                id: Self.makeConversationID(connectionID: connectionID),
                connectionID: connectionID,
                title: title,
                cwd: cwd,
                modelID: modelID,
                createdAt: now,
                updatedAt: now
            )
            let next = OpenAICompatibleConversationSnapshot(
                conversations: current.conversations + [record]
            )
            try Self.validate(next)
            try persist(next)
            return record
        }
    }

    @discardableResult
    func upsert(
        _ incoming: OpenAICompatibleStoredConversation
    ) throws -> OpenAICompatibleStoredConversation {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            var candidate = current.conversations
            if let index = candidate.firstIndex(where: {
                $0.connectionID == incoming.connectionID && $0.id == incoming.id
            }) {
                candidate[index] = incoming
            } else {
                candidate.append(incoming)
            }
            let next = OpenAICompatibleConversationSnapshot(conversations: candidate)
            try Self.validate(next)
            try persist(next)
            return incoming
        }
    }

    @discardableResult
    func remove(
        connectionID: ProviderConnectionID,
        id: String
    ) throws -> OpenAICompatibleStoredConversation? {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            guard let index = current.conversations.firstIndex(where: {
                $0.connectionID == connectionID && $0.id == id
            }) else { return nil }
            var candidate = current.conversations
            let removed = candidate.remove(at: index)
            let next = OpenAICompatibleConversationSnapshot(conversations: candidate)
            try Self.validate(next)
            try persist(next)
            return removed
        }
    }

    /// A process exit can leave the last atomic snapshot marked as running.
    /// On reconnect that state is made truthful before it reaches the task
    /// list; completed text is retained and only the unfinished item changes.
    @discardableResult
    func recoverInterruptedTurns(
        connectionID: ProviderConnectionID,
        now: Date = .now
    ) throws -> [OpenAICompatibleStoredConversation] {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            var candidate = current.conversations
            var recovered: [OpenAICompatibleStoredConversation] = []
            for index in candidate.indices
            where candidate[index].connectionID == connectionID
                && candidate[index].status == .running
            {
                candidate[index].status = .failed
                candidate[index].updatedAt = now
                for messageIndex in candidate[index].messages.indices
                where candidate[index].messages[messageIndex].status == .running
                {
                    candidate[index].messages[messageIndex].status = .failed
                    candidate[index].messages[messageIndex].detail =
                        "The app closed before this response finished."
                }
                recovered.append(candidate[index])
            }
            guard !recovered.isEmpty else { return [] }
            let next = OpenAICompatibleConversationSnapshot(conversations: candidate)
            try Self.validate(next)
            try persist(next)
            return recovered
        }
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Onyx", isDirectory: true)
            .appendingPathComponent("openai-compatible-conversations.json", isDirectory: false)
    }

    private func loadFromDisk() throws -> OpenAICompatibleConversationSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return OpenAICompatibleConversationSnapshot()
        }
        do {
            let snapshot = try Self.decoder.decode(
                OpenAICompatibleConversationSnapshot.self,
                from: Data(contentsOf: fileURL)
            )
            try Self.validate(snapshot)
            return snapshot
        } catch let error as OpenAICompatibleConversationStoreError {
            throw error
        } catch {
            throw OpenAICompatibleConversationStoreError.malformedDocument(
                error.localizedDescription
            )
        }
    }

    private func persist(_ snapshot: OpenAICompatibleConversationSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static func validate(_ snapshot: OpenAICompatibleConversationSnapshot) throws {
        guard snapshot.schemaVersion == OpenAICompatibleConversationSnapshot.currentSchemaVersion
        else {
            throw OpenAICompatibleConversationStoreError.unsupportedSchemaVersion(
                snapshot.schemaVersion
            )
        }

        struct ConversationKey: Hashable {
            let connectionID: ProviderConnectionID
            let id: String
        }
        var conversationKeys: Set<ConversationKey> = []
        for conversation in snapshot.conversations {
            guard !conversation.connectionID.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAICompatibleConversationStoreError.emptyConnectionID
            }
            guard !conversation.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAICompatibleConversationStoreError.emptyConversationID
            }
            guard !conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAICompatibleConversationStoreError.emptyTitle
            }
            guard !conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAICompatibleConversationStoreError.emptyModelID
            }
            let key = ConversationKey(
                connectionID: conversation.connectionID,
                id: conversation.id
            )
            guard conversationKeys.insert(key).inserted else {
                throw OpenAICompatibleConversationStoreError.duplicateConversation(
                    connectionID: conversation.connectionID,
                    id: conversation.id
                )
            }
            var messageIDs: Set<String> = []
            for message in conversation.messages {
                guard !message.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw OpenAICompatibleConversationStoreError.duplicateMessageID(
                        conversationID: conversation.id,
                        messageID: message.id
                    )
                }
                guard messageIDs.insert(message.id).inserted else {
                    throw OpenAICompatibleConversationStoreError.duplicateMessageID(
                        conversationID: conversation.id,
                        messageID: message.id
                    )
                }
            }
        }
    }

    private static func makeConversationID(connectionID: ProviderConnectionID) -> String {
        let scoped = Data(connectionID.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "openai.\(scoped).\(UUID().uuidString.lowercased())"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private final class OpenAICompatibleConversationFileAccess: @unchecked Sendable {
    static let shared = OpenAICompatibleConversationFileAccess()

    private let registryLock = NSLock()
    private var locksByPath: [String: NSLock] = [:]

    func withLock<T>(for fileURL: URL, _ operation: () throws -> T) rethrows -> T {
        let fileLock = lock(for: fileURL)
        fileLock.lock()
        defer { fileLock.unlock() }
        return try operation()
    }

    private func lock(for fileURL: URL) -> NSLock {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locksByPath[path] { return existing }
        let created = NSLock()
        locksByPath[path] = created
        return created
    }
}
