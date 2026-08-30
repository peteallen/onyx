import Combine
import Foundation

/// Durable, app-owned project preferences used by the workspace switcher.
///
/// This state deliberately stays separate from `ProjectCatalogRecord`. A
/// favorite or recent visit is presentation metadata, not part of the folder
/// import contract, and older project catalogs therefore need no migration.
struct ProjectWorkspaceSwitcherStateSnapshot: Codable, Equatable, Sendable {
    struct RecentProject: Codable, Equatable, Sendable {
        let projectID: ProjectID
        var openedAt: Date
    }

    static let currentSchemaVersion = 1
    static let recentLimit = 32

    let schemaVersion: Int
    var favoriteProjectIDs: [ProjectID]
    var recentProjects: [RecentProject]

    init(
        favoriteProjectIDs: [ProjectID] = [],
        recentProjects: [RecentProject] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.favoriteProjectIDs = favoriteProjectIDs
        self.recentProjects = recentProjects
        normalize()
    }

    var favoriteProjectIDSet: Set<ProjectID> {
        Set(favoriteProjectIDs)
    }

    func lastOpenedAt(for projectID: ProjectID) -> Date? {
        recentProjects.first(where: { $0.projectID == projectID })?.openedAt
    }

    mutating func normalize(recentLimit: Int = Self.recentLimit) {
        favoriteProjectIDs = Array(Set(favoriteProjectIDs)).sorted {
            $0.rawValue < $1.rawValue
        }

        var newestByProjectID: [ProjectID: Date] = [:]
        for recent in recentProjects {
            newestByProjectID[recent.projectID] = max(
                newestByProjectID[recent.projectID] ?? .distantPast,
                recent.openedAt
            )
        }
        recentProjects = newestByProjectID
            .map { RecentProject(projectID: $0.key, openedAt: $0.value) }
            .sorted {
                if $0.openedAt != $1.openedAt { return $0.openedAt > $1.openedAt }
                return $0.projectID.rawValue < $1.projectID.rawValue
            }
        let boundedLimit = max(0, recentLimit)
        if recentProjects.count > boundedLimit {
            recentProjects.removeSubrange(boundedLimit...)
        }
    }
}

/// A lightweight UserDefaults boundary for switcher-only state. Favorites and
/// recents are global across Onyx windows because the imported project catalog
/// is global as well. Malformed or newer snapshots fail closed to empty state
/// without affecting projects or task history.
@MainActor
final class ProjectWorkspaceSwitcherStateModel: ObservableObject {
    static let defaultPreferenceKey = "Onyx.projectWorkspaceSwitcherState"
    nonisolated static let recentLimit = ProjectWorkspaceSwitcherStateSnapshot.recentLimit

    @Published private(set) var snapshot: ProjectWorkspaceSwitcherStateSnapshot

    private let defaults: UserDefaults
    private let preferenceKey: String

    init(
        defaults: UserDefaults = .standard,
        preferenceKey: String = defaultPreferenceKey
    ) {
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        snapshot = Self.load(defaults: defaults, preferenceKey: preferenceKey)
    }

    func toggleFavorite(_ projectID: ProjectID) {
        var favorites = snapshot.favoriteProjectIDSet
        if !favorites.insert(projectID).inserted {
            favorites.remove(projectID)
        }
        snapshot.favoriteProjectIDs = favorites.sorted { $0.rawValue < $1.rawValue }
        persist()
    }

    func setFavorite(_ isFavorite: Bool, projectID: ProjectID) {
        var favorites = snapshot.favoriteProjectIDSet
        if isFavorite {
            favorites.insert(projectID)
        } else {
            favorites.remove(projectID)
        }
        let ordered = favorites.sorted { $0.rawValue < $1.rawValue }
        guard ordered != snapshot.favoriteProjectIDs else { return }
        snapshot.favoriteProjectIDs = ordered
        persist()
    }

    func recordOpened(_ projectID: ProjectID, at openedAt: Date = .now) {
        snapshot.recentProjects.removeAll { $0.projectID == projectID }
        snapshot.recentProjects.insert(
            .init(projectID: projectID, openedAt: openedAt),
            at: 0
        )
        snapshot.normalize()
        persist()
    }

