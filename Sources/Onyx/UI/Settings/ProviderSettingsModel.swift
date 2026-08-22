import Foundation

/// The narrow seam used by the provider settings screen to exercise an
/// endpoint without coupling the form to URLSession. Production uses
/// `URLSessionProviderModelDiscovery`; tests and previews can inject a small
/// deterministic implementation instead.
protocol ProviderModelDiscovery: Sendable {
    func discoverModels(
        for connection: ProviderConnectionRecord,
        credential: ProviderBearerCredential?
    ) async throws -> [ProviderModelDescriptor]
}

enum ProviderModelDiscoveryError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case insecureEndpoint
    case insecureBearerCredential
    case invalidCredential
    case invalidHTTPResponse
    case httpFailure(statusCode: Int)
    case malformedResponse
    case noModels
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The provider URL is not a valid HTTP(S) endpoint."
        case .insecureEndpoint:
            "Clear-text HTTP is allowed only after acknowledgement and only for a literal loopback, private-network, or link-local IP address. Use HTTPS for hostnames and public IPs."
        case .insecureBearerCredential:
            "Bearer credentials cannot be sent over clear-text HTTP. Use HTTPS or choose No authentication."
        case .invalidCredential:
            "The API bearer token cannot be sent to this endpoint."
        case .invalidHTTPResponse:
            "The provider returned a response that was not HTTP."
        case let .httpFailure(statusCode):
            "The provider returned HTTP \(statusCode) while testing the connection."
        case .malformedResponse:
            "The provider returned an unreadable model catalog."
        case .noModels:
            "The provider responded, but did not advertise any usable models."
        case .networkFailure:
            "Onyx could not reach the provider endpoint. Check the URL and network connection."
        }
    }
}

