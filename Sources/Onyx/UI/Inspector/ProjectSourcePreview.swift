import Combine
import Foundation

struct ProjectSourceLimits: Equatable, Sendable {
    static let `default` = ProjectSourceLimits()

    let maximumIndexedFiles: Int
    let maximumVisitedEntries: Int
    let maximumDepth: Int
    let maximumFileSizeBytes: Int
    let maximumPreviewBytes: Int
    let maximumPreviewLines: Int
    let maximumSearchResults: Int

    init(
        maximumIndexedFiles: Int = 4_000,
        maximumVisitedEntries: Int = 20_000,
        maximumDepth: Int = 14,
        maximumFileSizeBytes: Int = 1_000_000,
        maximumPreviewBytes: Int = 256_000,
        maximumPreviewLines: Int = 800,
        maximumSearchResults: Int = 40
    ) {
        self.maximumIndexedFiles = max(1, maximumIndexedFiles)
        self.maximumVisitedEntries = max(1, maximumVisitedEntries)
        self.maximumDepth = max(1, maximumDepth)
        self.maximumFileSizeBytes = max(1, maximumFileSizeBytes)
        self.maximumPreviewBytes = max(1, min(maximumPreviewBytes, maximumFileSizeBytes))
        self.maximumPreviewLines = max(1, maximumPreviewLines)
        self.maximumSearchResults = max(1, maximumSearchResults)
    }
}

struct ProjectSourceFile: Identifiable, Equatable, Sendable {
    let path: String
    let relativePath: String
    let byteCount: Int

    var id: String { path }
    var name: String { URL(fileURLWithPath: relativePath).lastPathComponent }
}

struct ProjectSourceIndexSnapshot: Equatable, Sendable {
    let rootPath: String
    let files: [ProjectSourceFile]
    let wasTruncated: Bool
}

struct ProjectSourcePreviewLine: Identifiable, Equatable, Sendable {
    let number: Int
    let text: String

    var id: Int { number }
}

struct ProjectSourcePreview: Equatable, Sendable {
    let file: ProjectSourceFile
    let lines: [ProjectSourcePreviewLine]
    let wasTruncated: Bool
}

protocol ProjectSourceReading: Sendable {
    func indexFiles(atRoot rootPath: String) async throws -> ProjectSourceIndexSnapshot
    func previewFile(at path: String, insideRoot rootPath: String) async throws -> ProjectSourcePreview
}

enum ProjectSourceError: LocalizedError, Equatable, Sendable {
    case missingRoot(String)
    case rootIsNotDirectory(String)
    case outsideWorkspace
    case notRegularFile
    case fileTooLarge(maximumBytes: Int)
    case binaryFile
    case unsupportedTextEncoding
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .missingRoot(path):
            "The project folder no longer exists at \(path)."
        case let .rootIsNotDirectory(path):
            "The project location is not a folder: \(path)."
        case .outsideWorkspace:
            "Onyx will only preview files contained by this project."
        case .notRegularFile:
            "This item is not a regular file and cannot be previewed."
        case let .fileTooLarge(maximumBytes):
            "This file is larger than the \(Self.formattedByteCount(maximumBytes)) preview limit."
        case .binaryFile:
            "This appears to be a binary file, so Onyx did not read it as text."
        case .unsupportedTextEncoding:
            "This file is not valid UTF-8 text and cannot be previewed safely."
        case let .unavailable(message):
            message
        }
    }

    private static func formattedByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

enum WorkspacePathSafety {
    struct Root: Equatable, Sendable {
        let requestedURL: URL
        let canonicalURL: URL
    }

    static func resolveRoot(_ path: String) throws -> Root {
        let requestedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory) else {
            throw ProjectSourceError.missingRoot(requestedURL.path)
        }
        guard isDirectory.boolValue else {
            throw ProjectSourceError.rootIsNotDirectory(requestedURL.path)
        }

