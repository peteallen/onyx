import XCTest
@testable import Onyx

final class CodexRuntimeTests: XCTestCase {
    func testThreadManagementUsesStableMethodsWithoutCallingLiveServer() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)

        let resumed = try await runtime.resumeThread(id: "resume-thread")
        let fork = try await runtime.forkThread(id: "source-thread")
        try await runtime.compactThread(id: "compact-thread")
        try await runtime.deleteThread(id: "delete-thread")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(fork.id, "forked-thread")
        XCTAssertEqual(resumed.thread.id, "resume-thread")
        XCTAssertEqual(requests.map(\.method), [
            "thread/resume",
            "thread/fork",
            "thread/compact/start",
            "thread/delete",
        ])
        XCTAssertEqual(requests.map { $0.params["threadId"]?.stringValue }, [
            "resume-thread",
            "source-thread",
            "compact-thread",
            "delete-thread",
        ])
    }

    func testExecutionControlsMapToStableThreadAndTurnFields() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)

        _ = try await runtime.startThread(
            StartThreadRequest(
                cwd: "/tmp/onyx",
                model: "gpt-test",
                sandboxMode: .fullAccess,
                approvalPolicy: .never
            )
        )
        try await runtime.startTurn(
            StartTurnRequest(
                threadID: "started-thread",
                inputs: [
                    .text("Continue"),
                    .localImagePath("/tmp/reference.png"),
                    .imageURL("data:image/png;base64,aW1hZ2U="),
                ],
                model: "gpt-test",
                cwd: "/tmp/onyx",
                reasoningEffort: "high",
                sandboxMode: .workspaceWrite,
                approvalPolicy: .onRequest
            )
        )
        try await runtime.steer(
            threadID: "started-thread",
            inputs: [
                .localImagePath("/tmp/follow-up.jpg"),
                .text("Look here"),
            ]
        )

        let requests = await transport.recordedRequests()
        let threadStart = try XCTUnwrap(requests.first(where: { $0.method == "thread/start" }))
        let turnStart = try XCTUnwrap(requests.first(where: { $0.method == "turn/start" }))
        let steer = try XCTUnwrap(requests.first(where: { $0.method == "turn/steer" }))

        XCTAssertEqual(threadStart.params["sandbox"]?.stringValue, "danger-full-access")
        XCTAssertEqual(threadStart.params["approvalPolicy"]?.stringValue, "never")
        XCTAssertNil(threadStart.params["modelProvider"])
        XCTAssertEqual(turnStart.params["effort"]?.stringValue, "high")
        XCTAssertEqual(turnStart.params["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(turnStart.params["sandboxPolicy"]?["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(
            turnStart.params["sandboxPolicy"]?["writableRoots"]?.arrayValue?.compactMap(\.stringValue),
            ["/tmp/onyx"]
        )
        XCTAssertEqual(
            turnStart.params["input"],
            .array([
                .object(["type": .string("text"), "text": .string("Continue")]),
                .object(["type": .string("localImage"), "path": .string("/tmp/reference.png")]),
                .object(["type": .string("image"), "url": .string("data:image/png;base64,aW1hZ2U=")]),
            ])
        )
        XCTAssertEqual(steer.params["threadId"]?.stringValue, "started-thread")
        XCTAssertEqual(steer.params["expectedTurnId"]?.stringValue, "started-turn")
        XCTAssertEqual(
            steer.params["input"],
            .array([
                .object(["type": .string("localImage"), "path": .string("/tmp/follow-up.jpg")]),
                .object(["type": .string("text"), "text": .string("Look here")]),
            ])
        )
    }

    func testBoundProviderScopesDiscoveryAndValidatesExplicitTaskOperations() async throws {
        let providerID = "onyx-custom-provider"
        let transport = ProviderBoundCodexTransport(returnedProviderID: providerID)
        let runtime = CodexRuntime(
            client: transport,
            modelProviderID: providerID
        )

        let listed = try await runtime.listThreads()
        _ = try await runtime.startThread(
            StartThreadRequest(cwd: "/tmp/onyx", model: "custom-model")
        )
        _ = try await runtime.readThread(id: "custom-thread")
        _ = try await runtime.resumeThread(id: "custom-thread")
        _ = try await runtime.forkThread(id: "custom-thread")
        _ = try await runtime.revertThread(id: "custom-thread", beforeTurnID: "turn-1")
        try await runtime.startTurn(
            StartTurnRequest(
                threadID: "started-thread",
                inputs: [.text("Continue")],
                model: "custom-model"
            )
        )

        let requests = await transport.recordedRequests()
        let threadList = try XCTUnwrap(requests.first(where: { $0.method == "thread/list" }))
        let threadStart = try XCTUnwrap(requests.first(where: { $0.method == "thread/start" }))
        let turnStart = try XCTUnwrap(requests.first(where: { $0.method == "turn/start" }))
        XCTAssertEqual(listed.map(\.id), ["custom-thread"])
        XCTAssertEqual(
            threadList.params["modelProviders"]?.arrayValue?.compactMap(\.stringValue),
            [providerID]
        )
        XCTAssertEqual(threadStart.params["modelProvider"]?.stringValue, providerID)
        XCTAssertNil(turnStart.params["modelProvider"])
    }

    func testBoundProviderRejectsThreadReturnedForAnotherProvider() async throws {
        let runtime = CodexRuntime(
            client: ProviderBoundCodexTransport(returnedProviderID: "another-provider"),
            modelProviderID: "expected-provider"
        )

        do {
            _ = try await runtime.startThread(
                StartThreadRequest(cwd: "/tmp/onyx", model: "custom-model")
            )
            XCTFail("A custom runtime must reject a task owned by another provider")
        } catch let AgentRuntimeError.protocolFailure(message) {
            XCTAssertTrue(message.contains("did not confirm the custom-provider task"))
        }
    }

    func testInlineUncommittedReviewUsesStablePayloadAndCanBeInterrupted() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)

        let review = try await runtime.startReview(
            StartReviewRequest(threadID: "review-thread")
        )
        try await runtime.interrupt(threadID: review.threadID)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(review, RuntimeReviewRun(threadID: "review-thread", turnID: "review-turn"))
        XCTAssertEqual(requests.map(\.method), ["thread/resume", "review/start", "turn/interrupt"])
        let resume = try XCTUnwrap(requests.first)
        XCTAssertEqual(resume.params["threadId"]?.stringValue, "review-thread")
        let start = try XCTUnwrap(requests.first(where: { $0.method == "review/start" }))
        XCTAssertEqual(start.params["threadId"]?.stringValue, "review-thread")
        XCTAssertEqual(start.params["delivery"]?.stringValue, "inline")
        XCTAssertEqual(start.params["target"]?["type"]?.stringValue, "uncommittedChanges")
        let interrupt = try XCTUnwrap(requests.last)
        XCTAssertEqual(interrupt.params["threadId"]?.stringValue, "review-thread")
        XCTAssertEqual(interrupt.params["turnId"]?.stringValue, "review-turn")
    }

    func testModelCatalogProjectsStructuredReasoningOptions() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)

        let session = try await runtime.connect()
        await runtime.disconnect()

        XCTAssertEqual(session.availableModels.first?.defaultReasoningEffort, "low")
        XCTAssertEqual(session.availableModels.first?.reasoningEfforts, ["low", "high"])
        XCTAssertTrue(session.capabilities.contains(.threadHistoryPagination))
        XCTAssertTrue(session.capabilities.contains(.threadHistoryRevert))
    }

    func testCompletedTurnPublishesFailureRowBeforeCompletionWithoutDuplicateNotice() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)
        let recordedEvents = Task {
            try await collectEventsThroughTurnCompletion(
                from: runtime.events,
                threadID: "failed-thread"
            )
        }

        _ = try await runtime.connect()
        await transport.emitNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string("failed-thread"),
                "turn": .object(["id": .string("failed-turn")]),
            ])
        )
        await transport.emitNotification(
            method: "error",
            params: .object([
                "threadId": .string("failed-thread"),
                "turnId": .string("failed-turn"),
                "willRetry": .bool(false),
                "error": .object([
                    "message": .string("The provider stopped before returning an answer."),
                ]),
            ])
        )
        await transport.emitNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("failed-thread"),
                "turn": .object([
                    "id": .string("failed-turn"),
                    "status": .string("failed"),
                    "error": .object([
                        "message": .string("The provider stopped before returning an answer."),
                    ]),
                ]),
            ])
        )

        let events = try await recordedEvents.value
        let failures = events.compactMap { event -> TimelineItem? in
            guard case let .itemCompleted(threadID, item) = event,
                  threadID == "failed-thread",
                  item.kind == .error else { return nil }
            return item
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.id, "codex-turn-error:failed-turn")
        XCTAssertEqual(failures.first?.body, "The provider stopped before returning an answer.")
        XCTAssertFalse(events.contains { event in
            if case .runtimeNotice = event { return true }
            return false
        })
        let failureIndex = try XCTUnwrap(events.firstIndex { event in
            guard case let .itemCompleted(threadID, item) = event else { return false }
            return threadID == "failed-thread" && item.kind == .error
        })
        let completionIndex = try XCTUnwrap(events.firstIndex { event in
            guard case let .turnCompleted(threadID, status) = event else { return false }
            return threadID == "failed-thread" && status == .failed
        })
        XCTAssertLessThan(failureIndex, completionIndex)
        await runtime.disconnect()
    }

    func testBoundedResumeMapsInitialTurnsPageAndPresentsTranscriptChronologically() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)

        let resumed = try await runtime.resumeThread(
            id: "history-thread",
            initialHistoryPage: RuntimeInitialThreadHistoryPageRequest(
                limit: 20,
                direction: .descending,
                itemDetail: .full
            )
        )
        try await runtime.steer(threadID: "history-thread", text: "Keep going")

        let requests = await transport.recordedRequests()
        let resume = try XCTUnwrap(requests.first(where: { $0.method == "thread/resume" }))
        XCTAssertEqual(resume.params["threadId"]?.stringValue, "history-thread")
        XCTAssertEqual(resume.params["excludeTurns"]?.boolValue, true)
        XCTAssertEqual(resume.params["initialTurnsPage"]?["limit"]?.intValue, 20)
        XCTAssertEqual(resume.params["initialTurnsPage"]?["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(resume.params["initialTurnsPage"]?["itemsView"]?.stringValue, "full")

        let page = try XCTUnwrap(resumed.initialHistoryPage)
        XCTAssertEqual(page.turns.map(\.id), ["turn-new", "turn-old"])
        XCTAssertEqual(page.turns.map(\.status), [.inProgress, .completed])
        XCTAssertEqual(page.turns.map(\.itemDetail), [.full, .full])
        XCTAssertEqual(page.nextCursor, "older-turns")
        XCTAssertEqual(page.backwardsCursor, "newer-turns")
        XCTAssertEqual(page.chronologicalItems.map(\.id), ["user-old", "assistant-new"])
        XCTAssertEqual(resumed.conversation.items.map(\.id), ["user-old", "assistant-new"])
        XCTAssertEqual(
            resumed.conversation.items.map(\.timestamp),
            [
                Date(timeIntervalSince1970: 200),
                Date(timeIntervalSince1970: 300),
            ],
            "Persisted items without their own timestamps should inherit the turn start"
        )
        XCTAssertEqual(
            resumed.conversation.thread.updatedAt,
            Date(timeIntervalSince1970: 100),
            "Opening paginated history must not make the task appear newly active"
        )
        XCTAssertEqual(resumed.turnsBackwardsCursor, "resume-turn-head")
        XCTAssertEqual(resumed.itemsBackwardsCursor, "resume-item-head")

        let steer = try XCTUnwrap(requests.first(where: { $0.method == "turn/steer" }))
        XCTAssertEqual(steer.params["expectedTurnId"]?.stringValue, "turn-new")
    }

    func testBoundedReadUsesReadOnlyMetadataAndTurnPageWithoutResuming() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)

        let read = try await runtime.readThread(
            id: "history-thread",
            initialHistoryPage: RuntimeThreadHistoryPageRequest(
                limit: 12,
                direction: .descending,
                itemDetail: .full
            )
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["thread/read", "thread/turns/list"])
        let metadataRead = try XCTUnwrap(requests.first)
        XCTAssertEqual(metadataRead.params["threadId"]?.stringValue, "history-thread")
        XCTAssertEqual(metadataRead.params["includeTurns"]?.boolValue, false)
        XCTAssertFalse(requests.contains(where: { $0.method == "thread/resume" }))
        XCTAssertEqual(read.conversation.thread.id, "history-thread")
        XCTAssertEqual(read.initialHistoryPage?.turns.map(\.id), ["page-turn"])
        XCTAssertEqual(read.conversation.items.map(\.id), ["page-item"])
        XCTAssertEqual(
            read.conversation.items.first?.timestamp,
            Date(timeIntervalSince1970: 90)
        )
        XCTAssertEqual(
            read.conversation.thread.updatedAt,
            Date(timeIntervalSince1970: 100),
            "Read-only navigation must preserve the metadata recency"
        )
    }

    func testTurnHistoryPaginationAndRevertUseExactCodexFields() async throws {
        let transport = RecordingCodexTransport()
        let runtime = CodexRuntime(client: transport)

        let page = try await runtime.listThreadHistory(
            id: "history-thread",
            page: RuntimeThreadHistoryPageRequest(
                cursor: "older-turns",
                limit: 12,
                direction: .ascending,
                itemDetail: .summary
            )
        )
        let reverted = try await runtime.revertThread(
            id: "history-thread",
            beforeTurnID: "turn-new"
        )

        let requests = await transport.recordedRequests()
        let list = try XCTUnwrap(requests.first(where: { $0.method == "thread/turns/list" }))
        XCTAssertEqual(list.params["threadId"]?.stringValue, "history-thread")
        XCTAssertEqual(list.params["cursor"]?.stringValue, "older-turns")
        XCTAssertEqual(list.params["limit"]?.intValue, 12)
        XCTAssertEqual(list.params["sortDirection"]?.stringValue, "asc")
        XCTAssertEqual(list.params["itemsView"]?.stringValue, "summary")
        XCTAssertEqual(page.direction, .ascending)
        XCTAssertEqual(page.turns.map(\.id), ["page-turn"])
        XCTAssertEqual(page.nextCursor, "page-next")
        XCTAssertEqual(page.backwardsCursor, "page-backwards")

        let revert = try XCTUnwrap(requests.first(where: { $0.method == "thread/revert" }))
        XCTAssertEqual(revert.params["threadId"]?.stringValue, "history-thread")
        XCTAssertEqual(revert.params["beforeTurnId"]?.stringValue, "turn-new")
        XCTAssertEqual(reverted.thread.id, "history-thread")
        XCTAssertEqual(reverted.turnsBackwardsCursor, "retained-turn-head")
        XCTAssertEqual(reverted.itemsBackwardsCursor, "retained-item-head")
    }

    func testUnsupportedNativeRevertIsDowngradedForLaterSessionSnapshots() async throws {
        let transport = RecordingCodexTransport(revertFailureCode: -32_601)
        let runtime = CodexRuntime(client: transport)

        let initial = try await runtime.connect()
        XCTAssertTrue(initial.capabilities.contains(.threadHistoryRevert))

        do {
            _ = try await runtime.revertThread(
                id: "history-thread",
                beforeTurnID: "turn-new"
            )
            XCTFail("An older app-server should reject native history editing")
        } catch let error as AgentRuntimeError {
            guard case .unsupported = error else {
                return XCTFail("Expected an unsupported capability error, got \(error)")
            }
        }

        let refreshed = try await runtime.refreshAccount()
        XCTAssertFalse(refreshed.capabilities.contains(.threadHistoryRevert))
        XCTAssertTrue(refreshed.capabilities.contains(.threadHistoryPagination))
    }

    func testCompleteThreadCatalogFollowsEveryCursorWithoutLosingOrDuplicatingRows() async throws {
        let transport = PaginatedCodexTransport()
        let runtime = CodexRuntime(client: transport)

        let threads = try await runtime.listAllThreads(archived: false)
        let requests = await transport.recordedListRequests()

        XCTAssertEqual(Set(threads.map(\.id)), Set((0 ..< 205).map { "thread-" + String($0) }))
        XCTAssertEqual(threads.count, 205)
        XCTAssertEqual(requests.map { $0.params["limit"]?.intValue }, [100, 100, 100])
        XCTAssertEqual(requests.map { $0.params["cursor"]?.stringValue }, [nil, "page-2", "page-3"])
        XCTAssertEqual(requests.map { $0.params["archived"]?.boolValue }, [false, false, false])
        XCTAssertTrue(requests.allSatisfy { $0.params["modelProviders"] == nil })
    }
}

