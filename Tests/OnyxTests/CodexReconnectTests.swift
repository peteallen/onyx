import Foundation
import XCTest
@testable import Onyx

final class CodexReconnectTests: XCTestCase {
    func testReconnectIgnoresEveryBufferedEventFromThePreviousConnection() async throws {
        let transport = ReconnectCodexTransport()
        let runtime = CodexRuntime(client: transport)
        let events = RuntimeEventRecorder()
        await events.start(stream: runtime.events)

        _ = try await runtime.connect()
        let firstGenerationValue = await transport.currentGeneration()
        let firstGeneration = try XCTUnwrap(firstGenerationValue)
        await runtime.disconnect()
        _ = try await runtime.connect()
        let secondGenerationValue = await transport.currentGeneration()
        let secondGeneration = try XCTUnwrap(secondGenerationValue)
        XCTAssertNotEqual(firstGeneration, secondGeneration)

        let staleRequestID = RuntimeRequestID.integer(77)
        await transport.emit(
            .notification(
                generation: firstGeneration,
                AppServerNotification(
                    method: "turn/started",
                    params: .object([
                        "threadId": .string("stale-thread"),
                        "turn": .object(["id": .string("stale-turn")]),
                    ])
                )
            )
        )
        await transport.emit(
            .request(
                generation: firstGeneration,
                AppServerRequest(
                    id: staleRequestID,
                    method: "item/commandExecution/requestApproval",
                    params: .object([
                        "threadId": .string("stale-thread"),
                        "command": .string("echo stale"),
                    ])
                )
            )
        )
        await transport.emit(.stopped(generation: firstGeneration, "stale connection stopped"))
        await transport.emit(.stderr(generation: secondGeneration, "error: current-generation barrier"))

        try await events.waitForNotice(containing: "current-generation barrier")

        await XCTAssertThrowsErrorAsync {
            try await runtime.steer(threadID: "stale-thread", text: "must not steer")
        }
        await XCTAssertThrowsErrorAsync {
            try await runtime.respond(to: staleRequestID, with: .approval(.accept))
        }

        _ = try await runtime.connect()
        let startCount = await transport.startCount()
        XCTAssertEqual(startCount, 2, "A stale stop must not disconnect the new generation")
        let recordedEvents = await events.snapshot()
        XCTAssertFalse(recordedEvents.contains(.connectionChanged(.failed("stale connection stopped"))))
        await runtime.disconnect()
    }

    func testDisconnectClearsThePreviousConnectionsActiveTurn() async throws {
        let transport = ReconnectCodexTransport()
        let runtime = CodexRuntime(client: transport)

        _ = try await runtime.connect()
        try await runtime.startTurn(
            StartTurnRequest(threadID: "thread-1", text: "Start", cwd: "/tmp")
        )
        try await runtime.steer(threadID: "thread-1", text: "Before reconnect")

        await runtime.disconnect()
        _ = try await runtime.connect()

        await XCTAssertThrowsErrorAsync {
            try await runtime.steer(threadID: "thread-1", text: "After reconnect")
        }
        await runtime.disconnect()
    }

    func testReconnectKeepsOneLongLivedTransportEventPump() async throws {
        let transport = ReconnectCodexTransport()
        let runtime = CodexRuntime(client: transport)
        let events = RuntimeEventRecorder()
        await events.start(stream: runtime.events)

        _ = try await runtime.connect()
        await runtime.disconnect()
        _ = try await runtime.connect()
        let currentGenerationValue = await transport.currentGeneration()
        let currentGeneration = try XCTUnwrap(currentGenerationValue)
        await transport.emit(.stderr(generation: currentGeneration, "error: event-pump barrier"))
        try await events.waitForNotice(containing: "event-pump barrier")

        XCTAssertEqual(transport.eventStreamAccessCount, 1)
        await runtime.disconnect()
    }

    func testLateDisconnectCompletionCannotClobberACompletedReconnect() async throws {
        let transport = ReconnectCodexTransport()
        let runtime = CodexRuntime(client: transport)
        let events = RuntimeEventRecorder()
        await events.start(stream: runtime.events)

        _ = try await runtime.connect()
        await transport.blockNextStop()
        let disconnect = Task { await runtime.disconnect() }
        await transport.waitUntilStopEntered()

        _ = try await runtime.connect()
        let currentGenerationValue = await transport.currentGeneration()
        let currentGeneration = try XCTUnwrap(currentGenerationValue)
        await transport.releaseStop()
        await disconnect.value

        await transport.emit(.stderr(generation: currentGeneration, "error: reconnect-complete barrier"))
        try await events.waitForNotice(containing: "reconnect-complete barrier")

        _ = try await runtime.connect()
        let startCount = await transport.startCount()
        XCTAssertEqual(startCount, 2, "The old disconnect must not mark the new connection disconnected")
        let recordedEvents = await events.snapshot()
        XCTAssertFalse(recordedEvents.contains(.connectionChanged(.disconnected)))
        await runtime.disconnect()
    }

