import SwiftUI

struct ConversationWorkspaceView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    /// The parent owns compact pane arbitration, so the header can describe
    /// what is actually visible rather than only the persisted preference.
    var sidebarDisplayed: Bool?
    var onShowSidebar: (@MainActor () -> Void)?
    var providerConnections: [OnyxApplicationHost.WorkspaceConnection] = []
    var selectedProviderConnectionID: ProviderConnectionID = .codexDefault
    var onSelectProviderConnection: @MainActor (ProviderConnectionID) -> Void = { _ in }
    var rankedModelChoices: [OnyxApplicationHost.ProviderModelChoice] = []
    var onSelectProviderModel: @MainActor (OnyxApplicationHost.ProviderModelChoice) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let sideChatLayout = SideChatPanelLayout.resolve(availableWidth: proxy.size.width)
            let composerInset = ConversationContentLayout.horizontalInset(
                availableWidth: proxy.size.width
            )

            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    ConversationHeaderView(
                        model: model,
                        sidebarDisplayed: sidebarDisplayed ?? model.isSidebarVisible,
                        onShowSidebar: onShowSidebar ?? { model.isSidebarVisible = true }
                    )

                    ZStack {
                        ConversationHistoryViewport(
                            canLoadEarlierHistory: model.canLoadEarlierHistory,
                            isLoadingEarlierHistory: model.isLoadingEarlierHistory,
                            onLoadEarlierHistory: model.loadEarlierHistory
                        ) {
                            NativeTranscriptView(
                                items: model.transcriptSnapshot.items,
                                isAwaitingResponse: (model.isTurnRunning
                                    || model.isSelectedReviewStarting
                                    || model.isPreparingFailedResponseRetryForSelectedThread)
                                    && model.activeUserInteraction == nil,
                                workingLabel: model.isPreparingFailedResponseRetryForSelectedThread
                                    ? "Preparing retry…"
                                    : (model.isReviewRunning || model.isSelectedReviewStarting
                                        ? "Reviewing changes…"
                                        : "Working on a response…"),
                                revision: model.transcriptSnapshot.revision,
                                changeHint: model.transcriptSnapshot.changeHint,
                                editableUserMessageID: model.latestEditableUserMessageID,
                                retryableFailedResponseItemID: model.retryableFailedResponseItemID,
                                onEditUserMessage: { messageID in
                                    model.beginEditLatestUserMessage(
                                        messageID: messageID,
                                        window: windowPresentation.window
                                    )
                                },
                                onRetryFailedResponse: { responseItemID in
                                    guard let messageID = model.retryUserMessageID(
                                        forFailedResponseItemID: responseItemID
                                    ) else { return }
                                    model.beginRetryLatestFailedResponse(
                                        messageID: messageID,
                                        window: windowPresentation.window
                                    )
                                }
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        if model.isLoadingThread {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Loading task history…")
                                    .font(.system(size: OnyxTypography.reading))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(18)
                            .onyxPanel(radius: 12)
                        } else if model.timeline.isEmpty {
                            EmptyTranscriptView(isArchive: model.isShowingArchivedThreads)
                        }
                    }

                    VStack(spacing: 8) {
                        if let interaction = model.activeUserInteraction {
                            UserInteractionView(model: model, interaction: interaction)
                                .id(interaction)
                        }

                        if model.session != nil,
                           (model.loginAttempt != nil
                            || (model.authState.requiresAuthentication && !model.authState.isSignedIn)) {
                            AccountAccessStrip(model: model)
                        }

                        RuntimeStatusStrip(model: model)
                        ProviderExecutionScopeStrip(model: model)
                        if model.isShowingArchivedThreads {
                            ArchivedThreadStrip(model: model)
                        } else {
                            ComposerView(
                                model: model,
                                providerConnections: providerConnections,
                                selectedProviderConnectionID: selectedProviderConnectionID,
                                onSelectProviderConnection: onSelectProviderConnection,
                                rankedModelChoices: rankedModelChoices,
                                onSelectProviderModel: onSelectProviderModel
                            )
                        }
                    }
                    .frame(maxWidth: ConversationContentLayout.maximumComposerWidth)
                    .padding(.leading, composerInset)
                    .padding(.trailing, composerInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, ConversationContentLayout.bottomInset)
                }

                if model.isSideChatPresented {
                    SideChatPanelView(model: model)
                        .frame(width: sideChatLayout.panelWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.isSideChatPresented)
        .background(OnyxTheme.canvas)
    }
}

/// Models that remain on the plain OpenAI-compatible chat lane are useful
/// chat/reasoning backends, but that lane cannot execute Onyx's local
/// workspace tools. Capable models are projected onto the adaptive agent lane
/// and do not show this strip.
struct ProviderExecutionScopeStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        if !model.supports(.tools) {
            Label(
                "Chat only — this model is currently on the reply-only path and cannot inspect or edit project files or run commands.",
                systemImage: "text.bubble"
            )
            .font(.system(size: OnyxTypography.metadata))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Chat-only model")
            .accessibilityHint("This model cannot inspect or edit project files or run Onyx tools")
        }
    }
}

