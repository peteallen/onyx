import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelAuthenticationRecoveryWriterTests: XCTestCase {
    func testRecoveryKeepsPendingApprovalVisibleButNeverAuthorizesOldRequest() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        await startAndLoad(fixture)

        await fixture.runtime.emit(.userInteractionRequested(WriterRecoveryFixture.approval))
        await waitUntil("The approval did not reach the model") {
            fixture.model.activeUserInteraction == WriterRecoveryFixture.approval
        }

        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        await waitUntil("Recovery did not reach the model") {
            fixture.model.authenticationRecovery == .signInExpired
        }

        XCTAssertEqual(
            fixture.model.activeUserInteraction,
            WriterRecoveryFixture.approval,
            "The pending approval should remain visible as task context."
        )
        XCTAssertFalse(fixture.model.canRespond(to: WriterRecoveryFixture.approval))
        fixture.model.respondToApproval(.acceptForSession, for: WriterRecoveryFixture.approval)
        await yieldSeveralTimes()
        let blockedResponses = await fixture.runtime.recordedResponses()
        XCTAssertTrue(blockedResponses.isEmpty)

        await fixture.runtime.suspendNextResume()
        await fixture.runtime.emit(.loginCompleted(RuntimeLoginCompletion(
            loginID: nil,
            success: true,
            error: nil
        )))
        await fixture.runtime.waitUntilResumeIsSuspended()
        XCTAssertNil(fixture.model.authenticationRecovery)
        XCTAssertTrue(fixture.model.canRunAgent)
        XCTAssertFalse(
            fixture.model.canRespond(to: WriterRecoveryFixture.approval),
            "Login success must not make an old approval request authorizing again."
        )

        // Reissue the same provider request while the authoritative task resume
        // is in flight. Its fresh event must win over cleanup from the older
        // recovery snapshot.
        await fixture.runtime.emit(.userInteractionRequested(WriterRecoveryFixture.approval))
        await waitUntil("A freshly reissued approval did not become actionable") {
            fixture.model.canRespond(to: WriterRecoveryFixture.approval)
        }

        var reconciledConversation = RuntimeConversation(
            thread: WriterRecoveryFixture.thread,
            items: [WriterRecoveryFixture.initialItem]
        )
        reconciledConversation.thread.preview = WriterRecoveryFixture.reconciledPreview
        await fixture.runtime.setConversation(reconciledConversation)
        await fixture.runtime.releaseSuspendedResume()
        await waitUntil("The completed recovery refresh erased the fresh approval") {
            fixture.model.selectedThread?.preview == WriterRecoveryFixture.reconciledPreview
                && fixture.model.canRespond(to: WriterRecoveryFixture.approval)
        }
        fixture.model.respondToApproval(.accept, for: WriterRecoveryFixture.approval)
        await waitUntil("The freshly reissued approval was not sent") {
            await fixture.runtime.recordedResponses().count == 1
        }
        let acceptedResponses = await fixture.runtime.recordedResponses()
        XCTAssertEqual(acceptedResponses.first?.0, WriterRecoveryFixture.approval.id)
    }

    func testRecoveryGatesEveryProviderWriterEntryPoint() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        await startAndLoad(fixture)

        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        await waitUntil("Recovery did not reach the model") {
            fixture.model.authenticationRecovery == .signInExpired
        }

        XCTAssertFalse(fixture.model.canRunAgent)
        XCTAssertFalse(fixture.model.canStartReview)
        XCTAssertFalse(fixture.model.canForkThread(WriterRecoveryFixture.thread))
        XCTAssertFalse(fixture.model.canCompactThread(WriterRecoveryFixture.thread))
        XCTAssertFalse(fixture.model.canArchiveThread(WriterRecoveryFixture.thread))
        XCTAssertFalse(fixture.model.canDeleteThread(WriterRecoveryFixture.thread))

        fixture.model.composerText = "Keep this draft"
        fixture.model.sendComposer()
        fixture.model.startReview()
        fixture.model.fork(WriterRecoveryFixture.thread.id)
        fixture.model.compact(WriterRecoveryFixture.thread.id)
        fixture.model.archive(WriterRecoveryFixture.thread.id)
        fixture.model.interrupt()
        await yieldSeveralTimes()

        XCTAssertEqual(fixture.model.composerText, "Keep this draft")
        let writerCallCount = await fixture.runtime.recordedWriterCallCount()
        XCTAssertEqual(writerCallCount, 0)
    }

    func testApprovalRequestAuthenticationFailureUsesRecoveryWithoutRawModal() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        await startAndLoad(fixture)

        await fixture.runtime.emit(.userInteractionRequested(WriterRecoveryFixture.approval))
        await waitUntil("The approval did not reach the model") {
            fixture.model.canRespond(to: WriterRecoveryFixture.approval)
        }
        await fixture.runtime.failNextResponseForAuthenticationRecovery()

        fixture.model.respondToApproval(.acceptForSession, for: WriterRecoveryFixture.approval)

        await waitUntil("The response failure did not enter sign-in recovery") {
            fixture.model.authenticationRecovery == .signInExpired
                && !fixture.model.canRespond(to: WriterRecoveryFixture.approval)
        }
        XCTAssertEqual(fixture.model.activeUserInteraction, WriterRecoveryFixture.approval)
        XCTAssertNil(fixture.model.notice)
        let responses = await fixture.runtime.recordedResponses()
        XCTAssertTrue(responses.isEmpty)
    }

    func testSameAccountRecoveryReconcilesFailedThreadSoRetryReturns() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        await startAndLoad(fixture)

        await fixture.runtime.setConversation(
            WriterRecoveryFixture.failedConversation()
        )
        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        await waitUntil("Recovery did not reach the model") {
            fixture.model.authenticationRecovery == .signInExpired
        }
        XCTAssertNil(fixture.model.retryableFailedResponseItemID)

        await fixture.runtime.emit(.loginCompleted(RuntimeLoginCompletion(
            loginID: nil,
            success: true,
            error: nil
        )))
        await waitUntil("The recovered thread was not resumed and reconciled") {
            fixture.model.retryableFailedResponseItemID
                == WriterRecoveryFixture.failedAssistant.id
                && !fixture.model.isTurnRunning
        }

        XCTAssertEqual(fixture.model.selectedThreadID, WriterRecoveryFixture.thread.id)
        XCTAssertEqual(
            fixture.model.retryUserMessageID(
                forFailedResponseItemID: WriterRecoveryFixture.failedAssistant.id
            ),
            WriterRecoveryFixture.failedUser.id
        )
    }

    private func makeFixture() -> WriterRecoveryFixture {
        let suiteName = "OnyxAppModelAuthenticationRecoveryWriterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let runtime = WriterRecoveryRuntime()
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        return WriterRecoveryFixture(
            model: model,
            runtime: runtime,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func startAndLoad(_ fixture: WriterRecoveryFixture) async {
        fixture.model.start()
        await waitUntil("The fixture task did not load") {
            fixture.model.canRunAgent
                && fixture.model.selectedThreadID == WriterRecoveryFixture.thread.id
                && fixture.model.timeline == [WriterRecoveryFixture.initialItem]
        }
    }

    private func waitUntil(
        _ failureMessage: String,
        timeout: Duration = .seconds(1),
        condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            await Task.yield()
        }
        let didSatisfyCondition = await condition()
        XCTAssertTrue(didSatisfyCondition, failureMessage)
    }

    private func yieldSeveralTimes() async {
        for _ in 0 ..< 10 { await Task.yield() }
    }
}

