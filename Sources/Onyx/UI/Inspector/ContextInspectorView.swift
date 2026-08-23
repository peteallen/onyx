import AppKit
import SwiftUI

struct ContextInspectorView: View {
    @ObservedObject var model: OnyxAppModel
    @State private var summaryContentHeight: CGFloat = 0

    private let summaryMaximumHeight: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            inspectorTabBar

            inspectorContent
        }
        // The pane owns the canvas/background.  Keeping this view transparent
        // lets the summary surface size itself to its content instead of
        // painting a full-height rounded dashboard when the task has little
        // context to show.
        .background(Color.clear)
        .onChange(of: model.selectedThreadID) { _, _ in
            summaryContentHeight = 0
        }
    }

    private var inspectorTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(InspectorTab.allCases) { tab in
                    Button {
                        model.inspectorTab = tab
                    } label: {
                        Label(tab.label, systemImage: tab.icon)
                            .font(.system(size: 11.5, weight: model.inspectorTab == tab ? .medium : .regular))
                            .foregroundStyle(
                                model.inspectorTab == tab
                                    ? Color.primary
                                    : OnyxTheme.inactiveControlText
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 31)
                            .background {
                                if model.inspectorTab == tab {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.065))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.inspectorTab == tab ? .isSelected : [])
                    .accessibilityHint("Shows the \(tab.label.lowercased()) section")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context panel sections")

            Divider()
                .overlay(OnyxTheme.divider)
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch model.inspectorTab {
        case .summary:
            summarySurface
        case .files:
            inspectorScrollableSurface {
                FilesInspector(model: model)
            }
        case .review:
            inspectorScrollableSurface {
                GitDiffViewerView(model: model)
            }
        }
    }

    /// A regular vertical ScrollView expands to the height proposed by its
    /// parent, even when its content is short. Measure the summary content in
    /// its unconstrained scroll axis and give the viewport only that height
    /// (up to a sensible cap) so a quiet task produces a compact card.
    private var summarySurface: some View {
        ScrollView {
            SummaryInspector(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: InspectorContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                    }
                }
        }
        .scrollIndicators(.hidden)
        .frame(height: summaryViewportHeight, alignment: .top)
        .background(OnyxTheme.inspector)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .onPreferenceChange(InspectorContentHeightPreferenceKey.self) { height in
            guard height.isFinite,
                  height > 0,
                  abs(height - summaryContentHeight) > 0.5 else { return }
            summaryContentHeight = height
        }
    }

    private var summaryViewportHeight: CGFloat {
        let measuredHeight = summaryContentHeight > 0 ? summaryContentHeight : 220
        return min(max(measuredHeight, 1), summaryMaximumHeight)
    }

    @ViewBuilder
    private func inspectorScrollableSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .background(OnyxTheme.inspector)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(10)
    }
}

private struct InspectorContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SummaryInspector: View {
    @ObservedObject var model: OnyxAppModel
    @State private var isTaskExpanded = false
    @State private var isPlanExpanded = false
    @State private var isAgentsExpanded = false
    @State private var isChangesExpanded = false
    @State private var isEnvironmentExpanded = false
    @State private var showsAllAgents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorDisclosureSection(
                title: "Task",
                icon: "checklist",
                summary: model.selectedTaskAttention.label,
                isExpanded: $isTaskExpanded,
                accessibilityHint: "Shows runtime and model details"
            ) {
                InspectorValueRow(label: "Runtime", value: model.runtimeDisplayName)
                InspectorValueRow(label: "Model", value: model.selectedModelName)
                InspectorValueRow(label: "Reasoning", value: model.selectedReasoningEffortName)
            }

