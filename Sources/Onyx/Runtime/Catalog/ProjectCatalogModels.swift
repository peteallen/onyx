import Foundation

/// Stable, app-owned identity for a folder imported into Onyx.
///
/// Folder paths can be renamed, moved, or re-imported, so presentation and
/// ordering code use this identity rather than treating a path as an ID.
struct ProjectID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible, Identifiable
{
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    init() {
        self.init(UUID().uuidString.lowercased())
    }

    var id: ProjectID { self }
    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Durable user-owned project metadata. `folderPath` is normalized lexically
/// before persistence; Onyx never needs to inspect or mutate folder contents
/// to add, rename, order, resolve, or remove this record.
struct ProjectCatalogRecord: Identifiable, Codable, Hashable, Sendable {
    let id: ProjectID
    var folderPath: String
    var displayName: String
    var order: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: ProjectID = ProjectID(),
        folderPath: String,
        displayName: String,
        order: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.folderPath = folderPath
        self.displayName = displayName
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Compatibility projection for APIs that still attach the original
    /// path/name pair directly to a conversation.
    var conversationProject: ConversationProject {
        ConversationProject(path: folderPath, displayName: displayName)
    }
}

/// Versioned persistence boundary for the independent project catalog.
struct ProjectCatalogSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var projects: [ProjectCatalogRecord]
    /// Compatibility marker written by a rejected pre-release importer.
    /// Current builds preserve it while treating every existing row as
    /// potentially user-curated because the old schema had no provenance.
    let didBootstrapConversationProjects: Bool

    init(
        projects: [ProjectCatalogRecord] = [],
        didBootstrapConversationProjects: Bool = false
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.projects = projects
        self.didBootstrapConversationProjects = didBootstrapConversationProjects
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projects
        case didBootstrapConversationProjects
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        projects = try container.decode([ProjectCatalogRecord].self, forKey: .projects)
        // The marker remains decodable for older development catalogs, but is
        // never evidence that any individual project is safe to remove.
        didBootstrapConversationProjects = try container.decodeIfPresent(
            Bool.self,
            forKey: .didBootstrapConversationProjects
        ) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(projects, forKey: .projects)
        try container.encode(
            didBootstrapConversationProjects,
            forKey: .didBootstrapConversationProjects
        )
    }
}

/// Conversations resolved to one imported project. Empty groups are retained
/// so the caller can render the complete user-controlled project list.
struct ProjectConversationGroup: Equatable, Sendable {
    let project: ProjectCatalogRecord
    var conversations: [ConversationCatalogRecord]
}

/// Complete grouping result. Conversations without a usable path, or whose
/// path is outside every imported project, remain explicitly unassigned.
struct ProjectConversationGrouping: Equatable, Sendable {
    let groups: [ProjectConversationGroup]
    let unassigned: [ConversationCatalogRecord]
}

/// Pure path-based compatibility layer between the project catalog and both
/// current and legacy `ConversationProject` values.
enum ProjectCatalogResolver {
    static func project(
        for conversation: ConversationCatalogRecord,
        in projects: [ProjectCatalogRecord]
    ) -> ProjectCatalogRecord? {
        project(forFolderPath: conversation.project?.path, in: projects)
    }

    static func project(
        for conversationProject: ConversationProject?,
        in projects: [ProjectCatalogRecord]
    ) -> ProjectCatalogRecord? {
        project(forFolderPath: conversationProject?.path, in: projects)
    }

    /// Resolves exact paths and nested working directories. When projects are
    /// nested, the most specific imported ancestor wins.
    static func project(
        forFolderPath rawPath: String?,
        in projects: [ProjectCatalogRecord]
    ) -> ProjectCatalogRecord? {
        guard let rawPath,
              let normalizedPath = ProjectPathNormalizer.normalize(rawPath)
        else { return nil }

        return candidates(for: projects).first {
            ProjectPathNormalizer.contains(normalizedPath, inside: $0.root)
        }?.project
    }

    static func group(
        _ conversations: [ConversationCatalogRecord],
        by projects: [ProjectCatalogRecord]
    ) -> ProjectConversationGrouping {
        let orderedProjects = projects.sorted(by: ProjectCatalogOrdering.areInIncreasingOrder)
        let resolutionCandidates = candidates(for: orderedProjects)
        var conversationsByProject: [ProjectID: [ConversationCatalogRecord]] = [:]
        var unassigned: [ConversationCatalogRecord] = []

        for conversation in conversations {
            let project = conversation.project
                .flatMap { ProjectPathNormalizer.normalize($0.path) }
                .flatMap { normalizedPath in
                    resolutionCandidates.first {
                        ProjectPathNormalizer.contains(normalizedPath, inside: $0.root)
                    }?.project
                }
            if let project {
                conversationsByProject[project.id, default: []].append(conversation)
            } else {
                unassigned.append(conversation)
            }
        }

        return ProjectConversationGrouping(
            groups: orderedProjects.map { project in
                ProjectConversationGroup(
                    project: project,
                    conversations: conversationsByProject[project.id] ?? []
                )
            },
            unassigned: unassigned
        )
    }

    private static func candidates(
        for projects: [ProjectCatalogRecord]
    ) -> [(project: ProjectCatalogRecord, root: String, depth: Int)] {
        projects
            .compactMap { project in
                ProjectPathNormalizer.normalize(project.folderPath).map {
                    (
                        project: project,
                        root: $0,
                        depth: ProjectPathNormalizer.componentCount($0)
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
                if lhs.project.order != rhs.project.order {
                    return lhs.project.order < rhs.project.order
                }
                return lhs.project.id.rawValue < rhs.project.id.rawValue
            }
    }
}

enum ProjectCatalogOrdering {
    static func areInIncreasingOrder(
        _ lhs: ProjectCatalogRecord,
        _ rhs: ProjectCatalogRecord
    ) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

/// Lexical normalization deliberately avoids resolving symlinks or asking the
/// filesystem whether a folder exists. This keeps project removal and grouping
/// metadata-only while still handling `~`, dot components, and trailing `/`.
enum ProjectPathNormalizer {
    static func normalize(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard NSString(string: expanded).isAbsolutePath else { return nil }

        let standardized = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        guard standardized.hasPrefix("/") else { return nil }
        return standardized
    }

    static func contains(_ candidate: String, inside root: String) -> Bool {
        let candidateComponents = NSString(string: candidate).pathComponents
        let rootComponents = NSString(string: root).pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count)
            .elementsEqual(rootComponents)
    }

    static func componentCount(_ path: String) -> Int {
        NSString(string: path).pathComponents.count
    }
}