    /// Removes stale presentation state after the catalog changes. This never
    /// mutates the catalog or any represented folder. An empty set is treated
    /// as an unhydrated catalog snapshot; this avoids erasing favorites while
    /// the project store is still loading at palette-open time.
    func retainProjects(_ projectIDs: Set<ProjectID>) {
        guard !projectIDs.isEmpty else { return }
        let favorites = snapshot.favoriteProjectIDs.filter(projectIDs.contains)
        let recents = snapshot.recentProjects.filter {
            projectIDs.contains($0.projectID)
        }
        guard favorites != snapshot.favoriteProjectIDs
            || recents != snapshot.recentProjects else { return }
        snapshot.favoriteProjectIDs = favorites
        snapshot.recentProjects = recents
        persist()
    }

    private func persist() {
        snapshot.normalize()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: preferenceKey)
    }

    private static func load(
        defaults: UserDefaults,
        preferenceKey: String
    ) -> ProjectWorkspaceSwitcherStateSnapshot {
        guard let data = defaults.data(forKey: preferenceKey),
              var decoded = try? JSONDecoder().decode(
                  ProjectWorkspaceSwitcherStateSnapshot.self,
                  from: data
              ),
              decoded.schemaVersion == ProjectWorkspaceSwitcherStateSnapshot.currentSchemaVersion
        else { return ProjectWorkspaceSwitcherStateSnapshot() }
        decoded.normalize()
        return decoded
    }
}

/// Structured checkout context lets the eventual palette render branch and
/// worktree information without parsing a preformatted subtitle.
struct ProjectWorkspaceSwitcherContext: Hashable, Sendable {
    let projectID: ProjectID?
    let projectName: String?
    let projectPath: String?
    let workingDirectory: String?
    let relativeWorkingDirectory: String?
    let branch: String?
    let providerDisplayName: String?

    var checkoutLabel: String? {
        if let relativeWorkingDirectory,
           !relativeWorkingDirectory.isEmpty,
           relativeWorkingDirectory != "." {
            return relativeWorkingDirectory
        }
        guard let workingDirectory else { return nil }
        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return name.isEmpty ? workingDirectory : name
    }

    var subtitle: String {
        var components: [String] = []
        appendDistinct(projectName, to: &components)
        appendDistinct(branch, to: &components)
        // A worktree can live beside (rather than beneath) its imported
        // project root. Keep that checkout visible in the subtitle even when
        // no relative path can be computed; for an exact project-root task,
        // the display name already provides the same context.
        let isDifferentCheckout = projectPath != nil
            && workingDirectory != nil
            && projectPath != workingDirectory
        if relativeWorkingDirectory != nil || projectName == nil || isDifferentCheckout {
            appendDistinct(checkoutLabel, to: &components)
        }
        appendDistinct(providerDisplayName, to: &components)
        return components.joined(separator: " · ")
    }

    private func appendDistinct(_ value: String?, to components: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !components.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
        else { return }
        components.append(value)
    }
}

struct ProjectWorkspaceSwitcherRequest: Sendable {
    var projects: [ProjectCatalogRecord]
    /// Raw provider snapshots are the preferred input for the live palette.
    /// Keeping lists unmerged lets the palette's first frame mount and focus
    /// before the potentially large active/archived reference merge runs on
    /// the projection worker. The reference arrays below remain as a source-
    /// compatible fallback for small/unit fixtures and older callers.
    var taskLists: [ProjectProviderTaskList]?
    /// Monotonic catalog revision for `taskLists`. The production worker uses
    /// this to merge active/archived provider snapshots once, then reuses the
    /// prepared references while each query only reranks/filter results.
    var taskListRevision: UInt64?
    var activeTasks: [ProjectTaskReference]
    var archivedTasks: [ProjectTaskReference]
    var query: String
    var selectedProjectID: ProjectID?
    /// The currently visible checkout, including a welcome/new-task draft.
    /// This is kept separate from `selectedProjectID` because a project may
    /// have several observed worktrees and a blank task has no task row whose
    /// cwd could otherwise carry that distinction.
    var selectedWorkspacePath: String?
    var selectedTaskID: ProjectTaskReference.ID?
    var state: ProjectWorkspaceSwitcherStateSnapshot
    var resultLimit: Int

