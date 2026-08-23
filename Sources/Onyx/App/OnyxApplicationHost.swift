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
    /// Changes only after an accepted turn is attributed to a model. Views
    /// observe this narrow signal to refresh the picker once, instead of
    /// rebuilding rankings for every streamed transcript publication.
    @Published private(set) var modelUsageRevision: UInt64 = 0

    private let registry: RuntimeRegistry
    private let defaultConnectionID: ProviderConnectionID
    private let providerConnectionStore: ProviderConnectionStore
    private let providerCredentialStore: any CredentialStore
    private let providerConversationStore: OpenAICompatibleConversationStore
    private var runtimeCoordinators: [ProviderConnectionID: SharedRuntimeCoordinator]
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
        providerConversationStore: OpenAICompatibleConversationStore = OpenAICompatibleConversationStore()
    ) {
        self.registry = registry
        self.defaultConnectionID = connectionID
        self.providerConnectionStore = providerConnectionStore
        self.providerCredentialStore = providerCredentialStore
        self.providerConversationStore = providerConversationStore
        let coordinator: SharedRuntimeCoordinator?
        let resolutionError: (any Error)?
        do {
            coordinator = SharedRuntimeCoordinator(runtime: try registry.resolve(connectionID))
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
        providerSettingsModel.onConnectionMutation = { [weak self] connectionID in
            self?.invalidateProviderRuntime(for: connectionID)
        }
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
        var values = [
            WorkspaceConnection(
                id: defaultConnectionID,
                displayName: "Codex",
                isCodex: true
            ),
        ]
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

    /// Returns credential-free cached catalogs for every configured provider.
    /// This is deliberately read without connecting any runtime, so opening a
    /// model menu never fans out network requests or provider processes.
    func cachedProviderModelCatalogs() async -> [ProviderConnectionID: [RuntimeModel]] {
        guard let records = try? await providerConnectionStore.connections() else { return [:] }
        return Dictionary(uniqueKeysWithValues: records.map { record in
            // A provider can be saved with a manually entered default model
            // before `/models` discovery succeeds (common for a local vLLM
            // endpoint). Keep that model visible in the workspace picker so
            // the user can start a task and retry discovery later. IDs from
            // older records are retained as a second fallback as well.
            let discovered = record.discovery.discoveredModels.isEmpty
                ? record.discovery.discoveredModelIDs.compactMap(Self.fallbackModelDescriptor)
                : record.discovery.discoveredModels
            var descriptors = discovered
            if let selectedModelID = record.selectedModelID,
               !descriptors.contains(where: { $0.id == selectedModelID }),
               let fallback = Self.fallbackModelDescriptor(selectedModelID) {
                descriptors.append(fallback)
            }
            let models = descriptors.enumerated().map { index, descriptor in
                RuntimeModel(
                    id: descriptor.id,
                    displayName: descriptor.displayName,
                    description: descriptor.description,
                    isDefault: descriptor.id == record.selectedModelID
                        || (record.selectedModelID == nil && index == 0),
                    defaultReasoningEffort: descriptor.capabilities.reasoningEfforts.first,
                    reasoningEfforts: descriptor.capabilities.reasoningEfforts,
                    inputModalities: descriptor.capabilities.inputModalities,
                    serverAdvertisedRequestParameters: descriptor.capabilities.supportedParameters,
                    supportedRequestParameters: descriptor.capabilities.clientUsableParameters,
                    serverAdvertisedCapabilities: descriptor.capabilities.serverAdvertisedCapabilities,
                    capabilityEvidence: descriptor.capabilityEvidence
                )
            }
            return (record.id, models)
        })
    }

    /// Loads the complete task catalog for every configured connection. The
    /// returned `sourceComplete` bit is intentionally separate from the lists:
    /// a partial snapshot is still useful to paint the sidebar, but must never
    /// be used to commit the one-time legacy project migration marker.
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

            let providerRecord = try? await providerConnectionStore.connection(id: connection.id)
            let conversationScopeID = providerRecord?.conversationScopeID
                ?? ProviderConnectionRecord.legacyConversationScopeID(for: connection.id)
            // Local provider transcripts created by older builds have no
            // scope marker. Migrate them before filtering so they remain
            // visible on the first launch, while later endpoint/credential
            // rotations keep the old scope isolated.
            if let providerRecord {
                _ = try? await providerConversationStore.migrateLegacyConversations(
                    connectionID: connection.id,
                    to: providerRecord.conversationScopeID
                )
            }
            for scope in ThreadListScope.allCases {
                do {
                    let conversations = try await providerConversationStore.conversations(
                        connectionID: connection.id,
                        scopeID: conversationScopeID,
                        archived: scope == .archived,
                        // Local provider history is already on disk. Do not
                        // apply the remote UI page size to this complete
                        // source; otherwise projects/tasks after row 100 vanish.
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
        }

        return ProjectProviderTaskCatalog(
            lists: lists,
            sourceComplete: sourceComplete
        )
    }

    /// Compatibility projection for callers that only need sidebar lists.
    /// Production startup uses `loadProviderTaskCatalog` below so migration
    /// can distinguish a complete source from a partial rendering snapshot.
    func cachedProviderTaskLists(
        connections: [WorkspaceConnection]
    ) async -> [ProjectProviderTaskList] {
        await cachedProviderTaskCatalog(connections: connections).lists
    }

    /// Loads provider tasks and, only when every source succeeded, performs
    /// the one-time migration from task working folders into the durable
    /// project catalog. Keeping this boundary in the composition host makes
    /// the behavior identical for every restored workspace window.
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
        guard catalog.sourceComplete else { return catalog }
        _ = await projectCatalogModel.importTaskProjectsIfSourceComplete(
            from: catalog,
            onFailure: onFailure
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
        try? ProviderModelDescriptor(
            id: id,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(),
            capabilityEvidence: .unknown
        )
    }

    /// Resolves configured OpenAI-compatible connections in the same
    /// composition root as Codex.  The connection record and credential are
    /// intentionally supplied to the adapter rather than copied into a
    /// registry or UI model.
    private func runtimeCoordinator(
        for connectionID: ProviderConnectionID
    ) -> (coordinator: SharedRuntimeCoordinator?, error: (any Error)?) {
        if let existing = runtimeCoordinators[connectionID] {
            return (existing, nil)
        }

        do {
            let runtime: any AgentRuntime
            if registry.connections.contains(where: { $0.id == connectionID }) {
                runtime = try registry.resolve(connectionID)
            } else {
                runtime = OpenAICompatibleRuntime(
                    connectionID: connectionID,
                    connectionStore: providerConnectionStore,
                    credentialStore: providerCredentialStore,
                    conversationStore: providerConversationStore
                )
            }
            let coordinator = SharedRuntimeCoordinator(runtime: runtime)
            runtimeCoordinators[connectionID] = coordinator
            return (coordinator, nil)
        } catch {
            return (nil, error)
        }
    }

    /// A settings edit or deletion invalidates the endpoint, credential, and
    /// capability snapshot captured by a live OpenAI-compatible runtime. Drop
    /// it from the cache synchronously so the next workspace gets a fresh
    /// adapter, then disconnect the old coordinator so already-open windows
    /// cannot keep using the stale or deleted provider configuration.
    private func invalidateProviderRuntime(for connectionID: ProviderConnectionID) {
        guard connectionID != defaultConnectionID,
              let coordinator = runtimeCoordinators.removeValue(forKey: connectionID)
        else { return }
        Task { await coordinator.disconnect() }
    }

    #if DEBUG
    func cachedRuntimeCoordinatorForTesting(
        _ connectionID: ProviderConnectionID
    ) -> SharedRuntimeCoordinator? {
        runtimeCoordinators[connectionID]
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
    private let host: OnyxApplicationHost
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
            availableConnections: []
        ))
        self.host = host
        defaults = host.defaults
    }

    var body: some View {
        ProviderWorkspaceContent(
            selection: $selection,
            host: host,
            defaults: defaults,
            windowReference: windowReference
        )
        .frame(minWidth: 860, minHeight: 620)
        .background(
            OnyxWindowConfigurator(
                windowID: windowID,
                windowReference: windowReference
            )
        )
        .task(id: providerSettingsModel.connections) {
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
        if case .connected = selection.model.connectionState,
           !selection.model.isLoadingThreadList,
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
        let validated = host.validatedSelection(
            for: selection.windowID,
            availableConnections: loadedConnections
        )
        if validated != selection.connectionID {
            replaceSelection(with: validated)
        }

        let cachedTaskCatalog = await host.loadProviderTaskCatalog(
            connections: loadedConnections,
            connectionSourceComplete: loadedConnectionCatalog.sourceComplete
        )
        guard !Task.isCancelled,
              catalogRefreshRevision == refreshRevision else { return }
        for list in cachedTaskCatalog.lists {
            host.projectCatalogModel.replaceTasks(
                for: list.providerConnectionID,
                providerDisplayName: list.providerDisplayName,
                scope: list.scope,
                threads: list.threads
            )
        }
    }
}

/// Provider selection is window-scoped. Replacing this small container creates
/// a model bound to the chosen provider while leaving every existing task in
/// its original provider-specific model and preference namespace.
@MainActor
private struct ProviderWorkspaceSelection {
    let windowID: WorkspaceWindowID
    var model: OnyxAppModel
    var connectionID: ProviderConnectionID
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
            preferenceKeyPrefix: providerWindowID.providerPreferenceKeyPrefix(),
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
        .id(selection.connectionID)
        .task(id: selection.connectionID) {
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
        .onChange(of: model.threadListRevision) { _, _ in
            selectPendingThreadIfAvailable()
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
        threadID: String
    ) {
        guard connectionID != selection.connectionID else {
            model.selectThread(threadID)
            return
        }
        replaceSelection(
            with: connectionID,
            pendingThreadID: threadID,
            pendingThreadScope: model.threadListScope
        )
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
            availableConnections: selection.availableConnections,
            modelCatalogs: selection.modelCatalogs,
            pendingModelID: nil,
            pendingThreadID: pendingThreadID,
            pendingThreadScope: pendingThreadScope
        )
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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 860, height: 620)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName(windowID.frameAutosaveName)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
