import XCTest
@testable import Onyx

final class CodexDynamicToolTests: XCTestCase {
    func testThreadStartAttachesOneHandlerProvidedOnyxDelegateFunction() async throws {
        let definition = CodexDynamicToolDefinition(
            description: "Available targets: local-qwen / Qwen/Qwen3.8-27B-FP8",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "provider": .object([
                        "type": .string("string"),
                        "enum": .strings(["local-qwen"]),
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "enum": .strings(["Qwen/Qwen3.8-27B-FP8"]),
                    ]),
                    "prompt": .object(["type": .string("string")]),
                ]),
                "required": .strings(["provider", "model", "prompt"]),
            ])
        )
        let handler = RecordingDynamicToolHandler(
            definition: definition,
            behavior: .result(.succeeded("unused"))
        )
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)

        _ = try await runtime.startThread(
            StartThreadRequest(cwd: "/tmp/onyx", model: "gpt-parent")
        )

        let recordedRequests = await transport.recordedRequests()
        let request = try XCTUnwrap(
            recordedRequests.first(where: { $0.method == "thread/start" })
        )
        let tools = try XCTUnwrap(request.params["dynamicTools"]?.arrayValue)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"]?.stringValue, "function")
        XCTAssertEqual(tools[0]["name"]?.stringValue, "onyx_delegate")
        XCTAssertEqual(tools[0]["description"]?.stringValue, definition.description)
        XCTAssertEqual(tools[0]["inputSchema"], definition.inputSchema)
        let definitionRequestCount = await handler.definitionRequestCount()
        XCTAssertEqual(definitionRequestCount, 1)
    }

    func testThreadStartWithoutHandlerDoesNotAdvertiseDynamicTools() async throws {
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport)

        _ = try await runtime.startThread(StartThreadRequest(cwd: "/tmp/onyx"))

        let recordedRequests = await transport.recordedRequests()
        let request = try XCTUnwrap(
            recordedRequests.first(where: { $0.method == "thread/start" })
        )
        XCTAssertNil(request.params["dynamicTools"])
    }

    func testDelegatedChildThreadExplicitlyDisablesDynamicTools() async throws {
        let handler = RecordingDynamicToolHandler(
            behavior: .result(.succeeded("unused"))
        )
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)

        _ = try await runtime.startThread(
            StartThreadRequest(
                cwd: "/tmp/onyx",
                model: "gpt-child",
                allowsDynamicTools: false
            )
        )

        let recordedRequests = await transport.recordedRequests()
        let request = try XCTUnwrap(
            recordedRequests.first(where: { $0.method == "thread/start" })
        )
        XCTAssertNil(request.params["dynamicTools"])
        let definitionRequestCount = await handler.definitionRequestCount()
        XCTAssertEqual(definitionRequestCount, 0)
    }

    func testRecognizedToolCallForwardsSanitizedEnvelopeAndReturnsSuccessWithoutNotice() async throws {
        let handler = RecordingDynamicToolHandler(
            behavior: .result(.succeeded("{\"type\":\"onyx_delegation_result\",\"success\":true}"))
        )
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        let notices = RuntimeNoticeRecorder()
        let eventTask = recordRuntimeNotices(from: runtime.events, into: notices)
        defer { eventTask.cancel() }

        _ = try await runtime.connect()
        _ = try await runtime.startThread(
            StartThreadRequest(cwd: "/tmp/project", model: "gpt-parent")
        )
        try await runtime.startTurn(
            StartTurnRequest(threadID: "started-thread", text: "Use the delegated model.")
        )
        let arguments: JSONValue = .object([
            "provider": .string("local-qwen"),
            "model": .string("Qwen/Qwen3.8-27B-FP8"),
            "prompt": .string("Check this bounded question."),
        ])
        await transport.emit(
            AppServerRequest(
                id: .string("delegate-success"),
                method: "item/tool/call",
                params: .object([
                    "turnId": .string("started-turn"),
                    "callId": .string("call-success"),
                    "tool": .string("onyx_delegate"),
                    "arguments": arguments,
                    // These model-authored envelope fields must not cross the
                    // handler boundary as trusted provider configuration.
                    "endpoint": .string("https://should-not-forward.invalid"),
                    "apiKey": .string("should-not-forward"),
                ])
            )
        )

        let response = try await waitForResponse(
            id: .string("delegate-success"),
            transport: transport
        )
        XCTAssertEqual(
            response.result,
            dynamicToolResponse(
                text: "{\"type\":\"onyx_delegation_result\",\"success\":true}",
                success: true
            )
        )
        let recordedCalls = await handler.recordedCalls()
        XCTAssertEqual(
            recordedCalls,
            [
                CodexDynamicToolCall(
                    threadID: "started-thread",
                    callID: "call-success",
                    arguments: arguments,
                    parentModelID: "gpt-parent",
                    workingDirectory: "/tmp/project"
                ),
            ]
        )
        await Task.yield()
        let recordedNotices = await notices.values()
        XCTAssertEqual(recordedNotices, [])
        await runtime.disconnect()
    }

    func testHandlerFailureReturnsStructuredFailureAndDoesNotLeakErrorDetail() async throws {
        let handler = RecordingDynamicToolHandler(
            behavior: .throwError("vLLM at http://private-host:8002 rejected secret-token")
        )
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        _ = try await runtime.connect()
        try await prepareParentTurn(runtime)

        await transport.emit(validDelegateRequest(id: .string("delegate-failure")))

        let response = try await waitForResponse(
            id: .string("delegate-failure"),
            transport: transport
        )
        XCTAssertEqual(
            response.result,
            dynamicToolResponse(text: "Onyx could not complete this delegation.", success: false)
        )
        XCTAssertFalse(response.result.compactDescription.contains("private-host"))
        XCTAssertFalse(response.result.compactDescription.contains("secret-token"))
        await runtime.disconnect()
    }

    func testUnknownToolPreservesStructuredUnsupportedResponseAndNotice() async throws {
        let handler = RecordingDynamicToolHandler(behavior: .result(.succeeded("unused")))
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        let notices = RuntimeNoticeRecorder()
        let eventTask = recordRuntimeNotices(from: runtime.events, into: notices)
        defer { eventTask.cancel() }
        _ = try await runtime.connect()

        await transport.emit(
            AppServerRequest(
                id: .string("unknown-tool"),
                method: "item/tool/call",
                params: .object([
                    "threadId": .string("started-thread"),
                    "turnId": .string("parent-turn"),
                    "callId": .string("call-unknown"),
                    "tool": .string("future_tool"),
                    "arguments": .object([:]),
                ])
            )
        )

        let response = try await waitForResponse(
            id: .string("unknown-tool"),
            transport: transport
        )
        XCTAssertEqual(
            response.result,
            dynamicToolResponse(
                text: "Onyx does not support the app-server request item/tool/call.",
                success: false
            )
        )
        let didRecordNotice = try await waitUntil {
            await notices.values().contains(where: { $0.detail.contains("item/tool/call") })
        }
        XCTAssertTrue(didRecordNotice)
        let recordedCalls = await handler.recordedCalls()
        XCTAssertEqual(recordedCalls, [])
        await runtime.disconnect()
    }

    func testMalformedRecognizedCallReturnsFailureWithoutCallingHandlerOrShowingNotice() async throws {
        let handler = RecordingDynamicToolHandler(behavior: .result(.succeeded("unused")))
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        let notices = RuntimeNoticeRecorder()
        let eventTask = recordRuntimeNotices(from: runtime.events, into: notices)
        defer { eventTask.cancel() }
        _ = try await runtime.connect()

        await transport.emit(
            AppServerRequest(
                id: .string("malformed-tool"),
                method: "item/tool/call",
                params: .object([
                    "threadId": .string("started-thread"),
                    "tool": .string("onyx_delegate"),
                    "arguments": .string("not-an-object"),
                ])
            )
        )

        let response = try await waitForResponse(
            id: .string("malformed-tool"),
            transport: transport
        )
        XCTAssertEqual(
            response.result,
            dynamicToolResponse(
                text: "The onyx_delegate request is missing a valid turnId, callId, or arguments object.",
                success: false
            )
        )
        let recordedCalls = await handler.recordedCalls()
        XCTAssertEqual(recordedCalls, [])
        await Task.yield()
        let recordedNotices = await notices.values()
        XCTAssertEqual(recordedNotices, [])
        await runtime.disconnect()
    }

    func testReconnectDropsLateResultFromCancelledTransportGeneration() async throws {
        let handler = RecordingDynamicToolHandler(
            behavior: .deferred(.succeeded("stale result"))
        )
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        _ = try await runtime.connect()
        try await prepareParentTurn(runtime)

        await transport.emit(validDelegateRequest(id: .string("reused-request-id")))
        let didStartHandler = try await waitUntil {
            await handler.recordedCalls().count == 1
        }
        XCTAssertTrue(didStartHandler)

        await runtime.disconnect()
        _ = try await runtime.connect()
        await handler.releaseDeferredCalls()
        try await Task.sleep(for: .milliseconds(50))

        let responses = await transport.recordedResponses()
        XCTAssertEqual(responses, [])
        await runtime.disconnect()
    }

    func testInterruptCancelsDelegationEvenWhenParentInterruptRequestFails() async throws {
        let handler = RecordingDynamicToolHandler(
            behavior: .deferred(.succeeded("late result"))
        )
        let transport = DynamicToolCodexTransport(failsInterrupt: true)
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        _ = try await runtime.connect()
        try await prepareParentTurn(runtime)

        await transport.emit(validDelegateRequest(id: .string("delegate-to-cancel")))
        let didStartHandler = try await waitUntil {
            await handler.recordedCalls().count == 1
        }
        XCTAssertTrue(didStartHandler)

        do {
            try await runtime.interrupt(threadID: "started-thread")
            XCTFail("Expected the simulated app-server interrupt to fail")
        } catch {
            // The local delegation still has to be cancelled by the failed stop attempt.
        }
        await handler.releaseDeferredCalls()
        try await Task.sleep(for: .milliseconds(50))

        let responses = await transport.recordedResponses()
        XCTAssertEqual(responses, [])
        await runtime.disconnect()
    }

    func testOrdinaryResumeRestoresTrustedParentContextForToolCall() async throws {
        let handler = RecordingDynamicToolHandler(behavior: .result(.succeeded("done")))
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        _ = try await runtime.connect()

        _ = try await runtime.resumeThread(id: "resumed-thread")
        try await runtime.startTurn(
            StartTurnRequest(threadID: "resumed-thread", text: "Continue.")
        )
        await transport.emit(
            validDelegateRequest(
                id: .string("resumed-delegate"),
                callID: "resumed-call"
            )
        )
        _ = try await waitForResponse(id: .string("resumed-delegate"), transport: transport)

        let recordedCalls = await handler.recordedCalls()
        let call = try XCTUnwrap(recordedCalls.first)
        XCTAssertEqual(call.threadID, "resumed-thread")
        XCTAssertEqual(call.parentModelID, "gpt-resumed")
        XCTAssertEqual(call.workingDirectory, "/tmp/resumed-project")
        await runtime.disconnect()
    }

    func testPaginatedResumeRestoresTrustedParentContextForToolCall() async throws {
        let handler = RecordingDynamicToolHandler(behavior: .result(.succeeded("done")))
        let transport = DynamicToolCodexTransport()
        let runtime = CodexRuntime(client: transport, dynamicToolHandler: handler)
        _ = try await runtime.connect()

        _ = try await runtime.resumeThread(
            id: "resumed-thread",
            initialHistoryPage: RuntimeInitialThreadHistoryPageRequest(limit: 20)
        )
        try await runtime.startTurn(
            StartTurnRequest(threadID: "resumed-thread", text: "Continue.")
        )
        await transport.emit(
            validDelegateRequest(
                id: .string("paginated-resumed-delegate"),
                callID: "paginated-resumed-call"
            )
        )
        _ = try await waitForResponse(
            id: .string("paginated-resumed-delegate"),
            transport: transport
        )

        let recordedCalls = await handler.recordedCalls()
        let call = try XCTUnwrap(recordedCalls.first)
        XCTAssertEqual(call.threadID, "resumed-thread")
        XCTAssertEqual(call.parentModelID, "gpt-resumed")
        XCTAssertEqual(call.workingDirectory, "/tmp/resumed-project")
        await runtime.disconnect()
    }
}

