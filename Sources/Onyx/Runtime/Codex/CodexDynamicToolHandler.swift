import Foundation

/// Credential-free presentation of the one dynamic tool Onyx exposes to
/// Codex. The runtime owns the stable function name and wire shape; production
/// composition can keep the description and target enums current as provider
/// settings change.
struct CodexDynamicToolDefinition: Sendable, Equatable {
    let description: String
    let inputSchema: JSONValue

    init(description: String, inputSchema: JSONValue) {
        self.description = description
        self.inputSchema = inputSchema
    }

    static let onyxDelegate = Self(
        description: "Delegate a bounded, read-only text task to another model configured in Onyx. Include all context the child needs in the prompt because it cannot inspect local files.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "provider": .object([
                    "type": .string("string"),
                    "description": .string("Configured Onyx provider connection ID."),
                ]),
                "model": .object([
                    "type": .string("string"),
                    "description": .string("Model ID advertised by the selected provider."),
                ]),
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("Self-contained task and all context needed to complete it."),
                ]),
                "reasoningEffort": .object([
                    "type": .string("string"),
                    "description": .string("Optional reasoning effort supported by the selected model."),
                ]),
            ]),
            "required": .strings(["provider", "model", "prompt"]),
            "additionalProperties": .bool(false),
        ])
    )
}

/// Sanitized app-server envelope for an `onyx_delegate` invocation. Provider
/// endpoints and credentials are deliberately absent. Parent task context is
/// captured by the runtime when it starts the task rather than trusted from
/// model-authored tool arguments.
struct CodexDynamicToolCall: Sendable, Equatable {
    let threadID: String
    let callID: String
    let arguments: JSONValue
    let parentModelID: String?
    let workingDirectory: String?
}

/// Text is the only output modality in the first delegation slice. Structured
/// metadata can be encoded into `text` by the production handler and is then
/// returned unchanged to Codex as an `inputText` content item.
struct CodexDynamicToolResult: Sendable, Equatable {
    let text: String
    let success: Bool

    static func succeeded(_ text: String) -> Self {
        Self(text: text, success: true)
    }

    static func failed(_ text: String) -> Self {
        Self(text: text, success: false)
    }
}

/// App-lifetime bridge from Codex app-server requests into Onyx-owned
/// delegation. Implementations may be actors; both entry points are async so
/// provider/model catalogs can be refreshed without moving credentials across
/// this boundary.
protocol CodexDynamicToolHandler: Sendable {
    func dynamicToolDefinition() async -> CodexDynamicToolDefinition
    func handleDynamicToolCall(_ call: CodexDynamicToolCall) async throws -> CodexDynamicToolResult
}

extension CodexDynamicToolHandler {
    func dynamicToolDefinition() async -> CodexDynamicToolDefinition {
        .onyxDelegate
    }
}
