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
            "This endpoint uses HTTP without an explicit insecure-network acknowledgement."
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
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

        if scheme == "http",
           connection.transportSecurity != .allowInsecureHTTP,
           !Self.isLoopback(host)
        {
            throw ProviderModelDiscoveryError.insecureEndpoint
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

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "[::1]"
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

    var hasNonLoopbackHTTP: Bool {
        guard let url = URL(string: trimmedBaseURL),
              url.scheme?.lowercased() == "http",
              let host = url.host,
              !host.isEmpty
        else { return false }
        let normalized = host.lowercased()
        return ![
            "localhost", "127.0.0.1", "::1", "[::1]"
        ].contains(normalized)
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
        let security: ProviderConnectionTransportSecurity = hasNonLoopbackHTTP
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
            "Acknowledge the clear-text LAN warning before using this URL."
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
            "This non-local HTTP URL needs an explicit clear-text LAN acknowledgement."
        case .invalidBaseURL:
            "Enter a valid HTTP(S) base URL without credentials, query parameters, or fragments."
        case .emptyConnectionID, .emptyDisplayName:
            "Complete the connection details."
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

    private var hasStarted = false

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
            } else if let first = connections.first {
                selectedConnectionID = first.id
                draft = await makeDraft(for: first)
            } else {
                selectedConnectionID = nil
                draft = .new()
            }
            errorMessage = nil
        } catch {
            errorMessage = userFacing(error)
        }
    }

    func beginAdd() {
        selectedConnectionID = nil
        draft = .new()
        lastDiscoveredModels = []
        errorMessage = nil
        statusMessage = nil
    }

    func beginEdit(_ id: ProviderConnectionID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        selectedConnectionID = id
        Task { [weak self] in
            guard let self else { return }
            let loadedDraft = await makeDraft(for: connection)
            guard selectedConnectionID == id else { return }
            draft = loadedDraft
            lastDiscoveredModels = []
            errorMessage = nil
            statusMessage = nil
        }
    }

    /// Saves the current draft and updates the Keychain only when bearer auth
    /// is selected. The durable JSON record never contains the token.
    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let existing = connections.first(where: { $0.id == draft.id })
        let record: ProviderConnectionRecord
        do {
            record = try makeRecordForSave()
        } catch {
            errorMessage = userFacing(error)
            return false
        }

        do {
            let previousCredential = try await credentialStore.credential(
                for: record.credentialKey
            )
            try await updateCredential(for: record, existing: existing)
            do {
                try await connectionStore.upsert(record)
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
            draft = await makeDraft(for: record)
            statusMessage = "Saved \(record.displayName)."
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

        do {
            let credential = try await credentialForDiscovery(for: record)
            let models = try await discovery.discoverModels(
                for: record,
                credential: credential
            )
            let ids = models.map(\.id)
            let now = Date()
            draft.discoveredModelIDs = ids
            draft.discovery = ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: now,
                lastSucceededAt: now,
                discoveredModelIDs: ids
            )
            lastDiscoveredModels = models
            if draft.trimmedModelID == nil,
               let first = ids.first {
                draft.selectedModelID = first
            }
            statusMessage = "Found \(models.count) model\(models.count == 1 ? "" : "s"). Save to keep this catalog."
            errorMessage = nil
            return models
        } catch {
            let attempted = ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: Date(),
                lastSucceededAt: draft.discovery.lastSucceededAt,
                discoveredModelIDs: draft.discovery.discoveredModelIDs
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

    private func makeRecordForSave() throws -> ProviderConnectionRecord {
        guard !draft.trimmedDisplayName.isEmpty else {
            throw ProviderSettingsError.missingDisplayName
        }
        guard !draft.trimmedBaseURL.isEmpty else {
            throw ProviderSettingsError.missingBaseURL
        }
        if draft.hasNonLoopbackHTTP && !draft.allowInsecureHTTP {
            throw ProviderSettingsError.insecureHTTPRequiresAcknowledgement
        }
        let security: ProviderConnectionTransportSecurity = draft.hasNonLoopbackHTTP
            && draft.allowInsecureHTTP
            ? .allowInsecureHTTP
            : .requireTLS
        do {
            _ = try ProviderBaseURLNormalizer.normalize(
                draft.trimmedBaseURL,
                transportSecurity: security
            )
        } catch let error as ProviderConnectionRecordError {
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
        let discovery = draft.discovery
        // OpenAI-compatible chat endpoints are expected to support SSE
        // streaming. A newly-created connection has no prior record from
        // which to inherit endpoint capabilities, so default it to the
        // capabilities the runtime actually requires. Existing records keep
        // their explicitly persisted values so a future capability editor can
        // narrow them deliberately.
        let existingCapabilities = connections.first(where: { $0.id == draft.id })?
            .transportCapabilities ?? [.streaming, .streamUsage]
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
                )
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
        if draft.hasNonLoopbackHTTP && !draft.allowInsecureHTTP {
            throw ProviderSettingsError.insecureHTTPRequiresAcknowledgement
        }
        let security: ProviderConnectionTransportSecurity = draft.hasNonLoopbackHTTP
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
                )
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
