import Foundation

/// The wire protocol used by a provider connection.  This is intentionally
/// narrower than an adapter ID: several providers can speak the same
/// OpenAI-compatible protocol, while one provider may expose more than one
/// protocol.
enum ProviderWireProtocol: String, Codable, Hashable, Sendable {
    case codexAppServer
    case openAIChatCompletions
    case anthropicMessages
}

/// Input and output modalities advertised by a provider's model catalog.
/// These values are kept separate from the agent runtime capability set: a
/// model can accept images without being able to execute a local command, and
/// a remote API can stream without supporting Codex's durable thread controls.
enum ProviderInputModality: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case image
    case file
    case audio
    case video
}

enum ProviderOutputModality: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case image
    case audio
    case embeddings
    case video
}

/// Optional request fields a provider model explicitly advertises.  An
/// adapter must negotiate these before adding fields to a request; otherwise
/// an upstream may silently ignore a safety- or behavior-affecting option.
enum ProviderRequestParameter: String, Codable, Hashable, Sendable, CaseIterable {
    case reasoning
    case reasoningEffort
    case tools
    case toolChoice
    case structuredOutputs
    case responseFormat

    /// OpenRouter uses snake_case catalog names while the provider-neutral
    /// enum keeps Swift-friendly stable cases. Unknown names remain
    /// unavailable until explicitly added.
    static func fromOpenRouterCatalog(_ rawValue: String) -> Self? {
        switch rawValue {
        case "reasoning", "include_reasoning": .reasoning
        case "reasoning_effort": .reasoningEffort
        case "tools": .tools
        case "tool_choice": .toolChoice
        case "structured_outputs": .structuredOutputs
        case "response_format": .responseFormat
        default: nil
        }
    }
}

/// Endpoint-level behavior that is not reported in a model catalog. For
/// example, OpenRouter's chat endpoint supports SSE streaming even though
/// model `supported_parameters` usually does not contain `stream`.
enum ProviderTransportCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case streaming
    case streamUsage
}

enum ProviderCapabilityRequirement: Hashable, Sendable {
    case input(ProviderInputModality)
    case output(ProviderOutputModality)
    case parameter(ProviderRequestParameter)
    case transport(ProviderTransportCapability)
    case reasoningEffort(String)
}

/// Model-level capability metadata.  This is deliberately a discovery value,
/// not a promise that every endpoint behind a router behaves identically;
/// callers should use endpoint-level metadata when a provider supplies it.
struct ProviderCapabilitySet: Codable, Equatable, Hashable, Sendable {
    let inputModalities: Set<ProviderInputModality>
    let outputModalities: Set<ProviderOutputModality>
    let supportedParameters: Set<ProviderRequestParameter>
    let reasoningEfforts: [String]

    init(
        inputModalities: Set<ProviderInputModality> = [.text],
        outputModalities: Set<ProviderOutputModality> = [.text],
        supportedParameters: Set<ProviderRequestParameter> = [],
        reasoningEfforts: [String] = []
    ) {
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.supportedParameters = supportedParameters
        self.reasoningEfforts = reasoningEfforts
    }

    func supports(_ requirement: ProviderCapabilityRequirement) -> Bool {
        switch requirement {
        case let .input(modality): inputModalities.contains(modality)
        case let .output(modality): outputModalities.contains(modality)
        case let .parameter(parameter): supportedParameters.contains(parameter)
        case .transport: false
        case let .reasoningEffort(effort):
            supportedParameters.contains(.reasoningEffort)
                && reasoningEfforts.contains(effort)
        }
    }

    func missing(
        _ requirements: some Sequence<ProviderCapabilityRequirement>
    ) -> [ProviderCapabilityRequirement] {
        requirements.filter { !supports($0) }
    }

}

/// Records which capability dimensions were actually present in provider
/// metadata. A generic OpenAI-compatible `/models` row often contains only an
/// ID; the adapter still uses text as its safe chat baseline, but the UI must
/// not present that baseline as a provider-verified text-only declaration.
struct ProviderCapabilityEvidence: Codable, Equatable, Hashable, Sendable {
    let inputModalitiesAdvertised: Bool
    let outputModalitiesAdvertised: Bool
    let supportedParametersAdvertised: Bool
    let reasoningEffortsAdvertised: Bool

