import AppKit
import Foundation
import SwiftUI

struct OnyxWindowPresentationContext: @unchecked Sendable {
    let windowProvider: @MainActor () -> NSWindow?

    @MainActor
    var window: NSWindow? { windowProvider() }

    static let unavailable = Self(windowProvider: { nil })
}

private struct OnyxWindowPresentationContextKey: EnvironmentKey {
    static let defaultValue = OnyxWindowPresentationContext.unavailable
}

extension EnvironmentValues {
    var onyxWindowPresentationContext: OnyxWindowPresentationContext {
        get { self[OnyxWindowPresentationContextKey.self] }
        set { self[OnyxWindowPresentationContextKey.self] = newValue }
    }
}

/// Breaks the app-host/runtime construction cycle without retaining the app
/// host from the Codex runtime. The broker keeps this bridge, while the bridge
/// refers weakly back to the fully initialized composition root.
@MainActor
private final class OnyxDelegationHostBridge {
    weak var host: OnyxApplicationHost?

    func providerConfigurations() async throws -> [DelegationProviderConfiguration] {
        guard let host else { throw DelegationHostBridgeError.unavailable }
        return try await host.delegationProviderConfigurations()
    }

    func runtime(
        for connectionID: ProviderConnectionID
    ) throws -> any AgentRuntime {
        guard let host else { throw DelegationHostBridgeError.unavailable }
        return try host.delegationRuntime(for: connectionID)
    }

    private enum DelegationHostBridgeError: Error { case unavailable }
}

/// Durable scene identity used by SwiftUI to restore each workspace window
/// independently. The UUID never crosses the provider boundary; it only scopes
/// app-owned window state and macOS frame restoration.
struct WorkspaceWindowID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: UUID
    /// An optional provider connection selected when this workspace was
    /// created.  Keeping it on the scene identity lets SwiftUI restore a
    /// provider-specific window without teaching the Codex task IDs about
    /// other providers.  Existing windows decode with `nil` and retain the
    /// legacy Codex behavior.
    let providerConnectionID: ProviderConnectionID?

    init(rawValue: UUID) {
        self.rawValue = rawValue
        self.providerConnectionID = nil
    }

    init(rawValue: UUID, providerConnectionID: ProviderConnectionID?) {
        self.rawValue = rawValue
        self.providerConnectionID = providerConnectionID
    }

    init(providerConnectionID: ProviderConnectionID? = nil) {
        self.init(rawValue: UUID(), providerConnectionID: providerConnectionID)
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
        case providerConnectionID
    }

    init(from decoder: any Decoder) throws {
        // Older scene-restoration values were encoded as the RawRepresentable
        // UUID itself. The keyed form is used now that provider identity is
        // carried beside it; both shapes remain readable.
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let rawValue = try container.decodeIfPresent(UUID.self, forKey: .rawValue) {
            self.init(
                rawValue: rawValue,
                providerConnectionID: try container.decodeIfPresent(
                    ProviderConnectionID.self,
                    forKey: .providerConnectionID
                )
            )
            return
        }
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
        try container.encodeIfPresent(providerConnectionID, forKey: .providerConnectionID)
    }

    var id: UUID { rawValue }

    var preferenceKeyPrefix: String {
        "Onyx.window.\(rawValue.uuidString.lowercased())"
    }

    var frameAutosaveName: String {
        "Onyx.Window.\(rawValue.uuidString.lowercased())"
    }

    /// Preferences containing task IDs and drafts must not be shared by two
    /// providers.  Window chrome remains keyed by `preferenceKeyPrefix`; the
    /// provider suffix is used only for app-model state.
    func providerPreferenceKeyPrefix() -> String {
        guard let providerConnectionID else { return preferenceKeyPrefix }
        let bytes = Data(providerConnectionID.rawValue.utf8)
        let escaped = bytes.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(preferenceKeyPrefix).provider.\(escaped)"
    }
}

/// Maps the existing single-window preference keys into a stable window
/// namespace. A nil prefix intentionally preserves the legacy keys so focused
/// model tests and callers outside production composition remain compatible.
struct OnyxPreferenceNamespace: Hashable, Sendable {
    let prefix: String?

    init(prefix: String?) {
        let trimmed = prefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.prefix = trimmed.isEmpty ? nil : trimmed
    }

    func key(_ legacyKey: String) -> String {
        guard let prefix else { return legacyKey }
        let suffix = legacyKey.hasPrefix("Onyx.")
            ? String(legacyKey.dropFirst("Onyx.".count))
            : legacyKey
        return "\(prefix).\(suffix)"
    }
}

/// App-lifetime composition owner. It resolves and wraps the provider runtime
/// exactly once, then lends the same broadcast-capable coordinator to every
/// independently owned window model.
@MainActor
final class OnyxApplicationHost: ObservableObject {
    let runtimeCoordinator: SharedRuntimeCoordinator?
    let startupError: (any Error)?
    let defaults: UserDefaults
    let pinnedThreadStore: OnyxPinnedThreadStore
    let workspacePersistenceStore: OnyxWorkspacePersistenceStore
    let projectCatalogModel: ProjectCatalogModel
    let settingsModel: OnyxAppModel
    let providerSettingsModel: ProviderSettingsModel
    private let delegationBroker: OnyxDelegationBroker
    /// Changes only after an accepted turn is attributed to a model. Views
    /// observe this narrow signal to refresh the picker once, instead of
    /// rebuilding rankings for every streamed transcript publication.
    @Published private(set) var modelUsageRevision: UInt64 = 0
    /// Advances after a provider settings transaction fully finishes. Open
    /// windows observe this narrow signal and replace models that still retain
    /// the permanently retired runtime generation.
    @Published private(set) var providerRuntimeRevision: UInt64 = 0

    private let registry: RuntimeRegistry
    private let defaultConnectionID: ProviderConnectionID
    private let providerConnectionStore: ProviderConnectionStore
    private let providerCredentialStore: any CredentialStore
    private let providerConversationStore: OpenAICompatibleConversationStore
    private let providerAdaptiveStateStore: OpenAICompatibleAdaptiveStateStore
    private var runtimeCoordinators: [ProviderConnectionID: SharedRuntimeCoordinator]
    private var providerRuntimeMutationDepths: [ProviderConnectionID: Int] = [:]
    private var providerRuntimeRevisions: [ProviderConnectionID: UInt64] = [:]
    private var pinnedThreadStores: [ProviderConnectionID: OnyxPinnedThreadStore]
    /// Model choices are rendered from SwiftUI's frequently invalidated view
    /// tree. Keep the decoded usage ledger in memory so a transcript/status
    /// publication does not repeatedly decode the entire JSON blob just to
    /// sort the picker. The cache is refreshed whenever this host records a
    /// usage event (the only writer owned by the app).
    private var modelUsageCache: [String: ModelUsageRecord]? = nil

    static let selectedProviderPreferenceSuffix = "selectedProviderConnectionID"
    static let modelUsagePreferenceKey = "Onyx.providerModelUsage"

    struct WorkspaceConnection: Identifiable, Hashable, Sendable {
        let id: ProviderConnectionID
        let displayName: String
        let isCodex: Bool
    }

    struct WorkspaceConnectionCatalog: Sendable {
        let connections: [WorkspaceConnection]
        /// False means configured provider records could not be read. The
        /// built-in Codex row remains renderable, but a one-time project
        /// migration cannot safely conclude that its task source is complete.
        let sourceComplete: Bool
    }

