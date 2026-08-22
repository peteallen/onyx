import XCTest
@testable import Onyx

final class CodexRuntimeLiveTests: XCTestCase {
    func testInstalledAppServerConnectsAndListsThreadsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ONYX_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Set ONYX_LIVE_CODEX_TEST=1 to exercise the installed Codex runtime")
        }

        let runtime = try CodexRuntime.makeDefault()
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

        let runtime = try CodexRuntime.makeDefault()
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
}