    init(
        inputModalitiesAdvertised: Bool,
        outputModalitiesAdvertised: Bool,
        supportedParametersAdvertised: Bool,
        reasoningEffortsAdvertised: Bool
    ) {
        self.inputModalitiesAdvertised = inputModalitiesAdvertised
        self.outputModalitiesAdvertised = outputModalitiesAdvertised
        self.supportedParametersAdvertised = supportedParametersAdvertised
        self.reasoningEffortsAdvertised = reasoningEffortsAdvertised
    }

    var isUnknown: Bool {
        !inputModalitiesAdvertised
            && !outputModalitiesAdvertised
            && !supportedParametersAdvertised
            && !reasoningEffortsAdvertised
    }

    var isPartial: Bool {
        !isUnknown && !isFullyAdvertised
    }

    var isFullyAdvertised: Bool {
        inputModalitiesAdvertised
            && outputModalitiesAdvertised
            && supportedParametersAdvertised
            && reasoningEffortsAdvertised
    }

    static let unknown = Self(
        inputModalitiesAdvertised: false,
        outputModalitiesAdvertised: false,
        supportedParametersAdvertised: false,
        reasoningEffortsAdvertised: false
    )

    /// Used by descriptors constructed from an explicit, typed capability set
    /// rather than a partially shaped remote response.
    static let advertised = Self(
        inputModalitiesAdvertised: true,
        outputModalitiesAdvertised: true,
        supportedParametersAdvertised: true,
        reasoningEffortsAdvertised: true
    )

    func pickerSummary(
        inputModalities: Set<ProviderInputModality>,
        reasoningEfforts: [String]
    ) -> String {
        if isUnknown { return "Capabilities unknown" }

        var values: [String] = []
        if inputModalitiesAdvertised {
            values.append(inputModalities.contains(.image) ? "Images" : "Text")
        }
        if reasoningEffortsAdvertised, !reasoningEfforts.isEmpty {
            values.append("Reasoning")
        }
        if isPartial { values.append("Partial metadata") }
        return values.isEmpty ? "Capability metadata available" : values.joined(separator: " · ")
    }
}

