import XCTest
@testable import Onyx

final class CodexProjectionTests: XCTestCase {
    func testProjectsThreadAndTranscriptItemsFromStableSchemaShape() throws {
        let fixture = #"""
        {
          "thread": {
            "id": "thread-1",
            "cwd": "/tmp/onyx",
            "preview": "Build a native client",
            "model": "gpt-5.6-terra",
            "isPinned": true,
            "createdAt": 1787385600,
            "updatedAt": 1787385660,
            "status": { "type": "idle" },
            "gitInfo": { "branch": "codex/onyx" },
            "turns": [
              {
                "id": "turn-1",
                "status": "completed",
                "startedAt": 1787385601,
                "items": [
                  {
                    "type": "userMessage",
                    "id": "user-1",
                    "content": [{ "type": "text", "text": "Make it fast" }]
                  },
                  {
                    "type": "agentMessage",
                    "id": "agent-1",
                    "text": "Implemented the native transcript.",
                    "phase": "final_answer"
                  },
                  {
                    "type": "commandExecution",
                    "id": "command-1",
                    "command": ["swift", "test"],
                    "aggregatedOutput": "All tests passed",
                    "status": "completed"
                  }
                ]
              }
            ]
          }
        }
        """#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(fixture.utf8))

        let conversation = try CodexProjection.conversation(from: value)

        XCTAssertEqual(conversation.thread.id, "thread-1")
        XCTAssertEqual(conversation.thread.title, "Build a native client")
        XCTAssertEqual(conversation.thread.branch, "codex/onyx")
        XCTAssertTrue(conversation.thread.isPinned)
        XCTAssertEqual(
            conversation.thread.updatedAt,
            Date(timeIntervalSince1970: 1_787_385_660),
            "Projecting history must preserve the server's task recency"
        )
        XCTAssertEqual(conversation.items.map(\.kind), [.userMessage, .assistantMessage, .command])
        XCTAssertEqual(conversation.turns.map(\.id), ["turn-1"])
        XCTAssertEqual(
            conversation.turns[0].items.map(\.id),
            ["user-1", "agent-1", "command-1"],
            "The flat transcript and the provider turn must share the same item boundary"
        )
        XCTAssertEqual(conversation.turns[0].status, .completed)
        XCTAssertEqual(
            conversation.items.map(\.timestamp),
            Array(repeating: Date(timeIntervalSince1970: 1_787_385_601), count: 3),
            "Schema items without timestamps should inherit their stable turn time"
        )
        XCTAssertEqual(conversation.items[0].body, "Make it fast")
        XCTAssertEqual(conversation.items[2].title, "swift test")
    }

    func testConversationProjectionPreservesMultipleTurnBoundaries() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "thread": {
            "id": "thread-boundaries",
            "updatedAt": 1787385660,
            "turns": [
              {
                "id": "turn-old",
                "status": "completed",
                "startedAt": 1787385601,
                "items": [
                  { "id": "old-user", "type": "userMessage", "text": "First" },
                  { "id": "old-assistant", "type": "agentMessage", "text": "Done" }
                ]
              },
              {
                "id": "turn-new",
                "status": "inProgress",
                "startedAt": 1787385661,
                "items": [
                  { "id": "new-user", "type": "userMessage", "text": "Second" },
                  { "id": "new-command", "type": "commandExecution", "command": ["swift", "test"], "status": "inProgress" }
                ]
              }
            ]
          }
        }
        """#.utf8))

        let conversation = try CodexProjection.conversation(from: value)

        XCTAssertEqual(conversation.turns.map(\.id), ["turn-old", "turn-new"])
        XCTAssertEqual(
            conversation.turns.map { $0.items.map(\.id) },
            [["old-user", "old-assistant"], ["new-user", "new-command"]]
        )
        XCTAssertEqual(conversation.turns.map(\.status), [.completed, .inProgress])
        XCTAssertEqual(
            conversation.items.map(\.id),
            ["old-user", "old-assistant", "new-user", "new-command"]
        )
        XCTAssertEqual(conversation.turns[1].items[1].status, .running)
    }

    func testProjectsStringValuedApprovalID() throws {
        let request = AppServerRequest(
            id: .string("server-request-9"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "command": .string("swift test"),
                "reason": .string("Run the project tests"),
            ])
        )

        let interaction = try XCTUnwrap(CodexProjection.userInteraction(from: request))

