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

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            projectCard
            scopePicker

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    projectListHeader

                    ForEach(displayedProjectGroups) { group in
                        projectHeader(group)
                            .padding(.top, 5)
                        if group.tasks.isEmpty {
                            Text("No tasks yet")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(group.tasks) { task in threadRow(task) }
                        }
                    }

                    if !sidebarGrouping.unassigned.isEmpty {
                        SidebarSectionLabel(
                            title: projectCatalog.projects.isEmpty
                                ? (model.isShowingArchivedThreads ? "Archived" : "Tasks")
                                : "Other Tasks",
                            count: sidebarGrouping.unassigned.count
                        )
                        .padding(.top, displayedProjectGroups.isEmpty ? 4 : 10)
                        ForEach(sidebarGrouping.unassigned) { task in threadRow(task) }
                    }

                    if sidebarGrouping.taskCount == 0,
                       displayedProjectGroups.isEmpty,
                       !model.isLoadingThreadList {
                        sidebarEmptyState
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
            .overlay(alignment: .top) {
                if model.isLoadingThreadList {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 20)
                        .accessibilityLabel("Loading tasks")
                }
            }
        }
        .background(OnyxTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(OnyxTheme.border).frame(width: OnyxTheme.hairline)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Onyx")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            Button(action: model.newTask) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 27, height: 27)
                    .background(Color.primary.opacity(0.055))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
                    }
            }
            .buttonStyle(.plain)
            .onyxHelp("New task (⌘N)")
            .accessibilityLabel("New task")
            .accessibilityHint("Creates a new task")
        }
        .frame(height: 50)
        .padding(.horizontal, 13)
        .padding(.top, 2)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11.5, weight: .medium))
            TextField("Search tasks", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isSearchFocused)
                .accessibilityLabel("Search tasks")
                .accessibilityHint("Filters the task list as you type")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear task search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 31)
        .background(OnyxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
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

    private var projectCard: some View {
        Menu {
            ForEach(projectCatalog.projects) { project in
                Button {
                    model.selectWorkspace(project.folderPath)
                } label: {
                    Label(project.displayName, systemImage: "folder")
                }
            }
            if !projectCatalog.projects.isEmpty {
                Divider()
            }
            Button(action: beginImportProject) {
                Label("Add Project…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(model.selectedThreadID == "onyx:welcome"
                        ? (model.draftWorkspacePath ?? "Choose a local folder")
                        : (model.selectedThread?.cwd ?? "Local workspace"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace")
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityHint("Chooses an imported project or adds a folder")
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }

    private var projectListHeader: some View {
        HStack(spacing: 6) {
            Text("Projects")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            if projectCatalog.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Loading projects")
            }
            Button(action: beginImportProject) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onyxHelp("Add a project folder")
            .accessibilityLabel("Add project")
            .accessibilityHint("Opens a folder chooser; you can also create a new folder there")
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 2)
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(ThreadListScope.allCases) { scope in
                Button {
                    model.setThreadListScope(scope)
                } label: {
                    Text(scope.label)
                        .font(.system(size: 10.5, weight: model.threadListScope == scope ? .semibold : .medium))
                        .foregroundStyle(model.threadListScope == scope ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if model.threadListScope == scope {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.075))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.threadListScope == scope ? .isSelected : [])
                .accessibilityLabel(scope.label)
                .accessibilityHint("Shows (scope.label.lowercased()) tasks")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
        .disabled(!isConnected)
        .opacity(isConnected ? 1 : 0.55)
        .accessibilityLabel("Task list")
        .accessibilityHint("Choose active or archived tasks")
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isShowingArchivedThreads ? "archivebox" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(model.searchText.isEmpty ? "No archived tasks" : "No matching tasks")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    private var isConnected: Bool {
        if case .connected = model.connectionState { return true }
        return false
    }

    private var workspaceAccessibilityValue: String {
        let location = model.selectedThreadID == "onyx:welcome"
            ? (model.draftWorkspacePath ?? "No folder selected")
            : (model.selectedThread?.cwd ?? "Local workspace")
        return "\(model.projectName), \(location)"
    }

    private var providerDisplayName: String {
        providerConnections.first(where: { $0.id == providerConnectionID })?.displayName
            ?? (providerConnectionID == .codexDefault ? "Codex" : "Provider")
    }

    private var sidebarGrouping: ProjectTaskGrouping {
        var references = projectCatalog.taskReferences(for: model.threadListScope)
        if let welcome = model.visibleThreads.first(where: { $0.id == "onyx:welcome" }) {
            var projected = welcome
            projected.cwd = model.draftWorkspacePath
            references.append(ProjectTaskReference(
                providerConnectionID: providerConnectionID,
                providerDisplayName: providerDisplayName,
                thread: projected
            ))
        }
        return ProjectTaskSidebarProjection.group(
            references,
            by: projectCatalog.projects,
            searchText: model.searchText
        )
    }

    private var displayedProjectGroups: [ProjectTaskGroup] {
        if model.isShowingArchivedThreads || !model.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sidebarGrouping.groups.filter { !$0.tasks.isEmpty }
        }
        return sidebarGrouping.groups
    }

    private func projectHeader(_ group: ProjectTaskGroup) -> some View {
        ProjectSidebarHeader(
            project: group.project,
            taskCount: group.tasks.count,
            canMoveUp: projectCatalog.canMoveProject(id: group.id, offset: -1),
            canMoveDown: projectCatalog.canMoveProject(id: group.id, offset: 1),
            select: { model.selectWorkspace(group.project.folderPath) },
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
        }
        .buttonStyle(.plain)
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
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
            Spacer()
            Text("\(count)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 7)
        .padding(.bottom, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "task" : "tasks")")
    }
}

private struct ProjectSidebarHeader: View {
    let project: ProjectCatalogRecord
    let taskCount: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let select: () -> Void
    let rename: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(project.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(taskCount)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onyxHelp("Start a new task in \(project.folderPath)")
            .accessibilityLabel(project.displayName)
            .accessibilityValue("\(taskCount) \(taskCount == 1 ? "task" : "tasks")")
            .accessibilityHint("Starts a new task in this project")

            Menu {
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
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onyxHelp("Manage \(project.displayName)")
            .accessibilityLabel("Manage \(project.displayName)")
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .padding(.bottom, 2)
    }
}

private struct TaskSidebarRow: View {
    let thread: RuntimeThread
    let attention: RuntimeTaskAttention
    let isSelected: Bool
    let isArchived: Bool
    let providerName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIndicator
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(thread.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !isArchived {
                        Text(attention.label)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(attention.sidebarColor)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    if thread.isPinned && !isArchived {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(OnyxTheme.iris.opacity(0.78))
                            .accessibilityHidden(true)
                    }
                    Text(thread.preview)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let providerName {
                        Text(providerName)
                            .lineLimit(1)
                    }
                    Text(thread.updatedAt, style: .relative)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
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
