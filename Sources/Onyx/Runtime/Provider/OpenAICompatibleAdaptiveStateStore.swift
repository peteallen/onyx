import Foundation

/// The state store is an actor, but the application can briefly have two
/// runtime generations (or two windows) pointing at the same file.  Atomic
/// replacement protects against torn JSON; it does not protect a stale
/// read-modify-write from erasing the other generation's update.  Serialize
/// each path in-process and reload while holding this lock.
private final class OpenAICompatibleAdaptiveStateFileLockRegistry: @unchecked Sendable {
    static let shared = OpenAICompatibleAdaptiveStateFileLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func withLock<T>(for url: URL, _ body: () throws -> T) rethrows -> T {
        let path = url.standardizedFileURL.path
        let lock = registryLock.withLock {
            if let existing = locks[path] { return existing }
            let created = NSLock()
            locks[path] = created
            return created
        }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The backend that owns one durable OpenAI-compatible task. A task never
/// changes lanes after creation: doing so would merge two unrelated history
/// formats and could replay a prompt or tool result in the wrong runtime.
enum OpenAICompatibleTaskLane: String, Codable, Equatable, Hashable, Sendable {
    case chat
    case agent
}

/// Compatibility spelling used by composition code that treats this as a
/// runtime decision. Keep one underlying type so persisted ownership can never
/// be decoded differently by two resolver surfaces.
typealias OpenAICompatibleRuntimeLane = OpenAICompatibleTaskLane

/// Durable routing metadata for one provider task. The provider connection and
/// its rotating conversation scope are both part of the identity boundary, so
/// changing an endpoint or credential never makes an older task visible to the
/// replacement configuration.
struct OpenAICompatibleTaskLaneOwnership: Codable, Equatable, Hashable, Sendable {
    let connectionID: ProviderConnectionID
    let conversationScopeID: String
    let threadID: String
    let lane: OpenAICompatibleTaskLane
    var modelID: String
    var updatedAt: Date
}

enum OpenAICompatibleAdaptiveStateStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformedDocument
    case invalidRecord
    case ownershipConflict(
        connectionID: ProviderConnectionID,
        conversationScopeID: String,
        threadID: String
    )
    case stateLimitExceeded

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "OpenAI-compatible adaptive state schema version \(version) is not supported."
        case .malformedDocument:
            "OpenAI-compatible task routing state could not be read."
        case .invalidRecord:
            "OpenAI-compatible task routing state contains an invalid record."
        case let .ownershipConflict(connectionID, _, threadID):
            "Task \(threadID) has conflicting backend ownership for provider \(connectionID)."
        case .stateLimitExceeded:
            "OpenAI-compatible task routing state exceeds Onyx's safety limit."
        }
    }
}

