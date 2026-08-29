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

/// One immutable publication consumed by the native transcript. Keeping the
/// items, revision, and hint in the same value prevents SwiftUI from observing
/// a new array with metadata from an older mutation.
struct TranscriptPresentationSnapshot: Equatable, Sendable {
    var items: [TimelineItem]
    var revision: UInt64
    var changeHint: TranscriptCollectionUpdate.Hint?

    init(
        items: [TimelineItem],
        revision: UInt64 = 0,
        changeHint: TranscriptCollectionUpdate.Hint? = nil
    ) {
        self.items = items
        self.revision = revision
        self.changeHint = changeHint
    }

    mutating func replaceAll(with newItems: [TimelineItem]) {
        revision &+= 1
        items = newItems
        changeHint = nil
    }

    mutating func append(_ item: TimelineItem) {
        let previousRevision = revision
        let previousCount = items.count
        revision &+= 1
        items.append(item)
        if case let .itemsAppended(startIndex, fromRevision, toRevision) = changeHint,
           toRevision == previousRevision,
           let appendedCount = Int(exactly: toRevision - fromRevision),
           previousCount == startIndex + appendedCount {
            // Preserve the lineage across coalesced SwiftUI publications. A
            // controller may have rendered any earlier revision in this run.
            changeHint = .itemsAppended(
                startIndex: startIndex,
                fromRevision: fromRevision,
                toRevision: revision
            )
        } else {
            changeHint = .itemsAppended(
                startIndex: previousCount,
                fromRevision: previousRevision,
                toRevision: revision
            )
        }
    }

    /// Inserts an older, bounded history page ahead of the currently visible
    /// tail. The revision-bound hint lets the native transcript preserve its
    /// mounted rows and viewport instead of treating pagination as a complete
    /// replacement of a potentially large conversation.
    mutating func prepend(contentsOf olderItems: [TimelineItem]) {
        guard !olderItems.isEmpty else { return }
        let previousRevision = revision
        revision &+= 1
        items.insert(contentsOf: olderItems, at: 0)
        changeHint = .itemsPrepended(
            count: olderItems.count,
            fromRevision: previousRevision,
            toRevision: revision
        )
    }

    nonisolated func prepending(contentsOf olderItems: [TimelineItem]) -> Self {
        var copy = self
        copy.prepend(contentsOf: olderItems)
        return copy
    }

    mutating func replaceRow(at index: Int, with item: TimelineItem) {
        guard items.indices.contains(index) else { return }
        let previousRevision = revision
        revision &+= 1
        items[index] = item
        changeHint = .rowsChanged(
            indices: IndexSet(integer: index),
            fromRevision: previousRevision,
            toRevision: revision
        )
    }

    mutating func mutateRows(
        _ indices: IndexSet,
        mutation: (inout [TimelineItem]) -> Void
    ) {
        guard !indices.isEmpty,
              indices.allSatisfy({ items.indices.contains($0) }) else {
            mutation(&items)
            revision &+= 1
            changeHint = nil
            return
        }
        let previousRevision = revision
        mutation(&items)
        revision &+= 1
        changeHint = .rowsChanged(
            indices: indices,
            fromRevision: previousRevision,
            toRevision: revision
        )
    }
}

/// One follow-up submitted into an active turn. This is deliberately
/// presentation state rather than a `TimelineItem`: the provider remains the
/// authority for durable user-message history, while Onyx owns the short gap
/// between clearing the composer and receiving that authoritative item.
struct PendingSteeringMessage: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The local request has been captured but `turn/steer` has not yet
        /// acknowledged it.
        case submitting
        /// The runtime accepted the request and it is waiting to be reflected
        /// by the live turn.
        case queued
    }

    let id: UUID
    let threadID: String
    let text: String
    let attachmentCount: Int
    var state: State
}

@MainActor
final class OnyxAppModel: ObservableObject {
    @Published var connectionState: RuntimeConnectionState = .disconnected
    @Published var session: RuntimeSession?
    /// Protocol compatibility can be disproved after an adaptive task is
    /// already visible. Keep that evidence outside the provider's immutable
    /// task/model snapshots so a later thread refresh cannot accidentally
    /// re-enable the rejected action in this window.
    private var downgradedRuntimeCapabilities: RuntimeCapabilities = []
    @Published var authState = RuntimeAuthState.signedOut
    @Published private(set) var authenticationRecovery: RuntimeAuthenticationRecovery?
    @Published var loginAttempt: RuntimeLoginStart?
    @Published var isAuthenticating = false
    @Published var isSigningOut = false
    @Published var threads: [RuntimeThread] {
        didSet {
            threadListRevision &+= 1
            selectedThreadCacheNeedsRefresh = true
            threadIndexCacheRevision = nil
        }
    }
    /// Cheap identity for views that react to task-list mutations. Comparing
    /// the full multi-thousand-task array after every unrelated model
    /// publication made streaming and navigation contend with sidebar work.
    private(set) var threadListRevision: UInt64 = 0
    @Published var selectedThreadID: String? {
        didSet { selectedThreadCacheNeedsRefresh = true }
    }
    /// The selected task is read by most workspace panes. Keep one projection
    /// per model publication instead of making every observer scan the full
    /// catalog independently (which is especially visible while a large task
    /// list is streaming status updates).
    private var selectedThreadCache: RuntimeThread?
    private var selectedThreadCacheNeedsRefresh = true
    /// Lifecycle notifications address tasks by id. A lazy index keeps routine
    /// title/status updates constant-time after a catalog publication instead
    /// of linearly searching a multi-thousand-task history for every event.
    private var threadIndexByID: [String: Int] = [:]
    private var threadIndexCacheRevision: UInt64?
    @Published private(set) var transcriptSnapshot: TranscriptPresentationSnapshot
    var timeline: [TimelineItem] { transcriptSnapshot.items }
    /// Primary composer editing state is observed by the composer subtree only.
    /// Keeping it out of this model's `objectWillChange` stream prevents a
    /// publication for every keystroke from invalidating the sidebar and
    /// transcript.
    let composerDraftModel: OnyxComposerDraftModel

    /// Compatibility accessors keep the app model's navigation/send API
    /// stable while routing reads and writes to the isolated composer child.
    var composerText: String {
        get { composerDraftModel.text }
        set { composerDraftModel.text = newValue }
    }

    private(set) var composerImages: [ComposerImageDraft] {
        get { composerDraftModel.images }
        set { composerDraftModel.images = newValue }
    }

    /// Explicit focus requests use an identity token so a newly replaced
    /// provider model cannot accidentally reuse a value already consumed by a
    /// surviving native editor coordinator.
    var composerFocusRequest: UUID? {
        composerDraftModel.focusRequest
    }

    func requestComposerFocus() {
        composerDraftModel.requestFocus()
    }
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
    /// Earlier history is deliberately independent from the initial task-load
    /// state. Once the newest page is visible, the composer and transcript are
    /// ready even while an older page is being fetched above them.
    @Published private(set) var isLoadingEarlierHistory = false
    @Published private(set) var canLoadEarlierHistory = false
    /// True only while the native provider is replacing the selected task's
    /// durable history prefix. Keeping this separate from ordinary agent work
    /// prevents a double-click from issuing the destructive operation twice.
    @Published private(set) var isPreparingLatestMessageEdit = false
    @Published private(set) var isPreparingFailedResponseRetry = false
    @Published var isTurnRunning = false
    /// Follow-ups submitted while the selected turn is already active are
    /// steering messages, not new turns. Keep a small app-owned projection of
    /// those requests until app-server publishes the matching user item (or
    /// the active turn ends) so clearing the composer never makes an accepted
    /// instruction look lost.
    @Published private(set) var pendingSteeringMessagesByThreadID: [String: [PendingSteeringMessage]] = [:]
    @Published private(set) var reviewingThreadID: String?
    @Published private(set) var startingReviewThreadID: String?
    @Published private(set) var pendingUserInteractions: [RuntimeUserInteraction] = []
    @Published private(set) var respondingInteractionIDs: Set<RuntimeRequestID> = []
    @Published private(set) var collaborationAgents: [RuntimeCollaborationAgent] = []
    @Published private(set) var plansByThreadID: [String: RuntimePlan] = [:]
    /// Ephemeral side chat state is intentionally owned by the window model,
    /// but kept completely separate from the durable task transcript/catalog.
    /// The fork's remote thread ID is only retained while this panel is open.
    @Published private(set) var isSideChatPresented = false
    @Published private(set) var isSideChatLoading = false
    @Published private(set) var sideChatParentThreadID: String?
    @Published private(set) var sideChatThreadID: String?
    @Published private(set) var sideChatTranscriptSnapshot = TranscriptPresentationSnapshot(items: [])
    var sideChatTimeline: [TimelineItem] { sideChatTranscriptSnapshot.items }
    @Published var sideChatComposerText = ""
    @Published private(set) var sideChatComposerImages: [ComposerImageDraft] = []
    @Published private(set) var isSideChatTurnRunning = false
    @Published private(set) var sideChatInteraction: RuntimeUserInteraction?
    @Published private(set) var isRespondingToSideChatInteraction = false
    @Published private(set) var sideChatError: String?
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
    @Published private(set) var taskModelOverrides: [String: String]
    /// The provider-reported model captured when a task is first overridden.
    /// Providers update `RuntimeThread.model` after a successful switched
    /// turn, so deriving the reset target from the live thread would make the
    /// override replace its own default.
    @Published private(set) var taskModelDefaults: [String: String]
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
    /// Indicates that the current scope has been populated by a successful
    /// provider list read. New/failed destination models keep the shared
    /// project catalog visible until this becomes true; logout explicitly
    /// marks its empty list authoritative.
    @Published private(set) var hasAuthoritativeThreadListForCurrentScope = false

    private let runtime: (any AgentRuntime)?
    /// The runtime kind is available before a provider session has connected.
    /// Use it only as a fallback; a connected session supplies the configured
    /// provider name (for example, "vLLM").
    private let runtimeKind: AgentRuntimeKind?
    private let startupError: (any Error)?
    private let preferences: UserDefaults
    private let composerDraftPersistence: any OnyxComposerDraftPersisting
    private let preferenceNamespace: OnyxPreferenceNamespace
    private let pinnedThreadStore: OnyxPinnedThreadStore
    private let workspacePersistenceStore: OnyxWorkspacePersistenceStore?
    /// The window composition root scopes this callback to the active
    /// provider.  It is invoked only after the runtime has accepted a user
    /// message, never when the user merely browses the model picker.
    private let modelUsageRecorder: @MainActor (String) -> Void
    private var pinnedThreadCancellable: AnyCancellable?
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var connectionRevision: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var earlierHistoryTask: Task<Void, Never>?
    private var threadListTask: Task<Void, Never>?
    private var deltaFlushTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var composerDraftPersistenceRevision: UInt64 = 0
    /// Coalesces the small set of changed draft entries until the next writer
    /// submission. The production writer consumes these deltas without
    /// retaining `composerDrafts` and forcing a whole-dictionary COW on the
    /// next keystroke or navigation action.
    private var pendingComposerDraftMutations: [String: OnyxComposerDraftMutation] = [:]
    private var catalogThreadsCacheRevision: UInt64?
    private var catalogThreadsCache: [RuntimeThread] = []
    private var accountRefreshTask: Task<Void, Never>?
    private var sideChatForkTask: Task<Void, Never>?
    private var sideChatTurnTask: Task<Void, Never>?
    private struct DeltaKey: Hashable {
        let threadID: String
        let itemID: String
    }

    private var pendingDeltas: [DeltaKey: String] = [:]
    private var collaborationAgentsByID: [String: RuntimeCollaborationAgent] = [:]
    private var activeTurnIDsByThreadID: [String: String] = [:]
    /// A fresh send paints before the provider reports its stable turn ID.
    /// Retain that exact optimistic user item until `turnStarted` binds it to
    /// the provider turn, then replace it with the stable item notification.
    private var pendingUserItemByThreadID: [String: TimelineItem] = [:]
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
    /// Provider requests that were already pending when account access expired
    /// remain visible as context, but their old request IDs must never become
    /// authorizing again merely because login succeeded. A fresh provider
    /// interaction event after recovery explicitly releases one quarantine.
    private var recoveryQuarantinedInteractionIDs: Set<RuntimeRequestID> = []
    /// Fences response completions that began before the account-recovery
    /// boundary. Even an unusually late success cannot clear or implicitly
    /// reuse the old approval after credentials have changed.
    private var recoveryInteractionGeneration: UInt64 = 0
    private var pendingRestoredSelectionID: String?
    private var cancelledLoginID: String?
    /// A stale signed-in event cannot prove that a revoked refresh token was
    /// replaced. Clear recovery only after a login started from that recovery
    /// completes and its authoritative account read confirms the new session.
    private var loginRecoveryPendingConfirmation = false
    /// The last authoritative, provider-reported identity that owns the
    /// account-scoped state mounted in this window. During an expired-login
    /// recovery, this is frozen before a new ceremony begins so a successful
    /// refresh cannot silently attach account A's task or draft to account B.
    /// A nil value is deliberately not treated as proof that two accounts are
    /// equal; identity-less recovery takes the destructive boundary rather
    /// than risking old account state under replacement credentials.
    private var mountedAccountIdentity: AccountIdentity?
    private var authenticationRecoveryAccountIdentity: AccountIdentity?
    private var didStart = false
    private var navigationRevision = 0
    /// Distinguishes the user's first explicit New Task action from the
    /// synthetic welcome surface shown while the provider catalog is loading.
    /// Repeated clicks on an already-visible blank composer remain idempotent,
    /// while the first click can invalidate startup restoration or a stale
    /// refresh result.
    private var hasExplicitNewTaskSelection = false
    /// Invalidates async work that began while a different provider account
    /// owned the visible task state.
    private var accountEpoch: UInt64 = 0
    /// Separates successive destructive history operations so a late completion
    /// from an invalidated account cannot unlock a newer edit request.
    private var latestMessageEditGeneration: UInt64 = 0
    private var latestMessageEditThreadID: String?
    /// An ambiguous provider failure keeps sending locked until a later task
    /// open proves which history the provider retained.
    private var latestMessageEditRequiresReloadThreadID: String?
    private var sideChatGeneration: UInt64 = 0
    private var sideChatPendingDeltas: [String: String] = [:]
    private var sideChatModelID: String?
    private var sideChatReasoningEffort: String?
    private var sideChatCWD: String?
    /// Retain every side-chat ID for this window/runtime session. The runtime
    /// also quarantines Codex ephemeral IDs, but keeping this UI-level set makes
    /// the provider-neutral reducer safe against late events from any future
    /// ephemeral-capable adapter without an arbitrary eviction boundary.
    private var discardedSideChatThreadIDs: Set<String> = []

    /// ChatGPT email is the stable account identifier exposed by app-server's
    /// authoritative `account/read` result. Authentication mode is included so
    /// identities from unrelated credential systems can never compare equal.
    private struct AccountIdentity: Equatable {
        let mode: RuntimeAuthMode
        let email: String

        init?(_ auth: RuntimeAuthState) {
            guard let mode = auth.mode,
                  let email = auth.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else { return nil }
            self.mode = mode
            self.email = email.lowercased()
        }
    }

    /// Cursor-backed providers hydrate older turns remotely. Providers without
    /// that capability still get the same bounded presentation by retaining
    /// their already-read transcript and revealing it one small page at a
    /// time. This keeps the UI contract provider neutral.
    private enum EarlierHistorySource {
        case provider(cursor: String)
        case buffered(
            items: [TimelineItem],
            visibleStartIndex: Int,
            nextProviderCursor: String?
        )
    }

    private var earlierHistorySource: EarlierHistorySource?
    /// Retains provider turn identity for history operations such as editing
    /// the latest user message. Turns are stored in chronological order even
    /// when the provider pages newest-first.
    private(set) var loadedConversationTurns: [RuntimeConversationTurn] = []
    private var resumedThreadID: String?

