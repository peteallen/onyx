import XCTest
@testable import Onyx

final class ProviderCapabilitiesTests: XCTestCase {
    func testReasoningEffortMetadataIsTrimmedAndStableAcrossPersistence() throws {
        let descriptor = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("acme/vllm-model"),
            "reasoning": .object([
                // Some OpenAI-compatible catalogs are assembled from a
                // whitespace-delimited server flag and can repeat values.
                "supported_efforts": .array([
                    .string(" low "),
                    .string("medium"),
                    .string("low"),
                    .string(""),
                    .string("  "),
                    .string("xhigh"),
                ]),
            ]),
        ]))

        XCTAssertEqual(
            descriptor.capabilities.reasoningEfforts,
            ["low", "medium", "xhigh"]
        )
        XCTAssertTrue(descriptor.capabilities.supports(.reasoningEffort("medium")))
        XCTAssertFalse(descriptor.capabilities.supports(.reasoningEffort(" low ")))

        let roundTripped = try JSONDecoder().decode(
            ProviderModelDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )
        XCTAssertEqual(roundTripped.capabilities.reasoningEfforts, ["low", "medium", "xhigh"])
    }

    func testMalformedNumericLimitsAreIgnoredInsteadOfTrappingCatalogDiscovery() throws {
        let descriptor = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("acme/unsafe-metadata"),
            // These values are valid JSON numbers but are not usable integer
            // model limits. The parser should leave both fields unknown.
            "max_model_len": .number(1e308),
            "context_length": .number(3.5),
            "top_provider": .object([
                "max_completion_tokens": .number(-1e308),
            ]),
        ]))

        XCTAssertNil(descriptor.contextLength)
        XCTAssertNil(descriptor.maxCompletionTokens)
        XCTAssertEqual(descriptor.capabilities.inputModalities, [.text])
    }

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
        XCTAssertTrue(model.capabilities.serverAdvertisesToolUse)
        XCTAssertFalse(model.capabilities.supportsClient(.parameter(.tools)))
        XCTAssertFalse(model.capabilities.supportsClient(.parameter(.toolChoice)))
        XCTAssertFalse(model.capabilities.clientUsableParameters.contains(.tools))
        XCTAssertFalse(model.capabilities.clientUsableParameters.contains(.toolChoice))
        XCTAssertTrue(model.capabilities.supports(.parameter(.structuredOutputs)))
        XCTAssertTrue(model.capabilities.supports(.reasoningEffort("high")))
        XCTAssertFalse(model.capabilities.supports(.reasoningEffort("medium")))
        XCTAssertEqual(model.contextLength, 200_000)
        XCTAssertEqual(model.maxCompletionTokens, 8_192)
        XCTAssertEqual(
            model.pickerCapabilitySummary,
            "Images · Reasoning · Server tools · Onyx tools unavailable"
        )

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

    func testGenericVLLMCatalogKeepsTextBaselineButMarksCapabilitiesUnknown() throws {
        let model = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("acme/unknown-text-model"),
            "object": .string("model"),
            "owned_by": .string("vllm"),
        ]))

        XCTAssertEqual(model.capabilities.inputModalities, [.text])
        XCTAssertEqual(model.capabilities.outputModalities, [.text])
        XCTAssertTrue(model.capabilities.supportedParameters.isEmpty)
        XCTAssertTrue(model.capabilityEvidence.isUnknown)
        XCTAssertEqual(model.pickerCapabilitySummary, "Capabilities unknown")

        let nearMatch = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("acme/qwen3.80-lookalike"),
            "owned_by": .string("vllm"),
        ]))
        XCTAssertTrue(nearMatch.capabilities.reasoningEfforts.isEmpty)
        XCTAssertTrue(nearMatch.capabilityEvidence.isUnknown)
    }

    func testSparseQwen38CatalogUsesVerifiedFamilyReasoningProfile() throws {
        let model = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("Qwen/Qwen3.8-27B-FP8"),
            "object": .string("model"),
            "owned_by": .string("vllm"),
        ]))

        XCTAssertEqual(model.capabilities.inputModalities, [.text])
        XCTAssertEqual(model.capabilities.reasoningEfforts, ["none", "low", "medium", "xhigh"])
        XCTAssertTrue(model.capabilities.supports(.reasoningEffort("medium")))
        XCTAssertFalse(model.capabilities.supports(.reasoningEffort("high")))
        XCTAssertTrue(model.capabilities.supportedParameters.isEmpty)
        XCTAssertEqual(model.capabilities.clientUsableParameters, [.reasoningEffort])
        XCTAssertEqual(model.preferredDefaultReasoningEffort, "xhigh")
        XCTAssertEqual(model.pickerCapabilitySummary, "Reasoning · Partial metadata")
        XCTAssertTrue(model.capabilityEvidence.isPartial)
        XCTAssertFalse(model.capabilityEvidence.reasoningEffortsAdvertised)
        XCTAssertTrue(model.capabilityEvidence.reasoningEffortsVerifiedByClient)
    }

    func testQwen38CatalogWithReasoningParameterUsesVerifiedMissingEffortMatrix() throws {
        let model = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("Qwen/Qwen3.8-27B-FP8"),
            "supported_parameters": .array([.string("reasoning_effort")]),
        ]))

        XCTAssertEqual(model.capabilities.supportedParameters, [.reasoningEffort])
        XCTAssertEqual(model.capabilities.reasoningEfforts, ["none", "low", "medium", "xhigh"])
        XCTAssertTrue(model.capabilityEvidence.supportedParametersAdvertised)
        XCTAssertFalse(model.capabilityEvidence.reasoningEffortsAdvertised)
        XCTAssertTrue(model.capabilityEvidence.reasoningEffortsVerifiedByClient)

        let explicitOmission = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("Qwen/Qwen3.8-27B-FP8"),
            "supported_parameters": .array([.string("tools")]),
        ]))
        XCTAssertTrue(explicitOmission.capabilities.reasoningEfforts.isEmpty)
        XCTAssertFalse(explicitOmission.capabilityEvidence.reasoningEffortsVerifiedByClient)
    }

    func testExactVLLMModelsResponsePreservesServerCapabilitiesAndContextLength() throws {
        // This is the shape returned by the configured Qwen vLLM endpoint.
        // Keep the provider-only fields in the fixture so parser changes do
        // not silently throw away useful metadata when vLLM adds fields.
        let response = """
        {
          "object": "list",
          "data": [
            {
              "id": "Qwen/Qwen3.8-27B-FP8",
              "object": "model",
              "created": 1787446223,
              "owned_by": "vllm",
              "root": "/root/.cache/huggingface/local/qwen38-official-fp8-017b9c7a",
              "parent": null,
              "max_model_len": 262144,
              "permission": [
                {
                  "id": "modelperm-89ef5994b9094a28",
                  "object": "model_permission",
                  "created": 1787446223,
                  "allow_create_engine": false,
                  "allow_sampling": true,
                  "allow_logprobs": true,
                  "allow_search_indices": false,
                  "allow_view": true,
                  "allow_fine_tuning": false,
                  "organization": "*",
                  "group": null,
                  "is_blocking": false
                }
              ],
              "capabilities": ["completion", "tool_use"]
            }
          ]
        }
        """
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(response.utf8)
        )
        let model = try XCTUnwrap(
            ProviderModelDescriptor.openRouterCatalog(from: value).first
        )

        XCTAssertEqual(model.id, "Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(model.contextLength, 262_144)
        XCTAssertEqual(
            model.capabilities.serverAdvertisedCapabilities,
            ["completion", "tool_use"]
        )
        XCTAssertTrue(model.capabilities.serverAdvertisesToolUse)
        XCTAssertEqual(model.capabilities.reasoningEfforts, ["none", "low", "medium", "xhigh"])
        XCTAssertTrue(model.capabilities.supportedParameters.isEmpty)
        XCTAssertEqual(model.capabilities.clientUsableParameters, [.reasoningEffort])
        XCTAssertFalse(
            model.capabilities.supportsClient(.parameter(.tools)),
            "Server tool metadata must not imply an Onyx-executable tool runtime"
        )
        XCTAssertEqual(
            model.pickerCapabilitySummary,
            "Reasoning · Server tools · Onyx tools unavailable · Partial metadata"
        )

        let runtimeModel = RuntimeModel(
            id: model.id,
            displayName: model.displayName,
            description: model.description,
            isDefault: true,
            defaultReasoningEffort: model.preferredDefaultReasoningEffort,
            reasoningEfforts: model.capabilities.reasoningEfforts,
            inputModalities: model.capabilities.inputModalities,
            serverAdvertisedRequestParameters: model.capabilities.supportedParameters,
            supportedRequestParameters: model.capabilities.clientUsableParameters,
            serverAdvertisedCapabilities: model.capabilities.serverAdvertisedCapabilities,
            capabilityEvidence: model.capabilityEvidence
        )
        XCTAssertFalse(runtimeModel.capabilityMetadataIsUnknown)
        XCTAssertTrue(runtimeModel.capabilityMetadataIsPartial)
        XCTAssertEqual(runtimeModel.defaultReasoningEffort, "xhigh")
        XCTAssertEqual(runtimeModel.reasoningEfforts, ["none", "low", "medium", "xhigh"])
        XCTAssertTrue(runtimeModel.serverAdvertisedRequestParameters.isEmpty)
        XCTAssertEqual(runtimeModel.supportedRequestParameters, [.reasoningEffort])

        let roundTripped = try JSONDecoder().decode(
            ProviderModelDescriptor.self,
            from: JSONEncoder().encode(model)
        )
        XCTAssertEqual(roundTripped, model)
    }

    func testCapabilityEvidenceRoundTripsAndLegacyTextOnlyCatalogDecodesAsUnknown() throws {
        let descriptor = try ProviderModelDescriptor(
            id: "image-model",
            wireProtocol: .openAIChatCompletions,
            capabilities: ProviderCapabilitySet(inputModalities: [.text, .image]),
            capabilityEvidence: ProviderCapabilityEvidence(
                inputModalitiesAdvertised: true,
                outputModalitiesAdvertised: false,
                supportedParametersAdvertised: false,
                reasoningEffortsAdvertised: false
            )
        )
        let roundTripped = try JSONDecoder().decode(
            ProviderModelDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )
        XCTAssertEqual(roundTripped, descriptor)
        XCTAssertTrue(roundTripped.capabilityEvidence.isPartial)

        let legacy = """
        {
          "id": "legacy-text-only",
          "displayName": "Legacy",
          "wireProtocol": "openAIChatCompletions",
          "capabilities": {
            "inputModalities": ["text"],
            "outputModalities": ["text"],
            "supportedParameters": [],
            "reasoningEfforts": []
          }
        }
        """
        let decodedLegacy = try JSONDecoder().decode(
            ProviderModelDescriptor.self,
            from: Data(legacy.utf8)
        )
        XCTAssertTrue(decodedLegacy.capabilityEvidence.isUnknown)
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

    func testQwenReasoningSelectionUsesVerifiedVLLMFieldsAndPreservesLegacyDisable() throws {
        let connection = try ProviderConnectionDescriptor.openRouter()
        let qwen = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("Qwen/Qwen3.8-27B-FP8"),
            "owned_by": .string("vllm"),
        ]))

        let medium = try OpenAICompatibleChatRequestBuilder.make(
            connection: connection,
            model: qwen,
            inputs: [.text("Think carefully")],
            reasoningEffort: "medium",
            requestBehavior: .init(enableThinking: false)
        )
        XCTAssertEqual(medium.payload["reasoning_effort"], .string("medium"))
        XCTAssertNil(
            medium.payload["chat_template_kwargs"],
            "The task-level reasoning choice must override a legacy provider-wide disable"
        )

        let none = try OpenAICompatibleChatRequestBuilder.make(
            connection: connection,
            model: qwen,
            inputs: [.text("Answer directly")],
            reasoningEffort: "none"
        )
        XCTAssertEqual(none.payload["reasoning_effort"], .string("none"))
        XCTAssertEqual(
            none.payload["chat_template_kwargs"]?["enable_thinking"],
            .bool(false)
        )

        let legacyDisable = try OpenAICompatibleChatRequestBuilder.make(
            connection: connection,
            model: qwen,
            inputs: [.text("Answer directly")],
            requestBehavior: .init(enableThinking: false)
        )
        XCTAssertNil(legacyDisable.payload["reasoning_effort"])
        XCTAssertEqual(
            legacyDisable.payload["chat_template_kwargs"]?["enable_thinking"],
            .bool(false)
        )

        let unknown = try ProviderModelDescriptor.openRouter(from: .object([
            "id": .string("acme/unknown-text-model"),
            "owned_by": .string("vllm"),
        ]))
        XCTAssertThrowsError(
            try OpenAICompatibleChatRequestBuilder.make(
                connection: connection,
                model: unknown,
                inputs: [.text("Do work")],
                reasoningEffort: "medium"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCapabilityError,
                .missingCapabilities([.reasoningEffort("medium")])
            )
        }
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

    func testCodecRejectsClaudeProtocolUnsupportedCapabilitiesAndResolvesSelectedLocalImages() throws {
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
        let localImage = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxProviderCapabilities-\(UUID().uuidString).png")
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
        try imageBytes.write(to: localImage)
        defer { try? FileManager.default.removeItem(at: localImage) }
        let localImageRequest = try OpenAICompatibleChatRequestBuilder.make(
            connection: connection,
            model: imageModel,
            inputs: [.localImagePath(localImage.path)]
        )
        let localImageParts = try XCTUnwrap(
            localImageRequest.payload["messages"]?.arrayValue?.last?["content"]?.arrayValue
        )
        XCTAssertEqual(
            localImageParts.first?["image_url"],
            .object([
                "url": .string("data:image/png;base64,\(imageBytes.base64EncodedString())"),
            ])
        )

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

    func testLegacyDescriptorUsesSameAcknowledgedLocalIPNoCredentialHTTPPolicy() throws {
        XCTAssertThrowsError(
            try ProviderConnectionDescriptor(
                id: ProviderConnectionID("http.unacknowledged"),
                adapterID: RuntimeAdapterID("test.adapter"),
                displayName: "Unacknowledged",
                wireProtocol: .openAIChatCompletions,
                endpoint: URL(string: "http://127.0.0.1:8000/v1")!,
                credential: .none
            )
        ) { error in
            guard case .insecureEndpoint = error as? ProviderCapabilityError else {
                return XCTFail("Expected acknowledgement rejection, got \(error)")
            }
        }

        XCTAssertNoThrow(
            try ProviderConnectionDescriptor(
                id: ProviderConnectionID("http.private"),
                adapterID: RuntimeAdapterID("test.adapter"),
                displayName: "Private",
                wireProtocol: .openAIChatCompletions,
                endpoint: URL(string: "http://192.168.1.20:8000/v1")!,
                credential: .none,
                transportSecurity: .allowInsecureHTTP
            )
        )

        XCTAssertThrowsError(
            try ProviderConnectionDescriptor(
                id: ProviderConnectionID("http.hostname"),
                adapterID: RuntimeAdapterID("test.adapter"),
                displayName: "Hostname",
                wireProtocol: .openAIChatCompletions,
                endpoint: URL(string: "http://provider.example.test:8000/v1")!,
                credential: .none,
                transportSecurity: .allowInsecureHTTP
            )
        ) { error in
            guard case .insecureEndpoint = error as? ProviderCapabilityError else {
                return XCTFail("Expected hostname rejection, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try ProviderConnectionDescriptor(
                id: ProviderConnectionID("http.credential"),
                adapterID: RuntimeAdapterID("test.adapter"),
                displayName: "Credential",
                wireProtocol: .openAIChatCompletions,
                endpoint: URL(string: "http://10.0.0.8:8000/v1")!,
                credential: try .keychainAPIKey(service: "dev.peteallen.onyx.test"),
                transportSecurity: .allowInsecureHTTP
            )
        ) { error in
            guard case .insecureCredential = error as? ProviderCapabilityError else {
                return XCTFail("Expected bearer-over-HTTP rejection, got \(error)")
            }
        }
    }
}
