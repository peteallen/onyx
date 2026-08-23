import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ProjectSourcePreviewTests: XCTestCase {
    func testIndexFindsNestedTextSizedFilesAndSkipsHeavyFoldersLargeFilesAndSymlinks() throws {
        let project = try SourcePreviewFixture()
        let outside = try SourcePreviewFixture()
        defer {
            project.remove()
            outside.remove()
        }

        try project.makeFile("README.md", contents: "hello")
        try project.makeFile("Sources/App.swift", contents: "struct App {}")
        try project.makeFile(".gitignore", contents: ".build")
        try project.makeFile(".git/config", contents: "hidden directory")
        try project.makeFile("node_modules/library.js", contents: "excluded")
        try project.makeDataFile("large.txt", contents: Data(repeating: 65, count: 65))
        try outside.makeFile("secret.txt", contents: "outside")
        try FileManager.default.createSymbolicLink(
            at: project.url.appendingPathComponent("EscapedFolder"),
            withDestinationURL: outside.url
        )

        let snapshot = try LocalProjectSourceReader.readIndex(
            atRoot: project.url.path,
            limits: limits(maximumFileSizeBytes: 64)
        )

        XCTAssertEqual(
            snapshot.files.map(\.relativePath),
            [".gitignore", "README.md", "Sources/App.swift"]
        )
        XCTAssertFalse(snapshot.files.contains { $0.relativePath.contains("secret") })
        XCTAssertFalse(snapshot.wasTruncated)
    }

    func testIndexStopsAtConfiguredFileLimit() throws {
        let project = try SourcePreviewFixture()
        defer { project.remove() }
        try project.makeFile("a.txt", contents: "a")
        try project.makeFile("b.txt", contents: "b")
        try project.makeFile("c.txt", contents: "c")

        let snapshot = try LocalProjectSourceReader.readIndex(
            atRoot: project.url.path,
            limits: limits(maximumIndexedFiles: 2)
        )

        XCTAssertEqual(snapshot.files.count, 2)
        XCTAssertTrue(snapshot.wasTruncated)
    }

    func testPreviewProducesLineNumbersAndHonorsLineLimit() throws {
        let project = try SourcePreviewFixture()
        defer { project.remove() }
        let file = try project.makeFile("Sources/App.swift", contents: "alpha\r\nbeta\n\nomega")

        let preview = try LocalProjectSourceReader.readPreview(
            at: file.path,
            insideRoot: project.url.path,
            limits: limits(maximumPreviewLines: 3)
        )

        XCTAssertEqual(preview.file.relativePath, "Sources/App.swift")
        XCTAssertEqual(
            preview.lines,
            [
                ProjectSourcePreviewLine(number: 1, text: "alpha"),
                ProjectSourcePreviewLine(number: 2, text: "beta"),
                ProjectSourcePreviewLine(number: 3, text: ""),
            ]
        )
        XCTAssertTrue(preview.wasTruncated)
    }

    func testPreviewByteLimitDoesNotRejectUTF8SplitAtBoundary() throws {
        let project = try SourcePreviewFixture()
        defer { project.remove() }
        let file = try project.makeFile("unicode.txt", contents: "abc😀tail")

        let preview = try LocalProjectSourceReader.readPreview(
            at: file.path,
            insideRoot: project.url.path,
            limits: limits(maximumPreviewBytes: 5)
        )

        XCTAssertEqual(preview.lines.map(\.text), ["abc"])
        XCTAssertTrue(preview.wasTruncated)
    }

    func testPreviewRejectsLexicalTraversalAndSymlinkEscape() throws {
        let project = try SourcePreviewFixture()
        let outside = try SourcePreviewFixture()
        defer {
            project.remove()
            outside.remove()
        }
        try outside.makeFile("secret.txt", contents: "do not read")
        try FileManager.default.createSymbolicLink(
            at: project.url.appendingPathComponent("Escape"),
            withDestinationURL: outside.url
        )

        let traversal = "../\(outside.url.lastPathComponent)/secret.txt"
        XCTAssertThrowsError(
            try LocalProjectSourceReader.readPreview(
                at: traversal,
                insideRoot: project.url.path
            )
        ) { error in
            XCTAssertEqual(error as? ProjectSourceError, .outsideWorkspace)
        }

        XCTAssertThrowsError(
            try LocalProjectSourceReader.readPreview(
                at: project.url.appendingPathComponent("Escape/secret.txt").path,
                insideRoot: project.url.path
            )
        ) { error in
            XCTAssertEqual(error as? ProjectSourceError, .outsideWorkspace)
        }
    }

    func testPreviewRejectsHugeAndBinaryFilesBeforeRendering() throws {
        let project = try SourcePreviewFixture()
        defer { project.remove() }
        let huge = try project.makeDataFile("huge.txt", contents: Data(repeating: 65, count: 33))
        let binary = try project.makeDataFile("image.bin", contents: Data([0x89, 0x50, 0x00, 0x47]))
        let testLimits = limits(maximumFileSizeBytes: 32)

        XCTAssertThrowsError(
            try LocalProjectSourceReader.readPreview(
                at: huge.path,
                insideRoot: project.url.path,
                limits: testLimits
            )
        ) { error in
            XCTAssertEqual(error as? ProjectSourceError, .fileTooLarge(maximumBytes: 32))
        }

        XCTAssertThrowsError(
            try LocalProjectSourceReader.readPreview(
                at: binary.path,
                insideRoot: project.url.path,
                limits: testLimits
            )
        ) { error in
            XCTAssertEqual(error as? ProjectSourceError, .binaryFile)
        }
    }

    func testSearchRanksExactFilenameBeforeNestedMatchesAndBoundsResults() {
        let files = [
            sourceFile("Sources/Application/App.swift"),
            sourceFile("App.swift"),
            sourceFile("Tests/App.swift"),
            sourceFile("Sources/AppSupport.swift"),
        ]

        let matches = ProjectSourceSearch.matches(files: files, query: "APP.SWIFT", limit: 2)

        XCTAssertEqual(matches.map(\.relativePath), ["App.swift", "Tests/App.swift"])
    }

    func testNavigatorSearchesLargeIndexesOffActorAndPublishesOnlyTheLatestBoundedQuery() async {
        let files = (0..<4_000).map { index in
            sourceFile(index == 3_999 ? "Sources/LatestTarget.swift" : "Sources/File\(index).swift")
        }
        let reader = SourcePreviewReaderStub(
            snapshot: ProjectSourceIndexSnapshot(
                rootPath: "/fixture",
                files: files,
                wasTruncated: false
            )
        )
        let navigator = ProjectSourceNavigatorModel(reader: reader, searchResultLimit: 100)

        await navigator.loadRoot(path: "/fixture")
        navigator.query = "file"
        await waitUntil("The initial bounded search result was not published") {
            !navigator.isSearching && navigator.searchResults.count == 40
        }
        navigator.query = "latesttarget"
        XCTAssertTrue(navigator.isSearching)
        XCTAssertTrue(
            navigator.searchResults.isEmpty,
            "A new query must not leave the previous query's files selectable."
        )
        await waitUntil("The latest search result was not published") {
            navigator.searchResults.map(\.relativePath) == ["Sources/LatestTarget.swift"]
        }

        XCTAssertLessThanOrEqual(navigator.searchResults.count, 40)
        let firstIndexRequestCount = await reader.indexRequestCount()
        XCTAssertEqual(firstIndexRequestCount, 1)
        await navigator.loadRoot(path: "/fixture")
        let finalIndexRequestCount = await reader.indexRequestCount()
        XCTAssertEqual(
            finalIndexRequestCount,
            1,
            "The window-local navigator must share one index for an unchanged project."
        )
    }

    func testNavigatorCancelsSupersededProjectIndexes() async {
        let reader = CancellableSourceIndexReader()
        let navigator = ProjectSourceNavigatorModel(reader: reader)

        let firstLoad = Task { await navigator.loadRoot(path: "/first") }
        await waitUntil("The first project index did not start") {
            reader.startedRoots.contains("/first")
        }

        let secondLoad = Task { await navigator.loadRoot(path: "/second") }
        await waitUntil("The superseded project index was not cancelled") {
            reader.startedRoots.contains("/second")
                && reader.cancelledRoots.contains("/first")
        }

        await navigator.loadRoot(path: nil)
        await firstLoad.value
        await secondLoad.value
        XCTAssertTrue(reader.cancelledRoots.contains("/second"))
        XCTAssertEqual(navigator.indexState, .noProject)
    }

    func testCancelledLoadCallerDoesNotStrandSharedNavigatorInLoadingState() async {
        let file = sourceFile("Sources/EventuallyReady.swift")
        let reader = DelayedSourceIndexReader(
            delay: .milliseconds(80),
            snapshot: ProjectSourceIndexSnapshot(
                rootPath: "/fixture",
                files: [file],
                wasTruncated: false
            )
        )
        let navigator = ProjectSourceNavigatorModel(reader: reader)
        let load = Task { await navigator.loadRoot(path: "/fixture") }

        await waitUntil("The shared index did not start") {
            reader.didStart
        }
        load.cancel()
        await load.value

        await waitUntil("The shared index remained stuck in loading after its caller was cancelled") {
            if case let .loaded(snapshot) = navigator.indexState {
                return snapshot.files == [file]
            }
            return false
        }

        // A later Files/Quick Open consumer should reuse the completed index,
        // not return early on a permanently loading state.
        await navigator.loadRoot(path: "/fixture")
        XCTAssertEqual(navigator.indexState, .loaded(ProjectSourceIndexSnapshot(
            rootPath: "/fixture",
            files: [file],
            wasTruncated: false
        )))
    }

    func testPaletteLoadPreservesQueryEnteredBeforeIndexCompletes() async {
        let file = sourceFile("Sources/AlreadyTyped.swift")
        let reader = SourcePreviewReaderStub(
            snapshot: ProjectSourceIndexSnapshot(
                rootPath: "/fixture",
                files: [file],
                wasTruncated: false
            )
        )
        let navigator = ProjectSourceNavigatorModel(reader: reader)
        navigator.query = "alreadytyped"

        await navigator.loadRootPreservingQuery(path: "/fixture")
        await waitUntil("The pre-index palette query was not ranked") {
            !navigator.isSearching && navigator.searchResults == [file]
        }

        XCTAssertEqual(navigator.query, "alreadytyped")
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private func limits(
        maximumIndexedFiles: Int = 100,
        maximumVisitedEntries: Int = 500,
        maximumDepth: Int = 8,
        maximumFileSizeBytes: Int = 1_024,
        maximumPreviewBytes: Int = 512,
        maximumPreviewLines: Int = 50
    ) -> ProjectSourceLimits {
        ProjectSourceLimits(
            maximumIndexedFiles: maximumIndexedFiles,
            maximumVisitedEntries: maximumVisitedEntries,
            maximumDepth: maximumDepth,
            maximumFileSizeBytes: maximumFileSizeBytes,
            maximumPreviewBytes: maximumPreviewBytes,
            maximumPreviewLines: maximumPreviewLines,
            maximumSearchResults: 20
        )
    }

    private func sourceFile(_ path: String) -> ProjectSourceFile {
        ProjectSourceFile(path: "/fixture/\(path)", relativePath: path, byteCount: 1)
    }
}

private actor SourcePreviewReaderStub: ProjectSourceReading {
    private let snapshot: ProjectSourceIndexSnapshot
    private var indexRequests = 0

    init(snapshot: ProjectSourceIndexSnapshot) {
        self.snapshot = snapshot
    }

    func indexFiles(atRoot _: String) async throws -> ProjectSourceIndexSnapshot {
        indexRequests += 1
        return snapshot
    }

    func previewFile(at _: String, insideRoot _: String) async throws -> ProjectSourcePreview {
        throw ProjectSourceError.unavailable("Preview is outside this search fixture.")
    }

    func indexRequestCount() -> Int { indexRequests }
}

private final class DelayedSourceIndexReader: ProjectSourceReading, @unchecked Sendable {
    let delay: Duration
    let snapshot: ProjectSourceIndexSnapshot
    private let lock = NSLock()
    private var recordedDidStart = false

    var didStart: Bool { lock.withLock { recordedDidStart } }

    init(delay: Duration, snapshot: ProjectSourceIndexSnapshot) {
        self.delay = delay
        self.snapshot = snapshot
    }

    func indexFiles(atRoot _: String) async throws -> ProjectSourceIndexSnapshot {
        lock.withLock { recordedDidStart = true }
        try await Task.sleep(for: delay)
        return snapshot
    }

    func previewFile(at _: String, insideRoot _: String) async throws -> ProjectSourcePreview {
        throw ProjectSourceError.unavailable("Preview is outside this cancellation fixture.")
    }
}

private final class CancellableSourceIndexReader: ProjectSourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStartedRoots: [String] = []
    private var recordedCancelledRoots: [String] = []

    var startedRoots: [String] { lock.withLock { recordedStartedRoots } }
    var cancelledRoots: [String] { lock.withLock { recordedCancelledRoots } }

    func indexFiles(atRoot rootPath: String) async throws -> ProjectSourceIndexSnapshot {
        lock.withLock { recordedStartedRoots.append(rootPath) }
        do {
            try await Task.sleep(for: .seconds(30))
            return ProjectSourceIndexSnapshot(rootPath: rootPath, files: [], wasTruncated: false)
        } catch is CancellationError {
            lock.withLock { recordedCancelledRoots.append(rootPath) }
            throw CancellationError()
        }
    }

    func previewFile(at _: String, insideRoot _: String) async throws -> ProjectSourcePreview {
        throw ProjectSourceError.unavailable("Preview is outside this cancellation fixture.")
    }
}

private struct SourcePreviewFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxSourcePreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    @discardableResult
    func makeFile(_ relativePath: String, contents: String) throws -> URL {
        try makeDataFile(relativePath, contents: Data(contents.utf8))
    }

    @discardableResult
    func makeDataFile(_ relativePath: String, contents: Data) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
        return fileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