    init(
        projects: [ProjectCatalogRecord],
        activeTasks: [ProjectTaskReference],
        archivedTasks: [ProjectTaskReference] = [],
        query: String = "",
        selectedProjectID: ProjectID? = nil,
        selectedWorkspacePath: String? = nil,
        selectedTaskID: ProjectTaskReference.ID? = nil,
        state: ProjectWorkspaceSwitcherStateSnapshot = .init(),
        resultLimit: Int = 80,
        taskLists: [ProjectProviderTaskList]? = nil,
        taskListRevision: UInt64? = nil
    ) {
        self.projects = projects
        self.taskLists = taskLists
        self.taskListRevision = taskListRevision
        self.activeTasks = activeTasks
        self.archivedTasks = archivedTasks
        self.query = query
        self.selectedProjectID = selectedProjectID
        self.selectedWorkspacePath = selectedWorkspacePath
        self.selectedTaskID = selectedTaskID
        self.state = state
        self.resultLimit = resultLimit
    }
}

struct ProjectWorkspaceSwitcherProjection: Equatable, Sendable {
    let rows: [ProjectWorkspaceSwitcherRow]

    var initialSelectionID: ProjectWorkspaceSwitcherRow.ID? {
        // Opening the palette should be safe for Return: when a task is
        // already open, keep that task as the keyboard selection instead of
        // defaulting to the adjacent "New task" action.
        rows.first(where: { $0.isCurrent && $0.kind == .task })?.id
            // A blank task has no task row to select. In that case preserve
            // the exact current checkout (including a worktree) rather than
            // falling through to the project root row.
            ?? rows.first(where: {
                guard $0.isCurrent, $0.kind == .action else { return false }
                if case .newTask = $0.destination { return true }
                return false
            })?.id
            ?? rows.first(where: { $0.isCurrent && $0.kind == .project })?.id
            ?? rows.first?.id
    }

    func movingSelection(
        from currentID: ProjectWorkspaceSwitcherRow.ID?,
        direction: SelectionDirection
    ) -> ProjectWorkspaceSwitcherRow.ID? {
        guard !rows.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = rows.firstIndex(where: { $0.id == currentID })
        else { return direction == .next ? rows.first?.id : rows.last?.id }
        switch direction {
        case .next:
            return rows[(currentIndex + 1) % rows.count].id
        case .previous:
            return rows[(currentIndex - 1 + rows.count) % rows.count].id
        }
    }

    enum SelectionDirection: Sendable {
        case next
        case previous
    }

    static func make(_ request: ProjectWorkspaceSwitcherRequest) -> Self {
        makeCancellable(request) ?? ProjectWorkspaceSwitcherProjection(rows: [])
    }

    /// The palette's background worker uses the cancellable form so rapid
    /// typing cannot make the newest query wait behind obsolete catalog work.
    static func makeCancellable(
        _ request: ProjectWorkspaceSwitcherRequest
    ) -> Self? {
        ProjectWorkspaceSwitcherProjector(request: request).projection()
    }
}

struct ProjectWorkspaceSwitcherRow: Identifiable, Hashable, Sendable {
    enum ID: Hashable, Sendable {
        case newTask(ProjectID?)
        case newTaskAtPath(projectID: ProjectID?, workspacePath: String)
        case project(ProjectID)
        case task(ProjectTaskReference.ID, scopeRawValue: String)
        case addProject
    }

    enum Kind: Hashable, Sendable {
        case action
        case project
        case task
    }

    enum Destination: Hashable, Sendable {
        case newTask(projectID: ProjectID?, workspacePath: String?)
        case openTask(
            providerConnectionID: ProviderConnectionID,
            threadID: String,
            scopeRawValue: String
        )
        case addProject
    }

    let id: ID
    let kind: Kind
    let destination: Destination
    let title: String
    let subtitle: String
    let context: ProjectWorkspaceSwitcherContext?
    let project: ProjectCatalogRecord?
    let task: ProjectTaskReference?
    let isCurrent: Bool
    let isFavorite: Bool
    let isRecent: Bool
    let isArchived: Bool
}

