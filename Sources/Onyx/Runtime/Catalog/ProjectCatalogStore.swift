import Foundation

enum ProjectCatalogError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case malformedDocument(String)
    case emptyProjectID
    case invalidFolderPath(String)
    case invalidDisplayName
    case duplicateProjectID(ProjectID)
    case duplicateFolderPath(String)
    case invalidProjectOrder
    case invalidProjectDates(ProjectID)
    case projectNotFound(ProjectID)
    case invalidReorder

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Project catalog schema version \(version) is not supported."
        case let .malformedDocument(detail):
            "The project catalog could not be read: \(detail)"
        case .emptyProjectID:
            "A project has an empty app-owned ID."
        case let .invalidFolderPath(path):
            "Project folder path is not a usable absolute path: \(path)"
        case .invalidDisplayName:
            "Project display name cannot be empty."
        case let .duplicateProjectID(id):
            "The project ID \(id) appears more than once."
        case let .duplicateFolderPath(path):
            "The project folder \(path) appears more than once."
        case .invalidProjectOrder:
            "Project ordering must contain each contiguous position exactly once."
        case let .invalidProjectDates(id):
            "Project \(id) was updated before it was created."
        case let .projectNotFound(id):
            "No project exists for \(id)."
        case .invalidReorder:
            "A project reorder must contain every current project ID exactly once."
        }
    }
}

