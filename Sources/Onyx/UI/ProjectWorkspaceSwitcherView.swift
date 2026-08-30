import AppKit
import SwiftUI

/// A fast, window-local palette for moving between the things a developer is
/// most likely to need next: a project/worktree, a durable task, or a fresh
/// task in the current checkout.  The view deliberately receives an immutable
/// metadata snapshot. Opening it never performs a filesystem walk or network
/// request.
struct ProjectWorkspaceSwitcherView: View {
    let baseRequest: ProjectWorkspaceSwitcherRequest
    let sourceRevision: ProjectWorkspaceSwitcherSourceRevision
    let focusRequest: Int
    @ObservedObject var stateModel: ProjectWorkspaceSwitcherStateModel
    let dismiss: () -> Void
    let activate: (ProjectWorkspaceSwitcherRow.Destination) -> Void
    /// Injected in tests and previews; production posts a native VoiceOver
    /// announcement so arrow-key selection is audible while the search field
    /// remains the keyboard responder.
    let announce: @MainActor (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @StateObject private var projectionModel: ProjectWorkspaceSwitcherProjectionModel
    @State private var query = ""
    @State private var selectedID: ProjectWorkspaceSwitcherRow.ID?

    init(
        baseRequest: ProjectWorkspaceSwitcherRequest,
        sourceRevision: ProjectWorkspaceSwitcherSourceRevision,
        focusRequest: Int,
        stateModel: ProjectWorkspaceSwitcherStateModel,
        dismiss: @escaping () -> Void,
        activate: @escaping (ProjectWorkspaceSwitcherRow.Destination) -> Void,
        projectionModel: ProjectWorkspaceSwitcherProjectionModel = .init(),
        announce: @escaping @MainActor (String) -> Void =
            ProjectWorkspaceSwitcherAccessibility.announce
    ) {
        self.baseRequest = baseRequest
        self.sourceRevision = sourceRevision
        self.focusRequest = focusRequest
        _stateModel = ObservedObject(wrappedValue: stateModel)
        self.dismiss = dismiss
        self.activate = activate
        self.announce = announce
        _projectionModel = StateObject(wrappedValue: projectionModel)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                header
                Divider().overlay(OnyxTheme.divider)
                resultSurface
                footer
            }
            .frame(maxWidth: 720)
            .background(OnyxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
            }
            .shadow(color: .black.opacity(0.34), radius: 30, y: 14)
            .padding(.horizontal, 28)
            .padding(.bottom, 150)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98)))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel("Switch project, worktree, or task")
            .accessibilityIdentifier("workspace-switcher")
        }
        .onAppear {
            stateModel.retainProjects(Set(baseRequest.projects.map(\.id)))
            // Paint the palette and install the field editor before starting
            // any catalog merge/ranking. The first keystroke should never sit
            // behind a large active+archived task snapshot.
            let shouldStartInitialProjection = projectionModel.requestedGeneration == 0
            DispatchQueue.main.async {
                isSearchFocused = true
                // A query/source revision may have arrived while AppKit was
                // installing the field editor. Its onChange handler already
                // scheduled the newer generation; never let this deferred
                // bootstrap overwrite it with the original snapshot.
                guard shouldStartInitialProjection,
                      projectionModel.requestedGeneration == 0
                else { return }
                refreshProjection()
            }
        }
        .onChange(of: focusRequest) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: query) { _, _ in
            refreshProjection()
        }
        .onChange(of: sourceRevision) { _, _ in
            refreshProjection()
        }
        .onChange(of: stateModel.snapshot) { _, _ in
            refreshProjection()
        }
        .onChange(of: projectionModel.projection) { _, projection in
            guard !projection.rows.isEmpty else {
                selectedID = nil
                return
            }
            if let selectedID,
               projection.rows.contains(where: { $0.id == selectedID }) {
                return
            }
            selectedID = projection.initialSelectionID
        }
        .onExitCommand(perform: dismiss)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OnyxTheme.iris.opacity(0.14))
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnyxTheme.iris)
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Switch context")
                        .font(.system(size: OnyxTypography.paneTitle, weight: .semibold))
                        .foregroundStyle(OnyxTheme.strongText)
                    Text("Project · worktree · task")
                        .font(.system(size: OnyxTypography.metadata, weight: .medium))
                        .foregroundStyle(OnyxTheme.quietText)
                }

                Spacer(minLength: 8)

                Text("⌘K")
                    .font(.system(size: OnyxTypography.metadata, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(minHeight: 24)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("Command K")
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                TextField("Search projects, worktrees, tasks, branches…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: OnyxTypography.paneTitle))
                    .focused($isSearchFocused)
                    .onSubmit(activateSelection)
                    .onKeyPress(.downArrow) {
                        moveSelection(direction: .next)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(direction: .previous)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
                    .accessibilityIdentifier("workspace-switcher-field")
                    .accessibilityLabel("Search projects, worktrees, and tasks")

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onyxHelp("Clear context search")
                    .accessibilityLabel("Clear context search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(OnyxTheme.canvas.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var resultSurface: some View {
        let rows = projectionModel.projection.rows
        if rows.isEmpty {
            VStack(spacing: 9) {
                Spacer(minLength: 30)
                Image(systemName: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "arrow.triangle.2.circlepath"
                    : "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Add a project to get started"
                    : "No matching context")
                    .font(.system(size: OnyxTypography.navigation, weight: .medium))
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Projects and their worktrees will appear here."
                    : "Try a project name, folder, branch, provider, or task title.")
                    .font(.system(size: OnyxTypography.secondary))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Add Project…") {
                        activate(.addProject)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(OnyxTheme.iris)
                    .foregroundStyle(OnyxTheme.canvas)
                }
                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity, minHeight: 250)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            switcherRow(row)
                                .id(row.id)
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 180, maxHeight: 390)
                .scrollIndicators(.hidden)
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func switcherRow(_ row: ProjectWorkspaceSwitcherRow) -> some View {
        // Capture the publication generation used to paint this row. A click
        // delivered after a refresh must not be retargeted to a replacement
        // row that happens to reuse the same ID.
        let rowGeneration = projectionModel.publishedGeneration
        return HStack(spacing: 0) {
            Button {
                guard projectionModel.canActivate(row, generation: rowGeneration) else { return }
                selectedID = row.id
                activate(row)
            } label: {
                HStack(spacing: 10) {
                    rowIcon(row)
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.system(size: OnyxTypography.navigation,
                                              weight: row.isCurrent ? .semibold : .medium))
                                .foregroundStyle(row.isCurrent ? OnyxTheme.strongText : OnyxTheme.readingText)
                                .lineLimit(1)
                            if row.isCurrent {
                                Text("Current")
                                    .font(.system(size: OnyxTypography.metadata, weight: .semibold))
                                    .foregroundStyle(OnyxTheme.iris)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(OnyxTheme.iris.opacity(0.10))
                                    .clipShape(Capsule())
                            }
                            if row.isArchived {
                                Text("Archived")
                                    .font(.system(size: OnyxTypography.metadata, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !row.subtitle.isEmpty {
                            Text(row.subtitle)
                                .font(.system(size: OnyxTypography.secondary))
                                .foregroundStyle(OnyxTheme.quietText)
                                .lineLimit(1)
                        }
                        if let path = row.context?.workingDirectory {
                            Text(path)
                                .font(.system(size: OnyxTypography.metadata, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 8)

                    if selectedID == row.id {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    if selectedID == row.id {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(row.isCurrent ? OnyxTheme.iris.opacity(0.13) : OnyxTheme.iris.opacity(0.09))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!projectionModel.canActivate(row, generation: rowGeneration))
            .accessibilityLabel(row.title)
            .accessibilityValue(accessibilityValue(for: row))
            .accessibilityHint(destinationHint(for: row.destination))
            .accessibilityAddTraits(selectedID == row.id ? .isSelected : [])

            if let projectID = row.project?.id {
                let projectName = row.project?.displayName ?? "this project"
                Button {
                    guard projectionModel.canActivate(
                        row,
                        generation: rowGeneration
                    ) else { return }
                    stateModel.toggleFavorite(projectID)
                } label: {
                    Image(systemName: row.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(row.isFavorite ? OnyxTheme.warning : Color.secondary.opacity(0.56))
                        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!projectionModel.canActivate(row, generation: rowGeneration))
                .onyxHelp(row.isFavorite ? "Remove project from favorites" : "Favorite project")
                .accessibilityLabel(row.isFavorite ? "Unfavorite project" : "Favorite project")
                .accessibilityHint("Keeps \(projectName) near the top of the switcher")
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func rowIcon(_ row: ProjectWorkspaceSwitcherRow) -> some View {
        switch row.kind {
        case .action:
            switch row.destination {
            case .addProject:
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(OnyxTheme.iris)
            case .newTask:
                Image(systemName: "plus.square")
                    .foregroundStyle(OnyxTheme.electric)
            case .openTask:
                Image(systemName: "arrow.right")
                    .foregroundStyle(OnyxTheme.electric)
            }
        case .project:
            Image(systemName: "folder")
                .foregroundStyle(row.isCurrent ? OnyxTheme.iris : OnyxTheme.electric.opacity(0.82))
        case .task:
            Image(systemName: row.isArchived ? "archivebox" : "bubble.left")
                .foregroundStyle(row.isCurrent ? OnyxTheme.iris : Color.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("Navigate", systemImage: "arrow.up.arrow.down")
            Label("Open", systemImage: "return")
            Label("Close", systemImage: "escape")
            Spacer()
            Text("\(projectionModel.projection.rows.count) results")
        }
        .font(.system(size: OnyxTypography.metadata, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Rectangle().fill(OnyxTheme.border).frame(height: OnyxTheme.hairline)
        }
        .accessibilityHidden(true)
    }

    private func refreshProjection() {
        // Keep the last painted rows for visual continuity, but make them
        // noninteractive until this exact request publishes. A fast Return or
        // click must never activate a row from the previous query/catalog.
        selectedID = nil
        var request = baseRequest
        request.query = query
        request.state = stateModel.snapshot
        projectionModel.refresh(request)
    }

    private func moveSelection(direction: ProjectWorkspaceSwitcherProjection.SelectionDirection) {
        guard projectionModel.canActivateCurrentProjection else {
            // Do not let an arrow event resurrect a selection from the prior
            // query while a replacement generation is being ranked.
            selectedID = nil
            return
        }
        let nextID = projectionModel.projection.movingSelection(
            from: selectedID,
            direction: direction
        )
        guard let nextID,
              let row = projectionModel.projection.rows.first(where: { $0.id == nextID })
        else {
            selectedID = nil
            return
        }
        let didChange = selectedID != nextID
        selectedID = nextID
        if didChange {
            announce(ProjectWorkspaceSwitcherAccessibility.selectionAnnouncement(for: row))
        }
    }

    private func activateSelection() {
        guard let selectedID,
              let row = projectionModel.projection.rows.first(where: { $0.id == selectedID }),
              projectionModel.canActivate(row, generation: projectionModel.publishedGeneration)
        else { return }
        activate(row)
    }

    private func activate(_ row: ProjectWorkspaceSwitcherRow) {
        guard projectionModel.canActivate(
            row,
            generation: projectionModel.publishedGeneration
        )
        else { return }
        if let projectID = row.project?.id {
            stateModel.recordOpened(projectID)
        }
        activate(row.destination)
    }

    private func accessibilityValue(for row: ProjectWorkspaceSwitcherRow) -> String {
        var values: [String] = []
        if !row.subtitle.isEmpty { values.append(row.subtitle) }
        if let path = row.context?.workingDirectory { values.append(path) }
        if row.isCurrent { values.append("Current") }
        if row.isFavorite { values.append("Favorite") }
        if row.isRecent { values.append("Recent") }
        if row.isArchived { values.append("Archived") }
        return values.joined(separator: ". ")
    }

    private func destinationHint(
        for destination: ProjectWorkspaceSwitcherRow.Destination
    ) -> String {
        switch destination {
        case .newTask: "Starts a new task in this workspace"
        case .openTask: "Opens this task"
        case .addProject: "Opens a folder chooser"
        }
    }
}

/// Small AppKit bridge for VoiceOver feedback. Keeping this outside the view
/// makes the announcement text deterministic and lets hosted tests capture it
/// without requiring VoiceOver to be enabled on the test runner.
enum ProjectWorkspaceSwitcherAccessibility {
    static func selectionAnnouncement(
        for row: ProjectWorkspaceSwitcherRow
    ) -> String {
        var details = [row.title]
        if !row.subtitle.isEmpty { details.append(row.subtitle) }
        if row.isArchived { details.append("Archived") }
        if row.isCurrent { details.append("Current") }
        return "Selected " + details.joined(separator: ". ")
    }

    @MainActor
    static func announce(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                // Medium priority lets a selection change interrupt neither
                // the user's current VoiceOver sentence nor text entry.
                .priority: NSNumber(value: 50),
            ]
        )
    }
}

struct ProjectWorkspaceSwitcherSourceRevision: Hashable, Sendable {
    let projectRevision: UInt64
    let taskRevision: UInt64
    let scope: ThreadListScope
    let providerConnectionID: ProviderConnectionID
    let selectedThreadID: String?
    let selectedWorkspacePath: String?
}

protocol ProjectWorkspaceSwitcherProjectionProviding: Sendable {
    func make(
        _ request: ProjectWorkspaceSwitcherRequest
    ) async -> ProjectWorkspaceSwitcherProjection?
}

@MainActor
final class ProjectWorkspaceSwitcherProjectionModel: ObservableObject {
    @Published private(set) var projection = ProjectWorkspaceSwitcherProjection(rows: [])
    @Published private(set) var isRefreshing = false

    private let worker: any ProjectWorkspaceSwitcherProjectionProviding
    private var task: Task<Void, Never>?
    private(set) var requestedGeneration: UInt64 = 0
    private(set) var publishedGeneration: UInt64 = 0

    var canActivateCurrentProjection: Bool {
        !isRefreshing && publishedGeneration == requestedGeneration
    }

    /// Returns true only for a row from the currently published generation.
    /// SwiftUI/AppKit can deliver a click that was queued just before a new
    /// query or catalog revision invalidated the row. Comparing the captured
    /// row as well as its generation prevents that stale event from being
    /// retargeted to a newer row with the same identity but a different
    /// destination (for example, a project whose current worktree changed).
    func canActivate(
        _ row: ProjectWorkspaceSwitcherRow,
        generation: UInt64? = nil
    ) -> Bool {
        guard canActivateCurrentProjection,
              generation == nil || generation == publishedGeneration,
              let current = projection.rows.first(where: { $0.id == row.id })
        else { return false }
        return current == row
    }

    init(
        worker: any ProjectWorkspaceSwitcherProjectionProviding =
            ProjectWorkspaceSwitcherProjectionWorker()
    ) {
        self.worker = worker
    }

    func refresh(_ request: ProjectWorkspaceSwitcherRequest) {
        // Request equality would walk every task row on the main actor. A
        // monotonic token fences stale results without copying or comparing
        // the complete catalog after every keystroke.
        requestedGeneration &+= 1
        let generation = requestedGeneration
        task?.cancel()
        isRefreshing = true
        task = Task { [weak self, worker] in
            guard let result = await worker.make(request) else {
                // A worker may cooperatively cancel without throwing. If this
                // was still the active generation, retain the old rows but
                // leave the model fenced (publishedGeneration intentionally
                // stays behind requestedGeneration) so no stale click can
                // activate them.
                guard !Task.isCancelled,
                      let self,
                      self.requestedGeneration == generation
                else { return }
                self.isRefreshing = false
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.requestedGeneration == generation
            else { return }
            self.publishedGeneration = generation
            self.projection = result
            self.isRefreshing = false
        }
    }

    deinit {
        task?.cancel()
    }
}

actor ProjectWorkspaceSwitcherProjectionWorker: ProjectWorkspaceSwitcherProjectionProviding {
    private var cachedTaskListRevision: UInt64?
    private var cachedActiveTasks: [ProjectTaskReference] = []
    private var cachedArchivedTasks: [ProjectTaskReference] = []
    /// Internal observability for the focused regression suite. Production
    /// behavior only depends on the cached arrays and revision above.
    private(set) var taskListMergeCount = 0

    func make(
        _ request: ProjectWorkspaceSwitcherRequest
    ) async -> ProjectWorkspaceSwitcherProjection? {
        var preparedRequest = request
        if let taskLists = request.taskLists,
           let taskListRevision = request.taskListRevision {
            if cachedTaskListRevision != taskListRevision {
                // `mergedTaskReferences` is synchronous and intentionally
                // deterministic. Serialize it on this worker actor and cache
                // both scopes so canceled query generations cannot fan out
                // several full catalog sorts at once.
                let activeTasks = ProjectTaskSidebarProjection.mergedTaskReferences(
                    from: taskLists,
                    scope: .active
                )
                let archivedTasks = ProjectTaskSidebarProjection.mergedTaskReferences(
                    from: taskLists,
                    scope: .archived
                )
                cachedTaskListRevision = taskListRevision
                cachedActiveTasks = activeTasks
                cachedArchivedTasks = archivedTasks
                taskListMergeCount &+= 1
            }
            guard !Task.isCancelled else { return nil }
            preparedRequest.taskLists = nil
            preparedRequest.activeTasks = cachedActiveTasks
            preparedRequest.archivedTasks = cachedArchivedTasks
        }

        let operation = Task.detached(priority: .userInitiated) {
            ProjectWorkspaceSwitcherProjection.makeCancellable(preparedRequest)
        }
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }
}