/// A provider model as exposed by a discovery endpoint.  It is intentionally
/// separate from `RuntimeModel`, whose shape is optimized for the existing
/// Codex session UI and connection-scoped selection.
struct ProviderModelDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let description: String?
    let wireProtocol: ProviderWireProtocol
    let capabilities: ProviderCapabilitySet
    let capabilityEvidence: ProviderCapabilityEvidence
    let contextLength: Int?
    let maxCompletionTokens: Int?

    var pickerCapabilitySummary: String {
        capabilityEvidence.pickerSummary(
            inputModalities: capabilities.inputModalities,
            reasoningEfforts: capabilities.reasoningEfforts
        )
    }

    init(
        id: String,
        displayName: String? = nil,
        description: String? = nil,
        wireProtocol: ProviderWireProtocol,
        capabilities: ProviderCapabilitySet,
        capabilityEvidence: ProviderCapabilityEvidence = .advertised,
        contextLength: Int? = nil,
        maxCompletionTokens: Int? = nil
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw ProviderCapabilityError.emptyModelID
        }
        self.id = normalizedID
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ?? normalizedID
        self.description = description?.nilIfBlank
        self.wireProtocol = wireProtocol
        self.capabilities = capabilities
        self.capabilityEvidence = capabilityEvidence
        self.contextLength = contextLength
        self.maxCompletionTokens = maxCompletionTokens
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case description
        case wireProtocol
        case capabilities
        case capabilityEvidence
        case contextLength
        case maxCompletionTokens
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capabilities = try container.decode(ProviderCapabilitySet.self, forKey: .capabilities)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            description: container.decodeIfPresent(String.self, forKey: .description),
            wireProtocol: container.decode(ProviderWireProtocol.self, forKey: .wireProtocol),
            capabilities: capabilities,
            capabilityEvidence: container.decodeIfPresent(
                ProviderCapabilityEvidence.self,
                forKey: .capabilityEvidence
            ) ?? Self.inferredLegacyEvidence(for: capabilities),
            contextLength: container.decodeIfPresent(Int.self, forKey: .contextLength),
            maxCompletionTokens: container.decodeIfPresent(Int.self, forKey: .maxCompletionTokens)
        )
    }

    /// Decodes the stable subset of OpenRouter's `/models` response that an
    /// adapter needs for capability negotiation. Unknown modalities and
    /// parameters are ignored so a newer catalog does not break older Onyx.
    static func openRouter(from value: JSONValue) throws -> Self {
        guard let id = value["id"]?.stringValue else {
            throw ProviderCapabilityError.missingModelField("id")
        }

        let architecture = value["architecture"]
        let inputModalitiesAdvertised = architecture?["input_modalities"]?.arrayValue != nil
        let outputModalitiesAdvertised = architecture?["output_modalities"]?.arrayValue != nil
        let supportedParametersAdvertised = value["supported_parameters"]?.arrayValue != nil
        let reasoningEffortsAdvertised = value["reasoning"]?["supported_efforts"]?.arrayValue != nil
        let inputModalities = Self.decodeSet(
            architecture?["input_modalities"],
            as: ProviderInputModality.self,
            default: [.text]
        )
        let outputModalities = Self.decodeSet(
            architecture?["output_modalities"],
            as: ProviderOutputModality.self,
            default: [.text]
        )
        let catalogParameters: [ProviderRequestParameter] =
            value["supported_parameters"]?.arrayValue?.compactMap { value in
                guard let raw = value.stringValue else { return nil }
                return ProviderRequestParameter.fromOpenRouterCatalog(raw)
            } ?? []
        let supportedParameters = Set(catalogParameters)
        let reasoningEfforts = value["reasoning"]?["supported_efforts"]?.arrayValue?
            .compactMap(\.stringValue) ?? []

        return try Self(
            id: id,
            displayName: value["name"]?.stringValue,
            description: value["description"]?.stringValue,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(
                inputModalities: inputModalities,
                outputModalities: outputModalities,
                supportedParameters: supportedParameters,
                reasoningEfforts: reasoningEfforts
            ),
            capabilityEvidence: ProviderCapabilityEvidence(
                inputModalitiesAdvertised: inputModalitiesAdvertised,
                outputModalitiesAdvertised: outputModalitiesAdvertised,
                supportedParametersAdvertised: supportedParametersAdvertised,
                reasoningEffortsAdvertised: reasoningEffortsAdvertised
            ),
            contextLength: value["context_length"]?.intValue,
            maxCompletionTokens: value["top_provider"]?["max_completion_tokens"]?.intValue
        )
    }

    /// Decodes every usable model from an OpenRouter `/models` envelope while
    /// isolating malformed catalog entries. Discovery should remain usable
    /// when one newly introduced model is missing a stable field.
    static func openRouterCatalog(from response: JSONValue) -> [Self] {
        let values = response["data"]?.arrayValue ?? response.arrayValue ?? []
        return values.compactMap { try? Self.openRouter(from: $0) }
    }

    private static func decodeSet<T: RawRepresentable & Hashable>(
        _ value: JSONValue?,
        as type: T.Type,
        default fallback: Set<T> = []
    ) -> Set<T> where T.RawValue == String {
        guard let values = value?.arrayValue else { return fallback }
        return Set(values.compactMap { value in
            guard let raw = value.stringValue else { return nil }
            return T(rawValue: raw)
        })
    }

    /// Older cached catalogs predate explicit evidence flags. Preserve
    /// non-baseline metadata that can only have come from a provider response,
    /// while treating the old text-only defaults as unknown rather than making
    /// a stronger claim during migration.
    private static func inferredLegacyEvidence(
        for capabilities: ProviderCapabilitySet
    ) -> ProviderCapabilityEvidence {
        ProviderCapabilityEvidence(
            inputModalitiesAdvertised: capabilities.inputModalities != [.text],
            outputModalitiesAdvertised: capabilities.outputModalities != [.text],
            supportedParametersAdvertised: !capabilities.supportedParameters.isEmpty,
            reasoningEffortsAdvertised: !capabilities.reasoningEfforts.isEmpty
        )
    }
}

/// A durable, credential-free description of one configured account/endpoint.
/// It is a future composition input, not a registry entry by itself. The
/// credential reference identifies where a provider adapter may obtain a
/// secret; it never carries the secret or an OAuth token.
struct ProviderCredentialReference: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case codexManaged
        case keychainAPIKey
        case keychainOAuth
        case keychainPersonalAccessToken
        case none
    }

    let kind: Kind
    let keychainService: String?
    let keychainAccount: String?

    init(
        kind: Kind,
        keychainService: String? = nil,
        keychainAccount: String? = nil
    ) throws {
        let service = keychainService?.nilIfBlank
        let account = keychainAccount?.nilIfBlank
        switch kind {
        case .codexManaged, .none:
            guard service == nil, account == nil else {
                throw ProviderCapabilityError.unexpectedCredentialLocator(kind)
            }
        case .keychainAPIKey, .keychainOAuth, .keychainPersonalAccessToken:
            guard service != nil else {
                throw ProviderCapabilityError.missingCredentialLocator(kind)
            }
        }
        self.kind = kind
        self.keychainService = service
        self.keychainAccount = account
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case keychainService
        case keychainAccount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(Kind.self, forKey: .kind),
            keychainService: container.decodeIfPresent(String.self, forKey: .keychainService),
            keychainAccount: container.decodeIfPresent(String.self, forKey: .keychainAccount)
        )
    }

    static let codexManaged: Self = try! Self(kind: .codexManaged)
    static let none: Self = try! Self(kind: .none)

    static func keychainAPIKey(service: String, account: String? = nil) throws -> Self {
        try Self(kind: .keychainAPIKey, keychainService: service, keychainAccount: account)
    }

    static func keychainOAuth(service: String, account: String? = nil) throws -> Self {
        try Self(kind: .keychainOAuth, keychainService: service, keychainAccount: account)
    }
}