    struct ProviderModelChoice: Identifiable, Hashable, Sendable {
        let connection: WorkspaceConnection
        let model: RuntimeModel
        let usageCount: Int
        let lastUsedAt: Date?

        var id: String { "\(connection.id.rawValue)\u{1f}\(model.id)" }
    }

    struct ProviderModelCatalog: Hashable, Sendable {
        let connection: WorkspaceConnection
        let models: [RuntimeModel]
    }

    private struct ModelUsageRecord: Codable {
        var count: Int
        var lastUsedAt: Date
    }

    init(
        registry: RuntimeRegistry = .codexOnly,
        connectionID: ProviderConnectionID = .codexDefault,
        defaults: UserDefaults = .standard,
        projectCatalogStore: ProjectCatalogStore = ProjectCatalogStore(
            fileURL: ProjectCatalogLocation.applicationSupportFileURL()
        ),
        providerConnectionStore: ProviderConnectionStore = ProviderConnectionStore(),
        providerCredentialStore: any CredentialStore = KeychainCredentialStore(),
        providerModelDiscovery: any ProviderModelDiscovery = URLSessionProviderModelDiscovery(),
        providerConversationStore: OpenAICompatibleConversationStore = OpenAICompatibleConversationStore(),
        providerAdaptiveStateStore: OpenAICompatibleAdaptiveStateStore = OpenAICompatibleAdaptiveStateStore()
    ) {
        let delegationBridge = OnyxDelegationHostBridge()
        let delegationBroker = OnyxDelegationBroker(
            providerCatalogResolver: {
                try await delegationBridge.providerConfigurations()
            },
            runtimeResolver: { connectionID in
                try await delegationBridge.runtime(for: connectionID)
            }
        )
        self.registry = registry
        self.defaultConnectionID = connectionID
        self.providerConnectionStore = providerConnectionStore
        self.providerCredentialStore = providerCredentialStore
        self.providerConversationStore = providerConversationStore
        self.providerAdaptiveStateStore = providerAdaptiveStateStore
        self.delegationBroker = delegationBroker
        let coordinator: SharedRuntimeCoordinator?
        let resolutionError: (any Error)?
        do {
            coordinator = SharedRuntimeCoordinator(
                runtime: try registry.resolve(
                    connectionID,
                    dynamicToolHandler: delegationBroker.scopedHandler(
                        parentConnectionID: connectionID
                    )
                )
            )
            resolutionError = nil
        } catch {
            coordinator = nil
            resolutionError = error
        }

        runtimeCoordinator = coordinator
        runtimeCoordinators = coordinator.map { [connectionID: $0] } ?? [:]
        startupError = resolutionError
        self.defaults = defaults
        let pinnedThreadStore = OnyxPinnedThreadStore(
            defaults: defaults,
            connectionID: connectionID
        )
        let workspacePersistenceStore = OnyxWorkspacePersistenceStore(defaults: defaults)
        self.pinnedThreadStore = pinnedThreadStore
        pinnedThreadStores = [connectionID: pinnedThreadStore]
        self.workspacePersistenceStore = workspacePersistenceStore
        projectCatalogModel = ProjectCatalogModel(store: projectCatalogStore)
        settingsModel = OnyxAppModel(
            runtime: coordinator,
            startupError: resolutionError,
            defaults: defaults,
            preferenceKeyPrefix: "Onyx.settings",
            pinnedThreadStore: pinnedThreadStore,
            workspacePersistenceStore: workspacePersistenceStore
        )
        providerSettingsModel = ProviderSettingsModel(
            connectionStore: providerConnectionStore,
            credentialStore: providerCredentialStore,
            discovery: providerModelDiscovery
        )
        providerSettingsModel.onConnectionWillMutate = { [weak self] connectionID in
            await self?.retireProviderRuntime(for: connectionID)
        }
        providerSettingsModel.onConnectionMutation = { [weak self] connectionID in
            self?.evictRetiredProviderRuntime(for: connectionID)
        }
        delegationBridge.host = self
    }

    /// Creates a window model for the provider encoded by its scene identity.
    /// A provider window gets its own shared coordinator, while additional
    /// windows for that same connection reuse it (and therefore one network
    /// connection/event stream).
    func makeWindowModel(
        for windowID: WorkspaceWindowID,
        startsWithNewTask: Bool = false
    ) -> OnyxAppModel {
        let requestedConnectionID = selectedConnectionID(for: windowID)
        let resolved = runtimeCoordinator(for: requestedConnectionID)
        let preferencePrefix = providerPreferenceKeyPrefix(
            windowID: windowID,
            connectionID: requestedConnectionID
        )
        workspacePersistenceStore.prepareNamespace(preferencePrefix)
        let pinnedThreadStore = pinnedThreadStore(for: requestedConnectionID)
        return OnyxAppModel(
            runtime: resolved.coordinator,
            startupError: resolved.error,
            defaults: defaults,
            preferenceKeyPrefix: preferencePrefix,
            pinnedThreadStore: pinnedThreadStore,
            workspacePersistenceStore: workspacePersistenceStore,
            startsWithNewTask: startsWithNewTask,
            modelUsageRecorder: { [weak self] modelID in
                self?.recordModelUsage(connectionID: requestedConnectionID, modelID: modelID)
            }
        )
    }

    /// Carries an in-progress welcome-task draft across a provider switch.
    /// Durable tasks are intentionally excluded: their transcript and pinned
    /// model remain owned by the original provider window.
    static func transferNewTaskContext(from source: OnyxAppModel, to destination: OnyxAppModel) {
        let context = source.captureNewTaskContext()
        source.stageWindowStateForReplacement()
        if let context {
            destination.restoreNewTaskContext(context)
        }
    }

    /// Rebinds an open window after its provider runtime was retired while
    /// preserving the task selection and exact visible draft, including image
    /// attachments that intentionally are not serialized into UserDefaults.
    func makeRuntimeReplacementWindowModel(
        for windowID: WorkspaceWindowID,
        replacing source: OnyxAppModel
    ) -> OnyxAppModel {
        let context = source.captureRuntimeReplacementContext()
        let replacement = makeWindowModel(for: windowID)
        replacement.restoreRuntimeReplacementContext(context)
        return replacement
    }

    func selectedConnectionID(for windowID: WorkspaceWindowID) -> ProviderConnectionID {
        if let explicit = windowID.providerConnectionID { return explicit }
        let key = "\(windowID.preferenceKeyPrefix).\(Self.selectedProviderPreferenceSuffix)"
        guard let raw = defaults.string(forKey: key), !raw.isEmpty else {
            return defaultConnectionID
        }
        return ProviderConnectionID(raw)
    }

    func validatedSelection(
        for windowID: WorkspaceWindowID,
        availableConnections: [WorkspaceConnection]
    ) -> ProviderConnectionID {
        let selected = selectedConnectionID(for: windowID)
        guard availableConnections.contains(where: { $0.id == selected }) else {
            return defaultConnectionID
        }
        return selected
    }

    func selectConnection(_ connectionID: ProviderConnectionID, for windowID: WorkspaceWindowID) {
        let key = "\(windowID.preferenceKeyPrefix).\(Self.selectedProviderPreferenceSuffix)"
        defaults.set(connectionID.rawValue, forKey: key)
    }

