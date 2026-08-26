import Foundation
import XCTest
@testable import Onyx

final class AgentRuntimeDelegationExecutorTests: XCTestCase {
    private let connection = ProviderConnectionID("local.scripted")
    private let modelID = "scripted-model"

    func testRuntimeBridgeExecutesAChildTurnAndPreservesProviderBinding() async throws {
        let runtime = ScriptedDelegationRuntime(connectionName: connection.rawValue)
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            workingDirectory: "/tmp/provider-default"
        )
        let coordinator = try DelegationCoordinator(executors: [executor])
        let request = DelegationRequest(
            id: DelegationJobID("runtime-bridge"),
            parentAgent: DelegationAgentIdentity(
                connectionID: ProviderConnectionID("openai.codex.default"),
                modelID: "gpt-5.6-codex"
            ),
            target: DelegationTarget(
                connectionID: connection,
                modelID: modelID,
                agentID: "scripted-child"
            ),
            prompt: "Summarize the current task.",
            workingDirectory: "/tmp/onyx-delegation"
        )

        let handle = try await coordinator.submit(request)
        let result = try await coordinator.result(for: handle.jobID)
        let starts = await runtime.startedRequests()

        XCTAssertEqual(result.text, "scripted response")
        XCTAssertEqual(result.output.childConversationID, "child-thread")
        XCTAssertEqual(result.target, request.target)
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].model, modelID)
        XCTAssertEqual(starts[0].cwd, "/tmp/onyx-delegation")
        XCTAssertEqual(starts[0].inputs, [.text(request.prompt)])
        XCTAssertEqual(starts[0].sandboxMode, .readOnly)
        XCTAssertEqual(starts[0].approvalPolicy, .never)
        let childStarts = await runtime.startedThreadRequests()
        XCTAssertEqual(childStarts.count, 1)
        XCTAssertFalse(childStarts[0].allowsDynamicTools)
        let connectCalls = await runtime.connectCallCount()
        XCTAssertEqual(connectCalls, 1)
    }

    func testRuntimeBridgeCanDeletePrivateChildAfterCompletion() async throws {
        let runtime = ScriptedDelegationRuntime(connectionName: connection.rawValue)
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            deletesThreadAfterExecution: true
        )
        let request = DelegationRequest(
            id: DelegationJobID("private-runtime-bridge"),
            parentAgent: DelegationAgentIdentity(
                connectionID: connection,
                modelID: "parent"
            ),
            target: DelegationTarget(connectionID: connection, modelID: modelID),
            prompt: "Do the private check."
        )

        let output = try await executor.execute(request, reportProgress: { _ in })

        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(deleted, ["child-thread"])
        XCTAssertNil(output.childConversationID)
    }

    func testRuntimeBridgeRejectsUnsupportedTargetBeforeCreatingAThread() async throws {
        let runtime = ScriptedDelegationRuntime(connectionName: connection.rawValue)
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID]
        )
        let request = DelegationRequest(
            id: DelegationJobID("unsupported-runtime-bridge"),
            parentAgent: DelegationAgentIdentity(
                connectionID: connection,
                modelID: "parent"
            ),
            target: DelegationTarget(connectionID: connection, modelID: "other-model"),
            prompt: "Must not run."
        )

        do {
            _ = try await executor.execute(request, reportProgress: { _ in })
            XCTFail("Expected unsupported model")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(error, .unsupportedModel("other-model"))
        }
        let starts = await runtime.startedRequests()
        XCTAssertTrue(starts.isEmpty)
    }

    func testRuntimeBridgeFailsWhenProviderCompletesWithoutAnswerText() async throws {
        // Reasoning-only responses can reach an idle terminal state without
        // producing assistant prose. A delegated tool result must never turn
        // that into a successful blank response to the parent Codex task.
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .respond("   ")
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID]
        )

        do {
            _ = try await executor.execute(
                makeRequest(id: "empty-answer"),
                reportProgress: { _ in }
            )
            XCTFail("Expected an empty delegated answer to fail")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .execution("The delegated turn completed without an answer.")
            )
        }

        // The child is app-created work with no usable result, so the bridge
        // must clean it up instead of leaving an orphaned task behind.
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeCancellationInterruptsAndRemovesItsChild() async throws {
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .blockUntilCancellation
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID]
        )
        let request = DelegationRequest(
            id: DelegationJobID("cancel-runtime-bridge"),
            parentAgent: DelegationAgentIdentity(
                connectionID: connection,
                modelID: "parent"
            ),
            target: DelegationTarget(connectionID: connection, modelID: modelID),
            prompt: "Keep working until cancelled."
        )
        let execution = Task {
            try await executor.execute(request, reportProgress: { _ in })
        }
        for _ in 0 ..< 200 {
            if await runtime.startedRequests().isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        execution.cancel()

        do {
            _ = try await execution.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let interrupted = await runtime.interruptedThreadIDs()
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(interrupted, ["child-thread"])
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeFailsAndCleansUpWhenProviderConnectionDies() async throws {
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .connectionFailure("app-server exited")
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID]
        )

        do {
            _ = try await executor.execute(makeRequest(id: "disconnect"), reportProgress: { _ in })
            XCTFail("Expected provider failure")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(error, .provider("app-server exited"))
        }

        let interrupted = await runtime.interruptedThreadIDs()
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(interrupted, ["child-thread"])
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeHasABoundedTerminalTimeout() async throws {
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .noTerminal("partial response")
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            terminalTimeout: .milliseconds(50)
        )

        do {
            _ = try await executor.execute(makeRequest(id: "timeout"), reportProgress: { _ in })
            XCTFail("Expected terminal timeout")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .provider("The delegated turn did not reach a terminal state before the timeout.")
            )
        }

        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeBoundsConnectSetup() async throws {
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .blockConnect
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            setupTimeout: .milliseconds(30)
        )

        do {
            _ = try await executor.execute(makeRequest(id: "connect-timeout"), reportProgress: { _ in })
            XCTFail("A hanging provider connection must be bounded")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .provider("The provider connection did not complete before the setup timeout.")
            )
        }
        let started = await runtime.startedRequests()
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(started.count, 0)
        XCTAssertEqual(deleted, [])
    }

    func testRuntimeBridgeBoundsChildCreationSetup() async throws {
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .blockStartThread
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            setupTimeout: .milliseconds(30)
        )

        do {
            _ = try await executor.execute(makeRequest(id: "child-timeout"), reportProgress: { _ in })
            XCTFail("A hanging child creation must be bounded")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .provider("The provider child creation did not complete before the setup timeout.")
            )
        }
        let started = await runtime.startedRequests()
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(started.count, 0)
        XCTAssertEqual(deleted, [])
    }

    func testRuntimeBridgeBoundsTurnStartAndCleansKnownChild() async throws {
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .blockStartTurn
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            setupTimeout: .milliseconds(30)
        )

        do {
            _ = try await executor.execute(makeRequest(id: "turn-timeout"), reportProgress: { _ in })
            XCTFail("A hanging turn start must be bounded")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .provider("The provider turn start did not complete before the setup timeout.")
            )
        }
        let interrupted = await runtime.interruptedThreadIDs()
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(interrupted, ["child-thread"])
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeHardBoundsCancellationUncooperativeConnect() async throws {
        let gate = NonCooperativeDelegationGate()
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .ignoreConnectCancellation(gate)
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            setupTimeout: .milliseconds(30)
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            _ = try await executor.execute(
                makeRequest(id: "noncooperative-connect-timeout"),
                reportProgress: { _ in }
            )
            XCTFail("A cancellation-uncooperative connection must still time out")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .provider("The provider connection did not complete before the setup timeout.")
            )
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        gate.release()
    }

    func testRuntimeBridgeCancellationDuringCompletedProgressCannotReturnSuccess() async throws {
        let runtime = ScriptedDelegationRuntime(connectionName: connection.rawValue)
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID]
        )
        let completedProgress = NonCooperativeDelegationGate()
        let request = makeRequest(id: "cancel-during-completed-progress")
        let execution = Task {
            try await executor.execute(
                request,
                reportProgress: { update in
                    if update.phase == "completed" {
                        await completedProgress.wait()
                    }
                }
            )
        }
        for _ in 0 ..< 200 {
            if await runtime.startedRequests().isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Give the synchronous fixture time to reach its suspended completed
        // progress sink, then make cancellation authoritative.
        try await Task.sleep(for: .milliseconds(10))
        execution.cancel()
        completedProgress.release()

        do {
            _ = try await execution.value
            XCTFail("Cancellation during completed progress must not publish success")
        } catch is CancellationError {
            // Expected.
        }
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeRemovesChildCreatedAfterSetupTimeout() async throws {
        let gate = NonCooperativeDelegationGate()
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .ignoreStartThreadCancellation(gate)
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            setupTimeout: .milliseconds(30)
        )

        do {
            _ = try await executor.execute(
                makeRequest(id: "late-child-timeout"),
                reportProgress: { _ in }
            )
            XCTFail("A cancellation-uncooperative child creation must time out")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .provider("The provider child creation did not complete before the setup timeout.")
            )
        }
        gate.release()
        for _ in 0 ..< 200 {
            if await runtime.deletedThreadIDs() == ["child-thread"] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeStopsTurnThatReturnsAfterSetupTimeout() async throws {
        let gate = NonCooperativeDelegationGate()
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .ignoreStartTurnCancellation(gate)
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID],
            setupTimeout: .milliseconds(30)
        )

        do {
            _ = try await executor.execute(
                makeRequest(id: "late-turn-timeout"),
                reportProgress: { _ in }
            )
            XCTFail("A cancellation-uncooperative turn start must time out")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .provider("The provider turn start did not complete before the setup timeout.")
            )
        }
        gate.release()
        for _ in 0 ..< 200 {
            let interrupted = await runtime.interruptedThreadIDs()
            let deleted = await runtime.deletedThreadIDs()
            if interrupted == ["child-thread"], deleted == ["child-thread"] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let interrupted = await runtime.interruptedThreadIDs()
        let deleted = await runtime.deletedThreadIDs()
        XCTAssertEqual(interrupted, ["child-thread"])
        XCTAssertEqual(deleted, ["child-thread"])
    }

    func testRuntimeBridgeFailsWhenChildIsDeletedBeforeCompletion() async throws {
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .childDeleted
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID]
        )

        do {
            _ = try await executor.execute(makeRequest(id: "deleted"), reportProgress: { _ in })
            XCTFail("Expected deleted child failure")
        } catch let error as DelegationExecutorError {
            XCTAssertEqual(
                error,
                .execution("The delegated child task was deleted before it completed.")
            )
        }
    }

    func testRuntimeBridgeDiscardsToolDeltasAndBoundsAssistantOutputWhileStreaming() async throws {
        let toolOutput = String(
            repeating: "tool-output-that-must-not-appear ",
            count: 4_000
        )
        let response = String(
            repeating: "r",
            count: DelegationSafeText.outputCharacterLimit + 500
        )
        let runtime = ScriptedDelegationRuntime(
            connectionName: connection.rawValue,
            behavior: .noisyToolThenRespond(toolOutput: toolOutput, response: response)
        )
        let executor = AgentRuntimeDelegationExecutor(
            connectionID: connection,
            runtime: runtime,
            supportedModelIDs: [modelID]
        )

        let output = try await executor.execute(
            makeRequest(id: "bounded-stream"),
            reportProgress: { _ in }
        )

        XCTAssertEqual(
            output.truncatedAtCharacterLimit,
            DelegationSafeText.outputCharacterLimit
        )
        XCTAssertEqual(output.text.count, DelegationSafeText.outputCharacterLimit + 1)
        XCTAssertTrue(output.text.hasSuffix("…"))
        XCTAssertFalse(output.text.contains("tool-output"))
    }

    private func makeRequest(id: String) -> DelegationRequest {
        DelegationRequest(
            id: DelegationJobID(id),
            parentAgent: DelegationAgentIdentity(
                connectionID: connection,
                modelID: "parent"
            ),
            target: DelegationTarget(connectionID: connection, modelID: modelID),
            prompt: "Run the delegated check."
        )
    }
}

