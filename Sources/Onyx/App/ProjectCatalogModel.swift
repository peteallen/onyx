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
    /// Stable rank supplied by the provider task-list merge. Metadata reads
    /// can change titles and other row content without turning navigation into
    /// a fresh sort. Lifecycle list updates still produce a new rank.
    let presentationOrder: Int?

    init(
        providerConnectionID: ProviderConnectionID,
        providerDisplayName: String,
        thread: RuntimeThread,
        presentationOrder: Int? = nil
    ) {
        self.providerConnectionID = providerConnectionID
        self.providerDisplayName = providerDisplayName
        self.thread = thread
        self.presentationOrder = presentationOrder
    }

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

/// The complete, immutable input to one sidebar calculation. Keeping the key
/// beside the payload makes invalidation explicit: navigation and transcript
/// changes are intentionally absent, while every source that can change the
/// rows is represented.
struct ProjectTaskSidebarProjectionRequest: Sendable {
    struct Key: Hashable, Sendable {
        let sourceRevision: UInt64
        let scopeRawValue: String
        let searchText: String
        /// The selected provider's model is the live source of truth. Its
        /// revision is separate from the app-wide cached catalog so task
        /// lifecycle changes can invalidate the background projection without
        /// first copying or comparing the complete task list on the main actor.
        let liveProviderConnectionID: ProviderConnectionID?
        let liveProviderDisplayName: String?
        let liveProviderThreadListRevision: UInt64?
    }

    let key: Key
    let taskLists: [ProjectProviderTaskList]
    let projects: [ProjectCatalogRecord]
    func grouping() -> ProjectTaskGrouping {
        let references = ProjectTaskSidebarProjection.mergedTaskReferences(
            from: taskLists,
            scope: ThreadListScope(rawValue: key.scopeRawValue) ?? .active
        )
        return ProjectTaskSidebarProjection.group(
            references,
            by: projects,
            searchText: key.searchText
        )
    }
}

/// Runs grouping away from the main actor. The serial actor also makes a
/// repeated identical request cheap without sharing mutable resolver state
/// across executors.
actor ProjectTaskSidebarProjectionWorker {
    private var cachedKey: ProjectTaskSidebarProjectionRequest.Key?
    private var cachedGrouping: ProjectTaskGrouping?

    func grouping(
        for request: ProjectTaskSidebarProjectionRequest
    ) -> ProjectTaskGrouping? {
        // A fast search can enqueue several actor calls. Skip canceled work
        // before it reaches the expensive merge/sort path so the latest query
        // never waits behind every intermediate keystroke.
        guard !Task.isCancelled else { return nil }
        if cachedKey == request.key, let cachedGrouping { return cachedGrouping }
        let grouping = request.grouping()
        guard !Task.isCancelled else { return nil }
        cachedKey = request.key
        cachedGrouping = grouping
        return grouping
    }
}

/// View-owned, one-snapshot presentation state. A new request leaves the last
/// grouping visible while the replacement is calculated, and only the newest
/// request may publish. That keeps clicks paintable even with a very large
/// task history while avoiding empty-sidebar flashes during search.
@MainActor
final class ProjectTaskSidebarProjectionModel: ObservableObject {
    private(set) var grouping = ProjectTaskGrouping(groups: [], unassigned: [])
    private(set) var isReady = false
    /// Monotonic publication token for views that need to react to a new
    /// immutable grouping without asking SwiftUI to deep-compare thousands of
    /// task rows on the main actor.
    @Published private(set) var publicationRevision: UInt64 = 0

    private let worker: ProjectTaskSidebarProjectionWorker
    private var task: Task<Void, Never>?
    private var latestKey: ProjectTaskSidebarProjectionRequest.Key?

    init(worker: ProjectTaskSidebarProjectionWorker = ProjectTaskSidebarProjectionWorker()) {
        self.worker = worker
    }

