import Foundation

enum ConversationCatalogError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformedDocument(String)
    case emptyConversationID
    case emptyRemoteThreadID(ConversationID)
    case duplicateConversationID(ConversationID)
    case bindingCollision(
        ProviderConversationBinding,
        existingConversationID: ConversationID,
        incomingConversationID: ConversationID
    )
    case rebindConflict(
        ConversationID,
        existingBinding: ProviderConversationBinding,
        incomingBinding: ProviderConversationBinding
    )
    case invalidLineage(ConversationID, reason: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Conversation catalog schema version \(version) is not supported."
        case let .malformedDocument(detail):
            "The conversation catalog could not be read: \(detail)"
        case .emptyConversationID:
            "A conversation has an empty app-owned ID."
        case let .emptyRemoteThreadID(id):
            "Conversation \(id) has an empty provider thread ID."
        case let .duplicateConversationID(id):
            "The conversation ID \(id) appears more than once."
        case let .bindingCollision(binding, existingID, incomingID):
            "Provider thread \(binding.opaqueRemoteThreadID) on \(binding.connectionID) is already bound to \(existingID), so it cannot also bind to \(incomingID)."
        case let .rebindConflict(id, existing, incoming):
            "Conversation \(id) is already bound to \(existing.connectionID)/\(existing.opaqueRemoteThreadID), not \(incoming.connectionID)/\(incoming.opaqueRemoteThreadID)."
        case let .invalidLineage(id, reason):
            "Conversation \(id) has invalid lineage: \(reason)"
        }
    }
}

