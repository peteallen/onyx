import AppKit
import Combine
import Foundation

struct ProjectTaskReference: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let providerConnectionID: ProviderConnectionID
        let threadID: String
    }

    let providerConnectionID: ProviderConnectionID
    let providerDisplayName: String
    var thread: RuntimeThread

    var id: ID {
        ID(providerConnectionID: providerConnectionID, threadID: thread.id)
    }
}

struct ProjectTaskGroup: Identifiable, Hashable, Sendable {
    let project: ProjectCatalogRecord
    var tasks: [ProjectTaskReference]

    var id: ProjectID { project.id }
}

struct ProjectTaskGrouping: Hashable, Sendable {
    var groups: [ProjectTaskGroup]
    var unassigned: [ProjectTaskReference]

    var taskCount: Int {
        groups.reduce(unassigned.count) { $0 + $1.tasks.count }
    }
}

/// Pure projection used by the sidebar. Provider thread IDs are only unique
/// inside a connection, so every task retains its connection identity while
/// projects remain provider-neutral and resolve from the task working folder.
enum ProjectTaskSidebarProjection {
    static func group(
        _ tasks: [ProjectTaskReference],
        by projects: [ProjectCatalogRecord],
        searchText: String = ""
    ) -> ProjectTaskGrouping {
        let orderedProjects = projects.sorted(by: ProjectCatalogOrdering.areInIncreasingOrder)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = tasks.filter { task in
            guard !query.isEmpty else { return true }
            return task.thread.title.localizedCaseInsensitiveContains(query)
                || task.thread.preview.localizedCaseInsensitiveContains(query)
                || (task.thread.cwd?.localizedCaseInsensitiveContains(query) ?? false)
                || task.providerDisplayName.localizedCaseInsensitiveContains(query)
                || (ProjectCatalogResolver.project(
                    forFolderPath: task.thread.cwd,
                    in: orderedProjects
                )?.displayName.localizedCaseInsensitiveContains(query) ?? false)
        }

        var tasksByProject: [ProjectID: [ProjectTaskReference]] = [:]
        var unassigned: [ProjectTaskReference] = []
        for task in filtered {
            if let project = ProjectCatalogResolver.project(
                forFolderPath: task.thread.cwd,
                in: orderedProjects
            ) {
                tasksByProject[project.id, default: []].append(task)
            } else {
                unassigned.append(task)
            }
        }

        let groups = orderedProjects.compactMap { project -> ProjectTaskGroup? in
            let tasks = sorted(tasksByProject[project.id] ?? [])
            guard query.isEmpty || !tasks.isEmpty else { return nil }
            return ProjectTaskGroup(project: project, tasks: tasks)
        }
        return ProjectTaskGrouping(
            groups: groups,
            unassigned: sorted(unassigned)
        )
    }

    static func mergedTaskReferences(
        from lists: [ProjectProviderTaskList],
        scope: ThreadListScope
    ) -> [ProjectTaskReference] {
        var byID: [ProjectTaskReference.ID: ProjectTaskReference] = [:]
        for list in lists where list.scope.rawValue == scope.rawValue {
            for thread in list.threads where thread.id != "onyx:welcome" {
                let task = ProjectTaskReference(
                    providerConnectionID: list.providerConnectionID,
                    providerDisplayName: list.providerDisplayName,
                    thread: thread
                )
                if let existing = byID[task.id], existing.thread.updatedAt > thread.updatedAt {
                    continue
                }
                byID[task.id] = task
            }
        }
        return Array(byID.values)
    }

    private static func sorted(
        _ tasks: [ProjectTaskReference]
    ) -> [ProjectTaskReference] {
        tasks.sorted { lhs, rhs in
            if lhs.thread.isPinned != rhs.thread.isPinned {
                return lhs.thread.isPinned
            }
            if lhs.thread.updatedAt != rhs.thread.updatedAt {
                return lhs.thread.updatedAt > rhs.thread.updatedAt
            }
            let titleOrder = lhs.thread.title.localizedStandardCompare(rhs.thread.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            if lhs.providerDisplayName != rhs.providerDisplayName {
                return lhs.providerDisplayName.localizedStandardCompare(rhs.providerDisplayName)
                    == .orderedAscending
            }
            return lhs.id.threadID < rhs.id.threadID
        }
    }
}

struct ProjectProviderTaskList: Sendable {
    let providerConnectionID: ProviderConnectionID
    var providerDisplayName: String
    let scope: ThreadListScope
    var threads: [RuntimeThread]
}

/// A provider task snapshot together with the completeness of the sources
/// used to produce it.  The sidebar can render a partial snapshot when one
/// provider is unavailable, but legacy project migration must only consume a
/// snapshot after every provider/scope source has loaded successfully.
struct ProjectProviderTaskCatalog: Sendable {
    var lists: [ProjectProviderTaskList]
    let sourceComplete: Bool