    private static let historyTurnPageSize = 12
    private static let bufferedHistoryPageItemLimit = 120

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
        /// A user-owned presentation row created at the synchronous send
        /// boundary. Existing tasks paint it before any resume/read can
        /// suspend, while new tasks retain it until their provider thread ID
        /// exists. The provider event later replaces this stable optimistic
        /// row with its authoritative user item.
        let optimisticUserItem: TimelineItem?
        let cwd: String?
        let wasTurnRunning: Bool
        /// Stable UI identity for a follow-up submitted into an already-live
        /// turn. It is absent for fresh turns and new-task creation.
        let pendingSteeringMessageID: UUID?
        let modelID: String?
        let reasoningEffort: String?
        let sandboxMode: RuntimeSandboxMode
        let approvalPolicy: RuntimeApprovalPolicy
        let navigationRevision: Int
        let accountEpoch: UInt64
    }

    /// The in-progress new-task state that should follow the user when they
    /// switch providers before sending.  This is deliberately separate from
    /// durable task state: an existing task keeps the model it was created
    /// with, while a welcome-task draft can move to another provider.
    struct NewTaskContext: Equatable, Sendable {
        let composerText: String
        let composerImages: [ComposerImageDraft]
        let workspacePath: String?
        let reasoningEffort: String?
        let permissionLabel: String
    }

    /// Exact window-owned input state carried across a same-provider runtime
    /// replacement. Unlike an ordinary provider switch, replacing stale
    /// credentials must not discard a draft attached to an existing task.
    struct RuntimeReplacementContext: Equatable, Sendable {
        let selectedThreadID: String?
        let threadListScope: ThreadListScope
        let composerDraftKey: String
        let composerText: String
        /// Image drafts are intentionally session-only, so carry every task's
        /// in-memory attachments across a runtime generation replacement. Text
        /// drafts are synchronously persisted before capture and reload from
        /// the shared window namespace; image bytes never touch UserDefaults.
        let composerImageDrafts: [String: [ComposerImageDraft]]
    }

    private enum PreferenceKey {
        static let sidebarVisible = "Onyx.sidebarVisible"
        static let inspectorVisible = "Onyx.inspectorVisible"
        static let bottomPanelVisible = "Onyx.bottomPanelVisible"
        static let inspectorTab = "Onyx.inspectorTab"
        static let selectedModel = "Onyx.selectedModelID"
        static let taskModelOverrides = "Onyx.taskModelOverrides"
        static let taskModelDefaults = "Onyx.taskModelDefaults"
        static let reasoningEffort = "Onyx.reasoningEffort"
        static let permissionLabel = "Onyx.permissionLabel"
        static let threadListScope = "Onyx.threadListScope"
        static let selectedThread = "Onyx.selectedThreadID"
        static let composerDrafts = "Onyx.composerDrafts"
        static let acknowledgedHistoryEditWarning = "Onyx.acknowledgedHistoryEditWarning"
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

    /// Codex exposes its login ceremonies through the app-server session
    /// snapshot. An expired account can fail that snapshot before a session
    /// reaches the window model, but the already-initialized runtime still
    /// knows how to accept the same ceremony IDs. Keep these provider-owned
    /// descriptors as a narrow presentation fallback so the recovery card can
    /// start sign-in immediately instead of forcing a reconnect loop.
    private static func fallbackLoginMethods(for kind: AgentRuntimeKind?) -> [RuntimeLoginMethod] {
        guard kind == .codex else { return [] }
        return [
            RuntimeLoginMethod(
                id: "codex.chatgpt.browser",
                displayName: "Continue with ChatGPT",
                detail: "Sign in securely in your browser",
                ceremony: .browser
            ),
            RuntimeLoginMethod(
                id: "codex.chatgpt.device-code",
                displayName: "Use a device code",
                detail: "Enter a one-time code at OpenAI",
                ceremony: .deviceCode
            ),
        ]
    }

    init(
        runtime: (any AgentRuntime)?,
        startupError: (any Error)? = nil,
        defaults: UserDefaults = .standard,
        preferenceKeyPrefix: String? = nil,
        pinnedThreadStore: OnyxPinnedThreadStore? = nil,
        workspacePersistenceStore: OnyxWorkspacePersistenceStore? = nil,
        startsWithNewTask: Bool = false,
        modelUsageRecorder: @escaping @MainActor (String) -> Void = { _ in },
        composerDraftPersistence: (any OnyxComposerDraftPersisting)? = nil
    ) {
        let preferenceNamespace = OnyxPreferenceNamespace(prefix: preferenceKeyPrefix)
        let pinnedThreadStore = pinnedThreadStore ?? OnyxPinnedThreadStore(defaults: defaults)
        self.runtime = runtime
        runtimeKind = runtime?.kind
        self.startupError = startupError
        preferences = defaults
        self.composerDraftPersistence = composerDraftPersistence
            ?? OnyxComposerDraftPersistenceWriter(defaults: defaults)
        self.preferenceNamespace = preferenceNamespace
        self.pinnedThreadStore = pinnedThreadStore
        self.workspacePersistenceStore = workspacePersistenceStore
        self.modelUsageRecorder = modelUsageRecorder
        let restoredScope = defaults.string(forKey: preferenceNamespace.key(PreferenceKey.threadListScope))
            .flatMap(ThreadListScope.init(rawValue:)) ?? .active
        let restoredDrafts = defaults.dictionary(
            forKey: preferenceNamespace.key(PreferenceKey.composerDrafts)
        ) as? [String: String] ?? [:]
        let restoredTaskModelOverrides = defaults.dictionary(
            forKey: preferenceNamespace.key(PreferenceKey.taskModelOverrides)
        ) as? [String: String] ?? [:]
        let restoredTaskModelDefaults = defaults.dictionary(
            forKey: preferenceNamespace.key(PreferenceKey.taskModelDefaults)
        ) as? [String: String] ?? [:]

        draftWorkspacePath = defaults.string(forKey: preferenceNamespace.key("Onyx.lastWorkspacePath"))
        composerDrafts = restoredDrafts
        composerDraftKey = Self.welcomeThread.id
        composerDraftModel = OnyxComposerDraftModel(
            text: restoredDrafts[Self.welcomeThread.id] ?? "",
            focusRequest: startsWithNewTask ? UUID() : nil
        )
        taskModelOverrides = restoredTaskModelOverrides
        taskModelDefaults = restoredTaskModelDefaults
        isSidebarVisible = Self.boolPreference(
            preferenceNamespace.key(PreferenceKey.sidebarVisible),
            default: true,
            defaults: defaults
        )
        isInspectorVisible = Self.boolPreference(
            preferenceNamespace.key(PreferenceKey.inspectorVisible),
            default: false,
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
        pendingRestoredSelectionID = startsWithNewTask
            ? Self.welcomeThread.id
            : defaults.string(forKey: preferenceNamespace.key(PreferenceKey.selectedThread))
        threads = restoredScope == .active ? [Self.welcomeThread] : []
        selectedThreadID = restoredScope == .active ? Self.welcomeThread.id : nil
        transcriptSnapshot = TranscriptPresentationSnapshot(
            items: restoredScope == .active ? [.welcome()] : []
        )

        pinnedThreadCancellable = pinnedThreadStore.$ids
            .dropFirst()
            .sink { [weak self] ids in
                self?.applyPinnedThreadIDs(ids)
            }
        composerDraftModel.onTextChanged = { [weak self] _ in
            self?.scheduleComposerDraftSave()
        }
        refreshSelectedThreadCache()

    }

    deinit {
        eventTask?.cancel()
        connectionTask?.cancel()
        loadTask?.cancel()
        earlierHistoryTask?.cancel()
        threadListTask?.cancel()
        deltaFlushTask?.cancel()
        draftSaveTask?.cancel()
        accountRefreshTask?.cancel()
        sideChatForkTask?.cancel()
        sideChatTurnTask?.cancel()
    }

    private func refreshSelectedThreadCache() {
        guard let selectedThreadID else {
            selectedThreadCache = nil
            selectedThreadCacheNeedsRefresh = false
            return
        }
        // The New Task composer is intentionally absent from the durable
        // provider catalog. Resolve that synthetic selection directly instead
        // of scanning thousands of provider tasks for an id that cannot be
        // present after ordinary New Task navigation.
        if selectedThreadID == Self.welcomeThread.id {
            selectedThreadCache = Self.welcomeThread
            selectedThreadCacheNeedsRefresh = false
            return
        }
        selectedThreadCache = threadIndex(for: selectedThreadID).map { threads[$0] }
        selectedThreadCacheNeedsRefresh = false
    }

    var selectedThread: RuntimeThread? {
        if selectedThreadCacheNeedsRefresh {
            refreshSelectedThreadCache()
        }
        return selectedThreadCache
    }

    /// The model originally recorded by the provider remains the task default.
    /// A user-selected override applies only to this task and can be reset
    /// without changing the new-task picker.
    var selectedTaskDefaultModelID: String? {
        guard let selectedThread,
              selectedThread.id != Self.welcomeThread.id else { return nil }
        let providerDefault = session?.availableModels.first(where: \.isDefault)?.id
            ?? session?.availableModels.first?.id
        guard let rawModel = taskModelDefaults[selectedThread.id]
            ?? selectedThread.model
            ?? providerDefault else { return nil }
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return model
    }

    var selectedTaskModelOverrideID: String? {
        guard let selectedThread,
              selectedThread.id != Self.welcomeThread.id,
              let model = taskModelOverrides[selectedThread.id]?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !model.isEmpty else { return nil }
        return model
    }

    var selectedTaskModelID: String? {
        selectedTaskModelOverrideID ?? selectedTaskDefaultModelID
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
        guard authState.canRun, authenticationRecovery == nil, !isSigningOut else { return false }
        if case .connected = connectionState { return true }
        return false
    }

    /// A follow-up submitted while a response is active is a provider
    /// `steer` operation, not a second independent turn. Keep the composer
    /// editable for every runtime, but expose/accept its Send action only
    /// when the selected task can actually steer the active turn.
    var canQueueFollowUp: Bool {
        !isTurnRunning || supports(.steering)
    }

    /// Steering feedback follows the selected task, but requests for other
    /// tasks remain retained until their provider event or turn completion
    /// arrives. This makes a quick navigation away and back lossless without
    /// publishing an app-owned message into durable history.
    var pendingSteeringMessagesForSelectedThread: [PendingSteeringMessage] {
        guard let selectedThreadID else { return [] }
        return pendingSteeringMessagesByThreadID[selectedThreadID] ?? []
    }

    /// Drafting is a local window action and must not depend on provider or
    /// task writer availability. Keep the native editor available while a
    /// provider reconnects, an approval is pending, or a review owns the task;
    /// the Send action remains separately gated until writing is safe.
    var canEditComposer: Bool {
        !isShowingArchivedThreads
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

    /// Side chat is available only for runtimes that can make a real
    /// non-durable fork. OpenAI-compatible chat runtimes deliberately do not
    /// claim this capability, so their workspace never offers a misleading
    /// fallback that would create a durable conversation.
    var canOpenSideChat: Bool {
        guard canRunAgent,
              supports(.ephemeralThreadForking),
              !isShowingArchivedThreads,
              let thread = selectedThread,
              thread.id != Self.welcomeThread.id else { return false }
        return true
    }

    var canComposeSideChat: Bool {
        isSideChatPresented
            && !isSideChatLoading
            && sideChatThreadID != nil
            && canRunAgent
    }

    var canRetrySideChatFork: Bool {
        guard isSideChatPresented,
              !isSideChatLoading,
              sideChatThreadID == nil,
              sideChatError != nil,
              let parentID = sideChatParentThreadID,
              selectedThreadID == parentID else { return false }
        return canOpenSideChat
    }

    var canSendSideChat: Bool {
        guard canComposeSideChat,
              sideChatInteraction?.isBlocking != true else { return false }
        return !sideChatComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !sideChatComposerImages.isEmpty
    }

    var canAttachSideChatImages: Bool {
        guard canComposeSideChat,
              supports(.images),
              canRunAgent else { return false }
        guard let sideChatModelID,
              let model = session?.availableModels.first(where: { $0.id == sideChatModelID })
        else { return true }
        return model.inputModalities.contains(.image)
    }

    var sideChatModelName: String {
        guard let sideChatModelID else { return selectedModelName }
        return session?.availableModels.first(where: { $0.id == sideChatModelID })?.displayName
            ?? sideChatModelID
    }

    var sideChatReasoningEffortName: String {
        guard let sideChatReasoningEffort else { return "Default reasoning" }
        switch sideChatReasoningEffort.lowercased() {
        case "xhigh": return "X-High reasoning"
        case "max": return "Max reasoning"
        case "ultra": return "Ultra reasoning"
        default: return "\(sideChatReasoningEffort.capitalized) reasoning"
        }
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
            && !isPreparingLatestMessageEdit(for: thread.id)
            && !hasPendingInteraction(for: thread.id, blockingOnly: true)
    }

    /// The transcript may expose one edit affordance: the newest visible user
    /// message, provided its complete provider turn identity is loaded. Older
    /// messages never become editable merely because a later turn is busy or
    /// failed; that would make the button silently target the wrong history
    /// boundary.
    var latestEditableUserMessageID: String? {
        latestEditableUserMessage?.message.id
    }

    /// A failed latest turn can be retried directly. The operation uses the
    /// same provider-owned revert boundary as editing, so the failed response
    /// and original prompt are removed before one replacement send begins.
    var retryableFailedUserMessageID: String? {
        failedLatestUserMessage?.message.id
    }

    /// Retry is presented beside the failed response the user is looking at,
    /// while the action resolves back to the user message in that same turn.
    var retryableFailedResponseItemID: String? {
        return failedLatestUserMessage?.turn.items.last(where: {
            $0.kind == .assistantMessage || $0.kind == .error
        })?.id
    }

    func retryUserMessageID(forFailedResponseItemID itemID: String) -> String? {
        guard let candidate = failedLatestUserMessage,
              candidate.turn.items.contains(where: { $0.id == itemID }) else { return nil }
        return candidate.message.id
    }

    var isPreparingLatestMessageEditForSelectedThread: Bool {
        selectedThreadID.map(isPreparingLatestMessageEdit(for:)) == true
    }

    var isPreparingFailedResponseRetryForSelectedThread: Bool {
        isPreparingFailedResponseRetry
            && selectedThreadID != nil
            && selectedThreadID == latestMessageEditThreadID
    }

    private func isPreparingLatestMessageEdit(for threadID: String) -> Bool {
        isPreparingLatestMessageEdit && latestMessageEditThreadID == threadID
    }

    private struct EditableUserMessage {
        let turn: RuntimeConversationTurn
        let message: TimelineItem
    }

    private var latestEditableUserMessage: EditableUserMessage? {
        guard canRunAgent,
              supports(.threadHistoryRevert),
              !isLoadingThread,
              !isShowingArchivedThreads,
              let thread = selectedThread,
              thread.id != Self.welcomeThread.id,
              selectedThreadID == thread.id,
              !isPreparingLatestMessageEdit(for: thread.id),
              !isTurnRunning,
              !thread.status.isBusy,
              !isReviewActive(for: thread.id),
              !hasPendingInteraction(for: thread.id, blockingOnly: true),
              let turnIndex = loadedConversationTurns.lastIndex(where: { turn in
                  turn.items.contains(where: { $0.kind == .userMessage })
              }) else { return nil }

        let turn = loadedConversationTurns[turnIndex]
        let userMessages = turn.items.filter { $0.kind == .userMessage }
        guard turn.itemDetail == .full,
              turn.status == .completed || turn.status == .interrupted || turn.status == .failed,
              userMessages.count == 1,
              let message = userMessages.first,
              timeline.last(where: { $0.kind == .userMessage })?.id == message.id
        else { return nil }
        return EditableUserMessage(turn: turn, message: message)
    }

    private var failedLatestUserMessage: EditableUserMessage? {
        guard let candidate = latestEditableUserMessage,
              candidate.turn.status == .failed else { return nil }
        return candidate
    }

    var activeUserInteraction: RuntimeUserInteraction? {
        // A request that was on screen when sign-in expired is still useful
        // context. Keep presenting it while the account recovery surface owns
        // the next action; `canRespond(to:)` independently keeps every old
        // approval, answer, or form submission non-authorizing.
        guard !isShowingArchivedThreads,
              !isSigningOut,
              authenticationRecovery != nil || canRunAgent else { return nil }
        let eligible = pendingUserInteractions.filter { interaction in
            interaction.threadID == nil || interaction.threadID == selectedThreadID
        }
        return eligible.first(where: \.isBlocking) ?? eligible.first
    }

    func canForkThread(_ thread: RuntimeThread) -> Bool {
        canRunAgent
            && !thread.status.isBusy
            && !isPreparingLatestMessageEdit(for: thread.id)
            && !isReviewActive(for: thread.id)
            && !hasPendingInteraction(for: thread.id, blockingOnly: true)
    }

    func canCompactThread(_ thread: RuntimeThread) -> Bool {
        canForkThread(thread)
    }

    func canArchiveThread(_ thread: RuntimeThread) -> Bool {
        canRunAgent
            && !thread.status.isBusy
            && !isPreparingLatestMessageEdit(for: thread.id)
            && !isReviewActive(for: thread.id)
            && !hasPendingInteraction(for: thread.id, blockingOnly: false)
    }

    func canDeleteThread(_ thread: RuntimeThread) -> Bool {
        canRunAgent
            && thread.id != Self.welcomeThread.id
            && !isPreparingLatestMessageEdit(for: thread.id)
            && !isReviewActive(for: thread.id)
    }

    func canRespond(to interaction: RuntimeUserInteraction) -> Bool {
        guard canRunAgent,
              !recoveryQuarantinedInteractionIDs.contains(interaction.id),
              !respondingInteractionIDs.contains(interaction.id) else { return false }
        if sideChatInteraction == interaction {
            return interaction.threadID == sideChatThreadID
                && !isRespondingToSideChatInteraction
        }
        return pendingUserInteractions.contains(interaction)
            && (interaction.threadID == nil || interaction.threadID == selectedThreadID)
    }

    func isResponding(to interaction: RuntimeUserInteraction) -> Bool {
        respondingInteractionIDs.contains(interaction.id)
            || (sideChatInteraction?.id == interaction.id && isRespondingToSideChatInteraction)
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
        guard pendingUserInteractions.contains(interaction)
                || sideChatInteraction == interaction else { return }
        questionDrafts[interaction.id] = InteractionDraftEntry(interaction: interaction, value: draft)
    }

    func formDraft(for interaction: RuntimeUserInteraction) -> RuntimeFormDraft {
        guard let entry = formDrafts[interaction.id], entry.interaction == interaction else {
            return Self.defaultFormDraft(for: interaction)
        }
        return entry.value
    }

    func updateFormDraft(_ draft: RuntimeFormDraft, for interaction: RuntimeUserInteraction) {
        guard pendingUserInteractions.contains(interaction)
                || sideChatInteraction == interaction else { return }
        formDrafts[interaction.id] = InteractionDraftEntry(interaction: interaction, value: draft)
    }

    var primaryLoginMethod: RuntimeLoginMethod? {
        let methods = session?.availableLoginMethods ?? Self.fallbackLoginMethods(for: runtimeKind)
        return methods.first(where: { $0.ceremony == .browser })
            ?? methods.first
    }

    var deviceCodeLoginMethod: RuntimeLoginMethod? {
        let methods = session?.availableLoginMethods ?? Self.fallbackLoginMethods(for: runtimeKind)
        return methods.first(where: { $0.ceremony == .deviceCode })
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

    /// Durable provider tasks exclude Onyx's synthetic composer row. Keeping
    /// that row out of the published multi-thousand-task array means New Task
    /// can change selection without copying and republishing the whole list.
    var catalogThreads: [RuntimeThread] {
        if catalogThreadsCacheRevision == threadListRevision {
            return catalogThreadsCache
        }
        // Filter by identity rather than relying on the synthetic row staying
        // at index zero. A provider update can reorder the array by recency.
        catalogThreadsCache = threads.filter { $0.id != Self.welcomeThread.id }
        catalogThreadsCacheRevision = threadListRevision
        return catalogThreadsCache
    }

    /// A task can be opened directly from the shared sidebar cache before it
    /// appears in this provider model's first list page. Keep the cached
    /// projection authoritative until the direct read inserts that task; using
    /// the incomplete live snapshot would make the selected row disappear.
    var hasUnlistedSelectedTask: Bool {
        guard let selectedThreadID,
              selectedThreadID != Self.welcomeThread.id else { return false }
        return !threads.contains { $0.id == selectedThreadID }
    }

    var projectName: String {
        selectedProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose project"
    }

    var selectedProjectPath: String? {
        selectedThreadID == Self.welcomeThread.id
            ? draftWorkspacePath
            : selectedThread?.cwd
    }

    var selectedModelName: String {
        if let selectedTaskModelID {
            return session?.availableModels.first(where: { $0.id == selectedTaskModelID })?.displayName
                ?? selectedTaskModelID
        }
        guard let selectedModelID else {
            return session?.availableModels.first(where: \.isDefault)?.displayName
                ?? session?.availableModels.first?.displayName
                ?? (runtimeKind == .codex ? "Codex" : "Choose model")
        }
        return session?.availableModels.first(where: { $0.id == selectedModelID })?.displayName ?? selectedModelID
    }

    /// A user-facing runtime label. Remote providers should be identified by
    /// their configured connection name, never by the Codex implementation
    /// they do not use.
    var runtimeDisplayName: String {
        if let displayName = session?.displayName.nilIfEmpty { return displayName }
        if runtimeKind == .codex { return "Codex" }
        return "Agent runtime"
    }

    /// Safe UI-facing identity for account recovery copy. The concrete
    /// runtime remains private so views cannot couple to provider internals.
    var isCodexRuntime: Bool { runtimeKind == .codex }

    private var connectionFailureNoticeTitle: String {
        "\(runtimeDisplayName) did not connect"
    }

    private var signInRequiredDetail: String {
        if runtimeKind == .codex {
            return "Connect your ChatGPT account before starting or continuing a Codex task."
        }
        return "Add valid credentials for \(runtimeDisplayName) before starting or continuing a task."
    }

    var availableReasoningEfforts: [String] {
        guard let model = selectedRuntimeModel else { return [] }
        guard model.supportedRequestParameters.isEmpty
                || model.supportedRequestParameters.contains(.reasoningEffort)
        else { return [] }
        return model.reasoningEfforts
    }

    var selectedReasoningEffortName: String {
        guard let selectedReasoningEffort else { return "Default" }
        return reasoningEffortName(selectedReasoningEffort)
    }

    func reasoningEffortName(_ effort: String) -> String {
        switch effort.lowercased() {
        case "xhigh": return "X-High"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return effort.capitalized
        }
    }

    func supports(_ capability: RuntimeCapabilities) -> Bool {
        guard downgradedRuntimeCapabilities.intersection(capability).isEmpty else {
            return false
        }
        if let thread = selectedThread,
           thread.id != Self.welcomeThread.id,
           let capabilities = thread.taskCapabilities {
            return capabilities.contains(capability)
        }
        if let capabilities = selectedRuntimeModel?.taskCapabilities {
            return capabilities.contains(capability)
        }
        return session?.capabilities.contains(capability) == true
    }

    var canAttachImages: Bool {
        guard supports(.images), canRunAgent, !isSelectedThreadArchived else { return false }
        guard let selectedRuntimeModel else { return true }
        return selectedRuntimeModel.inputModalities.contains(.image)
    }

    var selectedRuntimeModel: RuntimeModel? {
        let models = session?.availableModels ?? []
        if let selectedTaskModelID {
            return models.first(where: { $0.id == selectedTaskModelID })
        }
        if let selectedModelID,
           let selected = models.first(where: { $0.id == selectedModelID }) {
            return selected
        }
        return models.first(where: \.isDefault) ?? models.first
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
        guard canAttachImages else {
            notice = ("Images are not available", "The selected runtime does not support image input for this task.")
            return
        }
        let epoch = accountEpoch
        let draftKey = composerDraftKey
        Task { [weak self] in
            let results = await ComposerImageValidator.pastedImages(images)
            guard let self,
                  accountEpoch == epoch,
                  composerDraftKey == draftKey else { return }
            addComposerImages(results)
        }
    }

    func removeComposerImage(id: UUID) {
        composerImages.removeAll { $0.id == id }
        saveCurrentImageDraftNow()
    }

    func chooseSideChatImages(window: NSWindow?) {
        guard canAttachSideChatImages else {
            notice = ("Images are not available", "The side chat model does not support image input.")
            return
        }
        let epoch = accountEpoch
        let generation = sideChatGeneration
        let panel = NSOpenPanel()
        panel.title = "Attach images to side chat"
        panel.prompt = "Attach"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .heif]
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      accountEpoch == epoch,
                      sideChatGeneration == generation,
                      isSideChatPresented else { return }
                addSideChatImageFiles(panel.urls)
            }
        }
        guard let window else { return }
        panel.beginSheetModal(for: window, completionHandler: completion)
    }

    func addSideChatImageFiles(_ urls: [URL]) {
        addSideChatImages(urls.map { url in
            Result { try ComposerImageValidator.localFile(at: url) }
        })
    }

    func addPastedSideChatImages(_ images: [NSImage]) {
        guard canAttachSideChatImages else {
            notice = ("Images are not available", "The side chat model does not support image input.")
            return
        }
        let epoch = accountEpoch
        let generation = sideChatGeneration
        Task { [weak self] in
            let results = await ComposerImageValidator.pastedImages(images)
            guard let self,
                  accountEpoch == epoch,
                  sideChatGeneration == generation,
                  isSideChatPresented else { return }
            addSideChatImages(results)
        }
    }

    func removeSideChatImage(id: UUID) {
        sideChatComposerImages.removeAll { $0.id == id }
    }

    private func addSideChatImages(_ results: [Result<ComposerImageDraft, any Error>]) {
        guard canAttachSideChatImages else {
            notice = ("Images are not available", "The side chat model does not support image input.")
            return
        }
        var accepted = sideChatComposerImages
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
        sideChatComposerImages = accepted
        if let firstError {
            notice = ("Could not attach image", firstError.localizedDescription)
        }
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

    func selectTaskModel(_ id: String) {
        guard let selectedThread,
              selectedThread.id != Self.welcomeThread.id else { return }
        let modelID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }

        var updated = taskModelOverrides
        var updatedDefaults = taskModelDefaults
        let taskDefaultModelID = selectedTaskDefaultModelID
        if modelID == taskDefaultModelID {
            updated.removeValue(forKey: selectedThread.id)
        } else {
            // Preserve the provider-recorded model before the runtime can
            // publish this override back onto `RuntimeThread.model`.
            if updatedDefaults[selectedThread.id] == nil,
               let taskDefaultModelID {
                updatedDefaults[selectedThread.id] = taskDefaultModelID
            }
            updated[selectedThread.id] = modelID
        }
        guard updated != taskModelOverrides || updatedDefaults != taskModelDefaults else { return }
        taskModelOverrides = updated
        taskModelDefaults = updatedDefaults
        persistTaskModelSelections()
        validateSelectedReasoningEffort()
    }

    func resetSelectedTaskModel() {
        guard let threadID = selectedThread?.id,
              threadID != Self.welcomeThread.id,
              taskModelOverrides[threadID] != nil else { return }
        taskModelOverrides.removeValue(forKey: threadID)
        persistTaskModelSelections()
        validateSelectedReasoningEffort()
    }

    /// Captures only the welcome-task state that is safe to carry between
    /// provider windows. Existing tasks return nil because their transcript,
    /// cwd, and model belong to their original provider.
    func captureNewTaskContext() -> NewTaskContext? {
        guard threadListScope == .active,
              selectedThreadID == nil || selectedThreadID == Self.welcomeThread.id else {
            return nil
        }
        return NewTaskContext(
            composerText: composerText,
            composerImages: composerImages,
            workspacePath: draftWorkspacePath,
            reasoningEffort: selectedReasoningEffort,
            permissionLabel: permissionLabel
        )
    }

    /// Restores a welcome-task draft after a provider/model switch. The target
    /// model itself is selected by the caller; reasoning is validated again
    /// when that provider's model catalog arrives.
    func restoreNewTaskContext(_ context: NewTaskContext) {
        guard threadListScope == .active,
              selectedThreadID == nil || selectedThreadID == Self.welcomeThread.id else {
            return
        }
        composerDraftKey = Self.welcomeThread.id
        draftWorkspacePath = context.workspacePath
        if let workspacePath = context.workspacePath, !workspacePath.isEmpty {
            preferences.set(workspacePath, forKey: preferenceKey("Onyx.lastWorkspacePath"))
        } else {
            preferences.removeObject(forKey: preferenceKey("Onyx.lastWorkspacePath"))
        }
        permissionLabel = context.permissionLabel
        selectedReasoningEffort = context.reasoningEffort
        composerImages = context.composerImages
        composerText = context.composerText
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()
    }

    func selectReasoningEffort(_ effort: String) {
        guard availableReasoningEfforts.contains(effort) else { return }
        selectedReasoningEffort = effort
    }

    func startLogin(_ method: RuntimeLoginMethod) {
        guard let runtime, !isAuthenticating, loginAttempt == nil else { return }
        cancelledLoginID = nil
        // A recovery login is not confirmed merely because its browser/device
        // ceremony opened. Arm confirmation only from the matching successful
        // completion event, then require an authoritative account refresh.
        loginRecoveryPendingConfirmation = false
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
                loginRecoveryPendingConfirmation = false
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
                loginRecoveryPendingConfirmation = false
            } catch {
                cancelledLoginID = nil
                isAuthenticating = false
                loginRecoveryPendingConfirmation = false
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
            connectionState = .failed(startupError?.localizedDescription ?? "\(runtimeDisplayName) is unavailable")
            return
        }

        eventTask = Task { [weak self, events = runtime.events] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }

        beginConnection(
            preferredSelection: selectedThreadID == nil
                || selectedThreadID == Self.welcomeThread.id
                ? pendingRestoredSelectionID
                : nil,
            rehydrateVisibleThread: false
        )
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
        let navigationAtStart = navigationRevision
        let selectedTaskAtStart = selectedThreadID.flatMap { id in
            id == Self.welcomeThread.id ? nil : id
        }
        connectionTask?.cancel()
        connectionState = .connecting
        if notice?.title == connectionFailureNoticeTitle {
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
                if let recovery = authenticationRecovery(for: error) {
                    // The Codex runtime can reject account/read before it has
                    // produced a session snapshot. Keep this failure attached
                    // to the workspace so the recovery card can offer its
                    // login ceremonies; a raw connection alert would both
                    // leak provider diagnostics and leave the user in a
                    // reconnect loop.
                    requireAuthenticationRecovery(recovery)
                    connectionState = .failed("Sign in required")
                    if notice?.title == connectionFailureNoticeTitle {
                        notice = nil
                    }
                    return
                }
                connectionState = .failed(error.localizedDescription)
                notice = (connectionFailureNoticeTitle, error.localizedDescription)
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
                // A user navigation that happened while the catalog was in
                // flight owns the visible selection. The one exception is an
                // explicit New Task action: its welcome selection must win
                // over the restored/refresh selection captured above.
                let navigationStillValid = navigationRevision == navigationAtStart
                    || hasExplicitNewTaskSelection
                if !navigationStillValid {
                    // The list read is still a complete provider snapshot even
                    // when a click changed the selected task while it was in
                    // flight. Publish it without taking ownership of that
                    // newer selection; discarding it would leave the sidebar
                    // permanently cache-only and stale until reconnect.
                    applyThreadList(
                        liveThreads,
                        scope: scope,
                        preferredSelection: selectedThreadID,
                        preserveCurrentSelection: true
                    )
                    pendingRestoredSelectionID = nil
                    return
                }
                let effectivePreferredSelection = hasExplicitNewTaskSelection
                    ? Self.welcomeThread.id
                    : preferredSelection
                applyThreadList(
                    liveThreads,
                    scope: scope,
                    preferredSelection: effectivePreferredSelection,
                    preserveCurrentSelection: selectedTaskAtStart != nil
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
        if id != Self.welcomeThread.id {
            hasExplicitNewTaskSelection = false
            // An explicit task click supersedes any selection restored from
            // preferences, including when it lands before SwiftUI starts a
            // newly-created provider model.
            pendingRestoredSelectionID = nil
        }
        closeSideChat()
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()

        navigationRevision += 1
        selectedThreadID = id
        validateSelectedReasoningEffort()
        preferences.set(id, forKey: preferenceKey(PreferenceKey.selectedThread))
        loadComposerDraft(for: id)
        loadTask?.cancel()
        resetEarlierHistory()
        let selected = selectedThread
        isTurnRunning = selected.map {
            $0.status.isBusy || isReviewActive(for: $0.id)
        } ?? false

        guard id != Self.welcomeThread.id, let runtime else {
            replaceTimeline([.welcome()])
            isLoadingThread = false
            return
        }

        rememberWorkspace(selected?.cwd)

        isLoadingThread = true
        replaceTimeline([])
        let epoch = accountEpoch
        let liveRevisionAtReadStart = liveTimelineRevision(for: id)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loadInitialHistory(for: id, runtime: runtime)
                guard accountEpoch == epoch, !Task.isCancelled, selectedThreadID == id else { return }
                applyConversationSnapshot(
                    loaded.visibleItems,
                    for: loaded.conversation.thread.id,
                    preservingLiveUpdatesAfter: liveRevisionAtReadStart
                )
                installEarlierHistory(from: loaded)
                updateThread(
                    loaded.conversation.thread,
                    preservePositionIfPresent: true
                )
                isTurnRunning = loaded.conversation.thread.status.isBusy
                    || isReviewActive(for: loaded.conversation.thread.id)
                isLoadingThread = false
                resolveLatestMessageEditAfterAuthoritativeReload(threadID: id)
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

    /// Opens a provider-native, non-durable branch of the selected task. The
    /// fork is kept entirely in this window model: it is never inserted into
    /// `threads`, written to the conversation catalog, or used as the current
    /// durable task. A generation token makes a late fork response harmless
    /// if the user navigates away while app-server is preparing it.
    func openSideChat() {
        guard canOpenSideChat,
              let runtime,
              let parentThread = selectedThread else { return }

        if isSideChatPresented, sideChatParentThreadID == parentThread.id {
            return
        }

        closeSideChat()
        sideChatGeneration &+= 1
        let parentID = parentThread.id
        // Paginated Codex threads must fork with turns omitted from the wire
        // response. The ephemeral branch still inherits the provider context;
        // seed its UI from the already-visible parent snapshot so the panel
        // paints immediately without another full-history request.
        let visibleParentContext = timeline

        sideChatParentThreadID = parentID
        sideChatThreadID = nil
        replaceSideChatTimeline(visibleParentContext)
        sideChatComposerText = ""
        sideChatComposerImages = []
        sideChatError = nil
        isSideChatPresented = true
        isSideChatLoading = true
        isSideChatTurnRunning = false
        sideChatPendingDeltas.removeAll()
        sideChatModelID = parentThread.model ?? selectedRuntimeModel?.id ?? selectedModelID
        sideChatReasoningEffort = selectedReasoningEffort
        sideChatCWD = parentThread.cwd

        startSideChatFork(parentID: parentID, runtime: runtime)
    }

    /// Retries only the failed remote fork. The panel, visible parent context,
    /// and any defensively retained local draft stay in place.
    func retrySideChatFork() {
        guard canRetrySideChatFork,
              let runtime,
              let parentID = sideChatParentThreadID else { return }

        sideChatForkTask?.cancel()
        sideChatForkTask = nil
        isSideChatLoading = true
        sideChatError = nil
        startSideChatFork(parentID: parentID, runtime: runtime)
    }

    private func startSideChatFork(parentID: String, runtime: any AgentRuntime) {
        let generation = sideChatGeneration
        let epoch = accountEpoch
        sideChatForkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let conversation = try await runtime.forkEphemeralThread(id: parentID)
                guard accountEpoch == epoch,
                      sideChatGeneration == generation,
                      isSideChatPresented,
                      sideChatParentThreadID == parentID,
                      selectedThreadID == parentID,
                      !Task.isCancelled else {
                    // The fork may have crossed the provider boundary just as
                    // the panel closed or navigation changed. Remember its ID
                    // before dropping the late response so no subsequent event
                    // can fall through to the durable task reducer.
                    rememberDiscardedSideChatThread(conversation.thread.id)
                    return
                }

                sideChatThreadID = conversation.thread.id
                if !conversation.items.isEmpty {
                    replaceSideChatTimeline(conversation.items)
                }
                sideChatModelID = conversation.thread.model ?? sideChatModelID
                sideChatCWD = conversation.thread.cwd ?? sideChatCWD
                isSideChatLoading = false
                sideChatError = nil
                sideChatForkTask = nil
            } catch {
                guard accountEpoch == epoch,
                      sideChatGeneration == generation,
                      isSideChatPresented,
                      sideChatParentThreadID == parentID,
                      !Task.isCancelled else { return }
                isSideChatLoading = false
                sideChatForkTask = nil
                if requireAuthenticationRecovery(for: error) {
                    sideChatError = nil
                    return
                }
                sideChatError = error.localizedDescription
            }
        }
    }

    /// Closes the ephemeral panel and drops every local fork reference. If a
    /// turn is live, interrupt it best-effort so closing the panel does not
    /// leave an invisible provider turn consuming resources.
    func closeSideChat() {
        // This path is also used by every navigation action. Avoid publishing
        // a dozen unchanged side-chat properties when the panel has never
        // been opened; those publications used to make a simple New Task
        // click rebuild the workspace repeatedly.
        guard isSideChatPresented
                || isSideChatLoading
                || sideChatParentThreadID != nil
                || sideChatThreadID != nil
                || !sideChatTimeline.isEmpty
                || !sideChatComposerText.isEmpty
                || !sideChatComposerImages.isEmpty
                || isSideChatTurnRunning
                || sideChatInteraction != nil
                || isRespondingToSideChatInteraction
                || sideChatError != nil
                || sideChatForkTask != nil
                || sideChatTurnTask != nil else { return }

        let threadID = sideChatThreadID
        let shouldInterrupt = isSideChatTurnRunning && canRunAgent
        if let interactionID = sideChatInteraction?.id {
            removeInteractionDraft(for: interactionID)
            recoveryQuarantinedInteractionIDs.remove(interactionID)
        }
        if let threadID {
            rememberDiscardedSideChatThread(threadID)
        }
        sideChatGeneration &+= 1
        sideChatForkTask?.cancel()
        sideChatForkTask = nil
        sideChatTurnTask?.cancel()
        sideChatTurnTask = nil
        sideChatPendingDeltas.removeAll()

        isSideChatPresented = false
        isSideChatLoading = false
        sideChatParentThreadID = nil
        sideChatThreadID = nil
        replaceSideChatTimeline([])
        sideChatComposerText = ""
        sideChatComposerImages = []
        isSideChatTurnRunning = false
        sideChatInteraction = nil
        isRespondingToSideChatInteraction = false
        sideChatError = nil
        sideChatModelID = nil
        sideChatReasoningEffort = nil
        sideChatCWD = nil

        guard shouldInterrupt, let runtime, let threadID else { return }
        Task { try? await runtime.interrupt(threadID: threadID) }
    }

    func sendSideChat() {
        let draft = sideChatComposerText
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = sideChatComposerImages
        guard !text.isEmpty || !images.isEmpty,
              isSideChatPresented,
              !isSideChatLoading,
              let threadID = sideChatThreadID,
              let runtime,
              canRunAgent,
              sideChatInteraction?.isBlocking != true else { return }
        guard images.isEmpty || canAttachSideChatImages else {
            notice = (
                "Images are not available",
                "The side chat model cannot receive these attachments. Remove them and try again."
            )
            return
        }

        let generation = sideChatGeneration
        let epoch = accountEpoch
        let modelID = sideChatModelID
        let reasoningEffort = sideChatReasoningEffort
        let cwd = sideChatCWD
        let parentID = sideChatParentThreadID
        let wasRunning = isSideChatTurnRunning
        let optimisticItemID = "side-optimistic:\(UUID().uuidString)"
        let steeringModelID = parentID.flatMap { parentID in
            threads.first(where: { $0.id == parentID })?.model
        } ?? modelID
        let inputs: [RuntimeTurnInput] = (text.isEmpty ? [] : [.text(text)]) + images.map(\.input)

        sideChatComposerText = ""
        sideChatComposerImages = []
        sideChatError = nil
        appendSideChatTimeline(
            TimelineItem(
                id: optimisticItemID,
                kind: .userMessage,
                title: nil,
                body: text,
                status: .completed,
                timestamp: .now,
                detail: nil,
                attachments: images.map(\.timelineAttachment)
            )
        )
        isSideChatTurnRunning = true

        sideChatTurnTask?.cancel()
        sideChatTurnTask = Task { [weak self] in
            guard let self else { return }
            do {
                if wasRunning {
                    try await runtime.steer(threadID: threadID, inputs: inputs)
                    recordModelUsageIfAvailable(steeringModelID)
                } else {
                    try await runtime.startTurn(
                        StartTurnRequest(
                            threadID: threadID,
                            inputs: inputs,
                            model: modelID,
                            cwd: cwd,
                            reasoningEffort: reasoningEffort,
                            sandboxMode: selectedSandboxMode,
                            approvalPolicy: selectedApprovalPolicy
                        )
                    )
                    recordModelUsageIfAvailable(modelID)
                }
                guard accountEpoch == epoch,
                      sideChatGeneration == generation,
                      isSideChatPresented,
                      sideChatThreadID == threadID,
                      sideChatParentThreadID == parentID,
                      !Task.isCancelled else { return }
            } catch {
                guard accountEpoch == epoch,
                      sideChatGeneration == generation,
                      isSideChatPresented,
                      sideChatThreadID == threadID,
                      !Task.isCancelled else { return }
                // A failed fresh start leaves no remote turn to stop. A failed
                // follow-up steer does not end the original turn, though, so
                // preserve its live state (unless a completion event already
                // cleared it while the steer request was in flight).
                if !wasRunning {
                    isSideChatTurnRunning = false
                }
                let laterDraft = sideChatComposerText
                if laterDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sideChatComposerText = draft
                } else if laterDraft != draft {
                    sideChatComposerText = draft.isEmpty ? laterDraft : draft + "\n\n" + laterDraft
                }
                let laterInputs = Set(sideChatComposerImages.map(\.input))
                sideChatComposerImages = images.filter { !laterInputs.contains($0.input) }
                    + sideChatComposerImages
                // The error strip below the transcript is the one visible
                // failure surface. Remove the optimistic sent row instead of
                // leaving it behind beside a second red error row; otherwise
                // retrying makes the panel look as though the same message
                // was sent repeatedly even though the provider rejected it.
                if let optimisticIndex = sideChatTimeline.firstIndex(where: {
                    $0.id == optimisticItemID
                }) {
                    var reconciled = sideChatTimeline
                    reconciled.remove(at: optimisticIndex)
                    replaceSideChatTimeline(reconciled)
                }
                if requireAuthenticationRecovery(for: error) {
                    sideChatError = nil
                    return
                }
                sideChatError = error.localizedDescription
            }
        }
    }

    func interruptSideChat() {
        guard canRunAgent, let runtime, let threadID = sideChatThreadID else { return }
        let generation = sideChatGeneration
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.interrupt(threadID: threadID)
            } catch {
                guard accountEpoch == epoch,
                      sideChatGeneration == generation,
                      isSideChatPresented else { return }
                if requireAuthenticationRecovery(for: error) {
                    sideChatError = nil
                    return
                }
                sideChatError = error.localizedDescription
            }
        }
    }

    func respondToSideChatInteraction(
        _ response: RuntimeUserInteractionResponse
    ) {
        guard let interaction = sideChatInteraction,
              canRespond(to: interaction),
              let runtime,
              !isRespondingToSideChatInteraction else { return }

        let epoch = accountEpoch
        let generation = sideChatGeneration
        let interactionGeneration = recoveryInteractionGeneration
        isRespondingToSideChatInteraction = true
        sideChatError = nil
        Task { [weak self] in
            guard let self else { return }
            defer {
                if sideChatGeneration == generation {
                    isRespondingToSideChatInteraction = false
                }
            }
            do {
                try await runtime.respond(to: interaction.id, with: response)
                guard accountEpoch == epoch,
                      sideChatGeneration == generation,
                      recoveryInteractionGeneration == interactionGeneration,
                      isSideChatPresented,
                      sideChatThreadID == interaction.threadID else { return }
                if sideChatInteraction?.id == interaction.id {
                    sideChatInteraction = nil
                    removeInteractionDraft(for: interaction.id)
                }
            } catch {
                guard accountEpoch == epoch,
                      sideChatGeneration == generation,
                      isSideChatPresented else { return }
                if !requireAuthenticationRecovery(for: error) {
                    sideChatError = error.localizedDescription
                }
            }
        }
    }

    /// Opens a same-runtime child conversation reported by a collaboration-capable runtime.
    ///
    /// Child threads are not guaranteed to be present in the current task list
    /// (for example, the provider may omit them from its normal listing). The
    /// normal selection path intentionally accepts an unknown id and reads it
    /// directly, after which the returned thread is inserted into the list.
    /// Cross-provider destinations are routed by the workspace composition
    /// layer, which owns provider selection. This compatibility entry point is
    /// retained for callers that are already bound to the destination runtime.
    func openCollaborationAgent(_ agent: RuntimeCollaborationAgent) {
        guard agent.destination?.isNavigable == true,
              let childThreadID = agent.destination?.navigableThreadID else {
            notice = ("Agent conversation unavailable", "This agent did not provide a conversation id.")
            return
        }
        guard runtime != nil else {
            notice = ("Agent conversation unavailable", "No agent runtime is configured for this workspace.")
            return
        }
        selectThread(childThreadID)
    }

    func newTask() {
        requestComposerFocus()

        // Treat a blank welcome surface as an idempotent click before
        // cancelling any in-flight list refresh. This matters while the first
        // active catalog is still loading: repeated clicks should not restart
        // a full provider fetch or queue several 4,824-row results.
        let isBlankWelcome = threadListScope == .active
            && selectedThreadID == Self.welcomeThread.id
            && composerText.isEmpty
            && composerImages.isEmpty
            && timeline.count == 1
            && timeline.first?.id == "onyx-welcome"
        if isBlankWelcome && !isTurnRunning
                && (hasExplicitNewTaskSelection
                    || (pendingRestoredSelectionID == nil && !isLoadingThreadList)) {
            return
        }

        hasExplicitNewTaskSelection = true
        pendingRestoredSelectionID = nil
        closeSideChat()
        loadTask?.cancel()
        resetEarlierHistory()
        let wasActiveScope = threadListScope == .active
        let canReuseConnectionRefresh = wasActiveScope
            && isLoadingThreadList
            && connectionTask != nil
            && threadListTask == nil
        threadListTask?.cancel()
        threadListTask = nil

        // New Task is also the escape hatch from the Archived view. Clear the
        // archived rows before changing scope so the workspace never projects
        // them into the active project catalog while the active list refreshes.
        // Mark the list as loading first; the workspace's catalog synchronizer
        // will wait for the active fetch instead of recording a transient
        // archived snapshot under the active scope.
        // Keep an active catalog mounted while its refresh is in flight. Replacing
        // a multi-thousand-row `threads` array here makes SwiftUI synchronously
        // tear down and diff the whole sidebar—the beachball users see when they
        // click New Task during startup/reconnect. The synthetic welcome row is
        // projected separately, so the composer can become usable immediately;
        // the pending refresh will reconcile the durable rows when it completes.
        let shouldClearCurrentList = threadListScope != .active
        let shouldRefreshActiveList = threadListScope != .active
            || (isLoadingThreadList && !canReuseConnectionRefresh)
        if shouldClearCurrentList {
            isLoadingThreadList = true
            hasAuthoritativeThreadListForCurrentScope = false
            threads = [Self.welcomeThread]
            threadListScope = .active
        }

        // Navigation must preserve the task being left, but serializing the
        // entire draft dictionary must not hold the main actor. Stage the
        // final in-memory snapshot first and let the revisioned writer handle
        // UserDefaults on its utility queue.
        draftSaveTask?.cancel()
        draftSaveTask = nil
        updateDraftCache(composerText, for: composerDraftKey)
        saveCurrentImageDraftNow()
        navigationRevision += 1
        if threadListScope != .active { threadListScope = .active }
        if selectedThreadID != Self.welcomeThread.id {
            selectedThreadID = Self.welcomeThread.id
        }
        preferences.set(Self.welcomeThread.id, forKey: preferenceKey(PreferenceKey.selectedThread))
        composerDraftKey = Self.welcomeThread.id
        if !composerText.isEmpty { composerText = "" }
        if !composerImages.isEmpty { composerImages = [] }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        updateDraftCache(composerText, for: composerDraftKey)
        persistComposerDraftCache(mode: .background)
        saveCurrentImageDraftNow()
        if timeline.count != 1 || timeline.first?.id != "onyx-welcome" {
            replaceTimeline([.welcome()])
        }
        if isLoadingThread { isLoadingThread = false }
        if isTurnRunning { isTurnRunning = false }

        if shouldRefreshActiveList, let runtime {
            let epoch = accountEpoch
            let navigationAtStart = navigationRevision
            isLoadingThreadList = true
            threadListTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let liveThreads = try await runtime.listAllThreads(archived: false).map { thread in
                        var projected = thread
                        projected.isPinned = self.pinnedThreadIDs.contains(thread.id)
                        return projected
                    }
                    let navigationStillValid = navigationRevision == navigationAtStart
                        || hasExplicitNewTaskSelection
                    guard accountEpoch == epoch,
                          !Task.isCancelled,
                          threadListScope == .active,
                          navigationStillValid else {
                        if accountEpoch == epoch,
                           threadListScope == .active,
                           !hasExplicitNewTaskSelection {
                            isLoadingThreadList = false
                        }
                        return
                    }
                    applyThreadList(
                        liveThreads,
                        scope: .active,
                        preferredSelection: Self.welcomeThread.id
                    )
                } catch {
                    guard accountEpoch == epoch,
                          !Task.isCancelled,
                          threadListScope == .active else { return }
                    isLoadingThreadList = false
                    notice = ("Connected, but tasks did not refresh", error.localizedDescription)
                }
            }
        } else if shouldRefreshActiveList {
            isLoadingThreadList = false
        }

    }

    /// Commits debounced window-owned state before its scene is released.
    /// Without this hook, pressing Command-W immediately after typing can
    /// cancel the pending draft write in deinit.
    func flushWindowState() {
        closeSideChat()
        saveCurrentDraftNow(mode: .synchronous)
        saveCurrentImageDraftNow()
    }

    /// Stages state before replacing this model inside a still-open window.
    /// Provider/model switches are interactive navigation, so they must not
    /// synchronously serialize every saved draft on the main actor. True scene
    /// teardown continues to use `flushWindowState()` as the durability fence.
    func stageWindowStateForReplacement() {
        closeSideChat()
        saveCurrentDraftNow(mode: .background)
        saveCurrentImageDraftNow()
    }

    /// Provider settings can retire this model's immutable runtime while its
    /// window stays open. Snapshot the visible task/draft directly so the fresh
    /// model does not depend on a debounced persistence write winning a race.
    func captureRuntimeReplacementContext() -> RuntimeReplacementContext {
        closeSideChat()
        saveCurrentDraftNow(mode: .synchronous)
        saveCurrentImageDraftNow()
        return RuntimeReplacementContext(
            selectedThreadID: pendingRestoredSelectionID ?? selectedThreadID,
            threadListScope: threadListScope,
            composerDraftKey: composerDraftKey,
            composerText: composerText,
            composerImageDrafts: composerImageDrafts
        )
    }

    func restoreRuntimeReplacementContext(_ context: RuntimeReplacementContext) {
        guard context.threadListScope == threadListScope else { return }
        composerDrafts[context.composerDraftKey] = context.composerText
        composerImageDrafts = context.composerImageDrafts
        composerDraftKey = context.composerDraftKey
        composerText = context.composerText
        composerImages = context.composerImageDrafts[context.composerDraftKey] ?? []
        pendingRestoredSelectionID = context.selectedThreadID
        hasExplicitNewTaskSelection = context.selectedThreadID == Self.welcomeThread.id
    }

    func setThreadListScope(_ scope: ThreadListScope) {
        guard scope != threadListScope, runtime != nil else { return }
        closeSideChat()
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()
        navigationRevision += 1
        threadListTask?.cancel()
        loadTask?.cancel()
        resetEarlierHistory()
        threadListScope = scope
        hasAuthoritativeThreadListForCurrentScope = false
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
        let navigationAtStart = navigationRevision
        threadListTask = Task { [weak self] in
            guard let self else { return }
            do {
                let liveThreads = try await fetchThreads(in: scope)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                applyThreadList(
                    liveThreads,
                    scope: scope,
                    preserveCurrentSelection: navigationRevision != navigationAtStart
                )
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
            Task { @MainActor [weak self] in
                guard let self, accountEpoch == epoch else { return }
                resolveWorkspaceChoice(response: response, path: panel.url?.path)
            }
        }
        guard let window else { return }
        panel.beginSheetModal(for: window, completionHandler: completion)
    }

    /// Restores the normal typing destination after the transient folder sheet
    /// closes. Cancellation must be just as lossless as choosing a folder: the
    /// still-visible composer should accept the next keystroke without another
    /// click. Archived history has no composer, so do not leave a latent focus
    /// token that could fire after navigating back to active tasks.
    func resolveWorkspaceChoice(
        response: NSApplication.ModalResponse,
        path: String?
    ) {
        guard response == .OK, let path else {
            if canEditComposer { requestComposerFocus() }
            return
        }
        selectWorkspace(path)
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
        } else {
            // Closing the project picker returns focus to the control that
            // opened it. Put the caret back in the still-visible draft so the
            // user can continue without a second click.
            requestComposerFocus()
        }
    }

    /// Starts a genuinely blank task from a project's quick-create action.
    /// Choosing a folder in the welcome composer intentionally preserves that
    /// draft; clicking a project's plus button is a different, explicit New
    /// Task command and must never carry the previous welcome draft with it.
    func newTask(inWorkspace path: String) {
        newTask()
        rememberWorkspace(path)
    }

    func sendComposer() {
        _ = submitComposer()
    }

    /// Returns true once the send has synchronously captured and cleared its
    /// input. Retry uses this acceptance boundary so a provider-state change
    /// cannot erase the original prompt after history was already reverted.
    @discardableResult
    private func submitComposer() -> Bool {
        guard !isPreparingLatestMessageEditForSelectedThread else { return false }
        let draftText = composerText
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = composerImages
        guard !text.isEmpty || !images.isEmpty else { return false }

        // Snapshot the exact draft before validation or any provider call.
        // Ordinary persistence is serialized on the utility queue so the
        // click can paint immediately; window/app teardown uses the explicit
        // synchronous flush boundary.
        saveCurrentDraftNow()
        saveCurrentImageDraftNow()

        guard images.count <= ComposerImageValidator.maximumCount else {
            notice = (
                "Too many images",
                "Keep up to \(ComposerImageValidator.maximumCount) attachments and try again. Your draft is still here."
            )
            return false
        }

        guard !isSelectedThreadArchived else { return false }
        guard !isReviewBlockingComposer else {
            notice = (
                "Review is still running",
                "Wait for the code review to finish or stop it before sending another message. Your draft is still here."
            )
            return false
        }
        guard let runtime else {
            notice = (
                "\(runtimeDisplayName) is unavailable",
                startupError?.localizedDescription ?? "Onyx could not start the configured runtime. Your draft is still here."
            )
            return false
        }
        guard activeUserInteraction?.isBlocking != true else {
            notice = (
                "Answer the pending request first",
                "\(runtimeDisplayName) is waiting for your response before this task can continue."
            )
            return false
        }
        guard canRunAgent else {
            notice = (
                "Sign in to continue",
                signInRequiredDetail
            )
            return false
        }
        guard images.isEmpty || canAttachImages else {
            notice = (
                "Images are not available",
                "The selected runtime cannot receive these attachments. Remove them or switch runtimes; your draft is still here."
            )
            return false
        }
        if selectedThreadID == nil || selectedThreadID == Self.welcomeThread.id {
            guard draftWorkspacePath != nil else {
                notice = ("Choose a project", "Select the folder Onyx should work in before starting a task.")
                return false
            }
        }

        // Existing tasks can each be pinned to a different model. Revalidate
        // at dispatch as a final guard against carrying an effort from the
        // previously selected task into this task's request.
        validateSelectedReasoningEffort()

        let originThread = selectedThread
        let originThreadID = selectedThreadID
        let isNewThread = originThreadID == nil || originThreadID == Self.welcomeThread.id
        let wasTurnRunning = originThread.map(\.status.isBusy) ?? isTurnRunning
        guard !wasTurnRunning || supports(.steering) else {
            notice = (
                "Follow-ups are unavailable",
                "This provider is still finishing the current response and does not support queued follow-ups. Your draft is still here."
            )
            return false
        }
        let pendingSteeringMessageID = !isNewThread && wasTurnRunning ? UUID() : nil
        let sourceDraftKey = composerDraftKey
        let provisionalDraftKey = isNewThread ? "onyx:pending:\(UUID().uuidString)" : nil
        let inputs: [RuntimeTurnInput] = (text.isEmpty ? [] : [.text(text)]) + images.map(\.input)
        let optimisticUserItem = contextOptimisticUserItem(
            text: text,
            images: images,
            wasTurnRunning: wasTurnRunning
        )
        let context = SendContext(
            draftText: draftText,
            text: text,
            images: images,
            inputs: inputs,
            sourceDraftKey: sourceDraftKey,
            provisionalDraftKey: provisionalDraftKey,
            originThreadID: originThreadID,
            isNewThread: isNewThread,
            optimisticUserItem: optimisticUserItem,
            cwd: isNewThread ? draftWorkspacePath : originThread?.cwd,
            wasTurnRunning: wasTurnRunning,
            pendingSteeringMessageID: pendingSteeringMessageID,
            // Capture the resolved default as well as an explicit picker
            // choice. This keeps the request and its usage attribution
            // aligned even when the user never opens the picker.
            // Existing tasks are pinned to the model recorded on their
            // thread unless this task has an explicit per-task override. The
            // window picker only chooses a model for a new task.
            modelID: selectedTaskModelID ?? selectedRuntimeModel?.id ?? selectedModelID,
            reasoningEffort: selectedReasoningEffort,
            sandboxMode: selectedSandboxMode,
            approvalPolicy: selectedApprovalPolicy,
            navigationRevision: navigationRevision,
            accountEpoch: accountEpoch
        )

        if let pendingSteeringMessageID, let originThreadID {
            enqueuePendingSteeringMessage(
                PendingSteeringMessage(
                    id: pendingSteeringMessageID,
                    threadID: originThreadID,
                    text: text,
                    attachmentCount: images.count,
                    state: .submitting
                )
            )
        }

        composerText = ""
        saveCurrentDraftNow()
        composerImages = []
        saveCurrentImageDraftNow()
        if let provisionalDraftKey {
            composerDraftKey = provisionalDraftKey
            composerText = composerDrafts[provisionalDraftKey] ?? ""
            composerImages = composerImageDrafts[provisionalDraftKey] ?? []
        }

        // Submission itself is visible work. Set this synchronously so the
        // transcript's inline waiting row appears in the same UI update that
        // clears the composer, including while a new thread or an existing
        // conversation is still being resumed by the provider.
        isTurnRunning = true
        if !isNewThread,
           let threadID = originThreadID,
           let optimisticUserItem,
           selectedThreadID == threadID {
            pendingUserItemByThreadID[threadID] = optimisticUserItem
            if !timeline.contains(where: { $0.id == optimisticUserItem.id }) {
                appendTimeline(optimisticUserItem)
            }
            updateThreadLifecycle(id: threadID, status: .running)
        }

        Task { [weak self] in
            guard let self else { return }
            var failureDraftKey = context.sourceDraftKey
            var targetThreadID = context.originThreadID
            var createdThread = false
            // A steering request has no model field: it continues the task's
            // established model. A fresh turn uses the model captured at send
            // time, so changing the picker while the request is in flight
            // cannot misattribute the usage.
            var modelUsed = context.modelID ?? originThread?.model
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
                    modelUsed = context.modelID ?? thread.model
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
                    // Steering has no model field, so an override selected
                    // while a turn is active applies to the next fresh turn.
                    modelUsed = originThread?.model ?? context.modelID
                    try await runtime.steer(threadID: threadID, inputs: context.inputs)
                    recordModelUsageIfAvailable(modelUsed)
                    guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                    if let pendingSteeringMessageID = context.pendingSteeringMessageID {
                        markPendingSteeringMessageQueued(
                            id: pendingSteeringMessageID,
                            for: threadID
                        )
                    }
                } else {
                    if !createdThread, resumedThreadID != threadID {
                        let loaded = try await loadInitialHistory(
                            for: threadID,
                            runtime: runtime,
                            resumeUnpaginated: true
                        )
                        guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                        modelUsed = context.modelID
                            ?? loaded.conversation.thread.model
                            ?? modelUsed
                        if selectedThreadID == threadID,
                           navigationRevision == context.navigationRevision {
                            replaceTimeline(
                                loaded.visibleItems,
                                authoritativeFor: loaded.conversation.thread.id
                            )
                            installEarlierHistory(from: loaded)
                        }
                        updateThread(
                            loaded.conversation.thread,
                            preservePositionIfPresent: true
                        )
                    }

                    if selectedThreadID == threadID,
                       (createdThread || navigationRevision == context.navigationRevision) {
                        if let optimisticUserItem = context.optimisticUserItem {
                            pendingUserItemByThreadID[threadID] = optimisticUserItem
                            if !timeline.contains(where: { $0.id == optimisticUserItem.id }) {
                                appendTimeline(optimisticUserItem)
                            }
                        }
                        isTurnRunning = true
                    }
                    updateThreadLifecycle(id: threadID, status: .running)
                    try await runtime.startTurn(
                        StartTurnRequest(
                            threadID: threadID,
                            inputs: context.inputs,
                            model: modelUsed,
                            cwd: context.cwd,
                            reasoningEffort: context.reasoningEffort,
                            sandboxMode: context.sandboxMode,
                            approvalPolicy: context.approvalPolicy
                        )
                    )
                    recordModelUsageIfAvailable(modelUsed)
                    guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                }
            } catch {
                guard accountEpoch == context.accountEpoch, !Task.isCancelled else { return }
                // Existing tasks paint their user turn before the provider
                // resumes history or accepts `turn/start`. If either of those
                // pre-acceptance steps fails, the draft is restored below but
                // the presentation row must not remain as if the provider
                // received it. The helper is fenced by the exact pending item
                // identity (and any authoritative turn-start notification),
                // so a late provider event cannot erase the real user item.
                if !context.isNewThread {
                    removePendingOptimisticUserItem(
                        context.optimisticUserItem,
                        for: targetThreadID ?? context.originThreadID
                    )
                }
                if let pendingSteeringMessageID = context.pendingSteeringMessageID,
                   let steeringThreadID = targetThreadID ?? context.originThreadID {
                    removePendingSteeringMessage(
                        id: pendingSteeringMessageID,
                        for: steeringThreadID
                    )
                }
                if context.isNewThread, !createdThread {
                    restoreFailedNewTaskSend(context)
                } else {
                    restoreFailedSend(context.draftText, for: failureDraftKey)
                    restoreFailedImages(context.images, for: failureDraftKey)
                }
                if let authenticationRecovery = authenticationRecovery(for: error) {
                    // The runtime also broadcasts this provider-wide, but the
                    // typed request error lets this exact window settle without
                    // racing a generic failure row or modal against the attached
                    // sign-in surface.
                    requireAuthenticationRecovery(authenticationRecovery)
                    if !context.wasTurnRunning, let targetThreadID {
                        mutateThread(id: targetThreadID) { $0.status = .idle }
                    }
                    if !context.wasTurnRunning,
                       (selectedThreadID == targetThreadID
                        || (targetThreadID == nil
                            && navigationRevision == context.navigationRevision)) {
                        isTurnRunning = false
                    }
                    return
                }
                let failure = context.wasTurnRunning
                    ? (
                        title: "Could not queue steering message",
                        detail: "The active task is still running. \(error.localizedDescription)"
                    )
                    : sendFailureMessage(for: error)
                notice = failure
                if !context.wasTurnRunning, let targetThreadID {
                    mutateThread(id: targetThreadID) { $0.status = .idle }
                }
                if !context.wasTurnRunning,
                   (selectedThreadID == targetThreadID
                    || (targetThreadID == nil && navigationRevision == context.navigationRevision)) {
                    isTurnRunning = false
                    appendTimeline(
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
        return true
    }

    private func contextOptimisticUserItem(
        text: String,
        images: [ComposerImageDraft],
        wasTurnRunning: Bool
    ) -> TimelineItem? {
        guard !wasTurnRunning else { return nil }
        return TimelineItem(
            id: "optimistic:\(UUID().uuidString)",
            kind: .userMessage,
            title: nil,
            body: text,
            status: .completed,
            timestamp: .now,
            detail: nil,
            attachments: images.map(\.timelineAttachment)
        )
    }

    /// Remove one user-owned optimistic row after a send fails before the
    /// provider accepts its turn. Matching the exact item ID matters: two
    /// consecutive prompts may have identical text, and an authoritative
    /// provider item can already have replaced the optimistic row by the
    /// time a request reports an error.
    private func removePendingOptimisticUserItem(
        _ item: TimelineItem?,
        for threadID: String?
    ) {
        guard let item,
              let threadID,
              pendingUserItemByThreadID[threadID]?.id == item.id
        else { return }

        // A turn-start event is the provider's acceptance boundary. Keep the
        // optimistic row when that event raced with a request failure; the
        // reducer will replace it with an authoritative item when available.
        guard activeTurnIDsByThreadID[threadID] == nil else { return }

        pendingUserItemByThreadID.removeValue(forKey: threadID)

        // The selected task owns the visible timeline. A send can fail after
        // the user navigates elsewhere, in which case only the pending map
        // needs clearing; the other task's visible rows must remain untouched.
        if selectedThreadID == threadID,
           let index = timeline.firstIndex(where: { $0.id == item.id }) {
            var visibleItems = timeline
            visibleItems.remove(at: index)
            transcriptSnapshot.replaceAll(with: visibleItems)
        }

        // A turn-start notification may have inserted the pending item into
        // the conversation projection before the request failed. Remove only
        // this exact optimistic identity; authoritative items use provider
        // IDs and are therefore preserved.
        for index in loadedConversationTurns.indices {
            loadedConversationTurns[index].items.removeAll { $0.id == item.id }
        }
    }

    private func enqueuePendingSteeringMessage(_ message: PendingSteeringMessage) {
        pendingSteeringMessagesByThreadID[message.threadID, default: []].append(message)
    }

    private func markPendingSteeringMessageQueued(id: UUID, for threadID: String) {
        guard var messages = pendingSteeringMessagesByThreadID[threadID],
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = .queued
        pendingSteeringMessagesByThreadID[threadID] = messages
    }

    private func removePendingSteeringMessage(id: UUID, for threadID: String) {
        guard var messages = pendingSteeringMessagesByThreadID[threadID] else { return }
        messages.removeAll { $0.id == id }
        if messages.isEmpty {
            pendingSteeringMessagesByThreadID.removeValue(forKey: threadID)
        } else {
            pendingSteeringMessagesByThreadID[threadID] = messages
        }
    }

    /// Reconciles one app-owned queue row with the provider's durable user
    /// item. FIFO matching matters when the same short correction is sent
    /// twice; attachment count disambiguates image-only follow-ups without
    /// retaining image bytes in the presentation queue.
    @discardableResult
    private func consumePendingSteeringMessage(
        matching item: TimelineItem,
        for threadID: String
    ) -> Bool {
        guard item.kind == .userMessage,
              var messages = pendingSteeringMessagesByThreadID[threadID],
              let index = messages.firstIndex(where: {
                  $0.text == item.body && $0.attachmentCount == item.attachments.count
              }) else { return false }
        messages.remove(at: index)
        if messages.isEmpty {
            pendingSteeringMessagesByThreadID.removeValue(forKey: threadID)
        } else {
            pendingSteeringMessagesByThreadID[threadID] = messages
        }
        return true
    }

    private func settlePendingSteeringMessages(for threadID: String) {
        pendingSteeringMessagesByThreadID.removeValue(forKey: threadID)
    }

    func interrupt() {
        guard canRunAgent, let id = selectedThreadID, let runtime else { return }
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.interrupt(threadID: id)
            } catch {
                guard accountEpoch == epoch else { return }
                if !requireAuthenticationRecovery(for: error) {
                    notice = ("Could not stop the task", error.localizedDescription)
                }
            }
        }
    }

    func startReview() {
        guard let runtime, let thread = selectedThread else { return }
        guard canRunAgent else { return }
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
        updateThreadLifecycle(id: threadID, status: .running)
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
                updateThreadLifecycle(id: threadID, status: .running)
                if selectedThreadID == threadID, navigationRevision == revision {
                    isTurnRunning = true
                }
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                if startingReviewThreadID == threadID { startingReviewThreadID = nil }
                if reviewingThreadID == threadID { reviewingThreadID = nil }
                if threadIndex(for: threadID).map({ threads[$0].status }) == .running {
                    mutateThread(id: threadID) { $0.status = originalStatus }
                }
                if selectedThreadID == threadID {
                    isTurnRunning = originalStatus.isBusy
                }
                if requireAuthenticationRecovery(for: error) { return }
                let detail: String
                if case let AgentRuntimeError.requestFailed(_, message) = error,
                   message.localizedCaseInsensitiveContains("active writer") {
                    detail = "This task is actively open in another \(runtimeDisplayName) window. Let that work finish, then try the review again."
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
        if sideChatInteraction == interaction {
            respondToSideChatInteraction(response)
            return
        }
        guard canRespond(to: interaction),
              let runtime,
              !respondingInteractionIDs.contains(interaction.id) else { return }
        respondingInteractionIDs.insert(interaction.id)
        let epoch = accountEpoch
        let interactionGeneration = recoveryInteractionGeneration
        Task { [weak self] in
            guard let self else { return }
            defer { respondingInteractionIDs.remove(interaction.id) }
            do {
                try await runtime.respond(to: interaction.id, with: response)
                guard accountEpoch == epoch,
                      recoveryInteractionGeneration == interactionGeneration else { return }
                pendingUserInteractions.removeAll { $0.id == interaction.id }
                removeInteractionDraft(for: interaction.id)
                reconcileThreadStatusAfterInteraction(for: interaction.threadID)
            } catch {
                guard accountEpoch == epoch else { return }
                if !requireAuthenticationRecovery(for: error) {
                    notice = ("Response failed", error.localizedDescription)
                }
            }
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
        if sideChatInteraction == interaction {
            interruptSideChat()
            return
        }
        guard let threadID = interaction.threadID,
              interaction.threadID == selectedThreadID,
              canRunAgent,
              let runtime else { return }
        let epoch = accountEpoch
        Task { [weak self] in
            do {
                try await runtime.interrupt(threadID: threadID)
            } catch {
                guard let self, accountEpoch == epoch else { return }
                if !requireAuthenticationRecovery(for: error) {
                    notice = ("Could not stop the task", error.localizedDescription)
                }
            }
        }
    }

    func togglePin(_ id: String) {
        guard id != Self.welcomeThread.id else { return }
        pinnedThreadStore.toggle(id)
    }

    /// Starts the native "edit last message" operation. The first use is
    /// deliberately confirmation-gated because provider history and project
    /// files have different undo semantics; later uses stay lightweight.
    func beginEditLatestUserMessage(messageID: String, window: NSWindow?) {
        guard latestEditableUserMessage?.message.id == messageID else { return }
        if preferences.bool(
            forKey: preferenceKey(PreferenceKey.acknowledgedHistoryEditWarning)
        ) {
            editLatestUserMessage(expectedMessageID: messageID)
            return
        }

        guard let window else {
            notice = (
                "Could not show the edit warning",
                "Try again after the task window is fully visible. Your message and draft were not changed."
            )
            return
        }

        let epoch = accountEpoch
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Edit your last message?"
        alert.informativeText = "This removes that message and everything after it from the task's conversation history. Changes already made to files in your project are not reverted."
        alert.addButton(withTitle: "Edit Message")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                guard let self, accountEpoch == epoch else { return }
                preferences.set(
                    true,
                    forKey: preferenceKey(PreferenceKey.acknowledgedHistoryEditWarning)
                )
                editLatestUserMessage(expectedMessageID: messageID)
            }
        }
    }

    /// Retries the latest failed turn without asking the user to reconstruct
    /// or duplicate its prompt. The provider suffix is removed first, then the
    /// original text and attachments are sent exactly once through the normal
    /// composer path. If reversion cannot be confirmed, the message remains in
    /// the composer and the existing safety lock prevents an ambiguous resend.
    func beginRetryLatestFailedResponse(messageID: String, window: NSWindow?) {
        guard let candidate = failedLatestUserMessage,
              candidate.message.id == messageID else { return }
        if preferences.bool(
            forKey: preferenceKey(PreferenceKey.acknowledgedHistoryEditWarning)
        ) {
            retryLatestFailedResponse(messageID: messageID)
            return
        }
        guard let window else {
            notice = (
                "Could not show the retry warning",
                "Try again after the task window is fully visible. The failed response was not retried."
            )
            return
        }
        let epoch = accountEpoch
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Retry this message?"
        alert.informativeText = "This removes the failed turn from conversation history and sends the message again. Changes already made to files in your project are not reverted and may be repeated."
        alert.addButton(withTitle: "Retry Message")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                guard let self, accountEpoch == epoch else { return }
                preferences.set(
                    true,
                    forKey: preferenceKey(PreferenceKey.acknowledgedHistoryEditWarning)
                )
                retryLatestFailedResponse(messageID: messageID)
            }
        }
    }

    func retryLatestFailedResponse(messageID: String) {
        guard let candidate = failedLatestUserMessage,
              candidate.message.id == messageID else { return }
        editLatestUserMessage(expectedMessageID: messageID, sendAfterRevert: true)
    }

    /// Executes the already-confirmed native history operation. Kept internal
    /// so model tests can exercise the provider boundary without presenting a
    /// modal sheet.
    func editLatestUserMessage(
        expectedMessageID: String? = nil,
        sendAfterRevert: Bool = false
    ) {
        guard let candidate = latestEditableUserMessage,
              expectedMessageID == nil || candidate.message.id == expectedMessageID,
              let threadID = selectedThreadID,
              let runtime else { return }

        // The provider projection supplies the exact text body. Image-only
        // turns are represented by an empty body plus attachments, while a
        // user who literally typed "[Image attachment]" keeps that text.
        let originalText = candidate.message.body
        let originalImages = Self.composerImages(from: candidate.message.attachments)
        let epoch = accountEpoch
        let revision = navigationRevision
        latestMessageEditGeneration &+= 1
        let editGeneration = latestMessageEditGeneration
        latestMessageEditThreadID = threadID
        latestMessageEditRequiresReloadThreadID = nil
        isPreparingLatestMessageEdit = true
        isPreparingFailedResponseRetry = sendAfterRevert

        Task { [weak self] in
            guard let self else { return }
            var shouldFinishEdit = true
            defer {
                if shouldFinishEdit {
                    finishLatestMessageEdit(generation: editGeneration)
                }
            }
            do {
                let result = try await runtime.revertThread(
                    id: threadID,
                    beforeTurnID: candidate.turn.id
                )
                guard accountEpoch == epoch, !Task.isCancelled else { return }

                updateThread(result.thread)
                // The native revert is itself a writer operation and leaves
                // this task's app-server session attached. Mark ownership so
                // the corrected send does not rehydrate the now-removed turn
                // from a stale pre-revert read page.
                resumedThreadID = threadID
                guard selectedThreadID == threadID,
                      navigationRevision == revision
                else {
                    // The provider operation already succeeded. Preserve the
                    // editable message as this task's draft even if the user
                    // navigated away while the request was in flight. Keep
                    // the original task locked until its authoritative reopen
                    // confirms the post-revert history; otherwise a delayed
                    // callback could unlock a task whose visible transcript is
                    // still from before the destructive operation.
                    restoreFailedSend(originalText, for: threadID)
                    restoreFailedImages(originalImages, for: threadID)
                    if selectedThreadID == threadID {
                        let reconciled = await reconcileHistoryAfterUncertainEdit(
                            threadID: threadID,
                            epoch: epoch,
                            runtime: runtime
                        )
                        if !reconciled, accountEpoch == epoch, !Task.isCancelled {
                            latestMessageEditRequiresReloadThreadID = threadID
                            shouldFinishEdit = false
                        }
                    } else {
                        latestMessageEditRequiresReloadThreadID = threadID
                        shouldFinishEdit = false
                    }
                    return
                }

                guard let currentTurnIndex = loadedConversationTurns.firstIndex(where: {
                    $0.id == candidate.turn.id
                }) else {
                    // A native `thread/reverted` notification can start an
                    // authoritative refresh before the request response arrives.
                    // Preserve the input and keep the edit locked until that
                    // refresh (or a replacement read) has reconciled the view.
                    restoreFailedSend(originalText, for: threadID)
                    restoreFailedImages(originalImages, for: threadID)
                    let reconciled = await reconcileHistoryAfterUncertainEdit(
                        threadID: threadID,
                        epoch: epoch,
                        runtime: runtime
                    )
                    if !reconciled, accountEpoch == epoch, !Task.isCancelled {
                        latestMessageEditRequiresReloadThreadID = threadID
                        shouldFinishEdit = false
                    }
                    return
                }

                let revertedItemIDs = Set(candidate.turn.items.map(\.id))
                let cutIndex = timeline.firstIndex(where: { revertedItemIDs.contains($0.id) })
                    ?? timeline.firstIndex(where: { $0.id == candidate.message.id })
                if let cutIndex {
                    replaceTimeline(
                        Array(timeline[..<cutIndex]),
                        authoritativeFor: threadID
                    )
                }
                loadedConversationTurns.removeSubrange(currentTurnIndex...)

                // The composer remains responsive while the provider works.
                // Merge anything typed or pasted during that interval instead
                // of silently replacing it with the restored message.
                if sendAfterRevert {
                    // `sendComposer` intentionally refuses writer work while
                    // the revert lock is held. Release only this confirmed
                    // generation, then dispatch through the ordinary send path
                    // so Retry receives the same validation and immediate
                    // waiting feedback as a manual submission.
                    finishLatestMessageEdit(generation: editGeneration)
                    shouldFinishEdit = false
                    let laterDraft = composerText
                    let laterImages = composerImages
                    composerText = originalText
                    composerImages = originalImages
                    let accepted = submitComposer()
                    if accepted {
                        composerText = laterDraft
                        composerImages = laterImages
                        saveCurrentDraftNow()
                        saveCurrentImageDraftNow()
                    } else {
                        let mergedText = laterDraft.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            ? originalText
                            : (originalText.isEmpty
                                ? laterDraft
                                : "\(originalText)\n\n\(laterDraft)")
                        composerText = mergedText
                        composerImages = originalImages + laterImages.filter { image in
                            !originalImages.contains(where: { $0.input == image.input })
                        }
                        saveCurrentDraftNow()
                        saveCurrentImageDraftNow()
                        notice = (
                            "Could not retry this message",
                            "The task history was reverted, but the provider was not ready to accept the retry. Your message and later draft are back in the composer."
                        )
                    }
                } else {
                    restoreFailedSend(originalText, for: threadID)
                    restoreFailedImages(originalImages, for: threadID)
                }
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                let operationError = error
                if requireAuthenticationRecovery(for: operationError) {
                    return
                }
                let compatibilityFailure = Self.isHistoryRevertCompatibilityFailure(operationError)
                if compatibilityFailure {
                    downgradeRuntimeCapability(.threadHistoryRevert)
                    notice = (
                        "Message editing is unavailable",
                        "This Codex version does not support native history editing. The conversation and your current draft were not changed."
                    )
                    return
                }
                // A timeout or lost response does not prove the server left
                // history untouched. Preserve the input first, then reload the
                // provider's authoritative tail before allowing another send.
                restoreFailedSend(originalText, for: threadID)
                restoreFailedImages(originalImages, for: threadID)
                let reconciled = if selectedThreadID == threadID {
                    await reconcileHistoryAfterUncertainEdit(
                        threadID: threadID,
                        epoch: epoch,
                        runtime: runtime
                    )
                } else {
                    false
                }
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                if !reconciled {
                    latestMessageEditRequiresReloadThreadID = threadID
                    shouldFinishEdit = false
                }
                notice = reconciled
                    ? (
                        "Could not confirm the edit",
                        "Onyx reloaded the task and preserved the original message in the composer. \(operationError.localizedDescription)"
                    )
                    : (
                        "Could not confirm the edit",
                        "The provider may have changed the conversation. The original message is preserved as this task's draft; reopen the task to confirm its history. \(operationError.localizedDescription)"
                    )
            }
        }
    }

    private func finishLatestMessageEdit(generation: UInt64) {
        guard latestMessageEditGeneration == generation else { return }
        isPreparingLatestMessageEdit = false
        isPreparingFailedResponseRetry = false
        latestMessageEditThreadID = nil
        latestMessageEditRequiresReloadThreadID = nil
    }

    private func invalidateLatestMessageEdit() {
        latestMessageEditGeneration &+= 1
        isPreparingLatestMessageEdit = false
        isPreparingFailedResponseRetry = false
        latestMessageEditThreadID = nil
        latestMessageEditRequiresReloadThreadID = nil
    }

    private func resolveLatestMessageEditAfterAuthoritativeReload(threadID: String) {
        guard latestMessageEditRequiresReloadThreadID == threadID,
              latestMessageEditThreadID == threadID else { return }
        finishLatestMessageEdit(generation: latestMessageEditGeneration)
    }

    private static func isHistoryRevertCompatibilityFailure(_ error: any Error) -> Bool {
        guard let runtimeError = error as? AgentRuntimeError else { return false }
        switch runtimeError {
        case .unsupported:
            return true
        case let .requestFailed(code, _):
            return code == -32_601 || code == -32_602
        default:
            return false
        }
    }

    private func downgradeRuntimeCapability(_ capability: RuntimeCapabilities) {
        downgradeRuntimeCapabilities(capability)
    }

    private func downgradeRuntimeCapabilities(_ unavailable: RuntimeCapabilities) {
        var newlyUnavailable = unavailable
        newlyUnavailable.subtract(downgradedRuntimeCapabilities)
        guard !newlyUnavailable.isEmpty else { return }
        downgradedRuntimeCapabilities.formUnion(newlyUnavailable)

        // Adaptive sessions intentionally keep execution capability on the
        // selected task/model rather than the provider-wide session. Mask all
        // three projections: checking only `session.capabilities` would leave
        // the edit/pagination control enabled on an already-open agent task.
        let projectedThreads = threads.map(applyingRuntimeCapabilityDowngrades)
        if projectedThreads != threads {
            threads = projectedThreads
        }
        if let session {
            self.session = applyingRuntimeCapabilityDowngrades(to: session)
        }
    }

    private func applyingRuntimeCapabilityDowngrades(
        to thread: RuntimeThread
    ) -> RuntimeThread {
        guard var capabilities = thread.taskCapabilities,
              !capabilities.intersection(downgradedRuntimeCapabilities).isEmpty else {
            return thread
        }
        capabilities.subtract(downgradedRuntimeCapabilities)
        var projected = thread
        projected.taskCapabilities = capabilities
        return projected
    }

    private func applyingRuntimeCapabilityDowngrades(
        to model: RuntimeModel
    ) -> RuntimeModel {
        guard var capabilities = model.taskCapabilities,
              !capabilities.intersection(downgradedRuntimeCapabilities).isEmpty else {
            return model
        }
        capabilities.subtract(downgradedRuntimeCapabilities)
        return RuntimeModel(
            id: model.id,
            displayName: model.displayName,
            description: model.description,
            isDefault: model.isDefault,
            defaultReasoningEffort: model.defaultReasoningEffort,
            reasoningEfforts: model.reasoningEfforts,
            inputModalities: model.inputModalities,
            serverAdvertisedRequestParameters: model.serverAdvertisedRequestParameters,
            supportedRequestParameters: model.supportedRequestParameters,
            serverAdvertisedCapabilities: model.serverAdvertisedCapabilities,
            capabilityEvidence: model.capabilityEvidence,
            executionMode: model.executionMode,
            taskCapabilities: capabilities
        )
    }

    private func applyingRuntimeCapabilityDowngrades(
        to session: RuntimeSession
    ) -> RuntimeSession {
        var capabilities = session.capabilities
        capabilities.subtract(downgradedRuntimeCapabilities)
        return RuntimeSession(
            runtime: session.runtime,
            displayName: session.displayName,
            accountLabel: session.accountLabel,
            planLabel: session.planLabel,
            auth: session.auth,
            availableLoginMethods: session.availableLoginMethods,
            availableModels: session.availableModels.map(applyingRuntimeCapabilityDowngrades),
            capabilities: capabilities
        )
    }

    private static func composerImages(
        from attachments: [TimelineAttachment]
    ) -> [ComposerImageDraft] {
        attachments.compactMap { attachment in
            let input: RuntimeTurnInput
            let byteCount: Int
            switch attachment.source {
            case let .localFilePath(path):
                input = .localImagePath(path)
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                byteCount = max(
                    0,
                    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                )
            case let .dataURL(value):
                input = .imageURL(value)
                if let comma = value.firstIndex(of: ",") {
                    // This is display/accounting metadata only. Preserve the
                    // exact provider-normalized data URL without allocating a
                    // second decoded image on the main actor.
                    byteCount = max(0, value.distance(from: comma, to: value.endIndex) * 3 / 4)
                } else {
                    byteCount = 0
                }
            case let .remoteURL(url):
                input = .imageURL(url.absoluteString)
                byteCount = 0
            }
            return ComposerImageDraft(
                input: input,
                displayName: attachment.accessibilityLabel,
                byteCount: byteCount
            )
        }
    }

    func beginRename(_ id: String, window: NSWindow?) {
        guard canRunAgent,
              let thread = threads.first(where: { $0.id == id }),
              id != Self.welcomeThread.id else { return }
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
        guard canRunAgent,
              !isShowingArchivedThreads,
              id != Self.welcomeThread.id,
              let runtime else { return }
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
                if !requireAuthenticationRecovery(for: error) {
                    notice = ("Could not archive task", error.localizedDescription)
                }
            }
        }
    }

    func restore(_ id: String) {
        guard canRunAgent, isShowingArchivedThreads, let runtime else { return }
        threadListTask?.cancel()
        navigationRevision += 1
        let navigationAtStart = navigationRevision
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.unarchiveThread(id: id)
                guard accountEpoch == epoch,
                      navigationRevision == navigationAtStart,
                      !Task.isCancelled else { return }
                threadListScope = .active
                hasAuthoritativeThreadListForCurrentScope = false
                threads = [Self.welcomeThread]
                selectedThreadID = nil
                resetEarlierHistory()
                replaceTimeline([])
                isTurnRunning = false
                isLoadingThread = false
                isLoadingThreadList = true

                let liveThreads = try await fetchThreads(in: .active)
                guard accountEpoch == epoch,
                      navigationRevision == navigationAtStart,
                      !Task.isCancelled else { return }
                applyThreadList(liveThreads, scope: .active, preferredSelection: id)
            } catch {
                guard accountEpoch == epoch,
                      navigationRevision == navigationAtStart,
                      !Task.isCancelled else { return }
                isLoadingThreadList = false
                if !requireAuthenticationRecovery(for: error) {
                    notice = ("Could not restore task", error.localizedDescription)
                }
            }
        }
    }

    func fork(_ id: String) {
        guard canRunAgent,
              !isShowingArchivedThreads, supports(.threadForking), let runtime,
              let source = threads.first(where: { $0.id == id }) else { return }
        guard canForkThread(source) else {
            notice = ("Task is still running", "Stop or finish the current turn before creating a fork.")
            return
        }

        let epoch = accountEpoch
        let navigationAtStart = navigationRevision
        Task { [weak self] in
            guard let self else { return }
            do {
                let forked = try await runtime.forkThread(id: id)
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                guard navigationRevision == navigationAtStart else {
                    // A newer task click can accept the completed fork into
                    // the still-visible active list, but a scope change owns
                    // the whole projection. Never relabel an archived list as
                    // active or insert an active fork among archived rows.
                    if threadListScope == .active {
                        updateThread(forked)
                    }
                    return
                }
                threadListScope = .active
                updateThread(forked)
                selectedThreadID = nil
                selectThread(forked.id)
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                if !requireAuthenticationRecovery(for: error) {
                    notice = ("Could not fork task", error.localizedDescription)
                }
            }
        }
    }

    func compact(_ id: String) {
        guard canRunAgent,
              !isShowingArchivedThreads, supports(.threadCompaction), let runtime,
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
                mutateThread(id: id) { $0.status = .running }
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                if !requireAuthenticationRecovery(for: error) {
                    notice = ("Could not compact task", error.localizedDescription)
                }
            }
        }
    }

    func beginDelete(_ id: String, window: NSWindow?) {
        guard canRunAgent,
              supports(.threadDeletion), id != Self.welcomeThread.id,
              let thread = threads.first(where: { $0.id == id }) else { return }
        guard canDeleteThread(thread) else {
            notice = (
                "Task is still active",
                isPreparingLatestMessageEdit(for: id)
                    ? "Wait for message editing to finish before deleting this task."
                    : "Finish or stop the code review before deleting this task."
            )
            return
        }
        let epoch = accountEpoch
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this task permanently?"
        alert.informativeText = "This removes the task history and any descendant tasks. It cannot be undone. Project files are not deleted."
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

    /// Enters the provider-wide recovery boundary without treating it as an
    /// account change. Durable task state stays mounted, while every request
    /// ID that existed before the new login is quarantined from future writes.
    private func requireAuthenticationRecovery(_ recovery: RuntimeAuthenticationRecovery) {
        if authenticationRecovery == nil {
            authenticationRecoveryAccountIdentity = mountedAccountIdentity
                ?? session.flatMap { AccountIdentity($0.auth) }
        }
        recoveryInteractionGeneration &+= 1
        authenticationRecovery = recovery
        recoveryQuarantinedInteractionIDs.formUnion(pendingUserInteractions.map(\.id))
        if let sideChatInteraction {
            recoveryQuarantinedInteractionIDs.insert(sideChatInteraction.id)
        }
        isTurnRunning = false
        isSideChatTurnRunning = false
    }

    @discardableResult
    private func requireAuthenticationRecovery(for error: any Error) -> Bool {
        guard let recovery = authenticationRecovery(for: error) else { return false }
        requireAuthenticationRecovery(recovery)
        return true
    }

    /// A successful account refresh proves only that credentials work again;
    /// it does not prove how the interrupted task settled. Resume the selected
    /// task once so its failed/running state, transcript tail, and pending
    /// interaction set become authoritative before Retry or another write is
    /// offered. This deliberately paints over the existing snapshot instead of
    /// blanking it behind a loading state.
    private func reconcileSelectedThreadAfterAuthenticationRecovery() {
        guard authenticationRecovery == nil,
              let threadID = selectedThreadID,
              threadID != Self.welcomeThread.id,
              let runtime else { return }

        // Snapshot only requests that crossed the recovery boundary. A provider
        // may reissue one of those request IDs while the authoritative resume is
        // still in flight; its event removes the ID from the quarantine, which
        // must make the replacement survive the older resume completion.
        let quarantinedInteractionIDsAtStart = recoveryQuarantinedInteractionIDs
        loadTask?.cancel()
        resetEarlierHistory()
        let epoch = accountEpoch
        let revision = navigationRevision
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loadInitialHistory(
                    for: threadID,
                    runtime: runtime,
                    resumeUnpaginated: true
                )
                guard accountEpoch == epoch,
                      navigationRevision == revision,
                      selectedThreadID == threadID,
                      authenticationRecovery == nil,
                      !Task.isCancelled else { return }

                replaceTimeline(
                    loaded.visibleItems,
                    authoritativeFor: loaded.conversation.thread.id
                )
                installEarlierHistory(from: loaded)
                updateThread(
                    loaded.conversation.thread,
                    preservePositionIfPresent: true
                )
                let status = loaded.conversation.thread.status
                isTurnRunning = status.isBusy || isReviewActive(for: threadID)
                if !status.isBusy {
                    activeTurnIDsByThreadID.removeValue(forKey: threadID)
                    pendingUserItemByThreadID.removeValue(forKey: threadID)
                    settlePendingSteeringMessages(for: threadID)
                    clearReviewState(for: threadID)
                    let stillStaleInteractionIDs = quarantinedInteractionIDsAtStart
                        .intersection(recoveryQuarantinedInteractionIDs)
                    removeUserInteractions(
                        for: threadID,
                        limitedTo: stillStaleInteractionIDs
                    )
                    reconcileThreadStatusAfterInteraction(for: threadID)
                }
                resolveLatestMessageEditAfterAuthoritativeReload(threadID: threadID)
            } catch {
                guard accountEpoch == epoch,
                      navigationRevision == revision,
                      selectedThreadID == threadID,
                      !Task.isCancelled else { return }
                if requireAuthenticationRecovery(for: error) { return }
                notice = (
                    "Task refresh needed",
                    "You are signed in again, but Onyx could not refresh this task yet. Reopen it to confirm its latest status."
                )
            }
        }
    }

    private func handle(_ event: AgentRuntimeEvent) {
        if shouldDiscardClosedSideChatEvent(event) {
            return
        }
        if handleSideChatEvent(event) {
            return
        }

        switch event {
        case let .connectionChanged(state):
            if isSideChatPresented {
                closeSideChat()
            }
            connectionState = state
            if case .failed = state {
                pendingUserInteractions.removeAll()
                respondingInteractionIDs.removeAll()
                recoveryQuarantinedInteractionIDs.removeAll()
                removeAllInteractionDrafts()
                reviewingThreadID = nil
                startingReviewThreadID = nil
                isTurnRunning = false
                activeTurnIDsByThreadID.removeAll()
                pendingSteeringMessagesByThreadID.removeAll()
                downgradeLiveCollaborationAgents()
            } else if case .disconnected = state {
                pendingUserInteractions.removeAll()
                respondingInteractionIDs.removeAll()
                recoveryQuarantinedInteractionIDs.removeAll()
                removeAllInteractionDrafts()
                reviewingThreadID = nil
                startingReviewThreadID = nil
                isTurnRunning = false
                activeTurnIDsByThreadID.removeAll()
                pendingSteeringMessagesByThreadID.removeAll()
                downgradeLiveCollaborationAgents()
            }
        case let .runtimeCapabilitiesDowngraded(capabilities):
            downgradeRuntimeCapabilities(capabilities)
        case let .runtimeModelsUpdated(models):
            guard let session else { return }
            self.session = applyingRuntimeCapabilityDowngrades(to: RuntimeSession(
                runtime: session.runtime,
                displayName: session.displayName,
                accountLabel: session.accountLabel,
                planLabel: session.planLabel,
                auth: session.auth,
                availableLoginMethods: session.availableLoginMethods,
                availableModels: models,
                capabilities: session.capabilities
            ))
            if selectedModelID == nil || !models.contains(where: { $0.id == selectedModelID }) {
                selectedModelID = models.first(where: \.isDefault)?.id ?? models.first?.id
            }
            validateSelectedReasoningEffort()
        case let .accountUpdated(updatedAuth):
            if isSideChatPresented, updatedAuth != authState {
                closeSideChat()
            }
            applyAuthProjection(updatedAuth)
            // A provider-authored signed-out projection is the destructive
            // account boundary even if an expired-login recovery was already
            // visible. Recovery preserves state only while account ownership
            // is unresolved; it must never weaken an authoritative logout.
            if !updatedAuth.canRun {
                closeAccountBoundary()
            }
            scheduleAccountRefresh(rejectSignedInSession: !updatedAuth.isSignedIn)
        case let .authenticationRecoveryRequired(recovery):
            requireAuthenticationRecovery(recovery)
            if let currentNotice = notice,
               CodexProjection.isAuthenticationRecoveryDiagnostic(currentNotice.detail) {
                // A stderr/request race can leave the raw diagnostic in the
                // alert binding just before the structured recovery event
                // arrives. Remove only that matching auth alert; unrelated
                // project or workspace notices remain available.
                notice = nil
            }
            // The transcript row and attached recovery surface carry this
            // state. Keep partially answered provider interactions intact and
            // avoid creating a duplicate modal. Do not clear an unrelated
            // notice that the user may still need to read.
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
                if authenticationRecovery != nil {
                    // Successful login is provider-wide. Every attached window
                    // in recovery must require one authoritative signed-in
                    // account read, even if another window owned the ceremony.
                    loginRecoveryPendingConfirmation = true
                }
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
                loginRecoveryPendingConfirmation = false
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
            mutateThread(id: threadID) { thread in
                thread.title = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? thread.preview.firstNonemptyLine
                    ?? "Untitled task"
            }
        case let .threadStatusChanged(threadID, status):
            guard authState.canRun, !isSigningOut else { return }
            updateThreadLifecycle(id: threadID, status: status)
            if !status.isBusy {
                settlePendingSteeringMessages(for: threadID)
            }
            if selectedThreadID == threadID {
                isTurnRunning = status.isBusy || isReviewActive(for: threadID)
            }
        case let .threadArchived(threadID):
            guard authState.canRun, !isSigningOut else { return }
            if sideChatParentThreadID == threadID {
                closeSideChat()
            }
            clearReviewState(for: threadID)
            activeTurnIDsByThreadID.removeValue(forKey: threadID)
            settlePendingSteeringMessages(for: threadID)
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
            if sideChatParentThreadID == threadID {
                closeSideChat()
            }
            clearReviewState(for: threadID)
            activeTurnIDsByThreadID.removeValue(forKey: threadID)
            settlePendingSteeringMessages(for: threadID)
            removeUserInteractions(for: threadID)
            removeThreadFromCurrentList(threadID)
            pinnedThreadStore.remove(threadID)
            plansByThreadID.removeValue(forKey: threadID)
            updateDraftCache("", for: threadID)
            composerImageDrafts.removeValue(forKey: threadID)
            taskModelOverrides.removeValue(forKey: threadID)
            taskModelDefaults.removeValue(forKey: threadID)
            persistComposerDraftCache(mode: .background)
            persistTaskModelSelections()
        case let .threadRefreshRequested(threadID):
            guard authState.canRun, !isSigningOut else { return }
            refreshThreadIfSelected(threadID)
        case let .itemStarted(threadID, item):
            guard authState.canRun, !isSigningOut else { return }
            consumePendingSteeringMessage(matching: item, for: threadID)
            guard selectedThreadID == threadID else { return }
            recordLiveItem(item.id, for: threadID)
            if item.kind == .userMessage,
               let optimisticIndex = timeline.lastIndex(where: { $0.id.hasPrefix("optimistic:") && $0.body == item.body }) {
                replaceTimelineRow(at: optimisticIndex, with: item)
                pendingUserItemByThreadID[threadID] = item
            } else if !timeline.contains(where: { $0.id == item.id }) {
                appendTimeline(item)
            }
            recordLoadedConversationItem(item, for: threadID)
            mergeCollaborationActivity(from: item)
        case let .itemDelta(threadID, itemID, delta):
            guard authState.canRun, !isSigningOut, selectedThreadID == threadID else { return }
            recordLiveItem(itemID, for: threadID)
            pendingDeltas[DeltaKey(threadID: threadID, itemID: itemID), default: ""] += delta
            scheduleDeltaFlush()
        case let .itemCompleted(threadID, item):
            guard authState.canRun, !isSigningOut else { return }
            consumePendingSteeringMessage(matching: item, for: threadID)
            guard selectedThreadID == threadID else { return }
            recordLiveItem(item.id, for: threadID)
            flushDeltas()
            if let index = timeline.firstIndex(where: { $0.id == item.id }) {
                replaceTimelineRow(at: index, with: item)
            } else {
                appendTimeline(item)
            }
            recordLoadedConversationItem(item, for: threadID)
            mergeCollaborationActivity(from: item)
        case let .turnStarted(threadID, turnID):
            guard authState.canRun, !isSigningOut else { return }
            let revision = advanceLiveTimelineRevision(for: threadID)
            livePlanRevisionByThreadID[threadID] = revision
            if activeTurnIDsByThreadID[threadID] != turnID {
                plansByThreadID.removeValue(forKey: threadID)
            }
            activeTurnIDsByThreadID[threadID] = turnID
            beginLoadedConversationTurn(threadID: threadID, turnID: turnID)
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
                replaceTimelineRow(at: index, with: item)
            } else {
                appendTimeline(item)
            }
        case let .turnCompleted(threadID, status):
            guard authState.canRun, !isSigningOut else { return }
            updateThreadLifecycle(id: threadID, status: status)
            if let turnID = activeTurnIDsByThreadID[threadID] {
                completeLoadedConversationTurn(
                    threadID: threadID,
                    turnID: turnID,
                    threadStatus: status
                )
            }
            activeTurnIDsByThreadID.removeValue(forKey: threadID)
            pendingUserItemByThreadID.removeValue(forKey: threadID)
            if status != .running {
                settlePendingSteeringMessages(for: threadID)
            }
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
            if authenticationRecovery == nil {
                // Re-emission after a successful resume is the provider's
                // explicit confirmation that this request is still pending.
                recoveryQuarantinedInteractionIDs.remove(interaction.id)
            } else {
                recoveryQuarantinedInteractionIDs.insert(interaction.id)
            }
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
            recoveryQuarantinedInteractionIDs.remove(requestID)
            removeInteractionDraft(for: requestID)
            reconcileThreadStatusAfterInteraction(for: threadID)
        case let .runtimeNotice(title, detail):
            // A few app-server versions report an expired ChatGPT session as
            // a generic runtime notice (and may include the complete 401
            // tracing envelope).  That is the same account-recovery state as
            // a typed request failure, not a developer diagnostic.  Route it
            // to the attached sign-in surface and discard any matching raw
            // alert that raced ahead of this event.
            if runtimeKind == .codex,
               CodexProjection.isAuthenticationRecoveryDiagnostic(detail) {
                requireAuthenticationRecovery(.signInExpired)
                if let currentNotice = notice,
                   CodexProjection.isAuthenticationRecoveryDiagnostic(currentNotice.detail) {
                    notice = nil
                }
            } else {
                notice = (title, detail)
            }
        }
    }

    /// Consumes events for the in-memory side-chat fork before the ordinary
    /// task event reducer sees them. This is the key isolation boundary: side
    /// items, plans, turns, and interactions never enter the durable task
    /// timeline or change a task's catalog status.
    @discardableResult
    private func handleSideChatEvent(_ event: AgentRuntimeEvent) -> Bool {
        guard isSideChatPresented,
              let sideThreadID = sideChatThreadID else { return false }

        switch event {
        case let .itemStarted(threadID, item) where threadID == sideThreadID:
            var item = item
            if let earlyDelta = sideChatPendingDeltas[item.id],
               !earlyDelta.isEmpty,
               !item.body.hasSuffix(earlyDelta) {
                // Provider notifications can cross the actor boundary in the
                // opposite order from their wire writes. Preserve text already
                // rendered from an early delta when the matching start arrives.
                item.body += earlyDelta
            }
            if item.kind == .userMessage,
               let optimisticIndex = sideChatTimeline.lastIndex(where: {
                   $0.id.hasPrefix("side-optimistic:") && $0.body == item.body
               }) {
                replaceSideChatTimelineRow(at: optimisticIndex, with: item)
            } else if let index = sideChatTimeline.firstIndex(where: { $0.id == item.id }) {
                replaceSideChatTimelineRow(at: index, with: item)
            } else {
                appendSideChatTimeline(item)
            }
            return true

        case let .itemDelta(threadID, itemID, delta) where threadID == sideThreadID:
            guard !delta.isEmpty else { return true }
            sideChatPendingDeltas[itemID, default: ""] += delta
            if let index = sideChatTimeline.firstIndex(where: { $0.id == itemID }) {
                mutateSideChatTimelineRows(IndexSet(integer: index)) { items in
                    items[index].body += delta
                    items[index].status = .running
                }
            } else {
                appendSideChatTimeline(
                    TimelineItem(
                        id: itemID,
                        kind: .assistantMessage,
                        title: nil,
                        body: delta,
                        status: .running,
                        timestamp: .now,
                        detail: nil
                    )
                )
            }
            return true

        case let .itemCompleted(threadID, item) where threadID == sideThreadID:
            sideChatPendingDeltas.removeValue(forKey: item.id)
            if item.kind == .userMessage,
               let optimisticIndex = sideChatTimeline.lastIndex(where: {
                   $0.id.hasPrefix("side-optimistic:") && $0.body == item.body
               }) {
                replaceSideChatTimelineRow(at: optimisticIndex, with: item)
            } else if let index = sideChatTimeline.firstIndex(where: { $0.id == item.id }) {
                replaceSideChatTimelineRow(at: index, with: item)
            } else {
                appendSideChatTimeline(item)
            }
            return true

        case let .turnStarted(threadID, _) where threadID == sideThreadID:
            isSideChatTurnRunning = true
            sideChatInteraction = nil
            isRespondingToSideChatInteraction = false
            return true

        case let .planUpdated(threadID, plan) where threadID == sideThreadID:
            let item = TimelineItem.planUpdate(plan)
            if let index = sideChatTimeline.firstIndex(where: { $0.id == item.id }) {
                replaceSideChatTimelineRow(at: index, with: item)
            } else {
                appendSideChatTimeline(item)
            }
            return true

        case let .turnCompleted(threadID, _) where threadID == sideThreadID:
            flushSideChatDeltas()
            isSideChatTurnRunning = false
            return true

        case let .userInteractionRequested(interaction)
            where interaction.threadID == sideThreadID:
            if authenticationRecovery == nil {
                recoveryQuarantinedInteractionIDs.remove(interaction.id)
            } else {
                recoveryQuarantinedInteractionIDs.insert(interaction.id)
            }
            if let existing = sideChatInteraction, existing != interaction {
                removeInteractionDraft(for: existing.id)
            }
            sideChatInteraction = interaction
            isSideChatTurnRunning = true
            return true

        case let .userInteractionResolved(requestID)
            where sideChatInteraction?.id == requestID:
            sideChatInteraction = nil
            isRespondingToSideChatInteraction = false
            recoveryQuarantinedInteractionIDs.remove(requestID)
            removeInteractionDraft(for: requestID)
            return true

        case let .threadDeleted(threadID) where threadID == sideThreadID:
            // Ephemeral threads should not normally emit a delete event, but
            // if a provider does, close only the local panel and leave the
            // parent task untouched.
            closeSideChat()
            return true

        default:
            return false
        }
    }

    private func flushSideChatDeltas() {
        sideChatPendingDeltas.removeAll()
    }

    private func rememberDiscardedSideChatThread(_ threadID: String) {
        discardedSideChatThreadIDs.insert(threadID)
    }

    private func shouldDiscardClosedSideChatEvent(_ event: AgentRuntimeEvent) -> Bool {
        let threadID: String? = switch event {
        case let .threadUpdated(thread): thread.id
        case let .threadNameChanged(threadID, _): threadID
        case let .threadStatusChanged(threadID, _): threadID
        case let .threadArchived(threadID): threadID
        case let .threadUnarchived(threadID): threadID
        case let .threadDeleted(threadID): threadID
        case let .threadRefreshRequested(threadID): threadID
        case let .itemStarted(threadID, _): threadID
        case let .itemDelta(threadID, _, _): threadID
        case let .itemCompleted(threadID, _): threadID
        case let .turnStarted(threadID, _): threadID
        case let .planUpdated(threadID, _): threadID
        case let .turnCompleted(threadID, _): threadID
        case let .userInteractionRequested(interaction): interaction.threadID
        case .connectionChanged,
             .runtimeCapabilitiesDowngraded,
             .runtimeModelsUpdated,
             .accountUpdated,
             .authenticationRecoveryRequired,
             .loginCompleted,
             .userInteractionResolved,
             .runtimeNotice:
            nil
        }
        guard let threadID else { return false }
        return discardedSideChatThreadIDs.contains(threadID)
    }

    private func updateThread(
        _ thread: RuntimeThread,
        preservePositionIfPresent: Bool = false
    ) {
        var thread = thread
        thread.isPinned = pinnedThreadIDs.contains(thread.id)
        if preservePositionIfPresent,
           let index = threadIndex(for: thread.id),
           threads.indices.contains(index) {
            // Reading a task refreshes descriptive metadata but is not new
            // activity. Keep the list snapshot's recency timestamp as the
            // ordering authority and its folder as the project-grouping
            // authority. Accepting either value from a navigation read could
            // move the row under the pointer; the next provider list refresh
            // remains responsible for genuine recency or project changes.
            thread.updatedAt = threads[index].updatedAt
            thread.cwd = threads[index].cwd
            if threads[index] != thread {
                threads[index] = thread
                threadIndexCacheRevision = threadListRevision
            }
        } else {
            upsertThreadInRecencyOrder(thread)
        }
        if selectedThreadID == thread.id {
            isTurnRunning = thread.status.isBusy || isReviewActive(for: thread.id)
            validateSelectedReasoningEffort()
        }
    }

    private func threadIndex(for id: String) -> Int? {
        if threadIndexCacheRevision != threadListRevision {
            var rebuilt: [String: Int] = [:]
            rebuilt.reserveCapacity(threads.count)
            for (index, thread) in threads.enumerated() {
                rebuilt[thread.id] = index
            }
            threadIndexByID = rebuilt
            threadIndexCacheRevision = threadListRevision
        }
        return threadIndexByID[id]
    }

    /// Mutates one row while preserving the id-to-index cache. This still
    /// publishes the user-visible lifecycle change immediately, but avoids a
    /// second catalog scan when SwiftUI asks for the selected task/sidebar.
    @discardableResult
    private func mutateThread(
        id: String,
        _ mutation: (inout RuntimeThread) -> Void
    ) -> RuntimeThread? {
        guard let index = threadIndex(for: id), threads.indices.contains(index) else { return nil }
        let previous = threads[index]
        var updated = previous
        mutation(&updated)
        guard updated != previous else { return previous }
        threads[index] = updated
        // `didSet` invalidates every derived cache conservatively. The row's
        // identity and position did not change, so this index remains exact.
        threadIndexCacheRevision = threadListRevision
        return updated
    }

    /// A lifecycle timestamp makes one task recent. Remove and binary-insert
    /// just that task instead of sorting the complete catalog on the main
    /// actor. Array movement is linear in the affected range; comparisons are
    /// logarithmic and there is only one `@Published` assignment.
    private func updateThreadLifecycle(
        id: String,
        status: RuntimeThreadStatus,
        updatedAt: Date = .now
    ) {
        guard let sourceIndex = threadIndex(for: id), threads.indices.contains(sourceIndex) else {
            return
        }
        var updated = threads[sourceIndex]
        updated.status = status
        updated.updatedAt = updatedAt
        var reordered = threads
        reordered.remove(at: sourceIndex)
        let destinationIndex = Self.recencyInsertionIndex(for: updated, in: reordered)
        reordered.insert(updated, at: destinationIndex)
        threads = reordered
        repairThreadIndexCache(
            from: min(sourceIndex, destinationIndex),
            through: max(sourceIndex, destinationIndex)
        )
    }

    private func upsertThreadInRecencyOrder(_ thread: RuntimeThread) {
        let sourceIndex = threadIndex(for: thread.id)
        var reordered = threads
        if let sourceIndex { reordered.remove(at: sourceIndex) }
        let destinationIndex = Self.recencyInsertionIndex(for: thread, in: reordered)
        reordered.insert(thread, at: destinationIndex)
        threads = reordered
        if let sourceIndex {
            repairThreadIndexCache(
                from: min(sourceIndex, destinationIndex),
                through: max(sourceIndex, destinationIndex)
            )
        } else {
            repairThreadIndexCache(from: destinationIndex, through: threads.count - 1)
        }
    }

    private static func recencyInsertionIndex(
        for thread: RuntimeThread,
        in sortedThreads: [RuntimeThread]
    ) -> Int {
        var lower = 0
        var upper = sortedThreads.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sortedThreads[middle].updatedAt > thread.updatedAt {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func repairThreadIndexCache(from lowerBound: Int, through upperBound: Int) {
        guard !threads.isEmpty else {
            threadIndexByID.removeAll(keepingCapacity: true)
            threadIndexCacheRevision = threadListRevision
            return
        }
        let lowerBound = max(0, lowerBound)
        let upperBound = min(threads.count - 1, upperBound)
        if lowerBound <= upperBound {
            for index in lowerBound...upperBound {
                threadIndexByID[threads[index].id] = index
            }
        }
        threadIndexCacheRevision = threadListRevision
    }

    private struct InitialHistoryLoad {
        let conversation: RuntimeConversation
        let visibleItems: [TimelineItem]
        let earlierSource: EarlierHistorySource?
        let chronologicalTurns: [RuntimeConversationTurn]
        let resumedThread: Bool
    }

    /// Loads only the useful tail when the provider has a native turn cursor.
    /// Other providers keep their existing read contract, but Onyx still
    /// bounds the first main-thread transcript projection and reveals the
    /// already-read prefix page by page.
    private func loadInitialHistory(
        for threadID: String,
        runtime: any AgentRuntime,
        resumeUnpaginated: Bool = false
    ) async throws -> InitialHistoryLoad {
        if supports(.threadHistoryPagination) {
            do {
                return try await loadPaginatedInitialHistory(
                    for: threadID,
                    runtime: runtime,
                    resuming: resumeUnpaginated
                )
            } catch {
                // Onyx can run a user-selected, older Codex binary. Only the
                // two JSON-RPC compatibility errors prove that its pagination
                // surface is unavailable; transport and malformed-data errors
                // must remain visible instead of silently rereading everything.
                guard Self.isHistoryPaginationCompatibilityFailure(error) else {
                    throw error
                }
            }
        }

        let conversation = if resumeUnpaginated {
            try await runtime.resumeThread(id: threadID)
        } else {
            try await runtime.readThread(id: threadID)
        }
        return Self.bufferedInitialHistory(
            conversation: conversation,
            resumedThread: resumeUnpaginated
        )
    }

    private func loadPaginatedInitialHistory(
        for threadID: String,
        runtime: any AgentRuntime,
        resuming: Bool
    ) async throws -> InitialHistoryLoad {
        let loaded = if resuming {
            try await runtime.resumeThread(
                id: threadID,
                initialHistoryPage: RuntimeInitialThreadHistoryPageRequest(
                    limit: Self.historyTurnPageSize,
                    direction: .descending,
                    itemDetail: .full
                )
            )
        } else {
            try await runtime.readThread(
                id: threadID,
                initialHistoryPage: RuntimeThreadHistoryPageRequest(
                    limit: Self.historyTurnPageSize,
                    direction: .descending,
                    itemDetail: .full
                )
            )
        }
        if let page = loaded.initialHistoryPage {
            let chronologicalTurns: [RuntimeConversationTurn] = switch page.direction {
            case .ascending: page.turns
            case .descending: Array(page.turns.reversed())
            }
            let pageItems = page.chronologicalItems
            let visibleStart = Self.bufferedHistoryPageStart(
                in: pageItems,
                before: pageItems.count
            )
            let earlierSource: EarlierHistorySource? = if visibleStart > 0 {
                .buffered(
                    items: pageItems,
                    visibleStartIndex: visibleStart,
                    nextProviderCursor: page.nextCursor
                )
            } else {
                page.nextCursor.map { .provider(cursor: $0) }
            }
            return InitialHistoryLoad(
                conversation: loaded.conversation,
                visibleItems: Array(pageItems.dropFirst(visibleStart)),
                earlierSource: earlierSource,
                chronologicalTurns: chronologicalTurns,
                resumedThread: resuming
            )
        }

        // A successful native operation with no initial page is still a
        // usable empty/metadata-only task. Do not turn it into an error by
        // immediately issuing a second full-history read that can fail.
        return InitialHistoryLoad(
            conversation: loaded.conversation,
            visibleItems: loaded.conversation.items,
            earlierSource: nil,
            chronologicalTurns: [],
            resumedThread: resuming
        )
    }

    private static func isHistoryPaginationCompatibilityFailure(_ error: any Error) -> Bool {
        guard let runtimeError = error as? AgentRuntimeError else { return false }
        switch runtimeError {
        case .unsupported:
            return true
        case let .requestFailed(code, _):
            return code == -32_601 || code == -32_602
        default:
            return false
        }
    }

    private static func bufferedInitialHistory(
        conversation: RuntimeConversation,
        resumedThread: Bool
    ) -> InitialHistoryLoad {
        let visibleStart = bufferedHistoryPageStart(
            in: conversation.items,
            before: conversation.items.count
        )
        let visibleItems = Array(conversation.items.dropFirst(visibleStart))
        let earlierSource: EarlierHistorySource? = visibleStart > 0
            ? .buffered(
                items: conversation.items,
                visibleStartIndex: visibleStart,
                nextProviderCursor: nil
            )
            : nil
        return InitialHistoryLoad(
            conversation: conversation,
            visibleItems: visibleItems,
            earlierSource: earlierSource,
            chronologicalTurns: conversation.turns,
            resumedThread: resumedThread
        )
    }

    /// A turn boundary is preferred, but a single pathological turn must not
    /// put thousands of tool events back on the first render. The item bound
    /// is therefore the hard limit and the turn count is the softer reading
    /// boundary.
    private static func bufferedHistoryPageStart(
        in items: [TimelineItem],
        before upperBound: Int
    ) -> Int {
        guard upperBound > 0 else { return 0 }
        let hardLowerBound = max(0, upperBound - bufferedHistoryPageItemLimit)
        var userTurnCount = 0
        var start = upperBound
        var index = upperBound - 1
        while index >= hardLowerBound {
            start = index
            if items[index].kind == .userMessage {
                userTurnCount += 1
                if userTurnCount >= historyTurnPageSize { break }
            }
            if index == 0 { break }
            index -= 1
        }
        return start
    }

    private func installEarlierHistory(from loaded: InitialHistoryLoad) {
        earlierHistorySource = loaded.earlierSource
        canLoadEarlierHistory = loaded.earlierSource != nil
        isLoadingEarlierHistory = false
        loadedConversationTurns = loaded.chronologicalTurns
        resumedThreadID = loaded.resumedThread ? loaded.conversation.thread.id : nil
    }

    private func resetEarlierHistory() {
        earlierHistoryTask?.cancel()
        earlierHistoryTask = nil
        earlierHistorySource = nil
        canLoadEarlierHistory = false
        isLoadingEarlierHistory = false
        loadedConversationTurns = []
        resumedThreadID = nil
    }

    private func beginLoadedConversationTurn(threadID: String, turnID: String) {
        guard selectedThreadID == threadID else { return }
        let initialItems = pendingUserItemByThreadID[threadID].map { [$0] } ?? []
        if let index = loadedConversationTurns.firstIndex(where: { $0.id == turnID }) {
            loadedConversationTurns[index].status = .inProgress
            for item in initialItems {
                upsert(item, inLoadedTurnAt: index)
            }
            return
        }
        loadedConversationTurns.append(
            RuntimeConversationTurn(
                id: turnID,
                items: initialItems,
                status: .inProgress,
                itemDetail: .full,
                startedAt: .now,
                completedAt: nil,
                durationMilliseconds: nil
            )
        )
    }

    private func recordLoadedConversationItem(_ item: TimelineItem, for threadID: String) {
        guard selectedThreadID == threadID,
              let turnID = activeTurnIDsByThreadID[threadID],
              let turnIndex = loadedConversationTurns.lastIndex(where: { $0.id == turnID })
        else { return }
        upsert(item, inLoadedTurnAt: turnIndex)
    }

    private func upsert(_ item: TimelineItem, inLoadedTurnAt turnIndex: Int) {
        guard loadedConversationTurns.indices.contains(turnIndex) else { return }
        if let itemIndex = loadedConversationTurns[turnIndex].items.firstIndex(where: {
            $0.id == item.id
                || ($0.id.hasPrefix("optimistic:")
                    && $0.kind == .userMessage
                    && item.kind == .userMessage
                    && $0.body == item.body)
        }) {
            loadedConversationTurns[turnIndex].items[itemIndex] = item
        } else {
            loadedConversationTurns[turnIndex].items.append(item)
        }
    }

    private func completeLoadedConversationTurn(
        threadID: String,
        turnID: String,
        threadStatus: RuntimeThreadStatus
    ) {
        guard selectedThreadID == threadID,
              let index = loadedConversationTurns.lastIndex(where: { $0.id == turnID })
        else { return }
        loadedConversationTurns[index].status = switch threadStatus {
        case .idle: .completed
        case .failed: .failed
        case .running, .waitingForInput, .waitingForApproval: .inProgress
        case .unknown: .unknown("unknown")
        }
        if loadedConversationTurns[index].status != .inProgress {
            let completion = Date.now
            loadedConversationTurns[index].completedAt = completion
            if let startedAt = loadedConversationTurns[index].startedAt {
                loadedConversationTurns[index].durationMilliseconds = max(
                    0,
                    Int(completion.timeIntervalSince(startedAt) * 1_000)
                )
            }
        }
    }

    func loadEarlierHistory() {
        guard !isLoadingEarlierHistory,
              let source = earlierHistorySource,
              let threadID = selectedThreadID,
              threadID != Self.welcomeThread.id else { return }

        isLoadingEarlierHistory = true
        let epoch = accountEpoch
        let revision = navigationRevision
        earlierHistoryTask?.cancel()
        earlierHistoryTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Give the loading affordance one render opportunity before a
                // buffered page is projected on the main actor.
                await Task.yield()
                let olderItems: [TimelineItem]
                let olderTurns: [RuntimeConversationTurn]
                let nextSource: EarlierHistorySource?

                switch source {
                case let .provider(cursor):
                    guard let runtime else {
                        throw AgentRuntimeError.unsupported("paginated thread history")
                    }
                    let page = try await runtime.listThreadHistory(
                        id: threadID,
                        page: RuntimeThreadHistoryPageRequest(
                            cursor: cursor,
                            limit: Self.historyTurnPageSize,
                            direction: .descending,
                            itemDetail: .full
                        )
                    )
                    let pageItems = page.chronologicalItems
                    let visibleStart = Self.bufferedHistoryPageStart(
                        in: pageItems,
                        before: pageItems.count
                    )
                    olderItems = Array(pageItems.dropFirst(visibleStart))
                    olderTurns = switch page.direction {
                    case .ascending: page.turns
                    case .descending: Array(page.turns.reversed())
                    }
                    if visibleStart > 0 {
                        nextSource = .buffered(
                            items: pageItems,
                            visibleStartIndex: visibleStart,
                            nextProviderCursor: page.nextCursor
                        )
                    } else {
                        nextSource = page.nextCursor.flatMap { nextCursor in
                            // A provider repeating an empty page/cursor would make
                            // the button an infinite no-op. Stop at no progress.
                            guard !olderItems.isEmpty || nextCursor != cursor else { return nil }
                            return .provider(cursor: nextCursor)
                        }
                    }

                case let .buffered(items, visibleStartIndex, nextProviderCursor):
                    let pageStart = Self.bufferedHistoryPageStart(
                        in: items,
                        before: visibleStartIndex
                    )
                    olderItems = Array(items[pageStart..<visibleStartIndex])
                    olderTurns = []
                    if pageStart > 0 {
                        nextSource = .buffered(
                            items: items,
                            visibleStartIndex: pageStart,
                            nextProviderCursor: nextProviderCursor
                        )
                    } else {
                        nextSource = nextProviderCursor.map { .provider(cursor: $0) }
                    }
                }

                guard accountEpoch == epoch,
                      navigationRevision == revision,
                      selectedThreadID == threadID,
                      !Task.isCancelled else { return }
                await prependTimeline(olderItems)
                if !olderTurns.isEmpty {
                    loadedConversationTurns.insert(contentsOf: olderTurns, at: 0)
                }
                earlierHistorySource = nextSource
                canLoadEarlierHistory = nextSource != nil
                isLoadingEarlierHistory = false
                earlierHistoryTask = nil
            } catch {
                guard accountEpoch == epoch,
                      navigationRevision == revision,
                      selectedThreadID == threadID,
                      !Task.isCancelled else { return }
                isLoadingEarlierHistory = false
                earlierHistoryTask = nil
                notice = ("Could not load earlier messages", error.localizedDescription)
            }
        }
    }

    private func replaceTimeline(_ items: [TimelineItem], authoritativeFor threadID: String? = nil) {
        transcriptSnapshot.replaceAll(with: items)
        if let threadID {
            plansByThreadID.removeValue(forKey: threadID)
        }
        collaborationAgentsByID.removeAll(keepingCapacity: true)
        for item in items {
            mergeCollaborationActivity(from: item, publish: false)
        }
        publishCollaborationAgents()
    }

    private func appendTimeline(_ item: TimelineItem) {
        transcriptSnapshot.append(item)
    }

    private func prependTimeline(_ items: [TimelineItem]) async {
        guard !items.isEmpty else { return }
        // Array's front insertion copies the complete loaded suffix. Prepare
        // that immutable snapshot away from the main actor, then publish it
        // with one constant-time copy-on-write assignment.
        while !Task.isCancelled {
            let base = transcriptSnapshot
            let prepared = await Task.detached(priority: .userInitiated) {
                base.prepending(contentsOf: items)
            }.value
            guard transcriptSnapshot.revision != base.revision else {
                transcriptSnapshot = prepared
                break
            }
        }
        for item in items {
            mergeCollaborationActivity(from: item, publish: false)
        }
        publishCollaborationAgents()
    }

    private func replaceTimelineRow(at index: Int, with item: TimelineItem) {
        transcriptSnapshot.replaceRow(at: index, with: item)
    }

    private func mutateTimelineRows(
        _ indices: IndexSet,
        mutation: (inout [TimelineItem]) -> Void
    ) {
        transcriptSnapshot.mutateRows(indices, mutation: mutation)
    }

    private func replaceSideChatTimeline(_ items: [TimelineItem]) {
        sideChatTranscriptSnapshot.replaceAll(with: items)
    }

    private func appendSideChatTimeline(_ item: TimelineItem) {
        sideChatTranscriptSnapshot.append(item)
    }

    private func replaceSideChatTimelineRow(at index: Int, with item: TimelineItem) {
        sideChatTranscriptSnapshot.replaceRow(at: index, with: item)
    }

    private func mutateSideChatTimelineRows(
        _ indices: IndexSet,
        mutation: (inout [TimelineItem]) -> Void
    ) {
        sideChatTranscriptSnapshot.mutateRows(indices, mutation: mutation)
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

        transcriptSnapshot.replaceAll(with: merged)
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
                if let destination = incoming.destination { existing.destination = destination }
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
            resetEarlierHistory()
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
        resetEarlierHistory()
        isLoadingThread = true
        let epoch = accountEpoch
        let liveRevisionAtReadStart = liveTimelineRevision(for: threadID)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loadInitialHistory(for: threadID, runtime: runtime)
                guard accountEpoch == epoch, !Task.isCancelled, selectedThreadID == threadID else { return }
                applyConversationSnapshot(
                    loaded.visibleItems,
                    for: loaded.conversation.thread.id,
                    preservingLiveUpdatesAfter: liveRevisionAtReadStart
                )
                installEarlierHistory(from: loaded)
                updateThread(
                    loaded.conversation.thread,
                    preservePositionIfPresent: true
                )
                isLoadingThread = false
                resolveLatestMessageEditAfterAuthoritativeReload(threadID: threadID)
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled, selectedThreadID == threadID else { return }
                isLoadingThread = false
                notice = ("Could not refresh task", error.localizedDescription)
            }
        }
    }

    /// Re-reads the selected task after a destructive request whose local
    /// completion can no longer be trusted (timeout, navigation race, or an
    /// early lifecycle notification). The edit lock stays held while this runs.
    private func reconcileHistoryAfterUncertainEdit(
        threadID: String,
        epoch: UInt64,
        runtime: any AgentRuntime
    ) async -> Bool {
        guard selectedThreadID == threadID, accountEpoch == epoch else { return false }
        loadTask?.cancel()
        loadTask = nil
        resetEarlierHistory()
        isLoadingThread = true
        let liveRevisionAtReadStart = liveTimelineRevision(for: threadID)
        do {
            let loaded = try await loadInitialHistory(for: threadID, runtime: runtime)
            guard accountEpoch == epoch,
                  selectedThreadID == threadID,
                  !Task.isCancelled else { return false }
            applyConversationSnapshot(
                loaded.visibleItems,
                for: loaded.conversation.thread.id,
                preservingLiveUpdatesAfter: liveRevisionAtReadStart
            )
            installEarlierHistory(from: loaded)
            updateThread(
                loaded.conversation.thread,
                preservePositionIfPresent: true
            )
            isLoadingThread = false
            return true
        } catch {
            guard accountEpoch == epoch,
                  selectedThreadID == threadID,
                  !Task.isCancelled else { return false }
            isLoadingThread = false
            return false
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
        resetEarlierHistory()
        isLoadingThread = true
        let epoch = accountEpoch
        let revision = connectionRevision
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await loadInitialHistory(
                    for: threadID,
                    runtime: runtime,
                    resumeUnpaginated: true
                )
                guard accountEpoch == epoch,
                      connectionRevision == revision,
                      !Task.isCancelled,
                      selectedThreadID == threadID,
                      case .connected = connectionState else { return }
                replaceTimeline(loaded.visibleItems, authoritativeFor: loaded.conversation.thread.id)
                installEarlierHistory(from: loaded)
                updateThread(
                    loaded.conversation.thread,
                    preservePositionIfPresent: true
                )
                isTurnRunning = loaded.conversation.thread.status.isBusy
                    || isReviewActive(for: loaded.conversation.thread.id)
                isLoadingThread = false
                resolveLatestMessageEditAfterAuthoritativeReload(threadID: threadID)
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
        guard canRunAgent, let runtime else { return }
        let epoch = accountEpoch
        do {
            try await runtime.renameThread(id: id, name: name)
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            if let index = threads.firstIndex(where: { $0.id == id }) {
                threads[index].title = name
            }
        } catch {
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            if !requireAuthenticationRecovery(for: error) {
                notice = ("Could not rename task", error.localizedDescription)
            }
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

    private func removeUserInteractions(
        for threadID: String,
        limitedTo limitedRequestIDs: Set<RuntimeRequestID>? = nil
    ) {
        let requestIDs = pendingUserInteractions.compactMap { interaction -> RuntimeRequestID? in
            guard interaction.threadID == threadID,
                  limitedRequestIDs?.contains(interaction.id) ?? true else { return nil }
            return interaction.id
        }
        let removedRequestIDs = Set(requestIDs)
        pendingUserInteractions.removeAll { interaction in
            interaction.threadID == threadID
                && removedRequestIDs.contains(interaction.id)
        }
        for requestID in requestIDs {
            respondingInteractionIDs.remove(requestID)
            recoveryQuarantinedInteractionIDs.remove(requestID)
            removeInteractionDraft(for: requestID)
        }
    }

    private func deleteThread(_ id: String) async {
        guard let runtime,
              let thread = threads.first(where: { $0.id == id }),
              canDeleteThread(thread) else {
            if isPreparingLatestMessageEdit(for: id) {
                notice = (
                    "Task history is still changing",
                    "Wait for message editing to finish, then confirm deletion again."
                )
            }
            return
        }
        let epoch = accountEpoch
        do {
            try await runtime.deleteThread(id: id)
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            removeThreadFromCurrentList(id)
            pinnedThreadStore.remove(id)
            updateDraftCache("", for: id)
            composerImageDrafts.removeValue(forKey: id)
            taskModelOverrides.removeValue(forKey: id)
            taskModelDefaults.removeValue(forKey: id)
            persistComposerDraftCache(mode: .background)
            persistTaskModelSelections()
        } catch {
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            if !requireAuthenticationRecovery(for: error) {
                notice = ("Could not delete task", error.localizedDescription)
            }
        }
    }

    private func fetchThreads(in scope: ThreadListScope) async throws -> [RuntimeThread] {
        guard let runtime else { return [] }
        // The sidebar is project-scoped and must remain complete even when a
        // provider has more than the old 100-row page. Codex implements this
        // with cursor pagination; local providers return their uncapped
        // on-disk catalog through the same runtime-neutral API.
        return try await runtime.listAllThreads(archived: scope == .archived).map { thread in
            var projected = thread
            projected.isPinned = pinnedThreadIDs.contains(thread.id)
            return projected
        }
    }

    private func applyThreadList(
        _ liveThreads: [RuntimeThread],
        scope: ThreadListScope,
        preferredSelection: String? = nil,
        preserveCurrentSelection: Bool = false
    ) {
        guard threadListScope == scope else { return }
        hasAuthoritativeThreadListForCurrentScope = true
        isLoadingThreadList = false
        let currentSelection = selectedThreadID
        let currentThreadIndex = currentSelection.flatMap { id in
            threads.firstIndex(where: { $0.id == id && id != Self.welcomeThread.id })
        }
        let currentThreadPresentationIndex = currentThreadIndex.map { index in
            threads[..<index].lazy.filter { $0.id != Self.welcomeThread.id }.count
        }
        let currentThread = currentThreadIndex.map { index in
            threads[index]
        }
        let shouldKeepNewTask = scope == .active && preferredSelection == Self.welcomeThread.id
            || (preserveCurrentSelection && currentSelection == Self.welcomeThread.id)
        var publishedThreads = liveThreads
        if preserveCurrentSelection,
           let currentSelection,
           currentSelection != Self.welcomeThread.id,
           !publishedThreads.contains(where: { $0.id == currentSelection }),
           let currentThread {
            // A provider may intentionally omit child/legacy tasks from its
            // normal list. Keep the task the user is actively viewing in the
            // published snapshot until a later lifecycle/list refresh can
            // reconcile it, instead of blanking the selected workspace. Keep
            // its former ordinal too: appending the retained row would still
            // make the selected target visibly jump to the bottom.
            publishedThreads.insert(
                currentThread,
                at: min(
                    currentThreadPresentationIndex ?? publishedThreads.count,
                    publishedThreads.count
                )
            )
        }
        if shouldKeepNewTask {
            threads = [Self.welcomeThread] + publishedThreads.filter { $0.id != Self.welcomeThread.id }
        } else {
            threads = publishedThreads.isEmpty && scope == .active ? [Self.welcomeThread] : publishedThreads
        }

        if preserveCurrentSelection,
           currentSelection != nil {
            // Navigation already loaded this task (or is loading it). Do not
            // issue a second read or replace its timeline just because the
            // background list completed. The selected ID may not be in either
            // snapshot yet when a cached sidebar click races its provider read;
            // that pending read still owns the user's navigation intent.
            return
        }

        let targetID = preferredSelection.flatMap { preferredID in
            threads.contains(where: { $0.id == preferredID }) ? preferredID : nil
        } ?? selectedThreadID.flatMap { currentID in
            threads.contains(where: { $0.id == currentID }) ? currentID : nil
        } ?? threads.first?.id

        guard let targetID else {
            selectedThreadID = nil
            resetEarlierHistory()
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

    private func recordModelUsageIfAvailable(_ modelID: String?) {
        guard let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else { return }
        modelUsageRecorder(modelID)
    }

    private func persistTaskModelSelections() {
        let overrideKey = preferenceKey(PreferenceKey.taskModelOverrides)
        if taskModelOverrides.isEmpty {
            preferences.removeObject(forKey: overrideKey)
        } else {
            preferences.set(taskModelOverrides, forKey: overrideKey)
        }

        let defaultKey = preferenceKey(PreferenceKey.taskModelDefaults)
        if taskModelDefaults.isEmpty {
            preferences.removeObject(forKey: defaultKey)
        } else {
            preferences.set(taskModelDefaults, forKey: defaultKey)
        }
    }

    /// Closes the local account boundary after the provider has confirmed
    /// logout. No task, transcript, draft, workspace, or async completion from
    /// the previous account may remain visible in the signed-out window.
    private func closeAccountBoundary() {
        closeSideChat()
        workspacePersistenceStore?.clearAccountOwnedState()
        invalidateLatestMessageEdit()
        accountEpoch &+= 1
        connectionRevision &+= 1
        navigationRevision += 1

        connectionTask?.cancel()
        connectionTask = nil
        loadTask?.cancel()
        loadTask = nil
        resetEarlierHistory()
        threadListTask?.cancel()
        threadListTask = nil
        accountRefreshTask?.cancel()
        accountRefreshTask = nil
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        draftSaveTask?.cancel()
        draftSaveTask = nil

        pendingDeltas.removeAll()
        discardedSideChatThreadIDs.removeAll()
        activeTurnIDsByThreadID.removeAll()
        pendingSteeringMessagesByThreadID.removeAll()
        liveTimelineRevisionByThreadID.removeAll()
        liveItemRevisionByThreadID.removeAll()
        livePlanRevisionByThreadID.removeAll()
        reviewingThreadID = nil
        startingReviewThreadID = nil
        pendingUserInteractions.removeAll()
        respondingInteractionIDs.removeAll()
        recoveryQuarantinedInteractionIDs.removeAll()
        removeAllInteractionDrafts()
        pendingRestoredSelectionID = nil
        hasExplicitNewTaskSelection = false
        downgradedRuntimeCapabilities = []
        cancelledLoginID = nil
        loginRecoveryPendingConfirmation = false
        authenticationRecoveryAccountIdentity = nil
        mountedAccountIdentity = nil
        loginAttempt = nil
        isAuthenticating = false
        authenticationRecovery = nil

        composerDrafts.removeAll()
        pendingComposerDraftMutations.removeAll(keepingCapacity: true)
        composerImageDrafts.removeAll()
        taskModelOverrides.removeAll()
        taskModelDefaults.removeAll()
        pinnedThreadStore.removeAll()
        plansByThreadID.removeAll()
        draftWorkspacePath = nil
        searchText = ""
        threadListScope = .active
        hasAuthoritativeThreadListForCurrentScope = true
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
        removePersistedComposerDrafts(mode: .synchronous)
        preferences.removeObject(forKey: preferenceKey(PreferenceKey.taskModelOverrides))
        preferences.removeObject(forKey: preferenceKey(PreferenceKey.taskModelDefaults))
        preferences.removeObject(forKey: preferenceKey("Onyx.lastWorkspacePath"))
    }

    private func applyRuntimeSession(_ updatedSession: RuntimeSession) {
        if isSideChatPresented,
           !updatedSession.capabilities.contains(.ephemeralThreadForking) {
            closeSideChat()
        }
        session = applyingRuntimeCapabilityDowngrades(to: updatedSession)
        authState = updatedSession.auth
        if authenticationRecovery == nil,
           let identity = AccountIdentity(updatedSession.auth) {
            mountedAccountIdentity = identity
        }
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

    private func scheduleAccountRefresh(
        rejectSignedInSession: Bool = false
    ) {
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
                if loginRecoveryPendingConfirmation, refreshedSession.auth.isSignedIn {
                    finishAuthenticationRecovery(with: refreshedSession)
                } else {
                    applyRuntimeSession(refreshedSession)
                }
            } catch {
                guard accountEpoch == epoch, !Task.isCancelled else { return }
                // The notification projection is still useful. A later account event or reconnect retries.
            }
            guard accountEpoch == epoch, !Task.isCancelled else { return }
            accountRefreshTask = nil
        }
    }

    /// Commits a login-confirmed account snapshot without ever displaying old
    /// account state under a known replacement identity. Same-account recovery
    /// is intentionally in place; a different known identity crosses the
    /// normal destructive account boundary before its session is projected.
    /// If app-server cannot identify either side, use the same destructive
    /// boundary rather than guessing that private state is safe to preserve.
    private func finishAuthenticationRecovery(with refreshedSession: RuntimeSession) {
        guard loginRecoveryPendingConfirmation,
              refreshedSession.auth.isSignedIn else { return }

        // `account/read` can fail before the first connection bootstrap has a
        // session. A successful recovery refresh proves the retained transport
        // is usable again, but it does not resume the connection task that
        // returned early. Remember that state so recovery can re-enter the
        // ordinary connect + complete-catalog path below.
        let shouldResumeConnectionBootstrap = canReconnect

        let priorIdentity = authenticationRecoveryAccountIdentity
        let refreshedIdentity = AccountIdentity(refreshedSession.auth)

        guard let priorIdentity, let refreshedIdentity else {
            // Only a known same-account result is safe for in-place recovery.
            // When either side is unknown, clear account-owned state before
            // projecting the refreshed session rather than guessing across a
            // possible account replacement.
            closeAccountBoundary()
            applyRuntimeSession(refreshedSession)
            if shouldResumeConnectionBootstrap {
                reconnect()
            }
            return
        }

        guard priorIdentity == refreshedIdentity else {
            closeAccountBoundary()
            applyRuntimeSession(refreshedSession)
            if shouldResumeConnectionBootstrap {
                reconnect()
            }
            return
        }

        applyRuntimeSession(refreshedSession)
        mountedAccountIdentity = refreshedIdentity
        authenticationRecoveryAccountIdentity = nil
        authenticationRecovery = nil
        loginRecoveryPendingConfirmation = false
        if shouldResumeConnectionBootstrap {
            reconnect()
        } else {
            reconcileSelectedThreadAfterAuthenticationRecovery()
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

    /// A provider should normally throw the typed recovery error. Keep the
    /// startup boundary tolerant of an older/runtime-wrapper build that still
    /// forwards the original diagnostic, because this catch runs before a
    /// session snapshot (and therefore before the view has any login methods).
    private func authenticationRecovery(for error: any Error) -> RuntimeAuthenticationRecovery? {
        if case let AgentRuntimeError.authenticationRecoveryRequired(recovery) = error {
            return recovery
        }
        guard runtimeKind == .codex,
              CodexProjection.isAuthenticationRecoveryDiagnostic(error.localizedDescription) else {
            return nil
        }
        return .signInExpired
    }

    private func validateSelectedReasoningEffort() {
        guard let model = selectedRuntimeModel else { return }
        guard model.supportedRequestParameters.isEmpty
                || model.supportedRequestParameters.contains(.reasoningEffort)
        else {
            selectedReasoningEffort = nil
            return
        }
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
        updateDraftCache("", for: sourceKey)
        composerImageDrafts.removeValue(forKey: sourceKey)
        persistDraft(followUp, for: targetKey)
        persistImageDraft(followUpImages, for: targetKey)

        guard isVisibleSource,
              navigationRevision == expectedRevision,
              threadListScope == .active,
              selectedThreadID == nil || selectedThreadID == Self.welcomeThread.id else { return }

        navigationRevision += 1
        selectedThreadID = thread.id
        hasExplicitNewTaskSelection = false
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
        let isVisibleOrigin = composerDraftKey == context.sourceDraftKey
        if isVisibleSource {
            saveCurrentDraftNow()
            saveCurrentImageDraftNow()
        }
        let followUp = composerDrafts[provisionalKey] ?? ""
        let followUpImages = composerImageDrafts[provisionalKey] ?? []
        updateDraftCache("", for: provisionalKey)
        composerImageDrafts.removeValue(forKey: provisionalKey)

        let restoredAttempt: String
        if followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restoredAttempt = context.draftText
        } else if followUp == context.draftText {
            restoredAttempt = followUp
        } else {
            restoredAttempt = context.draftText + "\n\n" + followUp
        }
        // New Task can expose the welcome composer again while start-thread is
        // still pending. Preserve anything typed there instead of replacing it
        // with the failed request. Keep the failed request first so both pieces
        // remain recoverable and the existing follow-up ordering is unchanged.
        let existingOriginDraft = if isVisibleOrigin {
            composerText
        } else {
            composerDrafts[context.sourceDraftKey] ?? ""
        }
        let restored: String
        if existingOriginDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restored = restoredAttempt
        } else if existingOriginDraft == restoredAttempt {
            restored = existingOriginDraft
        } else {
            restored = restoredAttempt + "\n\n" + existingOriginDraft
        }
        persistDraft(restored, for: context.sourceDraftKey)
        persistImageDraft(mergedFailedImages(context.images, with: followUpImages), for: context.sourceDraftKey)

        if isVisibleSource,
           navigationRevision == context.navigationRevision,
           selectedThreadID == context.originThreadID {
            composerDraftKey = context.sourceDraftKey
            composerText = restored
            composerImages = composerImageDrafts[context.sourceDraftKey] ?? []
        } else if isVisibleOrigin {
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
                "Another \(runtimeDisplayName) window is actively working in this task. Let that turn finish or close the other window, then try again. Your draft is still here."
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
            updateDraftCache(text, for: key)
            persistComposerDraftCache(mode: .background)
            draftSaveTask = nil
        }
    }

    private func saveCurrentDraftNow(
        mode: OnyxComposerDraftPersistenceMode = .background
    ) {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        updateDraftCache(composerText, for: composerDraftKey)
        persistComposerDraftCache(mode: mode)
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
        updateDraftCache(text, for: key)
        // These calls reconcile a completed/failed turn after the user-visible
        // state has already been updated. They must not make the main actor
        // wait for serialization of every draft in the window.
        persistComposerDraftCache(mode: .background)
    }

    private func updateDraftCache(_ text: String, for key: String) {
        // Navigation often re-saves an unchanged empty draft. Avoid touching a
        // potentially large dictionary in that case; mutating a shared
        // UserDefaults snapshot would otherwise trigger a full copy on the
        // main actor during the New Task click.
        if composerDrafts[key] == text,
           pendingComposerDraftMutations[key] == nil {
            return
        }
        let mutation = OnyxComposerDraftMutation.replacingDraft(text, for: key)
        pendingComposerDraftMutations[key] = mutation
        if case .remove = mutation {
            composerDrafts.removeValue(forKey: key)
        } else {
            composerDrafts[key] = text
        }
    }

    private func persistComposerDraftCache(mode: OnyxComposerDraftPersistenceMode) {
        let mutations = Array(pendingComposerDraftMutations.values)
        pendingComposerDraftMutations.removeAll(keepingCapacity: true)
        composerDraftPersistenceRevision &+= 1
        composerDraftPersistence.persistChanges(
            mutations,
            currentDrafts: composerDrafts,
            forKey: preferenceKey(PreferenceKey.composerDrafts),
            revision: composerDraftPersistenceRevision,
            mode: mode
        )
    }

    private func removePersistedComposerDrafts(mode: OnyxComposerDraftPersistenceMode) {
        pendingComposerDraftMutations.removeAll(keepingCapacity: true)
        composerDraftPersistenceRevision &+= 1
        composerDraftPersistence.remove(
            forKey: preferenceKey(PreferenceKey.composerDrafts),
            revision: composerDraftPersistenceRevision,
            mode: mode
        )
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

        let selectedDeltas = deltas.compactMap { key, delta -> TranscriptDeltaFlushPlan.Delta? in
            guard key.threadID == selectedThreadID, !delta.isEmpty else { return nil }
            return TranscriptDeltaFlushPlan.Delta(itemID: key.itemID, text: delta)
        }
        // `itemCompleted` also drains the coalescing buffer. Keep that common
        // no-op path constant-time when another thread owns the buffered
        // events (or when the buffer was already consumed by a history read).
        guard !selectedDeltas.isEmpty else { return }
        let flushPlan = TranscriptDeltaFlushPlan.make(
            items: timeline,
            deltas: selectedDeltas
        )
        var changedIndices = IndexSet()
        for update in flushPlan.existingUpdates {
            changedIndices.insert(update.index)
        }

        if !changedIndices.isEmpty {
            let existingUpdates = flushPlan.existingUpdates
            mutateTimelineRows(changedIndices) { items in
                for update in existingUpdates where items.indices.contains(update.index) {
                    items[update.index].body += update.text
                }
            }
        }
        for update in flushPlan.appendedUpdates {
            appendTimeline(
                TimelineItem(
                    id: update.itemID,
                    kind: .assistantMessage,
                    title: nil,
                    body: update.text,
                    status: .running,
                    timestamp: .now,
                    detail: nil
                )
            )
        }
    }
}
