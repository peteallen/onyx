import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleAgentTurnLivenessRuntimeTests: XCTestCase {
    func testSilentAcceptedTurnBecomesFriendlyAttachedFailureInsteadOfWorkingForever() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime()
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .milliseconds(60)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        try await runtime.startTurn(Self.startTurnRequest)
        await upstream.emit(.turnStarted(threadID: "thread-1", turnID: "turn-stalled"))

        try await waitUntil("The silent turn never reached its bounded failure") {
            await log.events.contains { event in
                if case .connectionChanged(.failed) = event { return true }
                return false
            }
        }

        let events = await log.events
        let failure = try XCTUnwrap(events.compactMap { event -> TimelineItem? in
            guard case let .itemCompleted(threadID, item) = event,
                  threadID == "thread-1",
                  item.id.hasPrefix("onyx-provider-liveness:") else { return nil }
            return item
        }.first)
        XCTAssertEqual(failure.kind, .error)
        XCTAssertEqual(failure.status, .failed)
        XCTAssertEqual(failure.title, "Model stopped responding")
        XCTAssertTrue(failure.body.contains("Retry this response"))
        XCTAssertTrue(failure.body.contains("choose another model"))
        XCTAssertTrue(events.contains(.threadStatusChanged(threadID: "thread-1", status: .failed)))
        XCTAssertTrue(events.contains(.turnCompleted(threadID: "thread-1", status: .failed)))
        XCTAssertFalse(
            events.contains { event in
                guard case let .runtimeNotice(_, detail) = event else { return false }
                return detail.contains("stream") || detail.contains("SSE")
            },
            "Provider protocol jargon must stay out of the recovery surface"
        )
    }

    func testProgressRefreshesWatchdogAndNormalTerminalCancelsIt() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime()
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                // Keep the behavioral assertion comfortably above hosted
                // runner scheduling jitter. Production remains five minutes;
                // this test only needs enough room to prove a refresh.
                inactivityTimeout: .seconds(1)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        try await runtime.startTurn(Self.startTurnRequest)
        await upstream.emit(.turnStarted(threadID: "thread-1", turnID: "turn-healthy"))
        // Wait until the wrapper has actually observed the lifecycle event
        // before measuring the watchdog interval.  A busy CI runner can delay
        // AsyncStream delivery long enough for a fixed sleep to race the
        // intentionally tiny test timeout even though progress was emitted.
        try await waitUntil("The turn-start event was not observed") {
            await log.snapshot().contains(.turnStarted(threadID: "thread-1", turnID: "turn-healthy"))
        }
        await upstream.emit(.itemDelta(threadID: "thread-1", itemID: "answer", delta: "Still working"))
        try await waitUntil("The progress event was not observed") {
            await log.snapshot().contains(.itemDelta(threadID: "thread-1", itemID: "answer", delta: "Still working"))
        }
        try await Task.sleep(for: .milliseconds(650))

        let failedWhileProgressing = await log.containsLivenessFailure()
        XCTAssertFalse(failedWhileProgressing)

        await upstream.emit(.turnCompleted(threadID: "thread-1", status: .idle))
        try await waitUntil("The normal terminal event was not observed") {
            await log.snapshot().contains(.turnCompleted(threadID: "thread-1", status: .idle))
        }
        try await Task.sleep(for: .milliseconds(1_100))

        let completedEvents = await log.snapshot()
        XCTAssertFalse(completedEvents.contains { event in
            guard case let .itemCompleted(_, item) = event else { return false }
            return item.id.hasPrefix("onyx-provider-liveness:")
        })
        XCTAssertTrue(completedEvents.contains(
            .turnCompleted(threadID: "thread-1", status: .idle)
        ))
    }

    func testSynchronousTerminalBeforeStartTurnReturnsDoesNotArmFalseWatchdog() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            synchronousStartEvents: [
                .turnStarted(threadID: "thread-1", turnID: "turn-fast"),
                .turnCompleted(threadID: "thread-1", status: .idle),
            ]
        )
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .milliseconds(60)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        try await runtime.startTurn(Self.startTurnRequest)
        try await Task.sleep(for: .milliseconds(100))

        let synchronousEvents = await log.snapshot()
        XCTAssertFalse(synchronousEvents.contains { event in
            guard case let .itemCompleted(_, item) = event else { return false }
            return item.id.hasPrefix("onyx-provider-liveness:")
        })
    }

    func testEndedEventStreamFailsAcceptedTurnImmediately() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime()
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        try await runtime.startTurn(Self.startTurnRequest)
        await upstream.emit(.turnStarted(threadID: "thread-1", turnID: "turn-truncated"))
        await upstream.finishEvents()

        try await waitUntil("The ended event stream left the turn active") {
            await log.containsLivenessFailure()
        }
        let endedEvents = await log.snapshot()
        XCTAssertTrue(endedEvents.contains(
            .turnCompleted(threadID: "thread-1", status: .failed)
        ))
    }

    func testAcceptedTurnWithoutUpstreamTurnStartGetsSyntheticBoundaryBeforeFailure() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime()
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .milliseconds(60)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        try await runtime.startTurn(Self.startTurnRequest)

        try await waitUntil("The silent accepted turn never failed") {
            await log.containsLivenessFailure()
        }
        let events = await log.snapshot()
        let turnStartIndex = try XCTUnwrap(events.firstIndex { event in
            guard case let .turnStarted(threadID, turnID) = event else { return false }
            return threadID == "thread-1"
                && turnID.hasPrefix("onyx-provider-liveness-turn:")
        })
        let failureIndex = try XCTUnwrap(events.firstIndex { event in
            guard case let .itemCompleted(threadID, item) = event else { return false }
            return threadID == "thread-1"
                && item.id.hasPrefix("onyx-provider-liveness:")
        })
        XCTAssertLessThan(turnStartIndex, failureIndex)
        XCTAssertTrue(events.contains(
            .turnCompleted(threadID: "thread-1", status: .failed)
        ))
    }

    private static let startTurnRequest = StartTurnRequest(
        threadID: "thread-1",
        inputs: [.text("Do the work")],
        model: "generic-model",
        cwd: "/tmp",
        reasoningEffort: nil,
        sandboxMode: .workspaceWrite,
        approvalPolicy: .onRequest
    )

    private func collect(
        _ stream: AsyncStream<AgentRuntimeEvent>,
        into log: AgentTurnLivenessEventLog
    ) -> Task<Void, Never> {
        Task {
            for await event in stream {
                await log.append(event)
            }
        }
    }

    private func waitUntil(
        _ message: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

private actor AgentTurnLivenessEventLog {
    private(set) var events: [AgentRuntimeEvent] = []

    func append(_ event: AgentRuntimeEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentRuntimeEvent] {
        events
    }

    func containsLivenessFailure() -> Bool {
        events.contains { event in
            guard case let .itemCompleted(_, item) = event else { return false }
            return item.id.hasPrefix("onyx-provider-liveness:")
        }
    }
}

private actor AgentTurnLivenessFixtureRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind = .local
    nonisolated let events: AsyncStream<AgentRuntimeEvent>
    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let synchronousStartEvents: [AgentRuntimeEvent]

    init(synchronousStartEvents: [AgentRuntimeEvent] = []) {
        self.synchronousStartEvents = synchronousStartEvents
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func finishEvents() {
        eventContinuation.finish()
    }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
            runtime: .local,
            displayName: "Generic fixture",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming, .tools, .threadHistoryRevert]
        )
    }

    func disconnect() async {}
    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] { [] }
    func readThread(id _: String) async throws -> RuntimeConversation {
        throw AgentRuntimeError.unsupported("fixture history")
    }
    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        RuntimeThread(
            id: "thread-1",
            title: "Fixture",
            preview: "Fixture",
            cwd: request.cwd,
            updatedAt: .now,
            status: .idle,
            isPinned: false,
            runtime: .local,
            model: request.model,
            branch: nil
        )
    }
    func startTurn(_: StartTurnRequest) async throws {
        for event in synchronousStartEvents { eventContinuation.yield(event) }
        await Task.yield()
    }
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
}