private struct WriterRecoveryFixture {
    static let reconciledPreview = "Authoritative recovery snapshot"

    static let thread = RuntimeThread(
        id: "writer-recovery-task",
        title: "Recovery task",
        preview: "Recovery task",
        cwd: "/tmp/onyx-writer-recovery-tests",
        updatedAt: Date(timeIntervalSince1970: 2),
        status: .idle,
        isPinned: false,
        runtime: .codex,
        model: "test-model",
        branch: nil
    )

    static let initialItem = TimelineItem(
        id: "writer-recovery-initial",
        kind: .assistantMessage,
        title: nil,
        body: "Existing task context",
        status: .completed,
        timestamp: Date(timeIntervalSince1970: 1),
        detail: nil
    )

    static let failedUser = TimelineItem(
        id: "writer-recovery-failed-user",
        kind: .userMessage,
        title: nil,
        body: "Please retry this",
        status: .completed,
        timestamp: Date(timeIntervalSince1970: 3),
        detail: nil
    )

    static let failedAssistant = TimelineItem(
        id: "writer-recovery-failed-assistant",
        kind: .error,
        title: "Sign in required",
        body: "Sign in again to continue. Your task and draft are still here.",
        status: .failed,
        timestamp: Date(timeIntervalSince1970: 4),
        detail: nil
    )

    static let failedTurn = RuntimeConversationTurn(
        id: "writer-recovery-failed-turn",
        items: [failedUser, failedAssistant],
        status: .failed,
        itemDetail: .full,
        startedAt: nil,
        completedAt: nil,
        durationMilliseconds: nil
    )

