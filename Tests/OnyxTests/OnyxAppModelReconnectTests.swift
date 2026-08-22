import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelReconnectTests: XCTestCase {
    func testReconnectKeepsCachedWorkspaceVisibleThenRefreshesOpenTask() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("Initial task did not load") {
            fixture.model.connectionState == .connected(ReconnectFixture.runtimeLabel)
                && fixture.model.selectedThreadID == ReconnectFixture.threadID
                && fixture.model.timeline == [ReconnectFixture.initialItem]
        }

        await fixture.runtime.preparePausedReconnect(
            thread: ReconnectFixture.refreshedThread,
            items: [ReconnectFixture.refreshedItem]
        )
        await fixture.runtime.emit(.connectionChanged(.failed("Codex stopped")))
        await waitUntil("The disconnect did not reach the app model") {
            fixture.model.connectionState == .failed("Codex stopped")
                && fixture.model.canReconnect
        }

        let cachedThreads = fixture.model.threads
        let cachedTimeline = fixture.model.timeline
        fixture.model.reconnect()
        fixture.model.reconnect()

        await waitUntilAsync("Reconnect did not reach the runtime") {
            await fixture.runtime.recordedConnectCount() == 2
        }
        XCTAssertEqual(fixture.model.connectionState, .connecting)
        XCTAssertEqual(fixture.model.threads, cachedThreads)
        XCTAssertEqual(fixture.model.timeline, cachedTimeline)
        XCTAssertFalse(fixture.model.canReconnect)

        await fixture.runtime.completePausedReconnect()
        await waitUntil("Reconnect did not rehydrate the open task") {
            fixture.model.connectionState == .connected(ReconnectFixture.runtimeLabel)
                && fixture.model.selectedThread?.title == ReconnectFixture.refreshedThread.title
                && fixture.model.timeline == [ReconnectFixture.refreshedItem]
                && !fixture.model.isLoadingThread
        }

        let reads = await fixture.runtime.recordedReadCount()
        XCTAssertEqual(reads, 1, "Ordinary launch navigation should read the transcript without acquiring a writer")
        let resumes = await fixture.runtime.recordedResumeCount()
        XCTAssertEqual(resumes, 1, "Reconnect must resume the selected task to restore live notifications")
        let connects = await fixture.runtime.recordedConnectCount()
        XCTAssertEqual(connects, 2, "Repeated clicks while connecting must not start another process")
    }

    func testThreadRefreshFailureLeavesCachedTasksAndTranscriptUsable() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("Initial task did not load") {
            fixture.model.selectedThreadID == ReconnectFixture.threadID
                && fixture.model.timeline == [ReconnectFixture.initialItem]
        }

        let cachedThreads = fixture.model.threads
        let cachedTimeline = fixture.model.timeline
        await fixture.runtime.failNextThreadList()
        await fixture.runtime.emit(.connectionChanged(.disconnected))
        await waitUntil("The disconnect did not reach the app model") {
            fixture.model.connectionState == .disconnected
        }

        fixture.model.reconnect()
        await waitUntil("The refresh failure was not surfaced") {
            fixture.model.connectionState == .connected(ReconnectFixture.runtimeLabel)
                && fixture.model.notice?.title == "Connected, but tasks did not refresh"
                && !fixture.model.isLoadingThreadList
        }

        XCTAssertEqual(fixture.model.threads, cachedThreads)
        XCTAssertEqual(fixture.model.timeline, cachedTimeline)
        XCTAssertTrue(fixture.model.notice?.detail.contains("existing tasks are still available") == true)
    }

    func testConnectionFailureUsesRuntimeNameAndRetryClearsItsNotice() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("Initial task did not load") {
            fixture.model.connectionState == .connected(ReconnectFixture.runtimeLabel)
                && fixture.model.selectedThreadID == ReconnectFixture.threadID
        }

        await fixture.runtime.failNextConnect(message: "simulated provider outage")
        await fixture.runtime.emit(.connectionChanged(.disconnected))
        await waitUntil("The disconnect did not reach the app model") {
            fixture.model.connectionState == .disconnected
        }

        fixture.model.reconnect()
        await waitUntil("The provider-specific connection failure was not surfaced") {
            fixture.model.notice?.title == "\(ReconnectFixture.runtimeLabel) did not connect"
        }
        XCTAssertTrue(fixture.model.notice?.detail.contains("simulated provider outage") == true)

        await fixture.runtime.preparePausedReconnect(
            thread: ReconnectFixture.initialThread,
            items: [ReconnectFixture.initialItem]
        )
        fixture.model.reconnect()
        await waitUntilAsync("Retry did not reach the runtime") {
            await fixture.runtime.recordedConnectCount() == 3
        }
        XCTAssertEqual(fixture.model.connectionState, .connecting)
        XCTAssertNil(fixture.model.notice)

        await fixture.runtime.completePausedReconnect()
        await waitUntil("Retry did not reconnect") {
            fixture.model.connectionState == .connected(ReconnectFixture.runtimeLabel)
        }
    }

    func testLateSuccessfulConnectCannotConcealAStopEvent() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        fixture.model.start()
        await waitUntil("Initial task did not load") {
            fixture.model.selectedThreadID == ReconnectFixture.threadID
                && fixture.model.timeline == [ReconnectFixture.initialItem]
        }

        let initialListCount = await fixture.runtime.recordedListCount()
        await fixture.runtime.makeStopWinNextReconnect()
        await fixture.runtime.emit(.connectionChanged(.failed("First process stopped")))
        await waitUntil("The first failure did not reach the app model") {
            fixture.model.canReconnect
        }

        fixture.model.reconnect()
        await waitUntil("The stop event was overwritten by a late connect result") {
            fixture.model.connectionState == .failed("Replacement process stopped")
                && fixture.model.canReconnect
        }

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.model.connectionState, .failed("Replacement process stopped"))
        let finalListCount = await fixture.runtime.recordedListCount()
        XCTAssertEqual(finalListCount, initialListCount, "A stopped connection must not refresh against a dead process")
        XCTAssertEqual(fixture.model.timeline, [ReconnectFixture.initialItem])
    }

    private func makeFixture() -> ReconnectFixture {
        let suiteName = "OnyxAppModelReconnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let runtime = ReconnectModelRuntime()
        return ReconnectFixture(
            model: OnyxAppModel(runtime: runtime, defaults: defaults),
            runtime: runtime,
            defaults: defaults,
            defaultsSuiteName: suiteName
        )
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private func waitUntilAsync(
        _ failureMessage: String,
        timeout: Duration = .seconds(1),
        condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            await Task.yield()
        }
        let didMeetCondition = await condition()
        XCTAssertTrue(didMeetCondition, failureMessage)
    }
}