/// Durable metadata-only project catalog. Every mutation reloads the latest
/// file while holding a process-wide lock for that location, then validates
/// and atomically replaces the catalog document.
actor ProjectCatalogStore {
    let fileURL: URL

    private static let fileAccess = ProjectCatalogFileAccess.shared
    private let now: @Sendable () -> Date

    init(
        fileURL: URL,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileURL = fileURL
        self.now = now
    }

    func snapshot() throws -> ProjectCatalogSnapshot {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk()
        }
    }

    func projects() throws -> [ProjectCatalogRecord] {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk().projects
        }
    }

    func project(id: ProjectID) throws -> ProjectCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            try loadFromDisk().projects.first { $0.id == id }
        }
    }

    func project(forFolderPath folderPath: String) throws -> ProjectCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            return ProjectCatalogResolver.project(
                forFolderPath: folderPath,
                in: current.projects
            )
        }
    }

    func project(for conversation: ConversationCatalogRecord) throws -> ProjectCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            return ProjectCatalogResolver.project(for: conversation, in: current.projects)
        }
    }

    func groupConversations(
        _ conversations: [ConversationCatalogRecord]
    ) throws -> ProjectConversationGrouping {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            return ProjectCatalogResolver.group(conversations, by: current.projects)
        }
    }

    /// Imports a folder into Onyx without creating, reading, or modifying the
    /// folder itself. Re-importing the same normalized path is idempotent and
    /// returns the original stable ID.
    @discardableResult
    func importProject(
        folderPath: String,
        displayName: String? = nil,
        id: ProjectID = ProjectID()
    ) throws -> ProjectCatalogRecord {
        try Self.fileAccess.withLock(for: fileURL) {
            guard Self.isUsable(id) else {
                throw ProjectCatalogError.emptyProjectID
            }
            let normalizedPath = try Self.normalizedPath(folderPath)
            let current = try loadFromDisk()
            if let existing = current.projects.first(where: {
                $0.folderPath == normalizedPath
            }) {
                return existing
            }
            guard !current.projects.contains(where: { $0.id == id }) else {
                throw ProjectCatalogError.duplicateProjectID(id)
            }

            let timestamp = now()
            let imported = ProjectCatalogRecord(
                id: id,
                folderPath: normalizedPath,
                displayName: Self.importDisplayName(displayName, for: normalizedPath),
                order: current.projects.count,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            var projects = current.projects
            projects.append(imported)
            try persistValidated(
                projects,
                didBootstrapConversationProjects: current.didBootstrapConversationProjects
            )
            return imported
        }
    }

    @discardableResult
    func rename(
        id: ProjectID,
        displayName: String
    ) throws -> ProjectCatalogRecord {
        try Self.fileAccess.withLock(for: fileURL) {
            let normalizedName = displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                throw ProjectCatalogError.invalidDisplayName
            }

            let current = try loadFromDisk()
            guard let index = current.projects.firstIndex(where: { $0.id == id }) else {
                throw ProjectCatalogError.projectNotFound(id)
            }
            guard current.projects[index].displayName != normalizedName else {
                return current.projects[index]
            }

            var projects = current.projects
            projects[index].displayName = normalizedName
            projects[index].updatedAt = max(now(), projects[index].updatedAt)
            try persistValidated(
                projects,
                didBootstrapConversationProjects: current.didBootstrapConversationProjects
            )
            return projects[index]
        }
    }

    /// Replaces the complete user-controlled order. Requiring a permutation
    /// prevents stale UI state from accidentally hiding or duplicating a row.
    @discardableResult
    func reorder(_ orderedIDs: [ProjectID]) throws -> [ProjectCatalogRecord] {
        try Self.fileAccess.withLock(for: fileURL) {
            let current = try loadFromDisk()
            let existingIDs = Set(current.projects.map(\.id))
            guard orderedIDs.count == current.projects.count,
                  Set(orderedIDs).count == orderedIDs.count,
                  Set(orderedIDs) == existingIDs
            else {
                throw ProjectCatalogError.invalidReorder
            }

            let byID = Dictionary(uniqueKeysWithValues: current.projects.map { ($0.id, $0) })
            let timestamp = now()
            var reordered: [ProjectCatalogRecord] = []
            reordered.reserveCapacity(orderedIDs.count)
            for (order, id) in orderedIDs.enumerated() {
                guard var project = byID[id] else {
                    throw ProjectCatalogError.invalidReorder
                }
                if project.order != order {
                    project.order = order
                    project.updatedAt = max(timestamp, project.updatedAt)
                }
                reordered.append(project)
            }

            if reordered != current.projects {
                try persistValidated(
                    reordered,
                    didBootstrapConversationProjects: current.didBootstrapConversationProjects
                )
            }
            return reordered
        }
    }

    /// Removes only Onyx's metadata record. The represented directory and all
    /// of its contents are intentionally outside this operation's authority.
    @discardableResult
    func removeFromOnyx(id: ProjectID) throws -> ProjectCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            try removeFromOnyxLocked(id: id)
        }
    }

    @discardableResult
    func remove(id: ProjectID) throws -> ProjectCatalogRecord? {
        try Self.fileAccess.withLock(for: fileURL) {
            try removeFromOnyxLocked(id: id)
        }
    }

    // MARK: Persistence

    /// Must be called while holding this catalog file's process-local lock.
    private func loadFromDisk() throws -> ProjectCatalogSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProjectCatalogSnapshot()
        }

        let data = try Data(contentsOf: fileURL)
        let version: Int
        do {
            version = try Self.decoder
                .decode(ProjectCatalogSchemaVersionProbe.self, from: data)
                .schemaVersion
        } catch {
            throw ProjectCatalogError.malformedDocument(error.localizedDescription)
        }
        guard version == ProjectCatalogSnapshot.currentSchemaVersion else {
            throw ProjectCatalogError.unsupportedSchemaVersion(version)
        }

        var decoded: ProjectCatalogSnapshot
        do {
            decoded = try Self.decoder.decode(ProjectCatalogSnapshot.self, from: data)
        } catch {
            throw ProjectCatalogError.malformedDocument(error.localizedDescription)
        }
        try Self.validate(decoded)
        decoded.projects.sort(by: ProjectCatalogOrdering.areInIncreasingOrder)
        return decoded
    }

    private func persistValidated(
        _ projects: [ProjectCatalogRecord],
        didBootstrapConversationProjects: Bool
    ) throws {
        let ordered = projects.sorted(by: ProjectCatalogOrdering.areInIncreasingOrder)
        let snapshot = ProjectCatalogSnapshot(
            projects: ordered,
            didBootstrapConversationProjects: didBootstrapConversationProjects
        )
        try Self.validate(snapshot)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Must be called while holding this catalog file's process-local lock.
    private func removeFromOnyxLocked(id: ProjectID) throws -> ProjectCatalogRecord? {
        let current = try loadFromDisk()
        guard let index = current.projects.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        var projects = current.projects
        let removed = projects.remove(at: index)
        let timestamp = now()
        for index in projects.indices where projects[index].order != index {
            projects[index].order = index
            projects[index].updatedAt = max(timestamp, projects[index].updatedAt)
        }
        try persistValidated(
            projects,
            didBootstrapConversationProjects: current.didBootstrapConversationProjects
        )
        return removed
    }

    private static func validate(_ snapshot: ProjectCatalogSnapshot) throws {
        guard snapshot.schemaVersion == ProjectCatalogSnapshot.currentSchemaVersion else {
            throw ProjectCatalogError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }

        var ids: Set<ProjectID> = []
        var paths: Set<String> = []
        var orders: Set<Int> = []
        for project in snapshot.projects {
            guard isUsable(project.id) else {
                throw ProjectCatalogError.emptyProjectID
            }
            guard ids.insert(project.id).inserted else {
                throw ProjectCatalogError.duplicateProjectID(project.id)
            }
            let normalizedPath = try normalizedPath(project.folderPath)
            guard normalizedPath == project.folderPath else {
                throw ProjectCatalogError.invalidFolderPath(project.folderPath)
            }
            guard paths.insert(normalizedPath).inserted else {
                throw ProjectCatalogError.duplicateFolderPath(normalizedPath)
            }
            guard !project.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ProjectCatalogError.invalidDisplayName
            }
            guard orders.insert(project.order).inserted else {
                throw ProjectCatalogError.invalidProjectOrder
            }
            guard project.updatedAt >= project.createdAt else {
                throw ProjectCatalogError.invalidProjectDates(project.id)
            }
        }

        guard orders == Set(0 ..< snapshot.projects.count) else {
            throw ProjectCatalogError.invalidProjectOrder
        }
    }

    private static func normalizedPath(_ rawPath: String) throws -> String {
        guard let normalized = ProjectPathNormalizer.normalize(rawPath) else {
            throw ProjectCatalogError.invalidFolderPath(rawPath)
        }
        return normalized
    }

    private static func isUsable(_ id: ProjectID) -> Bool {
        !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func importDisplayName(
        _ requestedName: String?,
        for folderPath: String
    ) -> String {
        if let normalized = requestedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !normalized.isEmpty
        {
            return normalized
        }
        let lastComponent = URL(fileURLWithPath: folderPath).lastPathComponent
        return lastComponent.isEmpty ? folderPath : lastComponent
    }

    private static func uniqueID(excluding existing: Set<ProjectID>) -> ProjectID {
        var candidate = ProjectID()
        while existing.contains(candidate) {
            candidate = ProjectID()
        }
        return candidate
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

private struct ProjectCatalogSchemaVersionProbe: Decodable {
    let schemaVersion: Int
}

/// Coordinates read-modify-write transactions across independent store actors
/// that target the same project catalog file.
private final class ProjectCatalogFileAccess: @unchecked Sendable {
    static let shared = ProjectCatalogFileAccess()

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
