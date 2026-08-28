import AppKit
import SwiftUI

struct TaskSidebarView: View {
    @ObservedObject var model: OnyxAppModel
    @ObservedObject var projectCatalog: ProjectCatalogModel
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    let providerConnectionID: ProviderConnectionID
    let providerConnections: [OnyxApplicationHost.WorkspaceConnection]
    let onSelectTask: @MainActor (ProviderConnectionID, String) -> Void
    let onProjectFailure: ProjectCatalogFailureHandler
    var searchFocusRequest = 0
    @FocusState private var isSearchFocused: Bool
    @State private var expandedProjectIDs: Set<ProjectID> = []
    @State private var lastResolvedSelectedProjectID: ProjectID?
    @StateObject private var projectionModel = ProjectTaskSidebarProjectionModel()

    var body: some View {
        // Read one immutable snapshot. Grouping is calculated by the
        // projection worker, never while SwiftUI is evaluating this body.
        let grouping = projectionModel.grouping
        let displayedGroups = displayedProjectGroups(from: grouping)

        VStack(spacing: 0) {
            header
            search
            projectListHeader(taskCount: grouping.taskCount)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(displayedGroups) { group in
                        projectHeader(group)
                            .padding(.top, 8)
                        if isProjectExpanded(group.id) {
                            if group.tasks.isEmpty {
                                if !model.isLoadingThreadList {
                                    Text("No tasks yet")
                                        .font(.system(size: OnyxTypography.secondary))
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 28)
                                        .padding(.vertical, 5)
                                }
                            } else {
                                // A small inset makes the project/task relationship
                                // readable without turning each project into a card.
                                ForEach(group.tasks) { task in
                                    threadRow(task)
                                        .padding(.leading, 12)
                                }
                            }
                        }
                    }

                    if !grouping.unassigned.isEmpty {
                        if !projectCatalog.projects.isEmpty {
                            SidebarSectionLabel(
                                title: "Other Tasks",
                                count: grouping.unassigned.count
                            )
                            .padding(.top, displayedGroups.isEmpty ? 4 : 12)
                        }
                        ForEach(grouping.unassigned) { task in threadRow(task) }
                    }

                    switch TaskSidebarContentState.resolve(
                        isProjectionReady: projectionModel.isReady,
                        hasVisibleTasks: grouping.taskCount > 0,
                        hasVisibleProjects: !displayedGroups.isEmpty,
                        isLoadingThreadList: model.isLoadingThreadList
                    ) {
                    case .loading:
                        sidebarLoadingState
                    case .empty:
                        sidebarEmptyState
                    case .content:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }

            SidebarUtilityFooter(model: model)
        }
        .background(OnyxTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(OnyxTheme.border).frame(width: OnyxTheme.hairline)
        }
        .task(id: sidebarProjectionRequest.key) {
            projectionModel.refresh(sidebarProjectionRequest)
        }
        .onAppear {
            resetProjectDisclosureToSelection(in: projectionModel.grouping)
        }
        .onChange(of: model.selectedThreadID) {
            // Selecting a task must not collapse other projects and move the
            // rows that were under the pointer. Reveal the destination project
            // even when another task in that same project was selected before.
            // Projection-only metadata refreshes use the guarded reconciler
            // below so they do not reopen a group the user deliberately closed.
            revealSelectedProject(in: projectionModel.grouping)
        }
        .onChange(of: model.threadListScope) {
            resetProjectDisclosureToSelection(in: projectionModel.grouping)
        }
        .onChange(of: providerConnectionID) {
            // Provider-aware task navigation keeps the same sidebar shell.
            // Preserve the user's open projects while the destination
            // provider's projection replaces the rows in place.
            reconcileProjectDisclosure(in: projectionModel.grouping)
        }
        .onChange(of: projectionModel.publicationRevision) {
            reconcileProjectDisclosure(in: projectionModel.grouping)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Onyx")
                    .font(.system(size: OnyxTypography.paneTitle, weight: .semibold))
            }
            Spacer()
            Button(action: model.newTask) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                        .frame(width: 27, height: 27)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
                        }
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OnyxTheme.iris)
                }
                .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onyxHelp("New task (⌘N)")
            .accessibilityLabel("New task")
            .accessibilityHint("Creates a new task")
        }
        .frame(height: OnyxWorkspaceMetrics.paneHeaderHeight)
        .padding(.horizontal, OnyxWorkspaceMetrics.paneEdgeInset)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11.5, weight: .medium))
            TextField("Search tasks", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: OnyxTypography.secondary))
                .focused($isSearchFocused)
                .accessibilityLabel("Search tasks")
                .accessibilityHint("Filters the task list as you type")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear task search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: OnyxWorkspaceMetrics.fieldHeight)
        .background(OnyxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 11)
        .onExitCommand {
            if model.searchText.isEmpty {
                isSearchFocused = false
            } else {
                model.searchText = ""
            }
        }
        .onAppear {
            if searchFocusRequest > 0 {
                isSearchFocused = true
            }
        }
        .onChange(of: searchFocusRequest) {
            isSearchFocused = true
        }
    }

    private func projectListHeader(taskCount: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Projects")
                    .font(.system(size: OnyxTypography.secondary, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: beginImportProject) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.plus")
                        Text("Add Project")
                    }
                    .font(.system(size: OnyxTypography.secondary, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onyxHelp("Add a project folder")
                .accessibilityLabel("Add project")
                .accessibilityHint("Opens a folder chooser; you can also create a new folder there")
            }

            HStack(spacing: 7) {
                Text(model.isShowingArchivedThreads ? "Archived Tasks" : "Tasks")
                    .font(.system(size: OnyxTypography.secondary, weight: .semibold))
                Text("\(taskCount)")
                    .font(.system(size: OnyxTypography.metadata, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                scopeMenu
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .contain)
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 6)
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(ThreadListScope.allCases) { scope in
                Button {
                    model.setThreadListScope(scope)
                } label: {
                    HStack {
                        Text(scopeMenuTitle(for: scope, includeTasks: true))
                        if model.threadListScope == scope {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityAddTraits(model.threadListScope == scope ? .isSelected : [])
            }
        } label: {
            HStack(spacing: 4) {
                Text(scopeMenuTitle(for: model.threadListScope))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .font(.system(size: OnyxTypography.metadata, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minHeight: OnyxHitTarget.compact)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.55)
        .accessibilityLabel("Task list scope")
        .accessibilityValue(scopeMenuTitle(for: model.threadListScope, includeTasks: true))
        .accessibilityHint("Choose active or archived tasks")
    }

    private func scopeMenuTitle(
        for scope: ThreadListScope,
        includeTasks: Bool = false
    ) -> String {
        switch scope {
        case .active: includeTasks ? "Active Tasks" : "Active"
        case .archived: includeTasks ? "Archived Tasks" : "Archived"
        }
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isShowingArchivedThreads ? "archivebox" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(model.searchText.isEmpty ? "No archived tasks" : "No matching tasks")
                .font(.system(size: OnyxTypography.secondary, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    private var sidebarLoadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading tasks…")
                .font(.system(size: OnyxTypography.secondary, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading tasks")
    }

    private var isConnected: Bool {
        if case .connected = model.connectionState { return true }
        return false
    }

    private var providerDisplayName: String {
        providerConnections.first(where: { $0.id == providerConnectionID })?.displayName
            ?? (providerConnectionID == .codexDefault ? "Codex" : "Provider")
    }

    private var sidebarProjectionRequest: ProjectTaskSidebarProjectionRequest {
        let useLiveSnapshot = TaskSidebarLiveSnapshotPolicy.shouldUseLiveSnapshot(
            hasAuthoritativeThreadList: model.hasAuthoritativeThreadListForCurrentScope,
            hasUnlistedSelectedTask: model.hasUnlistedSelectedTask
        )
        return projectCatalog.sidebarProjectionRequest(
            scope: model.threadListScope,
            searchText: model.searchText,
            liveProviderConnectionID: providerConnectionID,
            liveProviderDisplayName: providerDisplayName,
            liveProviderThreadListRevision: useLiveSnapshot
                ? model.threadListRevision
                : nil,
            // New Task is a composer state, not a durable task. Excluding its
            // synthetic row also keeps every durable row fixed during
            // Task -> New Task -> Task navigation.
            liveProviderThreads: useLiveSnapshot ? model.catalogThreads : nil
        )
    }

    private func displayedProjectGroups(
        from grouping: ProjectTaskGrouping
    ) -> [ProjectTaskGroup] {
        if model.isShowingArchivedThreads || !model.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return grouping.groups.filter { !$0.tasks.isEmpty }
        }
        return grouping.groups
    }

    private func isProjectExpanded(_ projectID: ProjectID) -> Bool {
        TaskSidebarProjectDisclosure.isExpanded(
            projectID,
            expandedProjectIDs: expandedProjectIDs,
            searchText: model.searchText
        )
    }

    private func resetProjectDisclosureToSelection(in grouping: ProjectTaskGrouping) {
        let selected = selectedProjectID(in: grouping)
        expandedProjectIDs = TaskSidebarProjectDisclosure.defaultExpandedProjectIDs(
            selectedProjectID: selected
        )
        lastResolvedSelectedProjectID = selected
    }

    /// A projection can arrive after selection. Expand that project once when
    /// it becomes resolvable, but preserve every disclosure the user has
    /// already chosen during ordinary task/search/provider updates.
    private func reconcileProjectDisclosure(in grouping: ProjectTaskGrouping) {
        let selected = selectedProjectID(in: grouping)
        if TaskSidebarProjectDisclosure.shouldExpandResolvedSelection(
            selected,
            after: lastResolvedSelectedProjectID
        ) {
            expandedProjectIDs = TaskSidebarProjectDisclosure.expandedProjectIDs(
                revealing: selected,
                within: expandedProjectIDs
            )
        }
        lastResolvedSelectedProjectID = selected
    }

    private func revealSelectedProject(in grouping: ProjectTaskGrouping) {
        let selected = selectedProjectID(in: grouping)
        expandedProjectIDs = TaskSidebarProjectDisclosure.expandedProjectIDs(
            revealing: selected,
            within: expandedProjectIDs
        )
        lastResolvedSelectedProjectID = selected
    }

    private func selectedProjectID(in grouping: ProjectTaskGrouping) -> ProjectID? {
        guard let selectedThreadID = model.selectedThreadID else { return nil }
        return grouping.groups.first(where: { group in
            group.tasks.contains {
                $0.providerConnectionID == providerConnectionID
                    && $0.thread.id == selectedThreadID
            }
        })?.id
    }

    private func toggleProjectDisclosure(_ projectID: ProjectID) {
        guard TaskSidebarProjectDisclosure.mayToggle(
            searchText: model.searchText
        ) else { return }
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
    }

    private func projectHeader(_ group: ProjectTaskGroup) -> some View {
        let isExpanded = isProjectExpanded(group.id)
        return ProjectSidebarHeader(
            project: group.project,
            taskCount: group.tasks.count,
            isExpanded: isExpanded,
            canMoveUp: projectCatalog.canMoveProject(id: group.id, offset: -1),
            canMoveDown: projectCatalog.canMoveProject(id: group.id, offset: 1),
            toggleExpanded: { toggleProjectDisclosure(group.id) },
            newTask: { model.newTask(inWorkspace: group.project.folderPath) },
            rename: { beginRenameProject(group.project) },
            moveUp: {
                Task {
                    await projectCatalog.moveProject(
                        id: group.id,
                        offset: -1,
                        onFailure: onProjectFailure
                    )
                }
            },
            moveDown: {
                Task {
                    await projectCatalog.moveProject(
                        id: group.id,
                        offset: 1,
                        onFailure: onProjectFailure
                    )
                }
            },
            remove: { beginRemoveProject(group.project) }
        )
    }

    @ViewBuilder
    private func threadRow(_ task: ProjectTaskReference) -> some View {
        let isCurrentProvider = task.providerConnectionID == providerConnectionID
        let thread = task.thread
        let attention = isCurrentProvider
            ? model.taskAttention(for: thread)
            : thread.status.sidebarTaskAttention
        Button {
            onSelectTask(task.providerConnectionID, thread.id)
        } label: {
            TaskSidebarRow(
                thread: thread,
                attention: attention,
                isSelected: isCurrentProvider && model.selectedThreadID == thread.id,
                isArchived: model.isShowingArchivedThreads,
                providerName: providerConnections.count > 1 ? task.providerDisplayName : nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        // Keep the whole visible row clickable, including the quiet trailing
        // whitespace. The label's intrinsic text width should never become
        // the hit-target width in a wide sidebar.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thread.title)
        .accessibilityValue(threadAccessibilityValue(
            thread,
            providerName: task.providerDisplayName,
            attention: attention,
            isArchived: model.isShowingArchivedThreads
        ))
        .accessibilityHint(
            isCurrentProvider && model.selectedThreadID == thread.id
                ? "Selected task"
                : "Opens this task"
        )
        .accessibilityAddTraits(
            isCurrentProvider && model.selectedThreadID == thread.id ? .isSelected : []
        )
        .contextMenu {
            if !isCurrentProvider {
                Button("Open in \(task.providerDisplayName)") {
                    onSelectTask(task.providerConnectionID, thread.id)
                }
            } else if model.isShowingArchivedThreads {
                Button("Restore Task") { model.restore(thread.id) }
                if model.supports(.threadDeletion) {
                    Divider()
                    Button("Delete Permanently…", role: .destructive) {
                        model.beginDelete(thread.id, window: windowPresentation.window)
                    }
                }
            } else {
                Button(thread.isPinned ? "Unpin" : "Pin") { model.togglePin(thread.id) }
                Button("Rename…") { model.beginRename(thread.id, window: windowPresentation.window) }
                if model.supports(.threadForking) {
                    Button("Fork Task") { model.fork(thread.id) }
                        .disabled(!model.canForkThread(thread))
                }
                Divider()
                if model.supports(.threadCompaction) {
                    Button("Compact Context") { model.compact(thread.id) }
                        .disabled(!model.canCompactThread(thread))
                }
                Button("Archive") { model.archive(thread.id) }
                    .disabled(!model.canArchiveThread(thread))
                if model.supports(.threadDeletion) {
                    Divider()
                    Button("Delete Permanently…", role: .destructive) {
                        model.beginDelete(thread.id, window: windowPresentation.window)
                    }
                }
            }
        }
    }

    private func threadAccessibilityValue(
        _ thread: RuntimeThread,
        providerName: String,
        attention: RuntimeTaskAttention,
        isArchived: Bool
    ) -> String {
        var details = [providerName]
        if thread.isPinned { details.append("Pinned") }
        details.append(isArchived ? "Archived" : attention.label)
        if !thread.preview.isEmpty { details.append(thread.preview) }
        details.append("Updated \(TaskSidebarTimestamp.accessibilityDescription(for: thread.updatedAt))")
        return details.joined(separator: ". ")
    }

    private func beginImportProject() {
        projectCatalog.chooseAndImportProject(
            window: windowPresentation.window,
            initialFolderPath: model.draftWorkspacePath,
            onFailure: onProjectFailure
        ) { imported in
            model.selectWorkspace(imported.folderPath)
        }
    }

    private func beginRenameProject(_ project: ProjectCatalogRecord) {
        let alert = NSAlert()
        alert.messageText = "Rename project"
        alert.informativeText = "This changes only the name shown in Onyx. The folder is not renamed."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: project.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("Project name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard let window = windowPresentation.window else { return }
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            Task { @MainActor in
                await projectCatalog.renameProject(
                    id: project.id,
                    displayName: name,
                    onFailure: onProjectFailure
                )
            }
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    private func beginRemoveProject(_ project: ProjectCatalogRecord) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(project.displayName) from Onyx?"
        alert.informativeText = "The folder and everything inside it will stay exactly where they are. Tasks from this folder will appear under Other Tasks."
        alert.addButton(withTitle: "Remove from Onyx")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = windowPresentation.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                await projectCatalog.removeProject(
                    id: project.id,
                    onFailure: onProjectFailure
                )
            }
        }
    }
}

private struct SidebarSectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: OnyxTypography.secondary, weight: .semibold))
            Spacer()
            Text("\(count)")
                .font(.system(size: OnyxTypography.metadata, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "task" : "tasks")")
    }
}

struct ProjectSidebarHeader: View {
    let project: ProjectCatalogRecord
    let taskCount: Int
    let isExpanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let toggleExpanded: () -> Void
    let newTask: () -> Void
    let rename: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    var quickCreateVisibility: ProjectSidebarQuickCreateVisibility = .automatic

    @State private var isHovering = false
    @FocusState private var focusedAction: FocusTarget?

    private enum FocusTarget: Hashable {
        case project
        case newTask
    }

    /// Keep the quick-create affordance in the row's layout even while it is
    /// quiet. That prevents the project title and task count from shifting
    /// under the pointer when the pointer enters the row. It becomes visible
    /// for both pointer hover and keyboard focus, while hit testing remains
    /// disabled until it is discoverable.
    private var showsNewTaskAction: Bool {
        ProjectSidebarHeaderPresentation.showsNewTaskAction(
            isHovering: isHovering,
            isFocused: focusedAction != nil,
            visibility: quickCreateVisibility
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleExpanded) {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 9)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isExpanded ? Color.secondary : Color.secondary.opacity(0.78))
                    Text(project.displayName)
                        .font(.system(size: OnyxTypography.navigation, weight: .medium))
                        .foregroundStyle(isExpanded ? OnyxTheme.strongText : OnyxTheme.quietText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(taskCount)")
                        .font(.system(size: OnyxTypography.metadata, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: OnyxHitTarget.compact, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onyxHelp(isExpanded ? "Collapse \(project.displayName)" : "Expand \(project.displayName)")
            .accessibilityLabel(project.displayName)
            .accessibilityValue(
                "\(isExpanded ? "Expanded" : "Collapsed"), \(taskCount) \(taskCount == 1 ? "task" : "tasks")"
            )
            .accessibilityHint(isExpanded ? "Collapses this project" : "Expands this project")
            .focused($focusedAction, equals: .project)

            Button(action: newTask) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(showsNewTaskAction ? 0.07 : 0))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsNewTaskAction ? 1 : 0)
            .allowsHitTesting(showsNewTaskAction)
            .focused($focusedAction, equals: .newTask)
            .onyxHelp("New task in \(project.displayName)")
            .accessibilityLabel("New task in \(project.displayName)")
            .accessibilityHint("Starts a blank task in this project")
            .animation(.easeOut(duration: 0.12), value: showsNewTaskAction)

            Menu {
                Button("New Task in \(project.displayName)", action: newTask)
                Divider()
                Button("Rename…", action: rename)
                Divider()
                Button("Move Up", action: moveUp)
                    .disabled(!canMoveUp)
                Button("Move Down", action: moveDown)
                    .disabled(!canMoveDown)
                Divider()
                Button("Remove from Onyx…", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5, weight: .bold))
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onyxHelp("Manage \(project.displayName)")
            .accessibilityLabel("Manage \(project.displayName)")
            .accessibilityHint("Create a task, rename, reorder, or remove this project")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 9)
        .padding(.trailing, 2)
        .padding(.bottom, 3)
        .onHover { isHovering = $0 }
    }
}

/// Presentation rules for the project-row quick-create affordance live in a
/// small value type so interaction geometry can be regression-tested without
/// needing to depend on SwiftUI's transient hover state.
enum ProjectSidebarHeaderPresentation {
    static let newTaskHitTarget: CGFloat = OnyxHitTarget.compact

    static func showsNewTaskAction(
        isHovering: Bool,
        isFocused: Bool,
        visibility: ProjectSidebarQuickCreateVisibility = .automatic
    ) -> Bool {
        visibility == .visible || isHovering || isFocused
    }
}

/// Normal app rows follow hover/focus. Snapshot and hosted pointer tests can
/// pin the action visible so they exercise the exact hit region without
/// synthesizing process-global pointer movement.
enum ProjectSidebarQuickCreateVisibility {
    case automatic
    case visible
}

private struct TaskSidebarRow: View {
    let thread: RuntimeThread
    let attention: RuntimeTaskAttention
    let isSelected: Bool
    let isArchived: Bool
    let providerName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            statusIndicator
                .frame(width: 12, height: 14)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(thread.title)
                        .font(.system(size: OnyxTypography.navigation, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? OnyxTheme.strongText : OnyxTheme.readingText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !isArchived, attention.showsSidebarAttentionLabel {
                        Text(attention.label)
                            .font(.system(size: OnyxTypography.metadata, weight: .semibold))
                            .foregroundStyle(attention.sidebarColor)
                            .lineLimit(1)
                    } else {
                        Text(TaskSidebarTimestamp.compact(thread.updatedAt))
                            .font(.system(size: OnyxTypography.metadata))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 5) {
                    if thread.isPinned && !isArchived {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(OnyxTheme.iris.opacity(0.78))
                            .accessibilityHidden(true)
                    }
                    if let providerName {
                        Text(providerName)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        if previewText != nil {
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let previewText {
                        Text(previewText)
                            .foregroundStyle(
                                isSelected
                                    ? Color.secondary
                                    : Color.secondary.opacity(0.72)
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: OnyxTypography.metadata))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OnyxTheme.iris.opacity(0.09))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(OnyxTheme.iris)
                            .frame(width: 2)
                            .padding(.vertical, 6)
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var previewText: String? {
        let preview = thread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty,
              preview.caseInsensitiveCompare(title) != .orderedSame else { return nil }
        return preview
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isArchived {
            Image(systemName: "archivebox")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(isSelected ? OnyxTheme.iris : Color.secondary.opacity(0.55))
                .frame(width: 9, height: 9)
        } else {
            switch attention {
            case .working:
                ProgressView().controlSize(.mini).tint(OnyxTheme.electric).frame(width: 9, height: 9)
            case .needsInput, .needsApproval:
                Image(systemName: attention.sidebarStatusSymbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(attention.sidebarColor)
                    .frame(width: 9, height: 9)
            case .failed:
                Image(systemName: attention.sidebarStatusSymbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(OnyxTheme.destructive)
                    .frame(width: 9, height: 9)
            case .ready, .unknown:
                Circle().fill(isSelected ? OnyxTheme.iris : Color.secondary.opacity(0.28)).frame(width: 6, height: 6)
            }
        }
    }
}

extension RuntimeThreadStatus {
    var sidebarStatusSymbol: String {
        switch self {
        case .waitingForInput: "questionmark.circle.fill"
        case .waitingForApproval: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running: "circle.dotted"
        case .idle, .unknown: "circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Ready"
        case .running: "Working"
        case .waitingForInput: "Needs input"
        case .waitingForApproval: "Needs approval"
        case .failed: "Failed"
        case .unknown: "Status unknown"
        }
    }

    var sidebarTaskAttention: RuntimeTaskAttention {
        switch self {
        case .waitingForInput: .needsInput
        case .waitingForApproval: .needsApproval
        case .failed: .failed
        case .running: .working
        case .idle: .ready
        case .unknown: .unknown
        }
    }
}

extension RuntimeTaskAttention {
    var showsSidebarAttentionLabel: Bool {
        switch self {
        // The leading indicator already communicates routine work and failure.
        // Keep words only for states where the user needs to take an action or
        // where the indicator alone could be mistaken for a ready task;
        // repeating "Failed" beside a red failure icon crowds narrow rows and
        // recreates the detached debug-label problem from the transcript.
        case .needsInput, .needsApproval: true
        case .unknown: true
        case .working, .ready, .failed: false
        }
    }
}

enum TaskSidebarLiveSnapshotPolicy {
    static func shouldUseLiveSnapshot(
        hasAuthoritativeThreadList: Bool,
        hasUnlistedSelectedTask: Bool = false
    ) -> Bool {
        hasAuthoritativeThreadList && !hasUnlistedSelectedTask
    }
}

enum TaskSidebarContentState: Equatable {
    case loading
    case empty
    case content

    static func resolve(
        isProjectionReady: Bool,
        hasVisibleTasks: Bool,
        hasVisibleProjects: Bool,
        isLoadingThreadList: Bool
    ) -> Self {
        if hasVisibleTasks { return .content }
        if isLoadingThreadList { return .loading }
        if hasVisibleProjects { return .content }
        return isProjectionReady ? .empty : .content
    }
}

enum TaskSidebarProjectDisclosure {
    static func shouldExpandResolvedSelection(
        _ selectedProjectID: ProjectID?,
        after previousProjectID: ProjectID?
    ) -> Bool {
        guard let selectedProjectID else { return false }
        return selectedProjectID != previousProjectID
    }

    static func defaultExpandedProjectIDs(
        selectedProjectID: ProjectID?
    ) -> Set<ProjectID> {
        guard let selectedProjectID else { return [] }
        return [selectedProjectID]
    }

    static func expandedProjectIDs(
        revealing selectedProjectID: ProjectID?,
        within expandedProjectIDs: Set<ProjectID>
    ) -> Set<ProjectID> {
        guard let selectedProjectID else { return expandedProjectIDs }
        var result = expandedProjectIDs
        result.insert(selectedProjectID)
        return result
    }

    static func isExpanded(
        _ projectID: ProjectID,
        expandedProjectIDs: Set<ProjectID>,
        searchText: String
    ) -> Bool {
        let isSearching = !searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return isSearching || expandedProjectIDs.contains(projectID)
    }

    static func mayToggle(searchText: String) -> Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A deliberately short timestamp for the task list. SwiftUI's `.relative`
/// style is useful in prose, but can produce long compound strings (for
/// example, "4 mths, 20 days ago") that overwhelm a narrow sidebar row.
enum TaskSidebarTimestamp {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * minute
    private static let day: TimeInterval = 24 * hour
    private static let week: TimeInterval = 7 * day
    private static let month: TimeInterval = 30 * day
    private static let year: TimeInterval = 365 * day

    static func compact(
        _ date: Date,
        relativeTo now: Date = .now
    ) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval.isFinite else { return "—" }

        let future = interval < 0
        let magnitude = abs(interval)
        if magnitude < minute {
            return "now"
        }

        let unit: (seconds: TimeInterval, suffix: String)
        switch magnitude {
        case ..<hour: unit = (minute, "m")
        case ..<day: unit = (hour, "h")
        case ..<week: unit = (day, "d")
        case ..<month: unit = (week, "w")
        case ..<year: unit = (month, "mo")
        default: unit = (year, "y")
        }

        let value = max(1, Int(magnitude / unit.seconds))
        return future ? "in \(value)\(unit.suffix)" : "\(value)\(unit.suffix)"
    }

    static func accessibilityDescription(
        for date: Date,
        relativeTo now: Date = .now
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private extension RuntimeTaskAttention {
    var sidebarStatusSymbol: String {
        switch self {
        case .needsInput: "questionmark.circle.fill"
        case .needsApproval: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .working: "circle.dotted"
        case .ready, .unknown: "circle.fill"
        }
    }

    var sidebarColor: Color {
        switch self {
        case .needsInput: OnyxTheme.iris
        case .needsApproval: OnyxTheme.warning
        case .working: OnyxTheme.electric
        case .failed: OnyxTheme.destructive
        case .ready, .unknown: .secondary
        }
    }
}
