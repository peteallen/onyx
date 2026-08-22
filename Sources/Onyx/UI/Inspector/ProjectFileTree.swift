import Combine
import Foundation

struct ProjectFileEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
        case symbolicLink
    }

    let path: String
    let name: String
    let kind: Kind

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
}

struct ProjectDirectorySnapshot: Equatable, Sendable {
    let entries: [ProjectFileEntry]
    let wasTruncated: Bool
}

protocol ProjectDirectoryReading: Sendable {
    func contents(ofDirectoryAt path: String) async throws -> ProjectDirectorySnapshot
}

struct LocalProjectDirectoryReader: ProjectDirectoryReading {
    static let defaultEntryLimit = 500

    let entryLimit: Int

    init(entryLimit: Int = defaultEntryLimit) {
        self.entryLimit = max(1, entryLimit)
    }

    func contents(ofDirectoryAt path: String) async throws -> ProjectDirectorySnapshot {
        let entryLimit = entryLimit
        return try await Task.detached(priority: .userInitiated) {
            try Self.readDirectory(at: path, entryLimit: entryLimit)
        }.value
    }

    static func readDirectory(at path: String, entryLimit: Int) throws -> ProjectDirectorySnapshot {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw ProjectFileTreeError.missingDirectory(directoryURL.path)
        }
        guard isDirectory.boolValue else {
            throw ProjectFileTreeError.notDirectory(directoryURL.path)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        let entries = try urls.compactMap { url -> ProjectFileEntry? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = url.lastPathComponent
            let symbolicLink = values.isSymbolicLink == true
            let directory = values.isDirectory == true && !symbolicLink

            if directory && shouldExcludeDirectory(named: name) {
                return nil
            }

            let kind: ProjectFileEntry.Kind = if symbolicLink {
                .symbolicLink
            } else if directory {
                .directory
            } else {
                .file
            }

            return ProjectFileEntry(
                path: url.standardizedFileURL.path,
                name: name,
                kind: kind
            )
        }
        .sorted(by: entrySort)

        let safeLimit = max(1, entryLimit)
        return ProjectDirectorySnapshot(
            entries: Array(entries.prefix(safeLimit)),
            wasTruncated: entries.count > safeLimit
        )
    }

    private static func shouldExcludeDirectory(named name: String) -> Bool {
        name.hasPrefix(".") || ["node_modules", "Pods", "DerivedData"].contains(name)
    }

    private static func entrySort(_ lhs: ProjectFileEntry, _ rhs: ProjectFileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }

        let lhsFolded = lhs.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let rhsFolded = rhs.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if lhsFolded != rhsFolded {
            return lhsFolded < rhsFolded
        }
        return lhs.name < rhs.name
    }
}

enum ProjectFileTreeError: LocalizedError, Equatable {
    case missingDirectory(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .missingDirectory(path):
            "The project folder no longer exists at \(path)."
        case let .notDirectory(path):
            "The project location is not a folder: \(path)."
        }
    }
}

@MainActor
final class ProjectFileTreeModel: ObservableObject {
    enum RootState: Equatable {
        case noProject
        case loading
        case loaded
        case empty
        case failed(String)
    }

    enum Row: Identifiable, Equatable {
        case entry(ProjectFileEntry, depth: Int)
        case loading(parentPath: String, depth: Int)
        case failure(parentPath: String, message: String, depth: Int)
        case truncated(parentPath: String, depth: Int)

        var id: String {
            switch self {
            case let .entry(entry, _): entry.path
            case let .loading(path, _): "\(path)#loading"
            case let .failure(path, _, _): "\(path)#failure"
            case let .truncated(path, _): "\(path)#truncated"
            }
        }
    }

    @Published private(set) var rootState: RootState = .noProject
    @Published private(set) var rootPath: String?
    @Published private(set) var rootEntries: [ProjectFileEntry] = []
    @Published private(set) var expandedDirectories: Set<String> = []
    @Published private(set) var loadingDirectories: Set<String> = []

