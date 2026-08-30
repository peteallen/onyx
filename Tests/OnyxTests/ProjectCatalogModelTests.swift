import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ProjectCatalogModelTests: XCTestCase {
    func testCatalogSynchronizationRequiresACompleteConnectedSnapshot() {
        XCTAssertTrue(
            ProviderTaskCatalogSynchronizationPolicy.shouldReplaceCachedTasks(
                connectionState: .connected("Provider"),
                isLoadingThreadList: false,
                hasAuthoritativeThreadList: true
            )
        )
        XCTAssertFalse(
            ProviderTaskCatalogSynchronizationPolicy.shouldReplaceCachedTasks(
                connectionState: .connected("Provider"),
                isLoadingThreadList: false,
                hasAuthoritativeThreadList: false
            )
        )
        XCTAssertFalse(
            ProviderTaskCatalogSynchronizationPolicy.shouldReplaceCachedTasks(
                connectionState: .connected("Provider"),
                isLoadingThreadList: true,
                hasAuthoritativeThreadList: true
            )
        )
        XCTAssertFalse(
            ProviderTaskCatalogSynchronizationPolicy.shouldReplaceCachedTasks(
                connectionState: .disconnected,
                isLoadingThreadList: false,
                hasAuthoritativeThreadList: true
            )
        )
        XCTAssertFalse(
            ProviderTaskCatalogSynchronizationPolicy.shouldReplaceCachedTasks(
                connectionState: .connected("Provider"),
                isLoadingThreadList: false,
                hasAuthoritativeThreadList: true,
                hasUnlistedSelectedTask: true
            ),
            "An incomplete live page must not evict the selected cached task."
        )
    }

    func testProjectPickerCancellationCallbackRunsWhenNoWindowIsAvailable() {
        let model = ProjectCatalogModel()
        var cancellationCount = 0

        model.chooseAndImportProject(
            window: nil,
            initialFolderPath: nil,
            onCancelled: { cancellationCount += 1 },
            onImported: { _ in XCTFail("A missing window cannot import a project") }
        )

        XCTAssertEqual(
            cancellationCount,
            1,
            "A canceled/unavailable folder sheet must return focus exactly once."
        )
    }

    func testHostCatalogRefreshPreservesSelectedCachedTaskUntilDirectReadCompletes() {
        let model = ProjectCatalogModel()
        let selected = thread(id: "selected", title: "Selected cached task", cwd: "/work/onyx")
        let listed = thread(id: "listed", title: "Listed task", cwd: "/work/onyx")
        model.replaceTasks(
            for: .codexDefault,
            providerDisplayName: "Codex",
            scope: .active,
            threads: [selected, listed]
        )

        let refreshed = ProjectProviderTaskList(
            providerConnectionID: .codexDefault,
            providerDisplayName: "Codex",
            scope: .active,
            threads: [listed]
        )
        let protection = ProjectProviderTaskProtection(
            id: ProjectTaskReference.ID(
                providerConnectionID: .codexDefault,
                threadID: selected.id
            ),
            scope: .active
        )

        model.replaceTasks(from: [refreshed], preserving: protection)
        XCTAssertEqual(
            model.providerTaskLists.first?.threads.map(\.id),
            [selected.id, listed.id],
            "A host refresh must not remove the selected cached row while its direct read is pending."
        )

        model.replaceTasks(from: [refreshed])
        XCTAssertEqual(
            model.providerTaskLists.first?.threads.map(\.id),
            [listed.id],
            "Once the direct read settles, an authoritative refresh may remove an absent row."
        )
    }

    func testDefaultCatalogLivesInApplicationSupportInsteadOfAProjectFolder() {
        let fileURL = ProjectCatalogLocation.applicationSupportFileURL()

        XCTAssertTrue(fileURL.path.hasSuffix("/Library/Application Support/Onyx/projects.json"))
        XCTAssertFalse(fileURL.path.hasSuffix("/Documents/projects.json"))
    }

    func testProjectionGroupsProviderScopedTasksByProjectAndKeepsCollidingIDsDistinct() {
        let projects = [
            project(id: "alpha", path: "/work/alpha", name: "Alpha", order: 0),
            project(id: "beta", path: "/work/beta", name: "Beta", order: 1),
        ]
        let codex = ProjectProviderTaskList(
            providerConnectionID: .codexDefault,
            providerDisplayName: "Codex",
            scope: .active,
            threads: [
                thread(id: "same-remote-id", title: "Codex task", cwd: "/work/alpha"),
            ]
        )
        let localID = ProviderConnectionID("local.vllm")
        let vLLM = ProjectProviderTaskList(
            providerConnectionID: localID,
            providerDisplayName: "vLLM",
            scope: .active,
            threads: [
                thread(
                    id: "same-remote-id",
                    title: "Local task",
                    cwd: "/work/alpha/packages/client"
                ),
                thread(id: "beta-task", title: "Beta task", cwd: "/work/beta"),
            ]
        )

        let references = ProjectTaskSidebarProjection.mergedTaskReferences(
            from: [codex, vLLM],
            scope: .active
        )
        let grouping = ProjectTaskSidebarProjection.group(references, by: projects)

        XCTAssertEqual(grouping.groups.map(\.project.id), projects.map(\.id))
        XCTAssertEqual(grouping.groups[0].tasks.count, 2)
        XCTAssertEqual(
            Set(grouping.groups[0].tasks.map(\.providerConnectionID)),
            Set([.codexDefault, localID])
        )
        XCTAssertEqual(grouping.groups[1].tasks.map(\.thread.id), ["beta-task"])
        XCTAssertEqual(grouping.taskCount, 3)
    }

    func testProjectionKeepsPinnedTasksFirstInsideEachProjectThenSortsByRecency() {
        let alpha = project(id: "alpha", path: "/work/alpha", name: "Alpha", order: 0)
        let tasks = [
            reference(thread(
                id: "newest",
                title: "Newest unpinned",
                cwd: alpha.folderPath,
                updatedAt: 300
            )),
            reference(thread(
                id: "older-pinned",
                title: "Older pinned",
                cwd: alpha.folderPath,
                updatedAt: 100,
                isPinned: true
            )),
            reference(thread(
                id: "newer-pinned",
                title: "Newer pinned",
                cwd: alpha.folderPath,
                updatedAt: 200,
                isPinned: true
            )),
        ]

        let grouping = ProjectTaskSidebarProjection.group(tasks, by: [alpha])

        XCTAssertEqual(
            grouping.groups[0].tasks.map(\.thread.id),
            ["newer-pinned", "older-pinned", "newest"]
        )
    }

    func testMergedProviderSnapshotKeepsAuthoritativeRowOrderWhenMetadataTies() {
        let firstProvider = ProviderConnectionID("provider.a")
        let secondProvider = ProviderConnectionID("provider.b")
        let first = thread(id: "same-id", title: "Zulu title", cwd: nil, updatedAt: 100)
        let second = thread(id: "same-id", title: "Alpha title", cwd: nil, updatedAt: 100)
        let firstList = ProjectProviderTaskList(
            providerConnectionID: firstProvider,
            providerDisplayName: "Provider A",
            scope: .active,
            threads: [first]
        )
        let secondList = ProjectProviderTaskList(
            providerConnectionID: secondProvider,
            providerDisplayName: "Provider B",
            scope: .active,
            threads: [second]
        )

        func projectedIDs(_ lists: [ProjectProviderTaskList]) -> [String] {
            ProjectTaskSidebarProjection.group(
                ProjectTaskSidebarProjection.mergedTaskReferences(
                    from: lists,
                    scope: .active
                ),
                by: []
            ).unassigned.map { "\($0.providerConnectionID.rawValue):\($0.thread.id)" }
        }

        let initial = projectedIDs([firstList, secondList])
        // Replacing provider A's list removes it and appends the fresh live
        // snapshot after provider B. The visible order must not change merely
        // because a navigation read renamed one task.
        let afterLiveReplacement = projectedIDs([secondList, firstList])

        XCTAssertEqual(initial, afterLiveReplacement)
        XCTAssertEqual(initial, ["provider.a:same-id", "provider.b:same-id"])
    }

    func testProjectionSearchesProjectAndProviderNamesAndHidesEmptyGroups() {
        let projects = [
            project(id: "alpha", path: "/work/alpha", name: "Mobile App", order: 0),
            project(id: "beta", path: "/work/beta", name: "Server", order: 1),
        ]
        let tasks = [
            reference(
                thread(id: "local", title: "Fix layout", cwd: "/work/alpha"),
                providerID: ProviderConnectionID("local.vllm"),
                providerName: "Local Qwen"
            ),
            reference(thread(id: "server", title: "Database work", cwd: "/work/beta")),
        ]

        let byProject = ProjectTaskSidebarProjection.group(
            tasks,
            by: projects,
            searchText: "mobile"
        )
        XCTAssertEqual(byProject.groups.map(\.project.id), [ProjectID("alpha")])
        XCTAssertEqual(byProject.groups[0].tasks.map(\.thread.id), ["local"])

        let byProvider = ProjectTaskSidebarProjection.group(
            tasks,
            by: projects,
            searchText: "qwen"
        )
        XCTAssertEqual(byProvider.groups.map(\.project.id), [ProjectID("alpha")])
        XCTAssertEqual(byProvider.groups[0].tasks.map(\.thread.id), ["local"])
    }

    func testProjectionUsesMostSpecificAncestorWithoutPrefixCollisions() {
        let projects = [
            project(id: "app", path: "/work/app", name: "App", order: 0),
            project(
                id: "client",
                path: "/work/app/packages/client",
                name: "Client package",
                order: 1
            ),
            project(
                id: "application",
                path: "/work/application",
                name: "Application",
                order: 2
            ),
        ]
        let tasks = [
            reference(thread(id: "root-file", title: "Root", cwd: "/work/app/Sources")),
            reference(thread(
                id: "nested-file",
                title: "Nested",
                cwd: "/work/app/packages/client/Sources"
            )),
            reference(thread(
                id: "prefix-file",
                title: "Prefix",
                cwd: "/work/application/Sources"
            )),
            reference(thread(id: "collision", title: "Collision", cwd: "/work/appx/Sources")),
        ]

        let grouping = ProjectTaskSidebarProjection.group(tasks, by: projects)

        XCTAssertEqual(grouping.groups.map(\.project.id), [
            ProjectID("app"),
            ProjectID("client"),
            ProjectID("application"),
        ])
        XCTAssertEqual(grouping.groups[0].tasks.map(\.thread.id), ["root-file"])
        XCTAssertEqual(grouping.groups[1].tasks.map(\.thread.id), ["nested-file"])
        XCTAssertEqual(grouping.groups[2].tasks.map(\.thread.id), ["prefix-file"])
        XCTAssertEqual(grouping.unassigned.map(\.thread.id), ["collision"])
    }

    func testProjectionMatchesExactRootAndLeavesInvalidPathsUnassigned() {
        let root = project(id: "app", path: "/work/app", name: "App", order: 0)
        let tasks = [
            reference(thread(id: "exact", title: "Exact", cwd: "/work/app")),
            reference(thread(id: "relative", title: "Relative", cwd: "work/app")),
            reference(thread(id: "blank", title: "Blank", cwd: "   ")),
            reference(thread(id: "nul", title: "Nul", cwd: "/work/app\0/file")),
            reference(thread(id: "missing", title: "Missing", cwd: nil)),
        ]

        let grouping = ProjectTaskSidebarProjection.group(tasks, by: [root])

        XCTAssertEqual(grouping.groups[0].tasks.map(\.thread.id), ["exact"])
        XCTAssertEqual(
            Set(grouping.unassigned.map(\.thread.id)),
            Set(["relative", "blank", "nul", "missing"])
        )
    }

    func testProjectionDuplicateRootsKeepOrderAndIDTieBreak() {
        let projects = [
            project(id: "z-root", path: "/work/shared", name: "Z root", order: 0),
            project(id: "a-root", path: "/work/shared", name: "A root", order: 0),
        ]
        let task = reference(thread(
            id: "shared-file",
            title: "Shared",
            cwd: "/work/shared/file"
        ))

        let grouping = ProjectTaskSidebarProjection.group([task], by: projects)

        XCTAssertEqual(
            grouping.groups.map(\.project.id),
            [ProjectID("a-root"), ProjectID("z-root")]
        )
        XCTAssertEqual(grouping.groups[0].tasks.map(\.thread.id), ["shared-file"])
        XCTAssertTrue(grouping.groups[1].tasks.isEmpty)
    }

    func testLargeProjectionRemainsComfortablyInteractive() {
        // This mirrors a long-lived Codex installation: hundreds of imported
        // project roots and thousands of tasks. Projection runs away from the
        // UI thread, but a tight budget still prevents search results from
        // lagging behind the user's typing.
        // Match the real history that exposed the beachball on this machine.
        let projectCount = 224
        let taskCount = 4_824
        let projects = (0..<projectCount).map { index in
            project(
                id: "project-\(index)",
                path: "/work/project-\(index)",
                name: "Project \(index)",
                order: index
            )
        }
        let tasks = (0..<taskCount).map { index in
            let projectIndex = index % projectCount
            return reference(thread(
                id: "task-\(index)",
                title: "Task \(index)",
                // Real histories contain many tasks sharing a checkout. Keep
                // a handful of worktrees per project so the cache path is
                // exercised without manufacturing thousands of unique roots.
                cwd: "/work/project-\(projectIndex)/worktree-\((index / projectCount) % 3)",
                updatedAt: TimeInterval(index)
            ))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let grouping = ProjectTaskSidebarProjection.group(tasks, by: projects)
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(grouping.taskCount, taskCount)
        XCTAssertEqual(grouping.groups.count, projectCount)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(200),
            "A routine sidebar projection exceeded the interaction budget: \(elapsed)"
        )
    }

    func testModelMutationsPublishAndPersistProjectManagementOrder() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = ProjectCatalogStore(fileURL: location.file)
        let model = ProjectCatalogModel(store: store)

        let importedFirst = await model.importProject(folderPath: "/work/first")
        let importedSecond = await model.importProject(folderPath: "/work/second")
        let first = try XCTUnwrap(importedFirst)
        let second = try XCTUnwrap(importedSecond)
        XCTAssertEqual(model.projects.map(\.id), [first.id, second.id])

        let renamed = await model.renameProject(id: second.id, displayName: "Second Renamed")
        let moved = await model.moveProject(id: second.id, offset: -1)
        XCTAssertTrue(renamed)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.projects.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.projects[0].displayName, "Second Renamed")

        let removed = await model.removeProject(id: first.id)
        XCTAssertTrue(removed)
        XCTAssertEqual(model.projects.map(\.id), [second.id])

        let reopened = ProjectCatalogStore(fileURL: location.file)
        let persisted = try await reopened.projects()
        XCTAssertEqual(persisted.map(\.id), [second.id])
        XCTAssertEqual(persisted.map(\.displayName), ["Second Renamed"])
        XCTAssertEqual(persisted.map(\.order), [0])
    }

    func testModelCachesProviderListsIndependentlyByScopeAndReplacesFreshSnapshot() {
        let model = ProjectCatalogModel()
        let provider = ProviderConnectionID("local.vllm")
        model.replaceTasks(
            for: provider,
            providerDisplayName: "vLLM",
            scope: .active,
            threads: [thread(id: "active-old", title: "Old", cwd: "/work/alpha")]
        )
        model.replaceTasks(
            for: provider,
            providerDisplayName: "vLLM",
            scope: .archived,
            threads: [thread(id: "archived", title: "Archived", cwd: "/work/alpha")]
        )
        model.replaceTasks(
            for: provider,
            providerDisplayName: "Local Qwen",
            scope: .active,
            threads: [thread(id: "active-new", title: "New", cwd: "/work/alpha")]
        )

        XCTAssertEqual(model.taskReferences(for: .active).map(\.thread.id), ["active-new"])
        XCTAssertEqual(model.taskReferences(for: .active).map(\.providerDisplayName), ["Local Qwen"])
        XCTAssertEqual(model.taskReferences(for: .archived).map(\.thread.id), ["archived"])
    }

    func testSidebarProjectionRevisionChangesOnlyForMeaningfulTaskSourceChanges() {
        let model = ProjectCatalogModel()
        let provider = ProviderConnectionID("local.vllm")
        let first = thread(id: "task", title: "Task", cwd: "/work/alpha")

        XCTAssertEqual(model.sidebarProjectionRevision, 0)
        model.replaceTasks(
            for: provider,
            providerDisplayName: "vLLM",
            scope: .active,
            threads: [first]
        )
        let firstRevision = model.sidebarProjectionRevision
        XCTAssertGreaterThan(firstRevision, 0)

        model.replaceTasks(
            for: provider,
            providerDisplayName: "vLLM",
            scope: .active,
            threads: [first]
        )
        XCTAssertEqual(model.sidebarProjectionRevision, firstRevision)

        model.replaceTasks(
            for: provider,
            providerDisplayName: "vLLM",
            scope: .active,
            threads: [thread(id: "task-2", title: "Task 2", cwd: "/work/alpha")]
        )
        XCTAssertGreaterThan(model.sidebarProjectionRevision, firstRevision)
    }

    func testAsyncSidebarProjectionPublishesLatestRequestAndKeepsRowsOutOfBody() async {
        let alpha = project(id: "alpha", path: "/work/alpha", name: "Alpha", order: 0)
        let firstRequest = ProjectTaskSidebarProjectionRequest(
            key: .init(
                sourceRevision: 1,
                scopeRawValue: ThreadListScope.active.rawValue,
                searchText: "first",
                liveProviderConnectionID: nil,
                liveProviderDisplayName: nil,
                liveProviderThreadListRevision: nil
            ),
            taskLists: [ProjectProviderTaskList(
                providerConnectionID: .codexDefault,
                providerDisplayName: "Codex",
                scope: .active,
                threads: [thread(id: "first", title: "First", cwd: alpha.folderPath)]
            )],
            projects: [alpha]
        )
        let latestRequest = ProjectTaskSidebarProjectionRequest(
            key: .init(
                sourceRevision: 1,
                scopeRawValue: ThreadListScope.active.rawValue,
                searchText: "second",
                liveProviderConnectionID: nil,
                liveProviderDisplayName: nil,
                liveProviderThreadListRevision: nil
            ),
            taskLists: [ProjectProviderTaskList(
                providerConnectionID: .codexDefault,
                providerDisplayName: "Codex",
                scope: .active,
                threads: [thread(id: "second", title: "Second", cwd: alpha.folderPath)]
            )],
            projects: [alpha]
        )

        let projection = ProjectTaskSidebarProjectionModel()
        projection.refresh(firstRequest)
        projection.refresh(latestRequest)

        XCTAssertFalse(
            projection.isReady,
            "refresh must return before projection work runs so the main actor can paint the click"
        )

        for _ in 0..<100 where !projection.isReady {
            await Task.yield()
        }

        XCTAssertTrue(projection.isReady)
        XCTAssertEqual(projection.grouping.groups.first?.tasks.map(\.thread.id), ["second"])
    }

    func testLiveProviderSnapshotOverridesStaleCatalogWithoutMainActorReplacement() {
        let model = ProjectCatalogModel()
        let provider = ProviderConnectionID("local.vllm")
        model.replaceTasks(
            for: provider,
            providerDisplayName: "vLLM",
            scope: .active,
            threads: [thread(id: "task", title: "Old title", cwd: "/work/alpha")]
        )
        let cachedCatalogRevision = model.sidebarProjectionRevision
        var liveThread = thread(
            id: "task",
            title: "Renamed task",
            cwd: "/work/alpha",
            updatedAt: 200,
            isPinned: true
        )
        liveThread.status = .running

        let request = model.sidebarProjectionRequest(
            scope: .active,
            searchText: "",
            liveProviderConnectionID: provider,
            liveProviderDisplayName: "Local Qwen",
            liveProviderThreadListRevision: 42,
            liveProviderThreads: [liveThread]
        )
        let grouping = request.grouping()
        let projected = grouping.unassigned.first?.thread

        XCTAssertEqual(projected?.title, "Renamed task")
        XCTAssertEqual(projected?.status, .running)
        XCTAssertEqual(projected?.isPinned, true)
        XCTAssertEqual(request.key.liveProviderThreadListRevision, 42)
        XCTAssertEqual(
            model.sidebarProjectionRevision,
            cachedCatalogRevision,
            "Reading live rows must not republish or deep-compare the cached catalog on the main actor"
        )

        let nextRequest = model.sidebarProjectionRequest(
            scope: .active,
            searchText: "",
            liveProviderConnectionID: provider,
            liveProviderDisplayName: "Local Qwen",
            liveProviderThreadListRevision: 43,
            liveProviderThreads: [liveThread]
        )
        XCTAssertNotEqual(request.key, nextRequest.key)
    }

    func testStartupPreservesLegacyMarkerCatalogWithoutGuessingProjectProvenance() async throws {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = ProjectCatalogStore(fileURL: location.file)
        try writeCatalog(
            ProjectCatalogSnapshot(
                projects: [project(
                    id: "legacy-project",
                    path: "/work/legacy-project",
                    name: "legacy-project",
                    order: 0
                )],
                didBootstrapConversationProjects: true
            ),
            to: location.file
        )

        let model = ProjectCatalogModel(store: store)
        await model.reload()

        XCTAssertEqual(model.projects.map(\.folderPath), ["/work/legacy-project"])
        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.didBootstrapConversationProjects)
    }

    func testOperationFailureCanBeRoutedToInitiatingWindowWithoutSharedNotice() async {
        let location = temporaryCatalogLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let model = ProjectCatalogModel(
            store: ProjectCatalogStore(fileURL: location.file)
        )
        var windowNotice: ProjectCatalogNotice?

        let imported = await model.importProject(
            folderPath: "relative/project",
            onFailure: { windowNotice = $0 }
        )

        XCTAssertNil(imported)
        XCTAssertNil(model.notice, "A failure owned by one window must not alert every window")
        XCTAssertEqual(windowNotice?.title, "Could not add project")
        XCTAssertFalse(windowNotice?.detail.isEmpty ?? true)
    }
}

private extension ProjectCatalogModelTests {
    func project(
        id: String,
        path: String,
        name: String,
        order: Int
    ) -> ProjectCatalogRecord {
        ProjectCatalogRecord(
            id: ProjectID(id),
            folderPath: path,
            displayName: name,
            order: order,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    func thread(
        id: String,
        title: String,
        cwd: String?,
        updatedAt: TimeInterval = 100,
        isPinned: Bool = false
    ) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: title,
            preview: "Preview for \(title)",
            cwd: cwd,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle,
            isPinned: isPinned,
            runtime: .codex,
            model: nil,
            branch: nil
        )
    }

    func reference(
        _ thread: RuntimeThread,
        providerID: ProviderConnectionID = .codexDefault,
        providerName: String = "Codex"
    ) -> ProjectTaskReference {
        ProjectTaskReference(
            providerConnectionID: providerID,
            providerDisplayName: providerName,
            thread: thread
        )
    }

    func temporaryCatalogLocation() -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-project-model-tests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("projects.json"))
    }

    func writeCatalog(_ snapshot: ProjectCatalogSnapshot, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