private actor RecordingDynamicToolHandler: CodexDynamicToolHandler {
    enum Behavior: Sendable {
        case result(CodexDynamicToolResult)
        case throwError(String)
        case deferred(CodexDynamicToolResult)
    }

    private let definition: CodexDynamicToolDefinition
    private let behavior: Behavior
    private var calls: [CodexDynamicToolCall] = []
    private var definitionRequests = 0
    private var deferredCalls: [CheckedContinuation<CodexDynamicToolResult, Never>] = []

    init(
        definition: CodexDynamicToolDefinition = .onyxDelegate,
        behavior: Behavior
    ) {
        self.definition = definition
        self.behavior = behavior
    }

    func dynamicToolDefinition() -> CodexDynamicToolDefinition {
        definitionRequests += 1
        return definition
    }

    func handleDynamicToolCall(
        _ call: CodexDynamicToolCall
    ) async throws -> CodexDynamicToolResult {
        calls.append(call)
        switch behavior {
        case let .result(result): return result
        case let .throwError(detail): throw DynamicToolTestError(detail: detail)
        case .deferred:
            return await withCheckedContinuation { continuation in
                deferredCalls.append(continuation)
            }
        }
    }

    func recordedCalls() -> [CodexDynamicToolCall] { calls }
    func definitionRequestCount() -> Int { definitionRequests }

    func releaseDeferredCalls() {
        guard case let .deferred(result) = behavior else { return }
        let continuations = deferredCalls
        deferredCalls.removeAll()
        for continuation in continuations {
            continuation.resume(returning: result)
        }
    }
}