/// Provider/account configuration that can be persisted without exposing
/// credentials. No instance is registered in production until a real adapter
/// implements the protocol and lifecycle contract.
struct ProviderConnectionDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: ProviderConnectionID
    let adapterID: RuntimeAdapterID
    let displayName: String
    let wireProtocol: ProviderWireProtocol
    let endpoint: URL
    let credential: ProviderCredentialReference
    let transportSecurity: ProviderConnectionTransportSecurity
    let transportCapabilities: Set<ProviderTransportCapability>

    init(
        id: ProviderConnectionID,
        adapterID: RuntimeAdapterID,
        displayName: String,
        wireProtocol: ProviderWireProtocol,
        endpoint: URL,
        credential: ProviderCredentialReference,
        transportSecurity: ProviderConnectionTransportSecurity = .requireTLS,
        transportCapabilities: Set<ProviderTransportCapability> = []
    ) throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCapabilityError.emptyConnectionID
        }
        guard !adapterID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCapabilityError.emptyAdapterID
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCapabilityError.emptyDisplayName
        }
        guard let scheme = endpoint.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = endpoint.host, !host.isEmpty else {
            throw ProviderCapabilityError.invalidEndpoint(endpoint.absoluteString)
        }
        guard endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw ProviderCapabilityError.invalidEndpoint(endpoint.absoluteString)
        }
        if scheme == "http" {
            guard ProviderBaseURLNormalizer.isAllowedInsecureHTTPHost(host),
                  transportSecurity == .allowInsecureHTTP
            else {
                throw ProviderCapabilityError.insecureEndpoint(endpoint.absoluteString)
            }
            guard credential.kind == .none else {
                throw ProviderCapabilityError.insecureCredential(endpoint.absoluteString)
            }
        }
        self.id = id
        self.adapterID = adapterID
        self.displayName = displayName
        self.wireProtocol = wireProtocol
        self.endpoint = endpoint
        self.credential = credential
        self.transportCapabilities = transportCapabilities
        self.transportSecurity = transportSecurity
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case adapterID
        case displayName
        case wireProtocol
        case endpoint
        case credential
        case transportCapabilities
        case transportSecurity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ProviderConnectionID.self, forKey: .id),
            adapterID: container.decode(RuntimeAdapterID.self, forKey: .adapterID),
            displayName: container.decode(String.self, forKey: .displayName),
            wireProtocol: container.decode(ProviderWireProtocol.self, forKey: .wireProtocol),
            endpoint: container.decode(URL.self, forKey: .endpoint),
            credential: container.decode(ProviderCredentialReference.self, forKey: .credential),
            transportSecurity: container.decodeIfPresent(
                ProviderConnectionTransportSecurity.self,
                forKey: .transportSecurity
            ) ?? .requireTLS,
            transportCapabilities: container.decodeIfPresent(
                Set<ProviderTransportCapability>.self,
                forKey: .transportCapabilities
            ) ?? []
        )
    }

    /// Descriptor only: this does not create an adapter, read a key, or
    /// register a connection in `RuntimeRegistry`.
    static func openRouter(
        connectionID: ProviderConnectionID = ProviderConnectionID("openrouter.default"),
        keychainService: String = "dev.peteallen.onyx.openrouter"
    ) throws -> Self {
        try Self(
            id: connectionID,
            adapterID: RuntimeAdapterID("openai.compatible.chat"),
            displayName: "OpenRouter",
            wireProtocol: .openAIChatCompletions,
            endpoint: URL(string: "https://openrouter.ai/api/v1")!,
            credential: .keychainAPIKey(service: keychainService),
            transportCapabilities: [.streaming, .streamUsage]
        )
    }

    /// Descriptor only: Claude uses its native Messages protocol and is not
    /// silently treated as an OpenAI-compatible endpoint.
    static func claude(
        connectionID: ProviderConnectionID = ProviderConnectionID("anthropic.default"),
        keychainService: String = "dev.peteallen.onyx.anthropic"
    ) throws -> Self {
        try Self(
            id: connectionID,
            adapterID: RuntimeAdapterID("anthropic.messages"),
            displayName: "Claude",
            wireProtocol: .anthropicMessages,
            endpoint: URL(string: "https://api.anthropic.com")!,
            credential: .keychainAPIKey(service: keychainService),
            transportCapabilities: [.streaming]
        )
    }
}

