import Foundation
import Network

/// How an OpenAI-compatible endpoint authenticates requests. The bearer value
/// itself is intentionally absent: it lives in a `CredentialStore` under the
/// connection's stable ID.
enum ProviderConnectionAuthMode: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case bearer
}

/// User acknowledgement required before Onyx sends any clear-text HTTP
/// traffic. The acknowledgement is deliberately persisted on the connection,
/// including for local/private endpoints, so a hand-edited document cannot
/// silently opt a user into an insecure transport.
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
    /// Credential-free catalog entries are persisted so a workspace can show
    /// every configured provider's models (and their capability badges)
    /// before opening that provider. Older records contain IDs only and remain
    /// readable through the custom decoder below.
    let discoveredModels: [ProviderModelDescriptor]

    init(
        lastAttemptedAt: Date? = nil,
        lastSucceededAt: Date? = nil,
        discoveredModelIDs: [String] = [],
        discoveredModels: [ProviderModelDescriptor] = []
    ) {
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSucceededAt = lastSucceededAt
        self.discoveredModels = Self.normalizedModels(discoveredModels)
        self.discoveredModelIDs = self.discoveredModels.isEmpty
            ? Self.normalizedModelIDs(discoveredModelIDs)
            : self.discoveredModels.map(\.id)
    }

    private enum CodingKeys: String, CodingKey {
        case lastAttemptedAt
        case lastSucceededAt
        case discoveredModelIDs
        case discoveredModels
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastAttemptedAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptedAt),
            lastSucceededAt: try container.decodeIfPresent(Date.self, forKey: .lastSucceededAt),
            discoveredModelIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .discoveredModelIDs
            ) ?? [],
            discoveredModels: try container.decodeIfPresent(
                [ProviderModelDescriptor].self,
                forKey: .discoveredModels
            ) ?? []
        )
    }

    private static func normalizedModelIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func normalizedModels(
        _ values: [ProviderModelDescriptor]
    ) -> [ProviderModelDescriptor] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
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
    /// Non-secret ownership token for locally persisted provider chats. It is
    /// rotated whenever the endpoint or credential identity changes so a task
    /// created for one backend can never be replayed into another backend that
    /// reuses the same friendly connection ID.
    var conversationScopeID: String

    init(
        id: ProviderConnectionID,
        displayName: String,
        baseURL: URL,
        selectedModelID: String? = nil,
        authMode: ProviderConnectionAuthMode,
        transportSecurity: ProviderConnectionTransportSecurity = .requireTLS,
        transportCapabilities: Set<ProviderTransportCapability> = [],
        discovery: ProviderConnectionDiscoveryMetadata = .init(),
        requestBehavior: OpenAICompatibleRequestBehavior = .init(),
        conversationScopeID: String = ProviderConnectionRecord.makeConversationScopeID()
    ) throws {
        let normalizedID = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw ProviderConnectionRecordError.emptyConnectionID
        }

        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ProviderConnectionRecordError.emptyDisplayName
        }

        let normalizedBaseURL = try ProviderBaseURLNormalizer.normalize(
            baseURL,
            transportSecurity: transportSecurity
        )
        if normalizedBaseURL.scheme?.lowercased() == "http", authMode == .bearer {
            throw ProviderConnectionRecordError.insecureHTTPBearerCredentialNotAllowed(
                normalizedBaseURL.absoluteString
            )
        }

        self.id = ProviderConnectionID(normalizedID)
        self.displayName = normalizedName
        self.baseURL = normalizedBaseURL
        self.selectedModelID = selectedModelID?.providerNilIfBlank
        self.authMode = authMode
        self.transportSecurity = transportSecurity
        self.transportCapabilities = transportCapabilities
        self.discovery = discovery
        self.requestBehavior = requestBehavior
        let normalizedScopeID = conversationScopeID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.conversationScopeID = normalizedScopeID.isEmpty
            ? Self.makeConversationScopeID()
            : normalizedScopeID
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
        case conversationScopeID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProviderConnectionID.self, forKey: .id)
        try self.init(
            id: id,
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
            ) ?? .init(),
            conversationScopeID: container.decodeIfPresent(
                String.self,
                forKey: .conversationScopeID
            ) ?? Self.legacyConversationScopeID(for: id)
        )
    }

    /// Credential-store locator derived only from the stable connection ID.
    /// It is safe to persist and avoids putting a user-entered account string
    /// or any secret in the connection document.
    var credentialKey: ProviderCredentialKey {
        ProviderCredentialKey(connectionID: id)
    }

    /// Re-applies every constructor invariant after a field-scoped mutation.
    /// Records have mutable user/discovery fields so the store calls this
    /// before persisting an update; transport security must not rely only on
    /// the invariants that happened to be true at initial construction.
    func revalidated() throws -> Self {
        try Self(
            id: id,
            displayName: displayName,
            baseURL: baseURL,
            selectedModelID: selectedModelID,
            authMode: authMode,
            transportSecurity: transportSecurity,
            transportCapabilities: transportCapabilities,
            discovery: discovery,
            requestBehavior: requestBehavior,
            conversationScopeID: conversationScopeID
        )
    }

    static func makeConversationScopeID() -> String {
        "scope.\(UUID().uuidString.lowercased())"
    }

    /// Records created before conversation scoping decode to a deterministic
    /// token, allowing their legacy unscoped chats to remain available until
    /// the connection's endpoint or credentials are actually changed.
    static func legacyConversationScopeID(for id: ProviderConnectionID) -> String {
        let encoded = Data(id.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "scope.legacy.\(encoded)"
    }
}