    func providerPreferenceKeyPrefix(
        windowID: WorkspaceWindowID,
        connectionID: ProviderConnectionID
    ) -> String {
        if connectionID == defaultConnectionID { return windowID.preferenceKeyPrefix }
        return WorkspaceWindowID(
            rawValue: windowID.rawValue,
            providerConnectionID: connectionID
        ).providerPreferenceKeyPrefix()
    }

    func sceneProviderConnectionID(
        for connectionID: ProviderConnectionID
    ) -> ProviderConnectionID? {
        connectionID == defaultConnectionID ? nil : connectionID
    }

    func workspaceConnectionCatalog() async -> WorkspaceConnectionCatalog {
        var values = defaultWorkspaceConnections
        do {
            let records = try await providerConnectionStore.connections()
            values.append(contentsOf: records.map {
                WorkspaceConnection(id: $0.id, displayName: $0.displayName, isCodex: false)
            })
            return WorkspaceConnectionCatalog(connections: values, sourceComplete: true)
        } catch {
            return WorkspaceConnectionCatalog(connections: values, sourceComplete: false)
        }
    }

    func workspaceConnections() async -> [WorkspaceConnection] {
        await workspaceConnectionCatalog().connections
    }

    /// Settings publishes its durable post-transaction snapshot before the
    /// runtime revision advances. This synchronous projection lets an open
    /// window distinguish a same-ID edit from deletion without waiting behind
    /// filesystem-backed catalog work.
    func publishedWorkspaceConnections() -> [WorkspaceConnection] {
        defaultWorkspaceConnections + providerSettingsModel.connections.map {
            WorkspaceConnection(id: $0.id, displayName: $0.displayName, isCodex: false)
        }
    }

    private var defaultWorkspaceConnections: [WorkspaceConnection] {
        [
            WorkspaceConnection(
                id: defaultConnectionID,
                displayName: "Codex",
                isCodex: true
            ),
        ]
    }

    /// Returns the best model catalog already available for each configured
    /// provider. Saved discovery metadata paints immediately; a provider whose
    /// shared adaptive runtime already exists contributes its capability-aware
    /// session projection. Merely opening the picker must not create or connect
    /// an otherwise unused provider runtime.
    func cachedProviderModelCatalogs() async -> [ProviderConnectionID: [RuntimeModel]] {
        guard let records = try? await providerConnectionStore.connections() else { return [:] }
        var catalogs: [ProviderConnectionID: [RuntimeModel]] = [:]
        catalogs.reserveCapacity(records.count)
        for record in records {
            let persisted = Self.cachedRuntimeModels(for: record)
            guard providerRuntimeMutationDepths[record.id, default: 0] == 0,
                  let coordinator = runtimeCoordinators[record.id],
                  let session = try? await coordinator.connect() else {
                catalogs[record.id] = persisted
                continue
            }
            catalogs[record.id] = Self.modelCatalog(
                retaining: persisted,
                preferring: session.availableModels
            )
        }
        return catalogs
    }

    fileprivate func delegationProviderConfigurations() async throws
        -> [DelegationProviderConfiguration]
    {
        var configurations = try await providerConnectionStore.connections()
            .filter { $0.id != .codexDefault }
            .map { record in
                DelegationProviderConfiguration(
                    connectionID: record.id,
                    displayName: record.displayName,
                    models: Self.cachedRuntimeModels(for: record)
                )
            }
        // Keep the Codex target in the same credential-free catalog as saved
        // OpenAI-compatible providers.  A generic agent can therefore hand a
        // bounded subtask back to the native Codex runtime without receiving
        // its auth state or endpoint.  `connect()` is a cached read when the
        // Codex runtime is already active (which it is for a Codex task),
        // and is intentionally best-effort so a signed-out/failed Codex lane
        // does not prevent other providers from delegating.
        if let codexCoordinator = runtimeCoordinator(for: .codexDefault).coordinator,
           let codexSession = try? await codexCoordinator.connect() {
            configurations.insert(
                DelegationProviderConfiguration(
                    connectionID: .codexDefault,
                    displayName: "Codex",
                    models: codexSession.availableModels
                ),
                at: 0
            )
        }
        return configurations
    }

    fileprivate func delegationRuntime(
        for connectionID: ProviderConnectionID
    ) throws -> any AgentRuntime {
        let resolved = runtimeCoordinator(for: connectionID)
        if let error = resolved.error { throw error }
        guard let coordinator = resolved.coordinator else {
            throw AgentRuntimeError.unsupported("delegation provider connection")
        }
        return coordinator
    }

    /// Loads the complete task catalog for every configured connection. The
    /// returned `sourceComplete` bit is intentionally separate from the lists:
    /// a partial snapshot is still useful to paint the sidebar without
    /// pretending every provider finished loading successfully.
    func cachedProviderTaskCatalog(
        connections: [WorkspaceConnection]
    ) async -> ProjectProviderTaskCatalog {
        var lists: [ProjectProviderTaskList] = []
        var sourceComplete = true

        for connection in connections {
            let pinnedIDs = pinnedThreadStore(for: connection.id).ids
            if connection.isCodex {
                let resolved = runtimeCoordinator(for: connection.id)
                guard let coordinator = resolved.coordinator,
                      (try? await coordinator.connect()) != nil else {
                    sourceComplete = false
                    continue
                }

                for scope in ThreadListScope.allCases {
                    do {
                        let threads = try await coordinator.listAllThreads(
                            archived: scope == .archived
                        )
                        lists.append(ProjectProviderTaskList(
                            providerConnectionID: connection.id,
                            providerDisplayName: connection.displayName,
                            scope: scope,
                            threads: threads.map {
                                var thread = $0
                                thread.isPinned = pinnedIDs.contains(thread.id)
                                return thread
                            }
                        ))
                    } catch {
                        // Preserve successful scopes for rendering, while
                        // withholding migration until the source is whole.
                        sourceComplete = false
                    }
                }
                continue
            }

            let providerRecord = try? await providerConnectionStore.connection(
                id: connection.id
            )
            let conversationScopeID = providerRecord?.conversationScopeID
                ?? ProviderConnectionRecord.legacyConversationScopeID(for: connection.id)
            // Local provider transcripts created by older builds have no
            // scope marker. Migrate them before filtering so they remain
            // visible on the first launch, while later endpoint/credential
            // rotations keep the old scope isolated.
            if providerRecord != nil {
                _ = try? await providerConversationStore.migrateLegacyConversations(
                    connectionID: connection.id,
                    to: conversationScopeID
                )
            }
            // Chat ownership alone does not require a network/runtime
            // connection for the sidebar; only an agent owner means the
            // merged app-server catalog must be consulted.
            let hasAdaptiveOwners: Bool
            do {
                let ownerships = try await providerAdaptiveStateStore.taskOwnerships(
                    connectionID: connection.id,
                    conversationScopeID: conversationScopeID,
                    lane: .agent
                )
                hasAdaptiveOwners = !ownerships.isEmpty
            } catch {
                sourceComplete = false
                // Ownership metadata is only needed to decide whether an
                // agent catalog must be merged. If that metadata is damaged
                // or temporarily unreadable, preserve the scoped Onyx chat
                // rows instead of blanking this provider from the sidebar.
                // The partial marker prevents this fallback from being
                // mistaken for an authoritative absence of agent tasks.
                let fallback = await loadLocalProviderTaskLists(
                    connection: connection,
                    conversationScopeID: conversationScopeID,
                    pinnedIDs: pinnedIDs,
                    scopes: ThreadListScope.allCases
                )
                lists.append(contentsOf: fallback.lists)
                continue
            }

            if hasAdaptiveOwners {
                // Once this provider has adaptive ownership metadata, its
                // runtime owns the merged chat + app-server catalog. Reading
                // the chat store directly would make agent tasks disappear on
                // the next background/sidebar refresh.
                let resolved = runtimeCoordinator(for: connection.id)
                guard let coordinator = resolved.coordinator,
                      (try? await coordinator.connect()) != nil else {
                    // The app-owned chat history remains useful when the
                    // Responses/app-server lane is offline (for example, an
                    // endpoint outage or a missing credential). Keep those
                    // rows visible while accurately marking the merged
                    // snapshot partial; agent-owned rows will reappear after
                    // the next successful refresh.
                    sourceComplete = false
                    let fallback = await loadLocalProviderTaskLists(
                        connection: connection,
                        conversationScopeID: conversationScopeID,
                        pinnedIDs: pinnedIDs,
                        scopes: ThreadListScope.allCases
                    )
                    lists.append(contentsOf: fallback.lists)
                    continue
                }
                for scope in ThreadListScope.allCases {
                    do {
                        let threads = try await coordinator.listAllThreads(
                            archived: scope == .archived
                        )
                        lists.append(ProjectProviderTaskList(
                            providerConnectionID: connection.id,
                            providerDisplayName: connection.displayName,
                            scope: scope,
                            threads: threads.map {
                                var thread = $0
                                thread.isPinned = pinnedIDs.contains(thread.id)
                                return thread
                            }
                        ))
                    } catch {
                        sourceComplete = false
                        // Preserve chat-owned rows for this scope if the
                        // merged runtime fails after connecting. Do not read
                        // the other scope again, which would duplicate rows
                        // that already came from the successful app-server
                        // response above.
                        let fallback = await loadLocalProviderTaskLists(
                            connection: connection,
                            conversationScopeID: conversationScopeID,
                            pinnedIDs: pinnedIDs,
                            scopes: [scope]
                        )
                        lists.append(contentsOf: fallback.lists)
                    }
                }
                continue
            }

            // A never-opened or pre-adaptive provider has chat history only.
            // Read that local snapshot without connecting its endpoint; this
            // keeps global sidebar refreshes offline and immediately paintable.
            let localCatalog = await loadLocalProviderTaskLists(
                connection: connection,
                conversationScopeID: conversationScopeID,
                pinnedIDs: pinnedIDs,
                scopes: ThreadListScope.allCases
            )
            lists.append(contentsOf: localCatalog.lists)
            sourceComplete = sourceComplete && localCatalog.sourceComplete
        }

        return ProjectProviderTaskCatalog(
            lists: lists,
            sourceComplete: sourceComplete
        )
    }

