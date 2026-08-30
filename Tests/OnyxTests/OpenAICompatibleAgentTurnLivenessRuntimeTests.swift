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

    func testEventStreamEndingBeforeStartTurnReturnsStillFailsAcceptedTurn() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
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
        let start = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The start request never suspended") {
            await upstream.isStartSuspended(threadID: "thread-1")
        }
        await upstream.finishEvents()
        try await waitUntil("The wrapper never observed the ended event stream") {
            await runtime.hasObservedUpstreamEventStreamEndForTesting()
        }
        let finishedBeforeAdmissionSettled = await log.isFinished()
        XCTAssertFalse(finishedBeforeAdmissionSettled)

        await upstream.succeedStart(threadID: "thread-1")
        try await start.value

        try await waitUntil("An accepted turn was lost when its event stream ended") {
            await log.isFinished()
        }
        let events = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
        XCTAssertEqual(events.filter {
            $0 == .turnCompleted(threadID: "thread-1", status: .failed)
        }.count, 1)
    }

    func testEventStreamEndFailsActiveAndAcceptedPendingTurnsBeforeTermination() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-2"]
        )
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
        try await runtime.startTurn(Self.makeStartTurnRequest(threadID: "thread-1"))
        await upstream.emit(.turnStarted(threadID: "thread-1", turnID: "turn-active"))
        try await waitUntil("The active turn was not observed") {
            await log.snapshot().contains(
                .turnStarted(threadID: "thread-1", turnID: "turn-active")
            )
        }

        let pendingStart = startTurnTask(
            runtime,
            request: Self.makeStartTurnRequest(threadID: "thread-2")
        )
        try await waitUntil("The second start request never suspended") {
            await upstream.isStartSuspended(threadID: "thread-2")
        }
        await upstream.finishEvents()
        try await waitUntil("The active turn did not fail when its stream ended") {
            await log.livenessFailureCount(threadID: "thread-1") == 1
        }

        let pendingFailureCount = await log.livenessFailureCount(threadID: "thread-2")
        let connectionFailureCount = await log.terminalConnectionFailureCount()
        let finishedBeforeAdmissionSettled = await log.isFinished()
        XCTAssertEqual(pendingFailureCount, 0)
        XCTAssertEqual(connectionFailureCount, 0)
        XCTAssertFalse(finishedBeforeAdmissionSettled)

        await upstream.succeedStart(threadID: "thread-2")
        try await pendingStart.value
        try await waitUntil("The stream ended before every admission settled") {
            await log.isFinished()
        }

        let events = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 1)
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-2"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
        let pendingFailureIndex = try XCTUnwrap(events.firstIndex { event in
            guard case let .itemCompleted(threadID, item) = event else { return false }
            return threadID == "thread-2" && item.id.hasPrefix("onyx-provider-liveness:")
        })
        let connectionFailureIndex = try XCTUnwrap(events.firstIndex { event in
            guard case .connectionChanged(.failed) = event else { return false }
            return true
        })
        XCTAssertLessThan(pendingFailureIndex, connectionFailureIndex)
    }

    func testEventStreamWaitsForTwoAcceptedPendingAdmissionsAndFailsEachOnce() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1", "thread-2"]
        )
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
        let firstStart = startTurnTask(
            runtime,
            request: Self.makeStartTurnRequest(threadID: "thread-1")
        )
        let secondStart = startTurnTask(
            runtime,
            request: Self.makeStartTurnRequest(threadID: "thread-2")
        )
        try await waitUntil("Both start requests did not suspend") {
            await upstream.suspendedStartCount() == 2
        }
        await upstream.finishEvents()
        try await waitUntil("The wrapper never observed the ended event stream") {
            await runtime.hasObservedUpstreamEventStreamEndForTesting()
        }
        let finishedBeforeAdmissionsSettled = await log.isFinished()
        XCTAssertFalse(finishedBeforeAdmissionsSettled)

        await upstream.succeedStart(threadID: "thread-1")
        try await firstStart.value
        try await waitUntil("The first accepted admission did not fail") {
            await log.livenessFailureCount(threadID: "thread-1") == 1
        }
        let secondPendingFailureCount = await log.livenessFailureCount(threadID: "thread-2")
        let connectionFailureCount = await log.terminalConnectionFailureCount()
        let finishedBeforeSecondAdmissionSettled = await log.isFinished()
        XCTAssertEqual(secondPendingFailureCount, 0)
        XCTAssertEqual(connectionFailureCount, 0)
        XCTAssertFalse(finishedBeforeSecondAdmissionSettled)

        await upstream.succeedStart(threadID: "thread-2")
        try await secondStart.value
        try await waitUntil("The stream did not finish after both admissions settled") {
            await log.isFinished()
        }

        let events = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 1)
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-2"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
    }

    func testEventStreamWaitsForRejectedPendingAdmissionWithoutFalseFailure() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
        )
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
        let rejectedStart = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The rejected start request never suspended") {
            await upstream.isStartSuspended(threadID: "thread-1")
        }
        await upstream.finishEvents()
        try await waitUntil("The wrapper never observed the ended event stream") {
            await runtime.hasObservedUpstreamEventStreamEndForTesting()
        }
        let finishedBeforeAdmissionSettled = await log.isFinished()
        XCTAssertFalse(finishedBeforeAdmissionSettled)

        await upstream.rejectStart(threadID: "thread-1")
        do {
            try await rejectedStart.value
            XCTFail("The upstream rejection should remain authoritative")
        } catch let AgentRuntimeError.requestFailed(code, message) {
            XCTAssertEqual(code, 503)
            XCTAssertEqual(message, "Fixture rejected the start request")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await waitUntil("The stream did not finish after rejection settled") {
            await log.isFinished()
        }
        let events = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 0)
        // EOF retires the private lane even when the only in-flight request
        // is later rejected. The lane terminal is delayed until that
        // rejection settles, but it must still be emitted once so the
        // adaptive facade can replace the dead runtime.
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
        XCTAssertFalse(events.contains(
            .turnCompleted(threadID: "thread-1", status: .failed)
        ))
    }

    func testTerminalConnectionEventWaitsForPendingAdmissionAndIsForwardedOnce() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
        )
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10),
                admissionSettlementTimeout: .milliseconds(250)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        let start = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The start request never suspended") {
            await upstream.isStartSuspended(threadID: "thread-1")
        }

        await upstream.emit(.connectionChanged(.failed("upstream lane stopped")))
        try await waitUntil("The wrapper never entered terminal retirement") {
            await runtime.hasBegunRetirementForTesting()
        }
        let beforeAdmissionSettled = await log.snapshot()
        XCTAssertEqual(terminalConnectionFailureCount(in: beforeAdmissionSettled), 0)
        let finishedBeforeAdmissionSettled = await log.isFinished()
        XCTAssertFalse(finishedBeforeAdmissionSettled)

        await upstream.succeedStart(threadID: "thread-1")
        try await start.value
        try await waitUntil("The delayed terminal event never arrived") {
            await log.isFinished()
        }

        let events = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
        let failureIndex = try XCTUnwrap(events.firstIndex { event in
            guard case let .itemCompleted(threadID, item) = event else { return false }
            return threadID == "thread-1" && item.id.hasPrefix("onyx-provider-liveness:")
        })
        let terminalIndex = try XCTUnwrap(events.firstIndex { event in
            guard case let .connectionChanged(.failed(detail)) = event else { return false }
            return detail == "upstream lane stopped"
        })
        XCTAssertLessThan(failureIndex, terminalIndex)
    }

    func testNeverReturningAdmissionIsBoundedAfterUnexpectedEOF() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
        )
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10),
                admissionSettlementTimeout: .milliseconds(60)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        let start = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The start request never suspended") {
            await upstream.isStartSuspended(threadID: "thread-1")
        }
        await upstream.finishEvents()
        try await waitUntil("The wrapper never observed the ended event stream") {
            await runtime.hasObservedUpstreamEventStreamEndForTesting()
        }

        // The provider call is intentionally still suspended.  The wrapper
        // must retire its public stream on the bounded settlement deadline,
        // rather than waiting for this call forever.
        try await waitUntil(
            "A non-returning admission kept the wrapper stream alive",
            timeout: .seconds(1)
        ) {
            await log.isFinished()
        }
        let timedOutEvents = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: timedOutEvents, threadID: "thread-1"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: timedOutEvents), 1)

        // A late provider return is stale after the timeout and must not
        // publish a second failure or terminal connection event.
        await upstream.succeedStart(threadID: "thread-1")
        try await start.value
        try await Task.sleep(for: .milliseconds(100))
        let lateEvents = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: lateEvents, threadID: "thread-1"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: lateEvents), 1)
    }

    func testNeverReturningAdmissionIsBoundedWhileUpstreamStreamRemainsOpen() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
        )
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10),
                admissionSettlementTimeout: .milliseconds(60)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        let start = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The start request never suspended") {
            await upstream.isStartSuspended(threadID: "thread-1")
        }

        // No EOF or lifecycle signal arrives. The admission watchdog itself
        // must fence the lane and close the public stream.
        try await waitUntil(
            "A live stream let a never-returning admission hang forever",
            timeout: .seconds(1)
        ) {
            await log.isFinished()
        }
        let timedOutEvents = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: timedOutEvents, threadID: "thread-1"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: timedOutEvents), 1)

        await upstream.succeedStart(threadID: "thread-1")
        try await start.value
        try await Task.sleep(for: .milliseconds(100))
        let lateEvents = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: lateEvents, threadID: "thread-1"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: lateEvents), 1)
    }

    func testConcurrentSameThreadAdmissionsRemainTokenScoped() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
        )
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10),
                admissionSettlementTimeout: .milliseconds(250)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        // Suspend the first call before launching the second so the fixture's
        // FIFO continuation order gives us deterministic accepted/rejected
        // outcomes for two admissions sharing one thread ID.
        let first = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The first start request never suspended") {
            await upstream.suspendedStartCount() == 1
        }
        let second = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The second start request never suspended") {
            await upstream.suspendedStartCount() == 2
        }
        await upstream.finishEvents()
        try await waitUntil("The wrapper never entered terminal retirement") {
            await runtime.hasObservedUpstreamEventStreamEndForTesting()
        }

        await upstream.succeedStart(threadID: "thread-1")
        try await first.value
        await upstream.rejectStart(threadID: "thread-1")
        do {
            try await second.value
            XCTFail("The second admission should retain the upstream rejection")
        } catch let AgentRuntimeError.requestFailed(code, message) {
            XCTAssertEqual(code, 503)
            XCTAssertEqual(message, "Fixture rejected the start request")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try await waitUntil("The stream did not finish after both same-thread admissions settled") {
            await log.isFinished()
        }
        let events = await log.snapshot()
        // The first accepted request gets the single task-scoped failure;
        // the rejected second request must neither overwrite it nor add a
        // false failure of its own.
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
    }

    func testConcurrentSameThreadAcceptedAdmissionsEachReceiveOneFailure() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
        )
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10),
                admissionSettlementTimeout: .milliseconds(250)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        let first = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The first start request never suspended") {
            await upstream.suspendedStartCount() == 1
        }
        let second = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The second start request never suspended") {
            await upstream.suspendedStartCount() == 2
        }
        await upstream.finishEvents()
        try await waitUntil("The wrapper never entered terminal retirement") {
            await runtime.hasObservedUpstreamEventStreamEndForTesting()
        }

        await upstream.succeedStart(threadID: "thread-1")
        try await first.value
        await upstream.succeedStart(threadID: "thread-1")
        try await second.value
        try await waitUntil("The stream did not finish after both accepted admissions settled") {
            await log.isFinished()
        }

        let events = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 2)
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
        let failureIDs = events.compactMap { event -> String? in
            guard case let .itemCompleted(threadID, item) = event,
                  threadID == "thread-1",
                  item.id.hasPrefix("onyx-provider-liveness:") else { return nil }
            return item.id
        }
        XCTAssertEqual(Set(failureIDs).count, 2)
    }

    func testCompletedTurnDoesNotConsumeLaterAdmission() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime()
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10),
                admissionSettlementTimeout: .milliseconds(250)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        // Establish and finish one accepted turn before admitting the second
        // request. Its removed admission token must not be used as a reason
        // to mark any later request terminal.
        try await runtime.startTurn(Self.startTurnRequest)
        await upstream.emit(.turnStarted(threadID: "thread-1", turnID: "first-turn"))
        try await waitUntil("The first turn was not observed") {
            await log.snapshot().contains(
                .turnStarted(threadID: "thread-1", turnID: "first-turn")
            )
        }
        await upstream.emit(.turnCompleted(threadID: "thread-1", status: .idle))
        try await waitUntil("The first turn did not complete") {
            await log.snapshot().contains(
                .turnCompleted(threadID: "thread-1", status: .idle)
            )
        }
        let second = startTurnTask(
            runtime,
            request: Self.makeStartTurnRequest(threadID: "thread-2")
        )
        try await second.value
        await upstream.emit(.turnStarted(threadID: "thread-2", turnID: "second-turn"))
        try await waitUntil("The second turn was not observed") {
            await log.snapshot().contains(
                .turnStarted(threadID: "thread-2", turnID: "second-turn")
            )
        }
        await upstream.finishEvents()
        try await waitUntil("The wrapper never observed the ended event stream") {
            await runtime.hasObservedUpstreamEventStreamEndForTesting()
        }
        try await waitUntil("The second turn did not fail after EOF") {
            await log.livenessFailureCount(threadID: "thread-2") == 1
        }
        try await waitUntil("The stream did not finish after the active turn failed") {
            await log.isFinished()
        }

        let events = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-1"), 0)
        XCTAssertEqual(livenessFailureCount(in: events, threadID: "thread-2"), 1)
        XCTAssertEqual(terminalConnectionFailureCount(in: events), 1)
    }

    func testExplicitDisconnectDoesNotSynthesizeTaskFailureForPendingAdmission() async throws {
        let upstream = AgentTurnLivenessFixtureRuntime(
            suspendedStartThreadIDs: ["thread-1"]
        )
        let runtime = OpenAICompatibleAgentTurnLivenessRuntime(
            runtime: upstream,
            policy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .milliseconds(60),
                admissionSettlementTimeout: .milliseconds(60)
            )
        )
        let log = AgentTurnLivenessEventLog()
        let collector = collect(runtime.events, into: log)
        defer { collector.cancel() }

        _ = try await runtime.connect()
        let start = startTurnTask(runtime, request: Self.startTurnRequest)
        try await waitUntil("The start request never suspended") {
            await upstream.isStartSuspended(threadID: "thread-1")
        }

        await runtime.disconnect()
        try await waitUntil("Explicit disconnect did not finish the wrapper stream") {
            await log.isFinished()
        }
        let disconnectedEvents = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: disconnectedEvents, threadID: "thread-1"), 0)
        XCTAssertEqual(terminalConnectionFailureCount(in: disconnectedEvents), 0)

        // Complete the fixture continuation so the suspended caller can
        // unwind; the wrapper has already discarded this stale admission.
        await upstream.succeedStart(threadID: "thread-1")
        try await start.value
        try await Task.sleep(for: .milliseconds(100))
        let lateEvents = await log.snapshot()
        XCTAssertEqual(livenessFailureCount(in: lateEvents, threadID: "thread-1"), 0)
        XCTAssertEqual(terminalConnectionFailureCount(in: lateEvents), 0)
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

    private static func makeStartTurnRequest(threadID: String) -> StartTurnRequest {
        StartTurnRequest(
            threadID: threadID,
            inputs: [.text("Do the work")],
            model: "generic-model",
            cwd: "/tmp",
            reasoningEffort: nil,
            sandboxMode: .workspaceWrite,
            approvalPolicy: .onRequest
        )
    }

    private func livenessFailureCount(
        in events: [AgentRuntimeEvent],
        threadID: String
    ) -> Int {
        events.filter { event in
            guard case let .itemCompleted(eventThreadID, item) = event else { return false }
            return eventThreadID == threadID
                && item.id.hasPrefix("onyx-provider-liveness:")
        }.count
    }

    private func terminalConnectionFailureCount(in events: [AgentRuntimeEvent]) -> Int {
        events.filter { event in
            guard case .connectionChanged(.failed) = event else { return false }
            return true
        }.count
    }

    private func collect(
        _ stream: AsyncStream<AgentRuntimeEvent>,
        into log: AgentTurnLivenessEventLog
    ) -> Task<Void, Never> {
        Task {
            for await event in stream {
                await log.append(event)
            }
            await log.markFinished()
        }
    }

    private nonisolated func startTurnTask(
        _ runtime: OpenAICompatibleAgentTurnLivenessRuntime,
        request: StartTurnRequest
    ) -> Task<Void, any Error> {
        Task { try await runtime.startTurn(request) }
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
    private var finished = false

    func append(_ event: AgentRuntimeEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentRuntimeEvent] {
        events
    }

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }

    func containsLivenessFailure() -> Bool {
        events.contains { event in
            guard case let .itemCompleted(_, item) = event else { return false }
            return item.id.hasPrefix("onyx-provider-liveness:")
        }
    }

    func livenessFailureCount(threadID: String) -> Int {
        events.filter { event in
            guard case let .itemCompleted(eventThreadID, item) = event else { return false }
            return eventThreadID == threadID
                && item.id.hasPrefix("onyx-provider-liveness:")
        }.count
    }

    func terminalConnectionFailureCount() -> Int {
        events.filter { event in
            guard case .connectionChanged(.failed) = event else { return false }
            return true
        }.count
    }
}

private actor AgentTurnLivenessFixtureRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind = .local
    nonisolated let events: AsyncStream<AgentRuntimeEvent>
    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let synchronousStartEvents: [AgentRuntimeEvent]
    private let suspendedStartThreadIDs: Set<String>
    private var suspendedStarts: [String: [CheckedContinuation<Void, any Error>]] = [:]

    init(
        synchronousStartEvents: [AgentRuntimeEvent] = [],
        suspendedStartThreadIDs: Set<String> = []
    ) {
        self.synchronousStartEvents = synchronousStartEvents
        self.suspendedStartThreadIDs = suspendedStartThreadIDs
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

    func isStartSuspended(threadID: String) -> Bool {
        !(suspendedStarts[threadID]?.isEmpty ?? true)
    }

    func suspendedStartCount() -> Int {
        suspendedStarts.values.reduce(into: 0) { count, continuations in
            count += continuations.count
        }
    }

    func succeedStart(threadID: String) {
        guard var continuations = suspendedStarts[threadID], !continuations.isEmpty else {
            return
        }
        let continuation = continuations.removeFirst()
        if continuations.isEmpty {
            suspendedStarts[threadID] = nil
        } else {
            suspendedStarts[threadID] = continuations
        }
        continuation.resume(returning: ())
    }

    func rejectStart(threadID: String) {
        guard var continuations = suspendedStarts[threadID], !continuations.isEmpty else {
            return
        }
        let continuation = continuations.removeFirst()
        if continuations.isEmpty {
            suspendedStarts[threadID] = nil
        } else {
            suspendedStarts[threadID] = continuations
        }
        continuation.resume(
            throwing: AgentRuntimeError.requestFailed(
                code: 503,
                message: "Fixture rejected the start request"
            )
        )
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
    func startTurn(_ request: StartTurnRequest) async throws {
        for event in synchronousStartEvents { eventContinuation.yield(event) }
        if suspendedStartThreadIDs.contains(request.threadID) {
            try await withCheckedThrowingContinuation { continuation in
                suspendedStarts[request.threadID, default: []].append(continuation)
            }
        }
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