    private let reader: any ProjectDirectoryReading
    private var childEntries: [String: [ProjectFileEntry]] = [:]
    private var childErrors: [String: String] = [:]
    private var truncatedDirectories: Set<String> = []
    private var revision = 0

    init(reader: any ProjectDirectoryReading = LocalProjectDirectoryReader()) {
        self.reader = reader
    }

    var rows: [Row] {
        var result: [Row] = []
        appendRows(rootEntries, depth: 0, to: &result)
        if let rootPath, truncatedDirectories.contains(rootPath) {
            result.append(.truncated(parentPath: rootPath, depth: 0))
        }
        return result
    }

    func loadRoot(path: String?) async {
        revision += 1
        let expectedRevision = revision
        let normalizedPath = path.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }

        rootPath = normalizedPath
        rootEntries = []
        expandedDirectories = []
        loadingDirectories = []
        childEntries = [:]
        childErrors = [:]
        truncatedDirectories = []

        guard let normalizedPath else {
            rootState = .noProject
            return
        }

        rootState = .loading
        do {
            let snapshot = try await reader.contents(ofDirectoryAt: normalizedPath)
            guard revision == expectedRevision, rootPath == normalizedPath else { return }
            rootEntries = snapshot.entries
            if snapshot.wasTruncated { truncatedDirectories.insert(normalizedPath) }
            rootState = snapshot.entries.isEmpty ? .empty : .loaded
        } catch {
            guard revision == expectedRevision, rootPath == normalizedPath else { return }
            rootState = .failed(error.localizedDescription)
        }
    }

    func toggleDirectory(_ entry: ProjectFileEntry) async {
        guard entry.isDirectory else { return }

        if expandedDirectories.contains(entry.path) {
            expandedDirectories.remove(entry.path)
            return
        }

        expandedDirectories.insert(entry.path)
        guard childEntries[entry.path] == nil, childErrors[entry.path] == nil else { return }

        loadingDirectories.insert(entry.path)
        let expectedRevision = revision
        do {
            let snapshot = try await reader.contents(ofDirectoryAt: entry.path)
            guard revision == expectedRevision else { return }
            childEntries[entry.path] = snapshot.entries
            if snapshot.wasTruncated { truncatedDirectories.insert(entry.path) }
        } catch {
            guard revision == expectedRevision else { return }
            childErrors[entry.path] = error.localizedDescription
        }
        loadingDirectories.remove(entry.path)
    }

    func retryDirectory(_ path: String) async {
        guard let entry = findEntry(path: path), entry.isDirectory else { return }
        childErrors.removeValue(forKey: path)
        childEntries.removeValue(forKey: path)
        expandedDirectories.remove(path)
        await toggleDirectory(entry)
    }

    private func appendRows(_ entries: [ProjectFileEntry], depth: Int, to rows: inout [Row]) {
        for entry in entries {
            rows.append(.entry(entry, depth: depth))
            guard entry.isDirectory, expandedDirectories.contains(entry.path) else { continue }

            if loadingDirectories.contains(entry.path) {
                rows.append(.loading(parentPath: entry.path, depth: depth + 1))
            } else if let error = childErrors[entry.path] {
                rows.append(.failure(parentPath: entry.path, message: error, depth: depth + 1))
            } else if let children = childEntries[entry.path] {
                appendRows(children, depth: depth + 1, to: &rows)
                if truncatedDirectories.contains(entry.path) {
                    rows.append(.truncated(parentPath: entry.path, depth: depth + 1))
                }
            }
        }
    }

    private func findEntry(path: String) -> ProjectFileEntry? {
        if let rootEntry = rootEntries.first(where: { $0.path == path }) {
            return rootEntry
        }
        return childEntries.values.lazy.compactMap { entries in
            entries.first(where: { $0.path == path })
        }.first
    }
}
