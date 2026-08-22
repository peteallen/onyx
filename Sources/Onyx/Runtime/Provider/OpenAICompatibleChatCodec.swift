import Foundation

/// A provider-neutral chat message that can be translated to the
/// OpenAI-compatible `/chat/completions` shape. It intentionally contains no
/// authorization, endpoint, or transport behavior.
struct OpenAICompatibleChatMessage: Sendable, Equatable, Hashable {
    enum Role: String, Sendable, Equatable, Hashable {
        case system
        case user
        case assistant
    }

    enum ContentPart: Sendable, Equatable, Hashable {
        case text(String)
        case imageURL(String)
    }

    let role: Role
    let parts: [ContentPart]

    init(role: Role, text: String) {
        self.role = role
        self.parts = [.text(text)]
    }

    init(role: Role, parts: [ContentPart]) {
        self.role = role
        self.parts = parts
    }
}

struct OpenAICompatibleChatRequest: Sendable, Equatable {
    let model: String
    let messages: [OpenAICompatibleChatMessage]
    let stream: Bool
    let reasoningEffort: String?
    let includeStreamingUsage: Bool
    let requestBehavior: OpenAICompatibleRequestBehavior

    enum EncodingError: LocalizedError, Sendable {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(detail): "Could not encode provider request: \(detail)"
            }
        }
    }

    /// The exact JSON body accepted by OpenAI-compatible chat endpoints. A
    /// sorted encoder makes fixture comparisons stable while keeping all
    /// provider-specific fields behind this codec.
    var payload: JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages.map(Self.messageValue)),
            "stream": .bool(stream),
        ]
        if let reasoningEffort {
            object["reasoning_effort"] = .string(reasoningEffort)
        }
        if includeStreamingUsage && stream {
            object["stream_options"] = .object(["include_usage": .bool(true)])
        }
        if let enableThinking = requestBehavior.enableThinking {
            object["chat_template_kwargs"] = .object([
                "enable_thinking": .bool(enableThinking),
            ])
        }
        return .object(object)
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(payload)
        } catch {
            throw EncodingError.failed(error.localizedDescription)
        }
    }

    private static func messageValue(_ message: OpenAICompatibleChatMessage) -> JSONValue {
        let content: JSONValue
        if message.parts.allSatisfy({ if case .text = $0 { true } else { false } }) {
            content = .string(
                message.parts.compactMap { part in
                    guard case let .text(text) = part else { return nil }
                    return text
                }.joined(separator: "\n")
            )
        } else {
            content = .array(message.parts.map { part in
                switch part {
                case let .text(text):
                    return .object([
                        "text": .string(text),
                        "type": .string("text"),
                    ])
                case let .imageURL(url):
                    return .object([
                        "image_url": .object(["url": .string(url)]),
                        "type": .string("image_url"),
                    ])
                }
            })
        }
        return .object([
            "content": content,
            "role": .string(message.role.rawValue),
        ])
    }
}

/// Builds a single user message from Onyx's ordered turn inputs. This is a
/// codec, not an `AgentRuntime`: remote chat APIs do not inherently provide
/// Codex's thread, sandbox, approval, or local-tool lifecycle semantics.
enum OpenAICompatibleChatRequestBuilder {
    static func make(
        connection: ProviderConnectionDescriptor,
        model: ProviderModelDescriptor,
        history: [OpenAICompatibleChatMessage] = [],
        inputs: [RuntimeTurnInput],
        stream: Bool = true,
        reasoningEffort: String? = nil,
        includeStreamingUsage: Bool = true,
        requestBehavior: OpenAICompatibleRequestBehavior = .init()
    ) throws -> OpenAICompatibleChatRequest {
        let capabilities = try ProviderCapabilityNegotiator.negotiate(
            connection: connection,
            model: model
        )
        return try make(
            model: model,
            capabilities: capabilities,
            history: history,
            inputs: inputs,
            stream: stream,
            reasoningEffort: reasoningEffort,
            includeStreamingUsage: includeStreamingUsage,
            requestBehavior: requestBehavior
        )
    }

    /// Builds from already-negotiated endpoint/model capabilities. Runtime
    /// adapters use this overload when their durable connection record has an
    /// explicit insecure-HTTP acknowledgement that the credential-free
    /// descriptor intentionally cannot represent.
    static func make(
        model: ProviderModelDescriptor,
        capabilities: NegotiatedProviderCapabilities,
        history: [OpenAICompatibleChatMessage] = [],
        inputs: [RuntimeTurnInput],
        stream: Bool = true,
        reasoningEffort: String? = nil,
        includeStreamingUsage: Bool = true,
        requestBehavior: OpenAICompatibleRequestBehavior = .init()
    ) throws -> OpenAICompatibleChatRequest {
        guard model.wireProtocol == .openAIChatCompletions else {
            throw ProviderCapabilityError.protocolMismatch(
                expected: .openAIChatCompletions,
                actual: model.wireProtocol
            )
        }

        let requirements = Self.requirements(
            history: history,
            inputs: inputs,
            stream: stream,
            reasoningEffort: reasoningEffort,
            includeStreamingUsage: includeStreamingUsage
        )
        let missing = capabilities.missing(requirements)
        guard missing.isEmpty else {
            throw ProviderCapabilityError.missingCapabilities(missing)
        }

        var parts: [OpenAICompatibleChatMessage.ContentPart] = []
        for input in inputs {
            switch input {
            case let .text(text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(.text(text))
                }
            case let .localImagePath(path):
                throw ProviderCapabilityError.unsupportedLocalImagePath(path)
            case let .imageURL(value):
                guard Self.isAllowedImageURL(value) else {
                    throw ProviderCapabilityError.invalidImageURL(value)
                }
                parts.append(.imageURL(value))
            }
        }

        guard !parts.isEmpty else {
            throw ProviderCapabilityError.emptyTurnInput
        }
        let user = OpenAICompatibleChatMessage(role: .user, parts: parts)
        return OpenAICompatibleChatRequest(
            model: model.id,
            messages: history + [user],
            stream: stream,
            reasoningEffort: reasoningEffort,
            includeStreamingUsage: includeStreamingUsage,
            requestBehavior: requestBehavior
        )
    }

    private static func requirements(
        history: [OpenAICompatibleChatMessage],
        inputs: [RuntimeTurnInput],
        stream: Bool,
        reasoningEffort: String?,
        includeStreamingUsage: Bool
    ) -> [ProviderCapabilityRequirement] {
        var requirements: [ProviderCapabilityRequirement] = [.output(.text)]
        let historyParts = history.flatMap(\.parts)
        if historyParts.contains(where: { if case .text = $0 { true } else { false } })
            || inputs.contains(where: { if case .text = $0 { true } else { false } })
        {
            requirements.append(.input(.text))
        }
        if historyParts.contains(where: { if case .imageURL = $0 { true } else { false } })
            || inputs.contains(where: { if case .imageURL = $0 { true } else { false } })
        {
            requirements.append(.input(.image))
        }
        if stream { requirements.append(.transport(.streaming)) }
        if includeStreamingUsage && stream { requirements.append(.transport(.streamUsage)) }
        if let reasoningEffort {
            requirements.append(.reasoningEffort(reasoningEffort))
        }
        return requirements
    }

    private static func isAllowedImageURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" {
            return url.host != nil
        }
        guard scheme == "data", value.lowercased().hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ",") else { return false }
        let metadata = value[..<comma].lowercased()
        let payload = value[value.index(after: comma)...]
        return metadata.contains(";base64")
            && !payload.isEmpty
            && Data(base64Encoded: String(payload), options: []) != nil
    }
}
