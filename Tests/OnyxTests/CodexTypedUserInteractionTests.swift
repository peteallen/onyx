import Foundation
import XCTest
@testable import Onyx

final class CodexTypedUserInteractionTests: XCTestCase {
    func testHandshakeOptsIntoExperimentalTypedInteractionProtocol() {
        XCTAssertEqual(
            CodexAppServerHandshake.initializeParams["capabilities"]?["experimentalApi"],
            .bool(true)
        )
    }

    func testModernCommandApprovalProjectsTypedPromptAndWritesStableDecision() async throws {
        let request = AppServerRequest(
            id: .string("command-request"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("command-1"),
                "startedAtMs": .integer(1_787_385_600_000),
                "command": .string("swift test"),
                "cwd": .string("/tmp/onyx"),
                "reason": .string("Verify the build"),
            ])
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: request))
        XCTAssertEqual(interaction.id, .string("command-request"))
        XCTAssertEqual(interaction.threadID, "thread-1")
        XCTAssertEqual(interaction.providerMethod, "item/commandExecution/requestApproval")
        XCTAssertEqual(interaction.title, "Run this command?")
        XCTAssertEqual(
            interaction.detail,
            "Verify the build\nWorking directory: /tmp/onyx."
        )
        guard case let .approval(prompt) = interaction.kind else {
            return XCTFail("Expected a typed approval prompt")
        }
        XCTAssertEqual(prompt.subject, .command)
        XCTAssertEqual(prompt.command, "swift test")
        XCTAssertEqual(prompt.allowedDecisions, Set(ApprovalDecision.allCases))
        XCTAssertTrue(prompt.supportsSessionApproval)

        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()
        _ = try await emitAndAwaitInteraction(request, transport: transport, runtime: runtime)
        try await runtime.respond(to: request.id, with: .approval(.accept))

        let responses = await transport.recordedResponses()
        XCTAssertEqual(
            responses,
            [
                .init(
                    id: .string("command-request"),
                    result: .object(["decision": .string("accept")])
                ),
            ]
        )
        await runtime.disconnect()
    }

    func testModernCommandApprovalHonorsAvailableDecisionsAndShowsAdditionalPermissions() throws {
        let request = AppServerRequest(
            id: .string("command-permissions"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("command-2"),
                "startedAtMs": .integer(1_787_385_600_000),
                "command": .string("swift test"),
                "cwd": .string("/tmp/onyx"),
                "environmentId": .string("local-mac"),
                "networkApprovalContext": .object([
                    "host": .string("api.example.test"),
                    "protocol": .string("https"),
                ]),
                "availableDecisions": .array([
                    .string("accept"),
                    .string("decline"),
                ]),
                "additionalPermissions": .object([
                    "network": .object(["enabled": .bool(true)]),
                    "fileSystem": .object([
                        "read": .array([.string("/private/tmp/legacy-input")]),
                        "write": .array([.string("/private/tmp/legacy-output")]),
                        "entries": .array([
                            .object([
                                "access": .string("read"),
                                "path": .object([
                                    "type": .string("path"),
                                    "path": .string("/private/tmp/onyx-input"),
                                ]),
                            ]),
                            .object([
                                "access": .string("write"),
                                "path": .object([
                                    "type": .string("glob_pattern"),
                                    "pattern": .string("/private/tmp/onyx-output/**"),
                                ]),
                            ]),
                            .object([
                                "access": .string("deny"),
                                "path": .object([
                                    "type": .string("special"),
                                    "value": .object([
                                        "kind": .string("project_roots"),
                                        "subpath": .string(".secrets"),
                                    ]),
                                ]),
                            ]),
                            .object([
                                "access": .string("deny"),
                                "path": .object([
                                    "type": .string("special"),
                                    "value": .object([
                                        "kind": .string("unknown"),
                                        "path": .string("/Volumes/private"),
                                        "subpath": .string("tokens"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: request))
        guard case let .approval(prompt) = interaction.kind else {
            return XCTFail("Expected a typed approval prompt")
        }
        XCTAssertEqual(prompt.subject, .network)
        XCTAssertNil(prompt.command)
        XCTAssertEqual(prompt.allowedDecisions, Set([.accept, .decline]))
        XCTAssertTrue(prompt.allows(.accept))
        XCTAssertFalse(prompt.supportsSessionApproval)
        XCTAssertTrue(prompt.allows(.decline))
        XCTAssertFalse(prompt.allows(.cancel))
        XCTAssertTrue(interaction.detail.contains("Working directory: /tmp/onyx."))
        XCTAssertTrue(interaction.detail.contains("Environment: local-mac."))
        XCTAssertTrue(interaction.detail.contains("Network request: HTTPS api.example.test."))
        XCTAssertTrue(interaction.detail.contains("network access"))
        XCTAssertTrue(interaction.detail.contains("/private/tmp/legacy-input"))
        XCTAssertTrue(interaction.detail.contains("/private/tmp/legacy-output"))
        XCTAssertTrue(interaction.detail.contains("/private/tmp/onyx-input"))
        XCTAssertTrue(interaction.detail.contains("/private/tmp/onyx-output/**"))
        XCTAssertTrue(interaction.detail.contains("denied file access"))
        XCTAssertTrue(interaction.detail.contains("special project_roots; subpath .secrets"))
        XCTAssertTrue(interaction.detail.contains("special unknown; path /Volumes/private; subpath tokens"))
    }

    func testModernFileChangeApprovalProjectsTypedPromptAndWritesStableDecision() async throws {
        let request = AppServerRequest(
            id: .integer(42),
            method: "item/fileChange/requestApproval",
            params: .object([
                "threadId": .string("thread-files"),
                "turnId": .string("turn-files"),
                "itemId": .string("file-change-1"),
                "startedAtMs": .integer(1_787_385_600_001),
                "reason": .string("Update the native transcript"),
                "grantRoot": .string("/tmp/onyx"),
            ])
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: request))
        XCTAssertEqual(interaction.threadID, "thread-files")
        XCTAssertEqual(interaction.title, "Apply these changes?")
        XCTAssertTrue(interaction.detail.contains("Update the native transcript"))
        XCTAssertTrue(interaction.detail.contains("/tmp/onyx"))
        guard case let .approval(prompt) = interaction.kind else {
            return XCTFail("Expected a typed approval prompt")
        }
        XCTAssertEqual(prompt.subject, .fileChanges)
        XCTAssertNil(prompt.command)
        XCTAssertTrue(prompt.supportsSessionApproval)

        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()
        _ = try await emitAndAwaitInteraction(request, transport: transport, runtime: runtime)
        try await runtime.respond(to: request.id, with: .approval(.acceptForSession))

        let responses = await transport.recordedResponses()
        XCTAssertEqual(
            responses,
            [
                .init(
                    id: .integer(42),
                    result: .object(["decision": .string("acceptForSession")])
                ),
            ]
        )
        await runtime.disconnect()
    }

    func testPermissionsApprovalReturnsOnlyTheRequestedProfileWithCorrectScope() async throws {
        let requestedPermissions = JSONValue.object([
            "network": .object(["enabled": .bool(true)]),
            "fileSystem": .object([
                "read": .array([.string("/private/tmp/legacy-read-root")]),
                "write": .array([.string("/private/tmp/legacy-write-root")]),
                "entries": .array([
                    .object([
                        "access": .string("read"),
                        "path": .object([
                            "type": .string("path"),
                            "path": .string("/private/tmp/input"),
                        ]),
                    ]),
                    .object([
                        "access": .string("write"),
                        "path": .object([
                            "type": .string("glob_pattern"),
                            "pattern": .string("/private/tmp/output/**"),
                        ]),
                    ]),
                    .object([
                        "access": .string("deny"),
                        "path": .object([
                            "type": .string("special"),
                            "value": .object([
                                "kind": .string("tmpdir"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let accepted = AppServerRequest(
            id: .string("permissions-accept"),
            method: "item/permissions/requestApproval",
            params: .object([
                "threadId": .string("thread-permissions"),
                "turnId": .string("turn-permissions"),
                "itemId": .string("permission-tool-1"),
                "startedAtMs": .integer(1_787_385_600_002),
                "cwd": .string("/tmp/onyx"),
                "environmentId": .string("devbox-17"),
                "reason": .string("Read the input and write the generated app"),
                "permissions": requestedPermissions,
            ])
        )
        let declined = AppServerRequest(
            id: .string("permissions-decline"),
            method: accepted.method,
            params: accepted.params
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: accepted))
        guard case let .approval(prompt) = interaction.kind else {
            return XCTFail("Expected a typed approval prompt")
        }
        XCTAssertEqual(prompt.subject, .permissions)
        XCTAssertTrue(interaction.detail.contains("Working directory: /tmp/onyx."))
        XCTAssertTrue(interaction.detail.contains("Environment: devbox-17."))
        XCTAssertTrue(interaction.detail.contains("network access"))
        XCTAssertTrue(interaction.detail.contains("additional file reads"))
        XCTAssertTrue(interaction.detail.contains("additional file writes"))
        XCTAssertTrue(interaction.detail.contains("/private/tmp/legacy-read-root"))
        XCTAssertTrue(interaction.detail.contains("/private/tmp/legacy-write-root"))
        XCTAssertTrue(interaction.detail.contains("path /private/tmp/input"))
        XCTAssertTrue(interaction.detail.contains("glob /private/tmp/output/**"))
        XCTAssertTrue(interaction.detail.contains("denied file access"))
        XCTAssertTrue(interaction.detail.contains("special tmpdir"))

        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        _ = try await emitAndAwaitInteraction(accepted, transport: transport, runtime: runtime)
        try await runtime.respond(to: accepted.id, with: .approval(.acceptForSession))

        _ = try await emitAndAwaitInteraction(declined, transport: transport, runtime: runtime)
        try await runtime.respond(to: declined.id, with: .approval(.decline))

        let responses = await transport.recordedResponses()
        XCTAssertEqual(
            responses,
            [
                .init(
                    id: accepted.id,
                    result: .object([
                        "permissions": requestedPermissions,
                        "scope": .string("session"),
                    ])
                ),
                .init(
                    id: declined.id,
                    result: .object([
                        "permissions": .object([:]),
                        "scope": .string("turn"),
                    ])
                ),
            ]
        )
        await runtime.disconnect()
    }

    func testRequestUserInputProjectsQuestionsAndNestsAnswersByQuestionID() async throws {
        let request = AppServerRequest(
            id: .string("questions-request"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-questions"),
                "turnId": .string("turn-questions"),
                "itemId": .string("questions-1"),
                "isBlocking": .bool(true),
                "autoResolutionMs": .integer(30_000),
                "questions": .array([
                    .object([
                        "id": .string("workspace"),
                        "header": .string("Workspace"),
                        "question": .string("Which workspace should Onyx use?"),
                        "isOther": .bool(true),
                        "isSecret": .bool(false),
                        "options": .array([
                            .object([
                                "label": .string("Current folder"),
                                "description": .string("Keep the selected project"),
                            ]),
                            .object([
                                "label": .string("New worktree"),
                                "description": .string("Create an isolated checkout"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: request))
        XCTAssertEqual(interaction.title, "Workspace")
        XCTAssertEqual(interaction.detail, "Which workspace should Onyx use?")
        guard case let .questions(prompt) = interaction.kind else {
            return XCTFail("Expected a typed question prompt")
        }
        XCTAssertTrue(prompt.isBlocking)
        XCTAssertEqual(
            prompt.questions,
            [
                RuntimeQuestion(
                    id: "workspace",
                    header: "Workspace",
                    prompt: "Which workspace should Onyx use?",
                    options: [
                        RuntimeQuestionOption(label: "Current folder", detail: "Keep the selected project"),
                        RuntimeQuestionOption(label: "New worktree", detail: "Create an isolated checkout"),
                    ],
                    allowsOther: true,
                    isSecret: false
                ),
            ]
        )

        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()
        _ = try await emitAndAwaitInteraction(request, transport: transport, runtime: runtime)
        try await runtime.respond(
            to: request.id,
            with: .answers(["workspace": ["Current folder", "Keep generated files"]])
        )

        let responses = await transport.recordedResponses()
        XCTAssertEqual(
            responses,
            [
                .init(
                    id: request.id,
                    result: .object([
                        "answers": .object([
                            "workspace": .object([
                                "answers": .array([
                                    .string("Current folder"),
                                    .string("Keep generated files"),
                                ]),
                            ]),
                        ]),
                    ])
                ),
            ]
        )
        await runtime.disconnect()
    }

    func testMCPFormProjectsProviderNeutralFieldsAndWritesAcceptAndDeclineShapes() async throws {
        let responseMetadata = JSONValue.object([
            "requestToken": .string("mcp-request-token"),
            "attempt": .integer(2),
        ])
        let params = JSONValue.object([
            "threadId": .string("thread-form"),
            "turnId": .string("turn-form"),
            "serverName": .string("Deployments"),
            "mode": .string("form"),
            "message": .string("Choose deployment settings"),
            "_meta": responseMetadata,
            "requestedSchema": .object([
                "type": .string("object"),
                "required": .array([.string("attempts"), .string("region")]),
                "properties": .object([
                    "attempts": .object([
                        "type": .string("integer"),
                        "title": .string("Attempts"),
                        "default": .integer(2),
                    ]),
                    "notify": .object([
                        "type": .string("boolean"),
                        "title": .string("Notify team"),
                    ]),
                    "region": .object([
                        "type": .string("string"),
                        "title": .string("Region"),
                        "enum": .array([.string("us"), .string("eu")]),
                        "enumNames": .array([
                            .string("United States"),
                            .string("Europe"),
                        ]),
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "title": .string("Tags"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array([.string("preview"), .string("native")]),
                        ]),
                    ]),
                    "website": .object([
                        "type": .string("string"),
                        "title": .string("Website"),
                        "format": .string("uri"),
                    ]),
                ]),
            ]),
        ])
        let accepted = AppServerRequest(
            id: .string("form-accept"),
            method: "mcpServer/elicitation/request",
            params: params
        )
        let declined = AppServerRequest(
            id: .string("form-decline"),
            method: accepted.method,
            params: params
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: accepted))
        XCTAssertEqual(interaction.title, "Deployments needs input")
        XCTAssertEqual(interaction.detail, "Choose deployment settings")
        guard case let .form(prompt) = interaction.kind else {
            return XCTFail("Expected a typed MCP form")
        }
        XCTAssertEqual(prompt.sourceName, "Deployments")
        XCTAssertEqual(
            prompt.fields,
            [
                RuntimeFormField(
                    id: "attempts",
                    label: "Attempts",
                    detail: nil,
                    isRequired: true,
                    kind: .number(integerOnly: true),
                    initialValue: .integer(2)
                ),
                RuntimeFormField(
                    id: "notify",
                    label: "Notify team",
                    detail: nil,
                    isRequired: false,
                    kind: .toggle,
                    initialValue: nil
                ),
                RuntimeFormField(
                    id: "region",
                    label: "Region",
                    detail: nil,
                    isRequired: true,
                    kind: .singleChoice([
                        RuntimeFormChoice(value: "us", label: "United States"),
                        RuntimeFormChoice(value: "eu", label: "Europe"),
                    ]),
                    initialValue: nil
                ),
                RuntimeFormField(
                    id: "tags",
                    label: "Tags",
                    detail: nil,
                    isRequired: false,
                    kind: .multipleChoice([
                        RuntimeFormChoice(value: "preview", label: "preview"),
                        RuntimeFormChoice(value: "native", label: "native"),
                    ]),
                    initialValue: nil
                ),
                RuntimeFormField(
                    id: "website",
                    label: "Website",
                    detail: nil,
                    isRequired: false,
                    kind: .text(format: "uri"),
                    initialValue: nil
                ),
            ]
        )

        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        _ = try await emitAndAwaitInteraction(accepted, transport: transport, runtime: runtime)
        try await runtime.respond(
            to: accepted.id,
            with: .form(
                action: .accept,
                values: [
                    "attempts": .integer(3),
                    "notify": .boolean(true),
                    "region": .string("us"),
                    "tags": .strings(["preview", "native"]),
                    "website": .string("https://example.com"),
                ]
            )
        )

        _ = try await emitAndAwaitInteraction(declined, transport: transport, runtime: runtime)
        try await runtime.respond(to: declined.id, with: .form(action: .decline, values: [:]))

        let responses = await transport.recordedResponses()
        XCTAssertEqual(
            responses,
            [
                .init(
                    id: accepted.id,
                    result: .object([
                        "_meta": responseMetadata,
                        "action": .string("accept"),
                        "content": .object([
                            "attempts": .integer(3),
                            "notify": .bool(true),
                            "region": .string("us"),
                            "tags": .array([.string("preview"), .string("native")]),
                            "website": .string("https://example.com"),
                        ]),
                    ])
                ),
                .init(
                    id: declined.id,
                    result: .object([
                        "_meta": responseMetadata,
                        "action": .string("decline"),
                        "content": .null,
                    ])
                ),
            ]
        )
        await runtime.disconnect()
    }

    func testMCPExternalLinkPreservesMetadataAndUsesEmptyAcceptedContent() async throws {
        let responseMetadata = JSONValue.object([
            "requestToken": .string("url-request-token"),
        ])
        let params = JSONValue.object([
            "threadId": .string("thread-link"),
            "turnId": .string("turn-link"),
            "serverName": .string("Payments"),
            "mode": .string("url"),
            "message": .string("Confirm the payment in your browser"),
            "url": .string("https://example.com/confirm"),
            "elicitationId": .string("elicitation-1"),
            "_meta": responseMetadata,
        ])
        let accepted = AppServerRequest(
            id: .string("link-accept"),
            method: "mcpServer/elicitation/request",
            params: params
        )
        let canceled = AppServerRequest(
            id: .string("link-cancel"),
            method: accepted.method,
            params: params
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: accepted))
        XCTAssertEqual(interaction.title, "Continue with Payments")
        XCTAssertEqual(interaction.detail, "Confirm the payment in your browser")
        guard case let .externalLink(prompt) = interaction.kind else {
            return XCTFail("Expected a typed MCP external-link prompt")
        }
        XCTAssertEqual(prompt.sourceName, "Payments")
        XCTAssertEqual(prompt.url, URL(string: "https://example.com/confirm"))

        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        _ = try await emitAndAwaitInteraction(accepted, transport: transport, runtime: runtime)
        try await runtime.respond(to: accepted.id, with: .externalLink(.accept))

        _ = try await emitAndAwaitInteraction(canceled, transport: transport, runtime: runtime)
        try await runtime.respond(to: canceled.id, with: .externalLink(.cancel))

        let responses = await transport.recordedResponses()
        XCTAssertEqual(
            responses,
            [
                .init(
                    id: accepted.id,
                    result: .object([
                        "_meta": responseMetadata,
                        "action": .string("accept"),
                        "content": .object([:]),
                    ])
                ),
                .init(
                    id: canceled.id,
                    result: .object([
                        "_meta": responseMetadata,
                        "action": .string("cancel"),
                        "content": .null,
                    ])
                ),
            ]
        )
        await runtime.disconnect()
    }

    func testMCPElicitationOmitsNonObjectMetadataFromResponses() async throws {
        let requests: [(AppServerRequest, RuntimeUserInteractionResponse, JSONValue)] = [
            (
                AppServerRequest(
                    id: .string("form-invalid-meta"),
                    method: "mcpServer/elicitation/request",
                    params: .object([
                        "threadId": .string("thread-form"),
                        "turnId": .string("turn-form"),
                        "serverName": .string("Forms"),
                        "mode": .string("form"),
                        "message": .string("Provide details"),
                        "_meta": .string("not-an-object"),
                        "requestedSchema": .object([
                            "type": .string("object"),
                            "properties": .object([:]),
                        ]),
                    ])
                ),
                .form(action: .accept, values: [:]),
                .object([
                    "action": .string("accept"),
                    "content": .object([:]),
                ])
            ),
            (
                AppServerRequest(
                    id: .string("url-invalid-meta"),
                    method: "mcpServer/elicitation/request",
                    params: .object([
                        "threadId": .string("thread-link"),
                        "turnId": .string("turn-link"),
                        "serverName": .string("Links"),
                        "mode": .string("url"),
                        "message": .string("Continue in the browser"),
                        "url": .string("https://example.com/continue"),
                        "elicitationId": .string("elicitation-invalid-meta"),
                        "_meta": .array([.string("not-an-object")]),
                    ])
                ),
                .externalLink(.cancel),
                .object([
                    "action": .string("cancel"),
                    "content": .null,
                ])
            ),
        ]

        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        for (request, response, _) in requests {
            _ = try await emitAndAwaitInteraction(request, transport: transport, runtime: runtime)
            try await runtime.respond(to: request.id, with: response)
        }

        let responses = await transport.recordedResponses()
        XCTAssertEqual(
            responses,
            requests.map { request, _, expected in
                .init(id: request.id, result: expected)
            }
        )
        await runtime.disconnect()
    }

    func testLegacyExecAndApplyPatchApprovalsUseLegacyDecisionVocabulary() async throws {
        let methods: [(String, JSONValue)] = [
            (
                "execCommandApproval",
                .object([
                    "conversationId": .string("legacy-thread"),
                    "callId": .string("legacy-command"),
                    "command": .array([.string("swift"), .string("test")]),
                    "cwd": .string("/tmp/onyx"),
                    "parsedCmd": .array([]),
                ])
            ),
            (
                "applyPatchApproval",
                .object([
                    "conversationId": .string("legacy-thread"),
                    "callId": .string("legacy-patch"),
                    "fileChanges": .object([
                        "/tmp/onyx/README.md": .object([
                            "type": .string("update"),
                            "unified_diff": .string("@@ -1 +1 @@"),
                        ]),
                    ]),
                ])
            ),
        ]
        let cases: [(ApprovalDecision, JSONValue)] = [
            (.accept, .object(["decision": .string("approved")])),
            (.acceptForSession, .object(["decision": .string("approved_for_session")])),
            (
                .decline,
                .object([
                    "decision": .object([
                        "denied": .object(["rejection": .string("User declined the request.")]),
                    ]),
                ])
            ),
            (.cancel, .object(["decision": .string("abort")])),
        ]

        for (method, params) in methods {
            let projected = try XCTUnwrap(
                CodexProjection.userInteraction(
                    from: AppServerRequest(id: .integer(1), method: method, params: params)
                )
            )
            XCTAssertEqual(projected.threadID, "legacy-thread")
            guard case let .approval(prompt) = projected.kind else {
                return XCTFail("Expected \(method) to project as an approval")
            }
            XCTAssertEqual(prompt.subject, method == "execCommandApproval" ? .command : .fileChanges)

            let transport = TypedInteractionCodexTransport()
            let runtime = CodexRuntime(client: transport)
            _ = try await runtime.connect()

            for (offset, testCase) in cases.enumerated() {
                let request = AppServerRequest(
                    id: .string("\(method)-\(offset)"),
                    method: method,
                    params: params
                )
                _ = try await emitAndAwaitInteraction(request, transport: transport, runtime: runtime)
                try await runtime.respond(to: request.id, with: .approval(testCase.0))
            }

            let responses = await transport.recordedResponses()
            XCTAssertEqual(
                responses.map(\.result),
                cases.map(\.1),
                "Incorrect legacy decision mapping for \(method)"
            )
            await runtime.disconnect()
        }
    }

    func testNonUserServerRequestsDoNotMasqueradeAsApprovals() throws {
        for method in [
            "account/chatgptAuthTokens/refresh",
            "attestation/generate",
            "item/tool/call",
            "future/provider/request",
        ] {
            let request = AppServerRequest(
                id: .string("non-user-\(method)"),
                method: method,
                params: .object(["threadId": .string("thread-1")])
            )
            XCTAssertNil(
                CodexProjection.userInteraction(from: request),
                "\(method) must not appear as an Allow/Decline prompt"
            )
        }

        let malformedKnownPrompt = AppServerRequest(
            id: .string("malformed-questions"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("questions-1"),
                "isBlocking": .bool(true),
                "questions": .array([]),
            ])
        )
        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: malformedKnownPrompt))
        XCTAssertEqual(interaction.kind, .unsupported)

        let duplicateQuestionIDs = AppServerRequest(
            id: .string("duplicate-question-ids"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-1"),
                "questions": .array([
                    .object([
                        "id": .string("choice"),
                        "header": .string("First"),
                        "question": .string("First answer?"),
                    ]),
                    .object([
                        "id": .string("choice"),
                        "header": .string("Second"),
                        "question": .string("Second answer?"),
                    ]),
                ]),
            ])
        )
        let duplicateInteraction = try XCTUnwrap(
            CodexProjection.userInteraction(from: duplicateQuestionIDs)
        )
        XCTAssertEqual(duplicateInteraction.kind, .unsupported)
    }

    func testUnknownServerRequestReturnsMethodNotFoundInsteadOfAnApprovalDecision() async throws {
        let request = AppServerRequest(
            id: .string("future-request"),
            method: "future/provider/request",
            params: .object(["threadId": .string("thread-future")])
        )
        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        let notice = try await emitAndAwaitNotice(request, transport: transport, runtime: runtime)

        XCTAssertEqual(notice.title, "Codex requested an unsupported capability")
        XCTAssertEqual(
            notice.detail,
            "Onyx does not support the app-server request future/provider/request."
        )
        let responses = await transport.recordedResponses()
        let errors = await transport.recordedErrors()
        XCTAssertEqual(responses, [])
        XCTAssertEqual(
            errors,
            [
                .init(
                    id: request.id,
                    code: -32601,
                    message: "Onyx does not support the app-server request future/provider/request."
                ),
            ]
        )
        await runtime.disconnect()
    }

    func testUnsupportedDynamicToolCallReturnsStructuredToolFailure() async throws {
        let request = AppServerRequest(
            id: .string("dynamic-tool-request"),
            method: "item/tool/call",
            params: .object([
                "threadId": .string("thread-tool"),
                "turnId": .string("turn-tool"),
                "callId": .string("call-1"),
                "tool": .string("future_tool"),
                "arguments": .object([:]),
            ])
        )
        let transport = TypedInteractionCodexTransport()
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        _ = try await emitAndAwaitNotice(request, transport: transport, runtime: runtime)

        let errors = await transport.recordedErrors()
        let responses = await transport.recordedResponses()
        XCTAssertEqual(errors, [])
        XCTAssertEqual(
            responses,
            [
                .init(
                    id: request.id,
                    result: .object([
                        "contentItems": .array([
                            .object([
                                "type": .string("inputText"),
                                "text": .string("Onyx does not support the app-server request item/tool/call."),
                            ]),
                        ]),
                        "success": .bool(false),
                    ])
                ),
            ]
        )
        await runtime.disconnect()
    }
}

private actor TypedInteractionCodexTransport: CodexAppServerTransport {
    struct Response: Sendable, Equatable {
        let id: RuntimeRequestID
        let result: JSONValue
    }

    struct ErrorResponse: Sendable, Equatable {
        let id: RuntimeRequestID
        let code: Int
        let message: String
    }

    nonisolated let events: AsyncStream<AppServerEvent>

    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation
    private var responses: [Response] = []
    private var errors: [ErrorResponse] = []

    init() {
        let stream = AsyncStream.makeStream(of: AppServerEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func start() async throws -> AppServerConnection {
        AppServerConnection(generation: 1, initializeResponse: .object([:]))
    }

    func stop() async {}

    func request(method: String, params _: JSONValue) async throws -> JSONValue {
        switch method {
        case "account/read":
            .object([
                "account": .null,
                "requiresOpenaiAuth": .bool(false),
            ])
        case "model/list":
            .object(["data": .array([])])
        default:
            .object([:])
        }
    }

    func respond(id: RuntimeRequestID, result: JSONValue) async throws {
        responses.append(Response(id: id, result: result))
    }

    func respondError(id: RuntimeRequestID, code: Int, message: String) async throws {
        errors.append(ErrorResponse(id: id, code: code, message: message))
    }

    func emit(_ request: AppServerRequest) {
        eventContinuation.yield(.request(generation: 1, request))
    }

    func recordedResponses() -> [Response] {
        responses
    }

    func recordedErrors() -> [ErrorResponse] {
        errors
    }
}

private enum TypedInteractionTestFailure: Error {
    case eventStreamEnded
    case timedOutWaitingForInteraction(RuntimeRequestID)
    case timedOutWaitingForNotice(RuntimeRequestID)
}

private struct RuntimeNotice: Sendable, Equatable {
    let title: String
    let detail: String
}

private func emitAndAwaitInteraction(
    _ request: AppServerRequest,
    transport: TypedInteractionCodexTransport,
    runtime: CodexRuntime
) async throws -> RuntimeUserInteraction {
    try await withThrowingTaskGroup(of: RuntimeUserInteraction.self) { group in
        group.addTask {
            for await event in runtime.events {
                guard case let .userInteractionRequested(interaction) = event,
                      interaction.id == request.id else { continue }
                return interaction
            }
            throw TypedInteractionTestFailure.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw TypedInteractionTestFailure.timedOutWaitingForInteraction(request.id)
        }

        await transport.emit(request)
        guard let interaction = try await group.next() else {
            throw TypedInteractionTestFailure.eventStreamEnded
        }
        group.cancelAll()
        return interaction
    }
}

private func emitAndAwaitNotice(
    _ request: AppServerRequest,
    transport: TypedInteractionCodexTransport,
    runtime: CodexRuntime
) async throws -> RuntimeNotice {
    try await withThrowingTaskGroup(of: RuntimeNotice.self) { group in
        group.addTask {
            for await event in runtime.events {
                guard case let .runtimeNotice(title, detail) = event,
                      detail.contains(request.method) else { continue }
                return RuntimeNotice(title: title, detail: detail)
            }
            throw TypedInteractionTestFailure.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw TypedInteractionTestFailure.timedOutWaitingForNotice(request.id)
        }

        await transport.emit(request)
        guard let notice = try await group.next() else {
            throw TypedInteractionTestFailure.eventStreamEnded
        }
        group.cancelAll()
        return notice
    }
}