            if let plan = model.selectedPlan {
                inspectorSectionDivider
                planSection(plan)
            } else {
                let plans = model.timeline.filter { $0.kind == .plan }
                if let lastPlan = plans.last {
                    inspectorSectionDivider
                    InspectorDisclosureSection(
                        title: "Plan",
                        icon: "list.bullet.rectangle",
                        summary: "Latest update",
                        isExpanded: $isPlanExpanded,
                        accessibilityHint: "Shows the latest plan update"
                    ) {
                        Text(lastPlan.body)
                            .font(.system(size: 11.5))
                            .foregroundStyle(OnyxTheme.quietText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Latest plan update: \(lastPlan.body)")
                    }
                }
            }

            if !model.collaborationAgents.isEmpty {
                inspectorSectionDivider
                agentsSection
            }

            inspectorSectionDivider
            changesSection

            inspectorSectionDivider
            environmentSection
        }
        .onAppear {
            resetDisclosureState()
        }
        .onChange(of: model.selectedThreadID) { _, _ in
            resetDisclosureState()
        }
    }

    private var changes: [TimelineItem] {
        model.timeline.filter { $0.kind == .fileChange }
    }

    private var workspacePath: String {
        model.selectedThread?.cwd ?? model.draftWorkspacePath ?? "No project selected"
    }

    @ViewBuilder
    private func planSection(_ plan: RuntimePlan) -> some View {
        InspectorDisclosureSection(
            title: "Plan",
            icon: "list.bullet.rectangle",
            summary: planSummary(for: plan),
            isExpanded: $isPlanExpanded,
            accessibilityHint: "Shows the task plan"
        ) {
            if let explanation = plan.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(OnyxTheme.quietText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.steps.isEmpty {
                Text("No plan steps yet")
                    .foregroundStyle(OnyxTheme.quietText)
            } else {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: planSymbol(for: step.status))
                            .foregroundStyle(planColor(for: step.status))
                            .accessibilityHidden(true)
                        Text(step.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(step.status == .completed ? OnyxTheme.quietText : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(planStatusLabel(for: step.status)): \(step.text)")
                }
            }
        }
    }

    private var agentsSection: some View {
        InspectorDisclosureSection(
            title: "Agents",
            icon: "person.2",
            summary: agentsSummary,
            isExpanded: $isAgentsExpanded,
            accessibilityHint: "Shows delegated agent tasks"
        ) {
            let visibleAgents = showsAllAgents
                ? model.collaborationAgents
                : Array(model.collaborationAgents.prefix(6))
            ForEach(visibleAgents) { agent in
                Button {
                    model.openCollaborationAgent(agent)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(agentColor(for: agent.status))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.displayName)
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            if let message = agent.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !message.isEmpty {
                                Text(message)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(OnyxTheme.quietText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(agent.status.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(agentColor(for: agent.status))
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.quaternary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .frame(minHeight: 30)
                }
                .buttonStyle(.plain)
                .disabled(agent.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .onyxHelp("Open agent task")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(agent.displayName), \(agent.status.label)")
                .accessibilityValue(agentAccessibilityValue(agent))
                .accessibilityHint(
                    agent.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No child conversation is available"
                        : "Opens this agent's conversation"
                )
            }
            if model.collaborationAgents.count > 6 {
                Button {
                    showsAllAgents.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Text(showsAllAgents ? "Show fewer agents" : "Show all agents")
                        Spacer(minLength: 4)
                        Image(systemName: showsAllAgents ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(OnyxTheme.quietText)
                    .contentShape(Rectangle())
                    .frame(minHeight: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAllAgents ? "Show fewer agents" : "Show all agents")
                .accessibilityValue(
                    showsAllAgents
                        ? "All \(model.collaborationAgents.count) agents visible"
                        : "\(model.collaborationAgents.count - visibleAgents.count) additional agents hidden"
                )
            }
        }
    }

    private var changesSection: some View {
        InspectorDisclosureSection(
            title: "Changes",
            icon: "arrow.triangle.branch",
            summary: changesSummary,
            isExpanded: $isChangesExpanded,
            accessibilityHint: "Shows file changes recorded for this task"
        ) {
            InspectorValueRow(
                label: "Branch",
                value: model.selectedThread?.branch ?? "Current checkout"
            )
            if changes.isEmpty {
                Text("No file changes recorded in this task")
                    .font(.system(size: 11))
                    .foregroundStyle(OnyxTheme.quietText)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes.prefix(4)) { change in
                        HStack(spacing: 7) {
                            Image(systemName: "doc.badge.ellipsis")
                                .font(.system(size: 10.5))
                                .foregroundStyle(OnyxTheme.quietText)
                                .accessibilityHidden(true)
                            Text(change.title ?? "Changed file")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(change.title ?? "Changed file")
                    }
                }
                if changes.count > 4 {
                    Text("More changes are available in Files and Review")
                        .font(.system(size: 10.5))
                        .foregroundStyle(OnyxTheme.quietText)
                }
                Button {
                    model.inspectorTab = .files
                } label: {
                    Label("Open Files", systemImage: "doc.on.doc")
                }
                .buttonStyle(.link)
                .font(.system(size: 10.5, weight: .medium))
                .accessibilityHint("Shows the project's files and task changes")
            }
        }
    }

    private var environmentSection: some View {
        InspectorDisclosureSection(
            title: "Environment",
            icon: "shippingbox",
            summary: workspaceSummary,
            isExpanded: $isEnvironmentExpanded,
            accessibilityHint: "Shows the selected workspace and access level"
        ) {
            InspectorPathRow(label: "Workspace", path: workspacePath)
            InspectorValueRow(label: "Permissions", value: model.permissionLabel)
        }
    }

    private var agentsSummary: String {
        let failed = model.collaborationAgents.filter { $0.status == .failed }.count
        let live = model.collaborationAgents.filter { $0.status.isLive }.count
        let completed = model.collaborationAgents.filter { $0.status == .completed }.count

        var parts: [String] = []
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        if live > 0 {
            parts.append("\(live) working")
        }
        if completed > 0 {
            parts.append("\(completed) done")
        }
        if parts.isEmpty {
            return "\(model.collaborationAgents.count) available"
        }
        return parts.prefix(2).joined(separator: " · ")
    }

    private var changesSummary: String {
        guard !changes.isEmpty else { return "No task changes" }
        return changes.count == 1 ? "1 file changed" : "\(changes.count) files changed"
    }

    private var workspaceSummary: String {
        guard workspacePath != "No project selected" else { return workspacePath }
        let name = URL(fileURLWithPath: workspacePath).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? model.permissionLabel : name
    }

    private func planSummary(for plan: RuntimePlan) -> String {
        if !plan.steps.isEmpty {
            let completed = plan.steps.filter { $0.status == .completed }.count
            return "\(completed) of \(plan.steps.count) complete"
        }
        return switch plan.timelineStatus {
        case .running: "In progress"
        case .completed: "Complete"
        case .pending: "Not started"
        case .failed: "Needs attention"
        case .declined: "Declined"
        }
    }

    private func agentAccessibilityValue(_ agent: RuntimeCollaborationAgent) -> String {
        [agent.path, agent.message]
            .compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ". ")
    }

    private func resetDisclosureState() {
        isTaskExpanded = false
        isPlanExpanded = false
        isAgentsExpanded = false
        isChangesExpanded = false
        isEnvironmentExpanded = false
        showsAllAgents = false
    }

    private var inspectorSectionDivider: some View {
        Divider()
            .overlay(OnyxTheme.divider)
            .padding(.horizontal, 2)
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
                    .onyxHelp("Project actions")
                    .accessibilityLabel("Project actions")
                }
            }
            .font(.system(size: 13))
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
                        Text("Touched this task")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(OnyxTheme.quietText)
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
                .onyxHelp("Clear file search")
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
                                        .foregroundStyle(Color.primary)
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
            .onyxHelp("Back to project files")
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
                .onyxHelp("Open in default app")
                .accessibilityLabel("Open \(preview.file.name) in default app")

                Button {
                    revealSourceFile(preview.file.path)
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .onyxHelp("Reveal in Finder")
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

struct ProjectFileRow: View {
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
                // The disclosure affordance and the folder name are one
                // interaction.  Previously only the 12-point chevron was a
                // button, which made a normal click on the folder label look
                // broken.  Keeping the trailing actions outside this button
                // preserves the row menu while making the whole leading area
                // a generous, discoverable toggle target.
                Button(action: onToggle) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .frame(width: 12, height: 20)
                        Image(systemName: icon)
                            .frame(width: 13)
                            .foregroundStyle(OnyxTheme.iris)
                            .accessibilityHidden(true)
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .onyxHelp(isExpanded ? "Collapse folder" : "Expand folder")
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(entry.name)")
                .accessibilityHint("Changes which files are shown")
            } else {
                Color.clear.frame(width: 12, height: 20)
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
                    .onyxHelp("Preview \(entry.name)")
                } else {
                    Image(systemName: icon)
                        .frame(width: 13)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
            .onyxHelp("File actions")
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
                .foregroundStyle(Color.primary)
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

/// A compact key/value row used by the summary pane. Keeping the value on the
/// same visual line makes the inspector read like a quiet status surface
/// instead of a stack of cards.
private struct InspectorValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .fontWeight(.medium)
                .foregroundStyle(OnyxTheme.quietText)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct InspectorPathRow: View {
    let label: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(OnyxTheme.quietText)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct InspectorDisclosureSection<Content: View>: View {
    let title: String
    let icon: String
    let summary: String
    @Binding var isExpanded: Bool
    let accessibilityHint: String
    @ViewBuilder let content: Content

    init(
        title: String,
        icon: String,
        summary: String,
        isExpanded: Binding<Bool>,
        accessibilityHint: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.summary = summary
        self._isExpanded = isExpanded
        self.accessibilityHint = accessibilityHint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Label(title, systemImage: icon)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 8)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(OnyxTheme.quietText)
                            .lineLimit(1)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(accessibilityHint)

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    content
                }
                .font(.system(size: 11.5))
                .foregroundStyle(OnyxTheme.quietText)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 11)
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
