import Foundation
import XCTest
@testable import Onyx

final class ProjectCatalogStoreTests: XCTestCase {
    func testImportPersistsStableIdentityNormalizedPathAndDates() async throws {
        let location = temporaryCatalogLocation(nested: true)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ProjectCatalogStore(fileURL: location.file, now: { createdAt })

        let imported = try await store.importProject(
            folderPath: "/tmp/onyx-work/child/../",
            displayName: "  My Project  ",
            id: ProjectID("stable-project")
        )
        XCTAssertEqual(imported.id, ProjectID("stable-project"))
        XCTAssertEqual(imported.folderPath, "/tmp/onyx-work")
        XCTAssertEqual(imported.displayName, "My Project")
        XCTAssertEqual(imported.order, 0)
        XCTAssertEqual(imported.createdAt, createdAt)
        XCTAssertEqual(imported.updatedAt, createdAt)

        let reimported = try await store.importProject(
            folderPath: "/tmp/onyx-work/./",
            displayName: "A re-import does not implicitly rename",
            id: ProjectID("discarded-new-id")
        )
        XCTAssertEqual(reimported, imported)

        let reopened = ProjectCatalogStore(fileURL: location.file)
        let reopenedProjects = try await reopened.projects()
        let reopenedProject = try await reopened.project(id: imported.id)
        XCTAssertEqual(reopenedProjects, [imported])
        XCTAssertEqual(reopenedProject, imported)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: location.file))
                as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["projects"] as? [[String: Any]])
    }

    func testRenameAndCompleteReorderAreDurableAndUpdateMetadata() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let creator = ProjectCatalogStore(fileURL: location.file, now: { createdAt })

        let first = try await creator.importProject(
            folderPath: "/tmp/first",
            id: ProjectID("first")
        )
        let second = try await creator.importProject(
            folderPath: "/tmp/second",
            id: ProjectID("second")
        )
        let third = try await creator.importProject(
            folderPath: "/tmp/third",
            id: ProjectID("third")
        )
        XCTAssertEqual([first, second, third].map(\.displayName), ["first", "second", "third"])

        let editor = ProjectCatalogStore(fileURL: location.file, now: { updatedAt })
        let renamed = try await editor.rename(id: second.id, displayName: "  Renamed  ")
        XCTAssertEqual(renamed.displayName, "Renamed")
        XCTAssertEqual(renamed.createdAt, createdAt)
        XCTAssertEqual(renamed.updatedAt, updatedAt)

        let reordered = try await editor.reorder([third.id, first.id, second.id])
        XCTAssertEqual(reordered.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(reordered.map(\.order), [0, 1, 2])
        XCTAssertTrue(reordered.allSatisfy { $0.createdAt == createdAt })
        XCTAssertTrue(reordered.allSatisfy { $0.updatedAt == updatedAt })

        let bytesBeforeInvalidReorder = try Data(contentsOf: location.file)
        do {
            _ = try await editor.reorder([third.id, third.id, second.id])
            XCTFail("Expected duplicate/incomplete ordering to be rejected")
        } catch {
            XCTAssertEqual(error as? ProjectCatalogError, .invalidReorder)
        }
        XCTAssertEqual(try Data(contentsOf: location.file), bytesBeforeInvalidReorder)

        let reopened = ProjectCatalogStore(fileURL: location.file)
        let persistedProjects = try await reopened.projects()
        XCTAssertEqual(persistedProjects, reordered)
    }

    func testRemoveOnlyChangesOnyxMetadataAndCompactsOrdering() async throws {
        let location = temporaryCatalogLocation()
        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-project-contents-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: location.directory)
            try? FileManager.default.removeItem(at: projectDirectory)
        }
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let marker = projectDirectory.appendingPathComponent("must-survive.txt")
        let markerData = Data("leave me alone".utf8)
        try markerData.write(to: marker)

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let removedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let creator = ProjectCatalogStore(fileURL: location.file, now: { createdAt })
        let first = try await creator.importProject(
            folderPath: "/tmp/before",
            id: ProjectID("before")
        )
        let removable = try await creator.importProject(
            folderPath: projectDirectory.path,
            id: ProjectID("removable")
        )
        let last = try await creator.importProject(
            folderPath: "/tmp/after",
            id: ProjectID("after")
        )

        let remover = ProjectCatalogStore(fileURL: location.file, now: { removedAt })
        let removed = try await remover.removeFromOnyx(id: removable.id)
        XCTAssertEqual(removed, removable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDirectory.path))
        XCTAssertEqual(try Data(contentsOf: marker), markerData)

        let survivors = try await remover.projects()
        XCTAssertEqual(survivors.map(\.id), [first.id, last.id])
        XCTAssertEqual(survivors.map(\.order), [0, 1])
        XCTAssertEqual(survivors[0].updatedAt, createdAt)
        XCTAssertEqual(survivors[1].updatedAt, removedAt)
        let repeatedRemoval = try await remover.remove(id: removable.id)
        XCTAssertNil(repeatedRemoval)
    }

    func testResolverNormalizesPathsUsesDeepestAncestorAndAvoidsPrefixCollisions() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = makeProject(
            id: "parent",
            path: "/tmp/work",
            name: "Parent",
            order: 1,
            timestamp: timestamp
        )
        let nested = makeProject(
            id: "nested",
            path: "/tmp/work/packages/nested",
            name: "Nested",
            order: 0,
            timestamp: timestamp
        )
        let prefixCollision = makeProject(
            id: "worktree",
            path: "/tmp/worktree",
            name: "Worktree",
            order: 2,
            timestamp: timestamp
        )
        let projects = [parent, nested, prefixCollision]

        let nestedConversation = makeConversation(
            id: "nested-conversation",
            project: ConversationProject(
                path: " /tmp/work/packages/./nested/Sources/../Sources/ "
            )
        )
        let parentConversation = makeConversation(
            id: "parent-conversation",
            project: ConversationProject(path: "/tmp/work/Tests")
        )
        let prefixConversation = makeConversation(
            id: "prefix-conversation",
            project: ConversationProject(path: "/tmp/worktree/")
        )
        let falsePrefix = makeConversation(
            id: "false-prefix",
            project: ConversationProject(path: "/tmp/work-other")
        )
        let noProject = makeConversation(id: "no-project", project: nil)

        XCTAssertEqual(
            ProjectCatalogResolver.project(for: nestedConversation, in: projects)?.id,
            nested.id
        )
        XCTAssertEqual(
            ProjectCatalogResolver.project(for: parentConversation, in: projects)?.id,
            parent.id
        )
        XCTAssertEqual(
            ProjectCatalogResolver.project(for: prefixConversation, in: projects)?.id,
            prefixCollision.id
        )
        XCTAssertNil(ProjectCatalogResolver.project(for: falsePrefix, in: projects))

        let grouping = ProjectCatalogResolver.group(
            [nestedConversation, parentConversation, prefixConversation, falsePrefix, noProject],
            by: projects
        )
        XCTAssertEqual(grouping.groups.map { $0.project.id }, [nested.id, parent.id, prefixCollision.id])
        XCTAssertEqual(grouping.groups[0].conversations.map(\.id), [nestedConversation.id])
        XCTAssertEqual(grouping.groups[1].conversations.map(\.id), [parentConversation.id])
        XCTAssertEqual(grouping.groups[2].conversations.map(\.id), [prefixConversation.id])
        XCTAssertEqual(grouping.unassigned.map(\.id), [falsePrefix.id, noProject.id])
    }

    func testLegacyConversationProjectsDecodeAndResolveWithoutShapeChanges() throws {
        let legacyJSON = Data(#"{"path":"/tmp/legacy/child/.."}"#.utf8)
        let legacy = try JSONDecoder().decode(ConversationProject.self, from: legacyJSON)
        XCTAssertEqual(legacy.path, "/tmp/legacy/child/..")
        XCTAssertNil(legacy.displayName)

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = makeProject(
            id: "existing",
            path: "/tmp/legacy",
            name: "Existing",
            order: 0,
            timestamp: timestamp
        )
        XCTAssertEqual(
            ProjectCatalogResolver.project(for: legacy, in: [existing])?.id,
            existing.id
        )
    }

    func testConcurrentStoreInstancesPreserveAllImportsAndValidOrdering() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let count = 24
        let stores = (0 ..< count).map { _ in
            ProjectCatalogStore(fileURL: location.file, now: { timestamp })
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, store) in stores.enumerated() {
                group.addTask {
                    _ = try await store.importProject(
                        folderPath: "/tmp/concurrent-project-\(index)",
                        id: ProjectID("concurrent-\(index)")
                    )
                }
            }
            try await group.waitForAll()
        }

        let reopened = ProjectCatalogStore(fileURL: location.file)
        let persisted = try await reopened.projects()
        XCTAssertEqual(persisted.count, count)
        XCTAssertEqual(Set(persisted.map(\.id)), Set((0 ..< count).map { ProjectID("concurrent-\($0)") }))
        XCTAssertEqual(persisted.map(\.order), Array(0 ..< count))
        XCTAssertEqual(Set(persisted.map(\.folderPath)).count, count)
    }

    func testInvalidPathsAndMalformedOrderingDoNotOverwriteCatalog() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = ProjectCatalogStore(fileURL: location.file)
        do {
            _ = try await store.importProject(folderPath: "relative/project")
            XCTFail("Expected a relative path to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ProjectCatalogError,
                .invalidFolderPath("relative/project")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))

        try FileManager.default.createDirectory(
            at: location.directory,
            withIntermediateDirectories: true
        )
        let invalid = Data(
            #"{"schemaVersion":1,"projects":[{"id":"one","folderPath":"/tmp/one","displayName":"One","order":2,"createdAt":1700000000000,"updatedAt":1700000000000}]}"#.utf8
        )
        try invalid.write(to: location.file)
        do {
            _ = try await store.snapshot()
            XCTFail("Expected invalid persisted ordering")
        } catch {
            XCTAssertEqual(error as? ProjectCatalogError, .invalidProjectOrder)
        }
        XCTAssertEqual(try Data(contentsOf: location.file), invalid)
    }
}

private extension ProjectCatalogStoreTests {
    struct TemporaryLocation {
        let directory: URL
        let file: URL
    }

    func temporaryCatalogLocation(nested: Bool = false) -> TemporaryLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-project-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        let parent = nested
            ? directory.appendingPathComponent("nested/catalog", isDirectory: true)
            : directory
        return TemporaryLocation(
            directory: directory,
            file: parent.appendingPathComponent("projects.json")
        )
    }

    func makeProject(
        id: String,
        path: String,
        name: String,
        order: Int,
        timestamp: Date
    ) -> ProjectCatalogRecord {
        ProjectCatalogRecord(
            id: ProjectID(id),
            folderPath: path,
            displayName: name,
            order: order,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    func makeConversation(
        id: String,
        project: ConversationProject?
    ) -> ConversationCatalogRecord {
        ConversationCatalogRecord(
            id: ConversationID(id),
            binding: ProviderConversationBinding(
                connectionID: .codexDefault,
                opaqueRemoteThreadID: "remote-\(id)"
            ),
            title: id,
            project: project,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