        XCTAssertEqual(interaction.id, .string("server-request-9"))
        XCTAssertEqual(interaction.threadID, "thread-1")
        guard case let .approval(approval) = interaction.kind else {
            return XCTFail("Expected a command approval interaction")
        }
        XCTAssertEqual(approval.command, "swift test")
    }

    func testProjectsOneStableTurnFailureInFullAndPaginatedHistory() throws {
        let failedTurn = JSONValue.object([
            "id": .string("failed-turn-7"),
            "status": .string("failed"),
            "startedAt": .integer(1_787_385_601),
            "completedAt": .integer(1_787_385_607),
            "error": .object([
                "message": .string("The provider stopped before returning an answer."),
            ]),
            "items": .array([
                .object([
                    "type": .string("userMessage"),
                    "id": .string("failed-user-7"),
                    "text": .string("Build the site"),
                ]),
            ]),
        ])
        let full = try CodexProjection.conversation(from: .object([
            "thread": .object([
                "id": .string("failed-thread"),
                "preview": .string("Build the site"),
                "turns": .array([failedTurn]),
            ]),
        ]))
        let page = try CodexProjection.historyPage(
            from: .object(["data": .array([failedTurn])]),
            direction: .descending
        )

        let fullFailure = try XCTUnwrap(full.items.last)
        let paginatedFailure = try XCTUnwrap(page.turns.first?.items.last)
        XCTAssertEqual(full.items.filter { $0.kind == .error }.count, 1)
        XCTAssertEqual(page.turns.first?.items.filter { $0.kind == .error }.count, 1)
        XCTAssertEqual(full.turns.map(\.id), ["failed-turn-7"])
        XCTAssertEqual(full.turns.first?.items, full.items)
        XCTAssertEqual(fullFailure.id, "codex-turn-error:failed-turn-7")
        XCTAssertEqual(paginatedFailure.id, fullFailure.id)
        XCTAssertEqual(fullFailure.kind, .error)
        XCTAssertEqual(fullFailure.status, .failed)
        XCTAssertEqual(fullFailure.title, "Response failed")
        XCTAssertEqual(fullFailure.body, "The provider stopped before returning an answer.")
        XCTAssertEqual(paginatedFailure, fullFailure)
    }

    func testTurnFailureProjectionBoundsStringValuedError() throws {
        let turn = try XCTUnwrap(CodexProjection.conversationTurn(from: .object([
            "id": .string("bounded-failure"),
            "status": .string("failed"),
            "error": .string("Failure: " + String(repeating: "too much detail ", count: 300)),
            "items": .array([]),
        ])))

        let failure = try XCTUnwrap(turn.items.first)
        XCTAssertEqual(failure.id, "codex-turn-error:bounded-failure")
        XCTAssertEqual(failure.kind, .error)
        XCTAssertEqual(failure.body.count, 2_001)
        XCTAssertTrue(failure.body.hasSuffix("…"))
    }

    func testNormalizesAppServerOutputLimitDisconnectInLiveAndPersistedProjection() throws {
        let diagnostic =
            "stream disconnected before completion: Incomplete response returned, reason: max_output_tokens"
        let failedTurn = JSONValue.object([
            "id": .string("output-limit-turn"),
            "status": .string("failed"),
            "error": .object(["message": .string(diagnostic)]),
            "items": .array([]),
        ])

        XCTAssertEqual(
            CodexProjection.turnFailureMessage(from: failedTurn),
            "The provider reached its output limit before completing this response."
        )

        let turn = try XCTUnwrap(CodexProjection.conversationTurn(from: failedTurn))
        let failure = try XCTUnwrap(turn.items.first)
        XCTAssertEqual(
            failure.body,
            "The provider reached its output limit before completing this response."
        )
    }

    func testLeavesUnrelatedStreamDisconnectDiagnosticUntouched() {
        let diagnostic = JSONValue.object([
            "message": .string("stream disconnected before completion: upstream reset")
        ])

        XCTAssertEqual(
            CodexProjection.turnFailureMessage(from: diagnostic),
            "stream disconnected before completion: upstream reset"
        )
    }

    func testNormalizesRevokedRefreshTokenIntoFriendlySignInRecovery() throws {
        let diagnostic =
            "Your access token could not be refreshed because your refresh token was revoked. Please log out and sign in again."
        let failedTurn = JSONValue.object([
            "id": .string("revoked-refresh-token"),
            "status": .string("failed"),
            "error": .object(["message": .string(diagnostic)]),
            "items": .array([]),
        ])

        XCTAssertTrue(CodexProjection.isAuthenticationRecoveryDiagnostic(diagnostic))
        XCTAssertEqual(
            CodexProjection.turnFailureMessage(from: failedTurn),
            "Your ChatGPT sign-in is no longer valid. Sign in again to continue. Your task and draft are still here."
        )

        let turn = try XCTUnwrap(CodexProjection.conversationTurn(from: failedTurn))
        XCTAssertEqual(turn.items.first?.title, "Response failed")
        XCTAssertEqual(
            turn.items.first?.body,
            "Your ChatGPT sign-in is no longer valid. Sign in again to continue. Your task and draft are still here."
        )
    }

    func testAuthenticationRecoveryClassifierDoesNotMisclassifyOrdinaryTokenFailures() {
        XCTAssertFalse(
            CodexProjection.isAuthenticationRecoveryDiagnostic(
                "The request exceeded the model's maximum output token limit."
            )
        )
        XCTAssertTrue(
            CodexProjection.isAuthenticationRecoveryDiagnostic(
                "Your access token could not be refreshed. Please log out and sign in again."
            )
        )
        XCTAssertTrue(
            CodexProjection.isAuthenticationRecoveryDiagnostic(
                "Your session changed since you logged out or signed in to another account. Please sign in again."
            )
        )
        XCTAssertFalse(
            CodexProjection.isAuthenticationRecoveryDiagnostic(
                "Your access token could not be refreshed because the server is temporarily unavailable."
            )
        )
        XCTAssertFalse(
            CodexProjection.isAuthenticationRecoveryDiagnostic(
                "The refresh token was revoked while refreshing an unrelated integration."
            )
        )
    }

    func testFailedTurnWithoutServerErrorStillProjectsOneStableFailure() throws {
        let turn = try XCTUnwrap(CodexProjection.conversationTurn(from: .object([
            "id": .string("missing-error"),
            "status": .string("failed"),
            "items": .array([]),
        ])))

        let failure = try XCTUnwrap(turn.items.first)
        XCTAssertEqual(failure.id, "codex-turn-error:missing-error")
        XCTAssertEqual(failure.kind, .error)
        XCTAssertEqual(failure.status, .failed)
        XCTAssertEqual(
            failure.body,
            "The provider stopped before completing this response."
        )
        XCTAssertEqual(failure.timestamp, .distantPast)
    }

    func testFailedTurnDoesNotDuplicateAnExistingErrorItem() throws {
        let turn = try XCTUnwrap(CodexProjection.conversationTurn(from: .object([
            "id": .string("existing-error"),
            "status": .string("failed"),
            "error": .object([
                "message": .string("Duplicate metadata"),
            ]),
            "items": .array([
                .object([
                    "id": .string("server-error"),
                    "type": .string("error"),
                    "message": .string("Useful server failure"),
                ]),
            ]),
        ])))

        XCTAssertEqual(turn.items.count, 1)
        XCTAssertEqual(turn.items.first?.id, "server-error")
        XCTAssertEqual(turn.items.first?.body, "Useful server failure")
    }

    func testCollapsesDynamicToolEnvelopeIntoReadableOutput() throws {
        let nestedOutput = #"{"content":[{"type":"text","text":"Onyx quit for relaunch"}],"structuredContent":null}"#
        let item = JSONValue.object([
            "type": .string("dynamicToolCall"),
            "id": .string("tool-1"),
            "namespace": .string("node_repl"),
            "tool": .string("js"),
            "status": .string("completed"),
            "arguments": .object(["title": .string("Restart Onyx")]),
            "contentItems": .array([
                .object(["type": .string("inputText"), "text": .string(nestedOutput)]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.title, "node_repl · js")
        XCTAssertEqual(projected.body, "Onyx quit for relaunch")
        XCTAssertNil(projected.collaboration, "Ordinary dynamic tools must remain routine activity")
    }

    func testProjectsRunningOnyxDelegationAsQuietCollaborationActivity() throws {
        let item = JSONValue.object([
            "type": .string("dynamicToolCall"),
            "id": .string("delegate-call-1"),
            "tool": .string("onyx_delegate"),
            "status": .string("inProgress"),
            "arguments": .object([
                "provider": .string("qwen-home"),
                "model": .string("Qwen/Qwen3.8-27B-FP8"),
                "prompt": .string("Check the provider capability mapping."),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)
        let activity = try XCTUnwrap(projected.collaboration)
        let agent = try XCTUnwrap(activity.agents.first)

        XCTAssertEqual(projected.kind, .tool)
        XCTAssertEqual(projected.status, .running)
        XCTAssertEqual(projected.title, "Delegating to Qwen3.8-27B-FP8")
        XCTAssertEqual(projected.body, "Check the provider capability mapping.")
        XCTAssertEqual(projected.detail, "qwen-home · Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(activity.action, .spawn)
        XCTAssertEqual(agent.id, "delegate-call-1")
        XCTAssertEqual(agent.path, "Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(agent.displayName, "Qwen3.8 27B Fp8")
        XCTAssertEqual(agent.status, .working)
        XCTAssertEqual(agent.message, "Check the provider capability mapping.")
        XCTAssertNil(agent.destination, "The child is not navigable before the provider returns its durable id")
    }

    func testProjectsCompletedOnyxDelegationWithProviderScopedChildDestination() throws {
        let result = #"{"type":"onyx_delegation_result","version":1,"success":true,"job_id":"delegate-call-2","provider_connection_id":"qwen-home","model":"Qwen/Qwen3.8-27B-FP8","child_conversation_id":"child-42","text":"A deliberately noisy delegated result that belongs in the child task.","truncated":false}"#
        let item = JSONValue.object([
            "type": .string("dynamicToolCall"),
            "id": .string("delegate-call-2"),
            "tool": .string("onyx_delegate"),
            "status": .string("completed"),
            "arguments": .string(#"{"provider":"qwen-home","model":"Qwen/Qwen3.8-27B-FP8","prompt":"Audit model capability discovery."}"#),
            "contentItems": .array([
                .object(["type": .string("inputText"), "text": .string(result)]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)
        let agent = try XCTUnwrap(projected.collaboration?.agents.first)
        let destination = try XCTUnwrap(agent.destination)

        XCTAssertEqual(projected.status, .completed)
        XCTAssertEqual(projected.title, "Qwen3.8-27B-FP8 completed")
        XCTAssertEqual(projected.body, "Audit model capability discovery.")
        XCTAssertFalse(projected.body.contains("noisy delegated result"))
        XCTAssertFalse(projected.body.contains("onyx_delegation_result"))
        XCTAssertEqual(agent.id, "delegate-call-2", "The inspector identity stays stable across call updates")
        XCTAssertEqual(agent.status, .completed)
        XCTAssertEqual(destination.connectionID, ProviderConnectionID("qwen-home"))
        XCTAssertEqual(destination.threadID, "child-42")
    }

    func testProjectsFailedOnyxDelegationFromStructuredResult() throws {
        let result = #"{"type":"onyx_delegation_result","version":1,"success":false,"job_id":"delegate-call-3","provider_connection_id":"qwen-home","model":"Qwen/Qwen3.8-27B-FP8","error_code":"provider_request_failed","error_message":"The selected provider could not complete the request."}"#
        let item = JSONValue.object([
            "type": .string("dynamicToolCall"),
            "id": .string("delegate-call-3"),
            "tool": .string("onyx_delegate"),
            "status": .string("completed"),
            "arguments": .object([
                "provider": .string("qwen-home"),
                "model": .string("Qwen/Qwen3.8-27B-FP8"),
                "prompt": .string("Review the change."),
            ]),
            "contentItems": .array([
                .object(["type": .string("inputText"), "text": .string(result)]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)
        let agent = try XCTUnwrap(projected.collaboration?.agents.first)

        XCTAssertEqual(projected.status, .failed)
        XCTAssertEqual(projected.title, "Delegation failed")
        XCTAssertEqual(projected.body, "The selected provider could not complete the request.")
        XCTAssertEqual(agent.status, .failed)
        XCTAssertEqual(agent.message, "The selected provider could not complete the request.")
        XCTAssertNil(agent.destination)
        XCTAssertFalse(projected.body.contains("provider_connection_id"))
    }

    func testProjectsSanitizedPlainTextDelegationFailureWithoutDebugEnvelope() throws {
        let projected = CodexProjection.timelineItem(
            from: .object([
                "type": .string("dynamicToolCall"),
                "id": .string("delegate-call-plain-failure"),
                "tool": .string("onyx_delegate"),
                "status": .string("completed"),
                "success": .bool(false),
                "arguments": .object([
                    "provider": .string("qwen-home"),
                    "model": .string("Qwen/Qwen3.8-27B-FP8"),
                    "prompt": .string("Review the change."),
                ]),
                "contentItems": .array([
                    .object([
                        "type": .string("inputText"),
                        "text": .string("Onyx could not complete this delegation."),
                    ]),
                ]),
            ])
        )

        XCTAssertEqual(projected.status, .failed)
        XCTAssertEqual(projected.body, "Onyx could not complete this delegation.")
        XCTAssertEqual(projected.collaboration?.agents.first?.status, .failed)
        XCTAssertFalse(projected.body.contains("contentItems"))
    }

    func testProjectsUserImageAndLocalImageWithoutLeakingMediaIntoBody() {
        let dataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=="
        let item = JSONValue.object([
            "type": .string("userMessage"),
            "id": .string("user-images"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("Compare these")]),
                .object(["type": .string("image"), "url": .string(dataURL)]),
                .object(["type": .string("localImage"), "path": .string("/tmp/reference.png")]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.body, "Compare these")
        XCTAssertEqual(projected.attachments.count, 2)
        XCTAssertEqual(projected.attachments[0].source, .dataURL(dataURL))
        XCTAssertEqual(projected.attachments[1].source, .localFilePath("/tmp/reference.png"))
        XCTAssertFalse(projected.body.contains("iVBOR"))
    }

    func testImageOnlyUserProjectionKeepsBodyEmptyButPreservesLiteralText() {
        let dataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=="

        func project(text: String?) -> TimelineItem {
            var parts: [JSONValue] = []
            if let text {
                parts.append(.object([
                    "type": .string("text"),
                    "text": .string(text),
                ]))
            }
            parts.append(.object([
                "type": .string("image"),
                "url": .string(dataURL),
            ]))
            return CodexProjection.timelineItem(from: .object([
                "type": .string("userMessage"),
                "id": .string("image-only-body"),
                "content": .array(parts),
            ]))
        }

        let imageOnly = project(text: nil)
        XCTAssertEqual(imageOnly.body, "")
        XCTAssertEqual(imageOnly.attachments.count, 1)

        let literal = project(text: "[Image attachment]")
        XCTAssertEqual(literal.body, "[Image attachment]")
        XCTAssertEqual(literal.attachments.count, 1)
    }

    func testChangedStreamingAttachmentSourceReceivesANewCacheRevision() throws {
        func project(_ payload: String) -> TimelineAttachment {
            let item = JSONValue.object([
                "type": .string("userMessage"),
                "id": .string("same-provider-item"),
                "content": .array([
                    .object(["type": .string("image"), "url": .string(payload)]),
                ]),
            ])
            return CodexProjection.timelineItem(from: item).attachments[0]
        }

        let first = project("data:image/png;base64,AAAA")
        let replacement = project("data:image/png;base64,BBBB")

        XCTAssertEqual(first.id, replacement.id, "The provider reused its item and attachment identity")
        XCTAssertNotEqual(first.source, replacement.source)
        XCTAssertNotEqual(first.cacheIdentity, replacement.cacheIdentity)
    }

    func testProjectsDynamicAndMCPImageContentAcrossSupportedSources() {
        let dynamic = CodexProjection.timelineItem(
            from: .object([
                "type": .string("dynamicToolCall"),
                "id": .string("dynamic-image"),
                "tool": .string("render"),
                "contentItems": .array([
                    .object([
                        "type": .string("inputImage"),
                        "imageUrl": .string("https://example.test/render.png"),
                    ]),
                ]),
            ])
        )
        let mcp = CodexProjection.timelineItem(
            from: .object([
                "type": .string("mcpToolCall"),
                "id": .string("mcp-image"),
                "server": .string("canvas"),
                "tool": .string("draw"),
                "result": .object([
                    "content": .array([
                        .object([
                            "type": .string("image"),
                            "data": .string("iVBORw0KGgo="),
                            "mimeType": .string("image/png"),
                        ]),
                    ]),
                ]),
            ])
        )

        XCTAssertEqual(dynamic.body, "Returned an image.")
        XCTAssertEqual(dynamic.attachments.first?.source, .remoteURL(URL(string: "https://example.test/render.png")!))
        XCTAssertFalse(dynamic.body.contains("example.test"))
        XCTAssertEqual(mcp.body, "Returned an image.")
        XCTAssertEqual(mcp.attachments.first?.source, .dataURL("data:image/png;base64,iVBORw0KGgo="))
        XCTAssertFalse(mcp.body.contains("iVBOR"))
    }

    func testProjectsNestedMCPImageEnvelopeWithoutLeakingRawPayload() throws {
        let nested = #"{"content":[{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}]}"#
        let item = JSONValue.object([
            "type": .string("dynamicToolCall"),
            "id": .string("nested-image"),
            "tool": .string("image"),
            "contentItems": .array([
                .object(["type": .string("inputText"), "text": .string(nested)]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.body, "Returned an image.")
        XCTAssertEqual(projected.attachments.count, 1)
        XCTAssertFalse(projected.body.contains("iVBOR"))
        XCTAssertFalse(projected.body.contains("data"))
    }

    func testProjectsMCPResourceLinksAsSafeProviderNeutralResults() {
        let item = JSONValue.object([
            "type": .string("mcpToolCall"),
            "id": .string("mcp-links"),
            "server": .string("docs"),
            "tool": .string("search"),
            "result": .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("I found the relevant references."),
                    ]),
                    .object([
                        "type": .string("resource_link"),
                        "uri": .string("https://docs.example.test/guide"),
                        "name": .string("Implementation\n guide"),
                        "description": .string("Step-by-step\t instructions"),
                    ]),
                    .object([
                        "type": .string("resource_link"),
                        "uri": .string("file:///tmp/onyx-private.txt"),
                        "name": .string("Private file"),
                    ]),
                ]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.body, "I found the relevant references.")
        XCTAssertEqual(projected.links.count, 1)
        XCTAssertEqual(projected.links.first?.title, "Implementation guide")
        XCTAssertEqual(projected.links.first?.detail, "Step-by-step instructions")
        XCTAssertEqual(
            projected.links.first?.url,
            URL(string: "https://docs.example.test/guide")
        )
        XCTAssertFalse(projected.body.contains("docs.example.test"))
        XCTAssertFalse(projected.body.contains("Private file"))
    }

    func testProjectsTrustedMCPAppResourceMetadataAsALink() {
        let item = JSONValue.object([
            "type": .string("mcpToolCall"),
            "id": .string("mcp-app-resource"),
            "server": .string("drive"),
            "tool": .string("open"),
            "appContext": .object([
                "appName": .string("Google Drive"),
                "actionName": .string("Open document"),
                "resourceUri": .string("https://drive.example.test/document/42"),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.links.count, 1)
        XCTAssertEqual(projected.links.first?.title, "Google Drive")
        XCTAssertEqual(
            projected.links.first?.url,
            URL(string: "https://drive.example.test/document/42")
        )
    }

    func testProjectsNestedResourceLinkWithoutLeakingRawJSON() {
        let nested = #"{"content":[{"type":"resource_link","uri":"https://example.test/result","title":"Result"}]}"#
        let item = JSONValue.object([
            "type": .string("dynamicToolCall"),
            "id": .string("dynamic-link"),
            "tool": .string("lookup"),
            "contentItems": .array([
                .object(["type": .string("inputText"), "text": .string(nested)]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.body, "Returned a link.")
        XCTAssertEqual(projected.links.map(\.title), ["Result"])
        XCTAssertFalse(projected.body.contains("resource_link"))
        XCTAssertFalse(projected.body.contains("example.test"))
    }

    func testProjectsWebSearchOpenPageAsAResourceLinkAndRejectsUnsafeURLs() {
        let item = JSONValue.object([
            "type": .string("webSearch"),
            "id": .string("web-search-link"),
            "query": .string("Onyx docs"),
            "action": .object([
                "type": .string("openPage"),
                "url": .string("https://docs.example.test/onyx"),
            ]),
        ])
        let unsafe = JSONValue.object([
            "type": .string("webSearch"),
            "id": .string("web-search-unsafe"),
            "action": .object([
                "type": .string("openPage"),
                "url": .string("javascript:alert(1)"),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)
        let unsafeProjection = CodexProjection.timelineItem(from: unsafe)

        XCTAssertEqual(projected.links.count, 1)
        XCTAssertEqual(projected.links.first?.title, "Onyx docs")
        XCTAssertEqual(unsafeProjection.links, [])
    }

    func testResourceLinksAreDeduplicatedAndBoundedAfterValidation() {
        var content: [JSONValue] = [
            .object([
                "type": .string("resource_link"),
                "uri": .string("file:///tmp/not-opened"),
                "name": .string("Unsafe local file"),
            ]),
        ]
        content.append(contentsOf: (0..<8).map { index in
            .object([
                "type": .string("resource_link"),
                "uri": .string("https://example.test/result/" + String(index)),
                "name": .string("Result " + String(index)),
            ])
        })
        content.append(content[1])
        let item = JSONValue.object([
            "type": .string("mcpToolCall"),
            "id": .string("bounded-links"),
            "result": .object(["content": .array(content)]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.links.count, 6)
        XCTAssertEqual(
            projected.links.map { $0.url },
            (0..<6).map { URL(string: "https://example.test/result/" + String($0))! }
        )
        XCTAssertEqual(Set(projected.links.map { $0.id }).count, 6)
    }

    func testProjectsImageViewAndImageGenerationSuccessAndFailure() {
        let imageView = CodexProjection.timelineItem(
            from: .object([
                "type": .string("imageView"),
                "id": .string("view-image"),
                "path": .string("/tmp/screenshot.png"),
            ])
        )
        let generation = CodexProjection.timelineItem(
            from: .object([
                "type": .string("imageGeneration"),
                "id": .string("generated-image"),
                "status": .string("completed"),
                "result": .string("data:image/png;base64,AAAA"),
                "savedPath": .string("/tmp/generated.png"),
            ])
        )
        let failure = CodexProjection.timelineItem(
            from: .object([
                "type": .string("imageGeneration"),
                "id": .string("failed-image"),
                "status": .string("failed"),
                "result": .string("data:image/png;base64,SECRET"),
                "failure": .object([
                    "type": .string("usageLimitExceeded"),
                    "limitId": .string("imageGeneration"),
                ]),
            ])
        )

        XCTAssertEqual(imageView.attachments.first?.source, .localFilePath("/tmp/screenshot.png"))
        XCTAssertEqual(imageView.body, "Opened an image preview.")
        XCTAssertEqual(generation.attachments.first?.source, .localFilePath("/tmp/generated.png"))
        XCTAssertEqual(generation.body, "Generated an image.")
        XCTAssertEqual(failure.status, .failed)
        XCTAssertTrue(failure.body.contains("usage limit"))
        XCTAssertTrue(failure.attachments.isEmpty)
        XCTAssertFalse(failure.body.contains("SECRET"))
    }

    func testProjectsContextCompactionAsReadableActivity() {
        let item = JSONValue.object([
            "type": .string("contextCompaction"),
            "id": .string("compaction-1"),
        ])

        let projected = CodexProjection.timelineItem(from: item, defaultStatus: .running)

        XCTAssertEqual(projected.kind, .system)
        XCTAssertEqual(projected.title, "Conversation compacted")
        XCTAssertTrue(projected.body.contains("Earlier messages were condensed"))
        XCTAssertFalse(projected.body.contains("contextCompaction"))
        XCTAssertEqual(projected.status, .running)
    }

    func testProjectsReviewModeItemsAsReadableActivity() {
        let entered = CodexProjection.timelineItem(
            from: .object([
                "type": .string("enteredReviewMode"),
                "id": .string("review-entered"),
                "review": .string("Review the uncommitted changes"),
            ])
        )
        let exited = CodexProjection.timelineItem(
            from: .object([
                "type": .string("exitedReviewMode"),
                "id": .string("review-exited"),
                "review": .string("Found one correctness issue"),
            ])
        )

        XCTAssertEqual(entered.kind, .system)
        XCTAssertEqual(entered.title, "Code review started")
        XCTAssertEqual(entered.body, "Review the uncommitted changes")
        XCTAssertEqual(exited.kind, .system)
        XCTAssertEqual(exited.title, "Code review completed")
        XCTAssertEqual(exited.body, "Found one correctness issue")
    }

    func testProjectsActiveWaitingFlagsAsDistinctAttentionStates() {
        let fixtures: [(String, RuntimeThreadStatus, RuntimeTaskAttention)] = [
            ("waitingOnApproval", .waitingForApproval, .needsApproval),
            ("waitingOnUserInput", .waitingForInput, .needsInput),
        ]
        for (flag, expectedStatus, expectedAttention) in fixtures {
            let thread = CodexProjection.thread(
                from: .object([
                    "id": .string("thread-\(flag)"),
                    "status": .object([
                        "type": .string("active"),
                        "activeFlags": .array([.string(flag)]),
                    ]),
                ])
            )

            XCTAssertEqual(thread?.status, expectedStatus, "Failed to project \(flag)")
            XCTAssertEqual(thread?.status.attention, expectedAttention)
        }
    }

    func testProjectsCollaborationToolCallAsReadableProviderNeutralCard() {
        let item = JSONValue.object([
            "type": .string("collabAgentToolCall"),
            "id": .string("collab-1"),
            "tool": .string("wait"),
            "senderThreadId": .string("thread-parent"),
            "receiverThreadIds": .strings(["thread-child-a", "thread-child-b"]),
            "status": .string("completed"),
            "agentsStates": .object([
                "thread-child-a": .object([
                    "status": .string("running"),
                    "message": .string("Checking image attachment behavior"),
                ]),
                "thread-child-b": .object([
                    "status": .string("completed"),
                    "message": .string("Reconnect tests passed"),
                ]),
            ]),
        ])

        let projected = CodexProjection.timelineItem(from: item)

        XCTAssertEqual(projected.kind, .tool)
        XCTAssertEqual(projected.title, "Checked agent progress")
        XCTAssertTrue(projected.body.contains("1 working · 1 completed"))
        XCTAssertTrue(projected.body.contains("Checking image attachment behavior"))
        XCTAssertFalse(projected.body.contains("agentsStates"))
        XCTAssertFalse(projected.body.contains("thread-parent"))
        XCTAssertEqual(projected.collaboration?.agents.count, 2)
        XCTAssertEqual(
            Set(projected.collaboration?.agents.map(\.id) ?? []),
            Set(["thread-child-a", "thread-child-b"])
        )
        XCTAssertEqual(
            Set(projected.collaboration?.agents.map(\.status) ?? []),
            Set([.working, .completed])
        )
        XCTAssertEqual(
            Set(projected.collaboration?.agents.compactMap(\.destination?.connectionID) ?? []),
            Set([.codexDefault])
        )
        XCTAssertEqual(
            Set(projected.collaboration?.agents.compactMap(\.destination?.threadID) ?? []),
            Set(["thread-child-a", "thread-child-b"])
        )
    }

    func testProjectsSubAgentActivityAsReadableProviderNeutralCard() {
        let projected = CodexProjection.timelineItem(
            from: .object([
                "type": .string("subAgentActivity"),
                "id": .string("activity-1"),
                "agentThreadId": .string("thread-child"),
                "agentPath": .string("/root/image_attachments"),
                "kind": .string("started"),
            ])
        )

        XCTAssertEqual(projected.kind, .tool)
        XCTAssertEqual(projected.title, "Agent started")
        XCTAssertEqual(projected.body, "Image Attachments")
        XCTAssertEqual(projected.detail, "Collaboration")
        XCTAssertEqual(projected.collaboration?.agents.first?.id, "thread-child")
        XCTAssertEqual(projected.collaboration?.agents.first?.status, .working)
        XCTAssertEqual(projected.collaboration?.agents.first?.destination?.connectionID, .codexDefault)
        XCTAssertEqual(projected.collaboration?.agents.first?.destination?.threadID, "thread-child")
        XCTAssertFalse(projected.body.contains("agentThreadId"))
    }

    func testProjectsAuthoritativePlanSnapshotAsChecklist() throws {
        let plan = try XCTUnwrap(CodexProjection.plan(
            from: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-7"),
                "explanation": .string("Finishing the native collaboration surface."),
                "plan": .array([
                    .object(["step": .string("Inspect protocol"), "status": .string("completed")]),
                    .object(["step": .string("Implement projection"), "status": .string("inProgress")]),
                    .object(["step": .string("Run tests"), "status": .string("pending")]),
                ]),
            ])
        ))

        let projected = TimelineItem.planUpdate(plan)
        XCTAssertEqual(plan.turnID, "turn-7")
        XCTAssertEqual(plan.steps.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertEqual(projected.body, "[x] Inspect protocol\n[~] Implement projection\n[ ] Run tests")
        XCTAssertEqual(projected.status, .running)
    }

    func testPreservesUnknownPlanStepStatusWithoutDroppingSnapshot() throws {
        let plan = try XCTUnwrap(CodexProjection.plan(
            from: .object([
                "turnId": .string("turn-future"),
                "plan": .array([
                    .object(["step": .string("Known"), "status": .string("completed")]),
                    .object(["step": .string("Future"), "status": .string("blocked")]),
                ]),
            ])
        ))

        XCTAssertEqual(plan.steps.map(\.status), [.completed, .unknown("blocked")])
        XCTAssertEqual(plan.checklistText, "[x] Known\n[?] Future")
    }

    func testProjectsPartialThreadLifecycleNotifications() {
        let status = JSONValue.object([
            "type": .string("active"),
            "activeFlags": .array([]),
        ])
        let fixtures: [(String, JSONValue, AgentRuntimeEvent)] = [
            (
                "thread/name/updated",
                .object(["threadId": .string("thread-1"), "threadName": .string("Fast native app")]),
                .threadNameChanged(threadID: "thread-1", name: "Fast native app")
            ),
            (
                "thread/name/updated",
                .object(["threadId": .string("thread-1"), "threadName": .null]),
                .threadNameChanged(threadID: "thread-1", name: nil)
            ),
            (
                "thread/status/changed",
                .object(["threadId": .string("thread-1"), "status": status]),
                .threadStatusChanged(threadID: "thread-1", status: .running)
            ),
            (
                "thread/archived",
                .object(["threadId": .string("thread-1")]),
                .threadArchived(threadID: "thread-1")
            ),
            (
                "thread/unarchived",
                .object(["threadId": .string("thread-1")]),
                .threadUnarchived(threadID: "thread-1")
            ),
            (
                "thread/deleted",
                .object(["threadId": .string("thread-1")]),
                .threadDeleted(threadID: "thread-1")
            ),
            (
                "thread/reverted",
                .object(["threadId": .string("thread-1")]),
                .threadRefreshRequested(threadID: "thread-1")
            ),
        ]

        for (method, params, expected) in fixtures {
            let notification = AppServerNotification(method: method, params: params)
            XCTAssertEqual(CodexProjection.threadLifecycleEvent(from: notification), expected)
        }
    }
}
