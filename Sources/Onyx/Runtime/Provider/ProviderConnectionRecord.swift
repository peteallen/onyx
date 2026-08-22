import Foundation

/// How an OpenAI-compatible endpoint authenticates requests. The bearer value
/// itself is intentionally absent: it lives in a `CredentialStore` under the
/// connection's stable ID.
enum ProviderConnectionAuthMode: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case bearer
}

/// User acknowledgement required before Onyx sends clear-text HTTP traffic to
/// a non-loopback host. HTTP remains available for local development without
/// turning every private-network endpoint into an implicit exception.
enum ProviderConnectionTransportSecurity: String, Codable, Hashable, Sendable {
    case requireTLS
    case allowInsecureHTTP
}

/// Endpoint discovery state safe to keep in Application Support. This stores
/// only model names and timestamps returned by the endpoint, never response
/// headers, authorization material, or raw network diagnostics.
struct ProviderConnectionDiscoveryMetadata: Codable, Equatable, Hashable, Sendable {
    let lastAttemptedAt: Date?
    let lastSucceededAt: Date?
    let discoveredModelIDs: [String]

    init(
        lastAttemptedAt: Date? = nil,
        lastSucceededAt: Date? = nil,
        discoveredModelIDs: [String] = []
    ) {
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSucceededAt = lastSucceededAt
        self.discoveredModelIDs = Self.normalizedModelIDs(discoveredModelIDs)
    }

    private static func normalizedModelIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }
}

/// Non-secret provider-specific request behavior. Values are deliberately
/// scoped instead of accepting arbitrary headers or arbitrary JSON, either of
/// which could accidentally persist credentials. The first supported option
/// maps to `chat_template_kwargs.enable_thinking` on compatible Qwen servers.
struct OpenAICompatibleRequestBehavior: Codable, Equatable, Hashable, Sendable {
    var enableThinking: Bool?

    init(enableThinking: Bool? = nil) {
        self.enableThinking = enableThinking
    }
}

/// Durable, non-secret settings for one OpenAI-compatible endpoint.
///
/// The URL is normalized and revalidated on decode so hand-edited or older
/// files cannot bypass the explicit insecure-HTTP acknowledgement.
struct ProviderConnectionRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: ProviderConnectionID
    var displayName: String
    var baseURL: URL
    var selectedModelID: String?
    var authMode: ProviderConnectionAuthMode
    var transportSecurity: ProviderConnectionTransportSecurity
    var transportCapabilities: Set<ProviderTransportCapability>
    var discovery: ProviderConnectionDiscoveryMetadata
    var requestBehavior: OpenAICompatibleRequestBehavior

    init(
        id: ProviderConnectionID,
        displayName: String,
        baseURL: URL,
        selectedModelID: String? = nil,
        authMode: ProviderConnectionAuthMode,
        transportSecurity: ProviderConnectionTransportSecurity = .requireTLS,
        transportCapabilities: Set<ProviderTransportCapability> = [],
        discovery: ProviderConnectionDiscoveryMetadata = .init(),
        requestBehavior: OpenAICompatibleRequestBehavior = .init()
    ) throws {
        let normalizedID = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw ProviderConnectionRecordError.emptyConnectionID
        }

        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ProviderConnectionRecordError.emptyDisplayName
        }

        self.id = ProviderConnectionID(normalizedID)
        self.displayName = normalizedName
        self.baseURL = try ProviderBaseURLNormalizer.normalize(
            baseURL,
            transportSecurity: transportSecurity
        )
        self.selectedModelID = selectedModelID?.providerNilIfBlank
        self.authMode = authMode
        self.transportSecurity = transportSecurity
        self.transportCapabilities = transportCapabilities
        self.discovery = discovery
        self.requestBehavior = requestBehavior
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL
        case selectedModelID
        case authMode
        case transportSecurity
        case transportCapabilities
        case discovery
        case requestBehavior
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ProviderConnectionID.self, forKey: .id),
            displayName: container.decode(String.self, forKey: .displayName),
            baseURL: container.decode(URL.self, forKey: .baseURL),
            selectedModelID: container.decodeIfPresent(String.self, forKey: .selectedModelID),
            authMode: container.decode(ProviderConnectionAuthMode.self, forKey: .authMode),
            transportSecurity: container.decodeIfPresent(
                ProviderConnectionTransportSecurity.self,
                forKey: .transportSecurity
            ) ?? .requireTLS,
            transportCapabilities: container.decodeIfPresent(
                Set<ProviderTransportCapability>.self,
                forKey: .transportCapabilities
            ) ?? [],
            discovery: container.decodeIfPresent(
                ProviderConnectionDiscoveryMetadata.self,
                forKey: .discovery
            ) ?? .init(),
            requestBehavior: container.decodeIfPresent(
                OpenAICompatibleRequestBehavior.self,
                forKey: .requestBehavior
            ) ?? .init()
        )
    }

    /// Credential-store locator derived only from the stable connection ID.
    /// It is safe to persist and avoids putting a user-entered account string
    /// or any secret in the connection document.
    var credentialKey: ProviderCredentialKey {
        ProviderCredentialKey(connectionID: id)
    }
}

enum ProviderConnectionRecordError: LocalizedError, Equatable, Sendable {
    case emptyConnectionID
    case emptyDisplayName
    case invalidBaseURL(String)
    case insecureHTTPRequiresExplicitOptIn(String)

    var errorDescription: String? {
        switch self {
        case .emptyConnectionID:
            "Provider connection ID cannot be empty."
        case .emptyDisplayName:
            "Provider display name cannot be empty."
        case let .invalidBaseURL(value):
            "Provider base URL is invalid: \(value)."
        case let .insecureHTTPRequiresExplicitOptIn(value):
            "Clear-text provider URL requires explicit insecure-HTTP acknowledgement: \(value)."
        }
    }
}

enum ProviderBaseURLNormalizer {
    static func normalize(
        _ rawValue: String,
        transportSecurity: ProviderConnectionTransportSecurity = .requireTLS
    ) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw ProviderConnectionRecordError.invalidBaseURL(trimmed)
        }
        return try normalize(url, transportSecurity: transportSecurity)
    }

    static func normalize(
        _ rawURL: URL,
        transportSecurity: ProviderConnectionTransportSecurity = .requireTLS
    ) throws -> URL {
        let rawValue = rawURL.absoluteString
        guard var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw ProviderConnectionRecordError.invalidBaseURL(rawValue)
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw ProviderConnectionRecordError.invalidBaseURL(rawValue)
        }
        if scheme == "http",
           !isLoopback(host),
           transportSecurity != .allowInsecureHTTP
        {
            throw ProviderConnectionRecordError.insecureHTTPRequiresExplicitOptIn(rawValue)
        }

        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        {
            components.port = nil
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path == "/" ? "" : path

        guard let normalized = components.url else {
            throw ProviderConnectionRecordError.invalidBaseURL(rawValue)
        }
        return normalized
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "[::1]"
    }
}

private extension String {
    var providerNilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