private struct DynamicToolTestError: Error, LocalizedError, Sendable {
    let detail: String
    var errorDescription: String? { detail }
}

private actor DynamicToolCodexTransport: CodexAppServerTransport {
    struct Request: Sendable {
        let method: String
        let params: JSONValue
    }

    struct Response: Sendable, Equatable {
        let id: RuntimeRequestID
        let result: JSONValue
    }

    nonisolated let events: AsyncStream<AppServerEvent>
    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation
    private var requests: [Request] = []
    private var responses: [Response] = []
    private var generation: UInt64 = 0
    private let failsInterrupt: Bool

    init(failsInterrupt: Bool = false) {
        self.failsInterrupt = failsInterrupt
        let stream = AsyncStream.makeStream(of: AppServerEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func start() -> AppServerConnection {
        generation &+= 1
        return AppServerConnection(generation: generation, initializeResponse: .object([:]))
    }

    func stop() {}

    func request(method: String, params: JSONValue) throws -> JSONValue {
        requests.append(Request(method: method, params: params))
        switch method {
        case "account/read":
            return .object([
                "account": .object(["type": .string("chatgpt")]),
                "requiresOpenaiAuth": .bool(false),
            ])
        case "model/list":
            return .object(["data": .array([])])
        case "thread/start":
            var thread: [String: JSONValue] = [
                "id": .string("started-thread"),
                "preview": .string("Started task"),
            ]
            if let model = params["model"] { thread["model"] = model }
            if let cwd = params["cwd"] { thread["cwd"] = cwd }
            return .object([
                "thread": .object(thread),
            ])
        case "turn/start":
            return .object([
                "turn": .object([
                    "id": .string("started-turn"),
                    "status": .string("inProgress"),
                    "items": .array([]),
                ]),
            ])
        case "thread/resume":
            var result: [String: JSONValue] = [
                "thread": .object([
                    "id": .string(params["threadId"]?.stringValue ?? "resumed-thread"),
                    "preview": .string("Resumed task"),
                    "model": .string("gpt-resumed"),
                    "cwd": .string("/tmp/resumed-project"),
                    "turns": .array([]),
                ]),
            ]
            if params["initialTurnsPage"] != nil {
                result["initialTurnsPage"] = .null
            }
            return .object(result)
        case "turn/interrupt":
            if failsInterrupt {
                throw DynamicToolTestError(detail: "simulated interrupt failure")
            }
            return .object([:])
        default:
            return .object([:])
        }
    }

    func respond(id: RuntimeRequestID, result: JSONValue) {
        responses.append(Response(id: id, result: result))
    }

    func emit(_ request: AppServerRequest) {
        eventContinuation.yield(.request(generation: generation, request))
    }

    func recordedRequests() -> [Request] { requests }
    func recordedResponses() -> [Response] { responses }
}

private actor RuntimeNoticeRecorder {
    struct Notice: Sendable, Equatable {
        let title: String
        let detail: String
    }

    private var notices: [Notice] = []

    func append(title: String, detail: String) {
        notices.append(Notice(title: title, detail: detail))
    }

    func values() -> [Notice] { notices }
}

private func recordRuntimeNotices(
    from events: AsyncStream<AgentRuntimeEvent>,
    into recorder: RuntimeNoticeRecorder
) -> Task<Void, Never> {
    Task {
        for await event in events {
            guard case let .runtimeNotice(title, detail) = event else { continue }
            await recorder.append(title: title, detail: detail)
        }
    }
}

private func validDelegateRequest(
    id: RuntimeRequestID,
    callID: String = "call-1"
) -> AppServerRequest {
    AppServerRequest(
        id: id,
        method: "item/tool/call",
        params: .object([
            "turnId": .string("started-turn"),
            "callId": .string(callID),
            "tool": .string("onyx_delegate"),
            "arguments": .object([
                "provider": .string("local-qwen"),
                "model": .string("Qwen/Qwen3.8-27B-FP8"),
                "prompt": .string("Check this."),
            ]),
        ])
    )
}

private func prepareParentTurn(_ runtime: CodexRuntime) async throws {
    _ = try await runtime.startThread(
        StartThreadRequest(cwd: "/tmp/project", model: "gpt-parent")
    )
    try await runtime.startTurn(
        StartTurnRequest(threadID: "started-thread", text: "Use the delegated model.")
    )
}

private func dynamicToolResponse(text: String, success: Bool) -> JSONValue {
    .object([
        "contentItems": .array([
            .object([
                "type": .string("inputText"),
                "text": .string(text),
            ]),
        ]),
        "success": .bool(success),
    ])
}

private enum DynamicToolWaitError: Error {
    case timedOut(RuntimeRequestID)
}

private func waitForResponse(
    id: RuntimeRequestID,
    transport: DynamicToolCodexTransport
) async throws -> DynamicToolCodexTransport.Response {
    for _ in 0..<200 {
        if let response = await transport.recordedResponses().first(where: { $0.id == id }) {
            return response
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw DynamicToolWaitError.timedOut(id)
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}
