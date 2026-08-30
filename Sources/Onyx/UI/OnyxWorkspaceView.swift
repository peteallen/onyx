import SwiftUI

struct OnyxWorkspaceView: View {
    @ObservedObject var model: OnyxAppModel
    @ObservedObject private var projectCatalog: ProjectCatalogModel
    @StateObject private var switcherStateModel: ProjectWorkspaceSwitcherStateModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var terminalSession = TerminalSessionModel()
    @StateObject private var sourceNavigator = ProjectSourceNavigatorModel()
    @State private var storedTerminalHeight: Double
    @State private var storedSidebarWidth: Double
    @State private var storedInspectorWidth: Double
    @State private var searchFocusRequest = 0
    @State private var quickOpenFocusRequest = 0
    @State private var workspaceSwitcherFocusRequest = 0
    @State private var presentedPalette: WorkspaceTransientPalette?
    @State private var paletteFocusRestoration: WorkspacePaletteFocusRestoration?
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
    private let onSelectProviderTask: (@MainActor (
        ProviderConnectionID,
        String,
        ThreadListScope
    ) -> Void)?

    init(
        model: OnyxAppModel,
        preferenceKeyPrefix: String? = nil,
        defaults: UserDefaults = .standard,
        projectCatalog: ProjectCatalogModel = ProjectCatalogModel(),
        switcherStateModel: ProjectWorkspaceSwitcherStateModel? = nil,
        windowProvider: @escaping @MainActor () -> NSWindow? = { nil },
        providerConnections: [OnyxApplicationHost.WorkspaceConnection] = [],
        selectedProviderConnectionID: ProviderConnectionID = .codexDefault,
        onSelectProviderConnection: @escaping @MainActor (ProviderConnectionID) -> Void = { _ in },
        rankedModelChoices: [OnyxApplicationHost.ProviderModelChoice] = [],
        onSelectProviderModel: @escaping @MainActor (OnyxApplicationHost.ProviderModelChoice) -> Void = { _ in },
        onSelectProviderTask: (@MainActor (
            ProviderConnectionID,
            String,
            ThreadListScope
        ) -> Void)? = nil
    ) {
        self.model = model
        self.projectCatalog = projectCatalog
        _switcherStateModel = StateObject(
            wrappedValue: switcherStateModel
                ?? ProjectWorkspaceSwitcherStateModel(defaults: defaults)
        )
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
                            workspaceProjectName: workspaceHeaderProject?.displayName,
                            workspaceProjectPath: workspaceHeaderProject?.folderPath,
                            onOpenWorkspaceSwitcher: {
                                openWorkspaceSwitcher()
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
                                sourceNavigator: sourceNavigator,
                                width: inspectorWidth,
                                onSelectProviderTask: selectActiveProviderTask
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
            .accessibilityHidden(presentedPalette != nil)
            .overlay {
                if presentedPalette == .quickOpen {
                    ProjectQuickOpenView(
                        navigator: sourceNavigator,
                        projectPath: currentProjectPath,
                        focusRequest: quickOpenFocusRequest,
                        chooseProject: {
                            beginProjectPicker()
                        },
                        dismiss: { closeTransientPalette(restoringFocus: true) },
                        open: openQuickOpenResult
                    )
                }
            }
            .overlay {
                if presentedPalette == .workspaceSwitcher {
                    ProjectWorkspaceSwitcherView(
                        baseRequest: workspaceSwitcherRequest,
                        sourceRevision: workspaceSwitcherSourceRevision,
                        focusRequest: workspaceSwitcherFocusRequest,
                        stateModel: switcherStateModel,
                        dismiss: { closeTransientPalette(restoringFocus: true) },
                        activate: activateWorkspaceSwitcherDestination
                    )
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
        .onChange(of: model.threadListRevision) { _, _ in synchronizeProviderTasks() }
        .onChange(of: model.selectedThreadID) { _, _ in synchronizeProviderTasks() }
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
                // Authentication diagnostics are owned by the attached
                // recovery strip.  A stderr/request race can leave the
                // alert binding populated for one SwiftUI transaction after
                // the model has entered recovery; keep that raw JSON from
                // ever presenting (or remaining latched) over the Sign In
                // action surface.
                get: {
                    AccountAccessPresentation.shouldShowNotice(
                        noticePresent: model.notice != nil,
                        recoveryActive: model.authenticationRecovery != nil
                    )
                },
                set: { if !$0 { model.dismissNotice() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissNotice() }
        } message: {
            Text(model.authenticationRecovery == nil ? (model.notice?.detail ?? "") : "")
        }
    }

    @MainActor
    private func selectProviderTask(_ connectionID: ProviderConnectionID, threadID: String) {
        guard let onSelectProviderTask else {
            if connectionID == selectedProviderConnectionID {
                model.selectThread(threadID)
            }
            return
        }
        Self.routeProviderTaskSelection(
            connectionID,
            threadID: threadID,
            scope: model.threadListScope,
            onSelectProviderTask: onSelectProviderTask
        )
    }

    @MainActor
    private func selectActiveProviderTask(
        _ connectionID: ProviderConnectionID,
        threadID: String
    ) {
        guard let onSelectProviderTask else {
            if connectionID == selectedProviderConnectionID,
               model.threadListScope.rawValue == ThreadListScope.active.rawValue {
                model.selectThread(threadID)
            }
            return
        }
        Self.routeProviderTaskSelection(
            connectionID,
            threadID: threadID,
            scope: .active,
            onSelectProviderTask: onSelectProviderTask
        )
    }

    /// Provider-aware task routing shared by the sidebar and collaboration
    /// inspector. The child id does not need to exist in either catalog: the
    /// destination runtime reads it authoritatively after selection.
    @MainActor
    static func routeProviderTaskSelection(
        _ connectionID: ProviderConnectionID,
        threadID: String,
        scope: ThreadListScope,
        onSelectProviderTask: @MainActor (
            ProviderConnectionID,
            String,
            ThreadListScope
        ) -> Void
    ) {
        // The provider workspace owns pending cross-provider/scope
        // navigation. Route every click through it, including a same-provider
        // click, so a newer task can cancel an older destination that is still
        // waiting for its catalog. Letting this view select directly left the
        // old pending destination alive, and its late list completion stole
        // selection back from the user.
        onSelectProviderTask(connectionID, threadID, scope)
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
            openProject: { beginProjectPicker() },
            openWorkspaceSwitcher: {
                openWorkspaceSwitcher()
            },
            openQuickOpen: {
                openQuickOpen()
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

    private var currentProjectPath: String? {
        model.selectedProjectPath
    }

    private var workspaceSwitcherSourceRevision: ProjectWorkspaceSwitcherSourceRevision {
        ProjectWorkspaceSwitcherSourceRevision(
            projectRevision: projectCatalog.sidebarProjectionRevision,
            taskRevision: model.threadListRevision,
            scope: model.threadListScope,
            providerConnectionID: selectedProviderConnectionID,
            selectedThreadID: model.selectedThreadID,
            selectedWorkspacePath: model.selectedProjectPath
        )
    }

    private var workspaceHeaderProject: ProjectCatalogRecord? {
        ProjectCatalogResolver.project(
            forFolderPath: model.selectedProjectPath,
            in: projectCatalog.projects
        )
    }

    private var workspaceSwitcherRequest: ProjectWorkspaceSwitcherRequest {
        let selectedTaskID: ProjectTaskReference.ID?
        if let selectedThreadID = model.selectedThreadID,
           selectedThreadID != "onyx:welcome" {
            selectedTaskID = ProjectTaskReference.ID(
                providerConnectionID: selectedProviderConnectionID,
                threadID: selectedThreadID
            )
        } else {
            selectedTaskID = nil
        }

        let selectedProjectID = model.selectedProjectPath.flatMap { path in
            ProjectCatalogResolver.project(
                forFolderPath: path,
                in: projectCatalog.projects
            )?.id
        }

        return ProjectWorkspaceSwitcherRequest(
            projects: projectCatalog.projects,
            // Keep the palette-open path cheap: copying the provider-list
            // snapshot is COW/O(number-of-providers). Active/archived
            // de-duplication and ranking happen in the switcher's detached
            // projection worker after the surface has mounted and focused.
            activeTasks: [],
            archivedTasks: [],
            selectedProjectID: selectedProjectID,
            selectedWorkspacePath: model.selectedProjectPath,
            selectedTaskID: selectedTaskID,
            state: switcherStateModel.snapshot,
            taskLists: projectCatalog.providerTaskLists,
            taskListRevision: projectCatalog.sidebarProjectionRevision
        )
    }

    @MainActor
    private func openWorkspaceSwitcher() {
        openTransientPalette(.workspaceSwitcher)
        workspaceSwitcherFocusRequest &+= 1
    }

    @MainActor
    private func openQuickOpen() {
        openTransientPalette(.quickOpen)
        quickOpenFocusRequest &+= 1
    }

    @MainActor
    private func openTransientPalette(_ palette: WorkspaceTransientPalette) {
        if presentedPalette == nil, let window = windowProvider() {
            paletteFocusRestoration = WorkspacePaletteFocusRestoration(window: window)
        }
        // One transient palette owns the window at a time. Switching shortcuts
        // replaces the surface in place instead of stacking two search fields
        // that compete for focus and Escape.
        presentedPalette = palette
    }

    @MainActor
    private func closeTransientPalette(restoringFocus: Bool) {
        let restoration = paletteFocusRestoration
        presentedPalette = nil
        paletteFocusRestoration = nil
        guard restoringFocus else { return }
        DispatchQueue.main.async { [windowProvider, model] in
            guard let window = windowProvider() else { return }
            if restoration?.restore(in: window) == true { return }
            if restoration?.composerWasFocused == true {
                model.requestComposerFocus()
            }
        }
    }

    @MainActor
    private func activateWorkspaceSwitcherDestination(
        _ destination: ProjectWorkspaceSwitcherRow.Destination
    ) {
        switch destination {
        case .addProject:
            beginProjectPicker()
        case let .newTask(_, workspacePath):
            closeTransientPalette(restoringFocus: false)
            if let workspacePath {
                model.newTask(inWorkspace: workspacePath)
            } else {
                model.newTask()
            }
        case let .openTask(connectionID, threadID, scopeRawValue):
            closeTransientPalette(restoringFocus: false)
            guard let scope = ThreadListScope(rawValue: scopeRawValue) else { return }
            guard let onSelectProviderTask else {
                if scope.rawValue != model.threadListScope.rawValue {
                    model.setThreadListScope(scope)
                } else {
                    model.selectThread(threadID)
                }
                return
            }
            Self.routeProviderTaskSelection(
                connectionID,
                threadID: threadID,
                scope: scope,
                onSelectProviderTask: onSelectProviderTask
            )
        }
    }

    @MainActor
    private func beginProjectPicker() {
        // Keep the palette's original responder alive long enough to restore
        // it after the folder sheet closes. Closing the palette first would
        // otherwise discard the only reference to a composer/search editor.
        // Sidebar and header entry points do not open a transient palette, so
        // capture their current responder here as the equivalent fallback.
        let restoration = paletteFocusRestoration
            ?? windowProvider().map { WorkspacePaletteFocusRestoration(window: $0) }
        closeTransientPalette(restoringFocus: false)
        chooseProject(restoringFocus: restoration)
    }

    @MainActor
    private func chooseProject(
        restoringFocus: WorkspacePaletteFocusRestoration? = nil
    ) {
        projectCatalog.chooseAndImportProject(
            window: windowProvider(),
            initialFolderPath: model.draftWorkspacePath,
            onFailure: presentProjectFailure,
            onCancelled: { [windowProvider, model] in
                Self.restoreProjectPickerFocus(
                    restoringFocus,
                    model: model,
                    windowProvider: windowProvider
                )
            }
        ) { imported in
            model.selectWorkspace(imported.folderPath)
        }
    }

    /// A canceled folder sheet removes its temporary field editor. Restore
    /// the responder that opened the palette when it is still mounted; if it
    /// was a transient search field (or no window was available), route focus
    /// back to the durable composer so the next keystroke has somewhere
    /// useful to go.
    @MainActor
    private static func restoreProjectPickerFocus(
        _ restoration: WorkspacePaletteFocusRestoration?,
        model: OnyxAppModel,
        windowProvider: @escaping @MainActor () -> NSWindow?
    ) {
        DispatchQueue.main.async {
            guard let window = windowProvider() else {
                if model.canEditComposer { model.requestComposerFocus() }
                return
            }
            if restoration?.restore(in: window) == true { return }
            if model.canEditComposer { model.requestComposerFocus() }
        }
    }

    @MainActor
    private func openQuickOpenResult(_ file: ProjectSourceFile) {
        closeTransientPalette(restoringFocus: false)
        ProjectQuickOpenWorkspaceRouting.open(
            file,
            model: model,
            navigator: sourceNavigator
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
        guard ProviderTaskCatalogSynchronizationPolicy.shouldReplaceCachedTasks(
            connectionState: model.connectionState,
            isLoadingThreadList: model.isLoadingThreadList,
            hasAuthoritativeThreadList: model.hasAuthoritativeThreadListForCurrentScope,
            hasUnlistedSelectedTask: model.hasUnlistedSelectedTask
        ) else { return }
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

private enum WorkspaceTransientPalette: Hashable {
    case quickOpen
    case workspaceSwitcher
}

@MainActor
private final class WorkspacePaletteFocusRestoration {
    weak var responder: NSResponder?
    let composerWasFocused: Bool

    init(window: NSWindow) {
        let firstResponder = window.firstResponder
        composerWasFocused = firstResponder is ComposerTextView
        if let fieldEditor = firstResponder as? NSTextView,
           fieldEditor.isFieldEditor,
           let fieldOwner = fieldEditor.delegate as? NSResponder {
            responder = fieldOwner
        } else {
            responder = firstResponder
        }
    }

    func restore(in window: NSWindow) -> Bool {
        guard let responder else { return false }
        if let view = responder as? NSView, view.window !== window {
            return false
        }
        return window.makeFirstResponder(responder)
    }
}

/// The inspector is supporting context, not a second dashboard. Its Summary
/// surface is content-sized and top-aligned; Files and Review can still use the
/// full available height when the user explicitly opens them.
private struct InspectorWorkspacePane: View {
    @ObservedObject var model: OnyxAppModel
    @ObservedObject var sourceNavigator: ProjectSourceNavigatorModel
    let width: CGFloat
    let onSelectProviderTask: @MainActor (ProviderConnectionID, String) -> Void

    var body: some View {
        ContextInspectorView(
            model: model,
            sourceNavigator: sourceNavigator,
            onSelectProviderTask: onSelectProviderTask
        )
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OnyxTheme.canvas)
    }
}