    /// Reads only Onyx-owned chat history for a configured provider. This is
    /// deliberately separate from adaptive app-server listing so a partial
    /// agent catalog can still paint chat rows offline without implying that
    /// the missing agent rows are complete.
    private func loadLocalProviderTaskLists(
        connection: WorkspaceConnection,
        conversationScopeID: String,
        pinnedIDs: Set<String>,
        scopes: [ThreadListScope]
    ) async -> (lists: [ProjectProviderTaskList], sourceComplete: Bool) {
        var lists: [ProjectProviderTaskList] = []
        var sourceComplete = true
        for scope in scopes {
            do {
                let conversations = try await providerConversationStore.conversations(
                    connectionID: connection.id,
                    scopeID: conversationScopeID,
                    archived: scope == .archived,
                    limit: Int.max
                )
                lists.append(ProjectProviderTaskList(
                    providerConnectionID: connection.id,
                    providerDisplayName: connection.displayName,
                    scope: scope,
                    threads: conversations.map {
                        var thread = $0.runtimeThread(kind: .local)
                        thread.isPinned = pinnedIDs.contains(thread.id)
                        return thread
                    }
                ))
            } catch {
                sourceComplete = false
            }
        }
        return (lists, sourceComplete)
    }

    /// Compatibility projection for callers that only need sidebar lists.
    func cachedProviderTaskLists(
        connections: [WorkspaceConnection]
    ) async -> [ProjectProviderTaskList] {
        await cachedProviderTaskCatalog(connections: connections).lists
    }

    /// Loads provider tasks without deriving projects from their working
    /// folders. Projects are app-owned, explicit user choices; a fresh Onyx
    /// install must remain a blank slate even when a provider has years of
    /// task history.
    @discardableResult
    func loadProviderTaskCatalog(
        connections: [WorkspaceConnection],
        connectionSourceComplete: Bool = true,
        onFailure: ProjectCatalogFailureHandler? = nil
    ) async -> ProjectProviderTaskCatalog {
        let loaded = await cachedProviderTaskCatalog(connections: connections)
        let catalog = ProjectProviderTaskCatalog(
            lists: loaded.lists,
            sourceComplete: connectionSourceComplete && loaded.sourceComplete
        )
        return catalog
    }

    func rankedModelChoices(
        connection: WorkspaceConnection,
        models: [RuntimeModel]
    ) -> [ProviderModelChoice] {
        let usage = modelUsageRecords()
        return Self.rankModelChoices(models.map { model in
            let record = usage[modelUsageKey(connectionID: connection.id, modelID: model.id)]
            return ProviderModelChoice(
                connection: connection,
                model: model,
                usageCount: record?.count ?? 0,
                lastUsedAt: record?.lastUsedAt
            )
        })
    }