    var allThreads: [RuntimeThread] {
        lists.flatMap(\.threads)
    }
}

struct ProjectCatalogNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
}

typealias ProjectCatalogFailureHandler = @MainActor (ProjectCatalogNotice) -> Void

enum ProjectCatalogLocation {
    static func applicationSupportFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Onyx", isDirectory: true)
            .appendingPathComponent("projects.json", isDirectory: false)
    }
}

/// App-lifetime project state shared by every window and provider. The durable
/// store owns only metadata; this model never reads, writes, moves, or deletes
/// anything inside a project folder.
@MainActor
final class ProjectCatalogModel: ObservableObject {
    @Published private(set) var projects: [ProjectCatalogRecord] = []
    @Published private(set) var providerTaskLists: [ProjectProviderTaskList] = []
    @Published private(set) var isLoading = false
    @Published var notice: ProjectCatalogNotice?

    private let store: ProjectCatalogStore?
    private var didStart = false
    private var persistenceRevision: UInt64 = 0

    init(store: ProjectCatalogStore? = nil) {
        self.store = store
    }

    func start(onFailure: ProjectCatalogFailureHandler? = nil) {
        guard !didStart else { return }
        didStart = true
        Task { [weak self] in
            await self?.reload(onFailure: onFailure)
        }
    }