/// Performs the small piece of negotiation that can be made without opening
/// a network connection: the model metadata and configured connection must
/// agree on a wire protocol. Capability fields remain model/endpoint-scoped;
/// no guessed provider defaults are added here.
enum ProviderCapabilityNegotiator {
    static func negotiate(
        connection: ProviderConnectionDescriptor,
        model: ProviderModelDescriptor
    ) throws -> NegotiatedProviderCapabilities {
        guard connection.wireProtocol == model.wireProtocol else {
            throw ProviderCapabilityError.protocolMismatch(
                expected: connection.wireProtocol,
                actual: model.wireProtocol
            )
        }
        return NegotiatedProviderCapabilities(
            model: model.capabilities,
            transport: connection.transportCapabilities
        )
    }
}

struct NegotiatedProviderCapabilities: Equatable, Hashable, Sendable {
    let model: ProviderCapabilitySet
    let transport: Set<ProviderTransportCapability>

    func supports(_ requirement: ProviderCapabilityRequirement) -> Bool {
        if case let .transport(capability) = requirement {
            return transport.contains(capability)
        }
        return model.supports(requirement)
    }

    func missing(
        _ requirements: some Sequence<ProviderCapabilityRequirement>
    ) -> [ProviderCapabilityRequirement] {
        requirements.filter { !supports($0) }
    }
}

enum ProviderCapabilityError: LocalizedError, Equatable, Sendable {
    case emptyConnectionID
    case emptyAdapterID
    case emptyDisplayName
    case invalidEndpoint(String)
    case insecureEndpoint(String)
    case insecureCredential(String)
    case emptyModelID
    case missingModelField(String)
    case unexpectedCredentialLocator(ProviderCredentialReference.Kind)
    case missingCredentialLocator(ProviderCredentialReference.Kind)
    case protocolMismatch(expected: ProviderWireProtocol, actual: ProviderWireProtocol)
    case missingCapabilities([ProviderCapabilityRequirement])
    case unsupportedLocalImagePath(String)
    case unreadableLocalImagePath(String)
    case invalidImageURL(String)
    case emptyTurnInput

    var errorDescription: String? {
        switch self {
        case .emptyConnectionID: "Provider connection ID cannot be empty."
        case .emptyAdapterID: "Provider adapter ID cannot be empty."
        case .emptyDisplayName: "Provider display name cannot be empty."
        case let .invalidEndpoint(endpoint): "Provider endpoint is invalid: \(endpoint)."
        case let .insecureEndpoint(endpoint): "Provider endpoint must use HTTPS unless clear-text HTTP was explicitly acknowledged for a literal loopback, private-network, or link-local IP address: \(endpoint)."
        case let .insecureCredential(endpoint): "Provider credentials cannot be configured for clear-text HTTP; use HTTPS: \(endpoint)."
        case .emptyModelID: "Provider model ID cannot be empty."
        case let .missingModelField(field): "Provider model metadata is missing \(field)."
        case let .unexpectedCredentialLocator(kind): "Credential kind \(kind.rawValue) cannot use a keychain locator."
        case let .missingCredentialLocator(kind): "Credential kind \(kind.rawValue) requires a keychain locator."
        case let .protocolMismatch(expected, actual): "Provider protocol mismatch: expected \(expected.rawValue), got \(actual.rawValue)."
        case let .missingCapabilities(requirements): "Provider model is missing capabilities: \(requirements)."
        case let .unsupportedLocalImagePath(path): "The selected local image format is not supported by this provider: \(path)."
        case let .unreadableLocalImagePath(path): "The selected local image could not be read safely: \(path)."
        case let .invalidImageURL(value): "Image input is not an HTTP(S) URL or image data URL: \(value)."
        case .emptyTurnInput: "A provider turn must contain text or an image."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
