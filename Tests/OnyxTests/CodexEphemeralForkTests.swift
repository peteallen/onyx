import Foundation
import XCTest
@testable import Onyx

final class CodexEphemeralForkTests: XCTestCase {
    func testEphemeralForkStaysOutOfDurableTasksAndCatalogAndLeavesParentUntouched() async throws {
        let catalogDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxEphemeralForkTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: catalogDirectory) }

        let parentCatalogRecord = ConversationCatalogRecord(
            id: ConversationID("local-parent"),
            binding: ProviderConversationBinding(
                connectionID: .codexDefault,
                opaqueRemoteThreadID: "parent-thread"
            ),
            title: "Parent task",
            createdAt: Date(timeIntervalSince1970: 1_787_385_600),
            updatedAt: Date(timeIntervalSince1970: 1_787_385_660)
        )
        let catalog = ConversationCatalogStore(
            fileURL: catalogDirectory.appendingPathComponent("catalog.json")
        )
        try await catalog.upsert(parentCatalogRecord)

        let transport = EphemeralForkCodexTransport()
        let runtime = SharedRuntimeCoordinator(runtime: CodexRuntime(client: transport))
        let session = try await runtime.connect()

        let parentBefore = try await runtime.readThread(id: "parent-thread")
        let sideChat = try await runtime.forkEphemeralThread(id: "parent-thread")
        let durableTasks = try await runtime.listThreads(limit: 100, archived: false)
        let parentAfter = try await runtime.readThread(id: "parent-thread")
        let catalogAfter = try await catalog.snapshot()
        let recordedForkRequest = await transport.forkRequest()
        let forkRequest = try XCTUnwrap(recordedForkRequest)
        await runtime.disconnect()

        XCTAssertEqual(forkRequest.params["threadId"]?.stringValue, "parent-thread")
        XCTAssertEqual(forkRequest.params["ephemeral"]?.boolValue, true)
        XCTAssertEqual(forkRequest.params["excludeTurns"]?.boolValue, false)
        XCTAssertTrue(session.capabilities.contains(.ephemeralThreadForking))
        XCTAssertEqual(sideChat.thread.id, "side-thread")
        XCTAssertEqual(sideChat.items, parentBefore.items, "The fork should begin with an isolated copy of parent history")
        XCTAssertEqual(durableTasks.map(\.id), ["parent-thread"])
        XCTAssertEqual(parentAfter, parentBefore, "Forking must not append to or replace the parent transcript")
        XCTAssertEqual(catalogAfter.conversations, [parentCatalogRecord])
        XCTAssertNil(
            catalogAfter.conversations.first { $0.binding.opaqueRemoteThreadID == sideChat.thread.id },
            "Ephemeral side chats must never become durable catalog records"
        )
    }

    func testEphemeralThreadStartSkipsTaskListUpdateButKeepsSideChatEvents() async throws {
        let transport = EphemeralForkCodexTransport()
        let runtime = CodexRuntime(client: transport)
        let probe = EphemeralEventProbe()
        let receivedDurableUpdate = expectation(description: "received durable thread update")

        let collector = Task {
            for await event in runtime.events {
                switch event {
                case let .threadUpdated(thread):
                    await probe.recordThreadUpdate(thread.id)
                    if thread.id == "durable-thread" {
                        receivedDurableUpdate.fulfill()
                    }
                case let .itemCompleted(threadID, item) where threadID == "side-thread":
                    await probe.recordSideItem(item.body)
                default:
                    continue
                }
            }
        }

        _ = try await runtime.connect()
        await transport.emitThreadStarted(id: "side-thread", ephemeral: true)
        await transport.emitSideItemCompleted()
        await transport.emitThreadStarted(id: "durable-thread", ephemeral: false)
        await fulfillment(of: [receivedDurableUpdate], timeout: 1)
        collector.cancel()
        await runtime.disconnect()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.threadUpdates, ["durable-thread"])
        XCTAssertEqual(snapshot.sideItems, ["Side answer"])
    }

    func testForkWithoutExplicitEphemeralConfirmationIsDeletedAndRejected() async throws {
        let transport = EphemeralForkCodexTransport(forkResponseEphemeral: nil)
        let runtime = CodexRuntime(client: transport)

        do {
            _ = try await runtime.forkEphemeralThread(id: "parent-thread")
            XCTFail("A fork without explicit ephemeral metadata must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("without explicit ephemeral confirmation"))
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["thread/fork", "thread/delete"])
        XCTAssertEqual(requests.last?.params["threadId"]?.stringValue, "side-thread")
    }

    func testThreadStartedBeforeForkResponseIsQuarantinedWithAllLateLifecycleEvents() async throws {
        let transport = EphemeralForkCodexTransport(delayForkResponse: true)
        let runtime = CodexRuntime(client: transport)
        let probe = EphemeralEventProbe()
        let collector = Task {
            for await event in runtime.events {
                await probe.record(event)
            }
        }

        _ = try await runtime.connect()
        let forkTask = Task { try await runtime.forkEphemeralThread(id: "parent-thread") }
        await transport.waitUntilForkIsPending()
        await transport.emitThreadStarted(
            id: "side-thread",
            ephemeral: false,
            forkedFromID: "parent-thread"
        )
        await transport.emitThreadLifecycle(
            method: "thread/status/changed",
            threadID: "side-thread",
            extra: ["status": .object(["type": .string("active")])]
        )
        await transport.completeDelayedFork()
        _ = try await forkTask.value
        await transport.emitThreadLifecycle(
            method: "thread/name/updated",
            threadID: "side-thread",
            extra: ["threadName": .string("Must stay hidden")]
        )
        await transport.emitThreadLifecycle(method: "thread/archived", threadID: "side-thread")
        await transport.emitThreadLifecycle(method: "thread/unarchived", threadID: "side-thread")
        await transport.emitThreadLifecycle(method: "thread/reverted", threadID: "side-thread")
        await transport.emitThreadLifecycle(method: "thread/deleted", threadID: "side-thread")
        await transport.emitRuntimeNotice()
        await probe.waitForNotice()
        collector.cancel()
        await runtime.disconnect()

        let snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.sideLifecycleEvents.isEmpty)
    }

    func testUnrelatedDurableStartBufferedDuringForkIsReleasedAfterClassification() async throws {
        let transport = EphemeralForkCodexTransport(delayForkResponse: true)
        let runtime = CodexRuntime(client: transport)
        let probe = EphemeralEventProbe()
        let collector = Task {
            for await event in runtime.events {
                await probe.record(event)
            }
        }

        _ = try await runtime.connect()
        let forkTask = Task { try await runtime.forkEphemeralThread(id: "parent-thread") }
        await transport.waitUntilForkIsPending()
        await transport.emitThreadStarted(id: "durable-thread", ephemeral: false)
        await Task.yield()
        let beforeClassification = await probe.snapshot()
        XCTAssertTrue(beforeClassification.threadUpdates.isEmpty)

        await transport.completeDelayedFork()
        _ = try await forkTask.value
        await probe.waitForThreadUpdate("durable-thread")
        collector.cancel()
        await runtime.disconnect()

        let afterClassification = await probe.snapshot()
        XCTAssertEqual(afterClassification.threadUpdates, ["durable-thread"])
    }

    func testCancelledTurnStartInterruptsWorkAcceptedAfterCancellation() async throws {
        let transport = EphemeralForkCodexTransport(delayTurnResponse: true)
        let runtime = CodexRuntime(client: transport)
        let task = Task {
            try await runtime.startTurn(
                StartTurnRequest(
                    threadID: "side-thread",
                    inputs: [.text("Do not leave this running")]
                )
            )
        }

        await transport.waitUntilTurnIsPending()
        task.cancel()
        await transport.completeDelayedTurn()
        do {
            try await task.value
            XCTFail("Cancellation should be reported after cleaning up the accepted turn")
        } catch is CancellationError {
            // Expected only after the runtime has sent the interrupt below.
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["turn/start", "turn/interrupt"])
        XCTAssertEqual(requests.last?.params["threadId"]?.stringValue, "side-thread")
        XCTAssertEqual(requests.last?.params["turnId"]?.stringValue, "side-turn")
    }
}