private struct ProjectWorkspaceSwitcherProjector {
    private struct Candidate {
        let row: ProjectWorkspaceSwitcherRow
        let defaultScore: Int
        let recency: Date
        let stableOrder: Int
    }

    let request: ProjectWorkspaceSwitcherRequest

    func projection() -> ProjectWorkspaceSwitcherProjection? {
        let projects = request.projects.sorted(by: ProjectCatalogOrdering.areInIncreasingOrder)
        guard !Task.isCancelled else { return nil }
        // The durable catalog validates unique IDs, but keep this pure
        // projection total for callers supplying an in-memory snapshot too.
        var projectsByID: [ProjectID: ProjectCatalogRecord] = [:]
        projectsByID.reserveCapacity(projects.count)
        for (index, project) in projects.enumerated() {
            if index.isCancellationCheckpoint, Task.isCancelled { return nil }
            projectsByID[project.id] = project
        }
        var resolver = ProjectWorkspaceSwitcherProjectResolver(projects: projects)
        let favoriteIDs = request.state.favoriteProjectIDSet
        let recentByID = request.state.recentProjects.reduce(
            into: [ProjectID: Date]()
        ) { result, recent in
            result[recent.projectID] = max(
                result[recent.projectID] ?? .distantPast,
                recent.openedAt
            )
        }
        // The live workspace supplies raw provider lists so this potentially
        // large merge never runs while SwiftUI is mounting Command-K. Unit
        // callers may still provide already-merged references; keep that
        // fallback byte-for-byte compatible with the original request shape.
        let activeTasks: [ProjectTaskReference]
        let archivedTaskReferences: [ProjectTaskReference]
        if let taskLists = request.taskLists {
            activeTasks = ProjectTaskSidebarProjection.mergedTaskReferences(
                from: taskLists,
                scope: .active
            )
            guard !Task.isCancelled else { return nil }
            archivedTaskReferences = ProjectTaskSidebarProjection.mergedTaskReferences(
                from: taskLists,
                scope: .archived
            )
        } else {
            activeTasks = request.activeTasks
            archivedTaskReferences = request.archivedTasks
        }
        let activeIDs = Set(activeTasks.map(\.id))
        let archivedTasks = archivedTaskReferences.filter { !activeIDs.contains($0.id) }
        let allScopedTasks = activeTasks.map { ($0, ThreadListScope.active) }
            + archivedTasks.map { ($0, ThreadListScope.archived) }
        guard !Task.isCancelled else { return nil }
        let selectedTask = allScopedTasks.first { $0.0.id == request.selectedTaskID }
        let selectedProject = request.selectedProjectID.flatMap { projectsByID[$0] }
            ?? selectedTask.flatMap { resolver.project(forFolderPath: $0.0.thread.cwd) }
            ?? resolver.project(forFolderPath: request.selectedWorkspacePath)
        let selectedTaskWorkingDirectory = selectedTask?.0.thread.cwd.flatMap {
            ProjectPathNormalizer.normalize($0)
        }
        let selectedProjectID = selectedProject?.id

        var candidates: [Candidate] = []
        candidates.reserveCapacity(projects.count + allScopedTasks.count + 2)

        if let selectedProject {
            let selectedWorkspacePath = selectedTask?.0.thread.cwd
                ?? request.selectedWorkspacePath
                ?? selectedProject.folderPath
            let context = Self.context(
                project: selectedProject,
                task: selectedTask?.0,
                workingDirectory: selectedWorkspacePath
            )
            let row = ProjectWorkspaceSwitcherRow(
                id: .newTask(selectedProject.id),
                kind: .action,
                destination: .newTask(
                    projectID: selectedProject.id,
                    workspacePath: selectedWorkspacePath
                ),
                title: "New task in \(selectedProject.displayName)",
                subtitle: context.subtitle,
                context: context,
                project: selectedProject,
                task: nil,
                isCurrent: true,
                isFavorite: favoriteIDs.contains(selectedProject.id),
                isRecent: recentByID[selectedProject.id] != nil,
                isArchived: false
            )
            candidates.append(Candidate(
                row: row,
                defaultScore: 10_000,
                recency: recentByID[selectedProject.id] ?? selectedProject.updatedAt,
                stableOrder: -2
            ))
        }

        // A welcome task may remember a checkout that has not been explicitly
        // imported yet. Keep that exact folder actionable without turning it
        // into a project row or scanning the filesystem. Existing selected
        // tasks are handled by the observed-workspace pass below, so this
        // synthetic row is only needed when no task carries the path.
        if selectedProject == nil,
           selectedTaskWorkingDirectory == nil,
           let rawPath = request.selectedWorkspacePath,
           let normalizedPath = ProjectPathNormalizer.normalize(rawPath) {
            let context = Self.context(
                project: nil,
                task: nil,
                workingDirectory: normalizedPath
            )
            let label = context.checkoutLabel ?? normalizedPath
            let row = ProjectWorkspaceSwitcherRow(
                id: .newTaskAtPath(projectID: nil, workspacePath: normalizedPath),
                kind: .action,
                destination: .newTask(projectID: nil, workspacePath: normalizedPath),
                title: "New task in \(label)",
                subtitle: context.subtitle,
                context: context,
                project: nil,
                task: nil,
                isCurrent: true,
                isFavorite: false,
                isRecent: false,
                isArchived: false
            )
            candidates.append(Candidate(
                row: row,
                defaultScore: 9_500,
                recency: .distantPast,
                stableOrder: -1
            ))
        }

        for (index, project) in projects.enumerated() {
            if index.isCancellationCheckpoint, Task.isCancelled { return nil }
            let isFavorite = favoriteIDs.contains(project.id)
            let recent = recentByID[project.id]
            let isCurrent = project.id == selectedProjectID
            let context = Self.context(
                project: project,
                task: nil,
                workingDirectory: project.folderPath
            )
            let row = ProjectWorkspaceSwitcherRow(
                id: .project(project.id),
                kind: .project,
                destination: .newTask(
                    projectID: project.id,
                    workspacePath: project.folderPath
                ),
                title: project.displayName,
                subtitle: context.subtitle,
                context: context,
                project: project,
                task: nil,
                isCurrent: isCurrent,
                isFavorite: isFavorite,
                isRecent: recent != nil,
                isArchived: false
            )
            let defaultScore: Int
            if isCurrent {
                defaultScore = 8_500
            } else if isFavorite {
                defaultScore = 8_000
            } else if recent != nil {
                defaultScore = 7_000
            } else {
                defaultScore = 5_000
            }
            candidates.append(Candidate(
                row: row,
                defaultScore: defaultScore,
                recency: recent ?? project.updatedAt,
                stableOrder: project.order
            ))
        }

        for (index, scopedTask) in allScopedTasks.enumerated() {
            if index.isCancellationCheckpoint, Task.isCancelled { return nil }
            let (task, scope) = scopedTask
            let isCurrent = task.id == request.selectedTaskID
            // Archived tasks stay searchable without filling the default
            // palette with inactive history. The task already under the
            // reader remains visible, though: Command-K followed by Return
            // must never replace an archived task with a blank one.
            if scope == .archived,
               !isCurrent,
               request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            // The active workspace may be a sibling Git worktree that cannot
            // be matched lexically to the imported project root. If the
            // caller has an explicit current project, use it for that one
            // selected task without guessing associations for the rest of the
            // provider catalog.
            let project = resolver.project(forFolderPath: task.thread.cwd)
                ?? (isCurrent
                    ? request.selectedProjectID.flatMap { projectsByID[$0] }
                    : nil)
            let isFavorite = project.map { favoriteIDs.contains($0.id) } ?? false
            let recent = project.flatMap { recentByID[$0.id] }
            let context = Self.context(
                project: project,
                task: task,
                workingDirectory: task.thread.cwd
            )
            let row = ProjectWorkspaceSwitcherRow(
                id: .task(task.id, scopeRawValue: scope.rawValue),
                kind: .task,
                destination: .openTask(
                    providerConnectionID: task.providerConnectionID,
                    threadID: task.thread.id,
                    scopeRawValue: scope.rawValue
                ),
                title: task.thread.title,
                subtitle: context.subtitle,
                context: context,
                project: project,
                task: task,
                isCurrent: isCurrent,
                isFavorite: isFavorite,
                isRecent: recent != nil,
                isArchived: scope == .archived
            )
            candidates.append(Candidate(
                row: row,
                defaultScore: isCurrent ? 9_000 : (scope == .active ? 6_000 : 3_000),
                recency: task.thread.updatedAt,
                stableOrder: task.presentationOrder ?? Int.max
            ))
        }

        let addProject = ProjectWorkspaceSwitcherRow(
            id: .addProject,
            kind: .action,
            destination: .addProject,
            title: "Add Project…",
            subtitle: "Choose a folder to add to Onyx",
            context: nil,
            project: nil,
            task: nil,
            isCurrent: false,
            isFavorite: false,
            isRecent: false,
            isArchived: false
        )
        candidates.append(Candidate(
            row: addProject,
            defaultScore: 0,
            recency: .distantPast,
            stableOrder: Int.max
        ))

        let query = SearchQuery(request.query)
        let selectedWorkingDirectory = selectedTask?.0.thread.cwd
            .flatMap { ProjectPathNormalizer.normalize($0) }
            ?? request.selectedWorkspacePath.flatMap {
                ProjectPathNormalizer.normalize($0)
            }
            ?? selectedProject.flatMap {
                ProjectPathNormalizer.normalize($0.folderPath)
            }

        // A project row is enough for its root, but a developer often has
        // several observed checkouts beneath that root. Emit one lightweight
        // blank-task action per distinct working directory so searching a
        // worktree can start there directly without opening an existing task.
        var workspaceCandidates: [String: (task: ProjectTaskReference, scope: ThreadListScope)] = [:]
        for (index, scopedTask) in allScopedTasks.enumerated() {
            if index.isCancellationCheckpoint, Task.isCancelled { return nil }
            let (task, scope) = scopedTask
            guard let rawPath = task.thread.cwd,
                  let normalizedPath = ProjectPathNormalizer.normalize(rawPath)
            else { continue }
            if let existing = workspaceCandidates[normalizedPath] {
                let shouldReplace: Bool
                if existing.scope != scope {
                    // An active task keeps a worktree visible in the default
                    // palette even when an older archived task shares its
                    // checkout. Archived metadata still participates when
                    // the user explicitly searches for it.
                    shouldReplace = scope == .active
                } else {
                    shouldReplace = task.thread.updatedAt > existing.task.thread.updatedAt
                        || (task.thread.updatedAt == existing.task.thread.updatedAt
                            && task.id.threadID < existing.task.id.threadID)
                }
                if shouldReplace { workspaceCandidates[normalizedPath] = (task, scope) }
            } else {
                workspaceCandidates[normalizedPath] = (task, scope)
            }
        }
        let workspacePaths = workspaceCandidates.keys.sorted()
        guard !Task.isCancelled else { return nil }
        for (index, path) in workspacePaths.enumerated() {
            if index.isCancellationCheckpoint, Task.isCancelled { return nil }
            guard let candidate = workspaceCandidates[path] else { continue }
            let project = resolver.project(forFolderPath: path)
            // The selected-context action above already targets this exact
            // checkout when a current project is known. Do not show a second
            // visually identical row just because a task also observed it.
            if path == selectedWorkingDirectory, selectedProject != nil {
                continue
            }
            // An observed checkout can be a sibling worktree that has no
            // lexical ancestor in the explicit project catalog. Keep it
            // available for path searches (and for the currently open
            // workspace), but do not invent a project grouping for it.
            if project == nil, query.isEmpty, path != selectedWorkingDirectory {
                continue
            }
            if let project {
                // The project row already provides an exact-root New Task
                // action. Keep the palette free of two visually identical
                // root actions.
                let projectRoot = ProjectPathNormalizer.normalize(project.folderPath)
                if path == projectRoot { continue }
            }
            if query.isEmpty,
               candidate.scope == .archived,
               path != selectedWorkingDirectory {
                continue
            }
            let associatedProject = project
                ?? (path == selectedWorkingDirectory ? selectedProject : nil)
            let context = Self.context(
                project: associatedProject,
                task: candidate.task,
                workingDirectory: path,
                includeProvider: false
            )
            let label = context.relativeWorkingDirectory
                ?? context.checkoutLabel
                ?? associatedProject?.displayName
                ?? URL(fileURLWithPath: path).lastPathComponent
            let isCurrent = path == selectedWorkingDirectory
            let isFavorite = associatedProject.map { favoriteIDs.contains($0.id) } ?? false
            let recent = associatedProject.flatMap { recentByID[$0.id] }
            let row = ProjectWorkspaceSwitcherRow(
                id: .newTaskAtPath(projectID: associatedProject?.id, workspacePath: path),
                kind: .action,
                destination: .newTask(
                    projectID: associatedProject?.id,
                    workspacePath: path
                ),
                title: "New task in \(label)",
                subtitle: context.subtitle,
                context: context,
                project: associatedProject,
                task: nil,
                isCurrent: isCurrent,
                isFavorite: isFavorite,
                isRecent: recent != nil,
                isArchived: false
            )
            candidates.append(Candidate(
                row: row,
                defaultScore: isCurrent ? 9_500 : 6_500,
                recency: candidate.task.thread.updatedAt,
                stableOrder: Int.max - workspaceCandidates.count
            ))
        }

        var ranked: [(Candidate, Int)] = []
        ranked.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if index.isCancellationCheckpoint, Task.isCancelled { return nil }
            guard let matchScore = query.matchScore(
                title: candidate.row.title,
                fields: query.isEmpty ? [] : Self.searchFields(for: candidate.row)
            ) else { continue }
            let score: Int
            if query.isEmpty {
                score = candidate.defaultScore
            } else {
                score = matchScore
                    + (candidate.row.isCurrent ? 90 : 0)
                    + (candidate.row.isFavorite ? 55 : 0)
                    + (candidate.row.isArchived ? 0 : 25)
            }
            ranked.append((candidate, score))
        }
        guard !Task.isCancelled else { return nil }
        ranked.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.recency != rhs.0.recency { return lhs.0.recency > rhs.0.recency }
            if lhs.0.stableOrder != rhs.0.stableOrder {
                return lhs.0.stableOrder < rhs.0.stableOrder
            }
            let titleOrder = lhs.0.row.title.localizedStandardCompare(rhs.0.row.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return String(describing: lhs.0.row.id) < String(describing: rhs.0.row.id)
        }
        guard !Task.isCancelled else { return nil }

