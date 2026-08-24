import Foundation

/// A provider-neutral chat message that can be translated to the
/// OpenAI-compatible `/chat/completions` shape. It intentionally contains no
/// authorization, endpoint, or transport behavior.
struct OpenAICompatibleChatMessage: Sendable, Equatable, Hashable {
    enum Role: String, Sendable, Equatable, Hashable {
        case system
        case user
        case assistant
        case tool
    }

    enum ContentPart: Sendable, Equatable, Hashable {
        case text(String)
        case imageURL(String)
    }

    let role: Role
    let parts: [ContentPart]
    /// Present only on an assistant message that asked the client to invoke
    /// one or more functions. The arguments remain the provider's exact JSON
    /// string; protocol decoding must not reinterpret or execute them.
    let toolCalls: [OpenAICompatibleChatToolCall]
    /// Present only on a tool-role message and links its result to the
    /// assistant call that requested it.
    let toolCallID: String?

    init(role: Role, text: String) {
        self.role = role
        self.parts = [.text(text)]
        self.toolCalls = []
        self.toolCallID = nil
    }

    init(
        role: Role,
        parts: [ContentPart],
        toolCalls: [OpenAICompatibleChatToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.parts = parts
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    init(
        assistantToolCalls toolCalls: [OpenAICompatibleChatToolCall],
        text: String? = nil
    ) {
        self.init(
            role: .assistant,
            parts: text.map { [.text($0)] } ?? [],
            toolCalls: toolCalls
        )
    }

    init(toolCallID: String, result: String) {
        self.init(
            role: .tool,
            parts: [.text(result)],
            toolCallID: toolCallID
        )
    }
}

/// One complete function call produced by a chat-completions model. The
/// function type is implicit because this protocol slice intentionally does
/// not support provider-hosted, filesystem, or command tools.
struct OpenAICompatibleChatToolCall: Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let arguments: String

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One function definition encoded in a chat-completions request. Parameters
/// are retained as JSON Schema without interpreting them in the transport.
struct OpenAICompatibleChatFunctionTool: Sendable, Equatable {
    let name: String
    let description: String?
    let parameters: JSONValue
    let strict: Bool?

    init(
        name: String,
        description: String? = nil,
        parameters: JSONValue,
        strict: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

struct OpenAICompatibleChatRequest: Sendable, Equatable {
    let model: String
    let messages: [OpenAICompatibleChatMessage]
    let stream: Bool
    let reasoningEffort: String?
    let includeStreamingUsage: Bool
    let requestBehavior: OpenAICompatibleRequestBehavior
    let tools: [OpenAICompatibleChatFunctionTool]

    init(
        model: String,
        messages: [OpenAICompatibleChatMessage],
        stream: Bool,
        reasoningEffort: String?,
        includeStreamingUsage: Bool,
        requestBehavior: OpenAICompatibleRequestBehavior,
        tools: [OpenAICompatibleChatFunctionTool] = []
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.reasoningEffort = reasoningEffort
        self.includeStreamingUsage = includeStreamingUsage
        self.requestBehavior = requestBehavior
        self.tools = tools
    }

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
        if !tools.isEmpty {
            object["tools"] = .array(tools.map(Self.toolValue))
        }
        let enableThinking: Bool?
        if KnownOpenAICompatibleModelProfile.profile(for: model) == .qwen38,
           let reasoningEffort
        {
            // A per-task selection is more specific than the legacy
            // provider-wide "disable thinking" option. `none` preserves that
            // native Qwen behavior; a selected thinking level relies on the
            // typed `reasoning_effort` field and must not also send `false`.
            enableThinking = reasoningEffort == "none" ? false : nil
        } else {
            enableThinking = requestBehavior.enableThinking
        }
        if let enableThinking {
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
        var object: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
        ]
        if message.role == .assistant, message.parts.isEmpty, !message.toolCalls.isEmpty {
            object["content"] = .null
        } else {
            object["content"] = contentValue(message.parts)
        }
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = .array(message.toolCalls.map(toolCallValue))
        }
        if let toolCallID = message.toolCallID {
            object["tool_call_id"] = .string(toolCallID)
        }
        return .object(object)
    }

    private static func contentValue(
        _ parts: [OpenAICompatibleChatMessage.ContentPart]
    ) -> JSONValue {
        if parts.allSatisfy({ if case .text = $0 { true } else { false } }) {
            return .string(
                parts.compactMap { part in
                    guard case let .text(text) = part else { return nil }
                    return text
                }.joined(separator: "\n")
            )
        }
        return .array(parts.map { part in
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

    private static func toolCallValue(_ call: OpenAICompatibleChatToolCall) -> JSONValue {
        .object([
            "id": .string(call.id),
            "type": .string("function"),
            "function": .object([
                "name": .string(call.name),
                "arguments": .string(call.arguments),
            ]),
        ])
    }

    private static func toolValue(_ tool: OpenAICompatibleChatFunctionTool) -> JSONValue {
        var function: [String: JSONValue] = [
            "name": .string(tool.name),
            "parameters": tool.parameters,
        ]
        if let description = tool.description {
            function["description"] = .string(description)
        }
        if let strict = tool.strict {
            function["strict"] = .bool(strict)
        }
        return .object([
            "type": .string("function"),
            "function": .object(function),
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
                parts.append(.imageURL(try Self.localImageDataURL(path)))
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
            || inputs.contains(where: {
                switch $0 {
                case .imageURL, .localImagePath: true
                case .text: false
                }
            })
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

    /// File-pickers produce local paths, while OpenAI-compatible chat APIs
    /// accept image URLs or data URLs. Resolve only the validated image types
    /// we offer in the composer, keep the payload bounded, and send a data URL
    /// so the provider never needs access to the user's filesystem path.
    private static func localImageDataURL(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let extensionName = url.pathExtension.lowercased()
        let mimeType: String
        switch extensionName {
        case "png": mimeType = "image/png"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "gif": mimeType = "image/gif"
        case "webp": mimeType = "image/webp"
        case "heic", "heif": mimeType = "image/heic"
        default:
            throw ProviderCapabilityError.unsupportedLocalImagePath(path)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw ProviderCapabilityError.unreadableLocalImagePath(path)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= maximumLocalImageBytes
        else {
            throw ProviderCapabilityError.unreadableLocalImagePath(path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ProviderCapabilityError.unreadableLocalImagePath(path)
        }
        guard !data.isEmpty, data.count <= maximumLocalImageBytes else {
            throw ProviderCapabilityError.unreadableLocalImagePath(path)
        }
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private static let maximumLocalImageBytes = 20 * 1_024 * 1_024
}
