import SwiftUI

struct OnyxWorkspaceView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var terminalSession = TerminalSessionModel()
    @State private var storedTerminalHeight: Double
    @State private var searchFocusRequest = 0
    @State private var isCompactLayout = false
    private let terminalHeightPreferenceKey: String
    private let defaults: UserDefaults
    private let windowProvider: @MainActor () -> NSWindow?

    init(
        model: OnyxAppModel,
        preferenceKeyPrefix: String? = nil,
        defaults: UserDefaults = .standard,
        windowProvider: @escaping @MainActor () -> NSWindow? = { nil }
    ) {
        self.model = model
        let namespace = OnyxPreferenceNamespace(prefix: preferenceKeyPrefix)
        let key = namespace.key("Onyx.terminalHeight")
        terminalHeightPreferenceKey = key
        self.defaults = defaults
        self.windowProvider = windowProvider
        let restored = defaults.object(forKey: key) as? NSNumber
        let restoredHeight = CGFloat(restored?.doubleValue ?? 238.0)
        _storedTerminalHeight = State(
            initialValue: Double(TerminalDrawerLayout.clampedHeight(restoredHeight))
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1_180
            let showSidebar = model.isSidebarVisible && (!isCompact || !model.isInspectorVisible)

            HStack(spacing: 0) {
                CommandRailView(model: model)

                if showSidebar {
                    TaskSidebarView(model: model, searchFocusRequest: searchFocusRequest)
                        .frame(width: 264)
                        .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ConversationWorkspaceView(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if model.isInspectorVisible {
                            Divider().overlay(OnyxTheme.border)
                            ContextInspectorView(model: model)
                                .frame(width: min(344, max(300, proxy.size.width * 0.27)))
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

    private var windowCommandContext: OnyxWindowCommandContext {
        .workspace(
            model: model,
            windowProvider: windowProvider,
            focusTaskSearch: {
                if isCompactLayout {
                    model.isInspectorVisible = false
                }
                model.isSidebarVisible = true
                searchFocusRequest += 1
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
}