        let limit = max(0, request.resultLimit)
        guard limit > 0 else { return ProjectWorkspaceSwitcherProjection(rows: []) }
        if query.isEmpty,
           let addProject = ranked.first(where: { $0.0.row.id == .addProject })?.0.row {
            let contexts = ranked.lazy
                .filter { $0.0.row.id != .addProject }
                .prefix(max(0, limit - 1))
                .map(\.0.row)
            return ProjectWorkspaceSwitcherProjection(rows: Array(contexts) + [addProject])
        }
        return ProjectWorkspaceSwitcherProjection(rows: ranked.prefix(limit).map(\.0.row))
    }

    private static func context(
        project: ProjectCatalogRecord?,
        task: ProjectTaskReference?,
        workingDirectory: String?,
        includeProvider: Bool = true
    ) -> ProjectWorkspaceSwitcherContext {
        let normalizedProjectPath = project.flatMap {
            ProjectPathNormalizer.normalize($0.folderPath)
        }
        let normalizedWorkingDirectory = workingDirectory.flatMap(
            ProjectPathNormalizer.normalize
        )
        let relativeWorkingDirectory: String?
        if let normalizedProjectPath,
           let normalizedWorkingDirectory,
           ProjectPathNormalizer.contains(normalizedWorkingDirectory, inside: normalizedProjectPath) {
            let rootComponents = NSString(string: normalizedProjectPath).pathComponents
            let workingComponents = NSString(string: normalizedWorkingDirectory).pathComponents
            let relativeComponents = workingComponents.dropFirst(rootComponents.count)
            relativeWorkingDirectory = relativeComponents.isEmpty
                ? nil
                : relativeComponents.joined(separator: "/")
        } else {
            relativeWorkingDirectory = nil
        }
        return ProjectWorkspaceSwitcherContext(
            projectID: project?.id,
            projectName: project?.displayName,
            projectPath: normalizedProjectPath,
            workingDirectory: normalizedWorkingDirectory ?? workingDirectory,
            relativeWorkingDirectory: relativeWorkingDirectory,
            branch: task?.thread.branch?.nilIfBlank,
            providerDisplayName: includeProvider
                ? task?.providerDisplayName.nilIfBlank
                : nil
        )
    }

    private static func searchFields(for row: ProjectWorkspaceSwitcherRow) -> [String] {
        var fields = [row.title, row.subtitle]
        if let context = row.context {
            fields.append(contentsOf: [
                context.projectName,
                context.projectPath,
                context.workingDirectory,
                context.relativeWorkingDirectory,
                context.branch,
                context.providerDisplayName,
            ].compactMap { $0 })
        }
        if let task = row.task {
            fields.append(task.thread.preview)
        }
        switch row.destination {
        case .newTask:
            fields.append(contentsOf: ["new task", "workspace", "worktree"])
        case .openTask:
            fields.append(contentsOf: ["task", row.isArchived ? "archived" : "active"])
        case .addProject:
            fields.append(contentsOf: ["open folder", "import project"])
        }
        return fields
    }
}

