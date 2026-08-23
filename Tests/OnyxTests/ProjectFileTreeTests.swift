import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Onyx

final class ProjectFileTreeTests: XCTestCase {
    @MainActor
    func testClickingFolderNameTogglesDirectory() throws {
        let entry = ProjectFileEntry(
            path: "/tmp/OnyxProjectFileTreeTests/Sources",
            name: "Sources",
            kind: .directory
        )
        var toggleCount = 0
        let size = NSSize(width: 280, height: OnyxHitTarget.compact)
        let hostingView = NSHostingView(
            rootView: ProjectFileRow(
                entry: entry,
                depth: 0,
                isExpanded: false,
                onToggle: { toggleCount += 1 },
                onPreview: {},
                onOpen: {},
                onReveal: {}
            )
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()

        // The label begins after the chevron and folder icon. This point is
        // horizontally outside the old chevron-only target and vertically in
        // the extra area beyond the old 23-point row, so a normal imprecise
        // click still toggles the folder.
        try click(at: NSPoint(x: 55, y: 3), in: window)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))

        XCTAssertEqual(toggleCount, 1)
    }

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

    @MainActor
    private func click(at point: NSPoint, in window: NSWindow) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        window.sendEvent(down)
        window.sendEvent(up)
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
