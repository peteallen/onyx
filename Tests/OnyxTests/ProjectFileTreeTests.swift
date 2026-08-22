import Foundation
import XCTest
@testable import Onyx

final class ProjectFileTreeTests: XCTestCase {
    func testDirectoryListingUsesRealEntriesFoldersFirstAndExcludesHeavyFolders() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }

        try fixture.makeDirectory("zeta")
        try fixture.makeDirectory("Alpha")
        try fixture.makeDirectory(".git")
        try fixture.makeDirectory(".build")
        try fixture.makeDirectory("node_modules")
        try fixture.makeFile("beta.swift")
        try fixture.makeFile("A.swift")
        try fixture.makeFile(".gitignore")

        let snapshot = try LocalProjectDirectoryReader.readDirectory(
            at: fixture.url.path,
            entryLimit: 100
        )

        XCTAssertEqual(
            snapshot.entries.map(\.name),
            ["Alpha", "zeta", ".gitignore", "A.swift", "beta.swift"]
        )
        XCTAssertEqual(snapshot.entries.map(\.kind), [.directory, .directory, .file, .file, .file])
        XCTAssertFalse(snapshot.wasTruncated)
    }

    func testDirectoryListingIsShallowAndBounded() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }

        try fixture.makeDirectory("Sources")
        try fixture.makeFile("Sources/Nested.swift")
        try fixture.makeFile("one.txt")
        try fixture.makeFile("two.txt")
        try fixture.makeFile("three.txt")

        let snapshot = try LocalProjectDirectoryReader.readDirectory(
            at: fixture.url.path,
            entryLimit: 2
        )

        XCTAssertEqual(snapshot.entries.map(\.name), ["Sources", "one.txt"])
        XCTAssertFalse(snapshot.entries.contains { $0.name == "Nested.swift" })
        XCTAssertTrue(snapshot.wasTruncated)
    }

    func testSymbolicLinkIsNotTreatedAsExpandableDirectory() throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }

        try fixture.makeDirectory("RealFolder")
        try FileManager.default.createSymbolicLink(
            at: fixture.url.appendingPathComponent("LinkedFolder"),
            withDestinationURL: fixture.url.appendingPathComponent("RealFolder", isDirectory: true)
        )

        let snapshot = try LocalProjectDirectoryReader.readDirectory(
            at: fixture.url.path,
            entryLimit: 100
        )
        let link = try XCTUnwrap(snapshot.entries.first { $0.name == "LinkedFolder" })

        XCTAssertEqual(link.kind, .symbolicLink)
        XCTAssertFalse(link.isDirectory)
    }
}

private struct TemporaryProjectFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxProjectFileTreeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func makeFile(_ relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
