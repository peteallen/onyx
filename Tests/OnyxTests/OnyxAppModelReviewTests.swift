import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelReviewTests: XCTestCase {
    func testReviewBlocksDuplicateStartsAndComposerThenRemainsInterruptible() async {
        let fixture = makeFixture(reviewOutcome: .delayed)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The review fixture did not load") {
            model.selectedThreadID == ReviewFixture.threadA.id
                && model.timeline == [ReviewFixture.itemA]
        }

        model.startReview()
        model.startReview()
        await waitUntilAsync("The review request did not reach the runtime") {
            await fixture.runtime.reviewRequests().count == 1
        }
        XCTAssertTrue(model.isSelectedReviewStarting)
        XCTAssertTrue(model.isReviewBlockingComposer)
        XCTAssertTrue(
            model.canEditComposer,
            "An active review must gate Send without disabling local follow-up drafting"
        )

        model.composerText = "Keep this draft while review runs"
        model.sendComposer()
        await Task.yield()
        XCTAssertEqual(model.composerText, "Keep this draft while review runs")
        XCTAssertEqual(model.notice?.title, "Review is still running")
        let startedTurns = await fixture.runtime.startedTurnCount()
        let steeredTurns = await fixture.runtime.steeredTurnCount()
        XCTAssertEqual(startedTurns, 0)
        XCTAssertEqual(steeredTurns, 0)

        await fixture.runtime.completeDelayedReview()
        await waitUntil("Onyx did not enter the running review state") {
            model.isReviewRunning && model.isTurnRunning && !model.isStartingReview
        }
        let requests = await fixture.runtime.reviewRequests()
        let request = requests.first
        XCTAssertEqual(
            request,
            StartReviewRequest(
                threadID: ReviewFixture.threadA.id,
                target: .uncommittedChanges,
                delivery: .inline
            )
        )

        model.interrupt()
        await waitUntilAsync("Stop did not target the reviewed task") {
            await fixture.runtime.interruptedThreadIDs() == [ReviewFixture.threadA.id]
        }

        await fixture.runtime.emit(.turnCompleted(threadID: ReviewFixture.threadA.id, status: .idle))
        await waitUntil("The completed review remained busy") {
            model.reviewingThreadID == nil && !model.isTurnRunning
        }
        XCTAssertTrue(model.canStartReview)
    }

    func testReviewCompletionAfterNavigationDoesNotTakeOverTheNewSelection() async {
        let fixture = makeFixture(reviewOutcome: .delayed)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The review fixture did not load") {
            model.selectedThreadID == ReviewFixture.threadA.id
        }
        model.startReview()
        await waitUntilAsync("The delayed review did not start") {
            await fixture.runtime.reviewRequests().count == 1
        }

        model.selectThread(ReviewFixture.threadB.id)
        await waitUntil("The second task did not load") {
            model.selectedThreadID == ReviewFixture.threadB.id
                && model.timeline == [ReviewFixture.itemB]
        }
        await fixture.runtime.completeDelayedReview()
        await waitUntil("The original task did not retain its review state") {
            model.reviewingThreadID == ReviewFixture.threadA.id && !model.isStartingReview
        }

        XCTAssertEqual(model.selectedThreadID, ReviewFixture.threadB.id)
        XCTAssertEqual(model.timeline, [ReviewFixture.itemB])
        XCTAssertFalse(model.isTurnRunning)
        XCTAssertFalse(model.isReviewBlockingComposer)
        XCTAssertNil(model.notice)

        await fixture.runtime.emit(.turnCompleted(threadID: ReviewFixture.threadA.id, status: .idle))
        await waitUntil("The background review did not clear on completion") {
            model.reviewingThreadID == nil
        }
    }

    func testReviewFailureIsReadableAndLogoutInvalidatesDelayedCompletion() async {
        let failedFixture = makeFixture(reviewOutcome: .activeWriterFailure)
        defer { failedFixture.cleanUp() }
        failedFixture.model.start()
        await waitUntil("The failure fixture did not load") {
            failedFixture.model.selectedThreadID == ReviewFixture.threadA.id
        }

        failedFixture.model.startReview()
        await waitUntil("The active-writer failure was not surfaced") {
            failedFixture.model.notice?.title == "Could not start code review"
        }
        XCTAssertTrue(
            failedFixture.model.notice?.detail.contains("another Review test runtime window") == true
        )
        XCTAssertNil(failedFixture.model.reviewingThreadID)
        XCTAssertFalse(failedFixture.model.isStartingReview)
        XCTAssertTrue(failedFixture.model.canStartReview)

        let delayedFixture = makeFixture(reviewOutcome: .delayed)
        defer { delayedFixture.cleanUp() }
        delayedFixture.model.start()
        await waitUntil("The logout fixture did not load") {
            delayedFixture.model.selectedThreadID == ReviewFixture.threadA.id
        }
        delayedFixture.model.startReview()
        await waitUntilAsync("The logout review did not start") {
            await delayedFixture.runtime.reviewRequests().count == 1
        }

        await delayedFixture.runtime.emit(.accountUpdated(.signedOut))
        await waitUntil("Logout did not close the review state") {
            delayedFixture.model.reviewingThreadID == nil
                && !delayedFixture.model.isStartingReview
                && delayedFixture.model.selectedThreadID == "onyx:welcome"
        }
        await delayedFixture.runtime.completeDelayedReview()
        await Task.yield()

        XCTAssertNil(delayedFixture.model.reviewingThreadID)
        XCTAssertFalse(delayedFixture.model.isTurnRunning)
        XCTAssertEqual(delayedFixture.model.selectedThreadID, "onyx:welcome")
        XCTAssertNil(delayedFixture.model.notice)
    }

    private func makeFixture(reviewOutcome: ReviewTestRuntime.ReviewOutcome) -> ReviewTestFixture {
        let suiteName = "OnyxAppModelReviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(ReviewFixture.threadA.id, forKey: "Onyx.selectedThreadID")
        let runtime = ReviewTestRuntime(reviewOutcome: reviewOutcome)
        return ReviewTestFixture(
            model: OnyxAppModel(runtime: runtime, defaults: defaults),
            runtime: runtime,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), failureMessage)
    }

    private func waitUntilAsync(
        _ failureMessage: String,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let didMeetCondition = await condition()
        XCTAssertTrue(didMeetCondition, failureMessage)
    }
}

