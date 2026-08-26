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

/// Narrow model-family knowledge used only when a generic OpenAI-compatible
/// catalog omits a capability that Onyx has verified for that exact family.
/// Keep this list deliberately small: an arbitrary model name must never gain
/// request controls merely because it is served by vLLM.
enum KnownOpenAICompatibleModelProfile: Equatable, Sendable {
    case qwen38

    static func profile(for modelID: String) -> Self? {
        let normalized = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // This fallback intentionally names only the deployed model whose
        // request contract Onyx has exercised end to end. Similar-looking
        // Qwen variants (for example VL models) must provide their own
        // capability metadata until separately verified.
        if normalized == "qwen/qwen3.8-27b-fp8" {
            return .qwen38
        }
        return nil
    }

    /// Qwen 3.8's vLLM chat contract accepts `none` as the explicit direct
    /// mode plus three thinking levels. Do not expose the generic vLLM schema's
    /// `high` or `max` values: this model rejects both at request time.
    var reasoningEfforts: [String] {
        switch self {
        case .qwen38: ["none", "low", "medium", "xhigh"]
        }
    }

    var defaultReasoningEffort: String {
        switch self {
        case .qwen38: "xhigh"
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
    /// Raw capability names reported by the provider's model catalog. These
    /// are intentionally kept separate from `supportedParameters`: a server
    /// can advertise a feature (for example vLLM's `tool_use`) that Onyx does
    /// not yet implement as a client lifecycle. Unknown names are preserved so
    /// a newer provider catalog does not silently lose information.
    let serverAdvertisedCapabilities: [String]

    init(
        inputModalities: Set<ProviderInputModality> = [.text],
        outputModalities: Set<ProviderOutputModality> = [.text],
        supportedParameters: Set<ProviderRequestParameter> = [],
        reasoningEfforts: [String] = [],
        serverAdvertisedCapabilities: [String] = []
    ) {
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.supportedParameters = supportedParameters
        // Model catalogs are provider-controlled input.  vLLM/OpenAI
        // compatible servers occasionally include padded or repeated effort
        // names; retain the first advertised order while removing values that
        // could never be sent as a useful request parameter.  Keeping this
        // normalization at the capability boundary means persisted catalogs,
        // picker choices, and request negotiation all agree on the same set.
        self.reasoningEfforts = Self.normalizedReasoningEfforts(reasoningEfforts)
        self.serverAdvertisedCapabilities = Self.normalizedServerCapabilities(
            serverAdvertisedCapabilities
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputModalities
        case outputModalities
        case supportedParameters
        case reasoningEfforts
        case serverAdvertisedCapabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputModalities: try container.decodeIfPresent(
                Set<ProviderInputModality>.self,
                forKey: .inputModalities
            ) ?? [.text],
            outputModalities: try container.decodeIfPresent(
                Set<ProviderOutputModality>.self,
                forKey: .outputModalities
            ) ?? [.text],
            supportedParameters: try container.decodeIfPresent(
                Set<ProviderRequestParameter>.self,
                forKey: .supportedParameters
            ) ?? [],
            reasoningEfforts: try container.decodeIfPresent(
                [String].self,
                forKey: .reasoningEfforts
            ) ?? [],
            serverAdvertisedCapabilities: try container.decodeIfPresent(
                [String].self,
                forKey: .serverAdvertisedCapabilities
            ) ?? []
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputModalities, forKey: .inputModalities)
        try container.encode(outputModalities, forKey: .outputModalities)
        try container.encode(supportedParameters, forKey: .supportedParameters)
        try container.encode(reasoningEfforts, forKey: .reasoningEfforts)
        // Keep older persisted catalogs compact while still decoding the new
        // field whenever a provider actually advertises it.
        if !serverAdvertisedCapabilities.isEmpty {
            try container.encode(serverAdvertisedCapabilities, forKey: .serverAdvertisedCapabilities)
        }
    }

    /// A model's remote tool metadata is useful to explain what the server
    /// can do, but it is not a claim that Onyx can execute or approve tools.
    var serverAdvertisesToolUse: Bool {
        supportedParameters.contains(.tools)
            || supportedParameters.contains(.toolChoice)
            || serverAdvertisedCapabilities.contains { rawValue in
                let normalized = rawValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                return normalized == "tool_use"
                    || normalized == "tools"
                    || normalized == "function_call"
                    || normalized == "function_calling"
            }
    }

    /// Request parameters that the current OpenAI-compatible adapter can
    /// actually use. Tool parameters remain server metadata until Onyx has a
    /// decoder, approval surface, and execution lifecycle for tool calls.
    var clientUsableParameters: Set<ProviderRequestParameter> {
        var parameters = supportedParameters.subtracting([.tools, .toolChoice])
        // Exact effort values are sufficient client-side evidence for the
        // typed field. They may come from the provider catalog or from one of
        // the deliberately narrow, live-verified family profiles below; do
        // not force the latter into the server-advertised parameter set.
        if !reasoningEfforts.isEmpty {
            parameters.insert(.reasoningEffort)
        }
        return parameters
    }

    private static func normalizedServerCapabilities(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func normalizedReasoningEfforts(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    func supports(_ requirement: ProviderCapabilityRequirement) -> Bool {
        switch requirement {
        case let .input(modality): inputModalities.contains(modality)
        case let .output(modality): outputModalities.contains(modality)
        case let .parameter(parameter): supportedParameters.contains(parameter)
        case .transport: false
        case let .reasoningEffort(effort):
            reasoningEfforts.contains(effort)
        }
    }

    /// Whether the model metadata is sufficient for a client feature. This
    /// deliberately refuses server-only tool metadata until the runtime can
    /// decode and execute the provider's tool-call protocol.
    func supportsClient(_ requirement: ProviderCapabilityRequirement) -> Bool {
        switch requirement {
        case .parameter(.tools), .parameter(.toolChoice):
            false
        case .parameter(.reasoningEffort):
            !reasoningEfforts.isEmpty
        default:
            supports(requirement)
        }
    }

    func missing(
        _ requirements: some Sequence<ProviderCapabilityRequirement>
    ) -> [ProviderCapabilityRequirement] {
        requirements.filter { !supports($0) }
    }

}

/// Records which capability dimensions have usable evidence. Most evidence is
/// provider-advertised metadata; a deliberately allow-listed exact model
/// family can also supply evidence when a sparse `/models` row contains only
/// its ID. The adapter still uses text as its safe baseline for every other
/// unknown model.
struct ProviderCapabilityEvidence: Codable, Equatable, Hashable, Sendable {
    let inputModalitiesAdvertised: Bool
    let outputModalitiesAdvertised: Bool
    let supportedParametersAdvertised: Bool
    let reasoningEffortsAdvertised: Bool
    /// The provider omitted effort metadata, but Onyx has live-verified an
    /// exact allow-listed model profile. Keep this distinct from advertised
    /// evidence so persisted catalogs and picker copy remain honest.
    let reasoningEffortsVerifiedByClient: Bool

    init(
        inputModalitiesAdvertised: Bool,
        outputModalitiesAdvertised: Bool,
        supportedParametersAdvertised: Bool,
        reasoningEffortsAdvertised: Bool,
        reasoningEffortsVerifiedByClient: Bool = false
    ) {
        self.inputModalitiesAdvertised = inputModalitiesAdvertised
        self.outputModalitiesAdvertised = outputModalitiesAdvertised
        self.supportedParametersAdvertised = supportedParametersAdvertised
        self.reasoningEffortsAdvertised = reasoningEffortsAdvertised
        self.reasoningEffortsVerifiedByClient = reasoningEffortsVerifiedByClient
    }

    private enum CodingKeys: String, CodingKey {
        case inputModalitiesAdvertised
        case outputModalitiesAdvertised
        case supportedParametersAdvertised
        case reasoningEffortsAdvertised
        case reasoningEffortsVerifiedByClient
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputModalitiesAdvertised: try container.decodeIfPresent(
                Bool.self,
                forKey: .inputModalitiesAdvertised
            ) ?? false,
            outputModalitiesAdvertised: try container.decodeIfPresent(
                Bool.self,
                forKey: .outputModalitiesAdvertised
            ) ?? false,
            supportedParametersAdvertised: try container.decodeIfPresent(
                Bool.self,
                forKey: .supportedParametersAdvertised
            ) ?? false,
            reasoningEffortsAdvertised: try container.decodeIfPresent(
                Bool.self,
                forKey: .reasoningEffortsAdvertised
            ) ?? false,
            reasoningEffortsVerifiedByClient: try container.decodeIfPresent(
                Bool.self,
                forKey: .reasoningEffortsVerifiedByClient
            ) ?? false
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputModalitiesAdvertised, forKey: .inputModalitiesAdvertised)
        try container.encode(outputModalitiesAdvertised, forKey: .outputModalitiesAdvertised)
        try container.encode(supportedParametersAdvertised, forKey: .supportedParametersAdvertised)
        try container.encode(reasoningEffortsAdvertised, forKey: .reasoningEffortsAdvertised)
        if reasoningEffortsVerifiedByClient {
            try container.encode(true, forKey: .reasoningEffortsVerifiedByClient)
        }
    }

    var isUnknown: Bool {
        !inputModalitiesAdvertised
            && !outputModalitiesAdvertised
            && !supportedParametersAdvertised
            && !reasoningEffortsAdvertised
            && !reasoningEffortsVerifiedByClient
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
        reasoningEfforts: [String],
        serverAdvertisedParameters: Set<ProviderRequestParameter> = [],
        serverAdvertisedCapabilities: [String] = []
    ) -> String {
        var values: [String] = []
        if inputModalitiesAdvertised {
            values.append(inputModalities.contains(.image) ? "Images" : "Text")
        }
        if reasoningEffortsAdvertised || reasoningEffortsVerifiedByClient,
           !reasoningEfforts.isEmpty {
            values.append("Reasoning")
        }
        let serverAdvertisesToolUse = serverAdvertisedParameters.contains(.tools)
            || serverAdvertisedParameters.contains(.toolChoice)
            || serverAdvertisedCapabilities.contains { rawValue in
                let normalized = rawValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                return normalized == "tool_use"
                    || normalized == "tools"
                    || normalized == "function_call"
                    || normalized == "function_calling"
            }
        if serverAdvertisesToolUse {
            values.append("Server tools · Onyx tools unavailable")
        }
        let hasRawServerMetadata = !serverAdvertisedParameters.isEmpty
            || !serverAdvertisedCapabilities.isEmpty
        if values.isEmpty, isUnknown {
            return hasRawServerMetadata
                ? "Partial capability metadata"
                : "Capabilities unknown"
        }
        if isPartial || (isUnknown && hasRawServerMetadata) {
            values.append("Partial metadata")
        }
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
            reasoningEfforts: capabilities.reasoningEfforts,
            serverAdvertisedParameters: capabilities.supportedParameters,
            serverAdvertisedCapabilities: capabilities.serverAdvertisedCapabilities
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
        let descriptor = try Self(
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
        self = descriptor.applyingKnownModelProfile()
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
        var supportedParameters = Set(catalogParameters)
        let reasoningEfforts = value["reasoning"]?["supported_efforts"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        // A provider that names exact effort values has already supplied
        // enough evidence for the typed effort field, even if its flat
        // `supported_parameters` list is absent or incomplete.
        if !reasoningEfforts.isEmpty {
            supportedParameters.insert(.reasoningEffort)
        }
        let serverAdvertisedCapabilities = value["capabilities"]?.arrayValue?
            .compactMap(\.stringValue) ?? []

        let descriptor = try Self(
            id: id,
            displayName: value["name"]?.stringValue,
            description: value["description"]?.stringValue,
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(
                inputModalities: inputModalities,
                outputModalities: outputModalities,
                supportedParameters: supportedParameters,
                reasoningEfforts: reasoningEfforts,
                serverAdvertisedCapabilities: serverAdvertisedCapabilities
            ),
            capabilityEvidence: ProviderCapabilityEvidence(
                inputModalitiesAdvertised: inputModalitiesAdvertised,
                outputModalitiesAdvertised: outputModalitiesAdvertised,
                supportedParametersAdvertised: supportedParametersAdvertised,
                reasoningEffortsAdvertised: reasoningEffortsAdvertised
            ),
            // vLLM exposes its context window as `max_model_len`, while
            // OpenRouter uses `context_length`. Keep one provider-neutral
            // context field and prefer the canonical OpenRouter value when a
            // router includes both.
            contextLength: Self.positiveMetadataInteger(value["context_length"])
                ?? Self.positiveMetadataInteger(value["max_model_len"]),
            maxCompletionTokens: Self.positiveMetadataInteger(
                value["top_provider"]?["max_completion_tokens"]
            )
        )
        return descriptor.applyingKnownModelProfile()
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

    /// Provider metadata is untrusted JSON.  Do not use a plain `Int(...)`
    /// conversion for floating-point values here: a malformed or adversarial
    /// `/models` response can contain a non-finite or out-of-range number and
    /// otherwise trap the process while the picker is loading.  Capability
    /// limits are meaningful only as positive integral values, so reject
    /// everything else and keep the model usable with an unknown limit.
    private static func positiveMetadataInteger(_ value: JSONValue?) -> Int? {
        switch value {
        case let .integer(number) where number > 0:
            number
        case let .number(number)
            where number.isFinite && number > 0 && number.rounded() == number:
            Int(exactly: number)
        default:
            nil
        }
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

    /// Adds only exact, verified family knowledge when both the parameter and
    /// effort matrix is absent. An explicit provider parameter list that
    /// omits reasoning wins over this fallback; a list that positively names
    /// `reasoning_effort` may use the verified profile to fill only its missing
    /// values.
    func applyingKnownModelProfile() -> Self {
        guard wireProtocol == .openAIChatCompletions,
              !capabilityEvidence.reasoningEffortsAdvertised,
              !capabilityEvidence.supportedParametersAdvertised
                || capabilities.supportedParameters.contains(.reasoningEffort),
              let profile = KnownOpenAICompatibleModelProfile.profile(for: id)
        else { return self }

        return (try? Self(
            id: id,
            displayName: displayName,
            description: description,
            wireProtocol: wireProtocol,
            capabilities: ProviderCapabilitySet(
                inputModalities: capabilities.inputModalities,
                outputModalities: capabilities.outputModalities,
                // Preserve the literal `/models` response here. The verified
                // family profile makes this field client-usable through its
                // exact effort list without pretending the server advertised
                // `reasoning_effort` in a sparse catalog row.
                supportedParameters: capabilities.supportedParameters,
                reasoningEfforts: profile.reasoningEfforts,
                serverAdvertisedCapabilities: capabilities.serverAdvertisedCapabilities
            ),
            capabilityEvidence: ProviderCapabilityEvidence(
                inputModalitiesAdvertised: capabilityEvidence.inputModalitiesAdvertised,
                outputModalitiesAdvertised: capabilityEvidence.outputModalitiesAdvertised,
                supportedParametersAdvertised: capabilityEvidence.supportedParametersAdvertised,
                reasoningEffortsAdvertised: capabilityEvidence.reasoningEffortsAdvertised,
                reasoningEffortsVerifiedByClient: true
            ),
            contextLength: contextLength,
            maxCompletionTokens: maxCompletionTokens
        )) ?? self
    }

    var preferredDefaultReasoningEffort: String? {
        if let profile = KnownOpenAICompatibleModelProfile.profile(for: id),
           capabilities.reasoningEfforts.contains(profile.defaultReasoningEffort)
        {
            return profile.defaultReasoningEffort
        }
        return capabilities.reasoningEfforts.first
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