    func refresh(_ request: ProjectTaskSidebarProjectionRequest) {
        guard latestKey != request.key else { return }
        latestKey = request.key
        task?.cancel()
        task = Task { [weak self, worker] in
            guard let projected = await worker.grouping(for: request) else { return }
            guard !Task.isCancelled,
                  let self,
                  self.latestKey == request.key else { return }
            // The request key already changed, so this result is the only
            // projection that may be published for it. Avoid a synthesized
            // equality walk over every task on the main actor; with a large
            // history that comparison recreated the very interaction stall
            // this worker is meant to remove.
            self.grouping = projected
            self.isReady = true
            // Publish once, after all snapshot state has been installed. The
            // view reads the immutable grouping/isReady values during that
            // one invalidation instead of receiving three separate emissions.
            self.publicationRevision &+= 1
        }
    }

    deinit {
        task?.cancel()
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
        // Build the ancestor matcher once per projection. Calling
        // `ProjectCatalogResolver.project` for every task rebuilt and sorted
        // the complete candidate list each time, which made a simple sidebar
        // publication quadratic in the number of projects. With a large task
        // history that work ran during navigation and could beachball the UI.
        let resolver = ProjectTaskProjectResolver(projects: orderedProjects)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = tasks.filter { task in
            guard !query.isEmpty else { return true }
            return task.thread.title.localizedCaseInsensitiveContains(query)
                || task.thread.preview.localizedCaseInsensitiveContains(query)
                || (task.thread.cwd?.localizedCaseInsensitiveContains(query) ?? false)
                || task.providerDisplayName.localizedCaseInsensitiveContains(query)
                || (resolver.project(forFolderPath: task.thread.cwd)?
                    .displayName.localizedCaseInsensitiveContains(query) ?? false)
        }

        var tasksByProject: [ProjectID: [ProjectTaskReference]] = [:]
        var unassigned: [ProjectTaskReference] = []
        for task in filtered {
            if let project = resolver.project(forFolderPath: task.thread.cwd) {
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
        struct Candidate {
            var task: ProjectTaskReference
        }

        var byID: [ProjectTaskReference.ID: Candidate] = [:]
        for list in lists where list.scope.rawValue == scope.rawValue {
            for thread in list.threads where thread.id != "onyx:welcome" {
                let task = ProjectTaskReference(
                    providerConnectionID: list.providerConnectionID,
                    providerDisplayName: list.providerDisplayName,
                    thread: thread
                )
                if let existing = byID[task.id],
                   existing.task.thread.updatedAt > thread.updatedAt {
                    continue
                }
                byID[task.id] = Candidate(task: task)
            }
        }
        let ordered = byID.values.sorted { lhs, rhs in
            if lhs.task.thread.updatedAt != rhs.task.thread.updatedAt {
                return lhs.task.thread.updatedAt > rhs.task.thread.updatedAt
            }
            if lhs.task.providerConnectionID != rhs.task.providerConnectionID {
                return lhs.task.providerConnectionID.rawValue
                    < rhs.task.providerConnectionID.rawValue
            }
            return lhs.task.thread.id < rhs.task.thread.id
        }
        return ordered.enumerated().map { index, candidate in
            ProjectTaskReference(
                providerConnectionID: candidate.task.providerConnectionID,
                providerDisplayName: candidate.task.providerDisplayName,
                thread: candidate.task.thread,
                presentationOrder: index
            )
        }
    }

    private static func sorted(
        _ tasks: [ProjectTaskReference]
    ) -> [ProjectTaskReference] {
        tasks.sorted { lhs, rhs in
            if lhs.thread.isPinned != rhs.thread.isPinned {
                return lhs.thread.isPinned
            }
            if let lhsOrder = lhs.presentationOrder,
               let rhsOrder = rhs.presentationOrder,
               lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
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

/// One projection-scoped, allocation-light ancestor resolver. Project paths
/// are immutable for the duration of the sidebar calculation, so normalising
/// and sorting them once avoids repeating Foundation path work for every task.
private final class ProjectTaskProjectResolver {
    private struct Candidate {
        let project: ProjectCatalogRecord
        let components: [String]
        let depth: Int
    }

    private let candidates: [Candidate]
    private var matchedProjectsByPath: [String: ProjectCatalogRecord] = [:]
    private var unmatchedPaths: Set<String> = []

    init(projects: [ProjectCatalogRecord]) {
        candidates = projects
            .compactMap { project in
                ProjectPathNormalizer.normalize(project.folderPath).map { path in
                    let components = NSString(string: path).pathComponents
                    return Candidate(
                        project: project,
                        components: components,
                        depth: components.count
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
                if lhs.project.order != rhs.project.order {
                    return lhs.project.order < rhs.project.order
                }
                return lhs.project.id.rawValue < rhs.project.id.rawValue
            }
    }

    func project(forFolderPath rawPath: String?) -> ProjectCatalogRecord? {
        guard let rawPath else { return nil }
        if let cached = matchedProjectsByPath[rawPath] { return cached }
        if unmatchedPaths.contains(rawPath) { return nil }
        guard let path = ProjectPathNormalizer.normalize(rawPath) else {
            unmatchedPaths.insert(rawPath)
            return nil
        }
        let components = NSString(string: path).pathComponents
        let match = candidates.first { candidate in
            components.count >= candidate.components.count
                && components.prefix(candidate.components.count)
                    .elementsEqual(candidate.components)
        }?.project
        if let match {
            matchedProjectsByPath[rawPath] = match
        } else {
            unmatchedPaths.insert(rawPath)
        }
        return match
    }
}

struct ProjectProviderTaskList: Sendable {
    let providerConnectionID: ProviderConnectionID
    var providerDisplayName: String
    let scope: ThreadListScope
    var threads: [RuntimeThread]
}

/// A cached sidebar row that must survive a provider catalog refresh while
/// its direct task read is still in flight. Provider task IDs are scoped by
/// both connection and active/archived list.
struct ProjectProviderTaskProtection: Equatable, Sendable {
    let id: ProjectTaskReference.ID
    let scope: ThreadListScope
}

/// A provider task snapshot together with the completeness of the sources
/// used to produce it. The sidebar can render a partial snapshot when one
/// provider is unavailable while still reporting that the catalog is partial.
struct ProjectProviderTaskCatalog: Sendable {
    var lists: [ProjectProviderTaskList]
    let sourceComplete: Bool

    var allThreads: [RuntimeThread] {
        lists.flatMap(\.threads)
    }
}

/// Protects the shared sidebar cache from transient provider-model snapshots.
/// A navigation can invalidate an in-flight list read after the selected task
/// itself has loaded; that partial model must never replace the complete cache.
enum ProviderTaskCatalogSynchronizationPolicy {
    static func shouldReplaceCachedTasks(
        connectionState: RuntimeConnectionState,
        isLoadingThreadList: Bool,
        hasAuthoritativeThreadList: Bool,
        hasUnlistedSelectedTask: Bool = false
    ) -> Bool {
        guard case .connected = connectionState else { return false }
        return !isLoadingThreadList
            && hasAuthoritativeThreadList
            && !hasUnlistedSelectedTask
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

    /// Changes only when project/task-list inputs to the sidebar change.
    /// Transcript and composer publications can therefore reuse the last
    /// expensive grouping instead of sorting the complete task history again.
    private(set) var sidebarProjectionRevision: UInt64 = 0

    private let store: ProjectCatalogStore?
    private var didStart = false
    private var persistenceRevision: UInt64 = 0

    private struct CachedTaskReferences {
        let revision: UInt64
        let references: [ProjectTaskReference]
    }

    private var taskReferencesCache: [String: CachedTaskReferences] = [:]

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
            assignProjectsIfChanged(loaded)
        } catch {
            guard revision == persistenceRevision else { return }
            report(title: "Could not load projects", error: error, onFailure: onFailure)
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
            if revision == persistenceRevision { assignProjectsIfChanged(loaded) }
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
            if revision == persistenceRevision { assignProjectsIfChanged(loaded) }
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
            if revision == persistenceRevision { assignProjectsIfChanged(loaded) }
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
            if revision == persistenceRevision { assignProjectsIfChanged(reordered) }
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
            bumpSidebarProjectionRevision()
        } else {
            providerTaskLists.append(incoming)
            bumpSidebarProjectionRevision()
        }
    }

    /// Applies a host-level provider catalog without evicting the one cached
    /// row currently being opened directly. Once that read resolves, the live
    /// workspace snapshot replaces this list normally.
    func replaceTasks(
        from lists: [ProjectProviderTaskList],
        preserving protection: ProjectProviderTaskProtection? = nil
    ) {
        for list in lists {
            if let protection,
               protection.id.providerConnectionID == list.providerConnectionID,
               protection.scope.rawValue == list.scope.rawValue,
               !list.threads.contains(where: { $0.id == protection.id.threadID }),
               providerTaskLists.contains(where: { cached in
                   cached.providerConnectionID == list.providerConnectionID
                       && cached.scope.rawValue == list.scope.rawValue
                       && cached.threads.contains(where: { $0.id == protection.id.threadID })
               }) {
                continue
            }
            replaceTasks(
                for: list.providerConnectionID,
                providerDisplayName: list.providerDisplayName,
                scope: list.scope,
                threads: list.threads
            )
        }
    }

    func retainTaskLists(for availableProviderIDs: Set<ProviderConnectionID>) {
        let retained = providerTaskLists.filter {
            availableProviderIDs.contains($0.providerConnectionID)
        }
        guard retained.count != providerTaskLists.count else { return }
        providerTaskLists = retained
        bumpSidebarProjectionRevision()
    }

    func removeTaskList(
        for providerConnectionID: ProviderConnectionID,
        scope: ThreadListScope
    ) {
        let retained = providerTaskLists.filter {
            !($0.providerConnectionID == providerConnectionID
                && $0.scope.rawValue == scope.rawValue)
        }
        guard retained.count != providerTaskLists.count else { return }
        providerTaskLists = retained
        bumpSidebarProjectionRevision()
    }

    func taskReferences(for scope: ThreadListScope) -> [ProjectTaskReference] {
        let cacheKey = scope.rawValue
        if let cached = taskReferencesCache[cacheKey],
           cached.revision == sidebarProjectionRevision {
            return cached.references
        }
        let references = ProjectTaskSidebarProjection.mergedTaskReferences(
            from: providerTaskLists,
            scope: scope
        )
        taskReferencesCache[cacheKey] = CachedTaskReferences(
            revision: sidebarProjectionRevision,
            references: references
        )
        return references
    }

    func sidebarProjectionRequest(
        scope: ThreadListScope,
        searchText: String,
        liveProviderConnectionID: ProviderConnectionID,
        liveProviderDisplayName: String,
        liveProviderThreadListRevision: UInt64?,
        liveProviderThreads: [RuntimeThread]?
    ) -> ProjectTaskSidebarProjectionRequest {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace only the selected provider/scope snapshot. This walks the
        // handful of provider lists, not the potentially multi-thousand-row
        // task array; filtering, merging, and sorting stay on the projection
        // worker. The live model therefore wins over an older cached catalog
        // immediately after rename, pin, status, archive, or recency changes.
        var taskLists = providerTaskLists
        if liveProviderThreadListRevision != nil,
           let liveProviderThreads {
            taskLists.removeAll {
                $0.providerConnectionID == liveProviderConnectionID
                    && $0.scope.rawValue == scope.rawValue
            }
            taskLists.append(ProjectProviderTaskList(
                providerConnectionID: liveProviderConnectionID,
                providerDisplayName: liveProviderDisplayName,
                scope: scope,
                threads: liveProviderThreads
            ))
        }
        return ProjectTaskSidebarProjectionRequest(
            key: .init(
                sourceRevision: sidebarProjectionRevision,
                scopeRawValue: scope.rawValue,
                searchText: normalizedSearch,
                liveProviderConnectionID: liveProviderConnectionID,
                liveProviderDisplayName: liveProviderDisplayName,
                liveProviderThreadListRevision: liveProviderThreadListRevision
            ),
            taskLists: taskLists,
            projects: projects
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

    private func assignProjectsIfChanged(_ incoming: [ProjectCatalogRecord]) {
        guard projects != incoming else { return }
        projects = incoming
        bumpSidebarProjectionRevision()
    }

    private func bumpSidebarProjectionRevision() {
        sidebarProjectionRevision &+= 1
        taskReferencesCache.removeAll(keepingCapacity: true)
    }
}
