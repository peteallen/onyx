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
        XCTAssertEqual(conversation.items.map(\.kind), [.userMessage, .assistantMessage, .command])
        XCTAssertEqual(conversation.items[0].body, "Make it fast")
        XCTAssertEqual(conversation.items[2].title, "swift test")
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
            Set(projected.collaboration?.agents.map(\.status) ?? []),
            Set([.working, .completed])
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
        XCTAssertEqual(projected.collaboration?.agents.first?.status, .working)
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
