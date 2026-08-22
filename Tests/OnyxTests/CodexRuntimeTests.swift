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
    }
}

private actor RecordingCodexTransport: CodexAppServerTransport {
    struct Request: Sendable {
        let method: String
        let params: JSONValue
    }

    nonisolated let events: AsyncStream<AppServerEvent>
    private var requests: [Request] = []

    init() {
        events = AsyncStream { continuation in
            continuation.finish()
        }
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
        if method == "thread/resume" {
            return .object([
                "thread": .object([
                    "id": .string("resume-thread"),
                    "preview": .string("Resumed task"),
                    "turns": .array([]),
                ]),
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

    func recordedRequests() -> [Request] {
        requests
    }
}