/// Generic OpenAI-compatible `/models` discovery. It deliberately accepts
/// only the typed credential container and never logs response bodies or
/// authorization material.
struct URLSessionProviderModelDiscovery: ProviderModelDiscovery, Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeDefaultSession()
    }

    func discoverModels(
        for connection: ProviderConnectionRecord,
        credential: ProviderBearerCredential?
    ) async throws -> [ProviderModelDescriptor] {
        let endpoint = try Self.modelsURL(for: connection)
        if endpoint.scheme?.lowercased() == "http", credential != nil {
            // A credential may arrive here from an older caller even when the
            // record says `none`; reject it before constructing a request so a
            // clear-text connection can never accidentally carry a bearer
            // header.
            throw ProviderModelDiscoveryError.insecureBearerCredential
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let credential {
            let token = try credential.withValue { $0 }
            guard !token.isEmpty,
                  !token.contains(where: { $0.isNewline || $0 == "\0" })
            else {
                // Keep this error intentionally generic. The actual token is
                // never included in a user-facing error or diagnostic.
                throw ProviderModelDiscoveryError.invalidCredential
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // URLSession follows redirects by default. Re-wrap the injected
        // session with the same configuration plus the provider redirect
        // policy so discovery cannot silently leave its validated endpoint.
        let protectedSession = ProviderRedirectProtectedSession(
            wrapping: session,
            transportSecurity: connection.transportSecurity,
            hasBearerCredential: credential != nil
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await protectedSession.session.data(for: request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProviderModelDiscoveryError.networkFailure
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderModelDiscoveryError.invalidHTTPResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ProviderModelDiscoveryError.httpFailure(statusCode: http.statusCode)
        }

        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ProviderModelDiscoveryError.malformedResponse
        }

        let models = ProviderModelDescriptor.openRouterCatalog(from: root)
        guard !models.isEmpty else {
            throw ProviderModelDiscoveryError.noModels
        }
        return models.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func modelsURL(for connection: ProviderConnectionRecord) throws -> URL {
        let baseURL = connection.baseURL
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = baseURL.host,
              !host.isEmpty,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil
        else {
            throw ProviderModelDiscoveryError.invalidEndpoint
        }

        if scheme == "http" {
            guard ProviderBaseURLNormalizer.isAllowedInsecureHTTPHost(host),
                  connection.transportSecurity == .allowInsecureHTTP
            else {
                throw ProviderModelDiscoveryError.insecureEndpoint
            }
            guard connection.authMode != .bearer else {
                throw ProviderModelDiscoveryError.insecureBearerCredential
            }
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ProviderModelDiscoveryError.invalidEndpoint
        }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        }
        if path.isEmpty || path == "/" {
            path = "/models"
        } else {
            path += "/models"
        }
        components.percentEncodedPath = path
        guard let url = components.url else {
            throw ProviderModelDiscoveryError.invalidEndpoint
        }
        return url
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }
}

/// A form-only draft. Unlike `ProviderConnectionRecord`, this type is never
/// encoded or sent to UserDefaults. `bearerToken` exists only while the user
/// is editing and is written exclusively through `CredentialStore`.
struct ProviderConnectionDraft: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: ProviderConnectionID
    var displayName: String
    var baseURL: String
    var selectedModelID: String
    var authMode: ProviderConnectionAuthMode
    var allowInsecureHTTP: Bool
    var enableThinking: Bool
    var bearerToken: String
    var removeStoredCredential: Bool
    var hasStoredCredential: Bool
    var discoveredModelIDs: [String]
    var discovery: ProviderConnectionDiscoveryMetadata

    var identity: ProviderConnectionID { id }

    /// Never include the transient bearer value in diagnostics or previews.
    var description: String { redactedDescription }
    var debugDescription: String { redactedDescription }

    private var redactedDescription: String {
        "ProviderConnectionDraft(id: \(id), displayName: \(trimmedDisplayName), hasBaseURL: \(!trimmedBaseURL.isEmpty), authMode: \(authMode.rawValue), hasBearerToken: \(!bearerToken.isEmpty || hasStoredCredential))"
    }

    init(
        id: ProviderConnectionID = ProviderConnectionID("provider.\(UUID().uuidString.lowercased())"),
        displayName: String = "",
        baseURL: String = "",
        selectedModelID: String = "",
        authMode: ProviderConnectionAuthMode = .none,
        allowInsecureHTTP: Bool = false,
        enableThinking: Bool = false,
        bearerToken: String = "",
        removeStoredCredential: Bool = false,
        hasStoredCredential: Bool = false,
        discoveredModelIDs: [String] = [],
        discovery: ProviderConnectionDiscoveryMetadata = .init()
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.selectedModelID = selectedModelID
        self.authMode = authMode
        self.allowInsecureHTTP = allowInsecureHTTP
        self.enableThinking = enableThinking
        self.bearerToken = bearerToken
        self.removeStoredCredential = removeStoredCredential
        self.hasStoredCredential = hasStoredCredential
        self.discoveredModelIDs = discoveredModelIDs
        self.discovery = discovery
    }

    init(
        connection: ProviderConnectionRecord,
        hasStoredCredential: Bool = false
    ) {
        self.init(
            id: connection.id,
            displayName: connection.displayName,
            baseURL: connection.baseURL.absoluteString,
            selectedModelID: connection.selectedModelID ?? "",
            authMode: connection.authMode,
            allowInsecureHTTP: connection.transportSecurity == .allowInsecureHTTP,
            enableThinking: connection.requestBehavior.enableThinking == false,
            bearerToken: "",
            removeStoredCredential: false,
            hasStoredCredential: hasStoredCredential,
            discoveredModelIDs: connection.discovery.discoveredModelIDs,
            discovery: connection.discovery
        )
    }

    static func new() -> Self { Self() }

    var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModelID: String? {
        let value = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// True for a syntactically valid HTTP URL, regardless of whether its
    /// host is eligible for the narrowly-scoped clear-text exception.
    var usesHTTP: Bool {
        guard let url = URL(string: trimmedBaseURL),
              url.scheme?.lowercased() == "http",
              let host = url.host,
              !host.isEmpty
        else { return false }
        return true
    }

    var insecureHTTPHostClassification: ProviderBaseURLNormalizer.InsecureHTTPHostClassification? {
        guard let url = URL(string: trimmedBaseURL),
              url.scheme?.lowercased() == "http",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return ProviderBaseURLNormalizer.insecureHTTPHostClassification(host)
    }

    var hasAllowedInsecureHTTPHost: Bool {
        insecureHTTPHostClassification?.isAllowed == true
    }

    var urlValidationMessage: String? {
        guard !trimmedBaseURL.isEmpty else { return nil }
        do {
            _ = try ProviderBaseURLNormalizer.normalize(
                trimmedBaseURL,
                transportSecurity: allowInsecureHTTP ? .allowInsecureHTTP : .requireTLS
            )
            return nil
        } catch let error as ProviderConnectionRecordError {
            return ProviderSettingsURLValidation.message(for: error)
        } catch {
            return "The provider URL is invalid."
        }
    }

    /// Converts the transient draft into the durable, non-secret record.
    func makeRecord(
        discovery: ProviderConnectionDiscoveryMetadata? = nil
    ) throws -> ProviderConnectionRecord {
        let security: ProviderConnectionTransportSecurity = usesHTTP
            && allowInsecureHTTP
            ? .allowInsecureHTTP
            : .requireTLS
        return try ProviderConnectionRecord(
            id: id,
            displayName: trimmedDisplayName,
            baseURL: URL(string: trimmedBaseURL) ?? URL(fileURLWithPath: ""),
            selectedModelID: trimmedModelID,
            authMode: authMode,
            transportSecurity: security,
            discovery: discovery ?? self.discovery,
            requestBehavior: OpenAICompatibleRequestBehavior(
                enableThinking: enableThinking ? false : nil
            )
        )
    }
}

enum ProviderSettingsError: LocalizedError, Equatable, Sendable {
    case missingDisplayName
    case missingBaseURL
    case invalidBaseURL(String)
    case insecureHTTPRequiresAcknowledgement
    case insecureHTTPHostNotAllowed
    case insecureHTTPBearerCredential
    case missingBearerCredential
    case discoveryRequiresValidDraft
    case connectionNotFound
    case persistenceFailure(String)
    case credentialFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingDisplayName:
            "Give this connection a name."
        case .missingBaseURL:
            "Enter the provider base URL."
        case let .invalidBaseURL(detail): detail
        case .insecureHTTPRequiresAcknowledgement:
            "Acknowledge clear-text HTTP before using this URL, even when it points to a local IP address."
        case .insecureHTTPHostNotAllowed:
            "Clear-text HTTP is only allowed for a literal loopback, private-network, or link-local IP address. Hostnames and public IPs must use HTTPS."
        case .insecureHTTPBearerCredential:
            "Bearer authentication cannot be used over clear-text HTTP. Use HTTPS or choose No authentication."
        case .missingBearerCredential:
            "Enter an API bearer token, or choose No authentication."
        case .discoveryRequiresValidDraft:
            "Complete the connection details before testing the endpoint."
        case .connectionNotFound:
            "That provider connection no longer exists."
        case let .persistenceFailure(detail):
            "The provider connection could not be saved: \(detail)"
        case let .credentialFailure(detail):
            "The provider credential could not be updated: \(detail)"
        }
    }
}

