import SwiftUI

struct OnyxWorkspaceView: View {
    @ObservedObject var model: OnyxAppModel
    @ObservedObject private var projectCatalog: ProjectCatalogModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var terminalSession = TerminalSessionModel()
    @State private var storedTerminalHeight: Double
    @State private var storedSidebarWidth: Double
    @State private var storedInspectorWidth: Double
    @State private var searchFocusRequest = 0
    @State private var isCompactLayout = false
    private let terminalHeightPreferenceKey: String
    private let sidebarWidthPreferenceKey: String
    private let inspectorWidthPreferenceKey: String
    private let defaults: UserDefaults
    private let windowProvider: @MainActor () -> NSWindow?
    private let providerConnections: [OnyxApplicationHost.WorkspaceConnection]
    private let selectedProviderConnectionID: ProviderConnectionID
    private let onSelectProviderConnection: @MainActor (ProviderConnectionID) -> Void
    private let rankedModelChoices: [OnyxApplicationHost.ProviderModelChoice]
    private let onSelectProviderModel: @MainActor (OnyxApplicationHost.ProviderModelChoice) -> Void
    private let onSelectProviderTask: @MainActor (ProviderConnectionID, String) -> Void

    init(
        model: OnyxAppModel,
        preferenceKeyPrefix: String? = nil,
        defaults: UserDefaults = .standard,
        projectCatalog: ProjectCatalogModel = ProjectCatalogModel(),
        windowProvider: @escaping @MainActor () -> NSWindow? = { nil },
        providerConnections: [OnyxApplicationHost.WorkspaceConnection] = [],
        selectedProviderConnectionID: ProviderConnectionID = .codexDefault,
        onSelectProviderConnection: @escaping @MainActor (ProviderConnectionID) -> Void = { _ in },
        rankedModelChoices: [OnyxApplicationHost.ProviderModelChoice] = [],
        onSelectProviderModel: @escaping @MainActor (OnyxApplicationHost.ProviderModelChoice) -> Void = { _ in },
        onSelectProviderTask: @escaping @MainActor (ProviderConnectionID, String) -> Void = { _, _ in }
    ) {
        self.model = model
        self.projectCatalog = projectCatalog
        let namespace = OnyxPreferenceNamespace(prefix: preferenceKeyPrefix)
        let key = namespace.key("Onyx.terminalHeight")
        terminalHeightPreferenceKey = key
        sidebarWidthPreferenceKey = namespace.key(WorkspacePaneLayout.sidebarWidthPreferenceSuffix)
        inspectorWidthPreferenceKey = namespace.key(WorkspacePaneLayout.inspectorWidthPreferenceSuffix)
        self.defaults = defaults
        self.windowProvider = windowProvider
        self.providerConnections = providerConnections
        self.selectedProviderConnectionID = selectedProviderConnectionID
        self.onSelectProviderConnection = onSelectProviderConnection
        self.rankedModelChoices = rankedModelChoices
        self.onSelectProviderModel = onSelectProviderModel
        self.onSelectProviderTask = onSelectProviderTask
        let restored = defaults.object(forKey: key) as? NSNumber
        let restoredHeight = CGFloat(restored?.doubleValue ?? 238.0)
        _storedTerminalHeight = State(
            initialValue: Double(TerminalDrawerLayout.clampedHeight(restoredHeight))
        )

        let restoredSidebarWidth = defaults.object(forKey: sidebarWidthPreferenceKey) as? NSNumber
        let restoredInspectorWidth = defaults.object(forKey: inspectorWidthPreferenceKey) as? NSNumber
        _storedSidebarWidth = State(
            initialValue: Double(WorkspacePaneLayout.clampedStoredSidebarWidth(
                CGFloat(restoredSidebarWidth?.doubleValue ?? WorkspacePaneLayout.sidebarDefaultWidth)
            ))
        )
        _storedInspectorWidth = State(
            initialValue: Double(WorkspacePaneLayout.clampedStoredInspectorWidth(
                CGFloat(restoredInspectorWidth?.doubleValue ?? WorkspacePaneLayout.inspectorDefaultWidth)
            ))
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = WorkspacePaneLayout.isCompact(totalWidth: proxy.size.width)
            let showSidebar = WorkspacePaneLayout.isSidebarDisplayed(
                sidebarRequested: model.isSidebarVisible,
                inspectorVisible: model.isInspectorVisible,
                isCompact: isCompact
            )
            let inspectorWidthForSidebar = WorkspacePaneLayout.clampedStoredInspectorWidth(
                CGFloat(storedInspectorWidth)
            )
            let sidebarWidth = WorkspacePaneLayout.displayedSidebarWidth(
                storedWidth: CGFloat(storedSidebarWidth),
                totalWidth: proxy.size.width,
                inspectorVisible: model.isInspectorVisible,
                inspectorWidth: inspectorWidthForSidebar
            )
            let inspectorWidth = WorkspacePaneLayout.displayedInspectorWidth(
                storedWidth: CGFloat(storedInspectorWidth),
                totalWidth: proxy.size.width,
                sidebarVisible: showSidebar,
                sidebarWidth: sidebarWidth
            )

            HStack(spacing: 0) {
                if showSidebar {
                    TaskSidebarView(
                        model: model,
                        projectCatalog: projectCatalog,
                        providerConnectionID: selectedProviderConnectionID,
                        providerConnections: providerConnections,
                        onSelectTask: selectProviderTask,
                        onProjectFailure: presentProjectFailure,
                        searchFocusRequest: searchFocusRequest
                    )
                        .frame(width: sidebarWidth)
                        .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))

                    WorkspacePaneResizeHandle(
                        value: sidebarWidthBinding(
                            totalWidth: proxy.size.width,
                            inspectorVisible: model.isInspectorVisible,
                            inspectorWidth: inspectorWidthForSidebar
                        ),
                        label: "Resize task sidebar"
                    )
                }

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ConversationWorkspaceView(
                            model: model,
                            sidebarDisplayed: showSidebar,
                            onShowSidebar: {
                                toggleSidebar(sidebarDisplayed: showSidebar, isCompact: isCompact)
                            },
                            providerConnections: providerConnections,
                            selectedProviderConnectionID: selectedProviderConnectionID,
                            onSelectProviderConnection: onSelectProviderConnection,
                            rankedModelChoices: rankedModelChoices,
                            onSelectProviderModel: onSelectProviderModel
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)

                        if model.isInspectorVisible {
                            WorkspacePaneResizeHandle(
                                value: inspectorWidthBinding(
                                    totalWidth: proxy.size.width,
                                    sidebarVisible: showSidebar,
                                    sidebarWidth: sidebarWidth
                                ),
                                direction: .trailingPane,
                                label: "Resize context panel"
                            )
                            InspectorWorkspacePane(
                                model: model,
                                width: inspectorWidth
                            )
                                .frame(maxHeight: .infinity, alignment: .top)
                                .transition(reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity))
                        }
                    }

                    if model.isBottomPanelVisible {
                        Divider().overlay(OnyxTheme.border)
                        TerminalDrawerView(
                            model: model,
                            session: terminalSession,
                            height: Binding(
                                get: { CGFloat(storedTerminalHeight) },
                                set: {
                                    storedTerminalHeight = Double(TerminalDrawerLayout.clampedHeight($0))
                                    defaults.set(storedTerminalHeight, forKey: terminalHeightPreferenceKey)
                                }
                            )
                            )
                            .frame(height: CGFloat(storedTerminalHeight))
                            .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.isSidebarVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.isInspectorVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.isBottomPanelVisible)
            .onAppear { isCompactLayout = isCompact }
            .onChange(of: isCompact) { _, compact in isCompactLayout = compact }
        }
        .background(OnyxTheme.canvas)
        .environment(
            \.onyxWindowPresentationContext,
            OnyxWindowPresentationContext(windowProvider: windowProvider)
        )
        .task {
            projectCatalog.start(onFailure: presentProjectFailure)
            synchronizeProviderTasks()
        }
        .onChange(of: model.isLoadingThreadList) { _, _ in synchronizeProviderTasks() }
        .onChange(of: model.threadListScope) { _, _ in
            synchronizeProviderTasks()
        }
        .onChange(of: selectedProviderConnectionID) { _, _ in
            synchronizeProviderTasks()
        }
        .onChange(of: providerConnections) { _, connections in
            guard !connections.isEmpty else { return }
            projectCatalog.retainTaskLists(for: Set(connections.map(\.id)))
            synchronizeProviderTasks()
        }
        .focusedSceneValue(\.onyxTaskCommands, taskCommandContext)
        .focusedSceneValue(\.onyxWindowCommands, windowCommandContext)
        .alert(
            model.notice?.title ?? "Onyx",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.dismissNotice() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissNotice() }
        } message: {
            Text(model.notice?.detail ?? "")
        }
    }

    @MainActor
    private func selectProviderTask(_ connectionID: ProviderConnectionID, threadID: String) {
        if connectionID == selectedProviderConnectionID {
            model.selectThread(threadID)
        } else {
            onSelectProviderTask(connectionID, threadID)
        }
    }

    @MainActor
    private func toggleSidebar(sidebarDisplayed: Bool, isCompact: Bool) {
        let target = WorkspacePaneLayout.sidebarToggleTarget(
            sidebarDisplayed: sidebarDisplayed,
            inspectorVisible: model.isInspectorVisible,
            isCompact: isCompact
        )
        model.isInspectorVisible = target.inspectorVisible
        model.isSidebarVisible = target.sidebarRequested
    }

    private func sidebarWidthBinding(
        totalWidth: CGFloat,
        inspectorVisible: Bool,
        inspectorWidth: CGFloat
    ) -> Binding<CGFloat> {
        Binding(
            get: {
                WorkspacePaneLayout.displayedSidebarWidth(
                    storedWidth: CGFloat(storedSidebarWidth),
                    totalWidth: totalWidth,
                    inspectorVisible: inspectorVisible,
                    inspectorWidth: inspectorWidth
                )
            },
            set: { width in
                let clamped = WorkspacePaneLayout.clampedStoredSidebarWidth(width)
                storedSidebarWidth = Double(clamped)
                defaults.set(Double(clamped), forKey: sidebarWidthPreferenceKey)
            }
        )
    }

    private func inspectorWidthBinding(
        totalWidth: CGFloat,
        sidebarVisible: Bool,
        sidebarWidth: CGFloat
    ) -> Binding<CGFloat> {
        Binding(
            get: {
                WorkspacePaneLayout.displayedInspectorWidth(
                    storedWidth: CGFloat(storedInspectorWidth),
                    totalWidth: totalWidth,
                    sidebarVisible: sidebarVisible,
                    sidebarWidth: sidebarWidth
                )
            },
            set: { width in
                let clamped = WorkspacePaneLayout.clampedStoredInspectorWidth(width)
                storedInspectorWidth = Double(clamped)
                defaults.set(Double(clamped), forKey: inspectorWidthPreferenceKey)
            }
        )
    }

    private var windowCommandContext: OnyxWindowCommandContext {
        .workspace(
            model: model,
            windowProvider: windowProvider,
            openProject: {
                projectCatalog.chooseAndImportProject(
                    window: windowProvider(),
                    initialFolderPath: model.draftWorkspacePath,
                    onFailure: presentProjectFailure
                ) { imported in
                    model.selectWorkspace(imported.folderPath)
                }
            },
            focusTaskSearch: {
                let sidebarDisplayed = WorkspacePaneLayout.isSidebarDisplayed(
                    sidebarRequested: model.isSidebarVisible,
                    inspectorVisible: model.isInspectorVisible,
                    isCompact: isCompactLayout
                )
                if !sidebarDisplayed {
                    toggleSidebar(sidebarDisplayed: false, isCompact: isCompactLayout)
                }
                searchFocusRequest += 1
            },
            toggleSidebar: {
                let sidebarDisplayed = WorkspacePaneLayout.isSidebarDisplayed(
                    sidebarRequested: model.isSidebarVisible,
                    inspectorVisible: model.isInspectorVisible,
                    isCompact: isCompactLayout
                )
                toggleSidebar(sidebarDisplayed: sidebarDisplayed, isCompact: isCompactLayout)
            }
        )
    }

    private var taskCommandContext: OnyxTaskCommandContext? {
        guard let thread = model.selectedThread,
              thread.id != "onyx:welcome" else { return nil }

        let id = thread.id
        let isBusy = thread.status == .running
            || thread.status == .waitingForApproval
            || model.isReviewActive(for: thread.id)
        return OnyxTaskCommandContext(
            isArchived: model.isShowingArchivedThreads,
            isPinned: thread.isPinned,
            isBusy: isBusy,
            canFork: model.supports(.threadForking),
            canCompact: model.supports(.threadCompaction),
            canDelete: model.supports(.threadDeletion),
            rename: { model.beginRename(id, window: windowProvider()) },
            togglePin: { model.togglePin(id) },
            fork: { model.fork(id) },
            compact: { model.compact(id) },
            archive: { model.archive(id) },
            restore: { model.restore(id) },
            delete: { model.beginDelete(id, window: windowProvider()) }
        )
    }

    private var providerDisplayName: String {
        providerConnections.first(where: { $0.id == selectedProviderConnectionID })?.displayName
            ?? (selectedProviderConnectionID == .codexDefault ? "Codex" : "Provider")
    }

    @MainActor
    private func synchronizeProviderTasks() {
        guard case .connected = model.connectionState,
              !model.isLoadingThreadList else { return }
        projectCatalog.replaceTasks(
            for: selectedProviderConnectionID,
            providerDisplayName: providerDisplayName,
            scope: model.threadListScope,
            threads: model.catalogThreads
        )
    }

    @MainActor
    private func presentProjectFailure(_ notice: ProjectCatalogNotice) {
        model.notice = (notice.title, notice.detail)
    }
}

/// The inspector is supporting context, not a second dashboard. Its Summary
/// surface is content-sized and top-aligned; Files and Review can still use the
/// full available height when the user explicitly opens them.
private struct InspectorWorkspacePane: View {
    @ObservedObject var model: OnyxAppModel
    let width: CGFloat

    var body: some View {
        ContextInspectorView(model: model)
            .frame(width: width)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OnyxTheme.canvas)
    }
}