private actor EphemeralEventProbe {
    struct Snapshot: Sendable {
        let threadUpdates: [String]
        let sideItems: [String]
        let sideLifecycleEvents: [AgentRuntimeEvent]
    }

    private var threadUpdates: [String] = []
    private var sideItems: [String] = []
    private var sideLifecycleEvents: [AgentRuntimeEvent] = []
    private var sawNotice = false

    func recordThreadUpdate(_ id: String) {
        threadUpdates.append(id)
    }

    func recordSideItem(_ body: String) {
        sideItems.append(body)
    }

    func record(_ event: AgentRuntimeEvent) {
        switch event {
        case let .threadUpdated(thread):
            threadUpdates.append(thread.id)
            if thread.id == "side-thread" { sideLifecycleEvents.append(event) }
        case let .threadNameChanged(threadID, _),
             let .threadStatusChanged(threadID, _),
             let .threadArchived(threadID),
             let .threadUnarchived(threadID),
             let .threadDeleted(threadID),
             let .threadRefreshRequested(threadID):
            if threadID == "side-thread" { sideLifecycleEvents.append(event) }
        case .runtimeNotice:
            sawNotice = true
        default:
            break
        }
    }

    func waitForNotice() async {
        while !sawNotice { await Task.yield() }
    }

    func waitForThreadUpdate(_ id: String) async {
        while !threadUpdates.contains(id) { await Task.yield() }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            threadUpdates: threadUpdates,
            sideItems: sideItems,
            sideLifecycleEvents: sideLifecycleEvents
        )
    }
}