private enum ProviderSettingsURLValidation {
    static func message(for error: ProviderConnectionRecordError) -> String {
        switch error {
        case .insecureHTTPRequiresExplicitOptIn:
            "This clear-text HTTP URL needs an explicit acknowledgement, including for local IP addresses."
        case .insecureHTTPHostNotAllowed:
            "Clear-text HTTP is only allowed for a literal loopback, private-network, or link-local IP address. Hostnames and public IPs must use HTTPS."
        case .insecureHTTPBearerCredentialNotAllowed:
            "Bearer authentication cannot be used over clear-text HTTP. Use HTTPS or choose No authentication."
        case .invalidBaseURL:
            "Enter a valid HTTP(S) base URL without credentials, query parameters, or fragments."
        case .emptyConnectionID, .emptyDisplayName:
            "Complete the connection details."
        }
    }
}

/// The subset of a settings draft that determines which endpoint and
/// credential scope owns a discovered model catalog. The credential remains in
/// its opaque container so this comparison cannot accidentally make it
/// printable or persist it.
private struct ProviderDraftDiscoveryScope: Equatable {
    let connectionID: ProviderConnectionID
    let baseURL: String
    let authMode: ProviderConnectionAuthMode
    let allowInsecureHTTP: Bool
    let typedCredential: ProviderBearerCredential?
    let usesStoredCredential: Bool