    static func failedConversation() -> RuntimeConversation {
        var reconciledThread = thread
        reconciledThread.status = .failed
        return RuntimeConversation(
            thread: reconciledThread,
            items: failedTurn.items,
            turns: [failedTurn]
        )
    }

    static let approval = RuntimeUserInteraction(
        id: .string("writer-recovery-approval"),
        threadID: thread.id,
        providerMethod: "item/commandExecution/requestApproval",
        title: "Run this command?",
        detail: "This request existed before sign-in expired.",
        kind: .approval(RuntimeApprovalPrompt(
            subject: .command,
            command: "swift test",
            supportsSessionApproval: true
        ))
    )

    let model: OnyxAppModel
    let runtime: WriterRecoveryRuntime
    let defaults: UserDefaults
    let suiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor WriterRecoveryRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let continuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private var conversation = RuntimeConversation(
        thread: WriterRecoveryFixture.thread,
        items: [WriterRecoveryFixture.initialItem]
    )
    private var responses: [(RuntimeRequestID, RuntimeUserInteractionResponse)] = []
    private var writerCallCount = 0
    private var shouldFailNextResponseForAuthenticationRecovery = false
    private var shouldSuspendNextResume = false
    private var isResumeSuspended = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var resumeEntryWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        continuation.yield(.connectionChanged(.connected("Writer recovery runtime")))
        return Self.session
    }

    func disconnect() async {}
    func refreshAccount() async throws -> RuntimeSession { Self.session }
    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : [conversation.thread]
    }
    func readThread(id _: String) async throws -> RuntimeConversation { conversation }
    func resumeThread(id _: String) async throws -> RuntimeConversation {
        if shouldSuspendNextResume {
            shouldSuspendNextResume = false
            isResumeSuspended = true
            let waiters = resumeEntryWaiters
            resumeEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
            isResumeSuspended = false
        }
        return conversation
    }
    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        writerCallCount += 1
        return conversation.thread
    }
    func forkThread(id _: String) async throws -> RuntimeThread {
        writerCallCount += 1
        return conversation.thread
    }
    func compactThread(id _: String) async throws { writerCallCount += 1 }
    func deleteThread(id _: String) async throws { writerCallCount += 1 }
    func startTurn(_: StartTurnRequest) async throws { writerCallCount += 1 }
    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun {
        writerCallCount += 1
        return RuntimeReviewRun(threadID: request.threadID, turnID: "review")
    }
    func steer(threadID _: String, text _: String) async throws { writerCallCount += 1 }
    func interrupt(threadID _: String) async throws { writerCallCount += 1 }
    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {
        writerCallCount += 1
        if shouldFailNextResponseForAuthenticationRecovery {
            shouldFailNextResponseForAuthenticationRecovery = false
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
        responses.append((interactionID, response))
    }
    func renameThread(id _: String, name _: String) async throws { writerCallCount += 1 }
    func archiveThread(id _: String) async throws { writerCallCount += 1 }
    func unarchiveThread(id _: String) async throws { writerCallCount += 1 }

    func emit(_ event: AgentRuntimeEvent) {
        continuation.yield(event)
    }

    func setConversation(_ conversation: RuntimeConversation) {
        self.conversation = conversation
    }

    func recordedResponses() -> [(RuntimeRequestID, RuntimeUserInteractionResponse)] { responses }
    func recordedWriterCallCount() -> Int { writerCallCount }
    func failNextResponseForAuthenticationRecovery() {
        shouldFailNextResponseForAuthenticationRecovery = true
    }

    func suspendNextResume() {
        shouldSuspendNextResume = true
    }

    func waitUntilResumeIsSuspended() async {
        guard !isResumeSuspended else { return }
        await withCheckedContinuation { continuation in
            resumeEntryWaiters.append(continuation)
        }
    }

    func releaseSuspendedResume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    private static let session = RuntimeSession(
        runtime: .codex,
        displayName: "Writer recovery runtime",
        accountLabel: "writer@example.com",
        planLabel: "pro",
        auth: RuntimeAuthState(
            mode: .chatgpt,
            email: "writer@example.com",
            planLabel: "pro",
            requiresAuthentication: true
        ),
        availableLoginMethods: [],
        availableModels: [],
        capabilities: [
            .streaming,
            .interruption,
            .approvals,
            .threadForking,
            .threadArchiving,
            .threadCompaction,
            .threadDeletion,
            .threadHistoryRevert,
            .codeReview,
        ]
    )
}