private actor ProviderBoundCodexTransport: CodexAppServerTransport {
    struct Request: Sendable {
        let method: String
        let params: JSONValue
    }

    nonisolated let events: AsyncStream<AppServerEvent>
    private let returnedProviderID: String
    private var requests: [Request] = []

    init(returnedProviderID: String) {
        self.returnedProviderID = returnedProviderID
        events = AsyncStream { continuation in continuation.finish() }
    }

    func start() async throws -> AppServerConnection {
        AppServerConnection(generation: 1, initializeResponse: .object([:]))
    }

    func stop() async {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        requests.append(Request(method: method, params: params))
        switch method {
        case "thread/list":
            return .object([
                "data": .array([thread(id: "custom-thread")]),
            ])
        case "thread/start":
            return .object(["thread": thread(id: "started-thread")])
        case "thread/read", "thread/resume":
            return .object([
                "thread": thread(id: params["threadId"]?.stringValue ?? "custom-thread"),
            ])
        case "thread/fork":
            return .object(["thread": thread(id: "forked-thread")])
        case "thread/revert":
            return .object([
                "thread": thread(id: params["threadId"]?.stringValue ?? "custom-thread"),
            ])
        case "turn/start":
            return .object([
                "turn": .object([
                    "id": .string("started-turn"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                ]),
            ])
        default:
            return .object([:])
        }
    }

    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}

    func recordedRequests() -> [Request] { requests }

    private func thread(id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "preview": .string("Custom provider task"),
            "modelProvider": .string(returnedProviderID),
            "turns": .array([]),
        ])
    }
}