    init(_ draft: ProviderConnectionDraft) {
        connectionID = draft.id
        baseURL = draft.trimmedBaseURL
        authMode = draft.authMode
        allowInsecureHTTP = draft.allowInsecureHTTP
        if draft.authMode == .bearer {
            let token = draft.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            typedCredential = token.isEmpty ? nil : try? ProviderBearerCredential(token)
            usesStoredCredential = token.isEmpty
                && draft.hasStoredCredential
                && !draft.removeStoredCredential
        } else {
            typedCredential = nil
            usesStoredCredential = false
        }
    }
}

/// App-lifetime state owner for OpenAI-compatible provider settings.
/// Codex/ChatGPT OAuth remains owned by `OnyxAppModel` and is intentionally
/// not represented here.
@MainActor
final class ProviderSettingsModel: ObservableObject {
    @Published private(set) var connections: [ProviderConnectionRecord] = []
    @Published var selectedConnectionID: ProviderConnectionID?
    @Published var draft: ProviderConnectionDraft = .new()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var lastDiscoveredModels: [ProviderModelDescriptor] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    let connectionStore: ProviderConnectionStore
    let credentialStore: any CredentialStore
    let discovery: any ProviderModelDiscovery

    /// The application host uses this boundary to evict any live runtime that
    /// was created from the previous connection record. Keeping the callback
    /// here also makes save/delete semantics testable without coupling this
    /// settings model to workspace composition.
    var onConnectionMutation: (@MainActor (ProviderConnectionID) -> Void)?

    private var hasStarted = false
    private var draftRevision: UInt64 = 0
    private var catalogScope: ProviderDraftDiscoveryScope?

    init(
        connectionStore: ProviderConnectionStore = ProviderConnectionStore(),
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        discovery: any ProviderModelDiscovery = URLSessionProviderModelDiscovery()
    ) {
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.discovery = discovery
    }