/// One small app-owned document holds only opaque routing IDs and compatibility
/// outcomes. It never contains an endpoint, provider response, prompt, tool
/// output, or credential. The actor instance is shared by every runtime
/// generation in the application host, while atomic writes make replacement
/// after a settings edit crash-safe.
actor OpenAICompatibleAdaptiveStateStore {
    private struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        var taskOwnerships: [OpenAICompatibleTaskLaneOwnership]
        var probeRecords: [OpenAICompatibleResponsesProbeRecord]

        init(
            schemaVersion: Int = currentSchemaVersion,
            taskOwnerships: [OpenAICompatibleTaskLaneOwnership] = [],
            probeRecords: [OpenAICompatibleResponsesProbeRecord] = []
        ) {
            self.schemaVersion = schemaVersion
            self.taskOwnerships = taskOwnerships
            self.probeRecords = probeRecords
        }

        /// Probe cache entries are expendable. If an older build, a partial
        /// write, or a hand-edited record makes that array undecodable, retain
        /// the durable task owners and fail closed for the probe cache instead
        /// of making every existing task unreachable.
        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case taskOwnerships
            case probeRecords
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            taskOwnerships = try container.decode(
                [OpenAICompatibleTaskLaneOwnership].self,
                forKey: .taskOwnerships
            )
            probeRecords = (try? container.decode(
                [OpenAICompatibleResponsesProbeRecord].self,
                forKey: .probeRecords
            )) ?? []
        }
    }

    struct Limits: Sendable, Equatable {
        let maximumTaskOwnerships: Int
        let maximumProbeRecords: Int
        let maximumStateFileBytes: Int
        let maximumConnectionIDBytes: Int
        let maximumScopeIDBytes: Int
        let maximumThreadIDBytes: Int
        let maximumModelIDBytes: Int
        let maximumProbeRecordLifetime: TimeInterval
        let maximumFutureClockSkew: TimeInterval

        init(
            maximumTaskOwnerships: Int = 100_000,
            maximumProbeRecords: Int = 20_000,
            maximumStateFileBytes: Int = 8 * 1_024 * 1_024,
            maximumConnectionIDBytes: Int = 1_024,
            maximumScopeIDBytes: Int = 1_024,
            maximumThreadIDBytes: Int = 4_096,
            maximumModelIDBytes: Int = 1_024,
            maximumProbeRecordLifetime: TimeInterval = 7 * 24 * 60 * 60,
            maximumFutureClockSkew: TimeInterval = 5 * 60
        ) {
            self.maximumTaskOwnerships = max(1, maximumTaskOwnerships)
            self.maximumProbeRecords = max(1, maximumProbeRecords)
            self.maximumStateFileBytes = max(1_024, maximumStateFileBytes)
            self.maximumConnectionIDBytes = max(1, maximumConnectionIDBytes)
            self.maximumScopeIDBytes = max(1, maximumScopeIDBytes)
            self.maximumThreadIDBytes = max(1, maximumThreadIDBytes)
            self.maximumModelIDBytes = max(1, maximumModelIDBytes)
            self.maximumProbeRecordLifetime = max(1, maximumProbeRecordLifetime)
            self.maximumFutureClockSkew = max(0, maximumFutureClockSkew)
        }

        static let `default` = Limits()
    }

    private struct TaskKey: Hashable {
        let connectionID: ProviderConnectionID
        let conversationScopeID: String
        let threadID: String
    }

    let fileURL: URL
    private let limits: Limits
    private let protectsParentDirectory: Bool

    init(
        fileURL: URL? = nil,
        limits: Limits = .default,
        fileManager: FileManager = .default
    ) {
        // The default Application Support location is owned by Onyx and may
        // be tightened to 0700. An explicitly injected path can live inside
        // a caller-owned fixture or shared directory; changing that parent's
        // mode would be an unexpected side effect, so preserve it.
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.limits = limits
        self.protectsParentDirectory = fileURL == nil
    }

    func taskOwnership(
        connectionID: ProviderConnectionID,
        conversationScopeID: String,
        threadID: String
    ) throws -> OpenAICompatibleTaskLaneOwnership? {
        let key = try validatedTaskKey(
            connectionID: connectionID,
            conversationScopeID: conversationScopeID,
            threadID: threadID
        )
        return try withFileLock {
            try loadSnapshot().taskOwnerships.first { Self.key(for: $0) == key }
        }
    }

    func taskOwnerships(
        connectionID: ProviderConnectionID,
        conversationScopeID: String,
        lane: OpenAICompatibleTaskLane? = nil
    ) throws -> [OpenAICompatibleTaskLaneOwnership] {
        let key = try validatedTaskKey(
            connectionID: connectionID,
            conversationScopeID: conversationScopeID,
            threadID: "validation-placeholder"
        )
        return try withFileLock {
            try loadSnapshot().taskOwnerships.filter { ownership in
                Self.key(for: ownership).connectionID == key.connectionID
                && Self.key(for: ownership).conversationScopeID == key.conversationScopeID
                && (lane == nil || ownership.lane == lane)
            }
        }
    }

    /// Claims a task exactly once. Re-observing the same lane refreshes its
    /// model metadata, while an opposite-lane claim fails closed instead of
    /// making later reads scheduler-dependent.
    @discardableResult
    func recordTaskOwnership(
        connectionID: ProviderConnectionID,
        conversationScopeID: String,
        threadID: String,
        lane: OpenAICompatibleTaskLane,
        modelID: String,
        updatedAt: Date = .now
    ) throws -> OpenAICompatibleTaskLaneOwnership {
        let key = try validatedTaskKey(
            connectionID: connectionID,
            conversationScopeID: conversationScopeID,
            threadID: threadID
        )
        let normalizedModelID = try Self.validatedIdentifier(
            modelID,
            maximumBytes: limits.maximumModelIDBytes
        )
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return try withFileLock {
            var value = try loadSnapshot()
            if let index = value.taskOwnerships.firstIndex(where: { Self.key(for: $0) == key }) {
                guard value.taskOwnerships[index].lane == lane else {
                    throw OpenAICompatibleAdaptiveStateStoreError.ownershipConflict(
                        connectionID: connectionID,
                        conversationScopeID: key.conversationScopeID,
                        threadID: key.threadID
                    )
                }
                value.taskOwnerships[index].modelID = normalizedModelID
                value.taskOwnerships[index].updatedAt = updatedAt
                try persist(value, validationDate: .now)
                return value.taskOwnerships[index]
            }
            guard value.taskOwnerships.count < limits.maximumTaskOwnerships else {
                throw OpenAICompatibleAdaptiveStateStoreError.stateLimitExceeded
            }
            let ownership = OpenAICompatibleTaskLaneOwnership(
                connectionID: key.connectionID,
                conversationScopeID: key.conversationScopeID,
                threadID: key.threadID,
                lane: lane,
                modelID: normalizedModelID,
                updatedAt: updatedAt
            )
            value.taskOwnerships.append(ownership)
            try persist(value, validationDate: .now)
            return ownership
        }
    }

    /// Claims a task only when it has no existing owner.  Transcript
    /// projection uses this idempotent form for native child conversations so
    /// merely browsing a parent cannot refresh the child's recency or model
    /// metadata.
    @discardableResult
    func ensureTaskOwnership(
        connectionID: ProviderConnectionID,
        conversationScopeID: String,
        threadID: String,
        lane: OpenAICompatibleTaskLane,
        modelID: String,
        updatedAt: Date = .now
    ) throws -> OpenAICompatibleTaskLaneOwnership {
        let key = try validatedTaskKey(
            connectionID: connectionID,
            conversationScopeID: conversationScopeID,
            threadID: threadID
        )
        let normalizedModelID = try Self.validatedIdentifier(
            modelID,
            maximumBytes: limits.maximumModelIDBytes
        )
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return try withFileLock {
            var value = try loadSnapshot()
            if let existing = value.taskOwnerships.first(where: { Self.key(for: $0) == key }) {
                guard existing.lane == lane else {
                    throw OpenAICompatibleAdaptiveStateStoreError.ownershipConflict(
                        connectionID: connectionID,
                        conversationScopeID: key.conversationScopeID,
                        threadID: key.threadID
                    )
                }
                return existing
            }
            guard value.taskOwnerships.count < limits.maximumTaskOwnerships else {
                throw OpenAICompatibleAdaptiveStateStoreError.stateLimitExceeded
            }
            let ownership = OpenAICompatibleTaskLaneOwnership(
                connectionID: key.connectionID,
                conversationScopeID: key.conversationScopeID,
                threadID: key.threadID,
                lane: lane,
                modelID: normalizedModelID,
                updatedAt: updatedAt
            )
            value.taskOwnerships.append(ownership)
            try persist(value, validationDate: .now)
            return ownership
        }
    }

    @discardableResult
    func removeTaskOwnership(
        connectionID: ProviderConnectionID,
        conversationScopeID: String,
        threadID: String
    ) throws -> OpenAICompatibleTaskLaneOwnership? {
        let key = try validatedTaskKey(
            connectionID: connectionID,
            conversationScopeID: conversationScopeID,
            threadID: threadID
        )
        return try withFileLock {
            var value = try loadSnapshot()
            guard let index = value.taskOwnerships.firstIndex(where: { Self.key(for: $0) == key })
            else { return nil }
            let removed = value.taskOwnerships.remove(at: index)
            try persist(value, validationDate: .now)
            return removed
        }
    }

    func probeRecord(
        for fingerprint: OpenAICompatibleResponsesProbeFingerprint,
        at date: Date = .now
    ) throws -> OpenAICompatibleResponsesProbeRecord? {
        try probeRecords(for: [fingerprint], at: date)[fingerprint]
    }

    /// Returns reusable evidence for an entire model catalog from one durable
    /// snapshot. Provider catalogs can contain thousands of models, so callers
    /// must never decode this state file once per model merely to decorate a
    /// picker.
    func probeRecords(
        for fingerprints: Set<OpenAICompatibleResponsesProbeFingerprint>,
        at date: Date = .now
    ) throws -> [OpenAICompatibleResponsesProbeFingerprint: OpenAICompatibleResponsesProbeRecord] {
        guard !fingerprints.isEmpty else { return [:] }
        guard fingerprints.allSatisfy(Self.isValidFingerprint) else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return try withFileLock {
            let snapshot = try loadSnapshot(validationDate: date)
            return Dictionary(
                uniqueKeysWithValues: snapshot.probeRecords.compactMap { record in
                    guard fingerprints.contains(record.fingerprint),
                          record.isReusable(for: record.fingerprint, at: date) else {
                        return nil
                    }
                    return (record.fingerprint, record)
                }
            )
        }
    }

    func storeProbeRecord(
        _ record: OpenAICompatibleResponsesProbeRecord,
        at date: Date = .now
    ) throws {
        // Compatible evidence unlocks local tools. Until this app-owned file
        // has an authenticated format, that decision is process-local only;
        // an edited cache file must never enable the agent lane after launch.
        guard case .failed = record.outcome,
              Self.isValidProbeRecord(
            record,
            at: date,
            limits: limits
        ) else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return try withFileLock {
            var value = try loadSnapshot(validationDate: date)
            value.probeRecords.removeAll {
                $0.fingerprint == record.fingerprint || $0.expiresAt <= date
            }
            while value.probeRecords.count >= limits.maximumProbeRecords {
                guard let index = Self.probeEvictionIndex(value.probeRecords) else {
                    throw OpenAICompatibleAdaptiveStateStoreError.stateLimitExceeded
                }
                value.probeRecords.remove(at: index)
            }
            value.probeRecords.append(record)
            try persist(value, validationDate: date)
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        try OpenAICompatibleAdaptiveStateFileLockRegistry.shared.withLock(
            for: fileURL,
            body
        )
    }

    private func loadSnapshot(validationDate: Date = .now) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot()
        }
        do {
            let value = try Self.decoder.decode(Snapshot.self, from: try boundedData())
            return try Self.sanitized(value, validationDate: validationDate, limits: limits)
        } catch let error as OpenAICompatibleAdaptiveStateStoreError {
            throw error
        } catch {
            throw OpenAICompatibleAdaptiveStateStoreError.malformedDocument
        }
    }

    private func boundedData() throws -> Data {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile != false else {
            throw OpenAICompatibleAdaptiveStateStoreError.malformedDocument
        }
        if let size = values.fileSize, size > limits.maximumStateFileBytes {
            throw OpenAICompatibleAdaptiveStateStoreError.stateLimitExceeded
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= limits.maximumStateFileBytes else {
            throw OpenAICompatibleAdaptiveStateStoreError.stateLimitExceeded
        }
        return data
    }

    private func persist(_ value: Snapshot, validationDate: Date) throws {
        let sanitized = try Self.sanitized(value, validationDate: validationDate, limits: limits)
        let data = try Self.encoder.encode(sanitized)
        guard data.count <= limits.maximumStateFileBytes else {
            throw OpenAICompatibleAdaptiveStateStoreError.stateLimitExceeded
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if protectsParentDirectory {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private func validatedTaskKey(
        connectionID: ProviderConnectionID,
        conversationScopeID: String,
        threadID: String
    ) throws -> TaskKey {
        TaskKey(
            connectionID: ProviderConnectionID(try Self.validatedIdentifier(
                connectionID.rawValue,
                maximumBytes: limits.maximumConnectionIDBytes
            )),
            conversationScopeID: try Self.validatedIdentifier(
                conversationScopeID,
                maximumBytes: limits.maximumScopeIDBytes
            ),
            threadID: try Self.validatedIdentifier(
                threadID,
                maximumBytes: limits.maximumThreadIDBytes
            )
        )
    }

    private static func key(for ownership: OpenAICompatibleTaskLaneOwnership) -> TaskKey {
        TaskKey(
            connectionID: ownership.connectionID,
            conversationScopeID: ownership.conversationScopeID,
            threadID: ownership.threadID
        )
    }

    private static func sanitized(
        _ snapshot: Snapshot,
        validationDate: Date,
        limits: Limits
    ) throws -> Snapshot {
        guard snapshot.schemaVersion == Snapshot.currentSchemaVersion else {
            throw OpenAICompatibleAdaptiveStateStoreError.unsupportedSchemaVersion(
                snapshot.schemaVersion
            )
        }
        guard validationDate.timeIntervalSinceReferenceDate.isFinite,
              snapshot.taskOwnerships.count <= limits.maximumTaskOwnerships else {
            throw OpenAICompatibleAdaptiveStateStoreError.stateLimitExceeded
        }

        var keys: Set<TaskKey> = []
        for ownership in snapshot.taskOwnerships {
            let key = TaskKey(
                connectionID: ProviderConnectionID(try validatedIdentifier(
                    ownership.connectionID.rawValue,
                    maximumBytes: limits.maximumConnectionIDBytes
                )),
                conversationScopeID: try validatedIdentifier(
                    ownership.conversationScopeID,
                    maximumBytes: limits.maximumScopeIDBytes
                ),
                threadID: try validatedIdentifier(
                    ownership.threadID,
                    maximumBytes: limits.maximumThreadIDBytes
                )
            )
            guard ownership.connectionID.rawValue == key.connectionID.rawValue,
                  ownership.conversationScopeID == key.conversationScopeID,
                  ownership.threadID == key.threadID,
                  ownership.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
            }
            _ = try validatedIdentifier(
                ownership.modelID,
                maximumBytes: limits.maximumModelIDBytes
            )
            guard keys.insert(key).inserted else {
                throw OpenAICompatibleAdaptiveStateStoreError.ownershipConflict(
                    connectionID: ownership.connectionID,
                    conversationScopeID: ownership.conversationScopeID,
                    threadID: ownership.threadID
                )
            }
        }

        let probes = snapshot.probeRecords
            .filter { record in
                guard case .failed = record.outcome else { return false }
                return isValidProbeRecord(record, at: validationDate, limits: limits)
            }
            .sorted(by: probeOrder)
        var fingerprints: Set<OpenAICompatibleResponsesProbeFingerprint> = []
        let deduplicated = probes.filter { fingerprints.insert($0.fingerprint).inserted }
        return Snapshot(
            schemaVersion: snapshot.schemaVersion,
            taskOwnerships: snapshot.taskOwnerships,
            probeRecords: Array(deduplicated.suffix(limits.maximumProbeRecords))
        )
    }

    private static func validatedIdentifier(
        _ rawValue: String,
        maximumBytes: Int
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              !value.contains("\0") else {
            throw OpenAICompatibleAdaptiveStateStoreError.invalidRecord
        }
        return value
    }

    private static func isValidFingerprint(
        _ fingerprint: OpenAICompatibleResponsesProbeFingerprint
    ) -> Bool {
        fingerprint.value.utf8.count == 64
            && fingerprint.value.utf8.allSatisfy { byte in
                (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
            }
    }

    private static func isValidProbeRecord(
        _ record: OpenAICompatibleResponsesProbeRecord,
        at date: Date,
        limits: Limits
    ) -> Bool {
        guard isValidFingerprint(record.fingerprint),
              date.timeIntervalSinceReferenceDate.isFinite,
              record.testedAt.timeIntervalSinceReferenceDate.isFinite,
              record.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              record.expiresAt > record.testedAt,
              record.expiresAt.timeIntervalSince(record.testedAt)
                <= limits.maximumProbeRecordLifetime,
              record.testedAt <= date.addingTimeInterval(limits.maximumFutureClockSkew)
        else { return false }
        switch record.outcome {
        case let .compatible(evidence):
            return evidence.usedServerSentEvents
                && evidence.receivedFunctionCall
                && evidence.submittedCorrelatedOutput
                && evidence.completedAfterFunctionOutput
        case let .failed(failure):
            return isValidProbeFailure(failure)
        }
    }

    /// Persisted probe failures are decoded from an untrusted app-owned JSON
    /// file. Keep associated HTTP status values inside the protocol's valid
    /// three-digit range; otherwise a forged value could bypass the intended
    /// transient/permanent classification or produce misleading diagnostics.
    private static func isValidProbeFailure(
        _ failure: OpenAICompatibleResponsesProbeFailure
    ) -> Bool {
        guard case let .httpFailure(statusCode) = failure else { return true }
        return (100 ... 599).contains(statusCode)
    }

    private static func probeOrder(
        _ lhs: OpenAICompatibleResponsesProbeRecord,
        _ rhs: OpenAICompatibleResponsesProbeRecord
    ) -> Bool {
        if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
        if lhs.testedAt != rhs.testedAt { return lhs.testedAt < rhs.testedAt }
        return lhs.fingerprint.value < rhs.fingerprint.value
    }

    private static func probeEvictionIndex(
        _ records: [OpenAICompatibleResponsesProbeRecord]
    ) -> Int? {
        records.indices.min { lhs, rhs in probeOrder(records[lhs], records[rhs]) }
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Onyx", isDirectory: true)
            .appendingPathComponent("openai-compatible-adaptive-state.json", isDirectory: false)
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