private actor EphemeralForkCodexTransport: CodexAppServerTransport {
    struct Request: Sendable {
        let method: String
        let params: JSONValue
    }

    nonisolated let events: AsyncStream<AppServerEvent>
    private nonisolated let eventContinuation: AsyncStream<AppServerEvent>.Continuation
    private var requests: [Request] = []
    private let forkResponseEphemeral: Bool?
    private let delayForkResponse: Bool
    private let delayTurnResponse: Bool
    private var delayedForkContinuation: CheckedContinuation<JSONValue, Never>?
    private var delayedTurnContinuation: CheckedContinuation<JSONValue, Never>?

    init(
        forkResponseEphemeral: Bool? = true,
        delayForkResponse: Bool = false,
        delayTurnResponse: Bool = false
    ) {
        self.forkResponseEphemeral = forkResponseEphemeral
        self.delayForkResponse = delayForkResponse
        self.delayTurnResponse = delayTurnResponse
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
        switch method {
        case "account/read":
            return .object([
                "account": .object(["type": .string("chatgpt")]),
                "requiresOpenaiAuth": .bool(true),
            ])
        case "model/list":
            return .object(["data": .array([])])
        case "thread/read":
            return .object(["thread": Self.parentThread])
        case "thread/fork":
            var sideThread = Self.parentThread.objectValue ?? [:]
            sideThread["id"] = .string("side-thread")
            sideThread["name"] = .string("Ephemeral side chat")
            if let forkResponseEphemeral {
                sideThread["ephemeral"] = .bool(forkResponseEphemeral)
            } else {
                sideThread.removeValue(forKey: "ephemeral")
            }
            sideThread["forkedFromId"] = .string("parent-thread")
            let result = JSONValue.object(["thread": .object(sideThread)])
            if delayForkResponse {
                return await withCheckedContinuation { delayedForkContinuation = $0 }
            }
            return result
        case "thread/list":
            // Include the live fork defensively: the runtime boundary must not
            // leak it into the durable task surface even if a provider version
            // returns ephemeral metadata alongside materialized threads.
            var sideThread = Self.parentThread.objectValue ?? [:]
            sideThread["id"] = .string("side-thread")
            sideThread["ephemeral"] = .bool(true)
            return .object(["data": .array([Self.parentThread, .object(sideThread)])])
        case "turn/start":
            let result = JSONValue.object([
                "turn": .object([
                    "id": .string("side-turn"),
                    "status": .string("inProgress"),
                ]),
            ])
            if delayTurnResponse {
                return await withCheckedContinuation { delayedTurnContinuation = $0 }
            }
            return result
        case "turn/interrupt":
            return .object([:])
        default:
            return .object([:])
        }
    }

    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}

    func forkRequest() -> Request? {
        requests.first { $0.method == "thread/fork" }
    }

    func recordedRequests() -> [Request] { requests }

    func waitUntilForkIsPending() async {
        while delayedForkContinuation == nil { await Task.yield() }
    }

    func completeDelayedFork() {
        guard let continuation = delayedForkContinuation else { return }
        var sideThread = Self.parentThread.objectValue ?? [:]
        sideThread["id"] = .string("side-thread")
        sideThread["name"] = .string("Ephemeral side chat")
        if let forkResponseEphemeral {
            sideThread["ephemeral"] = .bool(forkResponseEphemeral)
        } else {
            sideThread.removeValue(forKey: "ephemeral")
        }
        sideThread["forkedFromId"] = .string("parent-thread")
        delayedForkContinuation = nil
        continuation.resume(returning: .object(["thread": .object(sideThread)]))
    }

    func waitUntilTurnIsPending() async {
        while delayedTurnContinuation == nil { await Task.yield() }
    }

    func completeDelayedTurn() {
        guard let continuation = delayedTurnContinuation else { return }
        delayedTurnContinuation = nil
        continuation.resume(
            returning: .object([
                "turn": .object([
                    "id": .string("side-turn"),
                    "status": .string("inProgress"),
                ]),
            ])
        )
    }

    func emitThreadStarted(id: String, ephemeral: Bool, forkedFromID: String? = nil) {
        var thread: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(ephemeral ? "Side chat" : "Durable task"),
            "preview": .string(ephemeral ? "Side chat" : "Durable task"),
            "ephemeral": .bool(ephemeral),
        ]
        if let forkedFromID { thread["forkedFromId"] = .string(forkedFromID) }
        eventContinuation.yield(
            .notification(
                generation: 1,
                AppServerNotification(
                    method: "thread/started",
                    params: .object([
                        "thread": .object(thread),
                    ])
                )
            )
        )
    }

    func emitThreadLifecycle(
        method: String,
        threadID: String,
        extra: [String: JSONValue] = [:]
    ) {
        var params = extra
        params["threadId"] = .string(threadID)
        eventContinuation.yield(
            .notification(
                generation: 1,
                AppServerNotification(method: method, params: .object(params))
            )
        )
    }

    func emitRuntimeNotice() {
        eventContinuation.yield(
            .notification(
                generation: 1,
                AppServerNotification(
                    method: "error",
                    params: .object(["message": .string("barrier")])
                )
            )
        )
    }

    func emitSideItemCompleted() {
        eventContinuation.yield(
            .notification(
                generation: 1,
                AppServerNotification(
                    method: "item/completed",
                    params: .object([
                        "threadId": .string("side-thread"),
                        "item": .object([
                            "type": .string("agentMessage"),
                            "id": .string("side-answer"),
                            "text": .string("Side answer"),
                        ]),
                    ])
                )
            )
        )
    }

    private static let parentThread = JSONValue.object([
        "id": .string("parent-thread"),
        "name": .string("Parent task"),
        "preview": .string("Parent question"),
        "cwd": .string("/tmp/onyx"),
        "updatedAt": .integer(1_787_385_660),
        "status": .object(["type": .string("idle")]),
        "ephemeral": .bool(false),
        "turns": .array([
            .object([
                "id": .string("parent-turn"),
                "status": .string("completed"),
                "items": .array([
                    .object([
                        "type": .string("userMessage"),
                        "id": .string("parent-user"),
                        "createdAt": .integer(1_787_385_600),
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("Parent question")]),
                        ]),
                    ]),
                    .object([
                        "type": .string("agentMessage"),
                        "id": .string("parent-answer"),
                        "createdAt": .integer(1_787_385_601),
                        "text": .string("Parent answer"),
                    ]),
                ]),
            ]),
        ]),
    ])
}