    /// One comparator owns both per-provider sections and the cross-provider
    /// frequent list. Besides keeping frequently used choices first, this
    /// prevents a provider's default model from being alphabetically buried
    /// when the user has no usage history yet.
    static func rankModelChoices(
        _ choices: [ProviderModelChoice]
    ) -> [ProviderModelChoice] {
        choices.sorted { lhs, rhs in
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
            }
            if lhs.model.isDefault != rhs.model.isDefault { return lhs.model.isDefault }
            let modelOrder = lhs.model.displayName.localizedStandardCompare(rhs.model.displayName)
            if modelOrder != .orderedSame { return modelOrder == .orderedAscending }
            let providerOrder = lhs.connection.displayName.localizedStandardCompare(
                rhs.connection.displayName
            )
            if providerOrder != .orderedSame { return providerOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// A provider can transiently publish an empty session while disconnected
    /// or reconnecting. Keep the credential-free saved catalog in that state;
    /// only a non-empty live response is authoritative for the picker.
    static func modelCatalog(
        retaining cached: [RuntimeModel],
        preferring live: [RuntimeModel]?
    ) -> [RuntimeModel] {
        guard let live, !live.isEmpty else { return cached }
        return live
    }

    /// Existing adaptive tasks keep the lane recorded on the task itself. This
    /// projection is used only while rendering that selected task: it makes a
    /// restored agent task read as agent-capable (and a chat-owned task remain
    /// chat-only) without changing the global catalog used to create new tasks.
    static func taskScopedModelCatalog(
        _ models: [RuntimeModel],
        selectedModelID: String?,
        taskCapabilities: RuntimeCapabilities?
    ) -> [RuntimeModel] {
        guard let selectedModelID = selectedModelID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !selectedModelID.isEmpty,
              let taskCapabilities else { return models }
        let executionMode: RuntimeModelExecutionMode = taskCapabilities.contains(.tools)
            ? .agent
            : .chat
        var found = false
        var projected = models.map { model in
            guard model.id == selectedModelID else { return model }
            found = true
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
                executionMode: executionMode,
                taskCapabilities: taskCapabilities
            )
        }
        if !found {
            projected.append(RuntimeModel(
                id: selectedModelID,
                displayName: selectedModelID,
                description: nil,
                isDefault: false,
                defaultReasoningEffort: nil,
                reasoningEfforts: [],
                inputModalities: [.text],
                capabilityEvidence: .unknown,
                executionMode: executionMode,
                taskCapabilities: taskCapabilities
            ))
        }
        return projected
    }

    func recordModelUsage(connectionID: ProviderConnectionID, modelID: String) {
        var records = modelUsageRecords()
        let key = modelUsageKey(connectionID: connectionID, modelID: modelID)
        var record = records[key] ?? ModelUsageRecord(count: 0, lastUsedAt: .distantPast)
        record.count += 1
        record.lastUsedAt = .now
        records[key] = record
        modelUsageCache = records
        if let encoded = try? JSONEncoder().encode(records) {
            defaults.set(encoded, forKey: Self.modelUsagePreferenceKey)
        }
        modelUsageRevision &+= 1
    }

    func modelUsage(
        connectionID: ProviderConnectionID,
        modelID: String
    ) -> (count: Int, lastUsedAt: Date?) {
        let record = modelUsageRecords()[
            modelUsageKey(connectionID: connectionID, modelID: modelID)
        ]
        return (record?.count ?? 0, record?.lastUsedAt)
    }

    private func modelUsageRecords() -> [String: ModelUsageRecord] {
        if let modelUsageCache { return modelUsageCache }
        guard let data = defaults.data(forKey: Self.modelUsagePreferenceKey),
              let records = try? JSONDecoder().decode([String: ModelUsageRecord].self, from: data)
        else {
            modelUsageCache = [:]
            return [:]
        }
        modelUsageCache = records
        return records
    }

    private func modelUsageKey(connectionID: ProviderConnectionID, modelID: String) -> String {
        Data("\(connectionID.rawValue)\u{1f}\(modelID)".utf8).base64EncodedString()
    }

    private func pinnedThreadStore(
        for connectionID: ProviderConnectionID
    ) -> OnyxPinnedThreadStore {
        if let existing = pinnedThreadStores[connectionID] { return existing }
        let created = OnyxPinnedThreadStore(
            defaults: defaults,
            connectionID: connectionID
        )
        pinnedThreadStores[connectionID] = created
        return created
    }

    private static func fallbackModelDescriptor(_ id: String) -> ProviderModelDescriptor? {
        let descriptor = try? ProviderModelDescriptor(
            id: id,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(),
            capabilityEvidence: .unknown
        )
        return descriptor?.applyingKnownModelProfile()
    }

    private static func cachedRuntimeModels(
        for record: ProviderConnectionRecord
    ) -> [RuntimeModel] {
        // A provider can be saved with a manually entered default model before
        // `/models` discovery succeeds (common for a local vLLM endpoint).
        // Retain it for both task selection and delegated work.
        let discovered = record.discovery.discoveredModels.isEmpty
            ? record.discovery.discoveredModelIDs.compactMap(fallbackModelDescriptor)
            : record.discovery.discoveredModels.map { $0.applyingKnownModelProfile() }
        var descriptors = discovered
        if let selectedModelID = record.selectedModelID,
           !descriptors.contains(where: { $0.id == selectedModelID }),
           let fallback = fallbackModelDescriptor(selectedModelID) {
            descriptors.append(fallback)
        }
        return descriptors.enumerated().map { index, descriptor in
            let defaultReasoningEffort = record.requestBehavior.enableThinking == false
                && descriptor.capabilities.reasoningEfforts.contains("none")
                ? "none"
                : descriptor.preferredDefaultReasoningEffort
            return RuntimeModel(
                id: descriptor.id,
                displayName: descriptor.displayName,
                description: descriptor.description,
                isDefault: descriptor.id == record.selectedModelID
                    || (record.selectedModelID == nil && index == 0),
                defaultReasoningEffort: defaultReasoningEffort,
                reasoningEfforts: descriptor.capabilities.reasoningEfforts,
                inputModalities: descriptor.capabilities.inputModalities,
                serverAdvertisedRequestParameters: descriptor.capabilities.supportedParameters,
                supportedRequestParameters: descriptor.capabilities.clientUsableParameters,
                serverAdvertisedCapabilities: descriptor.capabilities.serverAdvertisedCapabilities,
                capabilityEvidence: descriptor.capabilityEvidence
            )
        }
    }

    /// Resolves configured OpenAI-compatible connections in the same
    /// composition root as Codex.  The connection record and credential are
    /// intentionally supplied to the adapter rather than copied into a
    /// registry or UI model.
    private func runtimeCoordinator(
        for connectionID: ProviderConnectionID
    ) -> (coordinator: SharedRuntimeCoordinator?, error: (any Error)?) {
        guard providerRuntimeMutationDepths[connectionID, default: 0] == 0 else {
            return (
                nil,
                AgentRuntimeError.requestFailed(
                    code: -32_101,
                    message: "Provider settings are changing. Reconnect using the current configuration."
                )
            )
        }
        if let existing = runtimeCoordinators[connectionID] {
            return (existing, nil)
        }

        do {
            let runtime: any AgentRuntime
            if registry.connections.contains(where: { $0.id == connectionID }) {
                runtime = try registry.resolve(
                    connectionID,
                    dynamicToolHandler: delegationBroker.scopedHandler(
                        parentConnectionID: connectionID
                    )
                )
            } else {
                runtime = OpenAICompatibleAdaptiveRuntime(
                    connectionID: connectionID,
                    connectionStore: providerConnectionStore,
                    credentialStore: providerCredentialStore,
                    conversationStore: providerConversationStore,
                    stateStore: providerAdaptiveStateStore,
                    dynamicToolHandler: delegationBroker.scopedHandler(
                        parentConnectionID: connectionID
                    )
                )
            }
            let coordinator = SharedRuntimeCoordinator(runtime: runtime)
            runtimeCoordinators[connectionID] = coordinator
            return (coordinator, nil)
        } catch {
            return (nil, error)
        }
    }

    /// Retire before settings mutate. The coordinator remains cached as a
    /// rejecting tombstone while credentials and the durable record change, so
    /// another window cannot create a replacement runtime in the middle of the
    /// two-part transaction.
    private func retireProviderRuntime(for connectionID: ProviderConnectionID) async {
        guard connectionID != defaultConnectionID else { return }
        providerRuntimeMutationDepths[connectionID, default: 0] += 1
        await delegationBroker.invalidate(connectionID: connectionID)
        guard let coordinator = runtimeCoordinators[connectionID] else { return }
        await coordinator.retire()
    }

    /// The settings model calls this on every success or failure path after a
    /// pre-mutation retirement. A later workspace can now resolve one fresh
    /// adapter from the final stored configuration.
    private func evictRetiredProviderRuntime(for connectionID: ProviderConnectionID) {
        guard connectionID != defaultConnectionID else { return }
        let remainingDepth = max(
            0,
            providerRuntimeMutationDepths[connectionID, default: 1] - 1
        )
        if remainingDepth > 0 {
            providerRuntimeMutationDepths[connectionID] = remainingDepth
            return
        }
        providerRuntimeMutationDepths.removeValue(forKey: connectionID)
        runtimeCoordinators.removeValue(forKey: connectionID)
        providerRuntimeRevisions[connectionID, default: 0] &+= 1
        providerRuntimeRevision &+= 1
    }

    func runtimeConfigurationRevision(for connectionID: ProviderConnectionID) -> UInt64 {
        providerRuntimeRevisions[connectionID, default: 0]
    }

    #if DEBUG
    func cachedRuntimeCoordinatorForTesting(
        _ connectionID: ProviderConnectionID
    ) -> SharedRuntimeCoordinator? {
        runtimeCoordinators[connectionID]
    }

    func beginProviderRuntimeMutationForTesting(
        _ connectionID: ProviderConnectionID
    ) async {
        await retireProviderRuntime(for: connectionID)
    }

    func endProviderRuntimeMutationForTesting(
        _ connectionID: ProviderConnectionID
    ) {
        evictRetiredProviderRuntime(for: connectionID)
    }
    #endif
}

@MainActor
private final class OnyxWindowReference: ObservableObject {
    weak var window: NSWindow?
}

/// Owns one `OnyxAppModel` and one terminal/view tree for exactly one restored
/// window. Closing the scene releases those objects without affecting siblings.
struct OnyxWindowRootView: View {
    let windowID: WorkspaceWindowID