enum ProviderConnectionRecordError: LocalizedError, Equatable, Sendable {
    case emptyConnectionID
    case emptyDisplayName
    case invalidBaseURL(String)
    case insecureHTTPRequiresExplicitOptIn(String)
    case insecureHTTPHostNotAllowed(String)
    case insecureHTTPBearerCredentialNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .emptyConnectionID:
            "Provider connection ID cannot be empty."
        case .emptyDisplayName:
            "Provider display name cannot be empty."
        case let .invalidBaseURL(value):
            "Provider base URL is invalid: \(value)."
        case let .insecureHTTPRequiresExplicitOptIn(value):
            "Clear-text provider URL requires an explicit insecure-HTTP acknowledgement, even for a local IP address: \(value)."
        case let .insecureHTTPHostNotAllowed(value):
            "Clear-text provider URL is allowed only for a literal loopback, private-network, or link-local IP address (not a hostname or public IP): \(value)."
        case let .insecureHTTPBearerCredentialNotAllowed(value):
            "Bearer credentials cannot be configured for clear-text HTTP; use HTTPS for authenticated providers: \(value)."
        }
    }
}

enum ProviderBaseURLNormalizer {
    /// The categories relevant to the clear-text HTTP policy. Hostnames are
    /// intentionally kept separate from public IPs so callers can explain why
    /// an endpoint was rejected without ever resolving DNS.
    enum InsecureHTTPHostClassification: Equatable, Sendable {
        case loopback
        case privateNetwork
        case linkLocal
        case publicIP
        case hostname

        var isAllowed: Bool {
            switch self {
            case .loopback, .privateNetwork, .linkLocal:
                true
            case .publicIP, .hostname:
                false
            }
        }
    }

    /// Classifies a host without DNS resolution. Only a literal IP in one of
    /// the explicitly local/private ranges can ever be used with clear-text
    /// HTTP. `localhost`, mDNS names, and every other hostname remain
    /// hostnames even if they happen to resolve to a local address.
    static func insecureHTTPHostClassification(
        _ rawHost: String
    ) -> InsecureHTTPHostClassification {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }

        if let bytes = canonicalIPv4Bytes(host) {
            if bytes[0] == 127 {
                return .loopback
            }
            if bytes[0] == 10
                || (bytes[0] == 172 && (16 ... 31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
            {
                return .privateNetwork
            }
            if bytes[0] == 169 && bytes[1] == 254 {
                return .linkLocal
            }
            return .publicIP
        }

        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return .publicIP }

            // IPv4-mapped IPv6 literals retain the same security meaning as
            // their mapped address (for example ::ffff:192.168.1.10).
            let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
            if isIPv4Mapped {
                let mapped = Array(bytes[12..<16])
                if mapped[0] == 127 {
                    return .loopback
                }
                if mapped[0] == 10
                    || (mapped[0] == 172 && (16 ... 31).contains(mapped[1]))
                    || (mapped[0] == 192 && mapped[1] == 168)
                {
                    return .privateNetwork
                }
                if mapped[0] == 169 && mapped[1] == 254 {
                    return .linkLocal
                }
                return .publicIP
            }

            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
                return .loopback
            }
            if (bytes[0] & 0xfe) == 0xfc { // fc00::/7 (IPv6 ULA)
                return .privateNetwork
            }
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { // fe80::/10
                return .linkLocal
            }
            return .publicIP
        }

        return .hostname
    }

    /// Require the unambiguous dotted-decimal form. System IP parsers accept
    /// historical spellings such as `127.1` or octal-looking components; a
    /// security decision should not depend on whether URLSession interprets
    /// those legacy forms the same way.
    private static func canonicalIPv4Bytes(_ host: String) -> [UInt8]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for component in components {
            guard !component.isEmpty,
                  component.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  component.count == 1 || component.first != "0",
                  let value = UInt8(component)
            else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    static func isAllowedInsecureHTTPHost(_ host: String) -> Bool {
        insecureHTTPHostClassification(host).isAllowed
    }

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
        if scheme == "http" {
            guard isAllowedInsecureHTTPHost(host) else {
                throw ProviderConnectionRecordError.insecureHTTPHostNotAllowed(rawValue)
            }
            guard transportSecurity == .allowInsecureHTTP else {
                throw ProviderConnectionRecordError.insecureHTTPRequiresExplicitOptIn(rawValue)
            }
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

}

private extension String {
    var providerNilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