private struct ReconnectFixture {
    static let runtimeLabel = "Reconnect test runtime"
    static let threadID = "reconnect-thread"
    static let initialThread = makeThread(title: "Cached task", preview: "Cached preview", updatedAt: 1)
    static let refreshedThread = makeThread(title: "Refreshed task", preview: "Refreshed preview", updatedAt: 2)
    static let initialItem = makeItem(id: "cached-item", body: "Cached transcript")
    static let refreshedItem = makeItem(id: "refreshed-item", body: "Transcript rehydrated after reconnect")

    let model: OnyxAppModel
    let runtime: ReconnectModelRuntime
    let defaults: UserDefaults
    let defaultsSuiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private static func makeThread(title: String, preview: String, updatedAt: TimeInterval) -> RuntimeThread {
        RuntimeThread(
            id: threadID,
            title: title,
            preview: preview,
            cwd: "/tmp/onyx-reconnect-tests",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "test-model",
            branch: nil
        )
    }

    private static func makeItem(id: String, body: String) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: .assistantMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1),
            detail: nil
        )
    }
}

private actor ReconnectModelRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private var connectCount = 0
    private var listCount = 0
    private var readCount = 0
    private var resumeCount = 0
    private var thread = ReconnectFixture.initialThread
    private var items = [ReconnectFixture.initialItem]
    private var shouldPauseReconnect = false
    private var pausedReconnectContinuation: CheckedContinuation<Void, Never>?
    private var shouldFailThreadList = false
    private var shouldStopBeforeReturningSession = false
    private var nextConnectFailureMessage: String?

    init() {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        connectCount += 1
        if let nextConnectFailureMessage {
            self.nextConnectFailureMessage = nil
            throw AgentRuntimeError.protocolFailure(nextConnectFailureMessage)
        }
        if connectCount > 1, shouldPauseReconnect {
            await withCheckedContinuation { continuation in
                pausedReconnectContinuation = continuation
            }
        }
        if connectCount > 1, shouldStopBeforeReturningSession {
            shouldStopBeforeReturningSession = false
            eventContinuation.yield(.connectionChanged(.failed("Replacement process stopped")))
            for _ in 0 ..< 5 { await Task.yield() }
            return session
        }
        eventContinuation.yield(.connectionChanged(.connected(ReconnectFixture.runtimeLabel)))
        return session
    }

    func disconnect() async {}
    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        listCount += 1
        if shouldFailThreadList {
            shouldFailThreadList = false
            throw AgentRuntimeError.protocolFailure("simulated list refresh failure")
        }
        return archived ? [] : [thread]
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        readCount += 1
        return try conversation(id: id)
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        resumeCount += 1
        return try conversation(id: id)
    }

    private func conversation(id: String) throws -> RuntimeConversation {
        guard id == ReconnectFixture.threadID else {
            throw AgentRuntimeError.missingField("test conversation for \(id)")
        }
        return RuntimeConversation(thread: thread, items: items)
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread { throw AgentRuntimeError.unsupported("test") }
    func startTurn(_: StartTurnRequest) async throws {}
    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(to _: RuntimeRequestID, with _: RuntimeUserInteractionResponse) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func preparePausedReconnect(thread: RuntimeThread, items: [TimelineItem]) {
        self.thread = thread
        self.items = items
        shouldPauseReconnect = true
    }

    func completePausedReconnect() {
        shouldPauseReconnect = false
        pausedReconnectContinuation?.resume()
        pausedReconnectContinuation = nil
    }

    func failNextThreadList() {
        shouldFailThreadList = true
    }

    func failNextConnect(message: String) {
        nextConnectFailureMessage = message
    }

    func makeStopWinNextReconnect() {
        shouldStopBeforeReturningSession = true
    }

    func recordedConnectCount() -> Int { connectCount }
    func recordedListCount() -> Int { listCount }
    func recordedReadCount() -> Int { readCount }
    func recordedResumeCount() -> Int { resumeCount }

    private var session: RuntimeSession {
        RuntimeSession(
            runtime: .codex,
            displayName: ReconnectFixture.runtimeLabel,
            accountLabel: ReconnectFixture.runtimeLabel,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: .chatgpt,
                email: "reconnect-tests@example.com",
                planLabel: nil,
                requiresAuthentication: true
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming]
        )
    }
}
