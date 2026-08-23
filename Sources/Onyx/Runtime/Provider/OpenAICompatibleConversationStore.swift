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
    private let beforePersist: (@Sendable (OpenAICompatibleConversationSnapshot) throws -> Void)?

    init(
        fileURL: URL = OpenAICompatibleConversationStore.defaultFileURL(),
        beforePersist: (@Sendable (OpenAICompatibleConversationSnapshot) throws -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.beforePersist = beforePersist
    }

    func snapshot() throws -> OpenAICompatibleConversationSnapshot {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk()
        }
    }

    func conversations(
        connectionID: ProviderConnectionID,
        scopeID: String? = nil,
        archived: Bool,
        limit: Int = 100
    ) throws -> [OpenAICompatibleStoredConversation] {
        try Self.fileAccess.withLock(for: fileURL) {
            let maximum = max(0, limit)
            return Array(
                try loadFromDisk().conversations
                    .filter {
                        $0.connectionID == connectionID
                            && $0.isArchived == archived
                            && (scopeID == nil || $0.belongs(to: scopeID!))
                    }
                    .sorted { lhs, rhs in
                        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                        return lhs.id < rhs.id
                    }
                    .prefix(maximum)
            )
        }
    }

    /// Assigns legacy conversations written before provider scope isolation to
    /// the connection's current scope. This is intentionally an explicit
    /// migration step rather than a broad `nil` match in `conversations`:
    /// after an endpoint or credential rotation, an old record must stay in
    /// its previous scope and never be replayed to the replacement backend.
    @discardableResult
    func migrateLegacyConversations(
        connectionID: ProviderConnectionID,
        to scopeID: String
    ) throws -> Int {
        let normalizedScopeID = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedScopeID.isEmpty else { return 0 }
        return try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            var candidate = current.conversations
            var migrated = 0
            for index in candidate.indices
            where candidate[index].connectionID == connectionID
                && candidate[index].conversationScopeID == nil
            {
                candidate[index].conversationScopeID = normalizedScopeID
                migrated += 1
            }
            guard migrated > 0 else { return 0 }
            let next = OpenAICompatibleConversationSnapshot(conversations: candidate)
            try Self.validate(next)
            try persist(next)
            return migrated
        }
    }

    func conversation(
        connectionID: ProviderConnectionID,
        id: String,
        scopeID: String? = nil
    ) throws -> OpenAICompatibleStoredConversation? {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk().conversations.first {
                $0.connectionID == connectionID
                    && $0.id == id
                    && (scopeID == nil || $0.belongs(to: scopeID!))
            }
        }
    }

    @discardableResult
    func create(
        connectionID: ProviderConnectionID,
        title: String,
        cwd: String?,
        modelID: String,
        scopeID: String? = nil,
        now: Date = .now
    ) throws -> OpenAICompatibleStoredConversation {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            let record = OpenAICompatibleStoredConversation(
                id: Self.makeConversationID(connectionID: connectionID),
                connectionID: connectionID,
                conversationScopeID: scopeID,
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

    /// Mutates an existing conversation as one read-modify-write transaction.
    /// Runtime code uses this instead of pairing `conversation` with `upsert`:
    /// a streamed message update must not replace a rename/archive change that
    /// landed after the stream read its history, and a deleted conversation
    /// must never be recreated by a late stream callback.
    @discardableResult
    func update(
        connectionID: ProviderConnectionID,
        id: String,
        scopeID: String? = nil,
        _ mutation: @Sendable (inout OpenAICompatibleStoredConversation) throws -> Void
    ) throws -> OpenAICompatibleStoredConversation {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            var candidate = current.conversations
            guard let index = candidate.firstIndex(where: {
                $0.connectionID == connectionID
                    && $0.id == id
                    && (scopeID == nil || $0.belongs(to: scopeID!))
            }) else {
                throw OpenAICompatibleConversationStoreError.conversationNotFound(
                    connectionID: connectionID,
                    id: id
                )
            }
            if let scopeID, candidate[index].conversationScopeID == nil {
                candidate[index].conversationScopeID = scopeID
            }
            try mutation(&candidate[index])
            let next = OpenAICompatibleConversationSnapshot(conversations: candidate)
            try Self.validate(next)
            try persist(next)
            return candidate[index]
        }
    }

    @discardableResult
    func remove(
        connectionID: ProviderConnectionID,
        id: String,
        scopeID: String? = nil
    ) throws -> OpenAICompatibleStoredConversation? {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            guard let index = current.conversations.firstIndex(where: {
                $0.connectionID == connectionID
                    && $0.id == id
                    && (scopeID == nil || $0.belongs(to: scopeID!))
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
    ///
    /// This also repairs one narrow legacy shape: an older provider turn could
    /// persist an assistant message as `completed` with no answer text after
    /// the upstream had exhausted its response budget. That shape is repaired
    /// only when a concrete scope is supplied; without one, the endpoint that
    /// produced an old unscoped record is unknown.
    @discardableResult
    func recoverInterruptedTurns(
        connectionID: ProviderConnectionID,
        scopeID: String? = nil,
        now: Date = .now
    ) throws -> [OpenAICompatibleStoredConversation] {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            var candidate = current.conversations
            var recovered: [OpenAICompatibleStoredConversation] = []
            for index in candidate.indices
            where candidate[index].connectionID == connectionID
                && (scopeID == nil || candidate[index].belongs(to: scopeID!))
            {
                let legacyEmptyAssistantIndices: [Int] = if scopeID != nil {
                    candidate[index].messages.indices.filter { messageIndex in
                        let message = candidate[index].messages[messageIndex]
                        return message.role == .assistant
                            && message.status == .completed
                            && message.text
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                } else {
                    []
                }
                guard candidate[index].status == .running
                    || !legacyEmptyAssistantIndices.isEmpty
                else {
                    continue
                }

                var changed = false
                if let scopeID, candidate[index].conversationScopeID == nil {
                    candidate[index].conversationScopeID = scopeID
                    changed = true
                }

                if candidate[index].status == .running {
                    candidate[index].status = .failed
                    changed = true
                    for messageIndex in candidate[index].messages.indices
                    where candidate[index].messages[messageIndex].status == .running
                    {
                        candidate[index].messages[messageIndex].status = .failed
                        candidate[index].messages[messageIndex].detail =
                            "The app closed before this response finished."
                    }
                }

                // Do not infer a finish reason from a sparse legacy record.
                // Preserve useful usage/error detail when it exists, but make
                // the result actionable and explicit in the transcript.
                for messageIndex in legacyEmptyAssistantIndices {
                    let existingDetail = candidate[index].messages[messageIndex].detail
                    candidate[index].messages[messageIndex].status = .failed
                    candidate[index].messages[messageIndex].detail =
                        Self.repairedEmptyAssistantDetail(existingDetail)
                    changed = true
                }

                guard changed else { continue }
                candidate[index].status = .failed
                candidate[index].updatedAt = now
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
        try beforePersist?(snapshot)
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

    /// Builds a user-facing repair detail without claiming a finish reason
    /// that was not persisted. Usage-only metadata from the old runtime is not
    /// conversation content and stays hidden; an explicit provider limit/error
    /// detail is retained and receives a retry hint when needed.
    private static func repairedEmptyAssistantDetail(_ existing: String?) -> String {
        let detail = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowercased = detail.lowercased()
        let hasKnownFailureSignal = lowercased.contains("response limit")
            || lowercased.contains("output limit")
            || lowercased.contains("max_tokens")
            || lowercased.contains("max completion")
            || lowercased.contains("no final answer")
        if hasKnownFailureSignal {
            if lowercased.contains("retry") { return detail }
            return "\(detail) Retry with a lower reasoning level or a larger output limit."
        }

        let generic = "The provider completed without returning an answer. Retry this request; if it repeats, try a lower reasoning level or a larger output limit."
        guard !detail.isEmpty,
              !lowercased.hasPrefix("token usage:")
        else { return generic }
        return "\(generic) \(detail)"
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
