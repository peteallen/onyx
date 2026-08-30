import SwiftUI

struct ConversationWorkspaceView: View {
    @ObservedObject var model: OnyxAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation
    /// The parent owns compact pane arbitration, so the header can describe
    /// what is actually visible rather than only the persisted preference.
    var sidebarDisplayed: Bool?
    var onShowSidebar: (@MainActor () -> Void)?
    var workspaceProjectName: String? = nil
    var workspaceProjectPath: String? = nil
    var onOpenWorkspaceSwitcher: @MainActor () -> Void = {}
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
            let authenticationRecoveryActive = model.authenticationRecovery != nil
            let transcriptItems = AccountAccessPresentation.transcriptItems(
                model.transcriptSnapshot.items,
                recoveryActive: authenticationRecoveryActive
            )

            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    ConversationHeaderView(
                        model: model,
                        sidebarDisplayed: sidebarDisplayed ?? model.isSidebarVisible,
                        onShowSidebar: onShowSidebar ?? { model.isSidebarVisible = true },
                        workspaceProjectName: workspaceProjectName,
                        workspaceProjectPath: workspaceProjectPath,
                        onOpenWorkspaceSwitcher: onOpenWorkspaceSwitcher
                    )

                    ZStack {
                        ConversationHistoryViewport(
                            canLoadEarlierHistory: model.canLoadEarlierHistory,
                            isLoadingEarlierHistory: model.isLoadingEarlierHistory,
                            onLoadEarlierHistory: model.loadEarlierHistory
                        ) {
                            NativeTranscriptView(
                                items: transcriptItems,
                                isAwaitingResponse: (model.isTurnRunning
                                    || model.isSelectedReviewStarting
                                    || model.isPreparingFailedResponseRetryForSelectedThread)
                                    && model.activeUserInteraction == nil,
                                workingLabel: model.isPreparingFailedResponseRetryForSelectedThread
                                    ? "Preparing retry…"
                                    : (model.isReviewRunning || model.isSelectedReviewStarting
                                        ? "Reviewing changes…"
                                        : "Working on a response…"),
                                // Filtering is presentation-only and can
                                // change while the durable transcript revision
                                // stays fixed. Disable revision shortcuts for
                                // that state so the native collection removes
                                // the superseded auth row immediately.
                                revision: authenticationRecoveryActive
                                    ? nil
                                    : model.transcriptSnapshot.revision,
                                changeHint: authenticationRecoveryActive
                                    ? nil
                                    : model.transcriptSnapshot.changeHint,
                                editableUserMessageID: model.latestEditableUserMessageID,
                                // A failed turn may be retried only after the
                                // account can safely author a new provider
                                // operation. During reauthentication, the
                                // recovery surface owns the next action; a
                                // visible Retry would promise a second route
                                // that cannot succeed yet.
                                retryableFailedResponseItemID: model.canRunAgent
                                    ? model.retryableFailedResponseItemID
                                    : nil,
                                onEditUserMessage: { messageID in
                                    model.beginEditLatestUserMessage(
                                        messageID: messageID,
                                        window: windowPresentation.window
                                    )
                                },
                                onRetryFailedResponse: { responseItemID in
                                    guard model.canRunAgent else { return }
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

                    // Keep every short-state surface on the conversation's
                    // leading axis. Without an explicit alignment SwiftUI
                    // centers a capped approval card inside this wide stack.
                    // Twelve points also keeps the card/composer handoff
                    // readable without turning the bottom rail into a gap.
                    VStack(alignment: .leading, spacing: 12) {
                        if let interaction = model.activeUserInteraction {
                            UserInteractionView(model: model, interaction: interaction)
                                .id(interaction)
                        }

                        // A Codex account/read can fail before the first
                        // session snapshot is available. Recovery itself is
                        // sufficient evidence to mount the in-place card;
                        // otherwise the cold connecting state should stay
                        // quiet until a provider session exists.
                        if AccountAccessPresentation.shouldShow(
                            sessionAvailable: model.session != nil,
                            recoveryActive: model.authenticationRecovery != nil,
                            loginAttemptActive: model.loginAttempt != nil,
                            requiresAuthentication: model.authState.requiresAuthentication,
                            signedIn: model.authState.isSignedIn
                        ) {
                            AccountAccessStrip(model: model)
                        }

                        // Keep the queue projection out of the cold welcome
                        // path. A fresh task has no steering state, while a
                        // task that just entered auth recovery can stop
                        // reporting active work even though its accepted
                        // follow-up still needs to remain visible.
                        if PendingSteeringPresentation.shouldShow(
                            isTurnRunning: model.isTurnRunning,
                            messageCount: model.pendingSteeringMessagesForSelectedThread.count
                        ) {
                            PendingSteeringStrip(model: model)
                        }
                        RuntimeStatusStrip(model: model)
                        ProviderExecutionScopeStrip(model: model)
                        if model.isShowingArchivedThreads {
                            ArchivedThreadStrip(model: model)
                        } else {
                            ComposerView(
                                model: model,
                                composer: model.composerDraftModel,
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

/// Presentation for follow-ups submitted while a task is already running.
/// Steering is intentionally separate from the transcript: the provider owns
/// the durable user item, while this row makes the short acknowledgement gap
/// visible instead of making the cleared composer feel like it swallowed the
/// message.
enum PendingSteeringPresentation {
    static let rowHeight: CGFloat = 40

    /// The queue strip represents an accepted app-owned follow-up, not only
    /// an active provider turn.  Authentication recovery (and other terminal
    /// transitions) intentionally clears `isTurnRunning`; keep the strip
    /// mounted until the queued message is reconciled so a cleared composer
    /// never makes work appear lost.  A zero-message idle/new-task state still
    /// omits the strip entirely.
    static func shouldShow(isTurnRunning: Bool, messageCount: Int) -> Bool {
        isTurnRunning || messageCount > 0
    }

    static func title(for count: Int) -> String {
        count == 1 ? "Follow-up queued" : "\(count) follow-ups queued"
    }

    static func stateLabel(for state: PendingSteeringMessage.State) -> String {
        switch state {
        case .submitting: "Sending…"
        case .queued: "Queued for this response"
        }
    }

    static func messagePreview(for message: PendingSteeringMessage) -> String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return message.attachmentCount == 1
                ? "Image follow-up"
                : "\(message.attachmentCount) image follow-ups"
        }
        return trimmed
    }
}

private struct PendingSteeringStrip: View {
    @ObservedObject var model: OnyxAppModel

    private var messages: [PendingSteeringMessage] {
        model.pendingSteeringMessagesForSelectedThread
    }

    private var latestMessage: PendingSteeringMessage? { messages.last }

    var body: some View {
        if !messages.isEmpty {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(OnyxTheme.iris.opacity(0.16))
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OnyxTheme.electric)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(PendingSteeringPresentation.title(for: messages.count))
                        .font(.system(size: OnyxTypography.navigation, weight: .semibold))
                        // This strip represents active motion, so keep its
                        // headline in the same electric semantic lane as the
                        // arrow and count instead of falling back to glare-
                        // level primary white.
                        .foregroundStyle(OnyxTheme.electric)
                    if let latestMessage {
                        Text("\(PendingSteeringPresentation.stateLabel(for: latestMessage.state)) · \(PendingSteeringPresentation.messagePreview(for: latestMessage))")
                            .font(.system(size: OnyxTypography.secondary))
                            .foregroundStyle(OnyxTheme.quietText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if messages.count > 1 {
                    Text("\(messages.count)")
                        .font(.system(size: OnyxTypography.metadata, weight: .bold, design: .rounded))
                        .foregroundStyle(OnyxTheme.electric)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(OnyxTheme.iris.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: PendingSteeringPresentation.rowHeight, alignment: .leading)
            .background(OnyxTheme.iris.opacity(0.065))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OnyxTheme.iris.opacity(0.24), lineWidth: OnyxTheme.hairline)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
        }
    }

    private var accessibilityLabel: String {
        PendingSteeringPresentation.title(for: messages.count)
    }

    private var accessibilityValue: String {
        guard let latestMessage else { return "" }
        return "\(PendingSteeringPresentation.stateLabel(for: latestMessage.state)): \(PendingSteeringPresentation.messagePreview(for: latestMessage))"
    }
}

/// Models that remain on the plain OpenAI-compatible chat lane are useful
/// chat/reasoning backends, but that lane cannot execute Onyx's local
/// workspace tools. Capable models are projected onto the adaptive agent lane
/// and do not show this strip.
struct ProviderExecutionScopeStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        if ProviderExecutionScopePresentation.isChatOnly(
            session: model.session,
            selectedModel: model.selectedRuntimeModel,
            taskCapabilities: model.selectedThread?.taskCapabilities
        ) {
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
    /// Generic adaptive sessions intentionally keep `.tools` off the
    /// provider-wide capability set: tools belong to the selected model/task
    /// lane. Use the durable task projection first, then the selected model's
    /// execution mode, before falling back to the native session capability.
    /// This prevents a capable generic model from being labelled "Chat only"
    /// while its adaptive agent attempt is being prepared.
    static func isChatOnly(
        session: RuntimeSession?,
        selectedModel: RuntimeModel? = nil,
        taskCapabilities: RuntimeCapabilities? = nil
    ) -> Bool {
        if let taskCapabilities {
            return !taskCapabilities.contains(.tools)
        }
        if let selectedModel {
            if let capabilities = selectedModel.taskCapabilities {
                return !capabilities.contains(.tools)
            }
            switch selectedModel.executionMode {
            case .agent:
                return false
            case .chat, .checkingAgent:
                return true
            case .inherited:
                break
            }
        }
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
    /// Preserve a meaningful slice of the parent conversation whenever the
    /// panel shares its width. Below this threshold the panel becomes a full
    /// overlay instead of leaving a narrow, unusable strip of the main task.
    static let minimumConversationWidth: CGFloat = 320
    static let splitLayoutMinimumWidth: CGFloat = 640
    static let compactHorizontalInset: CGFloat = 20

    let panelWidth: CGFloat

    static func resolve(availableWidth: CGFloat) -> Self {
        guard availableWidth.isFinite, availableWidth > 0 else {
            return Self(panelWidth: 0)
        }

        // At compact widths Side Chat owns the whole conversation surface.
        // This keeps its editor and transcript useful and avoids a 40–100 pt
        // sliver of parent content that reads like a broken split view.
        if availableWidth < splitLayoutMinimumWidth {
            return Self(panelWidth: availableWidth)
        }

        let boundedAvailable = max(
            minimumWidth,
            availableWidth - compactHorizontalInset
        )
        let maximumForSplit = max(
            minimumWidth,
            availableWidth - minimumConversationWidth
        )
        let width = min(maximumWidth, max(minimumWidth, min(preferredWidth, boundedAvailable)))
        return Self(panelWidth: min(width, maximumForSplit))
    }
}

struct ConversationHeaderPresentation: Equatable {
    static let headerHeight = OnyxWorkspaceMetrics.paneHeaderHeight
    static let minimumSwitcherTargetHeight = OnyxHitTarget.compact

    let taskTitle: String
    let workspaceName: String
    let workspacePath: String?
    let branchName: String?

    var contextLabel: String {
        guard let branchName else { return workspaceName }
        return "\(workspaceName) · \(branchName)"
    }

    var helpText: String {
        let workspace = workspacePath ?? "Choose a project or worktree"
        guard let branchName else { return workspace }
        return "\(workspace) · branch \(branchName)"
    }

    var accessibilityValue: String {
        let workspace = workspacePath ?? "not selected"
        guard let branchName else {
            return "Task \(taskTitle). Workspace \(workspace)."
        }
        return "Task \(taskTitle). Workspace \(workspace). Branch \(branchName)."
    }

    static func resolve(
        taskTitle: String?,
        workspacePath: String?,
        workspaceProjectName: String? = nil,
        workspaceProjectPath: String? = nil,
        branch: String?,
        isShowingArchivedThreads: Bool
    ) -> Self {
        let title = nonEmpty(taskTitle)
            ?? (isShowingArchivedThreads ? "Archived tasks" : "New task")
        let path = nonEmpty(workspacePath)
        let workspaceName = workspaceDisplayName(
            workspacePath: path,
            projectName: nonEmpty(workspaceProjectName),
            projectPath: nonEmpty(workspaceProjectPath)
        )

        return Self(
            taskTitle: title,
            workspaceName: workspaceName,
            workspacePath: path,
            branchName: nonEmpty(branch)
        )
    }

    private static func workspaceDisplayName(
        workspacePath: String?,
        projectName: String?,
        projectPath: String?
    ) -> String {
        guard let workspacePath else { return "Choose workspace" }
        let normalizedWorkspace = ProjectPathNormalizer.normalize(workspacePath)
            ?? workspacePath

        if let projectName,
           let projectPath,
           let normalizedProject = ProjectPathNormalizer.normalize(projectPath),
           ProjectPathNormalizer.contains(normalizedWorkspace, inside: normalizedProject) {
            let projectComponents = NSString(string: normalizedProject).pathComponents
            let workspaceComponents = NSString(string: normalizedWorkspace).pathComponents
            let relative = workspaceComponents
                .dropFirst(projectComponents.count)
                .joined(separator: "/")
            return relative.isEmpty ? projectName : "\(projectName) / \(relative)"
        }

        let workspaceURL = URL(fileURLWithPath: normalizedWorkspace)
        let checkoutName = workspaceURL.lastPathComponent
        let parentName = workspaceURL.deletingLastPathComponent().lastPathComponent
        if parentName.hasSuffix(".worktrees") {
            let projectName = String(parentName.dropLast(".worktrees".count))
            if !projectName.isEmpty, !checkoutName.isEmpty {
                return "\(projectName) / \(checkoutName)"
            }
        }
        return checkoutName.isEmpty ? normalizedWorkspace : checkoutName
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private struct ConversationHeaderView: View {
    @ObservedObject var model: OnyxAppModel
    let sidebarDisplayed: Bool
    let onShowSidebar: @MainActor () -> Void
    let workspaceProjectName: String?
    let workspaceProjectPath: String?
    let onOpenWorkspaceSwitcher: @MainActor () -> Void
    @Environment(\.onyxWindowPresentationContext) private var windowPresentation

    var body: some View {
        let presentation = ConversationHeaderPresentation.resolve(
            taskTitle: model.selectedThread?.title,
            workspacePath: model.selectedProjectPath,
            workspaceProjectName: workspaceProjectName,
            workspaceProjectPath: workspaceProjectPath,
            branch: model.selectedThread?.branch,
            isShowingArchivedThreads: model.isShowingArchivedThreads
        )

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

            Button(action: onOpenWorkspaceSwitcher) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(OnyxTheme.electric.opacity(0.78))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(presentation.taskTitle)
                            .font(.system(size: OnyxTypography.paneTitle, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(presentation.contextLabel)
                            .font(.system(size: OnyxTypography.metadata, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: ConversationHeaderPresentation.minimumSwitcherTargetHeight,
                    alignment: .leading
                )
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onyxHelp("\(presentation.helpText)\nOpen workspace switcher (⌘K)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Switch workspace")
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityHint("Opens the project, worktree, and task switcher")

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
        .frame(height: ConversationHeaderPresentation.headerHeight)
        .background(OnyxTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OnyxTheme.divider)
                .frame(height: OnyxTheme.hairline)
        }
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
                    .foregroundStyle(OnyxTheme.canvas)
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
        // Authentication recovery owns the connection failure copy. Hiding
        // this generic strip prevents the raw account/read diagnostic (or a
        // second reconnect action) from competing with the attached Sign In
        // surface, including when the failure happened before `session` was
        // populated.
        // A confirmed logout has the same ownership rule. Codex may emit a
        // final process-stop event after the account boundary is cleared; it
        // is not a second actionable connection failure.
        if model.authenticationRecovery != nil
            || model.isSignedOutBoundaryActive
            || (model.session != nil
                && model.authState.requiresAuthentication
                && !model.authState.isSignedIn) {
            EmptyView()
        } else {
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

/// Copy and geometry for the account-recovery surface. Keep this separate
/// from the SwiftUI layout so the moment a session expires has a stable,
/// testable product contract instead of becoming another generic alert.
enum AccountAccessPresentation {
    static let minimumHeight: CGFloat = 72
    static let settingsActionTitle = "Open Settings"
    private static let legacyAuthenticationRecoveryDetail =
        "Your ChatGPT sign-in is no longer valid. Sign in again to continue. Your task and draft are still here."

    enum Action: Hashable {
        case openSettings(prominent: Bool)
        case moreSignInOptions
        case signIn(runtimeName: String)

        var title: String {
            switch self {
            case .openSettings: AccountAccessPresentation.settingsActionTitle
            case .moreSignInOptions: "More sign-in options"
            case .signIn: "Sign In"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .openSettings: "Open account settings"
            case .moreSignInOptions: "More sign-in options"
            case let .signIn(runtimeName): "Sign in to \(runtimeName)"
            }
        }

        var accessibilityHint: String {
            switch self {
            case .openSettings: "Review sign-in options without leaving this task"
            case .moreSignInOptions: "Choose device-code sign in"
            case .signIn: "Opens secure sign in; your current draft stays in Onyx"
            }
        }

        var minimumHeight: CGFloat { OnyxHitTarget.row }
    }

    static func idleActions(
        hasLoginMethod: Bool,
        hasDeviceCodeMethod: Bool,
        runtimeName: String
    ) -> [Action] {
        guard hasLoginMethod else { return [.openSettings(prominent: true)] }
        var actions: [Action] = [.openSettings(prominent: false)]
        if hasDeviceCodeMethod { actions.append(.moreSignInOptions) }
        actions.append(.signIn(runtimeName: runtimeName))
        return actions
    }

    /// The attached recovery card owns the actionable authentication state.
    /// Keep provider history untouched, but do not repeat the same state as a
    /// failure-styled transcript row while the card is present.
    static func transcriptItems(
        _ items: [TimelineItem],
        recoveryActive: Bool
    ) -> [TimelineItem] {
        guard recoveryActive else { return items }
        return items.filter { !isAuthenticationRecoveryItem($0) }
    }

    static func isAuthenticationRecoveryItem(_ item: TimelineItem) -> Bool {
        guard item.kind == .error else { return false }
        let normalizedTitle = item.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedTitle == "sign in required"
            || normalizedTitle == "sign in again to continue" {
            return true
        }
        if item.body == RuntimeAuthenticationRecovery.signInExpired.detail
            || item.body == legacyAuthenticationRecoveryDetail {
            return true
        }
        return CodexProjection.isAuthenticationRecoveryDiagnostic(item.body)
    }

    /// Recovery is allowed to mount before a provider session exists. A
    /// regular signed-out card still waits for a session so the cold startup
    /// frame does not flash an action-less account row.
    static func shouldShow(
        sessionAvailable: Bool,
        recoveryActive: Bool,
        loginAttemptActive: Bool,
        requiresAuthentication: Bool,
        signedIn: Bool
    ) -> Bool {
        recoveryActive
            || (sessionAvailable
                && (loginAttemptActive || (requiresAuthentication && !signedIn)))
    }

    static func signedOutTitle(isCodex: Bool, runtimeName: String) -> String {
        isCodex ? "Codex is signed out" : "\(runtimeName) needs credentials"
    }

    static func signedOutDetail(isCodex: Bool, runtimeName: String) -> String {
        if isCodex {
            return "Your draft is safe here. Sign in again to send it or continue this task."
        }
        return "Your draft is safe here. Add or replace credentials for \(runtimeName) to continue."
    }

    static func primaryActionTitle(hasLoginMethod: Bool) -> String {
        hasLoginMethod ? "Sign In" : "Open Settings"
    }

    static func resumeActionTitle(hasDeviceCode: Bool) -> String {
        hasDeviceCode ? "Open Sign In" : "Open Sign In Again"
    }

}

private struct AccountAccessStrip: View {
    @ObservedObject var model: OnyxAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(recoveryTint.opacity(0.14))
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(recoveryTint)
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: OnyxTypography.navigation, weight: .semibold))
                        .foregroundStyle(OnyxTheme.strongText)
                    if let code = model.loginAttempt?.userCode {
                        Text(code)
                            .font(.system(size: OnyxTypography.reading, weight: .bold, design: .monospaced))
                            .foregroundStyle(OnyxTheme.strongText)
                            .textSelection(.enabled)
                    } else {
                        Text(detail)
                            .font(.system(size: OnyxTypography.secondary))
                            .foregroundStyle(OnyxTheme.readingText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    actionButtons
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: AccountAccessPresentation.minimumHeight, alignment: .leading)
        .background(recoveryTint.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(recoveryTint.opacity(0.30), lineWidth: OnyxTheme.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account recovery")
    }

    private var title: String {
        guard let attempt = model.loginAttempt else {
            if let recovery = model.authenticationRecovery { return recovery.title }
            if model.authState.requiresAuthentication, !model.authState.isSignedIn {
                return AccountAccessPresentation.signedOutTitle(
                    isCodex: model.session?.runtime == .codex,
                    runtimeName: model.runtimeDisplayName
                )
            }
            return "Sign in to run \(model.runtimeDisplayName)"
        }
        return attempt.method.ceremony == .deviceCode ? "Enter this one-time code" : "Finish signing in in your browser"
    }

    private var detail: String {
        if let detail = model.loginAttempt?.method.detail { return detail }
        if let recovery = model.authenticationRecovery { return recovery.detail }
        if model.authState.requiresAuthentication, !model.authState.isSignedIn {
            return AccountAccessPresentation.signedOutDetail(
                isCodex: model.session?.runtime == .codex,
                runtimeName: model.runtimeDisplayName
            )
        }
        return "Your credentials stay with \(model.runtimeDisplayName) and are never copied into Onyx."
    }

    private var iconName: String {
        if model.loginAttempt != nil { return "person.badge.clock" }
        return model.primaryLoginMethod == nil ? "key.slash" : "person.crop.circle.badge.exclamationmark"
    }

    private var recoveryTint: Color {
        model.loginAttempt == nil ? OnyxTheme.warning : OnyxTheme.iris
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let attempt = model.loginAttempt {
            if attempt.userCode != nil {
                Button("Copy Code", action: model.copyDeviceCode)
                    .buttonStyle(.borderless)
                    .frame(minHeight: OnyxHitTarget.row)
                    .contentShape(Rectangle())
            }
            secondarySettingsAction
            Button(
                AccountAccessPresentation.resumeActionTitle(hasDeviceCode: attempt.userCode != nil),
                action: model.reopenLoginPage
            )
            .buttonStyle(.borderedProminent)
            .tint(OnyxTheme.iris)
            .foregroundStyle(OnyxTheme.canvas)
            .controlSize(.small)
            .frame(minHeight: OnyxHitTarget.row)
            .contentShape(Rectangle())
            Button("Cancel", action: model.cancelLogin)
                .buttonStyle(.borderless)
                .disabled(model.isAuthenticating)
                .frame(minHeight: OnyxHitTarget.row)
                .contentShape(Rectangle())
        } else if model.isAuthenticating {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Opening secure sign in…")
                    .font(.system(size: OnyxTypography.secondary))
                    .foregroundStyle(OnyxTheme.readingText)
            }
            .frame(minHeight: OnyxHitTarget.row)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Opening secure sign in")
        } else {
            ForEach(idleActions, id: \.self) { action in
                idleAction(action)
            }
        }
    }

    private var idleActions: [AccountAccessPresentation.Action] {
        AccountAccessPresentation.idleActions(
            hasLoginMethod: model.primaryLoginMethod != nil,
            hasDeviceCodeMethod: model.deviceCodeLoginMethod != nil,
            runtimeName: model.runtimeDisplayName
        )
    }

    @ViewBuilder
    private func idleAction(_ action: AccountAccessPresentation.Action) -> some View {
        switch action {
        case let .openSettings(prominent):
            if prominent {
                SettingsLink {
                    Text(action.title)
                }
                .buttonStyle(.borderedProminent)
                .tint(OnyxTheme.iris)
                .foregroundStyle(OnyxTheme.canvas)
                .controlSize(.small)
                .frame(minHeight: action.minimumHeight)
                .contentShape(Rectangle())
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityHint(action.accessibilityHint)
            } else {
                settingsAction(action)
            }
        case .moreSignInOptions:
            if let deviceMethod = model.deviceCodeLoginMethod {
                Menu {
                    Button(deviceMethod.displayName) { model.startLogin(deviceMethod) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(minHeight: action.minimumHeight)
                .onyxHelp(action.title)
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityHint(action.accessibilityHint)
            }
        case .signIn:
            if let method = model.primaryLoginMethod {
                Button(action.title) {
                    model.startLogin(method)
                }
                .buttonStyle(.borderedProminent)
                .tint(OnyxTheme.iris)
                .foregroundStyle(OnyxTheme.canvas)
                .controlSize(.small)
                .frame(minHeight: action.minimumHeight)
                .contentShape(Rectangle())
                .accessibilityLabel(action.accessibilityLabel)
                .accessibilityHint(action.accessibilityHint)
            }
        }
    }

    private var secondarySettingsAction: some View {
        settingsAction(.openSettings(prominent: false))
    }

    private func settingsAction(_ action: AccountAccessPresentation.Action) -> some View {
        SettingsLink {
            Text(action.title)
        }
        .buttonStyle(.borderless)
        .frame(minHeight: action.minimumHeight)
        .contentShape(Rectangle())
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityHint(action.accessibilityHint)
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
        userRequestedExpansion: Bool,
        automaticCompactionEnabled: Bool = false
    ) -> Bool {
        // Keep the compact presentation as a reusable visual primitive, but do
        // not automatically replace the native editor while work is running.
        // A draft must always have a visible, editable surface; the transcript
        // owns the waiting/progress indication instead. The explicit opt-in is
        // reserved for a future surface that can guarantee an alternate editor.
        guard automaticCompactionEnabled else { return false }

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
    @ObservedObject var composer: OnyxComposerDraftModel
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
        ProviderExecutionScopePresentation.isChatOnly(
            session: model.session,
            selectedModel: model.selectedRuntimeModel,
            taskCapabilities: model.selectedThread?.taskCapabilities
        )
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
            && model.canQueueFollowUp
            && !model.isPreparingLatestMessageEditForSelectedThread
            && !interactionBlocksComposer
            && !model.isReviewBlockingComposer
            && (!composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !composer.images.isEmpty)
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
            draftText: composer.text,
            attachmentCount: composer.images.count,
            canInterrupt: model.supports(.interruption),
            isComposingNewTask: isComposingNewTask,
            userRequestedExpansion: userExpandedBusyComposer,
            automaticCompactionEnabled: false
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
            if !composer.images.isEmpty {
                ComposerImagePreviewRow(
                    images: composer.images,
                    onRemove: model.removeComposerImage
                )
                .padding(.horizontal, OnyxWorkspaceMetrics.composerInnerInset)
                .padding(.top, 10)
            }

            NativeComposerTextView(
                text: $composer.text,
                measuredHeight: $textHeight,
                // Keep drafting available across provider reconnects and
                // authentication gaps. `canSend` still gates submission, so
                // a draft can never be dispatched until the runtime is ready.
                isEnabled: model.canEditComposer,
                focusRequest: composer.focusRequest,
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
                    .foregroundStyle(OnyxTheme.warning)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(OnyxTheme.warning.opacity(0.10))
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
            HStack(spacing: 1) {
                if canSend {
                    Button(action: model.sendComposer) {
                        ZStack {
                            Circle()
                                .fill(OnyxTheme.accentGradient)
                                .frame(width: 29, height: 29)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(OnyxTheme.canvas)
                        }
                        .frame(width: OnyxHitTarget.compact, height: OnyxHitTarget.compact)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onyxHelp("Queue follow-up")
                    .accessibilityLabel("Queue follow-up")
                    .accessibilityHint("Sends this message into the active task without stopping it")
                }

                Button(action: model.interrupt) {
                    ZStack {
                        Circle()
                            .fill(OnyxTheme.warning)
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
            }
        } else {
            Button(action: model.sendComposer) {
                ZStack {
                    Circle()
                        .fill(canSend ? AnyShapeStyle(OnyxTheme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.16)))
                        .frame(width: 29, height: 29)

                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? OnyxTheme.canvas : Color.secondary.opacity(0.58))
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