private struct SearchQuery {
    let normalized: String
    let tokens: [String]

    init(_ rawValue: String) {
        normalized = Self.normalize(rawValue)
        tokens = normalized.split(separator: " ").map(String.init)
    }

    var isEmpty: Bool { tokens.isEmpty }

    func matchScore(title: String, fields: [String]) -> Int? {
        guard !isEmpty else { return 0 }
        let normalizedTitle = Self.normalize(title)
        let normalizedFields = fields.map(Self.normalize)
        let searchable = normalizedFields.joined(separator: " ")
        guard tokens.allSatisfy({ token in
            searchable.contains(token) || Self.isSubsequence(token, of: searchable)
        }) else { return nil }

        if normalizedTitle == normalized { return 1_000 }
        if normalizedTitle.hasPrefix(normalized) { return 920 }
        if normalizedTitle.split(separator: " ").contains(where: { $0.hasPrefix(normalized) }) {
            return 860
        }
        if normalizedTitle.contains(normalized) { return 800 }
        if normalizedFields.dropFirst().contains(where: { $0.hasPrefix(normalized) }) {
            return 720
        }
        if normalizedFields.contains(where: { $0.contains(normalized) }) { return 660 }

        let exactTokenCount = tokens.filter { token in
            normalizedFields.contains(where: { $0.contains(token) })
        }.count
        return 420 + exactTokenCount * 20
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "_" || $0 == "-" })
            .joined(separator: " ")
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var needleIndex = needle.startIndex
        for character in haystack where needleIndex < needle.endIndex {
            if character == needle[needleIndex] {
                needle.formIndex(after: &needleIndex)
            }
        }
        return needleIndex == needle.endIndex
    }
}

private struct ProjectWorkspaceSwitcherProjectResolver {
    private let candidates: [(project: ProjectCatalogRecord, root: String, depth: Int)]
    private var cache: [String: ProjectCatalogRecord?] = [:]

    init(projects: [ProjectCatalogRecord]) {
        candidates = projects.compactMap { project in
            ProjectPathNormalizer.normalize(project.folderPath).map {
                (project, $0, ProjectPathNormalizer.componentCount($0))
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

    mutating func project(forFolderPath rawPath: String?) -> ProjectCatalogRecord? {
        guard let rawPath else { return nil }
        if let cached = cache[rawPath] { return cached }
        guard let normalized = ProjectPathNormalizer.normalize(rawPath) else {
            cache[rawPath] = .some(nil)
            return nil
        }
        let match = candidates.first {
            ProjectPathNormalizer.contains(normalized, inside: $0.root)
        }?.project
        cache[rawPath] = .some(match)
        return match
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Int {
    /// Frequent enough to make cancellation feel immediate without adding a
    /// branch to every candidate in a large cached catalog.
    var isCancellationCheckpoint: Bool { self & 63 == 0 }
}
