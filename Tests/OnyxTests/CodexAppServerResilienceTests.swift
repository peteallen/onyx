import Foundation
import XCTest
@testable import Onyx

final class CodexAppServerResilienceTests: XCTestCase {
    func testUnexpectedProcessExitFailsInFlightRequestAndReportsExitStatus() async throws {
        let script = #"""
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *'"method":"initialized"'*) ;;
            *'"method":"crash"'*) exec 1>&-; sleep 0.02; exit 23 ;;
          esac
        done
        """#
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", script]
        )

        let connection = try await client.start()
        let request = Task {
            try await client.request(method: "crash", params: .object([:]))
        }

        let stopped: (generation: UInt64, reason: String)
        do {
            stopped = try await nextStoppedEvent(in: client.events)
        } catch {
            await client.stop()
            _ = await request.result
            throw error
        }

        XCTAssertEqual(stopped.generation, connection.generation)
        XCTAssertTrue(stopped.reason.contains("exit 23"), stopped.reason)

        switch await request.result {
        case .success:
            XCTFail("A request must not succeed after its app-server process exits")
        case let .failure(error):
            guard case let .processExited(status) = error as? AgentRuntimeError else {
                return XCTFail("Expected processExited, got \(error)")
            }
            XCTAssertEqual(status, 23)
        }

        await client.stop()
    }

    func testOutputEOFWhileProcessRemainsAliveFallsBackToProtocolFailure() async throws {
        let counterURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-eof-fallback-\(UUID().uuidString).count")
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
            *'"method":"closeOutput"'*)
              if [ "$count" -eq 1 ]; then exec 1>&-; sleep 5; else printf '{"id":%s,"result":{"ok":true}}\n' "$id"; fi
              ;;
            *'"method":"echo"'*) printf '{"id":%s,"result":{"ok":true}}\n' "$id" ;;
          esac
        done
        """#
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", script, counterURL.path]
        )

        let connection = try await client.start()
        let request = Task {
            try await client.request(method: "closeOutput", params: .object([:]))
        }

        let stopped: (generation: UInt64, reason: String)
        do {
            stopped = try await nextStoppedEvent(in: client.events)
        } catch {
            await client.stop()
            _ = await request.result
            throw error
        }

        XCTAssertEqual(stopped.generation, connection.generation)
        XCTAssertTrue(stopped.reason.contains("closed its output stream"), stopped.reason)

        switch await request.result {
        case .success:
            XCTFail("A request must fail when app-server closes stdout while remaining alive")
        case let .failure(error):
            guard case let .protocolFailure(message) = error as? AgentRuntimeError else {
                return XCTFail("Expected protocolFailure, got \(error)")
            }
            XCTAssertTrue(message.contains("closed its output stream"), message)
        }

        // The fallback must fully retire the old generation so callers can
        // reconnect immediately while the terminated process is being reaped.
        let second = try await client.start()
        XCTAssertNotEqual(connection.generation, second.generation)
        XCTAssertEqual(second.initializeResponse["generation"]?.intValue, 2)
        let echo = try await client.request(method: "echo", params: .object([:]))
        XCTAssertEqual(echo["ok"]?.boolValue, true)
        await client.stop()
    }

    func testMalformedJSONFailsPendingRequestImmediatelyAndAllowsReconnect() async throws {
        let counterURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-malformed-transport-\(UUID().uuidString).count")
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
            *'"method":"malformed"'*) printf 'this is not json\n' ;;
            *'"method":"echo"'*) printf '{"id":%s,"result":{"generation":%s}}\n' "$id" "$count" ;;
          esac
        done
        """#
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", script, counterURL.path]
        )

        let first = try await client.start()
        let request = Task {
            try await client.request(method: "malformed", params: .object([:]))
        }

        let stopped: (generation: UInt64, reason: String)
        do {
            stopped = try await nextStoppedEvent(in: client.events)
        } catch {
            await client.stop()
            _ = await request.result
            throw error
        }

        XCTAssertEqual(stopped.generation, first.generation)
        XCTAssertTrue(stopped.reason.contains("app-server transport failed"), stopped.reason)
        switch await request.result {
        case .success:
            XCTFail("Malformed protocol output must fail its pending request")
        case let .failure(error):
            guard case let .protocolFailure(message) = error as? AgentRuntimeError else {
                return XCTFail("Expected protocolFailure, got \(error)")
            }
            XCTAssertTrue(message.contains("app-server transport failed"), message)
        }

        let second = try await client.start()
        XCTAssertNotEqual(first.generation, second.generation)
        let echo = try await client.request(method: "echo", params: .object([:]))
        XCTAssertEqual(echo["generation"]?.intValue, 2)
        await client.stop()
    }

    func testFutureNotificationAndResponseFieldsDoNotCorruptConnection() async throws {
        let script = #"""
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"id":%s,"result":{"serverVersion":999,"futureCapability":{"enabled":true}}}\n' "$id"
              printf '{"method":"future/session/changed","params":{"schemaVersion":999,"newField":"preserved"}}\n'
              ;;
            *'"method":"initialized"'*) ;;
            *'"method":"futureResponse"'*) printf '{"id":%s,"futureResult":{"ok":true},"schemaVersion":999}\n' "$id" ;;
            *'"method":"echo"'*) printf '{"id":%s,"result":{"ok":true,"newField":"ignored"}}\n' "$id" ;;
          esac
        done
        """#
        let client = CodexAppServerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            processArguments: ["-c", script]
        )

        let connection = try await client.start()
        XCTAssertEqual(connection.initializeResponse["serverVersion"]?.intValue, 999)

        let notification = try await nextNotification(in: client.events)
        XCTAssertEqual(notification.generation, connection.generation)
        XCTAssertEqual(notification.notification.method, "future/session/changed")
        XCTAssertEqual(notification.notification.params["newField"]?.stringValue, "preserved")

        do {
            _ = try await client.request(method: "futureResponse", params: .object([:]))
            XCTFail("A response without result or error must not be treated as success")
        } catch let error as AgentRuntimeError {
            guard case let .protocolFailure(message) = error else {
                return XCTFail("Expected protocolFailure, got \(error)")
            }
            XCTAssertTrue(message.contains("futureResponse"), message)
            XCTAssertTrue(message.contains("neither result nor error"), message)
        }

        let echo = try await client.request(method: "echo", params: .object([:]))
        XCTAssertEqual(echo["ok"]?.boolValue, true)
        await client.stop()
    }

    func testRuntimeReconnectsAfterCurrentTransportStops() async throws {
        let transport = ResilienceCodexTransport()
        let runtime = CodexRuntime(client: transport)

        _ = try await runtime.connect()
        let firstGenerationValue = await transport.currentGeneration()
        let firstGeneration = try XCTUnwrap(firstGenerationValue)
        await transport.crash(reason: "simulated app-server crash")

        let failure = try await nextConnectionFailure(in: runtime.events)
        XCTAssertEqual(failure, "simulated app-server crash")

        _ = try await runtime.connect()
        let secondGenerationValue = await transport.currentGeneration()
        let secondGeneration = try XCTUnwrap(secondGenerationValue)
        let startCount = await transport.startCount()
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(startCount, 2)
        await runtime.disconnect()
    }
}

private actor ResilienceCodexTransport: CodexAppServerTransport {
    nonisolated let events: AsyncStream<AppServerEvent>
    private let continuation: AsyncStream<AppServerEvent>.Continuation
    private var starts = 0
    private var generation: UInt64?

    init() {
        let stream = AsyncStream.makeStream(of: AppServerEvent.self)
        events = stream.stream
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
    }

    func request(method: String, params _: JSONValue) async throws -> JSONValue {
        switch method {
        case "account/read":
            .object(["account": .object(["type": .string("chatgpt")])])
        case "model/list":
            .object(["data": .array([])])
        default:
            .object([:])
        }
    }

    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}

    func crash(reason: String) {
        guard let generation else { return }
        self.generation = nil
        continuation.yield(.stopped(generation: generation, reason))
    }

    func currentGeneration() -> UInt64? { generation }
    func startCount() -> Int { starts }
}

private enum ResilienceTestError: Error {
    case streamEnded
    case timedOut
}

private func nextStoppedEvent(
    in events: AsyncStream<AppServerEvent>
) async throws -> (generation: UInt64, reason: String) {
    try await withResilienceTimeout {
        for await event in events {
            if case let .stopped(generation, reason) = event {
                return (generation, reason)
            }
        }
        throw ResilienceTestError.streamEnded
    }
}

private func nextNotification(
    in events: AsyncStream<AppServerEvent>
) async throws -> (generation: UInt64, notification: AppServerNotification) {
    try await withResilienceTimeout {
        for await event in events {
            if case let .notification(generation, notification) = event {
                return (generation, notification)
            }
        }
        throw ResilienceTestError.streamEnded
    }
}

private func nextConnectionFailure(
    in events: AsyncStream<AgentRuntimeEvent>
) async throws -> String {
    try await withResilienceTimeout {
        for await event in events {
            if case let .connectionChanged(.failed(reason)) = event {
                return reason
            }
        }
        throw ResilienceTestError.streamEnded
    }
}

private func withResilienceTimeout<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let clock = ContinuousClock()
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await clock.sleep(for: .seconds(2))
            throw ResilienceTestError.timedOut
        }
        guard let result = try await group.next() else {
            throw ResilienceTestError.streamEnded
        }
        group.cancelAll()
        return result
    }
}
