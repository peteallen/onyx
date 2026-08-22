import Foundation
import XCTest
@testable import Onyx

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