enum ProviderExecutionScopePresentation {
    static func isChatOnly(session: RuntimeSession?) -> Bool {
        guard let session else { return false }
        return !session.capabilities.contains(.tools)
    }
}

/// Reserves one compact row above the transcript for bounded history paging.
/// The row intentionally remains in the layout after the final page loads so
/// the transcript viewport never changes height while AppKit is preserving the
/// reader's anchor across a prepend.
enum ConversationHistoryViewportLayout {
    static let affordanceHeight = OnyxHitTarget.compact + 4
}

struct ConversationHistoryViewport<Transcript: View>: View {
    let canLoadEarlierHistory: Bool
    let isLoadingEarlierHistory: Bool
    let onLoadEarlierHistory: () -> Void
    @ViewBuilder let transcript: Transcript
    @State private var hasPresentedHistoryAffordance = false

    private var reservesHistoryAffordance: Bool {
        canLoadEarlierHistory || isLoadingEarlierHistory || hasPresentedHistoryAffordance
    }

    var body: some View {
        VStack(spacing: 0) {
            if reservesHistoryAffordance {
                ZStack {
                    if canLoadEarlierHistory || isLoadingEarlierHistory {
                        Button(action: onLoadEarlierHistory) {
                            HStack(spacing: 7) {
                                if isLoadingEarlierHistory {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.up")
                                }
                                Text(isLoadingEarlierHistory
                                    ? "Loading earlier messages…"
                                    : "Load earlier messages")
                            }
                            .font(.system(size: OnyxTypography.secondary, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: OnyxHitTarget.compact)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingEarlierHistory)
                        .accessibilityHint("Adds the preceding page without moving the visible conversation")
                    }
                }
                .frame(height: ConversationHistoryViewportLayout.affordanceHeight, alignment: .bottom)
            }

            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if canLoadEarlierHistory || isLoadingEarlierHistory {
                hasPresentedHistoryAffordance = true
            }
        }
        .onChange(of: canLoadEarlierHistory) { _, canLoad in
            if canLoad { hasPresentedHistoryAffordance = true }
        }
        .onChange(of: isLoadingEarlierHistory) { _, isLoading in
            if isLoading { hasPresentedHistoryAffordance = true }
        }
    }
}

/// Keeps the primary conversation controls aligned with the transcript's pane
/// gutters. Insets ease down on compact windows rather than taking a fixed
/// chunk from an already narrow center pane.
enum ConversationContentLayout {
    /// The composer belongs to the pane rather than a narrow card within it.
    /// Its modest outer gutters match the transcript while the inner inset
    /// keeps entered text comfortably away from the border.
    static let maximumComposerWidth: CGFloat = .infinity
    static let bottomInset: CGFloat = 20
    static let minimumHorizontalInset = OnyxWorkspaceMetrics.minimumConversationSideInset
    static let maximumHorizontalInset = OnyxWorkspaceMetrics.preferredConversationSideInset

    static func horizontalInset(availableWidth: CGFloat) -> CGFloat {
        OnyxWorkspaceMetrics.conversationSideInset(availableWidth: availableWidth)
    }
}

/// Keeps an ephemeral trailing panel useful without collapsing the main task
/// at compact workspace widths. The panel overlays the transcript rather than
/// consuming another permanent split-pane allocation (the project sidebar and
/// inspector may already be visible outside this conversation surface).
struct SideChatPanelLayout: Equatable {
    static let minimumWidth: CGFloat = 300
    static let preferredWidth: CGFloat = 380
    static let maximumWidth: CGFloat = 460
    static let compactHorizontalInset: CGFloat = 20

    let panelWidth: CGFloat

    static func resolve(availableWidth: CGFloat) -> Self {
        let boundedAvailable = max(0, availableWidth - compactHorizontalInset)
        let width = min(maximumWidth, max(minimumWidth, min(preferredWidth, boundedAvailable)))
        return Self(panelWidth: width)
    }
}

private struct ConversationHeaderView: View {
    @ObservedObject var model: OnyxAppModel
    let sidebarDisplayed: Bool
    let onShowSidebar: @MainActor () -> Void
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation

