import AppKit
import Combine
import Foundation
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case summary
    case files
    case review

    var id: Self { self }

    var label: String {
        switch self {
        case .summary: "Summary"
        case .files: "Files"
        case .review: "Review"
        }
    }

    var icon: String {
        switch self {
        case .summary: "sidebar.right"
        case .files: "doc.on.doc"
        case .review: "arrow.triangle.branch"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var firstNonemptyLine: String? {
        split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

enum ThreadListScope: String, CaseIterable, Identifiable {
    case active
    case archived

    var id: Self { self }

    var label: String {
        switch self {
        case .active: "Tasks"
        case .archived: "Archived"
        }
    }
}

@MainActor
final class OnyxAppModel: ObservableObject {
    @Published var connectionState: RuntimeConnectionState = .disconnected
    @Published var session: RuntimeSession?
    @Published var authState = RuntimeAuthState.signedOut
    @Published var loginAttempt: RuntimeLoginStart?
    @Published var isAuthenticating = false
    @Published var isSigningOut = false
    @Published var threads: [RuntimeThread]
    @Published var selectedThreadID: String?
    @Published var timeline: [TimelineItem]
    @Published var composerText: String {
        didSet { scheduleComposerDraftSave() }
    }
    @Published private(set) var composerImages: [ComposerImageDraft]
    @Published var searchText = ""
    @Published var isSidebarVisible: Bool {
        didSet { preferences.set(isSidebarVisible, forKey: preferenceKey(PreferenceKey.sidebarVisible)) }
    }
    @Published var isInspectorVisible: Bool {
        didSet { preferences.set(isInspectorVisible, forKey: preferenceKey(PreferenceKey.inspectorVisible)) }
    }
    @Published var isBottomPanelVisible: Bool {
        didSet { preferences.set(isBottomPanelVisible, forKey: preferenceKey(PreferenceKey.bottomPanelVisible)) }
    }
    @Published var inspectorTab: InspectorTab {
        didSet { preferences.set(inspectorTab.rawValue, forKey: preferenceKey(PreferenceKey.inspectorTab)) }
    }
    @Published var isLoadingThread = false
    @Published var isTurnRunning = false
    @Published private(set) var reviewingThreadID: String?
    @Published private(set) var startingReviewThreadID: String?
    @Published private(set) var pendingUserInteractions: [RuntimeUserInteraction] = []
    @Published private(set) var respondingInteractionIDs: Set<RuntimeRequestID> = []
    @Published private(set) var collaborationAgents: [RuntimeCollaborationAgent] = []
    @Published private(set) var plansByThreadID: [String: RuntimePlan] = [:]
    @Published var notice: (title: String, detail: String)?
    @Published var selectedModelID: String? {
        didSet {
            if let selectedModelID {
                preferences.set(selectedModelID, forKey: preferenceKey(PreferenceKey.selectedModel))
            } else {
                preferences.removeObject(forKey: preferenceKey(PreferenceKey.selectedModel))
            }
            validateSelectedReasoningEffort()
        }
    }
    @Published var selectedReasoningEffort: String? {
        didSet {
            if let selectedReasoningEffort {
                preferences.set(selectedReasoningEffort, forKey: preferenceKey(PreferenceKey.reasoningEffort))
            } else {
                preferences.removeObject(forKey: preferenceKey(PreferenceKey.reasoningEffort))
            }
        }
    }
    @Published var permissionLabel: String {
        didSet { preferences.set(permissionLabel, forKey: preferenceKey(PreferenceKey.permissionLabel)) }
    }
    @Published var draftWorkspacePath: String?
    @Published var threadListScope: ThreadListScope {
        didSet { preferences.set(threadListScope.rawValue, forKey: preferenceKey(PreferenceKey.threadListScope)) }
    }
    @Published var isLoadingThreadList = false

    private let runtime: (any AgentRuntime)?
    private let startupError: (any Error)?
    private let preferences: UserDefaults
    private let preferenceNamespace: OnyxPreferenceNamespace
    private let pinnedThreadStore: OnyxPinnedThreadStore
    private let workspacePersistenceStore: OnyxWorkspacePersistenceStore?
    private var pinnedThreadCancellable: AnyCancellable?
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var connectionRevision: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var threadListTask: Task<Void, Never>?
    private var deltaFlushTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var accountRefreshTask: Task<Void, Never>?
    private struct DeltaKey: Hashable {
        let threadID: String
        let itemID: String
    }

    private var pendingDeltas: [DeltaKey: String] = [:]
    private var collaborationAgentsByID: [String: RuntimeCollaborationAgent] = [:]
    private var activeTurnIDsByThreadID: [String: String] = [:]
    private var liveTimelineRevisionByThreadID: [String: UInt64] = [:]
    private var liveItemRevisionByThreadID: [String: [String: UInt64]] = [:]
    private var livePlanRevisionByThreadID: [String: UInt64] = [:]
    private var pinnedThreadIDs: Set<String> { pinnedThreadStore.ids }
    private var composerDrafts: [String: String]
    /// Image drafts are intentionally session-only. Local file references and
    /// pasted image bytes are never written into preferences.
    private var composerImageDrafts: [String: [ComposerImageDraft]] = [:]
    private var composerDraftKey: String
    private struct InteractionDraftEntry<Value> {
        let interaction: RuntimeUserInteraction
        var value: Value
    }

    private var questionDrafts: [RuntimeRequestID: InteractionDraftEntry<RuntimeQuestionDraft>] = [:]
    private var formDrafts: [RuntimeRequestID: InteractionDraftEntry<RuntimeFormDraft>] = [:]
    private var pendingRestoredSelectionID: String?
    private var cancelledLoginID: String?
    private var didStart = false
    private var navigationRevision = 0
    /// Invalidates async work that began while a different provider account
    /// owned the visible task state.
    private var accountEpoch: UInt64 = 0

    private struct SendContext: Sendable {
        /// The exact composer contents before submission. The runtime receives
        /// `text`, but failures restore this value so whitespace and any text
        /// typed while the request was starting are never discarded.
        let draftText: String
        let text: String
        let images: [ComposerImageDraft]
        let inputs: [RuntimeTurnInput]
        let sourceDraftKey: String
        let provisionalDraftKey: String?
        let originThreadID: String?
        let isNewThread: Bool
        let cwd: String?
        let wasTurnRunning: Bool
        let modelID: String?
        let reasoningEffort: String?
        let sandboxMode: RuntimeSandboxMode
        let approvalPolicy: RuntimeApprovalPolicy
        let navigationRevision: Int
        let accountEpoch: UInt64
    }

    private enum PreferenceKey {
        static let sidebarVisible = "Onyx.sidebarVisible"
        static let inspectorVisible = "Onyx.inspectorVisible"
        static let bottomPanelVisible = "Onyx.bottomPanelVisible"
        static let inspectorTab = "Onyx.inspectorTab"
        static let selectedModel = "Onyx.selectedModelID"
        static let reasoningEffort = "Onyx.reasoningEffort"
        static let permissionLabel = "Onyx.permissionLabel"
        static let threadListScope = "Onyx.threadListScope"
        static let selectedThread = "Onyx.selectedThreadID"
        static let composerDrafts = "Onyx.composerDrafts"
    }

    private static let welcomeThread = RuntimeThread(
        id: "onyx:welcome",
        title: "Welcome to Onyx",
        preview: "A fast native workspace for coding agents",
        cwd: nil,
        updatedAt: .now,
        status: .idle,
        isPinned: true,
        runtime: .codex,
        model: nil,
        branch: nil
    )

    init(
        runtime: (any AgentRuntime)?,
        startupError: (any Error)? = nil,
        defaults: UserDefaults = .standard,
        preferenceKeyPrefix: String? = nil,
        pinnedThreadStore: OnyxPinnedThreadStore? = nil,
        workspacePersistenceStore: OnyxWorkspacePersistenceStore? = nil
    ) {
        let preferenceNamespace = OnyxPreferenceNamespace(prefix: preferenceKeyPrefix)
        let pinnedThreadStore = pinnedThreadStore ?? OnyxPinnedThreadStore(defaults: defaults)
        self.runtime = runtime
        self.startupError = startupError
        preferences = defaults
        self.preferenceNamespace = preferenceNamespace
        self.pinnedThreadStore = pinnedThreadStore
        self.workspacePersistenceStore = workspacePersistenceStore
        let restoredScope = defaults.string(forKey: preferenceNamespace.key(PreferenceKey.threadListScope))
            .flatMap(ThreadListScope.init(rawValue:)) ?? .active
        let restoredDrafts = defaults.dictionary(
            forKey: preferenceNamespace.key(PreferenceKey.composerDrafts)
        ) as? [String: String] ?? [:]

        draftWorkspacePath = defaults.string(forKey: preferenceNamespace.key("Onyx.lastWorkspacePath"))
        composerDrafts = restoredDrafts
        composerDraftKey = Self.welcomeThread.id
        composerText = restoredDrafts[Self.welcomeThread.id] ?? ""
        composerImages = []
        isSidebarVisible = Self.boolPreference(
            preferenceNamespace.key(PreferenceKey.sidebarVisible),
            default: true,
            defaults: defaults
        )
        isInspectorVisible = Self.boolPreference(
            preferenceNamespace.key(PreferenceKey.inspectorVisible),
            default: true,
            defaults: defaults
        )
        isBottomPanelVisible = Self.boolPreference(
            preferenceNamespace.key(PreferenceKey.bottomPanelVisible),
            default: false,
            defaults: defaults
        )
        inspectorTab = defaults.string(forKey: preferenceNamespace.key(PreferenceKey.inspectorTab))
            .flatMap(InspectorTab.init(rawValue:)) ?? .summary
        selectedModelID = defaults.string(forKey: preferenceNamespace.key(PreferenceKey.selectedModel))
        selectedReasoningEffort = defaults.string(forKey: preferenceNamespace.key(PreferenceKey.reasoningEffort))
        permissionLabel = defaults.string(forKey: preferenceNamespace.key(PreferenceKey.permissionLabel)) ?? "Workspace"
        threadListScope = restoredScope
        pendingRestoredSelectionID = defaults.string(forKey: preferenceNamespace.key(PreferenceKey.selectedThread))
        threads = restoredScope == .active ? [Self.welcomeThread] : []
        selectedThreadID = restoredScope == .active ? Self.welcomeThread.id : nil
        timeline = restoredScope == .active ? [.welcome()] : []

        pinnedThreadCancellable = pinnedThreadStore.$ids
            .dropFirst()
            .sink { [weak self] ids in
                self?.applyPinnedThreadIDs(ids)
            }

    }

    deinit {
        eventTask?.cancel()
        connectionTask?.cancel()
        loadTask?.cancel()
        threadListTask?.cancel()
        deltaFlushTask?.cancel()
        draftSaveTask?.cancel()
        accountRefreshTask?.cancel()
    }

    var selectedThread: RuntimeThread? {
        threads.first { $0.id == selectedThreadID }
    }

    var selectedPlan: RuntimePlan? {
        selectedThreadID.flatMap { plansByThreadID[$0] }
    }

    var selectedTaskAttention: RuntimeTaskAttention {
        guard let selectedThread else { return .ready }
        return taskAttention(for: selectedThread)
    }

    func taskAttention(for thread: RuntimeThread) -> RuntimeTaskAttention {
        if thread.status == .failed { return .failed }

        let interactions = pendingUserInteractions.filter { interaction in
            interaction.threadID == thread.id
                || (interaction.threadID == nil && selectedThreadID == thread.id)
        }
        if interactions.contains(where: { interaction in
            if case .approval = interaction.kind { return true }
            return false
        }) {
            return .needsApproval
        }
        if !interactions.isEmpty { return .needsInput }
        if isReviewActive(for: thread.id) { return .working }
        return thread.status.attention
    }

    var isShowingArchivedThreads: Bool {
        threadListScope == .archived
    }

    var isSelectedThreadArchived: Bool {
        isShowingArchivedThreads && selectedThreadID != nil
    }

    var canRunAgent: Bool {
        guard authState.canRun, !isSigningOut else { return false }
        if case .connected = connectionState { return true }
        return false
    }

    var canReconnect: Bool {
        guard didStart, runtime != nil else { return false }
        return switch connectionState {
        case .failed, .disconnected:
            true
        case .connecting, .connected:
            false
        }
    }

    var isReviewRunning: Bool {
        selectedThreadID != nil
            && reviewingThreadID == selectedThreadID
            && startingReviewThreadID != selectedThreadID
    }

    func isReviewActive(for threadID: String) -> Bool {
        reviewingThreadID == threadID || startingReviewThreadID == threadID
    }

    var isStartingReview: Bool {
        startingReviewThreadID != nil
    }

    var isSelectedReviewStarting: Bool {
        selectedThreadID != nil && startingReviewThreadID == selectedThreadID
    }

    var isReviewBlockingComposer: Bool {
        isReviewRunning || isSelectedReviewStarting
    }

    var canStartReview: Bool {
        guard canRunAgent,
              supports(.codeReview),
              !isShowingArchivedThreads,
              startingReviewThreadID == nil,
              reviewingThreadID == nil,
              let thread = selectedThread,
              thread.id != Self.welcomeThread.id else { return false }
        return !thread.status.isBusy
            && !hasPendingInteraction(for: thread.id, blockingOnly: true)
    }

    var activeUserInteraction: RuntimeUserInteraction? {
        guard canRunAgent, !isShowingArchivedThreads else { return nil }
        let eligible = pendingUserInteractions.filter { interaction in
            interaction.threadID == nil || interaction.threadID == selectedThreadID
        }
        return eligible.first(where: \.isBlocking) ?? eligible.first
    }

    func canForkThread(_ thread: RuntimeThread) -> Bool {
        !thread.status.isBusy
            && !isReviewActive(for: thread.id)
            && !hasPendingInteraction(for: thread.id, blockingOnly: true)
    }

    func canCompactThread(_ thread: RuntimeThread) -> Bool {
        canForkThread(thread)
    }

    func canArchiveThread(_ thread: RuntimeThread) -> Bool {
        !thread.status.isBusy
            && !isReviewActive(for: thread.id)
            && !hasPendingInteraction(for: thread.id, blockingOnly: false)
    }

    func isResponding(to interaction: RuntimeUserInteraction) -> Bool {
        respondingInteractionIDs.contains(interaction.id)
    }

    func questionDraft(for interaction: RuntimeUserInteraction) -> RuntimeQuestionDraft {
        guard let entry = questionDrafts[interaction.id], entry.interaction == interaction else {
            return RuntimeQuestionDraft()
        }
        return entry.value
    }

    func updateQuestionDraft(
        _ draft: RuntimeQuestionDraft,
        for interaction: RuntimeUserInteraction
    ) {
        guard pendingUserInteractions.contains(interaction) else { return }
        questionDrafts[interaction.id] = InteractionDraftEntry(interaction: interaction, value: draft)
    }

    func formDraft(for interaction: RuntimeUserInteraction) -> RuntimeFormDraft {
        guard let entry = formDrafts[interaction.id], entry.interaction == interaction else {
            return Self.defaultFormDraft(for: interaction)
        }
        return entry.value
    }

    func updateFormDraft(_ draft: RuntimeFormDraft, for interaction: RuntimeUserInteraction) {
        guard pendingUserInteractions.contains(interaction) else { return }
        formDrafts[interaction.id] = InteractionDraftEntry(interaction: interaction, value: draft)
    }

    var primaryLoginMethod: RuntimeLoginMethod? {
        session?.availableLoginMethods.first(where: { $0.ceremony == .browser })
            ?? session?.availableLoginMethods.first
    }

    var deviceCodeLoginMethod: RuntimeLoginMethod? {
        session?.availableLoginMethods.first(where: { $0.ceremony == .deviceCode })
    }

    var visibleThreads: [RuntimeThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return threads }
        return threads.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || ($0.cwd?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var projectName: String {
        let path = selectedThreadID == Self.welcomeThread.id
            ? draftWorkspacePath
            : selectedThread?.cwd
        return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose project"
    }

    var selectedModelName: String {
        guard let selectedModelID else {
            return session?.availableModels.first(where: \.isDefault)?.displayName
                ?? session?.availableModels.first?.displayName
                ?? "Codex"
        }
        return session?.availableModels.first(where: { $0.id == selectedModelID })?.displayName ?? selectedModelID
    }

    var availableReasoningEfforts: [String] {
        guard let model = session?.availableModels.first(where: { $0.id == selectedModelID }) else { return [] }
        return model.reasoningEfforts
    }

    var selectedReasoningEffortName: String {
        guard let selectedReasoningEffort else { return "Default" }
        switch selectedReasoningEffort.lowercased() {
        case "xhigh": return "X-High"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return selectedReasoningEffort.capitalized
        }
    }

    func supports(_ capability: RuntimeCapabilities) -> Bool {
        session?.capabilities.contains(capability) == true
    }

    var canAttachImages: Bool {
        supports(.images) && canRunAgent && !isSelectedThreadArchived
    }

    func chooseComposerImages(window: NSWindow?) {
        guard canAttachImages else {
            notice = ("Images are not available", "The selected runtime does not support image input for this task.")
            return
        }
        let epoch = accountEpoch
        let panel = NSOpenPanel()
        panel.title = "Attach images"
        panel.prompt = "Attach"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .heif]
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in
                guard let self, accountEpoch == epoch else { return }
                addComposerImageFiles(panel.urls)
            }
        }
        guard let window else { return }
        panel.beginSheetModal(for: window, completionHandler: completion)
    }

    func addComposerImageFiles(_ urls: [URL]) {
        addComposerImages(urls.map { url in
            Result { try ComposerImageValidator.localFile(at: url) }
        })
    }

    func addPastedComposerImages(_ images: [NSImage]) {
        addComposerImages(images.enumerated().map { index, image in
            Result {
                try ComposerImageValidator.pastedImage(
                    image,
                    name: images.count == 1 ? "Pasted image" : "Pasted image \(index + 1)"
                )
            }
        })
    }

    func removeComposerImage(id: UUID) {
        composerImages.removeAll { $0.id == id }
        saveCurrentImageDraftNow()
    }

    private func addComposerImages(_ results: [Result<ComposerImageDraft, any Error>]) {
        guard canAttachImages else {
            notice = ("Images are not available", "The selected runtime does not support image input for this task.")
            return
        }
        var accepted = composerImages
        var firstError: (any Error)?
        for result in results {
            guard accepted.count < ComposerImageValidator.maximumCount else {
                firstError = firstError ?? ComposerImageValidationError.tooMany(
                    maximum: ComposerImageValidator.maximumCount
                )
                break
            }
            do {
                accepted.append(try result.get())
            } catch {
                firstError = firstError ?? error
            }
        }
        composerImages = accepted
        saveCurrentImageDraftNow()
        if let firstError {
            notice = ("Could not attach image", firstError.localizedDescription)
        }
    }

    func selectModel(_ id: String) {
        selectedModelID = id
    }

    func selectReasoningEffort(_ effort: String) {
        guard availableReasoningEfforts.contains(effort) else { return }
        selectedReasoningEffort = effort
    }

    func startLogin(_ method: RuntimeLoginMethod) {
        guard let runtime, !isAuthenticating, loginAttempt == nil else { return }
        cancelledLoginID = nil
        isAuthenticating = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let attempt = try await runtime.startLogin(methodID: method.id)
                loginAttempt = attempt
                isAuthenticating = false

                let destination = attempt.authURL ?? attempt.verificationURL
                if let destination, !NSWorkspace.shared.open(destination) {
                    notice = (
                        "Could not open sign in",
                        "Open the sign-in page from Onyx Settings and try again."
                    )
                }
            } catch {
                isAuthenticating = false
                notice = authenticationFailure(for: error)
            }
        }
    }

    func reopenLoginPage() {
        guard let destination = loginAttempt?.authURL ?? loginAttempt?.verificationURL else { return }
        if !NSWorkspace.shared.open(destination) {
            notice = ("Could not open sign in", "Your browser could not open the sign-in page.")
        }
    }

    func copyDeviceCode() {
        guard let code = loginAttempt?.userCode, !code.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func cancelLogin() {
        guard let runtime, let attempt = loginAttempt, !isAuthenticating else { return }
        cancelledLoginID = attempt.loginID
        isAuthenticating = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.cancelLogin(id: attempt.loginID)
                if loginAttempt?.loginID == attempt.loginID { loginAttempt = nil }
                isAuthenticating = false
            } catch {
                cancelledLoginID = nil
                isAuthenticating = false
                notice = ("Could not cancel sign in", error.localizedDescription)
            }
        }
    }

    func signOut() {
        guard let runtime, authState.isSignedIn, !isSigningOut else { return }
        isSigningOut = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.logout()
                applyAuthProjection(.signedOut)
                closeAccountBoundary()
                let signedOutEpoch = accountEpoch
                isSigningOut = false
                do {
                    let refreshedSession = try await runtime.refreshAccount()
                    guard accountEpoch == signedOutEpoch,
                          !authState.isSignedIn,
                          !refreshedSession.auth.isSignedIn else { return }
                    applyRuntimeSession(refreshedSession)
                } catch {
                    // Logout already succeeded. Keep the local privilege barrier
                    // closed and let a later account event reconcile metadata.
                }
            } catch {
                isSigningOut = false
                notice = ("Could not sign out", error.localizedDescription)
            }
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        guard let runtime else {
            connectionState = .failed(startupError?.localizedDescription ?? "Codex is unavailable")
            return
        }

        eventTask = Task { [weak self, events = runtime.events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }

        beginConnection(preferredSelection: pendingRestoredSelectionID, rehydrateVisibleThread: false)
    }

    func reconnect() {
        guard canReconnect else { return }
        beginConnection(
            preferredSelection: selectedThreadID == Self.welcomeThread.id
                ? pendingRestoredSelectionID
                : nil,
            rehydrateVisibleThread: true
        )
    }

    private func beginConnection(
        preferredSelection: String?,
        rehydrateVisibleThread: Bool
    ) {
        guard let runtime else { return }

        connectionRevision &+= 1
        let revision = connectionRevision
        let epoch = accountEpoch
        connectionTask?.cancel()
        connectionState = .connecting
        if notice?.title == "Codex did not connect" {
            notice = nil
        }

        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if connectionRevision == revision {
                    connectionTask = nil
                }
            }
            do {
                let connectedSession = try await runtime.connect()
                guard accountEpoch == epoch,
                      connectionRevision == revision,
                      !Task.isCancelled else { return }
                applyRuntimeSession(connectedSession)
                let connectedState = RuntimeConnectionState.connected(
                    connectedSession.accountLabel ?? connectedSession.displayName
                )
                switch connectionState {
                case .connecting, .connected:
                    connectionState = connectedState
                case .failed, .disconnected:
                    // A stop event can win the race with a successful handshake.
                    // Do not let the late connect completion conceal that failure.
                    return
                }
            } catch {
                guard accountEpoch == epoch,
                      connectionRevision == revision,
                      !Task.isCancelled else { return }
                isLoadingThreadList = false
                connectionState = .failed(error.localizedDescription)
                notice = ("Codex did not connect", error.localizedDescription)
                return
            }

            let scope = threadListScope
            let selectionBeforeRefresh = selectedThreadID
            isLoadingThreadList = true
            do {
                let liveThreads = try await fetchThreads(in: scope)
                guard accountEpoch == epoch,
                      connectionRevision == revision,
                      !Task.isCancelled else { return }
                guard case .connected = connectionState else {
                    isLoadingThreadList = false
                    return
                }
                applyThreadList(
                    liveThreads,
                    scope: scope,
                    preferredSelection: preferredSelection
                )
                pendingRestoredSelectionID = nil

                if rehydrateVisibleThread,
                   selectedThreadID == selectionBeforeRefresh,
                   let selectedThreadID,
                   selectedThreadID != Self.welcomeThread.id {
                    resumeThreadAfterReconnect(selectedThreadID)
                }
            } catch {
                guard accountEpoch == epoch,
                      connectionRevision == revision,
                      !Task.isCancelled else { return }
                isLoadingThreadList = false
                notice = (
                    "Connected, but tasks did not refresh",
                    "Your existing tasks are still available. \(error.localizedDescription)"
                )
            }

        }
    }

    func selectThread(_ id: String) {
        guard selectedThreadID != id else { return }
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()

        navigationRevision += 1
        selectedThreadID = id
        preferences.set(id, forKey: preferenceKey(PreferenceKey.selectedThread))
        loadComposerDraft(for: id)
        loadTask?.cancel()
        isTurnRunning = threads.first(where: { $0.id == id }).map {
            $0.status.isBusy || isReviewActive(for: $0.id)
        } ?? false

        guard id != Self.welcomeThread.id, let runtime else {
            replaceTimeline([.welcome()])
            isLoadingThread = false
            return
        }

        rememberWorkspace(threads.first(where: { $0.id == id })?.cwd)

        isLoadingThread = true
        replaceTimeline([])
        let epoch = accountEpoch
        let liveRevisionAtReadStart = liveTimelineRevision(for: id)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conversation = try await runtime.readThread(id: id)
                guard accountEpoch == epoch, !Task.isCancelled, selectedThreadID == id else { return }
                applyConversationSnapshot(
                    conversation.items,
                    for: conversation.thread.id,
                    preservingLiveUpdatesAfter: liveRevisionAtReadStart
                )
                updateThread(conversation.thread)
                isTurnRunning = conversation.thread.status.isBusy
                    || isReviewActive(for: conversation.thread.id)
                isLoadingThread = false
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled, selectedThreadID == id else { return }
                isLoadingThread = false
                replaceTimeline([
                    TimelineItem(
                        id: UUID().uuidString,
                        kind: .error,
                        title: "Could not load this task",
                        body: error.localizedDescription,
                        status: .failed,
                        timestamp: .now,
                        detail: nil
                    ),
                ])
            }
        }
    }

    func newTask() {
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()
        navigationRevision += 1
        loadTask?.cancel()
        threadListTask?.cancel()
        threadListScope = .active
        selectedThreadID = Self.welcomeThread.id
        preferences.set(Self.welcomeThread.id, forKey: preferenceKey(PreferenceKey.selectedThread))
        composerDraftKey = Self.welcomeThread.id
        composerText = ""
        composerImages = []
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()
        if !threads.contains(where: { $0.id == Self.welcomeThread.id }) {
            threads.insert(Self.welcomeThread, at: 0)
        }
        replaceTimeline([.welcome()])
        isTurnRunning = false
    }

    /// Commits debounced window-owned state before its scene is released.
    /// Without this hook, pressing Command-W immediately after typing can
    /// cancel the pending draft write in deinit.
    func flushWindowState() {
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()
    }

    func setThreadListScope(_ scope: ThreadListScope) {
        guard scope != threadListScope, runtime != nil else { return }
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()
        navigationRevision += 1
        threadListTask?.cancel()
        loadTask?.cancel()
        threadListScope = scope
        threads = scope == .active ? [Self.welcomeThread] : []
        selectedThreadID = nil
        composerDraftKey = Self.welcomeThread.id
        composerText = composerDrafts[composerDraftKey] ?? ""
        composerImages = composerImageDrafts[composerDraftKey] ?? []
        replaceTimeline([])
        isTurnRunning = false
        isLoadingThread = false
        isLoadingThreadList = true

        let epoch = accountEpoch
        threadListTask = Task { [weak self] in
            guard let self else { return }
            do {
                let liveThreads = try await fetchThreads(in: scope)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                applyThreadList(liveThreads, scope: scope)
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled, threadListScope == scope else { return }
                isLoadingThreadList = false
                notice = ("Could not load \(scope.label.lowercased())", error.localizedDescription)
            }
        }
    }

    func chooseWorkspace(window: NSWindow?) {
        let epoch = accountEpoch
        let panel = NSOpenPanel()
        panel.title = "Choose a project for Onyx"
        panel.prompt = "Use Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let draftWorkspacePath {
            panel.directoryURL = URL(fileURLWithPath: draftWorkspacePath)
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { @MainActor [weak self] in
                guard let self, accountEpoch == epoch else { return }
                selectWorkspace(path)
            }
        }
        guard let window else { return }
        panel.beginSheetModal(for: window, completionHandler: completion)
    }

    /// Applies a folder chosen by the user. If they are already composing a
    /// new task (including after the "Choose a project" send validation), the
    /// existing draft belongs to that task and must survive the folder change.
    func selectWorkspace(_ path: String) {
        let isComposingNewTask = threadListScope == .active
            && (selectedThreadID == nil || selectedThreadID == Self.welcomeThread.id)
        if isComposingNewTask {
            saveCurrentDraftNow()
            saveCurrentImageDraftNow()
        }
        rememberWorkspace(path)
        if !isComposingNewTask {
            newTask()
        }
    }

    func sendComposer() {
        let draftText = composerText
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = composerImages
        guard !text.isEmpty || !images.isEmpty else { return }

        // Make the typed text durable before any validation or provider call.
        // The later clear remains optimistic on a valid submission.
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()

        guard images.count <= ComposerImageValidator.maximumCount else {
            notice = (
                "Too many images",
                "Keep up to \(ComposerImageValidator.maximumCount) attachments and try again. Your draft is still here."
            )
            return
        }

        guard !isSelectedThreadArchived else { return }
        guard !isReviewBlockingComposer else {
            notice = (
                "Review is still running",
                "Wait for the code review to finish or stop it before sending another message. Your draft is still here."
            )
            return
        }
        guard let runtime else {
            notice = (
                "Codex is unavailable",
                startupError?.localizedDescription ?? "Onyx could not start its Codex runtime. Your draft is still here."
            )
            return
        }
        guard activeUserInteraction?.isBlocking != true else {
            notice = (
                "Answer the pending request first",
                "Codex is waiting for your response before this task can continue."
            )
            return
        }
        guard canRunAgent else {
            notice = (
                "Sign in to continue",
                "Connect your ChatGPT account before starting or continuing a Codex task."
            )
            return
        }
        guard images.isEmpty || supports(.images) else {
            notice = (
                "Images are not available",
                "The selected runtime cannot receive these attachments. Remove them or switch runtimes; your draft is still here."
            )
            return
        }
        if selectedThreadID == nil || selectedThreadID == Self.welcomeThread.id {
            guard draftWorkspacePath != nil else {
                notice = ("Choose a project", "Select the folder Onyx should work in before starting a task.")
                return
            }
        }

        let originThread = selectedThread
        let originThreadID = selectedThreadID
        let isNewThread = originThreadID == nil || originThreadID == Self.welcomeThread.id
        let sourceDraftKey = composerDraftKey
        let provisionalDraftKey = isNewThread ? "onyx:pending:\(UUID().uuidString)" : nil
        let inputs: [RuntimeTurnInput] = (text.isEmpty ? [] : [.text(text)]) + images.map(\.input)
        let context = SendContext(
            draftText: draftText,
            text: text,
            images: images,
            inputs: inputs,
            sourceDraftKey: sourceDraftKey,
            provisionalDraftKey: provisionalDraftKey,
            originThreadID: originThreadID,
            isNewThread: isNewThread,
            cwd: isNewThread ? draftWorkspacePath : originThread?.cwd,
            wasTurnRunning: originThread.map(\.status.isBusy) ?? isTurnRunning,
            modelID: selectedModelID,
            reasoningEffort: selectedReasoningEffort,
            sandboxMode: selectedSandboxMode,
            approvalPolicy: selectedApprovalPolicy,
            navigationRevision: navigationRevision,
            accountEpoch: accountEpoch
        )

        composerText = ""
        saveCurrentDraftNow()
        composerImages = []
        saveCurrentImageDraftNow()
        if let provisionalDraftKey {
            composerDraftKey = provisionalDraftKey
            composerText = composerDrafts[provisionalDraftKey] ?? ""
            composerImages = composerImageDrafts[provisionalDraftKey] ?? []
        }

        Task { [weak self] in
            guard let self else { return }
            var failureDraftKey = context.sourceDraftKey
            var targetThreadID = context.originThreadID
            var createdThread = false
            do {
                if context.isNewThread {
                    guard let cwd = context.cwd else { return }
                    let thread = try await runtime.startThread(
                        StartThreadRequest(
                            cwd: cwd,
                            model: context.modelID,
                            sandboxMode: context.sandboxMode,
                            approvalPolicy: context.approvalPolicy
                        )
                    )
                    guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                    targetThreadID = thread.id
                    failureDraftKey = thread.id
                    createdThread = true
                    if threadListScope == .active {
                        threads.removeAll { $0.id == Self.welcomeThread.id }
                        updateThread(thread)
                    }
                    movePendingDraft(
                        from: context.provisionalDraftKey,
                        to: thread.id,
                        selecting: thread,
                        ifNavigationRevisionIs: context.navigationRevision
                    )
                }

                guard let threadID = targetThreadID else { return }
                if context.wasTurnRunning {
                    if !context.images.isEmpty,
                       selectedThreadID == threadID,
                       navigationRevision == context.navigationRevision {
                        timeline.append(
                            TimelineItem(
                                id: "optimistic:\(UUID().uuidString)",
                                kind: .userMessage,
                                title: nil,
                                body: context.text,
                                status: .completed,
                                timestamp: .now,
                                detail: nil,
                                attachments: context.images.map(\.timelineAttachment)
                            )
                        )
                    }
                    try await runtime.steer(threadID: threadID, inputs: context.inputs)
                    guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                } else {
                    if !createdThread {
                        let conversation = try await runtime.resumeThread(id: threadID)
                        guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                        if selectedThreadID == threadID,
                           navigationRevision == context.navigationRevision {
                            replaceTimeline(conversation.items, authoritativeFor: conversation.thread.id)
                        }
                        updateThread(conversation.thread)
                    }

                    if selectedThreadID == threadID,
                       (createdThread || navigationRevision == context.navigationRevision) {
                        timeline.append(
                            TimelineItem(
                                id: "optimistic:\(UUID().uuidString)",
                                kind: .userMessage,
                                title: nil,
                                body: context.text,
                                status: .completed,
                                timestamp: .now,
                                detail: nil,
                                attachments: context.images.map(\.timelineAttachment)
                            )
                        )
                        isTurnRunning = true
                    }
                    if let index = threads.firstIndex(where: { $0.id == threadID }) {
                        threads[index].status = .running
                        threads[index].updatedAt = .now
                    }
                    try await runtime.startTurn(
                        StartTurnRequest(
                            threadID: threadID,
                            inputs: context.inputs,
                            model: context.modelID,
                            cwd: context.cwd,
                            reasoningEffort: context.reasoningEffort,
                            sandboxMode: context.sandboxMode,
                            approvalPolicy: context.approvalPolicy
                        )
                    )
                    guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                }
            } catch {
                guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                if context.isNewThread, !createdThread {
                    restoreFailedNewTaskSend(context)
                } else {
                    restoreFailedSend(context.draftText, for: failureDraftKey)
                    restoreFailedImages(context.images, for: failureDraftKey)
                }
                let failure = sendFailureMessage(for: error)
                notice = failure
                if let targetThreadID,
                   let index = threads.firstIndex(where: { $0.id == targetThreadID }) {
                    threads[index].status = .idle
                }
                if selectedThreadID == targetThreadID
                    || (targetThreadID == nil && navigationRevision == context.navigationRevision) {
                    isTurnRunning = false
                    timeline.append(
                        TimelineItem(
                            id: UUID().uuidString,
                            kind: .error,
                            title: failure.title,
                            body: failure.detail,
                            status: .failed,
                            timestamp: .now,
                            detail: nil
                        )
                    )
                }
            }
        }
    }

    func interrupt() {
        guard let id = selectedThreadID, let runtime else { return }
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.interrupt(threadID: id)
            } catch {
                guard accountEpoch == epoch else { return }
                notice = ("Could not stop the task", error.localizedDescription)
            }
        }
    }

    func startReview() {
        guard let runtime, let thread = selectedThread else { return }
        guard canStartReview else {
            if isTurnRunning || isStartingReview || reviewingThreadID != nil {
                notice = (
                    "Task is still active",
                    "Finish or stop the current task before starting a code review."
                )
            }
            return
        }

        let threadID = thread.id
        let originalStatus = thread.status
        let epoch = accountEpoch
        let revision = navigationRevision
        startingReviewThreadID = threadID
        // Track the review before awaiting the response because app-server may
        // deliver turn notifications while `review/start` is still pending.
        reviewingThreadID = threadID
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].status = .running
            threads[index].updatedAt = .now
        }
        if selectedThreadID == threadID { isTurnRunning = true }

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await runtime.startReview(
                    StartReviewRequest(threadID: threadID)
                )
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                guard reviewingThreadID == threadID else {
                    // The review completed while the start response was in
                    // flight. Do not resurrect its busy state.
                    startingReviewThreadID = nil
                    return
                }
                startingReviewThreadID = nil
                if let index = threads.firstIndex(where: { $0.id == threadID }) {
                    threads[index].status = .running
                    threads[index].updatedAt = .now
                }
                if selectedThreadID == threadID, navigationRevision == revision {
                    isTurnRunning = true
                }
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                if startingReviewThreadID == threadID { startingReviewThreadID = nil }
                if reviewingThreadID == threadID { reviewingThreadID = nil }
                if let index = threads.firstIndex(where: { $0.id == threadID }),
                   threads[index].status == .running {
                    threads[index].status = originalStatus
                }
                if selectedThreadID == threadID {
                    isTurnRunning = originalStatus.isBusy
                }
                let detail: String
                if case let AgentRuntimeError.requestFailed(_, message) = error,
                   message.localizedCaseInsensitiveContains("active writer") {
                    detail = "This task is actively open in another Codex window. Let that work finish, then try the review again."
                } else {
                    detail = error.localizedDescription
                }
                if selectedThreadID == threadID, navigationRevision == revision {
                    notice = ("Could not start code review", detail)
                }
            }
        }
    }

    func respond(
        to interaction: RuntimeUserInteraction,
        with response: RuntimeUserInteractionResponse
    ) {
        guard canRunAgent,
              pendingUserInteractions.contains(interaction),
              interaction.threadID == nil || interaction.threadID == selectedThreadID,
              let runtime,
              !respondingInteractionIDs.contains(interaction.id) else { return }
        respondingInteractionIDs.insert(interaction.id)
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.respond(to: interaction.id, with: response)
                guard accountEpoch == epoch else { return }
                pendingUserInteractions.removeAll { $0.id == interaction.id }
                removeInteractionDraft(for: interaction.id)
                reconcileThreadStatusAfterInteraction(for: interaction.threadID)
            } catch {
                guard accountEpoch == epoch else { return }
                notice = ("Response failed", error.localizedDescription)
            }
            respondingInteractionIDs.remove(interaction.id)
        }
    }

    func respondToApproval(_ decision: ApprovalDecision, for interaction: RuntimeUserInteraction) {
        respond(to: interaction, with: .approval(decision))
    }

    func openInteractionLink(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            let destination = url.host(percentEncoded: false) ?? "the provider sign-in page"
            notice = (
                "Could not open the link",
                "Your browser could not open \(destination). Close this message and try Open again."
            )
        }
    }

    func interruptInteraction(_ interaction: RuntimeUserInteraction) {
        guard let threadID = interaction.threadID,
              interaction.threadID == selectedThreadID,
              let runtime else { return }
        let epoch = accountEpoch
        Task { [weak self] in
            do {
                try await runtime.interrupt(threadID: threadID)
            } catch {
                guard let self, accountEpoch == epoch else { return }
                notice = ("Could not stop the task", error.localizedDescription)
            }
        }
    }

    func togglePin(_ id: String) {
        guard id != Self.welcomeThread.id else { return }
        pinnedThreadStore.toggle(id)
    }

    func beginRename(_ id: String, window: NSWindow?) {
        guard let thread = threads.first(where: { $0.id == id }), id != Self.welcomeThread.id else { return }
        let epoch = accountEpoch
        let alert = NSAlert()
        alert.messageText = "Rename task"
        alert.informativeText = "Choose a short name that will be easy to find later."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: thread.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.selectText(nil)
        alert.accessoryView = field

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, accountEpoch == epoch else { return }
                await renameThread(id, name: name)
            }
        }
    }

    func archive(_ id: String) {
        guard !isShowingArchivedThreads, id != Self.welcomeThread.id, let runtime else { return }
        if let thread = threads.first(where: { $0.id == id }), !canArchiveThread(thread) {
            notice = (
                "Task is still active",
                "Stop the task or answer its pending request before archiving it."
            )
            return
        }
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.archiveThread(id: id)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                if selectedThreadID == id {
                    saveCurrentDraftNow()
                    saveCurrentImageDraftNow()
                }
                threads.removeAll { $0.id == id }
                pinnedThreadStore.remove(id)
                if selectedThreadID == id {
                    if let next = threads.first {
                        selectedThreadID = nil
                        selectThread(next.id)
                    } else {
                        newTask()
                    }
                }
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                notice = ("Could not archive task", error.localizedDescription)
            }
        }
    }

    func restore(_ id: String) {
        guard isShowingArchivedThreads, let runtime else { return }
        threadListTask?.cancel()
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.unarchiveThread(id: id)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                threadListScope = .active
                threads = [Self.welcomeThread]
                selectedThreadID = nil
                replaceTimeline([])
                isTurnRunning = false
                isLoadingThread = false
                isLoadingThreadList = true

                let liveThreads = try await fetchThreads(in: .active)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                applyThreadList(liveThreads, scope: .active, preferredSelection: id)
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                isLoadingThreadList = false
                notice = ("Could not restore task", error.localizedDescription)
            }
        }
    }

    func fork(_ id: String) {
        guard !isShowingArchivedThreads, supports(.threadForking), let runtime,
              let source = threads.first(where: { $0.id == id }) else { return }
        guard canForkThread(source) else {
            notice = ("Task is still running", "Stop or finish the current turn before creating a fork.")
            return
        }

        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                let forked = try await runtime.forkThread(id: id)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                threadListScope = .active
                updateThread(forked)
                selectedThreadID = nil
                selectThread(forked.id)
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                notice = ("Could not fork task", error.localizedDescription)
            }
        }
    }

    func compact(_ id: String) {
        guard !isShowingArchivedThreads, supports(.threadCompaction), let runtime,
              let thread = threads.first(where: { $0.id == id }) else { return }
        guard canCompactThread(thread) else {
            notice = ("Task is still running", "Stop or finish the current turn before compacting its context.")
            return
        }

        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.compactThread(id: id)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                if selectedThreadID == id { isTurnRunning = true }
                if let index = threads.firstIndex(where: { $0.id == id }) {
                    threads[index].status = .running
                }
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                notice = ("Could not compact task", error.localizedDescription)
            }
        }
    }

    func beginDelete(_ id: String, window: NSWindow?) {
        guard supports(.threadDeletion), id != Self.welcomeThread.id,
              threads.contains(where: { $0.id == id }) else { return }
        guard !isReviewActive(for: id) else {
            notice = (
                "Task is still active",
                "Finish or stop the code review before deleting this task."
            )
            return
        }
        let epoch = accountEpoch
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this task permanently?"
        alert.informativeText = "This removes the task history and any descendant tasks from Codex. It cannot be undone. Project files are not deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                guard let self, accountEpoch == epoch else { return }
                await deleteThread(id)
            }
        }
    }

    func dismissNotice() {
        notice = nil
    }

    private func handle(_ event: AgentRuntimeEvent) {
        switch event {
        case let .connectionChanged(state):
            connectionState = state
            if case .failed = state {
                pendingUserInteractions.removeAll()
                respondingInteractionIDs.removeAll()
                removeAllInteractionDrafts()
                reviewingThreadID = nil
                startingReviewThreadID = nil
                isTurnRunning = false
                activeTurnIDsByThreadID.removeAll()
                downgradeLiveCollaborationAgents()
            } else if case .disconnected = state {
                pendingUserInteractions.removeAll()
                respondingInteractionIDs.removeAll()
                removeAllInteractionDrafts()
                reviewingThreadID = nil
                startingReviewThreadID = nil
                isTurnRunning = false
                activeTurnIDsByThreadID.removeAll()
                downgradeLiveCollaborationAgents()
            }
        case let .accountUpdated(updatedAuth):
            applyAuthProjection(updatedAuth)
            if !updatedAuth.canRun {
                closeAccountBoundary()
            }
            scheduleAccountRefresh(rejectSignedInSession: !updatedAuth.isSignedIn)
        case let .loginCompleted(completion):
            if cancelledLoginID != nil,
               (completion.loginID == nil || completion.loginID == cancelledLoginID),
               !completion.success {
                cancelledLoginID = nil
                loginAttempt = nil
                isAuthenticating = false
                return
            }
            let matchesCurrentAttempt = completion.loginID == nil
                || loginAttempt?.loginID == completion.loginID
            if completion.success {
                // Every window shares the provider account, even though only
                // Settings owns the visible login ceremony. Refresh all window
                // projections after a successful completion notification.
                if matchesCurrentAttempt {
                    isAuthenticating = false
                    loginAttempt = nil
                }
                scheduleAccountRefresh()
            } else {
                guard matchesCurrentAttempt else { return }
                isAuthenticating = false
                loginAttempt = nil
                notice = (
                    "Sign in was not completed",
                    completion.error ?? "The ChatGPT sign-in flow ended before it completed."
                )
            }
        case let .threadUpdated(thread):
            guard authState.canRun, !isSigningOut else { return }
            if threadListScope == .active {
                updateThread(thread)
            }
        case let .threadNameChanged(threadID, name):
            guard authState.canRun, !isSigningOut else { return }
            if let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index].title = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? threads[index].preview.firstNonemptyLine
                    ?? "Untitled task"
            }
        case let .threadStatusChanged(threadID, status):
            guard authState.canRun, !isSigningOut else { return }
            if let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index].status = status
                threads[index].updatedAt = .now
                sortThreadsByRecency()
            }
            if selectedThreadID == threadID {
                isTurnRunning = status.isBusy || isReviewActive(for: threadID)
            }
        case let .threadArchived(threadID):
            guard authState.canRun, !isSigningOut else { return }
            clearReviewState(for: threadID)
            activeTurnIDsByThreadID.removeValue(forKey: threadID)
            removeUserInteractions(for: threadID)
            if threadListScope == .active {
                removeThreadFromCurrentList(threadID)
            } else {
                loadThreadIntoCurrentList(threadID, expectedScope: .archived)
            }
        case let .threadUnarchived(threadID):
            guard authState.canRun, !isSigningOut else { return }
            if threadListScope == .archived {
                removeThreadFromCurrentList(threadID)
            } else {
                loadThreadIntoCurrentList(threadID, expectedScope: .active)
            }
        case let .threadDeleted(threadID):
            guard authState.canRun, !isSigningOut else { return }
            clearReviewState(for: threadID)
            activeTurnIDsByThreadID.removeValue(forKey: threadID)
            removeUserInteractions(for: threadID)
            removeThreadFromCurrentList(threadID)
            pinnedThreadStore.remove(threadID)
            plansByThreadID.removeValue(forKey: threadID)
            composerDrafts.removeValue(forKey: threadID)
            composerImageDrafts.removeValue(forKey: threadID)
            preferences.set(composerDrafts, forKey: preferenceKey(PreferenceKey.composerDrafts))
        case let .threadRefreshRequested(threadID):
            guard authState.canRun, !isSigningOut else { return }
            refreshThreadIfSelected(threadID)
        case let .itemStarted(threadID, item):
            guard authState.canRun, !isSigningOut, selectedThreadID == threadID else { return }
            recordLiveItem(item.id, for: threadID)
            if item.kind == .userMessage,
               let optimisticIndex = timeline.lastIndex(where: { $0.id.hasPrefix("optimistic:") && $0.body == item.body }) {
                timeline[optimisticIndex] = item
            } else if !timeline.contains(where: { $0.id == item.id }) {
                timeline.append(item)
            }
            mergeCollaborationActivity(from: item)
        case let .itemDelta(threadID, itemID, delta):
            guard authState.canRun, !isSigningOut, selectedThreadID == threadID else { return }
            recordLiveItem(itemID, for: threadID)
            pendingDeltas[DeltaKey(threadID: threadID, itemID: itemID), default: ""] += delta
            scheduleDeltaFlush()
        case let .itemCompleted(threadID, item):
            guard authState.canRun, !isSigningOut, selectedThreadID == threadID else { return }
            recordLiveItem(item.id, for: threadID)
            flushDeltas()
            if let index = timeline.firstIndex(where: { $0.id == item.id }) {
                timeline[index] = item
            } else {
                timeline.append(item)
            }
            mergeCollaborationActivity(from: item)
        case let .turnStarted(threadID, turnID):
            guard authState.canRun, !isSigningOut else { return }
            let revision = advanceLiveTimelineRevision(for: threadID)
            livePlanRevisionByThreadID[threadID] = revision
            if activeTurnIDsByThreadID[threadID] != turnID {
                plansByThreadID.removeValue(forKey: threadID)
            }
            activeTurnIDsByThreadID[threadID] = turnID
        case let .planUpdated(threadID, plan):
            guard authState.canRun,
                  !isSigningOut,
                  activeTurnIDsByThreadID[threadID] == plan.turnID else { return }
            let revision = advanceLiveTimelineRevision(for: threadID)
            livePlanRevisionByThreadID[threadID] = revision
            plansByThreadID[threadID] = plan
            guard selectedThreadID == threadID else { return }
            let item = TimelineItem.planUpdate(plan)
            liveItemRevisionByThreadID[threadID, default: [:]][item.id] = revision
            if let index = timeline.firstIndex(where: { $0.id == item.id }) {
                timeline[index] = item
            } else {
                timeline.append(item)
            }
        case let .turnCompleted(threadID, status):
            guard authState.canRun, !isSigningOut else { return }
            if let index = threads.firstIndex(where: { $0.id == threadID }) {
                threads[index].status = status
                threads[index].updatedAt = .now
                sortThreadsByRecency()
            }
            activeTurnIDsByThreadID.removeValue(forKey: threadID)
            if selectedThreadID == threadID {
                flushDeltas()
                isTurnRunning = status == .running
            }
            if reviewingThreadID == threadID {
                reviewingThreadID = nil
            }
            if startingReviewThreadID == threadID {
                startingReviewThreadID = nil
            }
        case let .userInteractionRequested(interaction):
            guard authState.canRun, !isSigningOut else { return }
            if interaction.isBlocking,
               let threadID = interaction.threadID,
               let index = threads.firstIndex(where: { $0.id == threadID }) {
                if case .approval = interaction.kind {
                    threads[index].status = .waitingForApproval
                } else {
                    threads[index].status = .waitingForInput
                }
            }
            if let index = pendingUserInteractions.firstIndex(where: { $0.id == interaction.id }) {
                if pendingUserInteractions[index] != interaction {
                    removeInteractionDraft(for: interaction.id)
                }
                pendingUserInteractions[index] = interaction
            } else {
                pendingUserInteractions.append(interaction)
            }
            if interaction.isBlocking,
               interaction.threadID == nil || interaction.threadID == selectedThreadID {
                isTurnRunning = true
            }
        case let .userInteractionResolved(requestID):
            guard authState.canRun, !isSigningOut else { return }
            let threadID = pendingUserInteractions.first(where: { $0.id == requestID })?.threadID
            pendingUserInteractions.removeAll { $0.id == requestID }
            respondingInteractionIDs.remove(requestID)
            removeInteractionDraft(for: requestID)
            reconcileThreadStatusAfterInteraction(for: threadID)
        case let .runtimeNotice(title, detail):
            notice = (title, detail)
        }
    }

    private func updateThread(_ thread: RuntimeThread) {
        var thread = thread
        thread.isPinned = pinnedThreadIDs.contains(thread.id)
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.insert(thread, at: 0)
        }
        threads.sort { $0.updatedAt > $1.updatedAt }
        if selectedThreadID == thread.id {
            isTurnRunning = thread.status.isBusy || isReviewActive(for: thread.id)
        }
    }

    private func replaceTimeline(_ items: [TimelineItem], authoritativeFor threadID: String? = nil) {
        timeline = items
        if let threadID {
            plansByThreadID.removeValue(forKey: threadID)
        }
        collaborationAgentsByID.removeAll(keepingCapacity: true)
        for item in items {
            mergeCollaborationActivity(from: item, publish: false)
        }
        publishCollaborationAgents()
    }

    /// Applies a provider history snapshot without allowing it to erase item,
    /// collaboration, or plan notifications that arrived while the read was
    /// in flight. When there was no overlap, the snapshot remains fully
    /// authoritative and retains the existing refresh semantics.
    private func applyConversationSnapshot(
        _ snapshot: [TimelineItem],
        for threadID: String,
        preservingLiveUpdatesAfter readStartRevision: UInt64
    ) {
        // Deltas are coalesced for a short window so a fast stream does not
        // trigger a SwiftUI publication for every token. A history read can
        // finish during that window, though, so the visible timeline may not
        // contain the text represented by a live revision yet. Consume only
        // this thread's buffered deltas here and fold them into the snapshot;
        // the delayed flush must not apply them a second time.
        let bufferedDeltas = takePendingDeltas(for: threadID)
        let visibleLiveItems = Dictionary(
            timeline.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let snapshotWithBufferedDeltas = applyingBufferedDeltas(
            bufferedDeltas,
            to: snapshot,
            visibleItems: visibleLiveItems
        )
        let bufferedDeltaByItemID = Dictionary(
            bufferedDeltas.compactMap { key, delta in
                delta.isEmpty ? nil : (key.itemID, delta)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let currentRevision = liveTimelineRevision(for: threadID)
        guard currentRevision != readStartRevision else {
            var authoritative = snapshotWithBufferedDeltas
            appendMissingBufferedDeltas(
                bufferedDeltas,
                to: &authoritative,
                includedIDs: Set(authoritative.map(\.id))
            )
            replaceTimeline(authoritative, authoritativeFor: threadID)
            pruneLiveTimelineTracking(for: threadID, through: readStartRevision)
            return
        }

        let liveItemRevisions = liveItemRevisionByThreadID[threadID] ?? [:]
        var merged: [TimelineItem] = []
        var includedIDs: Set<String> = []

        for snapshotItem in snapshotWithBufferedDeltas {
            // A buffered delta is the one live update that is not reflected in
            // `timeline` yet. Prefer the snapshot base for that item, after the
            // delta has been folded into it, instead of selecting the older
            // visible body solely because its revision is newer.
            let item = if bufferedDeltaByItemID[snapshotItem.id] == nil,
                          (liveItemRevisions[snapshotItem.id] ?? 0) > readStartRevision,
                          let liveItem = visibleLiveItems[snapshotItem.id] {
                liveItem
            } else {
                snapshotItem
            }
            merged.append(item)
            includedIDs.insert(item.id)
        }

        for liveItem in timeline where !includedIDs.contains(liveItem.id) {
            guard (liveItemRevisions[liveItem.id] ?? 0) > readStartRevision else { continue }
            var liveItem = liveItem
            if let delta = bufferedDeltaByItemID[liveItem.id] {
                appendBufferedDelta(delta, to: &liveItem)
            }
            merged.append(liveItem)
            includedIDs.insert(liveItem.id)
        }

        // A delta can arrive for an item that was not present in either the
        // visible timeline or the snapshot (for example, immediately after an
        // item-start event). Keep it once in that case.
        appendMissingBufferedDeltas(
            bufferedDeltas,
            to: &merged,
            includedIDs: includedIDs
        )

        timeline = merged
        if (livePlanRevisionByThreadID[threadID] ?? 0) <= readStartRevision {
            plansByThreadID.removeValue(forKey: threadID)
        }
        collaborationAgentsByID.removeAll(keepingCapacity: true)
        for item in merged {
            mergeCollaborationActivity(from: item, publish: false)
        }
        publishCollaborationAgents()
        pruneLiveTimelineTracking(for: threadID, through: readStartRevision)
    }

    /// Removes buffered deltas belonging to one conversation while retaining
    /// deltas for other conversations. The latter can still be flushed after a
    /// selection change, where `flushDeltas()` intentionally ignores them.
    private func takePendingDeltas(for threadID: String) -> [DeltaKey: String] {
        let keys = pendingDeltas.keys.filter { $0.threadID == threadID }
        var result: [DeltaKey: String] = [:]
        for key in keys {
            if let delta = pendingDeltas.removeValue(forKey: key) {
                result[key] = delta
            }
        }
        if pendingDeltas.isEmpty {
            deltaFlushTask?.cancel()
            deltaFlushTask = nil
        }
        return result
    }

    private func applyingBufferedDeltas(
        _ deltas: [DeltaKey: String],
        to items: [TimelineItem],
        visibleItems: [String: TimelineItem]
    ) -> [TimelineItem] {
        var merged = items
        for (key, delta) in deltas.sorted(by: { lhs, rhs in
            if lhs.key.itemID != rhs.key.itemID { return lhs.key.itemID < rhs.key.itemID }
            return lhs.key.threadID < rhs.key.threadID
        }) where !delta.isEmpty {
            if let index = merged.firstIndex(where: { $0.id == key.itemID }) {
                appendBufferedDelta(
                    delta,
                    to: &merged[index],
                    relativeTo: visibleItems[key.itemID]?.body
                )
            }
        }
        return merged
    }

    private func appendMissingBufferedDeltas(
        _ deltas: [DeltaKey: String],
        to items: inout [TimelineItem],
        includedIDs: Set<String>
    ) {
        var includedIDs = includedIDs
        for (key, delta) in deltas.sorted(by: { lhs, rhs in
            if lhs.key.itemID != rhs.key.itemID { return lhs.key.itemID < rhs.key.itemID }
            return lhs.key.threadID < rhs.key.threadID
        }) where !includedIDs.contains(key.itemID) && !delta.isEmpty {
            items.append(
                TimelineItem(
                    id: key.itemID,
                    kind: .assistantMessage,
                    title: nil,
                    body: delta,
                    status: .running,
                    timestamp: .now,
                    detail: nil
                )
            )
            includedIDs.insert(key.itemID)
        }
    }

    private func appendBufferedDelta(
        _ delta: String,
        to item: inout TimelineItem,
        relativeTo visibleBody: String? = nil
    ) {
        guard !delta.isEmpty else { return }
        if let visibleBody,
           item.body.hasPrefix(visibleBody),
           item.body.dropFirst(visibleBody.count).hasPrefix(delta) {
            return
        }
        item.body += delta
    }

    private func liveTimelineRevision(for threadID: String) -> UInt64 {
        liveTimelineRevisionByThreadID[threadID] ?? 0
    }

    @discardableResult
    private func advanceLiveTimelineRevision(for threadID: String) -> UInt64 {
        let revision = liveTimelineRevision(for: threadID) &+ 1
        liveTimelineRevisionByThreadID[threadID] = revision
        return revision
    }

    private func recordLiveItem(_ itemID: String, for threadID: String) {
        let revision = advanceLiveTimelineRevision(for: threadID)
        liveItemRevisionByThreadID[threadID, default: [:]][itemID] = revision
    }

    private func pruneLiveTimelineTracking(for threadID: String, through revision: UInt64) {
        if var itemRevisions = liveItemRevisionByThreadID[threadID] {
            itemRevisions = itemRevisions.filter { $0.value > revision }
            if itemRevisions.isEmpty {
                liveItemRevisionByThreadID.removeValue(forKey: threadID)
            } else {
                liveItemRevisionByThreadID[threadID] = itemRevisions
            }
        }
        if (livePlanRevisionByThreadID[threadID] ?? 0) <= revision {
            livePlanRevisionByThreadID.removeValue(forKey: threadID)
        }
    }

    private func mergeCollaborationActivity(from item: TimelineItem, publish: Bool = true) {
        guard let activity = item.collaboration else { return }
        for incoming in activity.agents where !incoming.id.isEmpty {
            if var existing = collaborationAgentsByID[incoming.id] {
                guard incoming.updatedAt >= existing.updatedAt else { continue }
                if let path = incoming.path, !path.isEmpty { existing.path = path }
                if incoming.status != .unknown { existing.status = incoming.status }
                if let message = incoming.message, !message.isEmpty { existing.message = message }
                existing.updatedAt = incoming.updatedAt
                collaborationAgentsByID[incoming.id] = existing
            } else {
                collaborationAgentsByID[incoming.id] = incoming
            }
        }
        if publish { publishCollaborationAgents() }
    }

    private func downgradeLiveCollaborationAgents() {
        var changed = false
        for id in Array(collaborationAgentsByID.keys) {
            guard collaborationAgentsByID[id]?.status.isLive == true else { continue }
            collaborationAgentsByID[id]?.status = .unavailable
            collaborationAgentsByID[id]?.updatedAt = .now
            changed = true
        }
        if changed { publishCollaborationAgents() }
    }

    private func sortThreadsByRecency() {
        threads.sort { $0.updatedAt > $1.updatedAt }
    }

    private func applyPinnedThreadIDs(_ ids: Set<String>) {
        for index in threads.indices where threads[index].id != Self.welcomeThread.id {
            threads[index].isPinned = ids.contains(threads[index].id)
        }
    }

    private func hasPendingInteraction(for threadID: String, blockingOnly: Bool) -> Bool {
        pendingUserInteractions.contains { interaction in
            let belongsToThread = interaction.threadID == threadID
                || (interaction.threadID == nil && selectedThreadID == threadID && !isShowingArchivedThreads)
            return belongsToThread && (!blockingOnly || interaction.isBlocking)
        }
    }

    private func publishCollaborationAgents() {
        collaborationAgents = collaborationAgentsByID.values.sorted { lhs, rhs in
            if lhs.status.isLive != rhs.status.isLive { return lhs.status.isLive }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func reconcileThreadStatusAfterInteraction(for threadID: String?) {
        guard let threadID,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let remaining = pendingUserInteractions.filter { $0.threadID == threadID }
        if remaining.contains(where: { interaction in
            if case .approval = interaction.kind { return true }
            return false
        }) {
            threads[index].status = .waitingForApproval
        } else if !remaining.isEmpty {
            threads[index].status = .waitingForInput
        } else if threads[index].status == .waitingForApproval
                    || threads[index].status == .waitingForInput {
            threads[index].status = .running
        }
        if selectedThreadID == threadID {
            isTurnRunning = threads[index].status.isBusy || isReviewActive(for: threadID)
        }
    }

    private func clearReviewState(for threadID: String) {
        if reviewingThreadID == threadID { reviewingThreadID = nil }
        if startingReviewThreadID == threadID { startingReviewThreadID = nil }
    }

    private func removeThreadFromCurrentList(_ threadID: String) {
        let wasSelected = selectedThreadID == threadID
        if wasSelected {
            saveCurrentDraftNow()
            saveCurrentImageDraftNow()
        }
        threads.removeAll { $0.id == threadID }
        guard wasSelected else { return }

        selectedThreadID = nil
        isTurnRunning = false
        if let next = threads.first {
            selectThread(next.id)
        } else if threadListScope == .active {
            newTask()
        } else {
            preferences.removeObject(forKey: preferenceKey(PreferenceKey.selectedThread))
            composerDraftKey = Self.welcomeThread.id
            composerText = composerDrafts[composerDraftKey] ?? ""
            composerImages = composerImageDrafts[composerDraftKey] ?? []
            replaceTimeline([])
            isLoadingThread = false
        }
    }

    private func loadThreadIntoCurrentList(_ threadID: String, expectedScope: ThreadListScope) {
        guard let runtime else { return }
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                let conversation = try await runtime.readThread(id: threadID)
                guard accountEpoch == epoch, threadListScope == expectedScope else { return }
                updateThread(conversation.thread)
            } catch {
                // A lifecycle notification can race a descendant move; the next list refresh is authoritative.
            }
        }
    }

    private func refreshThreadIfSelected(_ threadID: String) {
        guard selectedThreadID == threadID, let runtime else { return }
        loadTask?.cancel()
        isLoadingThread = true
        let epoch = accountEpoch
        let liveRevisionAtReadStart = liveTimelineRevision(for: threadID)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conversation = try await runtime.readThread(id: threadID)
                guard accountEpoch == epoch, !Task.isCancelled, selectedThreadID == threadID else { return }
                applyConversationSnapshot(
                    conversation.items,
                    for: conversation.thread.id,
                    preservingLiveUpdatesAfter: liveRevisionAtReadStart
                )
                updateThread(conversation.thread)
                isLoadingThread = false
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled, selectedThreadID == threadID else { return }
                isLoadingThread = false
                notice = ("Could not refresh task", error.localizedDescription)
            }
        }
    }

    /// Re-establishes app-server ownership and notification delivery for the
    /// visible task after a new transport connection. Ordinary navigation uses
    /// `readThread` so browsing history remains read-only; reconnect must use
    /// `resumeThread` or live items and approvals can stay attached to the old
    /// app-server process.
    private func resumeThreadAfterReconnect(_ threadID: String) {
        guard selectedThreadID == threadID, let runtime else { return }
        loadTask?.cancel()
        isLoadingThread = true
        let epoch = accountEpoch
        let revision = connectionRevision
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conversation = try await runtime.resumeThread(id: threadID)
                guard accountEpoch == epoch,
                      connectionRevision == revision,
                      !Task.isCancelled,
                      selectedThreadID == threadID,
                      case .connected = connectionState else { return }
                replaceTimeline(conversation.items, authoritativeFor: conversation.thread.id)
                updateThread(conversation.thread)
                isTurnRunning = conversation.thread.status.isBusy
                    || isReviewActive(for: conversation.thread.id)
                isLoadingThread = false
            } catch {
                guard accountEpoch == epoch,
                      connectionRevision == revision,
                      !Task.isCancelled,
                      selectedThreadID == threadID else { return }
                isLoadingThread = false
                notice = (
                    "Connected, but this task did not resume",
                    "Its cached history is still available. \(error.localizedDescription)"
                )
            }
        }
    }

    private func renameThread(_ id: String, name: String) async {
        guard let runtime else { return }
        let epoch = accountEpoch
        do {
            try await runtime.renameThread(id: id, name: name)
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            if let index = threads.firstIndex(where: { $0.id == id }) {
                threads[index].title = name
            }
        } catch {
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            notice = ("Could not rename task", error.localizedDescription)
        }
    }

    private static func defaultFormDraft(for interaction: RuntimeUserInteraction) -> RuntimeFormDraft {
        guard case let .form(prompt) = interaction.kind else { return RuntimeFormDraft() }

        var draft = RuntimeFormDraft()
        for field in prompt.fields {
            switch field.initialValue {
            case let .string(value):
                draft.textValues[field.id] = value
                draft.choiceValues[field.id] = value
            case let .number(value):
                draft.textValues[field.id] = String(value)
            case let .integer(value):
                draft.textValues[field.id] = String(value)
            case let .boolean(value):
                draft.boolValues[field.id] = value
                draft.touchedBoolFields.insert(field.id)
            case let .strings(values):
                draft.multiValues[field.id] = Set(values)
            case nil:
                break
            }
        }
        return draft
    }

    private func removeInteractionDraft(for requestID: RuntimeRequestID) {
        questionDrafts.removeValue(forKey: requestID)
        formDrafts.removeValue(forKey: requestID)
    }

    private func removeAllInteractionDrafts() {
        questionDrafts.removeAll()
        formDrafts.removeAll()
    }

    private func removeUserInteractions(for threadID: String) {
        let requestIDs = pendingUserInteractions.compactMap { interaction in
            interaction.threadID == threadID ? interaction.id : nil
        }
        pendingUserInteractions.removeAll { $0.threadID == threadID }
        for requestID in requestIDs {
            respondingInteractionIDs.remove(requestID)
            removeInteractionDraft(for: requestID)
        }
    }

    private func deleteThread(_ id: String) async {
        guard let runtime else { return }
        let epoch = accountEpoch
        do {
            try await runtime.deleteThread(id: id)
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            removeThreadFromCurrentList(id)
            pinnedThreadStore.remove(id)
            composerDrafts.removeValue(forKey: id)
            composerImageDrafts.removeValue(forKey: id)
            preferences.set(composerDrafts, forKey: preferenceKey(PreferenceKey.composerDrafts))
        } catch {
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            notice = ("Could not delete task", error.localizedDescription)
        }
    }

    private func fetchThreads(in scope: ThreadListScope) async throws -> [RuntimeThread] {
        guard let runtime else { return [] }
        return try await runtime.listThreads(limit: 100, archived: scope == .archived).map { thread in
            var projected = thread
            projected.isPinned = pinnedThreadIDs.contains(thread.id)
            return projected
        }
    }

    private func applyThreadList(
        _ liveThreads: [RuntimeThread],
        scope: ThreadListScope,
        preferredSelection: String? = nil
    ) {
        guard threadListScope == scope else { return }
        isLoadingThreadList = false
        threads = liveThreads.isEmpty && scope == .active ? [Self.welcomeThread] : liveThreads

        let targetID = preferredSelection.flatMap { preferredID in
            threads.contains(where: { $0.id == preferredID }) ? preferredID : nil
        } ?? selectedThreadID.flatMap { currentID in
            threads.contains(where: { $0.id == currentID }) ? currentID : nil
        } ?? threads.first?.id

        guard let targetID else {
            selectedThreadID = nil
            replaceTimeline([])
            isLoadingThread = false
            return
        }

        if selectedThreadID != targetID {
            selectedThreadID = nil
            selectThread(targetID)
        }
    }

    private func rememberWorkspace(_ path: String?) {
        guard let path, path != "/", !path.isEmpty else { return }
        draftWorkspacePath = path
        preferences.set(path, forKey: preferenceKey("Onyx.lastWorkspacePath"))
    }

    private var selectedSandboxMode: RuntimeSandboxMode {
        switch permissionLabel {
        case "Read only": .readOnly
        case "Full access": .fullAccess
        default: .workspaceWrite
        }
    }

    private var selectedApprovalPolicy: RuntimeApprovalPolicy {
        permissionLabel == "Full access" ? .never : .onRequest
    }

    /// Closes the local account boundary after the provider has confirmed
    /// logout. No task, transcript, draft, workspace, or async completion from
    /// the previous account may remain visible in the signed-out window.
    private func closeAccountBoundary() {
        workspacePersistenceStore?.clearAccountOwnedState()
        accountEpoch &+= 1
        connectionRevision &+= 1
        navigationRevision += 1

        connectionTask?.cancel()
        connectionTask = nil
        loadTask?.cancel()
        loadTask = nil
        threadListTask?.cancel()
        threadListTask = nil
        accountRefreshTask?.cancel()
        accountRefreshTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        draftSaveTask?.cancel()
        draftSaveTask = nil

        pendingDeltas.removeAll()
        activeTurnIDsByThreadID.removeAll()
        liveTimelineRevisionByThreadID.removeAll()
        liveItemRevisionByThreadID.removeAll()
        livePlanRevisionByThreadID.removeAll()
        reviewingThreadID = nil
        startingReviewThreadID = nil
        pendingUserInteractions.removeAll()
        respondingInteractionIDs.removeAll()
        removeAllInteractionDrafts()
        pendingRestoredSelectionID = nil
        cancelledLoginID = nil
        loginAttempt = nil
        isAuthenticating = false

        composerDrafts.removeAll()
        composerImageDrafts.removeAll()
        pinnedThreadStore.removeAll()
        plansByThreadID.removeAll()
        draftWorkspacePath = nil
        searchText = ""
        threadListScope = .active
        threads = [Self.welcomeThread]
        selectedThreadID = Self.welcomeThread.id
        replaceTimeline([.welcome()])
        composerDraftKey = Self.welcomeThread.id
        composerText = ""
        composerImages = []
        // The composer assignment schedules a save; there is intentionally no
        // signed-out draft to persist.
        draftSaveTask?.cancel()
        draftSaveTask = nil

        isLoadingThread = false
        isLoadingThreadList = false
        isTurnRunning = false
        notice = nil

        preferences.removeObject(forKey: preferenceKey(PreferenceKey.selectedThread))
        preferences.removeObject(forKey: preferenceKey(PreferenceKey.composerDrafts))
        preferences.removeObject(forKey: preferenceKey("Onyx.lastWorkspacePath"))
    }

    private func applyRuntimeSession(_ updatedSession: RuntimeSession) {
        session = updatedSession
        authState = updatedSession.auth
        if updatedSession.auth.isSignedIn { loginAttempt = nil }

        if selectedModelID == nil
            || !updatedSession.availableModels.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = updatedSession.availableModels.first(where: \.isDefault)?.id
                ?? updatedSession.availableModels.first?.id
        }
        validateSelectedReasoningEffort()

        if case .connected = connectionState {
            connectionState = .connected(updatedSession.accountLabel ?? updatedSession.displayName)
        }
    }

    private func applyAuthProjection(_ projection: RuntimeAuthState) {
        let merged = RuntimeAuthState(
            mode: projection.mode,
            email: nil,
            planLabel: projection.planLabel,
            requiresAuthentication: projection.requiresAuthentication
        )
        authState = merged
        if merged.isSignedIn { loginAttempt = nil }

        guard let session else { return }
        self.session = RuntimeSession(
            runtime: session.runtime,
            displayName: session.displayName,
            accountLabel: merged.email ?? merged.mode?.displayName,
            planLabel: merged.planLabel,
            auth: merged,
            availableLoginMethods: session.availableLoginMethods,
            availableModels: session.availableModels,
            capabilities: session.capabilities
        )
        if case .connected = connectionState {
            connectionState = .connected(self.session?.accountLabel ?? session.displayName)
        }
    }

    private func scheduleAccountRefresh(rejectSignedInSession: Bool = false) {
        guard let runtime else { return }
        accountRefreshTask?.cancel()
        let epoch = accountEpoch
        accountRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            do {
                let refreshedSession = try await runtime.refreshAccount()
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                guard !rejectSignedInSession || !refreshedSession.auth.isSignedIn else { return }
                applyRuntimeSession(refreshedSession)
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                // The notification projection is still useful. A later account event or reconnect retries.
            }
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            accountRefreshTask = nil
        }
    }

    private func authenticationFailure(for error: any Error) -> (title: String, detail: String) {
        let detail = error.localizedDescription
        if detail.localizedCaseInsensitiveContains("failed to start login server")
            || detail.localizedCaseInsensitiveContains("address already in use") {
            return (
                "Browser sign in could not start",
                "The secure local callback could not be opened. Try the device-code option instead."
            )
        }
        return ("Could not start sign in", detail)
    }

    private func validateSelectedReasoningEffort() {
        guard let model = session?.availableModels.first(where: { $0.id == selectedModelID }) else { return }
        if let selectedReasoningEffort, model.reasoningEfforts.contains(selectedReasoningEffort) {
            return
        }
        self.selectedReasoningEffort = model.defaultReasoningEffort ?? model.reasoningEfforts.first
    }

    private func loadComposerDraft(for threadID: String) {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        composerDraftKey = threadID
        composerText = composerDrafts[threadID] ?? ""
        composerImages = composerImageDrafts[threadID] ?? []
    }

    private func movePendingDraft(
        from sourceKey: String?,
        to targetKey: String,
        selecting thread: RuntimeThread,
        ifNavigationRevisionIs expectedRevision: Int
    ) {
        guard let sourceKey else { return }
        let isVisibleSource = composerDraftKey == sourceKey
        if isVisibleSource {
            saveCurrentDraftNow()
            saveCurrentImageDraftNow()
        }

        let followUp = composerDrafts[sourceKey] ?? ""
        let followUpImages = composerImageDrafts[sourceKey] ?? []
        composerDrafts.removeValue(forKey: sourceKey)
        composerImageDrafts.removeValue(forKey: sourceKey)
        persistDraft(followUp, for: targetKey)
        persistImageDraft(followUpImages, for: targetKey)

        guard isVisibleSource,
              navigationRevision == expectedRevision,
              threadListScope == .active,
              selectedThreadID == nil || selectedThreadID == Self.welcomeThread.id else { return }

        navigationRevision += 1
        selectedThreadID = thread.id
        preferences.set(thread.id, forKey: preferenceKey(PreferenceKey.selectedThread))
        composerDraftKey = targetKey
        composerText = followUp
        composerImages = followUpImages
        replaceTimeline([])
        isTurnRunning = false
    }

    private func restoreFailedNewTaskSend(_ context: SendContext) {
        guard let provisionalKey = context.provisionalDraftKey else {
            restoreFailedSend(context.draftText, for: context.sourceDraftKey)
            return
        }

        let isVisibleSource = composerDraftKey == provisionalKey
        if isVisibleSource {
            saveCurrentDraftNow()
            saveCurrentImageDraftNow()
        }
        let followUp = composerDrafts[provisionalKey] ?? ""
        let followUpImages = composerImageDrafts[provisionalKey] ?? []
        composerDrafts.removeValue(forKey: provisionalKey)
        composerImageDrafts.removeValue(forKey: provisionalKey)

        let restored: String
        if followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restored = context.draftText
        } else if followUp == context.draftText {
            restored = followUp
        } else {
            restored = context.draftText + "\n\n" + followUp
        }
        persistDraft(restored, for: context.sourceDraftKey)
        persistImageDraft(mergedFailedImages(context.images, with: followUpImages), for: context.sourceDraftKey)

        if isVisibleSource,
           navigationRevision == context.navigationRevision,
           selectedThreadID == context.originThreadID {
            composerDraftKey = context.sourceDraftKey
            composerText = restored
            composerImages = composerImageDrafts[context.sourceDraftKey] ?? []
        }
    }

    private func restoreFailedImages(_ failedImages: [ComposerImageDraft], for key: String) {
        let existing = key == composerDraftKey ? composerImages : (composerImageDrafts[key] ?? [])
        let restored = mergedFailedImages(failedImages, with: existing)
        if key == composerDraftKey {
            composerImages = restored
        }
        persistImageDraft(restored, for: key)
    }

    private func mergedFailedImages(
        _ failedImages: [ComposerImageDraft],
        with laterImages: [ComposerImageDraft]
    ) -> [ComposerImageDraft] {
        // A later re-attachment of the same source owns its current identity
        // and position. Restore only failed inputs the user has not re-added.
        let laterInputs = Set(laterImages.map(\.input))
        return failedImages.filter { !laterInputs.contains($0.input) } + laterImages
    }

    private func restoreFailedSend(_ failedText: String, for key: String) {
        let existing = key == composerDraftKey ? composerText : (composerDrafts[key] ?? "")
        let restored: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restored = failedText
        } else if existing == failedText {
            restored = existing
        } else {
            restored = failedText + "\n\n" + existing
        }

        if key == composerDraftKey {
            composerText = restored
        }
        persistDraft(restored, for: key)
    }

    private func sendFailureMessage(for error: any Error) -> (title: String, detail: String) {
        if case let AgentRuntimeError.requestFailed(_, message) = error,
           message.localizedCaseInsensitiveContains("active writer") {
            return (
                "Task is open elsewhere",
                "Another Codex window is actively working in this task. Let that turn finish or close the other window, then try again. Your draft is still here."
            )
        }
        return ("Could not send", error.localizedDescription)
    }

    private func scheduleComposerDraftSave() {
        draftSaveTask?.cancel()
        let key = composerDraftKey
        let text = composerText
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            persistDraft(text, for: key)
            draftSaveTask = nil
        }
    }

    private func saveCurrentDraftNow() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        persistDraft(composerText, for: composerDraftKey)
    }

    private func saveCurrentImageDraftNow() {
        persistImageDraft(composerImages, for: composerDraftKey)
    }

    private func persistImageDraft(_ images: [ComposerImageDraft], for key: String) {
        if images.isEmpty {
            composerImageDrafts.removeValue(forKey: key)
        } else {
            composerImageDrafts[key] = images
        }
    }

    private func persistDraft(_ text: String, for key: String) {
        if text.isEmpty {
            composerDrafts.removeValue(forKey: key)
        } else {
            composerDrafts[key] = text
        }
        preferences.set(composerDrafts, forKey: preferenceKey(PreferenceKey.composerDrafts))
    }

    private func preferenceKey(_ legacyKey: String) -> String {
        preferenceNamespace.key(legacyKey)
    }

    private static func boolPreference(_ key: String, default fallback: Bool, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(24))
            guard let self, !Task.isCancelled else { return }
            self.flushDeltas()
        }
    }

    private func flushDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        let deltas = pendingDeltas
        pendingDeltas.removeAll(keepingCapacity: true)

        for (key, delta) in deltas where !delta.isEmpty && key.threadID == selectedThreadID {
            if let index = timeline.firstIndex(where: { $0.id == key.itemID }) {
                timeline[index].body += delta
            } else {
                timeline.append(
                    TimelineItem(
                        id: key.itemID,
                        kind: .assistantMessage,
                        title: nil,
                        body: delta,
                        status: .running,
                        timestamp: .now,
                        detail: nil
                    )
                )
            }
        }
    }
}