private actor PaginatedCodexTransport: CodexAppServerTransport {
    struct Request: Sendable {
        let method: String
        let params: JSONValue
    }

    nonisolated let events: AsyncStream<AppServerEvent>
    private var requests: [Request] = []

    init() {
        events = AsyncStream { continuation in continuation.finish() }
    }

    func start() async throws -> AppServerConnection {
        AppServerConnection(generation: 1, initializeResponse: .object([:]))
    }

    func stop() async {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        requests.append(Request(method: method, params: params))
        guard method == "thread/list" else { return .object([:]) }

        let page: Range<Int>
        let nextCursor: String?
        switch params["cursor"]?.stringValue {
        case nil:
            page = 0 ..< 100
            nextCursor = "page-2"
        case "page-2":
            page = 100 ..< 200
            nextCursor = "page-3"
        default:
            page = 200 ..< 205
            nextCursor = nil
        }
        var result: [String: JSONValue] = [
            "data": .array(page.map { index in
                .object([
                    "id": .string("thread-" + String(index)),
                    "name": .string("Task " + String(index)),
                    "preview": .string("Task " + String(index)),
                    "updatedAt": .integer(index + 1),
                    "status": .object(["type": .string("idle")]),
                ])
            }),
        ]
        if let nextCursor { result["nextCursor"] = .string(nextCursor) }
        return .object(result)
    }

    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}

    func recordedListRequests() -> [Request] {
        requests.filter { $0.method == "thread/list" }
    }
}