/// A small serialized catalog for app-owned conversation metadata. Mutations
/// for the same file are coordinated across store actors, reload the latest
/// snapshot before editing, validate before commit, and use an atomic
/// replacement write.
actor ConversationCatalogStore {
    let fileURL: URL

    private static let fileAccess = ConversationCatalogFileAccess.shared

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func snapshot() throws -> ConversationCatalogSnapshot {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk()
        }
    }

    func conversations() throws -> [ConversationCatalogRecord] {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk().conversations
        }
    }

    func conversation(id: ConversationID) throws -> ConversationCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk().conversations.first { $0.id == id }
        }
    }

    func conversation(
        boundTo binding: ProviderConversationBinding
    ) throws -> ConversationCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk().conversations.first { $0.binding == binding }
        }
    }

    /// Updates mutable catalog metadata for an existing local/binding pair or
    /// inserts a new pair. Rebinding a local ID and aliasing one remote binding
    /// to two local IDs are both explicit conflicts.
    @discardableResult
    func upsert(_ incoming: ConversationCatalogRecord) throws -> ConversationCatalogRecord {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            var candidate = current.conversations

            let localIndex = candidate.firstIndex { $0.id == incoming.id }
            let bindingIndex = candidate.firstIndex { $0.binding == incoming.binding }

            if let localIndex {
                let existing = candidate[localIndex]
                guard existing.binding == incoming.binding else {
                    throw ConversationCatalogError.rebindConflict(
                        incoming.id,
                        existingBinding: existing.binding,
                        incomingBinding: incoming.binding
                    )
                }
                if let bindingIndex, bindingIndex != localIndex {
                    throw ConversationCatalogError.bindingCollision(
                        incoming.binding,
                        existingConversationID: candidate[bindingIndex].id,
                        incomingConversationID: incoming.id
                    )
                }
                candidate[localIndex] = incoming
            } else if let bindingIndex {
                throw ConversationCatalogError.bindingCollision(
                    incoming.binding,
                    existingConversationID: candidate[bindingIndex].id,
                    incomingConversationID: incoming.id
                )
            } else {
                candidate.append(incoming)
            }

            let next = ConversationCatalogSnapshot(conversations: candidate)
            try Self.validate(next)
            try persist(next)
            return incoming
        }
    }

    @discardableResult
    func remove(id: ConversationID) throws -> ConversationCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            guard let index = current.conversations.firstIndex(where: { $0.id == id }) else {
                return nil
            }

            var candidate = current.conversations
            let removed = candidate.remove(at: index)
            let next = ConversationCatalogSnapshot(conversations: candidate)
            try Self.validate(next)
            try persist(next)
            return removed
        }
    }

    /// Must be called while holding this catalog file's process-local lock.
    private func loadFromDisk() throws -> ConversationCatalogSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ConversationCatalogSnapshot()
        }

        let data = try Data(contentsOf: fileURL)
        let probe: SchemaVersionProbe
        do {
            probe = try Self.decoder.decode(SchemaVersionProbe.self, from: data)
        } catch {
            throw ConversationCatalogError.malformedDocument(error.localizedDescription)
        }

        let version = probe.schemaVersion ?? 0
        let decoded: ConversationCatalogSnapshot
        let needsMigration: Bool

        do {
            switch version {
            case 0:
                decoded = try Self.migrateV0(
                    Self.decoder.decode(LegacyConversationCatalogV0.self, from: data)
                )
                needsMigration = true
            case ConversationCatalogSnapshot.currentSchemaVersion:
                decoded = try Self.decoder.decode(ConversationCatalogSnapshot.self, from: data)
                needsMigration = false
            default:
                throw ConversationCatalogError.unsupportedSchemaVersion(version)
            }
        } catch let error as ConversationCatalogError {
            throw error
        } catch {
            throw ConversationCatalogError.malformedDocument(error.localizedDescription)
        }

        try Self.validate(decoded)
        if needsMigration {
            try persist(decoded)
        }
        return decoded
    }

    private func persist(_ snapshot: ConversationCatalogSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func migrateV0(
        _ legacy: LegacyConversationCatalogV0
    ) throws -> ConversationCatalogSnapshot {
        let records = legacy.conversations.map { conversation in
            ConversationCatalogRecord(
                id: conversation.id,
                binding: ProviderConversationBinding(
                    connectionID: .codexDefault,
                    opaqueRemoteThreadID: conversation.remoteThreadID
                ),
                lineage: .root,
                title: conversation.title,
                project: conversation.projectPath.map { ConversationProject(path: $0) },
                isPinned: conversation.isPinned,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt
            )
        }
        let migrated = ConversationCatalogSnapshot(conversations: records)
        try validate(migrated)
        return migrated
    }

    private static func validate(_ snapshot: ConversationCatalogSnapshot) throws {
        guard snapshot.schemaVersion == ConversationCatalogSnapshot.currentSchemaVersion else {
            throw ConversationCatalogError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }

        var recordsByID: [ConversationID: ConversationCatalogRecord] = [:]
        var IDsByBinding: [ProviderConversationBinding: ConversationID] = [:]

        for record in snapshot.conversations {
            guard !record.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationCatalogError.emptyConversationID
            }
            guard !record.binding.opaqueRemoteThreadID
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ConversationCatalogError.emptyRemoteThreadID(record.id)
            }
            guard recordsByID.updateValue(record, forKey: record.id) == nil else {
                throw ConversationCatalogError.duplicateConversationID(record.id)
            }
            if let existingID = IDsByBinding.updateValue(record.id, forKey: record.binding) {
                throw ConversationCatalogError.bindingCollision(
                    record.binding,
                    existingConversationID: existingID,
                    incomingConversationID: record.id
                )
            }
        }

        for record in snapshot.conversations {
            guard case let .continuation(continuation) = record.lineage else { continue }
            guard continuation.sourceConversationID != record.id else {
                throw ConversationCatalogError.invalidLineage(
                    record.id,
                    reason: "a conversation cannot continue itself"
                )
            }
            switch continuation.kind {
            case .sameProvider where continuation.sourceBinding.connectionID != record.binding.connectionID:
                throw ConversationCatalogError.invalidLineage(
                    record.id,
                    reason: "a same-provider continuation must keep its provider connection"
                )
            case .crossProvider where continuation.sourceBinding.connectionID == record.binding.connectionID:
                throw ConversationCatalogError.invalidLineage(
                    record.id,
                    reason: "a cross-provider continuation must change provider connections"
                )
            default:
                break
            }
            if let source = recordsByID[continuation.sourceConversationID],
               source.binding != continuation.sourceBinding
            {
                throw ConversationCatalogError.invalidLineage(
                    record.id,
                    reason: "the captured source binding does not match the source conversation"
                )
            }
        }

        try validateAcyclicLineage(snapshot.conversations, recordsByID: recordsByID)
    }

    private static func validateAcyclicLineage(
        _ records: [ConversationCatalogRecord],
        recordsByID: [ConversationID: ConversationCatalogRecord]
    ) throws {
        enum VisitState {
            case visiting
            case visited
        }

        var states: [ConversationID: VisitState] = [:]

        func visit(_ record: ConversationCatalogRecord) throws {
            switch states[record.id] {
            case .visiting:
                throw ConversationCatalogError.invalidLineage(
                    record.id,
                    reason: "the continuation chain contains a cycle"
                )
            case .visited:
                return
            case nil:
                break
            }

            states[record.id] = .visiting
            if case let .continuation(continuation) = record.lineage,
               let source = recordsByID[continuation.sourceConversationID]
            {
                try visit(source)
            }
            states[record.id] = .visited
        }

        for record in records {
            try visit(record)
        }
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

private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int?
}

/// Schema zero was the implicit Codex-only shape. It is intentionally private:
/// only migration code can create current catalog records from it.
private struct LegacyConversationCatalogV0: Decodable {
    let schemaVersion: Int?
    let conversations: [LegacyConversationCatalogRecordV0]
}

private struct LegacyConversationCatalogRecordV0: Decodable {
    let id: ConversationID
    let remoteThreadID: String
    let title: String
    let projectPath: String?
    let isPinned: Bool
    let createdAt: Date
    let updatedAt: Date
}

/// Coordinates complete read-modify-write transactions across independent
/// store actors that target the same catalog file. The catalog is still loaded
/// from disk for every operation so one actor never serves another actor's
/// superseded snapshot.
private final class ConversationCatalogFileAccess: @unchecked Sendable {
    static let shared = ConversationCatalogFileAccess()

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

        if let existing = locksByPath[path] {
            return existing
        }
        let created = NSLock()
        locksByPath[path] = created
        return created
    }
}
