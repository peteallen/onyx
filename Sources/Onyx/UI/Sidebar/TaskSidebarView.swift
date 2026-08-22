import SwiftUI

struct TaskSidebarView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    var searchFocusRequest = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            scopePicker
            projectCard

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    let pinned = model.isShowingArchivedThreads ? [] : model.visibleThreads.filter(\.isPinned)
                    let recent = model.isShowingArchivedThreads ? model.visibleThreads : model.visibleThreads.filter { !$0.isPinned }

                    if !pinned.isEmpty {
                        SidebarSectionLabel(title: "Pinned", count: pinned.count)
                        ForEach(pinned) { thread in threadRow(thread) }
                    }

                    if !recent.isEmpty {
                        SidebarSectionLabel(
                            title: model.isShowingArchivedThreads ? "Archived" : "Recent",
                            count: recent.count
                        )
                            .padding(.top, 9)
                        ForEach(recent) { thread in threadRow(thread) }
                    }

                    if model.visibleThreads.isEmpty, !model.isLoadingThreadList {
                        sidebarEmptyState
                    }
                }
                .padding(.horizontal, 9)
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
        .background(.ultraThinMaterial)
        .background(OnyxTheme.sidebar.opacity(0.92))
        .overlay(alignment: .trailing) {
            Rectangle().fill(OnyxTheme.border).frame(width: OnyxTheme.hairline)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ONYX")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.7)
                Text("Agent workspace")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.newTask) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(OnyxTheme.accentGradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("New task (⌘N)")
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
        .background(OnyxTheme.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
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
        Button(action: { model.chooseWorkspace(window: windowPresentation.window) }) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(OnyxTheme.raisedSurface)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OnyxTheme.iris)
                }
                .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(model.selectedThreadID == "onyx:welcome"
                        ? (model.draftWorkspacePath ?? "Choose a local folder")
                        : (model.selectedThread?.branch ?? "Local workspace"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace")
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityHint("Opens the folder chooser")
        .padding(.horizontal, 12)
        .padding(.bottom, 13)
    }

    private var scopePicker: some View {
        Picker(
            "Task list",
            selection: Binding(
                get: { model.threadListScope },
                set: { model.setThreadListScope($0) }
            )
        ) {
            ForEach(ThreadListScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .disabled(!isConnected)
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
            : (model.selectedThread?.branch ?? "Local workspace")
        return "\(model.projectName), \(location)"
    }

    @ViewBuilder
    private func threadRow(_ thread: RuntimeThread) -> some View {
        Button {
            model.selectThread(thread.id)
        } label: {
            TaskSidebarRow(
                thread: thread,
                attention: model.taskAttention(for: thread),
                isSelected: model.selectedThreadID == thread.id,
                isArchived: model.isShowingArchivedThreads
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thread.title)
        .accessibilityValue(threadAccessibilityValue(thread, isArchived: model.isShowingArchivedThreads))
        .accessibilityHint(model.selectedThreadID == thread.id ? "Selected task" : "Selects this task")
        .accessibilityAddTraits(model.selectedThreadID == thread.id ? .isSelected : [])
        .contextMenu {
            if model.isShowingArchivedThreads {
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

    private func threadAccessibilityValue(_ thread: RuntimeThread, isArchived: Bool) -> String {
        var details: [String] = []
        if thread.isPinned { details.append("Pinned") }
        details.append(isArchived ? "Archived" : model.taskAttention(for: thread).label)
        if !thread.preview.isEmpty { details.append(thread.preview) }
        return details.joined(separator: ". ")
    }
}

private struct SidebarSectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
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

private struct TaskSidebarRow: View {
    let thread: RuntimeThread
    let attention: RuntimeTaskAttention
    let isSelected: Bool
    let isArchived: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIndicator
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
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
                    Text(thread.preview)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(thread.updatedAt, style: .relative)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(OnyxTheme.raisedSurface.opacity(0.78))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(OnyxTheme.accentGradient)
                            .frame(width: 2.5)
                            .padding(.vertical, 7)
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