private struct ReviewTestFixture {
    let model: OnyxAppModel
    let runtime: ReviewTestRuntime
    let defaults: UserDefaults
    let suiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum ReviewFixture {
    static let threadA = makeThread(id: "review-thread-A", title: "Review task A", updatedAt: 2)
    static let threadB = makeThread(id: "review-thread-B", title: "Review task B", updatedAt: 1)
    static let itemA = makeItem(id: "review-item-A", body: "Task A history")
    static let itemB = makeItem(id: "review-item-B", body: "Task B history")

    private static func makeThread(id: String, title: String, updatedAt: TimeInterval) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: title,
            preview: title,
            cwd: "/tmp/onyx-review-tests",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "review-test-model",
            branch: "main"
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

private actor ReviewTestRuntime: AgentRuntime {
    enum ReviewOutcome: Sendable {
        case delayed
        case activeWriterFailure
    }

    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let reviewOutcome: ReviewOutcome
    private var recordedReviewRequests: [StartReviewRequest] = []
    private var delayedReviewContinuation: CheckedContinuation<RuntimeReviewRun, any Error>?
    private var startTurns = 0
    private var steeredTurns = 0
    private var interruptedThreads: [String] = []

    init(reviewOutcome: ReviewOutcome) {
        self.reviewOutcome = reviewOutcome
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        eventContinuation.yield(.connectionChanged(.connected("Review test runtime")))
        return RuntimeSession(
            runtime: .codex,
            displayName: "Review test runtime",
            accountLabel: "Review tester",
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: .chatgpt,
                email: "review@example.com",
                planLabel: nil,
                requiresAuthentication: true
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming, .interruption, .codeReview]
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : [ReviewFixture.threadA, ReviewFixture.threadB]
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        switch id {
        case ReviewFixture.threadA.id:
            return RuntimeConversation(thread: ReviewFixture.threadA, items: [ReviewFixture.itemA])
        case ReviewFixture.threadB.id:
            return RuntimeConversation(thread: ReviewFixture.threadB, items: [ReviewFixture.itemB])
        default:
            throw AgentRuntimeError.missingField("review fixture thread \(id)")
        }
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("starting a task in review tests")
    }

    func startTurn(_: StartTurnRequest) async throws {
        startTurns += 1
    }

    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun {
        recordedReviewRequests.append(request)
        switch reviewOutcome {
        case .delayed:
            return try await withCheckedThrowingContinuation { continuation in
                delayedReviewContinuation = continuation
            }
        case .activeWriterFailure:
            throw AgentRuntimeError.requestFailed(
                code: -32000,
                message: "thread already has an active writer"
            )
        }
    }

    func steer(threadID _: String, text _: String) async throws {
        steeredTurns += 1
    }

    func interrupt(threadID: String) async throws {
        interruptedThreads.append(threadID)
    }

    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {}

    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    func completeDelayedReview() {
        delayedReviewContinuation?.resume(
            returning: RuntimeReviewRun(
                threadID: ReviewFixture.threadA.id,
                turnID: "review-turn-A"
            )
        )
        delayedReviewContinuation = nil
    }

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func reviewRequests() -> [StartReviewRequest] {
        recordedReviewRequests
    }

    func startedTurnCount() -> Int { startTurns }
    func steeredTurnCount() -> Int { steeredTurns }
    func interruptedThreadIDs() -> [String] { interruptedThreads }
}