    @StateObject private var windowReference: OnyxWindowReference
    @ObservedObject private var providerSettingsModel: ProviderSettingsModel
    @State private var selection: ProviderWorkspaceSelection
    @State private var catalogRefreshRevision: UInt64 = 0
    @ObservedObject private var host: OnyxApplicationHost
    private let defaults: UserDefaults

    @MainActor
    init(windowID: WorkspaceWindowID, host: OnyxApplicationHost) {
        self.windowID = windowID
        _windowReference = StateObject(wrappedValue: OnyxWindowReference())
        _providerSettingsModel = ObservedObject(wrappedValue: host.providerSettingsModel)
        _selection = State(initialValue: ProviderWorkspaceSelection(
            windowID: windowID,
            model: host.makeWindowModel(for: windowID),
            connectionID: host.selectedConnectionID(for: windowID),
            runtimeRevision: host.runtimeConfigurationRevision(
                for: host.selectedConnectionID(for: windowID)
            ),
            availableConnections: []
        ))
        _host = ObservedObject(wrappedValue: host)
        defaults = host.defaults
    }

    var body: some View {
        ProviderWorkspaceContent(
            selection: $selection,
            host: host,
            defaults: defaults,
            windowReference: windowReference
        )
        .frame(minWidth: WorkspacePaneLayout.minimumWindowWidth, minHeight: 620)
        .background(
            OnyxWindowConfigurator(
                windowID: windowID,
                windowReference: windowReference
            )
        )
        .task(id: ProviderWorkspaceCatalogRefreshIdentity(
            connections: providerSettingsModel.connections,
            runtimeRevision: host.providerRuntimeRevision
        )) {
            await refreshWorkspaceCatalogs()
        }
        .onDisappear { selection.model.flushWindowState() }
    }

    @MainActor
    private func replaceSelection(with connectionID: ProviderConnectionID) {
        host.selectConnection(connectionID, for: selection.windowID)
        let replacementModel = host.makeWindowModel(
            for: WorkspaceWindowID(
                rawValue: selection.windowID.rawValue,
                providerConnectionID: host.sceneProviderConnectionID(for: connectionID)
            ),
            startsWithNewTask: true
        )
        OnyxApplicationHost.transferNewTaskContext(from: selection.model, to: replacementModel)
        selection = ProviderWorkspaceSelection(
            windowID: selection.windowID,
            model: replacementModel,
            connectionID: connectionID,
            runtimeRevision: host.runtimeConfigurationRevision(for: connectionID),
            availableConnections: selection.availableConnections,
            modelCatalogs: selection.modelCatalogs,
            pendingThreadID: nil,
            pendingThreadScope: nil
        )
    }

    @MainActor
    private func refreshWorkspaceCatalogs() async {
        guard !Task.isCancelled else { return }
        catalogRefreshRevision &+= 1
        let refreshRevision = catalogRefreshRevision

        // A provider mutation permanently retires the old coordinator. Rebind
        // the visible window before any store or history work can suspend so
        // Save never leaves the composer attached to a tombstone while an
        // unrelated catalog refresh finishes.
        let currentRuntimeRevision = host.runtimeConfigurationRevision(
            for: selection.connectionID
        )
        if currentRuntimeRevision != selection.runtimeRevision {
            let validated = host.validatedSelection(
                for: selection.windowID,
                availableConnections: host.publishedWorkspaceConnections()
            )
            if validated == selection.connectionID {
                replaceRetiredRuntime(revision: currentRuntimeRevision)
            } else {
                replaceSelection(with: validated)
            }
            return
        }

        async let connectionCatalog = host.workspaceConnectionCatalog()
        async let catalogs = host.cachedProviderModelCatalogs()
        let (loadedConnectionCatalog, loadedCatalogs) = await (connectionCatalog, catalogs)
        guard !Task.isCancelled,
              catalogRefreshRevision == refreshRevision else { return }
        let loadedConnections = loadedConnectionCatalog.connections

        // Publish provider/model choices before loading the complete task
        // catalog. Codex history can require several paginated app-server
        // requests; making the picker wait for that unrelated work meant a
        // newly saved vLLM model looked unavailable until the sidebar refresh
        // happened to finish.
        selection.availableConnections = loadedConnections
        host.projectCatalogModel.retainTaskLists(
            for: Set(loadedConnections.map(\.id))
        )
        selection.modelCatalogs = selection.modelCatalogs.filter { connectionID, _ in
            loadedConnections.contains(where: { $0.id == connectionID })
        }
        selection.modelCatalogs.merge(loadedCatalogs) { _, persisted in persisted }
        selection.modelCatalogs[selection.connectionID] = OnyxApplicationHost.modelCatalog(
            retaining: selection.modelCatalogs[selection.connectionID] ?? [],
            preferring: selection.model.session?.availableModels
        )
        selection.modelRankingRevision &+= 1
        let validated = host.validatedSelection(
            for: selection.windowID,
            availableConnections: loadedConnections
        )
        if validated != selection.connectionID {
            replaceSelection(with: validated)
            return
        }
        let loadedRuntimeRevision = host.runtimeConfigurationRevision(
            for: selection.connectionID
        )
        if loadedRuntimeRevision != selection.runtimeRevision {
            replaceRetiredRuntime(revision: loadedRuntimeRevision)
            return
        }
        if ProviderTaskCatalogSynchronizationPolicy.shouldReplaceCachedTasks(
            connectionState: selection.model.connectionState,
            isLoadingThreadList: selection.model.isLoadingThreadList,
            hasAuthoritativeThreadList: selection.model
                .hasAuthoritativeThreadListForCurrentScope,
            hasUnlistedSelectedTask: selection.model.hasUnlistedSelectedTask
        ),
           let currentConnection = loadedConnections.first(where: {
               $0.id == selection.connectionID
           }) {
            host.projectCatalogModel.replaceTasks(
                for: currentConnection.id,
                providerDisplayName: currentConnection.displayName,
                scope: selection.model.threadListScope,
                threads: selection.model.catalogThreads
            )
        }
        let cachedTaskCatalog = await host.loadProviderTaskCatalog(
            connections: loadedConnections,
            connectionSourceComplete: loadedConnectionCatalog.sourceComplete
        )
        guard !Task.isCancelled,
              catalogRefreshRevision == refreshRevision else { return }
        let protectedTask = selection.model.hasUnlistedSelectedTask
            ? selection.model.selectedThreadID.map { threadID in
                ProjectProviderTaskProtection(
                    id: ProjectTaskReference.ID(
                        providerConnectionID: selection.connectionID,
                        threadID: threadID
                    ),
                    scope: selection.model.threadListScope
                )
            }
            : nil
        host.projectCatalogModel.replaceTasks(
            from: cachedTaskCatalog.lists,
            preserving: protectedTask
        )
    }