    func testClientReconnectDropsAPartialLineFromThePreviousProcess() async throws {
        let counterURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-reconnect-\(UUID().uuidString).count")
        defer { try? FileManager.default.removeItem(at: counterURL) }

        let script = #"""
        counter_path="$0"
        count=0
        if [ -f "$counter_path" ]; then count=$(cat "$counter_path"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$counter_path"
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{"generation":%s}}\n' "$id" "$count" ;;
            *'"method":"initialized"'*) ;;
            *'"method":"prepare"'*)
              printf '{"id":%s,"result":{}}\n' "$id"
              if [ "$count" -eq 1 ]; then printf '{"method":"partial-from-old-process"'; fi
              ;;
            *'"method":"echo"'*) printf '{"id":%s,"result":{"generation":%s}}\n' "$id" "$count" ;;
          esac
        done
        """#
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", script, counterURL.path]
        )

        let first = try await client.start()
        XCTAssertEqual(first.generation, 1)
        _ = try await client.request(method: "prepare", params: .object([:]))
        await client.stop()

        let second = try await client.start()
        XCTAssertEqual(second.generation, 2)
        let echo = try await client.request(method: "echo", params: .object([:]))
        XCTAssertEqual(echo["generation"]?.intValue, 2)
        await client.stop()
    }
}

private actor ReconnectCodexTransport: CodexAppServerTransport {
    nonisolated var events: AsyncStream<AppServerEvent> {
        eventAccessLock.lock()
        _eventStreamAccessCount += 1
        eventAccessLock.unlock()
        return eventStream
    }

    nonisolated var eventStreamAccessCount: Int {
        eventAccessLock.lock()
        defer { eventAccessLock.unlock() }
        return _eventStreamAccessCount
    }

    private nonisolated let eventStream: AsyncStream<AppServerEvent>
    private let continuation: AsyncStream<AppServerEvent>.Continuation
    private nonisolated let eventAccessLock = NSLock()
    private nonisolated(unsafe) var _eventStreamAccessCount = 0
    private var starts = 0
    private var generation: UInt64?
    private var shouldBlockNextStop = false
    private var stopEntered = false
    private var stopEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRelease: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream.makeStream(of: AppServerEvent.self)
        eventStream = stream.stream
        continuation = stream.continuation
    }

    func start() async throws -> AppServerConnection {
        starts += 1
        let next = UInt64(starts)
        generation = next
        return AppServerConnection(generation: next, initializeResponse: .object([:]))
    }

    func stop() async {
        generation = nil
        guard shouldBlockNextStop else { return }
        shouldBlockNextStop = false
        stopEntered = true
        let waiters = stopEntryWaiters
        stopEntryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            stopRelease = continuation
        }
        stopEntered = false
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "account/read":
            return .object([
                "account": .object(["type": .string("chatgpt")]),
                "requiresOpenaiAuth": .bool(true),
            ])
        case "model/list":
            return .object(["data": .array([])])
        case "turn/start":
            return .object([
                "turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("inProgress"),
                ]),
            ])
        default:
            return .object([:])
        }
    }

    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}

    func emit(_ event: AppServerEvent) {
        continuation.yield(event)
    }

    func currentGeneration() -> UInt64? { generation }
    func startCount() -> Int { starts }

    func blockNextStop() {
        shouldBlockNextStop = true
    }

    func waitUntilStopEntered() async {
        if stopEntered { return }
        await withCheckedContinuation { continuation in
            stopEntryWaiters.append(continuation)
        }
    }

    func releaseStop() {
        stopRelease?.resume()
        stopRelease = nil
    }
}

private actor RuntimeEventRecorder {
    enum WaitError: Error {
        case timedOut
    }

    private var events: [AgentRuntimeEvent] = []
    private var noticeWaiters: [UUID: NoticeWaiter] = [:]
    private var task: Task<Void, Never>?

    private struct NoticeWaiter {
        let needle: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    func start(stream: AsyncStream<AgentRuntimeEvent>) {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await event in stream {
                await self?.record(event)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    func snapshot() -> [AgentRuntimeEvent] { events }

    func waitForNotice(containing needle: String) async throws {
        let clock = ContinuousClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.suspendUntilNotice(containing: needle)
            }
            group.addTask {
                try await clock.sleep(for: .seconds(2))
                throw WaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func record(_ event: AgentRuntimeEvent) {
        events.append(event)
        guard case let .runtimeNotice(_, detail) = event else { return }
        let matches = noticeWaiters.filter { detail.contains($0.value.needle) }
        for (id, waiter) in matches {
            noticeWaiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    private func suspendUntilNotice(containing needle: String) async throws {
        if hasNotice(containing: needle) { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                noticeWaiters[id] = NoticeWaiter(needle: needle, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelNoticeWaiter(id) }
        }
    }

    private func cancelNoticeWaiter(_ id: UUID) {
        guard let waiter = noticeWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func hasNotice(containing needle: String) -> Bool {
        events.contains { event in
            guard case let .runtimeNotice(_, detail) = event else { return false }
            return detail.contains(needle)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