        return Root(
            requestedURL: requestedURL,
            canonicalURL: requestedURL.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    static func resolveExistingURL(at path: String, insideRoot rootPath: String) throws -> URL {
        let root = try resolveRoot(rootPath)
        let requestedURL: URL
        if NSString(string: path).isAbsolutePath {
            requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            requestedURL = root.requestedURL.appendingPathComponent(path).standardizedFileURL
        }

        // Accept paths expressed relative to either the selected path or its canonical target.
        // Reject lexical traversal before following any symlink in the candidate path.
        guard contains(requestedURL, in: root.requestedURL)
                || contains(requestedURL, in: root.canonicalURL) else {
            throw ProjectSourceError.outsideWorkspace
        }

        let canonicalURL = requestedURL.resolvingSymlinksInPath().standardizedFileURL
        guard contains(canonicalURL, in: root.canonicalURL) else {
            throw ProjectSourceError.outsideWorkspace
        }
        guard FileManager.default.fileExists(atPath: canonicalURL.path) else {
            throw ProjectSourceError.unavailable("This file no longer exists.")
        }
        return canonicalURL
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }

    static func relativePath(for candidate: URL, in root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count,
              zip(rootComponents, candidateComponents).allSatisfy(==) else { return nil }
        return candidateComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

struct LocalProjectSourceReader: ProjectSourceReading {
    let limits: ProjectSourceLimits

    init(limits: ProjectSourceLimits = .default) {
        self.limits = limits
    }

    func indexFiles(atRoot rootPath: String) async throws -> ProjectSourceIndexSnapshot {
        let limits = limits
        let task = Task.detached(priority: .userInitiated) {
            try Self.readIndex(atRoot: rootPath, limits: limits)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func previewFile(at path: String, insideRoot rootPath: String) async throws -> ProjectSourcePreview {
        let limits = limits
        return try await Task.detached(priority: .userInitiated) {
            try Self.readPreview(at: path, insideRoot: rootPath, limits: limits)
        }.value
    }

    static func readIndex(
        atRoot rootPath: String,
        limits: ProjectSourceLimits = .default
    ) throws -> ProjectSourceIndexSnapshot {
        let root = try WorkspacePathSafety.resolveRoot(rootPath)
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root.canonicalURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw ProjectSourceError.unavailable("Onyx could not browse this project folder.")
        }

        var files: [ProjectSourceFile] = []
        var visitedEntryCount = 0
        var wasTruncated = false

        while let candidate = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            visitedEntryCount += 1
            if visitedEntryCount > limits.maximumVisitedEntries {
                wasTruncated = true
                break
            }

            let values: URLResourceValues
            do {
                values = try candidate.resourceValues(forKeys: Set(resourceKeys))
            } catch {
                enumerator.skipDescendants()
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if values.isDirectory == true {
                if shouldExcludeDirectory(named: candidate.lastPathComponent) {
                    enumerator.skipDescendants()
                } else if enumerator.level >= limits.maximumDepth {
                    enumerator.skipDescendants()
                    wasTruncated = true
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard WorkspacePathSafety.contains(canonicalCandidate, in: root.canonicalURL),
                  let relativePath = WorkspacePathSafety.relativePath(
                    for: canonicalCandidate,
                    in: root.canonicalURL
                  ) else { continue }

            let byteCount = max(0, values.fileSize ?? 0)
            guard byteCount <= limits.maximumFileSizeBytes else { continue }
            if files.count >= limits.maximumIndexedFiles {
                wasTruncated = true
                break
            }
            files.append(
                ProjectSourceFile(
                    path: canonicalCandidate.path,
                    relativePath: relativePath,
                    byteCount: byteCount
                )
            )
        }

        files.sort { lhs, rhs in
            let lhsFolded = lhs.relativePath.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let rhsFolded = rhs.relativePath.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if lhsFolded != rhsFolded { return lhsFolded < rhsFolded }
            return lhs.relativePath < rhs.relativePath
        }

        return ProjectSourceIndexSnapshot(
            rootPath: root.canonicalURL.path,
            files: files,
            wasTruncated: wasTruncated
        )
    }

    static func readPreview(
        at path: String,
        insideRoot rootPath: String,
        limits: ProjectSourceLimits = .default
    ) throws -> ProjectSourcePreview {
        let root = try WorkspacePathSafety.resolveRoot(rootPath)
        let fileURL = try WorkspacePathSafety.resolveExistingURL(at: path, insideRoot: rootPath)
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
        guard values.isRegularFile == true else { throw ProjectSourceError.notRegularFile }

        let byteCount = max(0, values.fileSize ?? 0)
        guard byteCount <= limits.maximumFileSizeBytes else {
            throw ProjectSourceError.fileTooLarge(maximumBytes: limits.maximumFileSizeBytes)
        }
        guard values.isReadable != false else {
            throw ProjectSourceError.unavailable("This file is not readable.")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw ProjectSourceError.unavailable("Onyx could not read this file.")
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: limits.maximumPreviewBytes + 1) ?? Data()
        } catch {
            throw ProjectSourceError.unavailable("Onyx could not read this file.")
        }

        let byteLimited = data.count > limits.maximumPreviewBytes
            || byteCount > limits.maximumPreviewBytes
        let visibleData = Data(data.prefix(limits.maximumPreviewBytes))
        guard !visibleData.contains(0) else { throw ProjectSourceError.binaryFile }
        let text = try decodeUTF8(visibleData, mayEndMidScalar: byteLimited)
        guard looksLikeReadableText(text) else { throw ProjectSourceError.binaryFile }

        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
        let lineLimited = rawLines.count > limits.maximumPreviewLines
        let lines = rawLines.prefix(limits.maximumPreviewLines).enumerated().map { offset, rawLine in
            ProjectSourcePreviewLine(number: offset + 1, text: String(rawLine))
        }
        let relativePath = WorkspacePathSafety.relativePath(for: fileURL, in: root.canonicalURL)
            ?? fileURL.lastPathComponent

        return ProjectSourcePreview(
            file: ProjectSourceFile(
                path: fileURL.path,
                relativePath: relativePath,
                byteCount: byteCount
            ),
            lines: lines,
            wasTruncated: byteLimited || lineLimited
        )
    }

    private static func shouldExcludeDirectory(named name: String) -> Bool {
        name.hasPrefix(".") || ["node_modules", "Pods", "DerivedData"].contains(name)
    }

    private static func decodeUTF8(_ data: Data, mayEndMidScalar: Bool) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if mayEndMidScalar, !data.isEmpty {
            for bytesToDrop in 1 ... min(3, data.count) {
                if let text = String(data: data.dropLast(bytesToDrop), encoding: .utf8) {
                    return text
                }
            }
        }
        throw ProjectSourceError.unsupportedTextEncoding
    }

    private static func looksLikeReadableText(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return true }
        let suspiciousCount = scalars.reduce(into: 0) { count, scalar in
            let value = scalar.value
            if value < 0x20, value != 0x09, value != 0x0A, value != 0x0D {
                count += 1
            }
        }
        return suspiciousCount * 50 <= scalars.count
    }
}

enum ProjectSourceSearch {
    static func matches(
        files: [ProjectSourceFile],
        query: String,
        limit: Int,
        isCancelled: () -> Bool = { false }
    ) -> [ProjectSourceFile] {
        let foldedQuery = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !foldedQuery.isEmpty else { return [] }
        let terms = foldedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

        var ranked: [(file: ProjectSourceFile, rank: SearchRank)] = []
        ranked.reserveCapacity(min(files.count, max(1, limit) * 4))
        for (offset, file) in files.enumerated() {
            if offset.isMultiple(of: 64), isCancelled() { return [] }
            let path = fold(file.relativePath)
            let name = fold(file.name)
            guard terms.allSatisfy({ path.contains($0) }) else { continue }

            let matchClass: Int
            if name == foldedQuery {
                matchClass = 0
            } else if name.hasPrefix(foldedQuery) {
                matchClass = 1
            } else if name.contains(foldedQuery) {
                matchClass = 2
            } else if path.hasPrefix(foldedQuery) {
                matchClass = 3
            } else {
                matchClass = 4
            }
            let firstMatch = terms.compactMap { path.range(of: $0)?.lowerBound.utf16Offset(in: path) }.min()
                ?? Int.max
            ranked.append(
                (file, SearchRank(matchClass: matchClass, firstMatch: firstMatch, length: path.count))
            )
        }

        guard !isCancelled() else { return [] }
        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.file.relativePath < rhs.file.relativePath
        }
        .prefix(max(1, limit))
        .map(\.file)
    }

    private struct SearchRank: Comparable {
        let matchClass: Int
        let firstMatch: Int
        let length: Int

        static func < (lhs: SearchRank, rhs: SearchRank) -> Bool {
            if lhs.matchClass != rhs.matchClass { return lhs.matchClass < rhs.matchClass }
            if lhs.firstMatch != rhs.firstMatch { return lhs.firstMatch < rhs.firstMatch }
            return lhs.length < rhs.length
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

@MainActor
final class ProjectSourceNavigatorModel: ObservableObject {
    enum IndexState: Equatable {
        case noProject
        case loading
        case loaded(ProjectSourceIndexSnapshot)
        case failed(String)
    }

    enum PreviewState: Equatable {
        case none
        case loading(String)
        case loaded(ProjectSourcePreview)
        case failed(String)
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var indexState: IndexState = .noProject
    @Published private(set) var previewState: PreviewState = .none
    @Published private(set) var searchResults: [ProjectSourceFile] = []
    @Published private(set) var isSearching = false

    private let reader: any ProjectSourceReading
    private let searchResultLimit: Int
    private var rootPath: String?
    private var indexRevision = 0
    private var previewRevision = 0
    private var searchRevision = 0
    private var indexTask: Task<ProjectSourceIndexSnapshot, any Error>?
    private var searchTask: Task<Void, Never>?
    private var searchCache: [String: [ProjectSourceFile]] = [:]
    private var searchCacheOrder: [String] = []
    private let searchCacheLimit = 24

    init(
        reader: any ProjectSourceReading = LocalProjectSourceReader(),
        searchResultLimit: Int = ProjectSourceLimits.default.maximumSearchResults
    ) {
        self.reader = reader
        self.searchResultLimit = max(1, searchResultLimit)
    }

    var indexWasTruncated: Bool {
        guard case let .loaded(snapshot) = indexState else { return false }
        return snapshot.wasTruncated
    }

    func loadRoot(path: String?) async {
        await loadRoot(path: path, force: false, preserveQuery: false)
    }

    /// Quick Open deliberately accepts typing before an uncached index is
    /// ready. Preserve that input when the palette starts the first load; the
    /// completed snapshot will rank the already-entered query.
    func loadRootPreservingQuery(path: String?) async {
        await loadRoot(path: path, force: false, preserveQuery: true)
    }

    func reloadRoot(path: String?) async {
        await loadRoot(path: path, force: true, preserveQuery: false)
    }

    private func loadRoot(path: String?, force: Bool, preserveQuery: Bool) async {
        let normalizedPath = Self.normalizedRootPath(path)
        if !force, rootPath == normalizedPath {
            switch indexState {
            case .loading, .loaded, .noProject:
                return
            case .failed:
                break
            }
        }

        indexRevision += 1
        previewRevision += 1
        searchRevision += 1
        indexTask?.cancel()
        indexTask = nil
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        isSearching = false
        searchCache.removeAll(keepingCapacity: true)
        searchCacheOrder.removeAll(keepingCapacity: true)
        let expectedRevision = indexRevision

        rootPath = normalizedPath
        if !preserveQuery { query = "" }
        previewState = .none
        guard let normalizedPath else {
            indexState = .noProject
            return
        }

        indexState = .loading
        let task = Task { try await reader.indexFiles(atRoot: normalizedPath) }
        indexTask = task
        // This is a window-owned cache, not a view-owned operation. A SwiftUI
        // `.task(id:)` caller is routinely cancelled when the Files inspector
        // disappears; that must not strand the shared navigator in `.loading`.
        // The next project load/refresh cancels this model-owned task if it is
        // obsolete, while the current task is allowed to finish and publish.
        let result = await task.result
        do {
            let snapshot = try result.get()
            guard indexRevision == expectedRevision, rootPath == normalizedPath else { return }
            indexTask = nil
            indexState = .loaded(snapshot)
            scheduleSearch()
        } catch is CancellationError {
            if indexRevision == expectedRevision { indexTask = nil }
            return
        } catch {
            guard indexRevision == expectedRevision, rootPath == normalizedPath else { return }
            indexTask = nil
            indexState = .failed(error.localizedDescription)
        }
    }

    func preview(_ file: ProjectSourceFile) async {
        await preview(path: file.path, displayName: file.relativePath)
    }

    func preview(path: String, displayName: String? = nil) async {
        guard let rootPath else { return }
        previewRevision += 1
        let expectedRevision = previewRevision
        previewState = .loading(displayName ?? URL(fileURLWithPath: path).lastPathComponent)

        do {
            let preview = try await reader.previewFile(at: path, insideRoot: rootPath)
            guard previewRevision == expectedRevision, self.rootPath == rootPath else { return }
            previewState = .loaded(preview)
        } catch is CancellationError {
            return
        } catch {
            guard previewRevision == expectedRevision, self.rootPath == rootPath else { return }
            previewState = .failed(error.localizedDescription)
        }
    }

    func clearPreview() {
        previewRevision += 1
        previewState = .none
    }

    private func scheduleSearch() {
        searchRevision += 1
        let expectedSearchRevision = searchRevision
        searchTask?.cancel()
        searchTask = nil
        isSearching = false

        guard case let .loaded(snapshot) = indexState else {
            searchResults = []
            return
        }

        let cacheKey = Self.searchCacheKey(query)
        guard !cacheKey.isEmpty else {
            searchResults = []
            return
        }
        if let cached = searchCache[cacheKey] {
            searchResults = cached
            touchCacheKey(cacheKey)
            return
        }

        let files = snapshot.files
        let requestedQuery = query
        let expectedIndexRevision = indexRevision
        let resultLimit = min(40, searchResultLimit)
        // Never leave the previous query's selectable rows live while a new
        // query is being ranked. Return during this brief interval must be a
        // no-op, not an accidental open of a stale file.
        searchResults = []
        isSearching = true
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let matches = ProjectSourceSearch.matches(
                files: files,
                query: requestedQuery,
                limit: resultLimit,
                isCancelled: { Task.isCancelled }
            )
            guard !Task.isCancelled else { return }
            await self?.publishSearchResults(
                matches,
                cacheKey: cacheKey,
                searchRevision: expectedSearchRevision,
                indexRevision: expectedIndexRevision
            )
        }
    }

    private func publishSearchResults(
        _ results: [ProjectSourceFile],
        cacheKey: String,
        searchRevision expectedSearchRevision: Int,
        indexRevision expectedIndexRevision: Int
    ) {
        guard searchRevision == expectedSearchRevision,
              indexRevision == expectedIndexRevision,
              Self.searchCacheKey(query) == cacheKey else { return }
        isSearching = false
        searchResults = Array(results.prefix(min(40, searchResultLimit)))
        searchCache[cacheKey] = searchResults
        touchCacheKey(cacheKey)
        while searchCacheOrder.count > searchCacheLimit {
            searchCache.removeValue(forKey: searchCacheOrder.removeFirst())
        }
    }

    private func touchCacheKey(_ key: String) {
        searchCacheOrder.removeAll { $0 == key }
        searchCacheOrder.append(key)
    }

    private static func normalizedRootPath(_ path: String?) -> String? {
        path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
    }

    private static func searchCacheKey(_ query: String) -> String {
        query
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