    @MainActor
    private func replaceRetiredRuntime(revision: UInt64) {
        let replacementModel = host.makeRuntimeReplacementWindowModel(
            for: WorkspaceWindowID(
                rawValue: selection.windowID.rawValue,
                providerConnectionID: host.sceneProviderConnectionID(for: selection.connectionID)
            ),
            replacing: selection.model
        )
        selection = ProviderWorkspaceSelection(
            windowID: selection.windowID,
            model: replacementModel,
            connectionID: selection.connectionID,
            runtimeRevision: revision,
            availableConnections: selection.availableConnections,
            modelCatalogs: selection.modelCatalogs,
            pendingModelID: selection.pendingModelID,
            pendingThreadID: selection.pendingThreadID,
            pendingThreadScope: selection.pendingThreadScope
        )
    }
}

private struct ProviderWorkspaceCatalogRefreshIdentity: Hashable {
    let connections: [ProviderConnectionRecord]
    let runtimeRevision: UInt64
}

/// Provider selection is window-scoped. Replacing this small container creates
/// a model bound to the chosen provider while leaving every existing task in
/// its original provider-specific model and preference namespace.
@MainActor
private struct ProviderWorkspaceSelection {
    let windowID: WorkspaceWindowID
    var model: OnyxAppModel
    var connectionID: ProviderConnectionID
    var runtimeRevision: UInt64 = 0
    var availableConnections: [OnyxApplicationHost.WorkspaceConnection]
    var modelCatalogs: [ProviderConnectionID: [RuntimeModel]] = [:]
    /// Changes only when the provider/model-picker inputs change. Keeping a
    /// scalar key avoids deep dictionary/array comparisons during every
    /// streamed transcript publication.
    var modelRankingRevision: UInt64 = 0
    var pendingModelID: String?
    var pendingThreadID: String?
    var pendingThreadScope: ThreadListScope?
}

private struct ProviderWorkspaceContent: View {
    @Binding var selection: ProviderWorkspaceSelection
    @ObservedObject private var model: OnyxAppModel
    @ObservedObject private var host: OnyxApplicationHost
    @State private var rankedModelChoices: [OnyxApplicationHost.ProviderModelChoice]
    let defaults: UserDefaults
    let windowReference: OnyxWindowReference

    init(
        selection: Binding<ProviderWorkspaceSelection>,
        host: OnyxApplicationHost,
        defaults: UserDefaults,
        windowReference: OnyxWindowReference
    ) {
        _selection = selection
        _model = ObservedObject(wrappedValue: selection.wrappedValue.model)
        _host = ObservedObject(wrappedValue: host)
        _rankedModelChoices = State(initialValue: Self.makeRankedModelChoices(
            host: host,
            selection: selection.wrappedValue,
            liveModels: selection.wrappedValue.model.session?.availableModels
        ))
        self.host = host
        self.defaults = defaults
        self.windowReference = windowReference
    }

    var body: some View {
        OnyxWorkspaceView(
            model: model,
            preferenceKeyPrefix: ProviderWorkspaceShellIdentity.preferenceKeyPrefix(
                for: selection.windowID
            ),
            defaults: defaults,
            projectCatalog: host.projectCatalogModel,
            windowProvider: { windowReference.window },
            providerConnections: selection.availableConnections,
            selectedProviderConnectionID: selection.connectionID,
            onSelectProviderConnection: selectProvider,
            rankedModelChoices: rankedModelChoices,
            onSelectProviderModel: selectProviderModel,
            onSelectProviderTask: selectProviderTask
        )
        // Provider task navigation replaces the runtime-bound model, not the
        // window's workspace shell. A window-stable identity preserves the
        // sidebar projection, scroll position, and disclosure state while the
        // destination provider connects behind it.
        .id(ProviderWorkspaceShellIdentity.id(for: selection.windowID))
        .task(id: ProviderWorkspaceRuntimeIdentity(
            connectionID: selection.connectionID,
            runtimeRevision: selection.runtimeRevision
        )) {
            model.start()
        }
        .onChange(of: model.session?.availableModels) { _, models in
            let values = OnyxApplicationHost.modelCatalog(
                retaining: selection.modelCatalogs[selection.connectionID] ?? [],
                preferring: models
            )
            selection.modelCatalogs[selection.connectionID] = values
            selection.modelRankingRevision &+= 1
            guard let pending = selection.pendingModelID,
                  values.contains(where: { $0.id == pending }) else { return }
            selection.model.selectModel(pending)
            selection.pendingModelID = nil
        }
        .onChange(of: selection.modelRankingRevision) { _, _ in
            refreshRankedModelChoices(liveModels: model.session?.availableModels)
        }
        .onChange(of: host.modelUsageRevision) { _, _ in
            refreshRankedModelChoices(liveModels: model.session?.availableModels)
        }
        .onChange(of: model.selectedThreadID) { _, _ in
            // A merged sidebar can switch between chat- and agent-owned
            // tasks without replacing this provider workspace. Rebuild the
            // picker when that happens so taskScopedModelCatalog projects
            // the selected task's durable execution lane (and can re-add a
            // model that is no longer present in the provider catalog).
            selection.modelRankingRevision &+= 1
        }
        .onChange(of: model.threadListRevision) { _, _ in
            selectPendingThreadIfAvailable()
        }
        .onChange(of: model.selectedThread?.taskCapabilities) { _, _ in
            // Selecting a merged task can initially use the sidebar's cached
            // row. The authoritative direct read then publishes a new thread
            // snapshot with its durable chat/agent capabilities. Rebuild the
            // picker for that update too; otherwise a task that was briefly
            // capability-unknown can leave the model menu on the new-task
            // catalog after its agent lane is known. Observe only this small
            // task-scoped value rather than every lifecycle/status list update.
            selection.modelRankingRevision &+= 1
        }
        .onChange(of: model.selectedTaskModelID) { _, _ in
            // A direct task read can also fill in the provider-recorded model
            // after the sidebar's cached row was selected. Reproject the
            // selected model without rebuilding on unrelated task updates.
            selection.modelRankingRevision &+= 1
        }
        .onChange(of: model.isLoadingThreadList) { _, _ in
            selectPendingThreadIfAvailable()
        }
        .onChange(of: model.connectionState) { _, _ in
            preparePendingThreadScopeIfPossible()
        }
    }

    private var providerWindowID: WorkspaceWindowID {
        WorkspaceWindowID(
            rawValue: selection.windowID.rawValue,
            providerConnectionID: host.sceneProviderConnectionID(for: selection.connectionID)
        )
    }

    @MainActor
    private func selectProvider(_ connectionID: ProviderConnectionID) {
        guard connectionID != selection.connectionID,
              selection.model.selectedThreadID == nil
                || selection.model.selectedThreadID == "onyx:welcome"
        else { return }
        replaceSelection(with: connectionID)
    }