private actor RecordingCodexTransport: CodexAppServerTransport {
    struct Request: Sendable {
        let method: String
        let params: JSONValue
    }

    nonisolated let events: AsyncStream<AppServerEvent>
    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation
    private var requests: [Request] = []
    private let revertFailureCode: Int?

    init(revertFailureCode: Int? = nil) {
        self.revertFailureCode = revertFailureCode
        let stream = AsyncStream.makeStream(of: AppServerEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func start() async throws -> AppServerConnection {
        AppServerConnection(generation: 1, initializeResponse: .object([:]))
    }

    func stop() async {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        requests.append(Request(method: method, params: params))
        if method == "thread/fork" {
            return .object([
                "thread": .object([
                    "id": .string("forked-thread"),
                    "preview": .string("Forked task"),
                ]),
            ])
        }
        if method == "thread/resume", params["initialTurnsPage"] != nil {
            return .object([
                "thread": .object([
                    "id": .string("history-thread"),
                    "preview": .string("History task"),
                    "updatedAt": .integer(100),
                    "turns": .array([]),
                ]),
                "initialTurnsPage": .object([
                    "data": .array([
                        .object([
                            "id": .string("turn-new"),
                            "itemsView": .string("full"),
                            "status": .string("inProgress"),
                            "startedAt": .integer(300),
                            "items": .array([
                                .object([
                                    "id": .string("assistant-new"),
                                    "type": .string("agentMessage"),
                                    "text": .string("Recent answer"),
                                ]),
                            ]),
                        ]),
                        .object([
                            "id": .string("turn-old"),
                            "itemsView": .string("full"),
                            "status": .string("completed"),
                            "startedAt": .integer(200),
                            "completedAt": .integer(210),
                            "durationMs": .integer(10_000),
                            "items": .array([
                                .object([
                                    "id": .string("user-old"),
                                    "type": .string("userMessage"),
                                    "text": .string("Earlier request"),
                                ]),
                            ]),
                        ]),
                    ]),
                    "nextCursor": .string("older-turns"),
                    "backwardsCursor": .string("newer-turns"),
                ]),
                "turnsBackwardsCursor": .string("resume-turn-head"),
                "itemsBackwardsCursor": .string("resume-item-head"),
            ])
        }
        if method == "thread/resume" {
            return .object([
                "thread": .object([
                    "id": .string("resume-thread"),
                    "preview": .string("Resumed task"),
                    "turns": .array([]),
                ]),
            ])
        }
        if method == "thread/read", params["includeTurns"]?.boolValue == false {
            return .object([
                "thread": .object([
                    "id": .string("history-thread"),
                    "preview": .string("History task"),
                    "updatedAt": .integer(100),
                    "turns": .array([]),
                ]),
            ])
        }
        if method == "thread/turns/list" {
            return .object([
                "data": .array([
                    .object([
                        "id": .string("page-turn"),
                        "itemsView": .string("summary"),
                        "status": .string("completed"),
                        "startedAt": .integer(90),
                        "items": .array([
                            .object([
                                "id": .string("page-item"),
                                "type": .string("agentMessage"),
                                "text": .string("Read-only page item"),
                            ]),
                        ]),
                    ]),
                ]),
                "nextCursor": .string("page-next"),
                "backwardsCursor": .string("page-backwards"),
            ])
        }
        if method == "thread/revert" {
            if let revertFailureCode {
                throw AgentRuntimeError.requestFailed(
                    code: revertFailureCode,
                    message: "simulated unsupported method"
                )
            }
            return .object([
                "thread": .object([
                    "id": .string("history-thread"),
                    "preview": .string("History task"),
                    "turns": .array([]),
                ]),
                "turnsBackwardsCursor": .string("retained-turn-head"),
                "itemsBackwardsCursor": .string("retained-item-head"),
            ])
        }
        if method == "thread/start" {
            return .object([
                "thread": .object([
                    "id": .string("started-thread"),
                    "preview": .string("Started task"),
                ]),
            ])
        }
        if method == "turn/start" {
            return .object([
                "turn": .object([
                    "id": .string("started-turn"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                ]),
            ])
        }
        if method == "review/start" {
            return .object([
                "reviewThreadId": .string("review-thread"),
                "turn": .object([
                    "id": .string("review-turn"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                ]),
            ])
        }
        if method == "account/read" {
            return .object(["account": .object(["type": .string("chatgpt")])])
        }
        if method == "model/list" {
            return .object([
                "data": .array([
                    .object([
                        "id": .string("gpt-test"),
                        "displayName": .string("GPT Test"),
                        "description": .string("Fixture model"),
                        "isDefault": .bool(true),
                        "defaultReasoningEffort": .string("low"),
                        "supportedReasoningEfforts": .array([
                            .object([
                                "reasoningEffort": .string("low"),
                                "description": .string("Fast"),
                            ]),
                            .object([
                                "reasoningEffort": .string("high"),
                                "description": .string("Deep"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        }
        return .object([:])
    }

    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}

    func emitNotification(method: String, params: JSONValue) {
        eventContinuation.yield(
            .notification(
                generation: 1,
                AppServerNotification(method: method, params: params)
            )
        )
    }

    func recordedRequests() -> [Request] {
        requests
    }
}

private enum CodexRuntimeTestFailure: Error {
    case eventStreamEnded
    case timedOutWaitingForTurnCompletion
}

private func collectEventsThroughTurnCompletion(
    from stream: AsyncStream<AgentRuntimeEvent>,
    threadID: String
) async throws -> [AgentRuntimeEvent] {
    try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
        group.addTask {
            var events: [AgentRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case let .turnCompleted(completedThreadID, _) = event,
                   completedThreadID == threadID {
                    return events
                }
            }
            throw CodexRuntimeTestFailure.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw CodexRuntimeTestFailure.timedOutWaitingForTurnCompletion
        }

        guard let events = try await group.next() else {
            throw CodexRuntimeTestFailure.eventStreamEnded
        }
        group.cancelAll()
        return events
    }
}
