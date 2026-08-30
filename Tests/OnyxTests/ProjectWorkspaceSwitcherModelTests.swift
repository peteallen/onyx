import Foundation
import XCTest
@testable import Onyx

final class ProjectWorkspaceSwitcherModelTests: XCTestCase {
    func testDefaultProjectionPrioritizesCurrentContextFavoritesRecentsAndActiveTasks() throws {
        let onyx = project(id: "onyx", path: "/work/onyx", name: "Onyx", order: 0)
        let server = project(id: "server", path: "/work/server", name: "Server", order: 1)
        let docs = project(id: "docs", path: "/work/docs", name: "Docs", order: 2)
        let selected = reference(thread(
            id: "selected",
            title: "Selected task",
            cwd: "/work/onyx.worktrees/keyboard",
            updatedAt: 500,
            branch: "codex/keyboard-switcher"
        ))
        let serverTask = reference(thread(
            id: "server-task",
            title: "Fix API",
            cwd: "/work/server",
            updatedAt: 400
        ))
        let archived = reference(thread(
            id: "archived",
            title: "Old docs task",
            cwd: "/work/docs",
            updatedAt: 1
        ))
        let state = ProjectWorkspaceSwitcherStateSnapshot(
            favoriteProjectIDs: [docs.id],
            recentProjects: [
                .init(projectID: server.id, openedAt: Date(timeIntervalSince1970: 900)),
            ]
        )

        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [onyx, server, docs],
            activeTasks: [selected, serverTask],
            archivedTasks: [archived],
            selectedProjectID: onyx.id,
            selectedTaskID: selected.id,
            state: state
        ))

        XCTAssertEqual(Array(projection.rows.prefix(5).map(\.id)), [
            .newTask(onyx.id),
            .task(selected.id, scopeRawValue: ThreadListScope.active.rawValue),
            .project(onyx.id),
            .project(docs.id),
            .project(server.id),
        ])
        XCTAssertEqual(
            projection.initialSelectionID,
            .task(selected.id, scopeRawValue: ThreadListScope.active.rawValue),
            "Return should reopen the current task rather than create a new one by default."
        )
        XCTAssertFalse(
            projection.rows.contains { $0.id == .task(
                archived.id,
                scopeRawValue: ThreadListScope.archived.rawValue
            ) },
            "Archived history should be searchable without cluttering the default switcher."
        )
        let newTask = try XCTUnwrap(projection.rows.first)
        XCTAssertEqual(
            newTask.destination,
            .newTask(projectID: onyx.id, workspacePath: "/work/onyx.worktrees/keyboard"),
            "The current-context action should preserve the exact selected worktree."
        )
        XCTAssertEqual(newTask.context?.branch, "codex/keyboard-switcher")
    }

    func testRawProviderTaskListsAreMergedByTheProjectionWithoutChangingResults() {
        let project = project(id: "project", path: "/work/project", name: "Project", order: 0)
        let active = reference(thread(
            id: "active",
            title: "Active",
            cwd: project.folderPath,
            updatedAt: 20
        ))
        let archived = reference(thread(
            id: "archived",
            title: "Archived",
            cwd: project.folderPath,
            updatedAt: 10
        ))
        let lists = [
            ProjectProviderTaskList(
                providerConnectionID: .codexDefault,
                providerDisplayName: "Codex",
                scope: .active,
                threads: [active.thread]
            ),
            ProjectProviderTaskList(
                providerConnectionID: .codexDefault,
                providerDisplayName: "Codex",
                scope: .archived,
                threads: [archived.thread]
            ),
        ]

        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [],
            archivedTasks: [],
            taskLists: lists
        ))

        XCTAssertTrue(projection.rows.contains { $0.task?.id == active.id })
        XCTAssertFalse(
            projection.rows.contains { $0.task?.id == archived.id },
            "Archived rows stay out of the empty-query projection while remaining searchable."
        )
        let searched = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [],
            archivedTasks: [],
            query: "Archived",
            taskLists: lists
        ))
        XCTAssertTrue(searched.rows.contains { $0.task?.id == archived.id })
    }

    func testProjectionWorkerMergesProviderListsOnlyOncePerCatalogRevision() async throws {
        let project = project(id: "project", path: "/work/project", name: "Project", order: 0)
        let active = thread(
            id: "active",
            title: "Active",
            cwd: project.folderPath,
            updatedAt: 20
        )
        let archived = thread(
            id: "archived",
            title: "Archived",
            cwd: project.folderPath,
            updatedAt: 10
        )
        let lists = [
            ProjectProviderTaskList(
                providerConnectionID: .codexDefault,
                providerDisplayName: "Codex",
                scope: .active,
                threads: [active]
            ),
            ProjectProviderTaskList(
                providerConnectionID: .codexDefault,
                providerDisplayName: "Codex",
                scope: .archived,
                threads: [archived]
            ),
        ]
        let worker = ProjectWorkspaceSwitcherProjectionWorker()
        var request = ProjectWorkspaceSwitcherRequest(
            projects: [project],
            activeTasks: [],
            archivedTasks: [],
            taskLists: lists,
            taskListRevision: 41
        )

        let initialResult = await worker.make(request)
        let initial = try XCTUnwrap(initialResult)
        request.query = "Archived"
        let searchedResult = await worker.make(request)
        let searched = try XCTUnwrap(searchedResult)
        let mergeCountAfterQuery = await worker.taskListMergeCount

        XCTAssertTrue(initial.rows.contains { $0.task?.thread.id == active.id })
        XCTAssertTrue(searched.rows.contains { $0.task?.thread.id == archived.id })
        XCTAssertEqual(
            mergeCountAfterQuery,
            1,
            "Typing should rerank the prepared task references without merging every provider list again."
        )

        request.taskListRevision = 42
        _ = await worker.make(request)
        let mergeCountAfterSourceChange = await worker.taskListMergeCount
        XCTAssertEqual(mergeCountAfterSourceChange, 2)
    }

    func testQuerySearchesProviderBranchCheckoutAndArchivedTasks() throws {
        let app = project(id: "app", path: "/work/app", name: "Mobile App", order: 0)
        let active = reference(
            thread(
                id: "active",
                title: "Polish navigation",
                cwd: "/work/app/worktrees/keyboard-flow",
                updatedAt: 100,
                branch: "codex/workspace-switcher"
            ),
            providerID: ProviderConnectionID("vllm"),
            providerName: "Local Qwen"
        )
        let archived = reference(thread(
            id: "archived",
            title: "Retired navigation spike",
            cwd: "/work/app/worktrees/old-flow",
            updatedAt: 90,
            branch: "archive/navigation"
        ))

        let byBranch = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [app],
            activeTasks: [active],
            archivedTasks: [archived],
            query: "workspace switcher"
        ))
        let activeRow = try XCTUnwrap(byBranch.rows.first(where: { $0.task?.id == active.id }))
        XCTAssertEqual(activeRow.context?.branch, "codex/workspace-switcher")
        XCTAssertEqual(activeRow.context?.relativeWorkingDirectory, "worktrees/keyboard-flow")
        XCTAssertEqual(
            activeRow.subtitle,
            "Mobile App · codex/workspace-switcher · worktrees/keyboard-flow · Local Qwen"
        )
        let workspaceAction = try XCTUnwrap(
            byBranch.rows.first(where: {
                if case let .newTaskAtPath(_, workspacePath) = $0.id {
                    return workspacePath == "/work/app/worktrees/keyboard-flow"
                }
                return false
            })
        )
        XCTAssertEqual(
            workspaceAction.destination,
            .newTask(
                projectID: app.id,
                workspacePath: "/work/app/worktrees/keyboard-flow"
            )
        )

        let byArchivedCheckout = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [app],
            activeTasks: [active],
            archivedTasks: [archived],
            query: "old flow"
        ))
        let workspaceRow = try XCTUnwrap(byArchivedCheckout.rows.first)
        XCTAssertEqual(
            workspaceRow.destination,
            .newTask(projectID: app.id, workspacePath: "/work/app/worktrees/old-flow"),
            "A worktree search should offer a blank task at that exact checkout."
        )
        let archivedRow = try XCTUnwrap(
            byArchivedCheckout.rows.first(where: { $0.task?.id == archived.id })
        )
        XCTAssertEqual(archivedRow.task?.id, archived.id)
        XCTAssertTrue(archivedRow.isArchived)
        XCTAssertEqual(
            archivedRow.destination,
            .openTask(
                providerConnectionID: .codexDefault,
                threadID: archived.thread.id,
                scopeRawValue: ThreadListScope.archived.rawValue
            )
        )
    }

    func testFuzzyQueryRanksExactProjectAndTaskMatchesDeterministically() {
        let onyx = project(id: "onyx", path: "/work/onyx", name: "Onyx", order: 0)
        let exact = reference(thread(
            id: "exact",
            title: "Release pipeline",
            cwd: "/work/onyx",
            updatedAt: 10
        ))
        let fuzzy = reference(thread(
            id: "fuzzy",
            title: "Repair publishing flow",
            cwd: "/work/onyx",
            updatedAt: 20
        ))

        let exactProjection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [onyx],
            activeTasks: [fuzzy, exact],
            query: "release pipeline"
        ))
        XCTAssertEqual(exactProjection.rows.first?.task?.id, exact.id)

        let fuzzyProjection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [onyx],
            activeTasks: [fuzzy, exact],
            query: "rpr pbl flow"
        ))
        XCTAssertEqual(fuzzyProjection.rows.first?.task?.id, fuzzy.id)
    }

    func testKeyboardSelectionWrapsAndRecoversFromMissingSelection() throws {
        let project = project(id: "project", path: "/work/project", name: "Project", order: 0)
        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [],
            selectedProjectID: project.id
        ))
        let first = try XCTUnwrap(projection.rows.first?.id)
        let last = try XCTUnwrap(projection.rows.last?.id)

        XCTAssertEqual(
            projection.movingSelection(from: nil, direction: .next),
            first
        )
        XCTAssertEqual(
            projection.movingSelection(from: nil, direction: .previous),
            last
        )
        XCTAssertEqual(
            projection.movingSelection(from: last, direction: .next),
            first
        )
        XCTAssertEqual(
            projection.movingSelection(from: first, direction: .previous),
            last
        )
    }

    @MainActor
    func testAStalePublishedRowCannotActivateAfterAReplacementGeneration() async throws {
        let project = project(id: "project", path: "/work/project", name: "Project", order: 0)
        let worker = SwitcherGenerationWorker()
        let model = ProjectWorkspaceSwitcherProjectionModel(worker: worker)
        let firstRequest = ProjectWorkspaceSwitcherRequest(
            projects: [project],
            activeTasks: [reference(thread(
                id: "task",
                title: "Task",
                cwd: "/work/project/first",
                updatedAt: 1
            ))],
            selectedProjectID: project.id,
            selectedWorkspacePath: "/work/project/first",
            selectedTaskID: ProjectTaskReference.ID(
                providerConnectionID: .codexDefault,
                threadID: "task"
            )
        )
        model.refresh(firstRequest)
        await waitUntil("The first switcher generation did not publish") {
            !model.isRefreshing && !model.projection.rows.isEmpty
        }
        let staleRow = try XCTUnwrap(model.projection.rows.first(where: {
            if case .newTask(_, _) = $0.destination { return true }
            return false
        }))
        let staleGeneration = model.publishedGeneration

        let secondRequest = ProjectWorkspaceSwitcherRequest(
            projects: [project],
            activeTasks: [],
            selectedProjectID: project.id,
            selectedWorkspacePath: "/work/project/second"
        )
        model.refresh(secondRequest)

        XCTAssertFalse(model.canActivate(staleRow, generation: staleGeneration))
        await waitUntil("The replacement switcher generation did not publish") {
            !model.isRefreshing && model.publishedGeneration == model.requestedGeneration
        }
        let currentRow = try XCTUnwrap(model.projection.rows.first(where: {
            if case let .newTask(_, workspacePath) = $0.destination {
                return workspacePath == "/work/project/second"
            }
            return false
        }))
        XCTAssertFalse(
            model.canActivate(staleRow, generation: staleGeneration),
            "A queued click from the prior generation must remain fenced after replacement."
        )
        XCTAssertTrue(model.canActivate(currentRow, generation: model.publishedGeneration))
    }

    func testInitialSelectionKeepsExactCurrentNewTaskWorkspace() throws {
        let project = project(id: "project", path: "/work/project", name: "Project", order: 0)
        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [],
            selectedProjectID: project.id,
            selectedWorkspacePath: "/work/project/worktrees/feature"
        ))

        XCTAssertEqual(
            projection.initialSelectionID,
            .newTask(project.id),
            "A blank task should reopen its current workspace rather than jump to the project root row."
        )
        XCTAssertEqual(
            projection.rows.first?.destination,
            .newTask(
                projectID: project.id,
                workspacePath: "/work/project/worktrees/feature"
            )
        )
    }

    func testRootCheckoutDoesNotRepeatTheProjectNameAndZeroLimitIsHonored() {
        let project = project(id: "app", path: "/work/app", name: "Mobile App", order: 0)
        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [],
            selectedProjectID: project.id,
            resultLimit: 0
        ))
        XCTAssertTrue(projection.rows.isEmpty)

        let normal = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [],
            selectedProjectID: project.id
        ))
        XCTAssertEqual(normal.rows.first?.subtitle, "Mobile App")
    }

    func testDefaultResultCapReservesTheTrailingAddProjectAction() {
        let projects = (0..<100).map { index in
            project(
                id: "project-\(index)",
                path: "/work/project-\(index)",
                name: "Project \(index)",
                order: index
            )
        }
        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: projects,
            activeTasks: [],
            resultLimit: 12
        ))

        XCTAssertEqual(projection.rows.count, 12)
        XCTAssertEqual(projection.rows.last?.id, .addProject)
    }

    func testActiveTaskKeepsSharedWorktreeActionVisibleOverArchivedHistory() {
        let project = project(id: "app", path: "/work/app", name: "App", order: 0)
        let path = "/work/app/worktrees/shared"
        let active = reference(thread(
            id: "active",
            title: "Active",
            cwd: path,
            updatedAt: 10
        ))
        let archived = reference(thread(
            id: "archived",
            title: "Archived",
            cwd: path,
            updatedAt: 900
        ))

        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [active],
            archivedTasks: [archived]
        ))
        let workspaceActions = projection.rows.filter { row in
            if case let .newTaskAtPath(_, workspacePath) = row.id {
                return workspacePath == path
            }
            return false
        }
        XCTAssertEqual(workspaceActions.count, 1)
        XCTAssertEqual(workspaceActions.first?.context?.branch, nil)
    }

    func testCurrentArchivedTaskRemainsTheSafeReturnSelection() {
        let project = project(id: "app", path: "/work/app", name: "App", order: 0)
        let archived = reference(thread(
            id: "archived-current",
            title: "Archived task under review",
            cwd: "/work/app",
            updatedAt: 100
        ))

        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [],
            archivedTasks: [archived],
            selectedProjectID: project.id,
            selectedWorkspacePath: "/work/app",
            selectedTaskID: archived.id
        ))
        let archivedID = ProjectWorkspaceSwitcherRow.ID.task(
            archived.id,
            scopeRawValue: ThreadListScope.archived.rawValue
        )

        XCTAssertTrue(projection.rows.contains { $0.id == archivedID })
        XCTAssertEqual(
            projection.initialSelectionID,
            archivedID,
            "Return should keep the archived task open instead of starting a new task."
        )
    }

    func testSiblingWorktreeContextRemainsVisibleWhenItIsOutsideProjectRoot() throws {
        let project = project(id: "app", path: "/work/app", name: "App", order: 0)
        let task = reference(thread(
            id: "sibling",
            title: "Sibling worktree",
            cwd: "/work/app.worktrees/feature",
            updatedAt: 10,
            branch: "feature"
        ))

        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [project],
            activeTasks: [task],
            selectedProjectID: project.id,
            selectedTaskID: task.id
        ))
        let row = try XCTUnwrap(projection.rows.first(where: { $0.task?.id == task.id }))
        XCTAssertEqual(row.subtitle, "App · feature · Codex")

        let pathAction = try XCTUnwrap(projection.rows.first(where: { row in
            if case let .newTask(_, workspacePath) = row.destination {
                return workspacePath == task.thread.cwd
            }
            return false
        }))
        XCTAssertEqual(
            pathAction.destination,
            .newTask(projectID: project.id, workspacePath: task.thread.cwd)
        )
    }

    func testUnassignedWorktreeIsSearchableWithAnExactFolderNewTask() throws {
        let task = reference(thread(
            id: "unassigned",
            title: "Review feature worktree",
            cwd: "/work/unknown.worktrees/feature",
            updatedAt: 10
        ))
        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [],
            activeTasks: [task],
            query: "unknown.worktrees"
        ))

        let action = try XCTUnwrap(projection.rows.first(where: { row in
            if case let .newTaskAtPath(projectID, workspacePath) = row.id {
                return projectID == nil && workspacePath == task.thread.cwd
            }
            return false
        }))
        XCTAssertEqual(
            action.destination,
            .newTask(projectID: nil, workspacePath: task.thread.cwd)
        )
        XCTAssertNil(
            action.context?.providerDisplayName,
            "A blank workspace action uses the window's current provider, not the provider that happened to reveal the folder."
        )
    }

    func testUnimportedWelcomeWorkspaceGetsAnExactCurrentAction() throws {
        let path = "/work/unimported"
        let projection = ProjectWorkspaceSwitcherProjection.make(.init(
            projects: [],
            activeTasks: [],
            selectedWorkspacePath: path
        ))

        let row = try XCTUnwrap(projection.rows.first)
        XCTAssertEqual(
            row.id,
            .newTaskAtPath(projectID: nil, workspacePath: path)
        )
        XCTAssertEqual(
            projection.initialSelectionID,
            row.id
        )
        XCTAssertEqual(
            row.destination,
            .newTask(projectID: nil, workspacePath: path)
        )
    }

    @MainActor
    func testFavoriteAndRecentStatePersistsSeparatelyFromProjectCatalog() throws {
        let suiteName = "ProjectWorkspaceSwitcherModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "switcher-state"
        let first = ProjectID("first")
        let second = ProjectID("second")

        let state = ProjectWorkspaceSwitcherStateModel(
            defaults: defaults,
            preferenceKey: key
        )
        state.toggleFavorite(first)
        state.recordOpened(first, at: Date(timeIntervalSince1970: 100))
        state.recordOpened(second, at: Date(timeIntervalSince1970: 200))
        state.recordOpened(first, at: Date(timeIntervalSince1970: 300))

        let reopened = ProjectWorkspaceSwitcherStateModel(
            defaults: defaults,
            preferenceKey: key
        )
        XCTAssertEqual(reopened.snapshot.favoriteProjectIDs, [first])
        XCTAssertEqual(reopened.snapshot.recentProjects.map(\.projectID), [first, second])
        XCTAssertEqual(
            reopened.snapshot.lastOpenedAt(for: first),
            Date(timeIntervalSince1970: 300)
        )

        reopened.retainProjects([])
        XCTAssertEqual(
            reopened.snapshot.favoriteProjectIDs,
            [first],
            "A transient empty catalog while loading must not erase presentation state."
        )
        reopened.retainProjects([second])
        XCTAssertTrue(reopened.snapshot.favoriteProjectIDs.isEmpty)
        XCTAssertEqual(reopened.snapshot.recentProjects.map(\.projectID), [second])
    }
}

private extension ProjectWorkspaceSwitcherModelTests {
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
        updatedAt: TimeInterval,
        branch: String? = nil
    ) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: title,
            preview: "Preview for \(title)",
            cwd: cwd,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: nil,
            branch: branch
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

    @MainActor
    func waitUntil(
        _ message: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), message)
    }
}

private actor SwitcherGenerationWorker: ProjectWorkspaceSwitcherProjectionProviding {
    func make(
        _ request: ProjectWorkspaceSwitcherRequest
    ) async -> ProjectWorkspaceSwitcherProjection? {
        await Task.yield()
        return ProjectWorkspaceSwitcherProjection.make(request)
    }
}