    var body: some View {
        HStack(spacing: 10) {
            if !sidebarDisplayed {
                Button {
                    onShowSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .onyxHelp("Show sidebar")
                .accessibilityLabel("Show task sidebar")
                .accessibilityHint("Reveals the task list")
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(headerTitle)
                    .font(.system(size: OnyxTypography.paneTitle, weight: .semibold))
                    .lineLimit(1)
            }
            .onyxHelp(projectContext)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Task")
            .accessibilityValue("\(headerTitle), \(projectContext)")

            Spacer()

            if model.isSideChatPresented {
                Button(action: model.closeSideChat) {
                    headerAction(
                        title: "Side chat",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        isSelected: true
                    )
                }
                .buttonStyle(.plain)
                .onyxHelp("Close side chat")
                .accessibilityLabel("Close side chat")
                .accessibilityHint("Returns focus to the durable task transcript")
            } else if model.canOpenSideChat {
                Button(action: model.openSideChat) {
                    headerAction(
                        title: "Side chat",
                        systemImage: "bubble.left.and.bubble.right",
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
                .onyxHelp("Ask a private follow-up without changing this task")
                .accessibilityLabel("Open side chat")
                .accessibilityHint("Creates an ephemeral fork with a copy of this task's context")
            }

            if model.isShowingArchivedThreads {
                Label("Archived", systemImage: "archivebox")
                    .font(.system(size: OnyxTypography.secondary, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Task status")
                    .accessibilityValue("Archived")
            }

            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(model.isInspectorVisible ? OnyxTheme.iris : Color.secondary)
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .onyxHelp("Toggle context panel (⌘⌥B)")
            .accessibilityLabel(model.isInspectorVisible ? "Hide context panel" : "Show context panel")
            .accessibilityHint("Keyboard shortcut Command-Option-B")

            Menu {
                if let id = model.selectedThreadID, id != "onyx:welcome" {
                    if model.isShowingArchivedThreads {
                        Button("Restore Task") { model.restore(id) }
                        if model.supports(.threadDeletion) {
                            Divider()
                            Button("Delete Permanently…", role: .destructive) {
                                model.beginDelete(id, window: windowPresentation.window)
                            }
                        }
                    } else {
                        if model.canOpenSideChat {
                            Button("Open Side Chat") { model.openSideChat() }
                            Divider()
                        }
                        Button("Rename…") { model.beginRename(id, window: windowPresentation.window) }
                        Button(model.selectedThread?.isPinned == true ? "Unpin" : "Pin") { model.togglePin(id) }
                        if model.supports(.threadForking) {
                            Button("Fork Task") { model.fork(id) }
                                .disabled(model.selectedThread.map(model.canForkThread) != true)
                        }
                        Divider()
                        if model.supports(.threadCompaction) {
                            Button("Compact Context") { model.compact(id) }
                                .disabled(model.selectedThread.map(model.canCompactThread) != true)
                        }
                        Button("Archive") { model.archive(id) }
                            .disabled(model.selectedThread.map(model.canArchiveThread) != true)
                        if model.supports(.threadDeletion) {
                            Divider()
                            Button("Delete Permanently…", role: .destructive) {
                                model.beginDelete(id, window: windowPresentation.window)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onyxHelp("Task actions")
            .accessibilityLabel("Task actions")
        }
        .padding(.horizontal, OnyxWorkspaceMetrics.paneEdgeInset)
        .frame(height: OnyxWorkspaceMetrics.paneHeaderHeight)
        .background(OnyxTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OnyxTheme.divider)
                .frame(height: OnyxTheme.hairline)
        }
    }

    private var headerTitle: String {
        model.selectedThread?.title ?? (model.isShowingArchivedThreads ? "Archived tasks" : "New task")
    }

    private var projectContext: String {
        guard let branch = model.selectedThread?.branch, !branch.isEmpty else {
            return model.projectName
        }
        return "\(model.projectName) / \(branch)"
    }

    private func headerAction(title: String, systemImage: String, isSelected: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 8)

            Image(systemName: systemImage)
                .frame(width: 28)
        }
        .font(.system(size: OnyxTypography.navigation, weight: .medium))
        .foregroundStyle(isSelected ? OnyxTheme.iris : Color.secondary)
        .frame(height: 28)
        .background(isSelected ? OnyxTheme.iris.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(height: OnyxHitTarget.compact)
        .contentShape(Rectangle())
    }
}

private struct EmptyTranscriptView: View {
    let isArchive: Bool

    var body: some View {
        VStack(spacing: 11) {
            if isArchive {
                Image(systemName: "archivebox")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else {
                OnyxMark(size: 38)
            }
            Text(isArchive ? "No archived tasks" : "Start with an outcome")
                .font(.system(size: OnyxTypography.paneTitle, weight: .semibold))
            Text(isArchive
                ? "Tasks you archive will remain available here and can be restored at any time."
                : "Onyx will inspect the workspace, work through the task, and keep the live result here.")
                .font(.system(size: OnyxTypography.navigation))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(.bottom, 60)
    }
}

private struct ArchivedThreadStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.11))
                Image(systemName: "archivebox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedThread == nil ? "Archived tasks" : "This task is archived")
                    .font(.system(size: OnyxTypography.navigation, weight: .semibold))
                Text(model.selectedThread == nil
                    ? "Select a task to review its history."
                    : "Restore it to continue the conversation or run more work.")
                    .font(.system(size: OnyxTypography.secondary))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let id = model.selectedThreadID {
                Button("Restore Task") { model.restore(id) }
                    .buttonStyle(.borderedProminent)
                    .tint(OnyxTheme.iris)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .background(OnyxTheme.raisedSurface.opacity(0.72))
        .onyxPanel(radius: 12)
    }
}

private struct RuntimeStatusStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        switch model.connectionState {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(model.session == nil
                    ? "Connecting to \(model.runtimeDisplayName)…"
                    : "Reconnecting to \(model.runtimeDisplayName)…")
            }
                .foregroundStyle(.secondary)
                .font(.system(size: OnyxTypography.metadata))
        case let .failed(message):
            reconnectRow(
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                color: OnyxTheme.destructive
            )
        case .disconnected:
            reconnectRow(
                message: "\(model.runtimeDisplayName) disconnected",
                systemImage: "bolt.slash",
                color: .secondary
            )
        case .connected:
            EmptyView()
        }
    }

    private func reconnectRow(message: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(color)
                .font(.system(size: OnyxTypography.metadata))
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.canReconnect {
                Button("Reconnect", action: model.reconnect)
                    .buttonStyle(.borderless)
                    .font(.system(size: OnyxTypography.metadata, weight: .semibold))
                    .accessibilityHint("Restarts \(model.runtimeDisplayName) and refreshes the open task")
            }
        }
    }
}

private struct AccountAccessStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(OnyxTheme.iris.opacity(0.13))
                Image(systemName: model.loginAttempt == nil ? "person.crop.circle.badge.plus" : "person.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnyxTheme.iris)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: OnyxTypography.navigation, weight: .semibold))
                if let code = model.loginAttempt?.userCode {
                    Text(code)
                        .font(.system(size: OnyxTypography.reading, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(detail)
                        .font(.system(size: OnyxTypography.secondary))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let attempt = model.loginAttempt {
                if attempt.userCode != nil {
                    Button("Copy Code", action: model.copyDeviceCode)
                        .buttonStyle(.borderless)
                }
                Button("Open Sign In", action: model.reopenLoginPage)
                    .buttonStyle(.borderedProminent)
                    .tint(OnyxTheme.iris)
                    .controlSize(.small)
                Button("Cancel", action: model.cancelLogin)
                    .buttonStyle(.borderless)
                    .disabled(model.isAuthenticating)
            } else if model.isAuthenticating {
                ProgressView().controlSize(.small)
            } else {
                if model.primaryLoginMethod == nil {
                    SettingsLink {
                        Text("Open Settings")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OnyxTheme.iris)
                    .controlSize(.small)
                    .accessibilityLabel("Open provider settings")
                    .accessibilityHint("Choose Providers to add or update this connection's API key")
                }
                if let deviceMethod = model.deviceCodeLoginMethod {
                    Menu {
                        Button(deviceMethod.displayName) { model.startLogin(deviceMethod) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .onyxHelp("More sign-in options")
                }
                if let method = model.primaryLoginMethod {
                    Button(method.displayName) { model.startLogin(method) }
                        .buttonStyle(.borderedProminent)
                        .tint(OnyxTheme.iris)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(OnyxTheme.iris.opacity(0.045))
        .onyxPanel(radius: 12)
    }

    private var title: String {
        guard let attempt = model.loginAttempt else {
            if model.primaryLoginMethod == nil {
                return "\(model.runtimeDisplayName) needs credentials"
            }
            return "Sign in to run \(model.runtimeDisplayName)"
        }
        return attempt.method.ceremony == .deviceCode ? "Enter this one-time code" : "Finish signing in in your browser"
    }

    private var detail: String {
        if let detail = model.loginAttempt?.method.detail { return detail }
        if model.primaryLoginMethod == nil {
            return "Open Settings, choose Providers, and add or update this connection's API key."
        }
        return "Your credentials stay with \(model.runtimeDisplayName) and are never copied into Onyx."
    }
}

/// Layout constants for the composer toolbar. The conversation surface can get
/// fairly narrow when the task list and context panel are open, so the toolbar
/// deliberately spends its available width on the model picker and keeps
/// secondary controls discoverable behind compact icon menus.
enum ComposerToolbarLayout {
    static let horizontalPadding: CGFloat = 9
    static let rowHeight: CGFloat = 34
}

/// Decides when ongoing work can yield the full message composer to a compact
/// progress row. Keep this policy independent from the view's ephemeral
/// expansion state so reviews, attachments, and interaction prompts cannot
/// accidentally hide controls the user still needs.
enum BusyComposerPresentation {
    static let compactHeight: CGFloat = 40
    static let compactActionLabel = "Write a follow-up"

    static func usesCompactStrip(
        isTurnRunning: Bool,
        isReviewRunning: Bool,
        isReviewStarting: Bool,
        hasPendingInteraction: Bool,
        draftText: String,
        attachmentCount: Int,
        canInterrupt: Bool,
        isComposingNewTask: Bool,
        userRequestedExpansion: Bool
    ) -> Bool {
        // While review/start is awaiting acceptance, Codex has not exposed a
        // turn ID that interrupt can target. Keep the existing starting UI in
        // that brief phase instead of presenting a Stop action that may fail.
        let hasStoppableWork = (isTurnRunning || isReviewRunning) && !isReviewStarting
        let draftIsEmpty = draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachmentCount == 0
        return hasStoppableWork
            && !hasPendingInteraction
            && draftIsEmpty
            && canInterrupt
            && !isComposingNewTask
            && !userRequestedExpansion
    }

    static func label(isReviewRunning: Bool, isReviewStarting: Bool) -> String {
        isReviewRunning || isReviewStarting ? "Reviewing changes…" : "Working on a response…"
    }
}

private struct ComposerView: View {
    @ObservedObject var model: OnyxAppModel
    let providerConnections: [OnyxApplicationHost.WorkspaceConnection]
    let selectedProviderConnectionID: ProviderConnectionID
    let onSelectProviderConnection: @MainActor (ProviderConnectionID) -> Void
    let rankedModelChoices: [OnyxApplicationHost.ProviderModelChoice]
    let onSelectProviderModel: @MainActor (OnyxApplicationHost.ProviderModelChoice) -> Void
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    @State private var textHeight: CGFloat = 46
    @State private var userExpandedBusyComposer = false

    private var interactionBlocksComposer: Bool {
        model.activeUserInteraction?.isBlocking == true
    }

    private var isChatOnlyProvider: Bool {
        !model.supports(.tools)
    }

    private var taskOptionsHelp: String {
        isChatOnlyProvider
            ? "Choose reasoning effort; this provider is chat only"
            : "Choose reasoning effort and task permissions"
    }

    private var taskOptionsAccessibilityValue: String {
        if isChatOnlyProvider {
            return model.availableReasoningEfforts.isEmpty
                ? "Chat only"
                : "\(model.selectedReasoningEffortName), chat only"
        }
        return model.availableReasoningEfforts.isEmpty
            ? model.permissionLabel
            : "\(model.selectedReasoningEffortName), \(model.permissionLabel)"
    }

    private var canSend: Bool {
        model.canRunAgent
            && !model.isPreparingLatestMessageEditForSelectedThread
            && !interactionBlocksComposer
            && !model.isReviewBlockingComposer
            && (!model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.composerImages.isEmpty)
    }

    private var hasActiveWork: Bool {
        model.isTurnRunning || model.isReviewRunning || model.isSelectedReviewStarting
    }

    private var usesCompactBusyStrip: Bool {
        BusyComposerPresentation.usesCompactStrip(
            isTurnRunning: model.isTurnRunning,
            isReviewRunning: model.isReviewRunning,
            isReviewStarting: model.isSelectedReviewStarting,
            hasPendingInteraction: model.activeUserInteraction != nil,
            draftText: model.composerText,
            attachmentCount: model.composerImages.count,
            canInterrupt: model.supports(.interruption),
            isComposingNewTask: isComposingNewTask,
            userRequestedExpansion: userExpandedBusyComposer
        )
    }

    var body: some View {
        Group {
            if usesCompactBusyStrip {
                compactBusyStrip
            } else {
                expandedComposer
            }
        }
        .onChange(of: hasActiveWork) { _, isActive in
            if !isActive {
                userExpandedBusyComposer = false
            }
        }
        .onChange(of: model.selectedThreadID) { _, _ in
            userExpandedBusyComposer = false
        }
    }

    private var expandedComposer: some View {
        VStack(spacing: 0) {
            if !model.composerImages.isEmpty {
                ComposerImagePreviewRow(
                    images: model.composerImages,
                    onRemove: model.removeComposerImage
                )
                .padding(.horizontal, OnyxWorkspaceMetrics.composerInnerInset)
                .padding(.top, 10)
            }

            NativeComposerTextView(
                text: $model.composerText,
                measuredHeight: $textHeight,
                // Keep drafting available across provider reconnects and
                // authentication gaps. `canSend` still gates submission, so
                // a draft can never be dispatched until the runtime is ready.
                isEnabled: model.canEditComposer,
                canSubmit: { canSend },
                onSubmit: submitComposer,
                onPasteImages: { images in
                    model.addPastedComposerImages(images)
                }
            )
            .frame(height: textHeight)
            .padding(.horizontal, OnyxWorkspaceMetrics.composerInnerInset)
            .padding(.top, 6)

            // ViewThatFits measures the full-label candidate at its intrinsic
            // width before falling back. This is important for arbitrary
            // provider/model names: a fixed breakpoint would either truncate
            // short names too early or still overflow a long vLLM name.
            ViewThatFits(in: .horizontal) {
                regularToolbarCandidate
                compactToolbar
                minimalToolbar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(height: ComposerToolbarLayout.rowHeight)
            .padding(.horizontal, ComposerToolbarLayout.horizontalPadding)
            .padding(.bottom, 7)
        }
        .background(OnyxTheme.composerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
        }
        .shadow(color: SwiftUI.Color(white: 0, opacity: 0.08), radius: 8, y: 3)
    }

    private var compactBusyStrip: some View {
        HStack(spacing: 8) {
            Button(action: expandBusyComposer) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)

                    Text(BusyComposerPresentation.compactActionLabel)
                        .font(.system(size: OnyxTypography.navigation, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityLabel(BusyComposerPresentation.compactActionLabel)
            .accessibilityHint("Expands the message composer so you can write a follow-up")

            Button(action: model.interrupt) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: OnyxTypography.navigation, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.065))
                    .clipShape(Capsule())
                .frame(height: OnyxHitTarget.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onyxHelp("Stop task")
            .accessibilityLabel("Stop task")
            .accessibilityHint("Interrupts the active work")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: BusyComposerPresentation.compactHeight)
        .background(OnyxTheme.composerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
        }
    }

    private func expandBusyComposer() {
        userExpandedBusyComposer = true
    }

    private func submitComposer() {
        guard canSend else { return }
        // A submitted follow-up has finished this expansion gesture. If the
        // task is still running, its now-empty composer can become compact
        // again in the same update that clears the draft.
        userExpandedBusyComposer = false
        model.sendComposer()
    }

    private var isComposingNewTask: Bool {
        model.selectedThreadID == nil || model.selectedThreadID == "onyx:welcome"
    }

    private var selectedProviderName: String {
        providerConnections.first(where: { $0.id == selectedProviderConnectionID })?.displayName
            ?? model.session?.displayName
            ?? "Provider"
    }

    private var selectedModelLabel: String {
        model.session?.availableModels.first(where: { $0.id == model.selectedTaskModelID })?.displayName
            ?? model.session?.availableModels.first(where: { $0.id == model.selectedModelID })?.displayName
            ?? model.selectedTaskModelID
            ?? model.selectedModelID
            ?? "Choose model"
    }

    private var pickerSelectedModelID: String? {
        isComposingNewTask ? model.selectedModelID : model.selectedTaskModelID
    }

    private var currentTaskProviderChoices: [OnyxApplicationHost.ProviderModelChoice] {
        rankedModelChoices.filter { $0.connection.id == selectedProviderConnectionID }
    }

    private var frequentChoices: [OnyxApplicationHost.ProviderModelChoice] {
        Array(rankedModelChoices.filter { $0.usageCount > 0 }.prefix(5))
    }

    private func choicesForProvider(
        _ connectionID: ProviderConnectionID
    ) -> [OnyxApplicationHost.ProviderModelChoice] {
        let promotedIDs = Set(frequentChoices.map(\.id))
        return rankedModelChoices.filter {
            $0.connection.id == connectionID && !promotedIDs.contains($0.id)
        }
    }

    private func hasCatalog(for connectionID: ProviderConnectionID) -> Bool {
        rankedModelChoices.contains { $0.connection.id == connectionID }
    }

    @ViewBuilder
    private var regularToolbar: some View {
        HStack(spacing: 8) {
            attachImagesButton
            regularProviderModelMenu
            Spacer(minLength: 4)
            regularOptionsMenu
            sendButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// Keep the wide row's trailing send action anchored to the composer edge
    /// after it is selected. The hidden fixed-size copy gives ViewThatFits the
    /// true intrinsic width for its fit check without constraining the visible
    /// row to that width (which would otherwise center the whole toolbar).
    private var regularToolbarCandidate: some View {
        ZStack {
            regularToolbar
            regularToolbar
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var compactToolbar: some View {
        HStack(spacing: 8) {
            attachImagesButton
            compactProviderModelMenu
            Spacer(minLength: 4)
            compactOptionsMenu
            sendButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var minimalToolbar: some View {
        HStack(spacing: 8) {
            attachImagesButton
            minimalProviderModelMenu
            Spacer(minLength: 4)
            minimalOptionsMenu
            sendButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var attachImagesButton: some View {
        Button(action: { model.chooseComposerImages(window: windowPresentation.window) }) {
            Image(systemName: "plus")
                .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!model.canAttachImages)
        .onyxHelp(model.canAttachImages ? "Attach images" : "This runtime does not support image input")
        .accessibilityLabel("Attach images")
        .accessibilityHint("Choose one or more images to include with this message")
    }

    @ViewBuilder
    private var providerModelMenuContent: some View {
        if isComposingNewTask {
            if !frequentChoices.isEmpty {
                Section("Frequent & recent") {
                    ForEach(frequentChoices) { choice in
                        modelChoiceButton(choice, showsProvider: true)
                    }
                }
            }
            ForEach(providerConnections) { connection in
                let choices = choicesForProvider(connection.id)
                if !choices.isEmpty {
                    Section(connection.displayName) {
                        ForEach(choices) { choice in modelChoiceButton(choice) }
                    }
                } else if !hasCatalog(for: connection.id) {
                    Section(connection.displayName) {
                        if connection.id == selectedProviderConnectionID {
                            Text("Models load after connection")
                        } else {
                            Button("Browse \(connection.displayName) models…") {
                                onSelectProviderConnection(connection.id)
                            }
                        }
                    }
                }
            }
        } else {
            Section("Next turn") {
                if currentTaskProviderChoices.isEmpty {
                    Text("Models load after connection")
                } else {
                    ForEach(currentTaskProviderChoices) { choice in
                        modelChoiceButton(choice)
                    }
                }
            }
            if model.selectedTaskModelOverrideID != nil {
                Divider()
                Button("Use task default · \(taskDefaultModelLabel)") {
                    model.resetSelectedTaskModel()
                }
            }
        }
    }

    private var taskDefaultModelLabel: String {
        let id = model.selectedTaskDefaultModelID ?? "provider default"
        return model.session?.availableModels.first(where: { $0.id == id })?.displayName ?? id
    }

    private var regularProviderModelMenu: some View {
        Menu {
            providerModelMenuContent
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Text(selectedModelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(selectedProviderName)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: OnyxTypography.navigation, weight: .medium))
            .frame(minHeight: OnyxHitTarget.compact)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .onyxHelp(isComposingNewTask ? "Choose a provider and model for this new task" : "Choose the model for the next turn")
        .accessibilityLabel("Provider and model")
        .accessibilityValue("\(selectedProviderName), \(selectedModelLabel)")
    }

    private var compactProviderModelMenu: some View {
        Menu {
            providerModelMenuContent
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Text(selectedModelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 132, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: OnyxTypography.navigation, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: OnyxHitTarget.compact)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: 164, alignment: .leading)
        .layoutPriority(1)
        .onyxHelp(isComposingNewTask ? "Choose a provider and model for this new task" : "Choose the model for the next turn")
        .accessibilityLabel("Provider and model")
        .accessibilityValue("\(selectedProviderName), \(selectedModelLabel)")
    }

    private var minimalProviderModelMenu: some View {
        Menu {
            providerModelMenuContent
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .onyxHelp(isComposingNewTask ? "Choose a provider and model for this new task" : "Choose the model for the next turn")
        .accessibilityLabel("Provider and model")
        .accessibilityValue("\(selectedProviderName), \(selectedModelLabel)")
    }

    @ViewBuilder
    private var reasoningMenuContent: some View {
        ForEach(model.availableReasoningEfforts, id: \.self) { effort in
            Button {
                model.selectReasoningEffort(effort)
            } label: {
                if effort == model.selectedReasoningEffort {
                    Label(model.reasoningEffortName(effort), systemImage: "checkmark")
                } else {
                    Text(model.reasoningEffortName(effort))
                }
            }
        }
    }

    @ViewBuilder
    private var permissionMenuContent: some View {
        Button("Read only") { model.permissionLabel = "Read only" }
        Button("Workspace") { model.permissionLabel = "Workspace" }
        Button("Full access") { model.permissionLabel = "Full access" }
    }

    @ViewBuilder
    private var minimalOptionsMenuContent: some View {
        if !model.availableReasoningEfforts.isEmpty {
            Section("Reasoning") {
                reasoningMenuContent
            }
        }
        if !isChatOnlyProvider {
            Section("Permissions") {
                permissionMenuContent
            }
        }
    }

    private var minimalOptionsMenu: some View {
        Menu {
            minimalOptionsMenuContent
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
        .onyxHelp(taskOptionsHelp)
        .accessibilityLabel("Task options")
        .accessibilityValue(taskOptionsAccessibilityValue)
    }

    /// Reasoning is a first-class model control, so keep the current choice
    /// visible whenever the composer has enough room. The icon-only fallback
    /// remains available to the compact toolbar through `ViewThatFits`.
    private var regularOptionsMenu: some View {
        Menu {
            minimalOptionsMenuContent
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.availableReasoningEfforts.isEmpty
                    ? (isChatOnlyProvider ? "text.bubble" : "slider.horizontal.3")
                    : "brain")
                    .foregroundStyle(.secondary)
                Text(model.availableReasoningEfforts.isEmpty
                    ? (isChatOnlyProvider ? "Chat only" : model.permissionLabel)
                    : model.selectedReasoningEffortName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: OnyxTypography.navigation, weight: .medium))
            .frame(minHeight: OnyxHitTarget.compact)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .onyxHelp(taskOptionsHelp)
        .accessibilityLabel("Task options")
        .accessibilityValue(taskOptionsAccessibilityValue)
    }

    private var compactOptionsMenu: some View {
        Menu {
            minimalOptionsMenuContent
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.availableReasoningEfforts.isEmpty
                    ? (isChatOnlyProvider ? "text.bubble" : "slider.horizontal.3")
                    : "brain")
                    .foregroundStyle(.secondary)
                if !model.availableReasoningEfforts.isEmpty {
                    Text(model.selectedReasoningEffortName)
                        .lineLimit(1)
                }
            }
            .font(.system(size: OnyxTypography.navigation, weight: .medium))
            .frame(
                minWidth: OnyxHitTarget.compact,
                minHeight: OnyxHitTarget.compact
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .onyxHelp(taskOptionsHelp)
        .accessibilityLabel("Task options")
        .accessibilityValue(taskOptionsAccessibilityValue)
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isSelectedReviewStarting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 29, height: 29)
                .onyxHelp("Starting code review")
        } else if model.isTurnRunning, isComposingNewTask {
            ProgressView()
                .controlSize(.small)
                .frame(width: 29, height: 29)
                .onyxHelp("Starting task")
                .accessibilityLabel("Starting task")
        } else if model.isTurnRunning {
            Button(action: model.interrupt) {
                ZStack {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 28, height: 28)

                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(OnyxTheme.canvas)
                }
                .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onyxHelp("Stop")
            .accessibilityLabel("Stop task")
        } else {
            Button(action: model.sendComposer) {
                ZStack {
                    Circle()
                        .fill(canSend ? AnyShapeStyle(OnyxTheme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.16)))
                        .frame(width: 29, height: 29)

                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary.opacity(0.58))
                }
                .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .onyxHelp("Send (Return)")
            .accessibilityLabel("Send message")
        }
    }

    @ViewBuilder
    private func modelChoiceButton(
        _ choice: OnyxApplicationHost.ProviderModelChoice,
        showsProvider: Bool = false
    ) -> some View {
        Button {
            if isComposingNewTask {
                onSelectProviderModel(choice)
            } else {
                model.selectTaskModel(choice.model.id)
            }
        } label: {
            let selected = choice.connection.id == selectedProviderConnectionID
                && choice.model.id == pickerSelectedModelID
            HStack {
                if selected { Image(systemName: "checkmark") }
                if showsProvider {
                    Text("\(choice.model.displayName) · \(choice.connection.displayName)")
                } else {
                    Text(choice.model.displayName)
                }
                if choice.model.capabilityEvidence.inputModalitiesAdvertised,
                   choice.model.inputModalities.contains(.image) {
                    Image(systemName: "photo")
                }
                if (choice.model.capabilityEvidence.reasoningEffortsAdvertised
                        || choice.model.capabilityEvidence.reasoningEffortsVerifiedByClient),
                   !choice.model.reasoningEfforts.isEmpty {
                    Image(systemName: "brain")
                }
                if choice.model.serverAdvertisesToolUse {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(OnyxTheme.warning)
                }
                if choice.model.capabilityMetadataIsUnknown {
                    Label("Capabilities unknown", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                } else if choice.model.capabilityMetadataIsPartial {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(
            showsProvider
                ? "\(choice.model.displayName), \(choice.connection.displayName)"
                : choice.model.displayName
        )
        .accessibilityValue(choice.model.pickerCapabilitySummary)
        .onyxHelp(choice.model.pickerCapabilitySummary)
    }
}

struct ComposerImagePreviewRow: View {
    let images: [ComposerImageDraft]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { draft in
                    ZStack(alignment: .topTrailing) {
                        ComposerDraftThumbnail(draft: draft)
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(OnyxTheme.border, lineWidth: OnyxTheme.hairline)
                            }
                            .accessibilityLabel("Attached image: \(draft.displayName)")

                        Button {
                            onRemove(draft.id)
                        } label: {
                            ZStack {
                                // Keep the painted glyph compact while giving
                                // the dismissal action the same forgiving
                                // acquisition area as the other composer
                                // controls.
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.white, Color.black.opacity(0.72))
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove \(draft.displayName)")
                        .accessibilityHint("Removes this image from the message")
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }
            }
        }
        .frame(height: 78)
        .accessibilityLabel("Message attachments")
    }
}

private struct ComposerDraftThumbnail: View {
    let draft: ComposerImageDraft

    @State private var thumbnail: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Image decoding (especially for pasted data URLs) is deliberately
        // outside `body`. SwiftUI reevaluates this view for every transcript
        // or draft mutation; doing a synchronous file read/base64 decode here
        // made typing and streaming contend with image work on the main actor.
        .task(id: draft.id) {
            guard thumbnail == nil, !didFail else { return }
            do {
                let image = try await TranscriptImageLoader.shared.loadThumbnail(
                    from: draft.timelineAttachment.source,
                    cacheIdentity: "composer-preview:\(draft.id.uuidString)",
                    maximumPixelSize: 160
                )
                guard !Task.isCancelled else { return }
                thumbnail = image
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                didFail = true
            }
        }
    }
}