    @MainActor
    private func refreshRankedModelChoices(liveModels: [RuntimeModel]?) {
        rankedModelChoices = Self.makeRankedModelChoices(
            host: host,
            selection: selection,
            liveModels: liveModels
        )
    }

    @MainActor
    private static func makeRankedModelChoices(
        host: OnyxApplicationHost,
        selection: ProviderWorkspaceSelection,
        liveModels: [RuntimeModel]?
    ) -> [OnyxApplicationHost.ProviderModelChoice] {
        var catalogs = selection.modelCatalogs
        catalogs[selection.connectionID] = OnyxApplicationHost.modelCatalog(
            retaining: catalogs[selection.connectionID] ?? [],
            preferring: liveModels
        )
        catalogs[selection.connectionID] = OnyxApplicationHost.taskScopedModelCatalog(
            catalogs[selection.connectionID] ?? [],
            selectedModelID: selection.model.selectedTaskModelID,
            taskCapabilities: selection.model.selectedThread?.taskCapabilities
        )
        return OnyxApplicationHost.rankModelChoices(
            selection.availableConnections.flatMap { connection in
                host.rankedModelChoices(
                    connection: connection,
                    models: catalogs[connection.id] ?? []
                )
            }
        )
    }

    @MainActor
    private func selectProviderModel(_ choice: OnyxApplicationHost.ProviderModelChoice) {
        guard choice.connection.id == selection.connectionID else {
            replaceSelection(with: choice.connection.id, pendingModelID: choice.model.id)
            return
        }
        model.selectModel(choice.model.id)
        selection.modelCatalogs[choice.connection.id] = OnyxApplicationHost.modelCatalog(
            retaining: selection.modelCatalogs[choice.connection.id] ?? [],
            preferring: model.session?.availableModels
        )
        selection.modelRankingRevision &+= 1
    }

    @MainActor
    private func selectProviderTask(
        _ connectionID: ProviderConnectionID,
        threadID: String,
        scope: ThreadListScope
    ) {
        let plan = ProviderTaskNavigationPlan.resolve(
            selectingConnectionID: connectionID,
            threadID: threadID,
            scope: scope,
            currentConnectionID: selection.connectionID,
            currentScope: model.threadListScope
        )
        switch plan.action {
        case .selectCurrentThread:
            // Assign the complete plan before selecting. For a direct click
            // both values are nil, which cancels an older provider/scope
            // destination before its late task-list completion can reopen it.
            selection.pendingThreadID = plan.pendingThreadID
            selection.pendingThreadScope = plan.pendingThreadScope
            model.selectThread(threadID)
        case .changeCurrentScope:
            selection.pendingThreadID = plan.pendingThreadID
            selection.pendingThreadScope = plan.pendingThreadScope
            model.setThreadListScope(scope)
        case .replaceProvider:
            replaceSelection(
                with: connectionID,
                pendingThreadID: plan.pendingThreadID,
                pendingThreadScope: plan.pendingThreadScope
            )
        }
    }

    @MainActor
    private func selectPendingThreadIfAvailable() {
        guard let pendingThreadID = selection.pendingThreadID,
              selection.pendingThreadScope?.rawValue == model.threadListScope.rawValue,
              !model.isLoadingThreadList,
              case .connected = model.connectionState
        else { return }
        selection.pendingThreadID = nil
        selection.pendingThreadScope = nil
        // A complete catalog normally contains the ID, but a provider can
        // still return a partial list during reconnect. `selectThread` is
        // intentionally able to read an ID that is absent from the list and
        // insert the authoritative thread returned by `readThread`; this is
        // what lets cached rows beyond a provider's first page open normally.
        model.selectThread(pendingThreadID)
    }

    @MainActor
    private func preparePendingThreadScopeIfPossible() {
        guard selection.pendingThreadID != nil,
              let pendingScope = selection.pendingThreadScope,
              case .connected = model.connectionState
        else { return }
        if pendingScope.rawValue != model.threadListScope.rawValue {
            model.setThreadListScope(pendingScope)
        } else {
            selectPendingThreadIfAvailable()
        }
    }

    @MainActor
    private func replaceSelection(
        with connectionID: ProviderConnectionID,
        pendingModelID: String? = nil,
        pendingThreadID: String? = nil,
        pendingThreadScope: ThreadListScope? = nil
    ) {
        host.selectConnection(connectionID, for: selection.windowID)
        let replacementModel = host.makeWindowModel(
            for: WorkspaceWindowID(
                rawValue: selection.windowID.rawValue,
                providerConnectionID: host.sceneProviderConnectionID(for: connectionID)
            ),
            startsWithNewTask: pendingThreadID == nil
        )
        if let pendingModelID {
            replacementModel.selectModel(pendingModelID)
        }
        OnyxApplicationHost.transferNewTaskContext(from: model, to: replacementModel)
        selection = ProviderWorkspaceSelection(
            windowID: selection.windowID,
            model: replacementModel,
            connectionID: connectionID,
            runtimeRevision: host.runtimeConfigurationRevision(for: connectionID),
            availableConnections: selection.availableConnections,
            modelCatalogs: selection.modelCatalogs,
            pendingModelID: nil,
            pendingThreadID: pendingThreadID,
            pendingThreadScope: pendingThreadScope
        )
    }
}

private struct ProviderWorkspaceRuntimeIdentity: Hashable {
    let connectionID: ProviderConnectionID
    let runtimeRevision: UInt64
}

struct ProviderTaskNavigationPlan: Equatable {
    enum Action: Equatable {
        case selectCurrentThread
        case changeCurrentScope
        case replaceProvider
    }

    let action: Action
    let pendingThreadID: String?
    let pendingThreadScope: ThreadListScope?

    static func resolve(
        selectingConnectionID: ProviderConnectionID,
        threadID: String,
        scope: ThreadListScope,
        currentConnectionID: ProviderConnectionID,
        currentScope: ThreadListScope
    ) -> Self {
        guard selectingConnectionID == currentConnectionID else {
            return Self(
                action: .replaceProvider,
                pendingThreadID: threadID,
                pendingThreadScope: scope
            )
        }
        guard scope.rawValue == currentScope.rawValue else {
            return Self(
                action: .changeCurrentScope,
                pendingThreadID: threadID,
                pendingThreadScope: scope
            )
        }
        return Self(
            action: .selectCurrentThread,
            pendingThreadID: nil,
            pendingThreadScope: nil
        )
    }
}

enum ProviderWorkspaceShellIdentity {
    static func id(for windowID: WorkspaceWindowID) -> UUID {
        windowID.rawValue
    }

    /// Pane geometry belongs to the retained window shell, not the runtime
    /// currently displayed inside it. Keeping the defaults namespace stable
    /// prevents a provider switch from restoring or later persisting a
    /// different sidebar, inspector, or terminal size.
    static func preferenceKeyPrefix(for windowID: WorkspaceWindowID) -> String {
        windowID.preferenceKeyPrefix
    }
}

private struct OnyxWindowConfigurator: NSViewRepresentable {
    let windowID: WorkspaceWindowID
    let windowReference: OnyxWindowReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    @MainActor
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        windowReference.window = window
        // Keep the native transcript/composer aligned with the SwiftUI dark
        // baseline. This is explicit because dynamic NSColor values otherwise
        // follow the user's system appearance independently of the root view.
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: WorkspacePaneLayout.minimumWindowWidth, height: 620)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName(windowID.frameAutosaveName)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
