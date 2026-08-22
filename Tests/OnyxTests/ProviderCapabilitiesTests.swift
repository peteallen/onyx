import XCTest
@testable import Onyx

final class ProviderCapabilitiesTests: XCTestCase {
    func testOpenRouterAndClaudeDescriptorsAreCredentialFreeAndUseDifferentProtocols() throws {
        let openRouter = try ProviderConnectionDescriptor.openRouter()
        let claude = try ProviderConnectionDescriptor.claude()

        XCTAssertEqual(openRouter.wireProtocol, .openAIChatCompletions)
        XCTAssertEqual(openRouter.endpoint.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouter.credential.kind, .keychainAPIKey)
        XCTAssertEqual(claude.wireProtocol, .anthropicMessages)
        XCTAssertNotEqual(openRouter.adapterID, claude.adapterID)

        let encoded = try JSONEncoder().encode(openRouter)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("OPENROUTER_API_KEY"))
        XCTAssertFalse(json.contains("Bearer"))
    }

    func testOpenRouterCatalogMetadataNegotiatesOnlyAdvertisedRuntimeFeatures() throws {
        let raw: JSONValue = .object([
            "id": .string("anthropic/claude-sonnet-4"),
            "name": .string("Claude Sonnet 4"),
            "architecture": .object([
                "input_modalities": .array([.string("text"), .string("image")]),
                "output_modalities": .array([.string("text")]),
            ]),
            "supported_parameters": .array([
                .string("tools"),
                .string("reasoning"),
                .string("streaming"),
                .string("stream_options"),
                .string("reasoning_effort"),
                .string("include_reasoning"),
                .string("tool_choice"),
                .string("structured_outputs"),
                .string("future_unknown_parameter"),
            ]),
            "reasoning": .object([
                "supported_efforts": .array([.string("low"), .string("high")]),
            ]),
            "context_length": .integer(200_000),
            "top_provider": .object(["max_completion_tokens": .integer(8_192)]),
        ])

        let model = try ProviderModelDescriptor.openRouter(from: raw)
        XCTAssertEqual(model.id, "anthropic/claude-sonnet-4")
        XCTAssertTrue(model.capabilities.supports(.input(.image)))
        XCTAssertTrue(model.capabilities.supports(.parameter(.tools)))
        XCTAssertTrue(model.capabilities.supports(.parameter(.toolChoice)))
        XCTAssertTrue(model.capabilities.supports(.parameter(.structuredOutputs)))
        XCTAssertTrue(model.capabilities.supports(.reasoningEffort("high")))
        XCTAssertFalse(model.capabilities.supports(.reasoningEffort("medium")))
        XCTAssertEqual(model.contextLength, 200_000)
        XCTAssertEqual(model.maxCompletionTokens, 8_192)

        let catalog = ProviderModelDescriptor.openRouterCatalog(
            from: .object([
                "data": .array([
                    raw,
                    .object(["name": .string("Malformed model without an ID")]),
                ]),
            ])
        )
        XCTAssertEqual(catalog, [model])
    }

    func testOpenAICompatibleCodecPreservesHistoryTextImagesReasoningAndUsage() throws {
        let connection = try ProviderConnectionDescriptor.openRouter()
        let model = try ProviderModelDescriptor(
            id: "openai/gpt-4.1",
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(
                inputModalities: [.text, .image],
                supportedParameters: [.reasoning, .reasoningEffort],
                reasoningEfforts: ["low", "high"]
            )
        )
        let request = try OpenAICompatibleChatRequestBuilder.make(
            connection: connection,
            model: model,
            history: [OpenAICompatibleChatMessage(role: .system, text: "Be concise.")],
            inputs: [
                .text("Read this image"),
                .imageURL("data:image/png;base64,AA=="),
            ],
            reasoningEffort: "high"
        )

        XCTAssertEqual(request.messages.count, 2)
        let payload = try XCTUnwrap(request.payload.objectValue)
        XCTAssertEqual(payload["model"], .string("openai/gpt-4.1"))
        XCTAssertEqual(payload["stream"], .bool(true))
        XCTAssertEqual(payload["reasoning_effort"], .string("high"))
        XCTAssertEqual(
            payload["stream_options"],
            .object(["include_usage": .bool(true)])
        )
        let messages = try XCTUnwrap(payload["messages"]?.arrayValue)
        XCTAssertEqual(messages[0]["content"], .string("Be concise."))
        let userParts = try XCTUnwrap(messages[1]["content"]?.arrayValue)
        XCTAssertEqual(userParts[0]["text"], .string("Read this image"))
        XCTAssertEqual(
            userParts[1]["image_url"],
            .object(["url": .string("data:image/png;base64,AA==")])
        )
        XCTAssertFalse(try request.encodedData().isEmpty)
    }

    func testConnectionAndModelMustNegotiateTheSameWireProtocol() throws {
        let connection = try ProviderConnectionDescriptor.openRouter()
        let model = try ProviderModelDescriptor(
            id: "anthropic/claude-sonnet-4",
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet()
        )
        let capabilities = try ProviderCapabilityNegotiator.negotiate(
            connection: connection,
            model: model
        )
        XCTAssertTrue(capabilities.supports(.transport(.streaming)))
        XCTAssertTrue(capabilities.supports(.transport(.streamUsage)))

        let nativeClaude = try ProviderModelDescriptor(
            id: "claude-sonnet-4",
            wireProtocol: .anthropicMessages,
            capabilities: ProviderCapabilitySet()
        )
        XCTAssertThrowsError(
            try ProviderCapabilityNegotiator.negotiate(
                connection: connection,
                model: nativeClaude
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .protocolMismatch(
                    expected: .openAIChatCompletions,
                    actual: .anthropicMessages
                )
            )
        }
    }

    func testCodecRejectsClaudeProtocolUnsupportedCapabilitiesAndUnresolvedLocalImages() throws {
        let connection = try ProviderConnectionDescriptor.openRouter()
        let claude = try ProviderModelDescriptor(
            id: "claude-sonnet",
            wireProtocol: .anthropicMessages,
            capabilities: ProviderCapabilitySet()
        )
        XCTAssertThrowsError(
            try OpenAICompatibleChatRequestBuilder.make(
                connection: connection,
                model: claude,
                inputs: [.text("hello")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .protocolMismatch(expected: .openAIChatCompletions, actual: .anthropicMessages)
            )
        }

        let textOnly = try ProviderModelDescriptor(
            id: "text-only",
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet()
        )
        XCTAssertThrowsError(
            try OpenAICompatibleChatRequestBuilder.make(
                connection: connection,
                model: textOnly,
                inputs: [.imageURL("https://example.com/image.png")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .missingCapabilities([.input(.image)])
            )
        }

        let imageModel = try ProviderModelDescriptor(
            id: "image-model",
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(
                inputModalities: [.text, .image]
            )
        )
        XCTAssertThrowsError(
            try OpenAICompatibleChatRequestBuilder.make(
                connection: connection,
                model: imageModel,
                inputs: [.localImagePath("/tmp/private.png")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .unsupportedLocalImagePath("/tmp/private.png")
            )
        }

        XCTAssertThrowsError(
            try OpenAICompatibleChatRequestBuilder.make(
                connection: connection,
                model: imageModel,
                inputs: [.text(" \n ")]
            )
        ) { error in
            XCTAssertEqual(error as? ProviderCapabilityError, .emptyTurnInput)
        }

        let nonStreaming = try OpenAICompatibleChatRequestBuilder.make(
            connection: connection,
            model: try ProviderModelDescriptor(
                id: "non-streaming",
                wireProtocol: .openAIChatCompletions,
                capabilities: ProviderCapabilitySet()
            ),
            inputs: [.text("hello")],
            stream: false,
            includeStreamingUsage: true
        )
        XCTAssertNil(nonStreaming.payload["stream_options"])
    }

    func testCredentialReferenceRequiresLocatorOnlyForKeychainBackedStrategies() throws {
        XCTAssertThrowsError(
            try ProviderCredentialReference(kind: .keychainAPIKey)
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .missingCredentialLocator(.keychainAPIKey)
            )
        }
        XCTAssertThrowsError(
            try ProviderCredentialReference(
                kind: .none,
                keychainService: "should-not-be-here"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .unexpectedCredentialLocator(.none)
            )
        }
        XCTAssertThrowsError(
            try ProviderCredentialReference(
                kind: .none,
                keychainAccount: "orphan-account"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .unexpectedCredentialLocator(.none)
            )
        }
        let credential = try ProviderCredentialReference.keychainAPIKey(
            service: "dev.peteallen.onyx.test",
            account: "default"
        )
        XCTAssertEqual(credential.keychainService, "dev.peteallen.onyx.test")
        XCTAssertEqual(credential.keychainAccount, "default")
    }

    func testConnectionDecodingRevalidatesEndpointAndCredentialInvariants() throws {
        let valid = try ProviderConnectionDescriptor.openRouter()
        let data = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(ProviderConnectionDescriptor.self, from: data), valid)

        var invalidEndpoint = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        invalidEndpoint["endpoint"] = "http://remote.example/v1"
        let invalidEndpointData = try JSONSerialization.data(withJSONObject: invalidEndpoint)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProviderConnectionDescriptor.self,
                from: invalidEndpointData
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .insecureEndpoint("http://remote.example/v1")
            )
        }

        var invalidCredential = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        invalidCredential["credential"] = [
            "kind": "keychainAPIKey",
            "keychainService": "",
        ]
        let invalidCredentialData = try JSONSerialization.data(withJSONObject: invalidCredential)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProviderConnectionDescriptor.self,
                from: invalidCredentialData
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .missingCredentialLocator(.keychainAPIKey)
            )
        }

        XCTAssertThrowsError(
            try ProviderConnectionDescriptor(
                id: ProviderConnectionID("test.endpoint-query"),
                adapterID: RuntimeAdapterID("test.adapter"),
                displayName: "Query endpoint",
                wireProtocol: .openAIChatCompletions,
                endpoint: try XCTUnwrap(
                    URL(string: "https://example.com/v1?api_key=secret")
                ),
                credential: .none
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .invalidEndpoint("https://example.com/v1?api_key=secret")
            )
        }
    }
}