    /// Idempotent app/settings-scene startup. It performs no network work.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            connections = try await connectionStore.connections()
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if let selectedConnectionID,
               let connection = connections.first(where: { $0.id == selectedConnectionID }) {
                draft = await makeDraft(for: connection)
                catalogScope = catalogScopeForLoadedDraft(draft)
            } else if let first = connections.first {
                selectedConnectionID = first.id
                draft = await makeDraft(for: first)
                catalogScope = catalogScopeForLoadedDraft(draft)
            } else {
                selectedConnectionID = nil
                draft = .new()
                catalogScope = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = userFacing(error)
        }
    }

    func beginAdd() {
        draftRevision &+= 1
        selectedConnectionID = nil
        draft = .new()
        catalogScope = nil
        lastDiscoveredModels = []
        errorMessage = nil
        statusMessage = nil
    }

    /// Draft fields that define catalog ownership should invalidate visible
    /// discovery immediately. Other edits (name, default model, request
    /// behavior) intentionally leave the current catalog usable.
    func updateDraftDiscoveryScope() {
        let currentScope = ProviderDraftDiscoveryScope(draft)
        guard catalogScope != nil, catalogScope != currentScope else { return }
        catalogScope = nil
        lastDiscoveredModels = []
        statusMessage = "Connection details changed. Models will refresh when you save."
        errorMessage = nil
    }

    func beginEdit(_ id: ProviderConnectionID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        draftRevision &+= 1
        let revision = draftRevision
        selectedConnectionID = id
        Task { [weak self] in
            guard let self else { return }
            let loadedDraft = await makeDraft(for: connection)
            guard selectedConnectionID == id, draftRevision == revision else { return }
            draft = loadedDraft
            catalogScope = catalogScopeForLoadedDraft(loadedDraft)
            lastDiscoveredModels = []
            errorMessage = nil
            statusMessage = nil
        }
    }

    /// Saves the current draft and updates the Keychain only when bearer auth
    /// is selected. The durable JSON record never contains the token.
    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSaving, !isDiscovering else { return false }
        isSaving = true
        defer { isSaving = false }

        let existing = connections.first(where: { $0.id == draft.id })
        let preflightRecord: ProviderConnectionRecord
        do {
            preflightRecord = try makeRecordForSave()
        } catch {
            errorMessage = userFacing(error)
            return false
        }

        let shouldAutomaticallyDiscover = existing == nil
            || catalogScope != ProviderDraftDiscoveryScope(draft)
            || preflightRecord.discovery.discoveredModelIDs.isEmpty
        let draftDiscoveryScopeChanged = catalogScope != ProviderDraftDiscoveryScope(draft)
        var automaticDiscoveryFailed = false
        var automaticallyDiscoveredCount: Int?
        if shouldAutomaticallyDiscover {
            statusMessage = "Checking the provider for models…"
            let models = await discoverModels()
            automaticallyDiscoveredCount = models?.count
            automaticDiscoveryFailed = models == nil
        }

        let record: ProviderConnectionRecord
        do {
            // Discovery can select the first advertised model and attach its
            // capability metadata to the draft, so rebuild the durable record
            // from that result before writing it.
            record = try makeRecordForSave()
        } catch {
            errorMessage = userFacing(error)
            return false
        }

        do {
            let previousCredential = try await credentialStore.credential(
                for: record.credentialKey
            )
            let endpointOrAuthChanged = existing.map {
                $0.baseURL != record.baseURL
                    || $0.authMode != record.authMode
                    || $0.transportSecurity != record.transportSecurity
            } ?? false
            let credentialChanged: Bool
            if record.authMode == .bearer {
                let typedToken = draft.bearerToken.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let typedCredential = typedToken.isEmpty
                    ? nil
                    : try ProviderBearerCredential(typedToken)
                credentialChanged = typedCredential.map { $0 != previousCredential } ?? false
            } else {
                credentialChanged = previousCredential != nil
            }
            let shouldRotateConversationScope = existing != nil
                && (endpointOrAuthChanged || credentialChanged)
            try await updateCredential(for: record, existing: existing)
            do {
                if existing != nil {
                    // Apply only user-editable settings to the latest stored
                    // record. Discovery can refresh its metadata concurrently;
                    // saving a form must not overwrite that newer catalog with
                    // the draft's stale copy.
                    _ = try await connectionStore.update(id: record.id) { current in
                        let discoveryScopeChanged = current.baseURL != record.baseURL
                            || current.authMode != record.authMode
                            || current.transportSecurity != record.transportSecurity
                        current.displayName = record.displayName
                        current.baseURL = record.baseURL
                        current.selectedModelID = record.selectedModelID
                        current.authMode = record.authMode
                        current.transportSecurity = record.transportSecurity
                        current.transportCapabilities = record.transportCapabilities
                        current.requestBehavior = record.requestBehavior
                        if shouldRotateConversationScope {
                            current.conversationScopeID = ProviderConnectionRecord
                                .makeConversationScopeID()
                        }
                        let draftDiscoveryIsNewer = record.discovery.lastSucceededAt.map { date in
                            date >= (current.discovery.lastSucceededAt ?? .distantPast)
                        } ?? false
                        if discoveryScopeChanged
                            || draftDiscoveryScopeChanged
                            || draftDiscoveryIsNewer
                        {
                            // A catalog belongs to an endpoint/auth scope. Keep
                            // the newest catalog tested in this draft, or clear
                            // the old scope's catalog when discovery failed.
                            current.discovery = record.discovery
                        }
                    }
                } else {
                    try await connectionStore.upsert(record)
                }
            } catch {
                await restoreCredentialAfterFailedSave(
                    existing: existing,
                    key: record.credentialKey,
                    previousCredential: previousCredential
                )
                throw error
            }
            connections = try await connectionStore.connections()
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            selectedConnectionID = record.id
            let savedRecord = try await connectionStore.connection(id: record.id) ?? record
            draft = await makeDraft(for: savedRecord)
            catalogScope = catalogScopeForLoadedDraft(draft)
            onConnectionMutation?(record.id)
            if let automaticallyDiscoveredCount {
                statusMessage = "Saved \(savedRecord.displayName) with \(automaticallyDiscoveredCount) model\(automaticallyDiscoveredCount == 1 ? "" : "s")."
            } else if automaticDiscoveryFailed {
                statusMessage = "Saved \(savedRecord.displayName). Models were not available; enter a model ID or retry discovery."
            } else {
                statusMessage = "Saved \(savedRecord.displayName)."
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = userFacing(error, persistence: true)
            return false
        }
    }

    func delete(_ id: ProviderConnectionID) async -> Bool {
        do {
            guard let removed = try await connectionStore.remove(id: id) else {
                throw ProviderSettingsError.connectionNotFound
            }
            // The durable endpoint is already gone. Evict its runtime before
            // any best-effort Keychain cleanup so an open workspace cannot
            // keep sending to deleted provider settings if that cleanup fails.
            onConnectionMutation?(id)
            if removed.authMode == .bearer {
                try await credentialStore.removeCredential(
                    for: ProviderCredentialKey(connectionID: id)
                )
            }
            connections = try await connectionStore.connections()
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if selectedConnectionID == id {
                if let first = connections.first {
                    selectedConnectionID = first.id
                    draft = await makeDraft(for: first)
                    catalogScope = catalogScopeForLoadedDraft(draft)
                } else {
                    beginAdd()
                }
            }
            statusMessage = "Connection removed."
            errorMessage = nil
            return true
        } catch {
            errorMessage = userFacing(error, persistence: true)
            return false
        }
    }

    /// Calls the injected discovery client against the current draft. A
    /// successful test updates the draft's model list but does not save the
    /// connection until the user presses Save.
    @discardableResult
    func discoverModels() async -> [ProviderModelDescriptor]? {
        guard !isDiscovering else { return nil }
        isDiscovering = true
        defer { isDiscovering = false }
        let record: ProviderConnectionRecord
        do {
            record = try makeRecordForDiscovery()
        } catch {
            errorMessage = userFacing(error)
            return nil
        }
        let revision = draftRevision
        let draftSnapshot = draft

        do {
            let credential = try await credentialForDiscovery(for: record)
            let models = try await discovery.discoverModels(
                for: record,
                credential: credential
            )
            guard !models.isEmpty else {
                throw ProviderModelDiscoveryError.noModels
            }
            guard draftRevision == revision, draft == draftSnapshot else {
                return nil
            }
            let ids = models.map(\.id)
            let now = Date()
            draft.discoveredModelIDs = ids
            draft.discovery = ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: now,
                lastSucceededAt: now,
                discoveredModelIDs: ids,
                discoveredModels: models
            )
            catalogScope = ProviderDraftDiscoveryScope(draftSnapshot)
            lastDiscoveredModels = models
            if draft.trimmedModelID == nil,
               let first = ids.first {
                draft.selectedModelID = first
            }
            statusMessage = "Found \(models.count) model\(models.count == 1 ? "" : "s"). Save to keep this catalog."
            errorMessage = nil
            return models
        } catch {
            guard draftRevision == revision, draft == draftSnapshot else {
                return nil
            }
            let attempted = ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: Date(),
                lastSucceededAt: draft.discovery.lastSucceededAt,
                discoveredModelIDs: draft.discovery.discoveredModelIDs,
                discoveredModels: draft.discovery.discoveredModels
            )
            draft.discovery = attempted
            errorMessage = userFacing(error)
            return nil
        }
    }

    func selectConnection(_ id: ProviderConnectionID) {
        beginEdit(id)
    }

    private func makeDraft(for connection: ProviderConnectionRecord) async -> ProviderConnectionDraft {
        let hasCredential: Bool
        if connection.authMode == .bearer {
            hasCredential = (try? await credentialStore.credential(for: connection.credentialKey)) != nil
        } else {
            hasCredential = false
        }
        return ProviderConnectionDraft(connection: connection, hasStoredCredential: hasCredential)
    }

    /// The Settings picker shows only a catalog that belongs to the current
    /// endpoint/auth draft. A stale catalog remains preserved in its saved
    /// record until the user saves the changed connection, but is never offered
    /// as if it came from the newly typed endpoint.
    var currentDraftDiscoveredModels: [ProviderModelDescriptor] {
        guard catalogScope == ProviderDraftDiscoveryScope(draft) else { return [] }
        return draft.discovery.discoveredModels
    }

    var currentDraftDiscoveredModelIDs: [String] {
        guard catalogScope == ProviderDraftDiscoveryScope(draft) else { return [] }
        return draft.discovery.discoveredModelIDs
    }

    private func catalogScopeForLoadedDraft(
        _ loadedDraft: ProviderConnectionDraft
    ) -> ProviderDraftDiscoveryScope? {
        guard !loadedDraft.discovery.discoveredModelIDs.isEmpty else { return nil }
        return ProviderDraftDiscoveryScope(loadedDraft)
    }

    private func makeRecordForSave() throws -> ProviderConnectionRecord {
        guard !draft.trimmedDisplayName.isEmpty else {
            throw ProviderSettingsError.missingDisplayName
        }
        guard !draft.trimmedBaseURL.isEmpty else {
            throw ProviderSettingsError.missingBaseURL
        }
        if draft.usesHTTP {
            guard draft.hasAllowedInsecureHTTPHost else {
                throw ProviderSettingsError.insecureHTTPHostNotAllowed
            }
            guard draft.allowInsecureHTTP else {
                throw ProviderSettingsError.insecureHTTPRequiresAcknowledgement
            }
            guard draft.authMode != .bearer else {
                throw ProviderSettingsError.insecureHTTPBearerCredential
            }
        }
        let security: ProviderConnectionTransportSecurity = draft.usesHTTP
            && draft.allowInsecureHTTP
            ? .allowInsecureHTTP
            : .requireTLS
        do {
            _ = try ProviderBaseURLNormalizer.normalize(
                draft.trimmedBaseURL,
                transportSecurity: security
            )
        } catch let error as ProviderConnectionRecordError {
            if case .insecureHTTPBearerCredentialNotAllowed = error {
                throw ProviderSettingsError.insecureHTTPBearerCredential
            }
            throw ProviderSettingsError.invalidBaseURL(
                ProviderSettingsURLValidation.message(for: error)
            )
        }
        if draft.authMode == .bearer {
            let token = draft.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty && (!draft.hasStoredCredential || draft.removeStoredCredential) {
                throw ProviderSettingsError.missingBearerCredential
            }
        }
        let discovery = catalogScope == ProviderDraftDiscoveryScope(draft)
            ? draft.discovery
            : ProviderConnectionDiscoveryMetadata()
        let existingConnection = connections.first(where: { $0.id == draft.id })
        let conversationScopeID = existingConnection?.conversationScopeID
            ?? ProviderConnectionRecord.makeConversationScopeID()
        // OpenAI-compatible chat endpoints are expected to support SSE
        // streaming. Early previews wrote an empty set, which cannot run a
        // chat turn at all; upgrade that legacy value on the next save while
        // preserving any non-empty explicit capability selection.
        let persistedCapabilities = connections.first(where: { $0.id == draft.id })?
            .transportCapabilities
        let existingCapabilities: Set<ProviderTransportCapability>
        if let persistedCapabilities, !persistedCapabilities.isEmpty {
            existingCapabilities = persistedCapabilities
        } else {
            existingCapabilities = [.streaming, .streamUsage]
        }
        do {
            return try ProviderConnectionRecord(
                id: draft.id,
                displayName: draft.trimmedDisplayName,
                baseURL: URL(string: draft.trimmedBaseURL) ?? URL(fileURLWithPath: ""),
                selectedModelID: draft.trimmedModelID,
                authMode: draft.authMode,
                transportSecurity: security,
                transportCapabilities: existingCapabilities,
                discovery: discovery,
                requestBehavior: OpenAICompatibleRequestBehavior(
                    enableThinking: draft.enableThinking ? false : nil
                ),
                conversationScopeID: conversationScopeID
            )
        } catch let error as ProviderConnectionRecordError {
            throw ProviderSettingsError.invalidBaseURL(
                ProviderSettingsURLValidation.message(for: error)
            )
        }
    }

    private func makeRecordForDiscovery() throws -> ProviderConnectionRecord {
        guard !draft.trimmedDisplayName.isEmpty,
              !draft.trimmedBaseURL.isEmpty
        else {
            throw ProviderSettingsError.discoveryRequiresValidDraft
        }
        if draft.usesHTTP {
            guard draft.hasAllowedInsecureHTTPHost else {
                throw ProviderSettingsError.insecureHTTPHostNotAllowed
            }
            guard draft.allowInsecureHTTP else {
                throw ProviderSettingsError.insecureHTTPRequiresAcknowledgement
            }
            guard draft.authMode != .bearer else {
                throw ProviderSettingsError.insecureHTTPBearerCredential
            }
        }
        let security: ProviderConnectionTransportSecurity = draft.usesHTTP
            && draft.allowInsecureHTTP
            ? .allowInsecureHTTP
            : .requireTLS
        do {
            return try ProviderConnectionRecord(
                id: draft.id,
                displayName: draft.trimmedDisplayName,
                baseURL: URL(string: draft.trimmedBaseURL) ?? URL(fileURLWithPath: ""),
                selectedModelID: draft.trimmedModelID,
                authMode: draft.authMode,
                transportSecurity: security,
                transportCapabilities: [.streaming, .streamUsage],
                discovery: draft.discovery,
                requestBehavior: OpenAICompatibleRequestBehavior(
                    enableThinking: draft.enableThinking ? false : nil
                ),
                conversationScopeID: connections.first(where: { $0.id == draft.id })?
                    .conversationScopeID ?? ProviderConnectionRecord.makeConversationScopeID()
            )
        } catch let error as ProviderConnectionRecordError {
            throw ProviderSettingsError.invalidBaseURL(
                ProviderSettingsURLValidation.message(for: error)
            )
        }
    }

    private func credentialForDiscovery(
        for record: ProviderConnectionRecord
    ) async throws -> ProviderBearerCredential? {
        guard record.authMode == .bearer else { return nil }
        let typedToken = draft.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedToken.isEmpty {
            return try ProviderBearerCredential(typedToken)
        }
        guard let credential = try await credentialStore.credential(for: record.credentialKey) else {
            throw ProviderSettingsError.missingBearerCredential
        }
        return credential
    }

    private func updateCredential(
        for record: ProviderConnectionRecord,
        existing: ProviderConnectionRecord?
    ) async throws {
        let key = record.credentialKey
        guard record.authMode == .bearer else {
            if existing?.authMode == .bearer || draft.hasStoredCredential {
                try await credentialStore.removeCredential(for: key)
            }
            return
        }

        let token = draft.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            try await credentialStore.setCredential(
                try ProviderBearerCredential(token),
                for: key
            )
        } else if draft.removeStoredCredential {
            try await credentialStore.removeCredential(for: key)
        } else if existing?.authMode != .bearer || !draft.hasStoredCredential {
            throw ProviderSettingsError.missingBearerCredential
        }
    }

    /// Best-effort compensation when the non-secret record write fails after
    /// a Keychain mutation. This keeps the two stores aligned without ever
    /// copying credential material into the durable provider document.
    private func restoreCredentialAfterFailedSave(
        existing: ProviderConnectionRecord?,
        key: ProviderCredentialKey,
        previousCredential: ProviderBearerCredential?
    ) async {
        do {
            if existing?.authMode == .bearer, let previousCredential {
                try await credentialStore.setCredential(previousCredential, for: key)
            } else {
                try await credentialStore.removeCredential(for: key)
            }
        } catch {
            // The original save failure remains the actionable result. The UI
            // never includes Keychain payloads or raw error internals.
        }
    }

    private func userFacing(
        _ error: any Error,
        persistence: Bool = false
    ) -> String {
        if let settingsError = error as? ProviderSettingsError {
            return settingsError.localizedDescription
        }
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return persistence
                ? ProviderSettingsError.persistenceFailure(description).localizedDescription
                : description
        }
        return persistence
            ? ProviderSettingsError.persistenceFailure("Please try again.").localizedDescription
            : "The provider connection could not be tested. Please try again."
    }
}