    func chooseAndImportProject(
        window: NSWindow?,
        initialFolderPath: String?,
        onFailure: ProjectCatalogFailureHandler? = nil,
        onImported: @escaping @MainActor (ProjectCatalogRecord) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Add a project to Onyx"
        panel.prompt = "Add Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let initialFolderPath {
            panel.directoryURL = URL(fileURLWithPath: initialFolderPath)
        }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folderPath = panel.url?.path else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let imported = await self.importProject(
                          folderPath: folderPath,
                          onFailure: onFailure
                      )
                else { return }
                onImported(imported)
            }
        }
    }

    func reload(onFailure: ProjectCatalogFailureHandler? = nil) async {
        guard let store else { return }
        let revision = persistenceRevision
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await store.projects()
            guard revision == persistenceRevision else { return }
            projects = loaded
        } catch {
            guard revision == persistenceRevision else { return }
            report(title: "Could not load projects", error: error, onFailure: onFailure)
        }
    }

    /// Imports the project paths carried by the complete provider task
    /// snapshot exactly once.  A failed or partial source is deliberately a
    /// no-op: persisting the migration marker in that case would make a later
    /// successful launch unable to discover the missing projects.  The store
    /// itself persists the marker atomically, so a user-removed project cannot
    /// be resurrected by a concurrent/repeated bootstrap.
    @discardableResult
    func importTaskProjectsIfSourceComplete(
        from catalog: ProjectProviderTaskCatalog,
        onFailure: ProjectCatalogFailureHandler? = nil
    ) async -> Bool {
        guard catalog.sourceComplete, let store else { return false }

        persistenceRevision &+= 1
        let revision = persistenceRevision
        do {
            _ = try await store.importTaskProjects(from: catalog.allThreads)
            let loaded = try await store.projects()
            if revision == persistenceRevision {
                projects = loaded
            }
            return true
        } catch {
            if revision == persistenceRevision {
                report(
                    title: "Could not import task projects",
                    error: error,
                    onFailure: onFailure
                )
            }
            return false
        }
    }

    @discardableResult
    func importProject(
        folderPath: String,
        onFailure: ProjectCatalogFailureHandler? = nil
    ) async -> ProjectCatalogRecord? {
        guard let store else { return nil }
        persistenceRevision &+= 1
        let revision = persistenceRevision
        do {
            let imported = try await store.importProject(folderPath: folderPath)
            let loaded = try await store.projects()
            if revision == persistenceRevision { projects = loaded }
            return imported
        } catch {
            if revision == persistenceRevision {
                report(title: "Could not add project", error: error, onFailure: onFailure)
            }
            return nil
        }
    }

    @discardableResult
    func renameProject(
        id: ProjectID,
        displayName: String,
        onFailure: ProjectCatalogFailureHandler? = nil
    ) async -> Bool {
        guard let store else { return false }
        persistenceRevision &+= 1
        let revision = persistenceRevision
        do {
            _ = try await store.rename(id: id, displayName: displayName)
            let loaded = try await store.projects()
            if revision == persistenceRevision { projects = loaded }
            return true
        } catch {
            if revision == persistenceRevision {
                report(title: "Could not rename project", error: error, onFailure: onFailure)
            }
            return false
        }
    }

    @discardableResult
    func removeProject(
        id: ProjectID,
        onFailure: ProjectCatalogFailureHandler? = nil
    ) async -> Bool {
        guard let store else { return false }
        persistenceRevision &+= 1
        let revision = persistenceRevision
        do {
            _ = try await store.removeFromOnyx(id: id)
            let loaded = try await store.projects()
            if revision == persistenceRevision { projects = loaded }
            return true
        } catch {
            if revision == persistenceRevision {
                report(title: "Could not remove project", error: error, onFailure: onFailure)
            }
            return false
        }
    }

    @discardableResult
    func moveProject(
        id: ProjectID,
        offset: Int,
        onFailure: ProjectCatalogFailureHandler? = nil
    ) async -> Bool {
        guard let store,
              let source = projects.firstIndex(where: { $0.id == id })
        else { return false }
        let destination = source + offset
        guard projects.indices.contains(destination) else { return false }

        persistenceRevision &+= 1
        let revision = persistenceRevision
        var orderedIDs = projects.map(\.id)
        let moved = orderedIDs.remove(at: source)
        orderedIDs.insert(moved, at: destination)
        do {
            let reordered = try await store.reorder(orderedIDs)
            if revision == persistenceRevision { projects = reordered }
            return true
        } catch {
            if revision == persistenceRevision {
                await reload(onFailure: onFailure)
                report(title: "Could not reorder projects", error: error, onFailure: onFailure)
            }
            return false
        }
    }

    func canMoveProject(id: ProjectID, offset: Int) -> Bool {
        guard let source = projects.firstIndex(where: { $0.id == id }) else { return false }
        return projects.indices.contains(source + offset)
    }

    func replaceTasks(
        for providerConnectionID: ProviderConnectionID,
        providerDisplayName: String,
        scope: ThreadListScope,
        threads: [RuntimeThread]
    ) {
        let incoming = ProjectProviderTaskList(
            providerConnectionID: providerConnectionID,
            providerDisplayName: providerDisplayName,
            scope: scope,
            threads: threads.filter { $0.id != "onyx:welcome" }
        )
        if let index = providerTaskLists.firstIndex(where: {
            $0.providerConnectionID == providerConnectionID && $0.scope.rawValue == scope.rawValue
        }) {
            let existing = providerTaskLists[index]
            guard existing.providerDisplayName != incoming.providerDisplayName
                || existing.threads != incoming.threads
            else { return }
            providerTaskLists[index] = incoming
        } else {
            providerTaskLists.append(incoming)
        }
    }

    func retainTaskLists(for availableProviderIDs: Set<ProviderConnectionID>) {
        providerTaskLists.removeAll {
            !availableProviderIDs.contains($0.providerConnectionID)
        }
    }

    func removeTaskList(
        for providerConnectionID: ProviderConnectionID,
        scope: ThreadListScope
    ) {
        providerTaskLists.removeAll {
            $0.providerConnectionID == providerConnectionID
                && $0.scope.rawValue == scope.rawValue
        }
    }

    func taskReferences(for scope: ThreadListScope) -> [ProjectTaskReference] {
        ProjectTaskSidebarProjection.mergedTaskReferences(
            from: providerTaskLists,
            scope: scope
        )
    }

    func dismissNotice() {
        notice = nil
    }

    private func report(
        title: String,
        error: any Error,
        onFailure: ProjectCatalogFailureHandler?
    ) {
        let reported = ProjectCatalogNotice(title: title, detail: error.localizedDescription)
        if let onFailure {
            onFailure(reported)
        } else {
            notice = reported
        }
    }
}
