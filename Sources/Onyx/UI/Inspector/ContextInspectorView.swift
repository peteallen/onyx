import AppKit
import SwiftUI

struct ContextInspectorView: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(InspectorTab.allCases) { tab in
                    Button {
                        model.inspectorTab = tab
                    } label: {
                        Label(tab.label, systemImage: tab.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(model.inspectorTab == tab ? OnyxTheme.raisedSurface : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.inspectorTab == tab ? .isSelected : [])
                    .accessibilityHint("Shows the \(tab.label.lowercased()) section")
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 13)
            .padding(.bottom, 9)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context panel sections")

            Divider().overlay(OnyxTheme.border)

            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case .summary:
                        SummaryInspector(model: model)
                    case .files:
                        FilesInspector(model: model)
                    case .review:
                        GitDiffViewerView(model: model)
                    }
                }
                .padding(12)
            }
        }
        .background(OnyxTheme.sidebar)
    }
}

private struct SummaryInspector: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorSection(title: "Task", icon: "checklist") {
                LabeledContent("Status", value: model.selectedTaskAttention.label)
                LabeledContent("Runtime", value: "Codex")
                LabeledContent("Model", value: model.selectedModelName)
                LabeledContent("Reasoning", value: model.selectedReasoningEffortName)
            }

            if let plan = model.selectedPlan {
                InspectorSection(title: "Plan", icon: "list.bullet.rectangle") {
                    if let explanation = plan.explanation {
                        Text(explanation)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: planSymbol(for: step.status))
                                .foregroundStyle(planColor(for: step.status))
                                .accessibilityHidden(true)
                            Text(step.text)
                                .font(.system(size: 11))
                                .foregroundStyle(step.status == .completed ? .secondary : .primary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(planStatusLabel(for: step.status)): \(step.text)")
                    }
                }
            } else {
                let plans = model.timeline.filter { $0.kind == .plan }
                if let lastPlan = plans.last {
                    InspectorSection(title: "Plan", icon: "list.bullet.rectangle") {
                        Text(lastPlan.body)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !model.collaborationAgents.isEmpty {
                InspectorSection(title: "Agents", icon: "person.2") {
                    let liveCount = model.collaborationAgents.filter { $0.status.isLive }.count
                    LabeledContent("Live", value: "\(liveCount)")
                    LabeledContent("Known", value: "\(model.collaborationAgents.count)")
                    ForEach(model.collaborationAgents.prefix(6)) { agent in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(agentColor(for: agent.status))
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.displayName)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let message = agent.message, !message.isEmpty {
                                    Text(message)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(agent.status.label)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(agentColor(for: agent.status))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(agent.displayName), \(agent.status.label)")
                    }
                    if model.collaborationAgents.count > 6 {
                        Text("\(model.collaborationAgents.count - 6) more agents")
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            InspectorSection(title: "Changes", icon: "arrow.triangle.branch") {
                let changes = model.timeline.filter { $0.kind == .fileChange }
                LabeledContent("Files touched", value: "\(changes.count)")
                LabeledContent("Branch", value: model.selectedThread?.branch ?? "Current checkout")
            }

            InspectorSection(title: "Environment", icon: "shippingbox") {
                Text(model.selectedThread?.cwd ?? model.draftWorkspacePath ?? "No project selected")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                LabeledContent("Permissions", value: model.permissionLabel)
            }
        }
    }

    private func planSymbol(for status: RuntimePlanStepStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func planColor(for status: RuntimePlanStepStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .inProgress: OnyxTheme.electric
        case .completed: OnyxTheme.iris
        case .unknown: .secondary
        }
    }

    private func planStatusLabel(for status: RuntimePlanStepStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .unknown: "Unknown"
        }
    }

    private func agentColor(for status: RuntimeCollaborationAgentStatus) -> Color {
        switch status {
        case .starting, .working: OnyxTheme.electric
        case .completed: OnyxTheme.iris
        case .failed: OnyxTheme.destructive
        case .interrupted: OnyxTheme.warning
        case .stopped, .unavailable, .unknown: .secondary
        }
    }
}

private struct FilesInspector: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    @StateObject private var fileTree = ProjectFileTreeModel()
    @StateObject private var sourceNavigator = ProjectSourceNavigatorModel()

    private var projectPath: String? {
        model.selectedThread?.cwd ?? model.draftWorkspacePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").foregroundStyle(OnyxTheme.iris)
                Text(projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose project")
                    .fontWeight(.semibold)
                Spacer(minLength: 6)
                if let projectPath {
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task {
                                await fileTree.loadRoot(path: projectPath)
                                await sourceNavigator.loadRoot(path: projectPath)
                            }
                        }
                        Button("Open in Finder", systemImage: "folder") {
                            openProjectFolder(projectPath)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Project actions")
                    .accessibilityLabel("Project actions")
                }
            }
            .font(.system(size: 12.5))
            .padding(.bottom, 5)

            if isPreviewPresented {
                sourcePreviewContent
            } else {
                if projectPath != nil {
                    quickOpenField
                }

                if sourceNavigator.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fileTreeContent

                    let touched = model.timeline.filter { $0.kind == .fileChange }
                    if !touched.isEmpty {
                        Divider().padding(.vertical, 7)
                        Text("TOUCHED THIS TASK")
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                        ForEach(touched) { item in
                            FileTreeRow(icon: "doc.badge.ellipsis", name: item.title ?? "Changed file", depth: 0)
                        }
                    }
                } else {
                    quickOpenResults
                }
            }
        }
        .task(id: projectPath) {
            await fileTree.loadRoot(path: projectPath)
        }
        .task(id: projectPath) {
            await sourceNavigator.loadRoot(path: projectPath)
        }
    }

    private var isPreviewPresented: Bool {
        switch sourceNavigator.previewState {
        case .none: false
        case .loading, .loaded, .failed: true
        }
    }

    private var quickOpenField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Quick Open", text: $sourceNavigator.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .onSubmit {
                    guard let firstMatch = sourceNavigator.searchResults.first else { return }
                    Task { await sourceNavigator.preview(firstMatch) }
                }

            if case .loading = sourceNavigator.indexState {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Indexing project files")
            } else if !sourceNavigator.query.isEmpty {
                Button {
                    sourceNavigator.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear file search")
                .accessibilityLabel("Clear file search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 29)
        .background(OnyxTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
        }
        .padding(.bottom, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick open project file")
    }

    @ViewBuilder
    private var quickOpenResults: some View {
        switch sourceNavigator.indexState {
        case .noProject:
            EmptyView()
        case .loading:
            compactState(
                title: "Finding project files",
                detail: "Search results will appear when the project index is ready.",
                icon: "magnifyingglass"
            )
        case let .failed(message):
            compactState(title: "Could not search files", detail: message, icon: "exclamationmark.triangle") {
                Button("Try Again") {
                    Task { await sourceNavigator.loadRoot(path: projectPath) }
                }
                .controlSize(.small)
            }
        case .loaded:
            let results = sourceNavigator.searchResults
            if results.isEmpty {
                compactState(
                    title: "No matching files",
                    detail: "Try part of a filename or folder path.",
                    icon: "doc.text.magnifyingglass"
                )
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { file in
                        Button {
                            Task { await sourceNavigator.preview(file) }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "doc.text")
                                    .frame(width: 13)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if file.relativePath != file.name {
                                        Text(file.relativePath)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 30)
                        .accessibilityLabel("Preview \(file.relativePath)")
                    }

                    if sourceNavigator.indexWasTruncated {
                        Text("Results are limited to keep search responsive.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
                .font(.system(size: 11.5))
            }
        }
    }

    @ViewBuilder
    private var sourcePreviewContent: some View {
        switch sourceNavigator.previewState {
        case .none:
            EmptyView()
        case let .loading(name):
            sourcePreviewHeader(title: name)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading preview…")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading preview for \(name)")
        case let .failed(message):
            sourcePreviewHeader(title: "Preview unavailable")
            compactState(title: "Could not preview file", detail: message, icon: "doc.badge.ellipsis")
        case let .loaded(preview):
            sourcePreviewHeader(title: preview.file.name, preview: preview)
            Text(preview.file.relativePath)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.bottom, 5)

            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.lines) { line in
                        SourcePreviewLineView(line: line)
                    }
                }
            }
            .background(OnyxTheme.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
            }
            .accessibilityLabel("Source preview")

            if preview.wasTruncated {
                Label("Preview shortened to keep the inspector responsive.", systemImage: "ellipsis")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func sourcePreviewHeader(
        title: String,
        preview: ProjectSourcePreview? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                sourceNavigator.clearPreview()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Back to project files")
            .accessibilityLabel("Back to project files")

            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            if let preview {
                Button {
                    openSourceFile(preview.file.path)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Open in default app")
                .accessibilityLabel("Open \(preview.file.name) in default app")

                Button {
                    revealSourceFile(preview.file.path)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(preview.file.name) in Finder")
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var fileTreeContent: some View {
        switch fileTree.rootState {
        case .noProject:
            compactState(
                title: "No project selected",
                detail: "Choose a project to browse its files.",
                icon: "folder.badge.questionmark"
            ) {
                Button("Choose Project") {
                    model.chooseWorkspace(window: windowPresentation.window)
                }
                    .controlSize(.small)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading project files…")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading project files")
        case .empty:
            compactState(
                title: "Empty project",
                detail: "This folder does not contain any visible files.",
                icon: "folder"
            )
        case let .failed(message):
            compactState(title: "Could not load files", detail: message, icon: "exclamationmark.triangle") {
                Button("Try Again") {
                    Task { await fileTree.loadRoot(path: projectPath) }
                }
                .controlSize(.small)
            }
        case .loaded:
            ForEach(fileTree.rows) { row in
                switch row {
                case let .entry(entry, depth):
                    ProjectFileRow(
                        entry: entry,
                        depth: depth,
                        isExpanded: fileTree.expandedDirectories.contains(entry.path),
                        onToggle: {
                            Task { await fileTree.toggleDirectory(entry) }
                        },
                        onPreview: {
                            Task {
                                await sourceNavigator.preview(path: entry.path, displayName: entry.name)
                            }
                        },
                        onOpen: { openEntry(entry) },
                        onReveal: { revealEntry(entry) }
                    )
                case let .loading(_, depth):
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Loading…")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, CGFloat(depth) * 13 + 19)
                    .frame(height: 23)
                case let .failure(parentPath, message, depth):
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(message).lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Retry") {
                            Task { await fileTree.retryDirectory(parentPath) }
                        }
                        .buttonStyle(.link)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, CGFloat(depth) * 13)
                    .padding(.vertical, 3)
                case let .truncated(_, depth):
                    Text("More items are hidden to keep the file browser responsive.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth) * 13 + 19)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func compactState<Actions: View>(
        title: String,
        detail: String,
        icon: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func compactState(title: String, detail: String, icon: String) -> some View {
        compactState(title: title, detail: detail, icon: icon) { EmptyView() }
    }

    private func openProjectFolder(_ path: String) {
        guard let root = try? WorkspacePathSafety.resolveRoot(path) else { return }
        NSWorkspace.shared.open(root.canonicalURL)
    }

    private func openEntry(_ entry: ProjectFileEntry) {
        guard let projectPath,
              let url = try? WorkspacePathSafety.resolveExistingURL(
                at: entry.path,
                insideRoot: projectPath
              ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealEntry(_ entry: ProjectFileEntry) {
        guard let projectPath,
              let url = try? WorkspacePathSafety.resolveExistingURL(
                at: entry.path,
                insideRoot: projectPath
              ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openSourceFile(_ path: String) {
        guard let projectPath,
              let url = try? WorkspacePathSafety.resolveExistingURL(at: path, insideRoot: projectPath)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealSourceFile(_ path: String) {
        guard let projectPath,
              let url = try? WorkspacePathSafety.resolveExistingURL(at: path, insideRoot: projectPath)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct ProjectFileRow: View {
    let entry: ProjectFileEntry
    let depth: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if entry.isDirectory {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse folder" : "Expand folder")
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(entry.name)")
                .accessibilityHint("Changes which files are shown")
            } else {
                Color.clear.frame(width: 12, height: 20)
            }

            if entry.kind == .file {
                Button(action: onPreview) {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .frame(width: 13)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Preview \(entry.name)")
            } else {
                Image(systemName: icon)
                    .frame(width: 13)
                    .foregroundStyle(entry.isDirectory ? OnyxTheme.iris : .secondary)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)

            Menu {
                if entry.kind == .file {
                    Button("Preview", systemImage: "doc.text.magnifyingglass", action: onPreview)
                }
                Button(entry.isDirectory ? "Open in Finder" : "Open", systemImage: "arrow.up.forward.app", action: onOpen)
                Button("Reveal in Finder", systemImage: "folder", action: onReveal)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("File actions")
            .accessibilityLabel("Actions for \(entry.name)")
        }
        .font(.system(size: 11.5))
        .padding(.leading, CGFloat(depth) * 13)
        .frame(height: 23)
        .contextMenu {
            if entry.kind == .file {
                Button("Preview", action: onPreview)
            }
            Button(entry.isDirectory ? "Open in Finder" : "Open", action: onOpen)
            Button("Reveal in Finder", action: onReveal)
        }
    }

    private var icon: String {
        switch entry.kind {
        case .directory: isExpanded ? "folder.fill" : "folder"
        case .file: "doc"
        case .symbolicLink: "link"
        }
    }
}

private struct SourcePreviewLineView: View {
    let line: ProjectSourcePreviewLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(line.number)")
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 7)
                .accessibilityHidden(true)
            Rectangle()
                .fill(OnyxTheme.border)
                .frame(width: OnyxTheme.hairline)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .frame(minHeight: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(line.number): \(line.text)")
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                content
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .onyxPanel(radius: 11)
    }
}

private struct FileTreeRow: View {
    let icon: String
    let name: String
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 13)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .padding(.leading, CGFloat(depth) * 13)
        .frame(height: 23)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}