private enum ScriptedDelegationBehavior: Sendable {
    case respond(String)
    case blockConnect
    case blockStartThread
    case blockStartTurn
    case ignoreConnectCancellation(NonCooperativeDelegationGate)
    case ignoreStartThreadCancellation(NonCooperativeDelegationGate)
    case ignoreStartTurnCancellation(NonCooperativeDelegationGate)
    case blockUntilCancellation
    case connectionFailure(String)
    case noTerminal(String)
    case childDeleted
    case noisyToolThenRespond(toolOutput: String, response: String)
}

private actor ScriptedDelegationRuntime: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind = .local
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let thread: RuntimeThread
    private let behavior: ScriptedDelegationBehavior
    private var starts: [StartTurnRequest] = []
    private var threadStarts: [StartThreadRequest] = []
    private var deleted: [String] = []
    private var interrupted: [String] = []
    private var connects = 0

    init(
        connectionName: String,
        behavior: ScriptedDelegationBehavior = .respond("scripted response")
    ) {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
        thread = RuntimeThread(
            id: "child-thread",
            title: "Scripted child",
            preview: "",
            cwd: "/tmp",
            updatedAt: .now,
            status: .idle,
            isPinned: false,
            runtime: .local,
            model: "scripted-model",
            branch: nil
        )
        self.behavior = behavior
        _ = connectionName
    }

    deinit { eventContinuation.finish() }

    func connect() async throws -> RuntimeSession {
        connects += 1
        if case .blockConnect = behavior {
            try await Task.sleep(for: .seconds(60))
        }
        if case let .ignoreConnectCancellation(gate) = behavior {
            await gate.wait()
        }
        return RuntimeSession(
            runtime: .local,
            displayName: "Scripted",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [
                RuntimeModel(
                    id: "scripted-model",
                    displayName: "Scripted",
                    description: nil,
                    isDefault: true,
                    defaultReasoningEffort: nil,
                    reasoningEfforts: []
                ),
            ],
            capabilities: [.streaming]
        )
    }

    func disconnect() async {}
    func startLogin(methodID _: String) async throws -> RuntimeLoginStart { throw AgentRuntimeError.unsupported("login") }
    func cancelLogin(id _: String) async throws { throw AgentRuntimeError.unsupported("login") }
    func logout() async throws { throw AgentRuntimeError.unsupported("logout") }
    func refreshAccount() async throws -> RuntimeSession { try await connect() }
    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] { [] }
    func listAllThreads(archived _: Bool) async throws -> [RuntimeThread] { [] }
    func readThread(id _: String) async throws -> RuntimeConversation { RuntimeConversation(thread: thread, items: []) }
    func resumeThread(id: String) async throws -> RuntimeConversation { try await readThread(id: id) }
    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        threadStarts.append(request)
        if case .blockStartThread = behavior {
            try await Task.sleep(for: .seconds(60))
        }
        if case let .ignoreStartThreadCancellation(gate) = behavior {
            await gate.wait()
        }
        return thread
    }
    func startTurn(_ request: StartTurnRequest) async throws {
        starts.append(request)
        switch behavior {
        case .blockConnect, .blockStartThread, .ignoreConnectCancellation,
             .ignoreStartThreadCancellation:
            return

        case .blockStartTurn:
            try await Task.sleep(for: .seconds(60))
            return

        case let .ignoreStartTurnCancellation(gate):
            await gate.wait()
            return

        case .blockUntilCancellation:
            try await Task.sleep(for: .seconds(60))
            return

        case let .connectionFailure(message):
            eventContinuation.yield(.connectionChanged(.failed(message)))
            return

        case let .noTerminal(response):
            emitAssistant(response, completesTurn: false)
            return

        case .childDeleted:
            eventContinuation.yield(.threadDeleted(threadID: thread.id))
            return

        case let .noisyToolThenRespond(toolOutput, response):
            eventContinuation.yield(.itemDelta(
                threadID: thread.id,
                itemID: "tool-item",
                delta: toolOutput
            ))
            eventContinuation.yield(.itemStarted(
                threadID: thread.id,
                item: TimelineItem(
                    id: "tool-item",
                    kind: .command,
                    title: "Noisy tool",
                    body: "",
                    status: .running,
                    timestamp: .now,
                    detail: nil
                )
            ))
            emitAssistant(response, completesTurn: true)
            return

        case let .respond(response):
            emitAssistant(response, completesTurn: true)
        }
    }

    private func emitAssistant(_ response: String, completesTurn: Bool) {
        eventContinuation.yield(.itemStarted(
            threadID: thread.id,
            item: TimelineItem(
                id: "assistant-item",
                kind: .assistantMessage,
                title: nil,
                body: "",
                status: .running,
                timestamp: .now,
                detail: nil
            )
        ))
        eventContinuation.yield(.itemDelta(
            threadID: thread.id,
            itemID: "assistant-item",
            delta: response
        ))
        eventContinuation.yield(.itemCompleted(
            threadID: thread.id,
            item: TimelineItem(
                id: "assistant-item",
                kind: .assistantMessage,
                title: nil,
                body: response,
                status: .completed,
                timestamp: .now,
                detail: nil
            )
        ))
        if completesTurn {
            eventContinuation.yield(.turnCompleted(threadID: thread.id, status: .idle))
        }
    }

    func interrupt(threadID: String) async throws { interrupted.append(threadID) }
    func steer(threadID _: String, text _: String) async throws { throw AgentRuntimeError.unsupported("steer") }
    func respond(to _: RuntimeRequestID, with _: RuntimeUserInteractionResponse) async throws { throw AgentRuntimeError.unsupported("respond") }
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}
    func deleteThread(id: String) async throws { deleted.append(id) }

    func startedRequests() -> [StartTurnRequest] { starts }
    func startedThreadRequests() -> [StartThreadRequest] { threadStarts }
    func deletedThreadIDs() -> [String] { deleted }
    func interruptedThreadIDs() -> [String] { interrupted }
    func connectCallCount() -> Int { connects }
}

private final class NonCooperativeDelegationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if isReleased { return true }
                waiter = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isReleased = true
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}
