import XCTest
@testable import Onyx

final class CodexRuntimeLiveTests: XCTestCase {
    func testInstalledAppServerAcceptsEphemeralPaginatedForkWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ONYX_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set ONYX_LIVE_CODEX_TEST=1 to exercise the installed Codex runtime")
        }

        let runtime = try CodexRuntime.makeDevelopmentInstalled()
        do {
            _ = try await runtime.connect()
            let threads = try await runtime.listThreads(limit: 20, archived: false)
            var forkedConversation: RuntimeConversation?
            var lastFailure: (any Error)?

            for thread in threads {
                do {
                    forkedConversation = try await runtime.forkEphemeralThread(id: thread.id)
                    break
                } catch let AgentRuntimeError.requestFailed(_, message)
                    where message.localizedCaseInsensitiveContains("active writer") {
                    lastFailure = AgentRuntimeError.protocolFailure(message)
                    continue
                } catch {
                    lastFailure = error
                    break
                }
            }

            await runtime.disconnect()
            if let lastFailure, forkedConversation == nil { throw lastFailure }
            let verifiedFork = try XCTUnwrap(
                forkedConversation,
                "At least one recent task should support an ephemeral paginated fork"
            )
            XCTAssertTrue(verifiedFork.items.isEmpty)
            XCTAssertFalse(verifiedFork.thread.id.isEmpty)
        } catch {
            await runtime.disconnect()
            throw error
        }
    }

    func testInstalledAppServerConnectsAndListsThreadsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ONYX_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set ONYX_LIVE_CODEX_TEST=1 to exercise the installed Codex runtime")
        }

        let runtime = try CodexRuntime.makeDevelopmentInstalled()
        let session = try await runtime.connect()
        let threads = try await runtime.listThreads(limit: 5, archived: false)
        let archivedThreads = try await runtime.listThreads(limit: 5, archived: true)
        var resumedThread: RuntimeConversation?
        for thread in threads {
            do {
                resumedThread = try await runtime.resumeThread(id: thread.id)
                break
            } catch let AgentRuntimeError.requestFailed(_, message)
                where message.localizedCaseInsensitiveContains("active writer") {
                continue
            }
        }
        await runtime.disconnect()

        XCTAssertEqual(session.runtime, .codex)
        XCTAssertFalse(session.displayName.isEmpty)
        XCTAssertLessThanOrEqual(threads.count, 5)
        XCTAssertLessThanOrEqual(archivedThreads.count, 5)
        XCTAssertFalse(threads.isEmpty, "The installed Codex state should expose at least one recent thread")
        XCTAssertNotNil(resumedThread, "At least one listed task should be resumable outside another active writer")
        if let resumedThread {
            XCTAssertTrue(threads.contains(where: { $0.id == resumedThread.thread.id }))
        }
        print(
            "Onyx live runtime: \(session.availableModels.count) models, "
                + "\(threads.count) active threads, \(archivedThreads.count) archived threads"
        )
    }

    func testEphemeralThreadStreamsAssistantTextWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ONYX_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set ONYX_LIVE_CODEX_TEST=1 to exercise the installed Codex runtime")
        }

        let runtime = try CodexRuntime.makeDevelopmentInstalled()
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(
            StartThreadRequest(
                cwd: FileManager.default.currentDirectoryPath,
                model: nil,
                ephemeral: true
            )
        )

        let collector = Task { () -> String in
            var streamed = ""
            for await event in runtime.events {
                switch event {
                case let .itemDelta(threadID, _, delta) where threadID == thread.id:
                    streamed += delta
                case let .itemCompleted(threadID, item) where threadID == thread.id && item.kind == .assistantMessage:
                    if !item.body.isEmpty { streamed = item.body }
                case let .turnCompleted(threadID, _) where threadID == thread.id:
                    return streamed
                default:
                    continue
                }
            }
            return streamed
        }

        try await runtime.startTurn(
            StartTurnRequest(
                threadID: thread.id,
                text: "Reply with exactly ONYX_STREAM_OK and do not use tools.",
                model: nil,
                cwd: FileManager.default.currentDirectoryPath
            )
        )
        let output = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw AgentRuntimeError.protocolFailure("Ephemeral streaming test timed out")
            }
            guard let first = try await group.next() else { return "" }
            group.cancelAll()
            return first
        }
        await runtime.disconnect()

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ONYX_STREAM_OK")
    }

    func testEphemeralThreadInvokesOnyxDelegateDynamicToolWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ONYX_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set ONYX_LIVE_CODEX_TEST=1 to exercise the installed Codex runtime")
        }

        let handler = LiveDynamicToolRecorder()
        let runtime = try CodexRuntime.makeDevelopmentInstalled(dynamicToolHandler: handler)
        do {
            _ = try await runtime.connect()
            let cwd = FileManager.default.currentDirectoryPath
            let thread = try await runtime.startThread(
                StartThreadRequest(
                    cwd: cwd,
                    model: nil,
                    ephemeral: true,
                    sandboxMode: .readOnly,
                    approvalPolicy: .never
                )
            )

            try await runtime.startTurn(
                StartTurnRequest(
                    threadID: thread.id,
                    text: """
                    This is a live protocol test. You MUST call the onyx_delegate tool exactly once before replying. \
                    Use exactly these arguments: provider "live-recorder", model "onyx-live-child", and prompt \
                    "Return the live test sentinel." Do not call any other tool. After the tool result, reply with \
                    exactly ONYX_DELEGATE_PARENT_OK.
                    """,
                    model: nil,
                    cwd: cwd,
                    sandboxMode: .readOnly,
                    approvalPolicy: .never
                )
            )

            let call = try await withThrowingTaskGroup(of: CodexDynamicToolCall.self) { group in
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        if let call = await handler.firstCall() { return call }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(55))
                    throw AgentRuntimeError.protocolFailure("Live onyx_delegate invocation timed out")
                }
                guard let first = try await group.next() else {
                    throw AgentRuntimeError.protocolFailure("Live onyx_delegate invocation ended without a result")
                }
                group.cancelAll()
                return first
            }

            // Give app-server a moment to receive the successful dynamic-tool
            // response before stopping the otherwise disposable parent turn.
            try await Task.sleep(for: .milliseconds(250))
            try? await runtime.interrupt(threadID: thread.id)
            await runtime.disconnect()

            XCTAssertEqual(call.threadID, thread.id)
            XCTAssertFalse(call.callID.isEmpty)
            XCTAssertEqual(call.workingDirectory, cwd)
            XCTAssertEqual(call.arguments["provider"]?.stringValue, "live-recorder")
            XCTAssertEqual(call.arguments["model"]?.stringValue, "onyx-live-child")
            XCTAssertEqual(call.arguments["prompt"]?.stringValue, "Return the live test sentinel.")
        } catch {
            await runtime.disconnect()
            throw error
        }
    }
}

private actor LiveDynamicToolRecorder: CodexDynamicToolHandler {
    private var calls: [CodexDynamicToolCall] = []

    func handleDynamicToolCall(_ call: CodexDynamicToolCall) -> CodexDynamicToolResult {
        calls.append(call)
        return .succeeded("ONYX_DELEGATE_TOOL_OK")
    }

    func firstCall() -> CodexDynamicToolCall? {
        calls.first
    }
}
