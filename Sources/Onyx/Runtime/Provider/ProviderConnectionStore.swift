import Foundation

protocol ProviderConnectionStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// Application Support persistence behind an injectable byte-storage seam.
/// `defaultFileURL` does not create directories or touch disk until a write.
struct ApplicationSupportProviderConnectionStorage: ProviderConnectionStorage, Sendable {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Onyx", isDirectory: true)
            .appendingPathComponent("provider-connections.json", isDirectory: false)
    }
}

enum ProviderConnectionStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformedDocument(String)
    case duplicateConnectionID(ProviderConnectionID)
    case connectionNotFound(ProviderConnectionID)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Provider connection schema version \(version) is not supported."
        case let .malformedDocument(detail):
            "Provider connections could not be read: \(detail)"
        case let .duplicateConnectionID(id):
            "Provider connection \(id) appears more than once."
        case let .connectionNotFound(id):
            "Provider connection \(id) does not exist."
        }
    }
}

struct ProviderConnectionSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var connections: [ProviderConnectionRecord]

    init(
        schemaVersion: Int = currentSchemaVersion,
        connections: [ProviderConnectionRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.connections = connections
    }
}

/// Actor-serialized connection records. Secrets are not accepted by any method
/// on this type, making it difficult to accidentally place bearer values in
/// the Application Support JSON.
actor ProviderConnectionStore {
    private let storage: any ProviderConnectionStorage

    init(storage: any ProviderConnectionStorage = ApplicationSupportProviderConnectionStorage()) {
        self.storage = storage
    }

    func snapshot() throws -> ProviderConnectionSnapshot {
        try load()
    }

    func connections() throws -> [ProviderConnectionRecord] {
        try load().connections
    }

    func connection(id: ProviderConnectionID) throws -> ProviderConnectionRecord? {
        try load().connections.first { $0.id == id }
    }

    @discardableResult
    func upsert(_ connection: ProviderConnectionRecord) throws -> ProviderConnectionRecord {
        var snapshot = try load()
        if let index = snapshot.connections.firstIndex(where: { $0.id == connection.id }) {
            snapshot.connections[index] = connection
        } else {
            snapshot.connections.append(connection)
        }
        try validate(snapshot)
        try persist(snapshot)
        return connection
    }

    @discardableResult
    func remove(id: ProviderConnectionID) throws -> ProviderConnectionRecord? {
        var snapshot = try load()
        guard let index = snapshot.connections.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = snapshot.connections.remove(at: index)
        try persist(snapshot)
        return removed
    }

    private func load() throws -> ProviderConnectionSnapshot {
        guard let data = try storage.read() else { return ProviderConnectionSnapshot() }
        do {
            let snapshot = try Self.decoder.decode(ProviderConnectionSnapshot.self, from: data)
            try validate(snapshot)
            return snapshot
        } catch let error as ProviderConnectionStoreError {
            throw error
        } catch {
            throw ProviderConnectionStoreError.malformedDocument(error.localizedDescription)
        }
    }

    private func persist(_ snapshot: ProviderConnectionSnapshot) throws {
        try storage.write(Self.encoder.encode(snapshot))
    }

    private func validate(_ snapshot: ProviderConnectionSnapshot) throws {
        guard snapshot.schemaVersion == ProviderConnectionSnapshot.currentSchemaVersion else {
            throw ProviderConnectionStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        var seen: Set<ProviderConnectionID> = []
        for connection in snapshot.connections {
            guard seen.insert(connection.id).inserted else {
                throw ProviderConnectionStoreError.duplicateConnectionID(connection.id)
            }
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

/// Deterministic in-memory non-secret storage for tests.
final class InMemoryProviderConnectionStorage: ProviderConnectionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func read() -> Data? {
        lock.withLock { data }
    }

    func write(_ data: Data) {
        lock.withLock { self.data = data }
    }

    func storedData() -> Data? {
        lock.withLock { data }
    }
}
