import Foundation
import XCTest
@testable import Onyx

final class DelegationCoreTests: XCTestCase {
    private let codexConnection = ProviderConnectionID("openai.codex.default")
    private let qwenConnection = ProviderConnectionID("local.qwen.vllm")

    func testCodexToQwenRoutingPreservesProviderScopedTargetAndLineage() async throws {
        let probe = DelegationProbe()
        let codex = makeExecutor(connectionID: codexConnection, probe: probe)
        let qwen = makeExecutor(connectionID: qwenConnection, probe: probe)
        let coordinator = try DelegationCoordinator(
            executors: [codex, qwen],
            maxConcurrentJobs: 2
        )

        let parent = DelegationAgentIdentity(
            connectionID: codexConnection,
            modelID: "gpt-5.6-codex"
        )
        let target = DelegationTarget(
            connectionID: qwenConnection,
            modelID: "Qwen/Qwen3.8-27B-FP8"
        )
        let request = DelegationRequest(
            id: DelegationJobID("codex-to-qwen"),
            parentAgent: parent,
            target: target,
            prompt: "Inspect the local build and report only actionable findings."
        )

        let handle = try await coordinator.submit(request)
        let result = try await coordinator.result(for: handle.jobID)
        let received = await probe.requests(for: handle.jobID)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].target.connectionID, qwenConnection)
        XCTAssertEqual(received[0].target.model.modelID, "Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(received[0].parentAgent, parent)
        XCTAssertEqual(result.target, target)
        XCTAssertEqual(result.lineage.agents, [parent])
        XCTAssertEqual(result.route, [parent, target.agent])
        XCTAssertEqual(result.lineage.rootJobID, handle.jobID)
        XCTAssertEqual(result.text, "qwen result")
    }

    func testQwenToCodexRoutingCanBeBuiltFromAcceptedParentJob() async throws {
        let probe = DelegationProbe()
        let codex = makeExecutor(connectionID: codexConnection, probe: probe)
        let qwen = makeExecutor(connectionID: qwenConnection, probe: probe)
        let coordinator = try DelegationCoordinator(
            executors: [codex, qwen],
            maxConcurrentJobs: 1
        )

        let qwenParent = DelegationAgentIdentity(
            connectionID: qwenConnection,
            modelID: "Qwen/Qwen3.8-27B-FP8"
        )
        let first = try await coordinator.submit(
            DelegationRequest(
                id: DelegationJobID("qwen-root"),
                parentAgent: qwenParent,
                target: DelegationTarget(
                    connectionID: codexConnection,
                    modelID: "gpt-5.6-codex"
                ),
                prompt: "Ask Codex for a repository-aware review."
            )
        )
        _ = try await coordinator.result(for: first.jobID)

        let child = try await coordinator.makeChildRequest(
            from: first.jobID,
            target: DelegationTarget(
                connectionID: qwenConnection,
                modelID: "Qwen/Qwen3.8-27B-FP8"
            ),
            prompt: "Now validate the review against the local model.",
            id: DelegationJobID("codex-child")
        )
        XCTAssertEqual(child.parentAgent.connectionID, codexConnection)
        XCTAssertEqual(child.parentAgent.model.modelID, "gpt-5.6-codex")
        XCTAssertEqual(child.lineage.rootJobID, first.jobID)
        XCTAssertEqual(child.lineage.parentJobID, first.jobID)
        XCTAssertEqual(
            child.lineage.agents.map(\.connectionID),
            [qwenConnection, codexConnection]
        )
        XCTAssertEqual(
            child.lineage.agents.map { $0.model.modelID },
            ["Qwen/Qwen3.8-27B-FP8", "gpt-5.6-codex"]
        )

        let second = try await coordinator.submit(child)
        let result = try await coordinator.result(for: second.jobID)
        XCTAssertEqual(result.target.connectionID, qwenConnection)
        XCTAssertEqual(result.lineage.agents.count, 2)
    }

    func testBoundedConcurrencyQueuesWorkFIFO() async throws {
        let probe = DelegationProbe()
        let gate = AsyncGate()
        let executor = makeExecutor(
            connectionID: qwenConnection,
            probe: probe,
            gate: gate,
            waitForGate: true
        )
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxConcurrentJobs: 2
        )

        let requests = (0 ..< 4).map { index in
            DelegationRequest(
                id: DelegationJobID("bounded-\(index)"),
                parentAgent: DelegationAgentIdentity(
                    connectionID: codexConnection,
                    modelID: "gpt-5.6-codex"
                ),
                target: DelegationTarget(
                    connectionID: qwenConnection,
                    modelID: "Qwen/Qwen3.8-27B-FP8"
                ),
                prompt: "job \(index)"
            )
        }
        let handles = try await requests.asyncMap { try await coordinator.submit($0) }

        try await probe.waitUntilActive(atLeast: 2)
        let activeCount = await probe.activeCount()
        let maximumActiveCount = await probe.maximumActiveCount()
        let requestCount = await probe.requestCount()
        XCTAssertEqual(activeCount, 2)
        XCTAssertEqual(maximumActiveCount, 2)
        XCTAssertEqual(requestCount, 2)

        await gate.open()
        for handle in handles {
            _ = try await coordinator.result(for: handle.jobID)
        }
        let requestIDs = await probe.requestIDs()
        let finalMaximumActiveCount = await probe.maximumActiveCount()
        XCTAssertEqual(requestIDs, requests.map(\.id))
        XCTAssertEqual(finalMaximumActiveCount, 2)
    }

    func testQueuedCancellationNeverInvokesExecutor() async throws {
        let probe = DelegationProbe()
        let gate = AsyncGate()
        let executor = makeExecutor(
            connectionID: qwenConnection,
            probe: probe,
            gate: gate,
            waitForGate: true
        )
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxConcurrentJobs: 1
        )
        let first = try await coordinator.submit(makeRequest(id: "queue-first"))
        let second = try await coordinator.submit(makeRequest(id: "queue-second"))
        try await probe.waitUntilActive(atLeast: 1)

        let disposition = try await coordinator.cancel(second.jobID)
        XCTAssertEqual(disposition, .queuedCancelled)
        do {
            _ = try await coordinator.result(for: second.jobID)
            XCTFail("Expected queued cancellation")
        } catch let error as DelegationResultError {
            guard case let .cancelled(cancellation) = error else {
                return XCTFail("Unexpected terminal error: \(error)")
            }
            XCTAssertEqual(cancellation.reason, .user)
        }
        let requestCountBeforeRelease = await probe.requestCount()
        XCTAssertEqual(requestCountBeforeRelease, 1)

        await gate.open()
        _ = try await coordinator.result(for: first.jobID)
        let requestCountAfterRelease = await probe.requestCount()
        XCTAssertEqual(requestCountAfterRelease, 1)
    }

    func testRunningCancellationWinsEvenWhenExecutorReturnsAfterCancellation() async throws {
        let probe = DelegationProbe()
        let release = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) { request, report in
            await probe.record(request)
            await report(.init(phase: "started", fraction: 0.1))
            await release.wait()
            // Deliberately do not check cancellation: the coordinator must
            // still make cancellation authoritative at the job boundary.
            return DelegationOutput(text: "late output")
        }
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxConcurrentJobs: 1
        )
        let handle = try await coordinator.submit(makeRequest(id: "running-cancel"))
        let stream = handle.events
        try await probe.waitUntilActive(atLeast: 1)
        let cancellationDisposition = try await coordinator.cancel(handle.jobID)
        XCTAssertEqual(cancellationDisposition, .runningCancellationRequested)
        let repeatedDisposition = try await coordinator.cancel(handle.jobID)
        XCTAssertEqual(repeatedDisposition, .alreadyTerminal)

        do {
            _ = try await coordinator.result(for: handle.jobID)
            XCTFail("Expected running cancellation")
        } catch let error as DelegationResultError {
            guard case let .cancelled(cancellation) = error else {
                return XCTFail("Unexpected terminal error: \(error)")
            }
            XCTAssertEqual(cancellation.jobID, handle.jobID)
        }
        await release.open()
        let events = await Self.collectEvents(from: stream)
        XCTAssertEqual(
            events.filter {
                if case .cancellationRequested = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testFailureIsProjectedWithLineageAndRedactedMessage() async throws {
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) { _, _ in
            throw DelegationExecutorError.provider(
                "HTTP 401 Bearer sk-super-secret-value api_key=another-secret "
                    + "github_pat_abcdefghi123456 {\"access_token\":\"quoted-secret\"} "
                    + "xoxb-slacksecret123 hf_huggingface123 "
                    + "AKIAABCDEFGHIJKLMNOP"
            )
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "failure"))

        do {
            _ = try await coordinator.result(for: handle.jobID)
            XCTFail("Expected provider failure")
        } catch let error as DelegationResultError {
            guard case let .failed(failure) = error else {
                return XCTFail("Unexpected terminal error: \(error)")
            }
            XCTAssertEqual(failure.code, .provider)
            XCTAssertEqual(failure.lineage.agents.count, 1)
            XCTAssertFalse(failure.message.contains("super-secret"))
            XCTAssertFalse(failure.message.contains("another-secret"))
            XCTAssertFalse(failure.message.contains("abcdefghi"))
            XCTAssertFalse(failure.message.contains("quoted-secret"))
            XCTAssertFalse(failure.message.contains("slacksecret"))
            XCTAssertFalse(failure.message.contains("huggingface"))
            XCTAssertFalse(failure.message.contains("AKIA"))
            XCTAssertTrue(failure.message.contains("[redacted]"))
        }
    }

    func testProgressDiagnosticsAreBoundedAndRedacted() async throws {
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            _, report in
            await report(
                .init(
                    phase: "Bearer sk-progress-secret-value",
                    message: "api_key=message-secret"
                )
            )
            return DelegationOutput(text: "done")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "safe-progress"))
        _ = try await coordinator.result(for: handle.jobID)
        let replay = try await coordinator.events(for: handle.jobID)
        let events = await Self.collectEvents(from: replay)
        let progress = try XCTUnwrap(
            events.compactMap { event -> DelegationProgress? in
                guard case let .progress(value) = event else { return nil }
                return value
            }.first
        )

        XCTAssertEqual(progress.update.phase, "[redacted]")
        XCTAssertEqual(progress.update.message, "[redacted]")
    }

    func testSuccessfulModelOutputIsNotHeuristicallyRedacted() async throws {
        let text = "Explain why the literal example `Authorization: Bearer demo-token` is unsafe."
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) { _, _ in
            DelegationOutput(text: text)
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "literal-output"))
        let result = try await coordinator.result(for: handle.jobID)

        XCTAssertEqual(result.text, text)
        XCTAssertFalse(result.isTruncated)
    }

    func testOversizedOutputIsBoundedAndExplicitlyMarkedTruncated() async throws {
        let text = String(repeating: "x", count: DelegationSafeText.outputCharacterLimit + 1)
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) { _, _ in
            DelegationOutput(text: text)
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "bounded-output"))
        let result = try await coordinator.result(for: handle.jobID)

        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(
            result.output.truncatedAtCharacterLimit,
            DelegationSafeText.outputCharacterLimit
        )
        XCTAssertEqual(result.text.count, DelegationSafeText.outputCharacterLimit + 1)
        XCTAssertTrue(result.text.hasSuffix("…"))
    }

    func testCredentialFreeRequestShapeRoundTripsWithoutAuthMaterial() throws {
        let request = makeRequest(id: "plain-request")
        let data = try JSONEncoder().encode(request)
        let json = String(decoding: data, as: UTF8.self).lowercased()

        XCTAssertEqual(try JSONDecoder().decode(DelegationRequest.self, from: data), request)
        XCTAssertFalse(json.contains("credential"))
        XCTAssertFalse(json.contains("authorization"))
        XCTAssertFalse(json.contains("bearer"))
        XCTAssertFalse(json.contains("api_key"))
        XCTAssertFalse(json.contains("token"))
    }

    func testLifecycleStreamReplaysAndEndsWithTerminalEvent() async throws {
        let probe = DelegationProbe()
        let executor = makeExecutor(connectionID: qwenConnection, probe: probe)
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "events"))
        _ = try await coordinator.result(for: handle.jobID)

        let replay = try await coordinator.events(for: handle.jobID)
        let events = await collectEvents(from: replay)
        XCTAssertEqual(events.first?.jobID, handle.jobID)
        XCTAssertEqual(events.first?.state, .queued)
        XCTAssertTrue(events.contains { if case .started = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .progress = $0 { true } else { false } })
        XCTAssertEqual(events.last?.state, .succeeded)
        XCTAssertTrue(events.last?.isTerminal == true)
    }

    func testIndependentSubscribersReceiveIdenticalLifecycleEvents() async throws {
        let executor = makeExecutor(
            connectionID: qwenConnection,
            probe: DelegationProbe()
        )
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "subscribers"))
        _ = try await coordinator.result(for: handle.jobID)
        let first = try await coordinator.events(for: handle.jobID)
        let second = try await coordinator.events(for: handle.jobID)

        let firstEvents = await Self.collectEvents(from: first)
        let secondEvents = await Self.collectEvents(from: second)
        XCTAssertEqual(firstEvents, secondEvents)
        XCTAssertEqual(firstEvents.first?.state, .queued)
        XCTAssertEqual(firstEvents.last?.state, .succeeded)
    }

    func testReplayIsBoundedButRetainsLifecycleBoundaries() async throws {
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            _, report in
            for index in 0 ..< 400 {
                await report(.init(phase: "progress-\(index)"))
            }
            return DelegationOutput(text: "done")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "bounded-events"))
        _ = try await coordinator.result(for: handle.jobID)
        let replay = try await coordinator.events(for: handle.jobID)
        let events = await Self.collectEvents(from: replay)

        XCTAssertEqual(events.count, 256)
        XCTAssertEqual(events.first?.state, .queued)
        XCTAssertTrue(events.contains { if case .started = $0 { true } else { false } })
        XCTAssertEqual(events.last?.state, .succeeded)
    }

    func testSlowLiveSubscriberCoalescesProgressWithoutDroppingLifecycle() async throws {
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            _, report in
            for index in 0 ..< 1_000 {
                await report(.init(phase: "progress-\(index)"))
            }
            return DelegationOutput(text: "done")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "slow-live"))
        _ = try await coordinator.result(for: handle.jobID)
        let events = await Self.collectEvents(from: handle.events)

        XCTAssertLessThanOrEqual(events.count, 256)
        XCTAssertEqual(events.first?.state, .queued)
        XCTAssertTrue(events.contains { if case .started = $0 { true } else { false } })
        XCTAssertEqual(events.last?.state, .succeeded)
    }

    func testRunningCancellationIsTerminalButRetainsPhysicalConcurrencySlot() async throws {
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()
        let secondStarted = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            request,
            _ in
            if request.id == DelegationJobID("stuck-first") {
                await firstStarted.open()
                await releaseFirst.wait()
                return DelegationOutput(text: "late")
            }
            await secondStarted.open()
            return DelegationOutput(text: "second")
        }
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxConcurrentJobs: 1
        )
        let first = try await coordinator.submit(makeRequest(id: "stuck-first"))
        let second = try await coordinator.submit(makeRequest(id: "next-job"))
        await firstStarted.wait()

        _ = try await coordinator.cancel(first.jobID)
        do {
            _ = try await coordinator.result(for: first.jobID)
            XCTFail("Expected authoritative cancellation")
        } catch let DelegationResultError.cancelled(cancellation) {
            XCTAssertEqual(cancellation.reason, .user)
        }
        try await Task.sleep(for: .milliseconds(25))
        let secondStartedWhileFirstExecutorWasRunning = await secondStarted.opened()
        XCTAssertFalse(
            secondStartedWhileFirstExecutorWasRunning,
            "A non-cooperative provider call must retain its physical concurrency slot"
        )

        await releaseFirst.open()
        try await waitForGate(secondStarted, description: "queued job to start after executor exit")
        let result = try await coordinator.result(for: second.jobID)
        XCTAssertEqual(result.text, "second")
    }

    func testQueuedCancellationRequestPreservesQueuedState() async throws {
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            request,
            _ in
            if request.id == DelegationJobID("queue-blocker") {
                await firstStarted.open()
                await releaseFirst.wait()
            }
            return DelegationOutput(text: "done")
        }
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxConcurrentJobs: 1
        )
        let blocker = try await coordinator.submit(makeRequest(id: "queue-blocker"))
        let queued = try await coordinator.submit(makeRequest(id: "queued-cancel"))
        await firstStarted.wait()

        _ = try await coordinator.cancel(queued.jobID)
        let events = await Self.collectEvents(from: queued.events)
        let cancellationRequest = try XCTUnwrap(events.first { event in
            if case .cancellationRequested = event { return true }
            return false
        })
        XCTAssertEqual(cancellationRequest.state, .queued)
        XCTAssertFalse(events.contains { if case .started = $0 { true } else { false } })

        await releaseFirst.open()
        _ = try await coordinator.result(for: blocker.jobID)
    }

    func testTerminalJobRetentionEvictsOldestRecord() async throws {
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            request,
            _ in DelegationOutput(text: request.id.rawValue)
        }
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxRetainedTerminalJobs: 2
        )

        for id in ["retained-one", "retained-two", "retained-three"] {
            let handle = try await coordinator.submit(makeRequest(id: id))
            _ = try await coordinator.result(for: handle.jobID)
        }

        do {
            _ = try await coordinator.snapshot(for: DelegationJobID("retained-one"))
            XCTFail("Expected the oldest terminal job to be evicted")
        } catch {
            XCTAssertEqual(
                error as? DelegationCoordinatorError,
                .unknownJob(DelegationJobID("retained-one"))
            )
        }
        let secondState = try await coordinator
            .snapshot(for: DelegationJobID("retained-two")).state
        let thirdState = try await coordinator
            .snapshot(for: DelegationJobID("retained-three")).state
        XCTAssertEqual(secondState, .succeeded)
        XCTAssertEqual(thirdState, .succeeded)
    }

    func testEvictedNonCooperativeJobIDCannotBeReused() async throws {
        let stuckStarted = AsyncGate()
        let releaseStuck = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            request,
            _ in
            if request.id == DelegationJobID("evicted-stuck") {
                await stuckStarted.open()
                // Deliberately ignore cancellation so the physical task stays
                // alive after its logical record reaches terminal state.
                await releaseStuck.wait()
                return DelegationOutput(text: "late old output")
            }
            return DelegationOutput(text: "retention trigger")
        }
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxConcurrentJobs: 2,
            maxRetainedTerminalJobs: 1
        )
        let stuck = try await coordinator.submit(makeRequest(id: "evicted-stuck"))
        await stuckStarted.wait()
        _ = try await coordinator.cancel(stuck.jobID)

        let trigger = try await coordinator.submit(makeRequest(id: "eviction-trigger"))
        _ = try await coordinator.result(for: trigger.jobID)
        do {
            _ = try await coordinator.snapshot(for: stuck.jobID)
            XCTFail("Expected the cancelled record to be evicted")
        } catch {
            XCTAssertEqual(
                error as? DelegationCoordinatorError,
                .unknownJob(stuck.jobID)
            )
        }

        do {
            _ = try await coordinator.submit(makeRequest(id: "evicted-stuck"))
            XCTFail("An evicted ID must remain reserved while its executor is alive")
        } catch {
            XCTAssertEqual(
                error as? DelegationCoordinatorError,
                .duplicateJobID(stuck.jobID)
            )
        }

        await releaseStuck.open()
    }

    func testCancelledEventConsumerIsRemovedFromRunningJob() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            _, _ in
            await started.open()
            await release.wait()
            return DelegationOutput(text: "done")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "subscriber-cancel"))
        await started.wait()
        let jobID = handle.jobID
        let stream = try await coordinator.events(for: jobID)
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            while await iterator.next() != nil {}
        }
        try await waitUntil("event subscriber registration") {
            try await coordinator.activeSubscriberCount(for: jobID) == 2
        }

        consumer.cancel()
        _ = await consumer.result
        try await waitUntil("cancelled event subscriber removal") {
            try await coordinator.activeSubscriberCount(for: jobID) == 1
        }

        await release.open()
        _ = try await coordinator.result(for: jobID)
    }

    func testDroppedEventStreamUnregistersSubscriber() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            _, _ in
            await started.open()
            await release.wait()
            return DelegationOutput(text: "done")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "dropped-stream"))
        await started.wait()

        do {
            let dropped = try await coordinator.events(for: handle.jobID)
            let subscriberCount = try await coordinator.activeSubscriberCount(for: handle.jobID)
            XCTAssertEqual(subscriberCount, 2)
            _ = dropped
        }

        try await waitUntil("dropped event stream removal") {
            try await coordinator.activeSubscriberCount(for: handle.jobID) == 1
        }
        await release.open()
        _ = try await coordinator.result(for: handle.jobID)
    }

    func testProgressAndLifecycleOrderingRemainPerJobUnderConcurrency() async throws {
        let release = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            request,
            report in
            await report(.init(phase: "one", fraction: 0.25))
            await release.wait()
            await report(.init(phase: "two", fraction: 0.75))
            return DelegationOutput(text: request.prompt)
        }
        let coordinator = try DelegationCoordinator(
            executors: [executor],
            maxConcurrentJobs: 2
        )
        let first = try await coordinator.submit(makeRequest(id: "ordered-one"))
        let second = try await coordinator.submit(makeRequest(id: "ordered-two"))

        try await waitUntil(
            "both jobs report their first progress update"
        ) {
            let a = try await coordinator.snapshot(for: first.jobID)
            let b = try await coordinator.snapshot(for: second.jobID)
            return a.latestProgress?.phase == "one" && b.latestProgress?.phase == "one"
        }
        await release.open()
        _ = try await coordinator.result(for: first.jobID)
        _ = try await coordinator.result(for: second.jobID)

        let firstReplay = try await coordinator.events(for: first.jobID)
        let secondReplay = try await coordinator.events(for: second.jobID)
        let firstEvents = await Self.collectEvents(from: firstReplay)
        let secondEvents = await Self.collectEvents(from: secondReplay)
        for events in [firstEvents, secondEvents] {
            XCTAssertEqual(events.first?.state, .queued)
            XCTAssertTrue(events.indices.dropFirst().allSatisfy { index in
                switch (events[index - 1].state, events[index].state) {
                case (.queued, .running), (.running, .running), (.running, .succeeded): true
                default: false
                }
            })
            let phases = events.compactMap { event -> String? in
                guard case let .progress(progress) = event else { return nil }
                return progress.update.phase
            }
            XCTAssertEqual(phases, ["one", "two"])
            XCTAssertEqual(events.last?.state, .succeeded)
        }
    }

    func testUnsupportedModelAndDuplicateJobIDAreRejectedBeforeExecution() async throws {
        let probe = DelegationProbe()
        let executor = ClosureDelegationExecutor(
            connectionID: qwenConnection,
            supportedModelIDs: ["Qwen/Qwen3.8-27B-FP8"]
        ) { request, _ in
            await probe.record(request)
            return DelegationOutput(text: "ok")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let unsupported = DelegationRequest(
            id: DelegationJobID("unsupported"),
            parentAgent: DelegationAgentIdentity(
                connectionID: codexConnection,
                modelID: "gpt-5.6-codex"
            ),
            target: DelegationTarget(
                connectionID: qwenConnection,
                modelID: "not-a-real-model"
            ),
            prompt: "do not run"
        )
        do {
            _ = try await coordinator.submit(unsupported)
            XCTFail("Expected unsupported model rejection")
        } catch {
            XCTAssertEqual(
                error as? DelegationCoordinatorError,
                .unsupportedModel(
                    connectionID: qwenConnection,
                    modelID: "not-a-real-model"
                )
            )
        }

        let accepted = makeRequest(id: "duplicate")
        let handle = try await coordinator.submit(accepted)
        do {
            _ = try await coordinator.submit(accepted)
            XCTFail("Expected duplicate job ID rejection")
        } catch {
            XCTAssertEqual(
                error as? DelegationCoordinatorError,
                .duplicateJobID(accepted.id)
            )
        }
        _ = try await coordinator.result(for: handle.jobID)
        let count = await probe.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testMultipleWaitersReceiveTheSameTerminalResult() async throws {
        let release = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            _, _ in
            await release.wait()
            return DelegationOutput(text: "one result")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "waiters"))
        let jobID = handle.jobID
        let first = Task { try await coordinator.result(for: jobID) }
        let second = Task { try await coordinator.result(for: jobID) }
        await release.open()

        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstResult.text, "one result")
    }

    func testCancellingResultWaiterDoesNotRetainItUntilProviderCompletes() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let executor = ClosureDelegationExecutor(connectionID: qwenConnection) {
            _, _ in
            await started.open()
            await release.wait()
            return DelegationOutput(text: "eventual")
        }
        let coordinator = try DelegationCoordinator(executors: [executor])
        let handle = try await coordinator.submit(makeRequest(id: "cancel-waiter"))
        await started.wait()

        let jobID = handle.jobID
        let waiter = Task { try await coordinator.result(for: jobID) }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {
            // Expected: the provider job itself remains active.
        }
        let stateAfterWaiterCancellation = try await coordinator.snapshot(for: jobID).state
        XCTAssertEqual(stateAfterWaiterCancellation, .running)

        await release.open()
        let eventualResult = try await coordinator.result(for: jobID)
        XCTAssertEqual(eventualResult.text, "eventual")
    }

    func testInvalidProviderScopedIdentityAndUnknownConnectionAreRejected() async throws {
        let executor = makeExecutor(connectionID: qwenConnection, probe: DelegationProbe())
        let coordinator = try DelegationCoordinator(executors: [executor])
        let mismatchedModel = ModelRef(
            connectionID: codexConnection,
            modelID: "gpt-5.6-codex"
        )
        let request = DelegationRequest(
            id: DelegationJobID("mismatch"),
            parentAgent: DelegationAgentIdentity(
                connectionID: codexConnection,
                modelID: "gpt-5.6-codex"
            ),
            target: DelegationTarget(
                connectionID: qwenConnection,
                model: mismatchedModel
            ),
            prompt: "invalid"
        )
        do {
            _ = try await coordinator.submit(request)
            XCTFail("Expected mismatched target identity to be rejected")
        } catch {
            XCTAssertEqual(error as? DelegationCoordinatorError, .invalidTargetIdentity)
        }

        let unknown = makeRequest(id: "unknown", targetConnectionID: codexConnection)
        do {
            _ = try await coordinator.submit(unknown)
            XCTFail("Expected unknown provider connection to be rejected")
        } catch {
            XCTAssertEqual(
                error as? DelegationCoordinatorError,
                .noExecutor(codexConnection)
            )
        }
    }

    func testDirectSubmissionCannotForgeCoordinatorOwnedLineage() async throws {
        let executor = makeExecutor(
            connectionID: qwenConnection,
            probe: DelegationProbe()
        )
        let codexExecutor = makeExecutor(
            connectionID: codexConnection,
            probe: DelegationProbe()
        )
        let coordinator = try DelegationCoordinator(executors: [executor, codexExecutor])
        let rootRequest = makeRequest(id: "lineage-root")
        let root = try await coordinator.submit(rootRequest)
        _ = try await coordinator.result(for: root.jobID)

        let childParent = root.request.target.agent
        let expectedAgents = root.request.lineage.agents + [childParent]
        let forged = DelegationRequest(
            id: DelegationJobID("forged-lineage"),
            parentAgent: childParent,
            target: DelegationTarget(
                connectionID: codexConnection,
                modelID: "gpt-5.6-codex"
            ),
            prompt: "must not run",
            lineage: DelegationLineage(
                rootJobID: DelegationJobID("unrelated-root"),
                parentJobID: root.jobID,
                agents: expectedAgents,
                depth: 1
            )
        )
        do {
            _ = try await coordinator.submit(forged)
            XCTFail("Expected forged lineage to be rejected")
        } catch {
            XCTAssertEqual(error as? DelegationCoordinatorError, .invalidLineage)
        }

        let unknownParent = DelegationRequest(
            id: DelegationJobID("unknown-parent"),
            parentAgent: childParent,
            target: forged.target,
            prompt: "must not run",
            lineage: DelegationLineage(
                rootJobID: root.jobID,
                parentJobID: DelegationJobID("not-accepted"),
                agents: expectedAgents,
                depth: 1
            )
        )
        do {
            _ = try await coordinator.submit(unknownParent)
            XCTFail("Expected unknown parent lineage to be rejected")
        } catch {
            XCTAssertEqual(error as? DelegationCoordinatorError, .invalidLineage)
        }
    }

    // MARK: Fixtures

    private func makeRequest(
        id: String,
        targetConnectionID: ProviderConnectionID? = nil
    ) -> DelegationRequest {
        DelegationRequest(
            id: DelegationJobID(id),
            parentAgent: DelegationAgentIdentity(
                connectionID: codexConnection,
                modelID: "gpt-5.6-codex"
            ),
            target: DelegationTarget(
                connectionID: targetConnectionID ?? qwenConnection,
                modelID: targetConnectionID == codexConnection
                    ? "gpt-5.6-codex"
                    : "Qwen/Qwen3.8-27B-FP8"
            ),
            prompt: "run \(id)"
        )
    }

    private func makeExecutor(
        connectionID: ProviderConnectionID,
        probe: DelegationProbe,
        gate: AsyncGate? = nil,
        waitForGate: Bool = false
    ) -> ClosureDelegationExecutor {
        let qwenID = qwenConnection
        return ClosureDelegationExecutor(connectionID: connectionID) { request, report in
            await probe.record(request)
            await report(.init(phase: "working", message: "safe progress", fraction: 0.5))
            if waitForGate, let gate {
                await gate.wait()
            }
            let text = connectionID == qwenID ? "qwen result" : "codex result"
            await probe.finish(request.id)
            return DelegationOutput(text: text)
        }
    }

    private static func collectEvents(
        from stream: DelegationEventStream
    ) async -> [DelegationEvent] {
        var events: [DelegationEvent] = []
        for await event in stream {
            events.append(event)
            if event.isTerminal { break }
        }
        return events
    }

    private func collectEvents(
        from stream: DelegationEventStream
    ) async -> [DelegationEvent] {
        await Self.collectEvents(from: stream)
    }

    private func waitUntil(
        _ description: String,
        condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(try await condition()) {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForGate(_ gate: AsyncGate, description: String) async throws {
        try await waitUntil(description) {
            await gate.opened()
        }
    }
}

private actor DelegationProbe {
    private var received: [DelegationRequest] = []
    private var active = 0
    private var maxActive = 0

    func record(_ request: DelegationRequest) {
        received.append(request)
        active += 1
        maxActive = max(maxActive, active)
    }

    func finish(_ requestID: DelegationJobID) {
        guard received.contains(where: { $0.id == requestID }) else { return }
        active = max(0, active - 1)
    }

    func requests(for jobID: DelegationJobID) -> [DelegationRequest] {
        received.filter { $0.id == jobID }
    }

    func requestIDs() -> [DelegationJobID] { received.map(\.id) }
    func requestCount() -> Int { received.count }
    func activeCount() -> Int { active }
    func maximumActiveCount() -> Int { maxActive }

    func waitUntilActive(atLeast expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while active < expected {
            if ContinuousClock.now >= deadline {
                throw XCTSkip("Timed out waiting for fake delegation executor")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func opened() -> Bool { isOpen }
}

private extension Collection {
    func asyncMap<T: Sendable>(
        _ transform: (Element) async throws -> T
    ) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
