import AppKit
import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelDraftSafetyTests: XCTestCase {
    func testWorkspaceValidationPersistsDraftAndChoosingWorkspaceKeepsItUntilSuccessfulSend() async throws {
        let fixture = makeFixture(initialThreads: [], workspacePath: nil)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The empty runtime did not show the new-task composer") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        let exactDraft = "  Build the project carefully.  "
        model.composerText = exactDraft
        model.sendComposer()

        XCTAssertEqual(model.notice?.title, "Choose a project")
        XCTAssertEqual(model.composerText, exactDraft)
        XCTAssertEqual(persistedDrafts(fixture)[DraftSafetyFixture.welcomeThreadID], exactDraft)
        let rejectedStartThreadCount = await fixture.runtime.startThreadRequestCount()
        XCTAssertEqual(rejectedStartThreadCount, 0)

        model.selectWorkspace(DraftSafetyFixture.workspacePath)

        XCTAssertEqual(model.draftWorkspacePath, DraftSafetyFixture.workspacePath)
        XCTAssertEqual(model.composerText, exactDraft)
        XCTAssertEqual(persistedDrafts(fixture)[DraftSafetyFixture.welcomeThreadID], exactDraft)

        model.dismissNotice()
        model.sendComposer()

        XCTAssertEqual(model.composerText, "", "A valid send should still clear the composer immediately.")
        await waitUntilAsync("The valid draft never reached the runtime") {
            await fixture.runtime.recordedStartTurns().count == 1
        }

        let recordedTurns = await fixture.runtime.recordedStartTurns()
        let turn = try XCTUnwrap(recordedTurns.first)
        XCTAssertEqual(turn.threadID, DraftSafetyFixture.createdThread.id)
        XCTAssertEqual(turn.text, "Build the project carefully.")
        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.createdThread.id)
        XCTAssertNil(persistedDrafts(fixture)[DraftSafetyFixture.welcomeThreadID])
        XCTAssertNil(persistedDrafts(fixture)[DraftSafetyFixture.createdThread.id])
    }

    func testUnavailableRuntimeKeepsDraftVisibleAndDurable() {
        let suiteName = "OnyxAppModelDraftSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OnyxAppModel(
            runtime: nil,
            startupError: AgentRuntimeError.executableNotFound,
            defaults: defaults
        )
        let exactDraft = "  Keep this even when Codex cannot start.\n"

        model.composerText = exactDraft
        model.sendComposer()

        XCTAssertEqual(model.notice?.title, "Codex is unavailable")
        XCTAssertEqual(model.composerText, exactDraft)
        let persisted = defaults.dictionary(forKey: "Onyx.composerDrafts") as? [String: String]
        XCTAssertEqual(persisted?[DraftSafetyFixture.welcomeThreadID], exactDraft)

        let relaunchedModel = OnyxAppModel(runtime: nil, defaults: defaults)
        XCTAssertEqual(relaunchedModel.composerText, exactDraft)
    }

    func testStartThreadFailureRestoresExactDraftWithoutOverwritingFollowUp() async {
        let fixture = makeFixture(initialThreads: [], failurePoint: .startThread)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The empty runtime did not show the new-task composer") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.welcomeThreadID
        }

        let exactDraft = "  First request with intentional spaces  "
        let followUp = "Follow-up typed while Codex starts"
        model.composerText = exactDraft
        model.sendComposer()
        await waitUntilAsync("The start-thread call did not reach the runtime") {
            await fixture.runtime.startThreadRequestCount() == 1
        }

        XCTAssertEqual(model.composerText, "")
        model.composerText = followUp
        await fixture.runtime.releaseFailure()

        await waitUntil("The start-thread failure was not shown") {
            model.notice?.title == "Could not send"
        }

        let restored = exactDraft + "\n\n" + followUp
        XCTAssertEqual(model.composerText, restored)
        XCTAssertEqual(persistedDrafts(fixture)[DraftSafetyFixture.welcomeThreadID], restored)
        let startedTurnCount = await fixture.runtime.recordedStartTurns().count
        XCTAssertEqual(startedTurnCount, 0)
    }

    func testStartTurnFailureRestoresSendingTaskWithoutTouchingNewerSelection() async {
        let fixture = makeFixture(
            initialThreads: [DraftSafetyFixture.threadA, DraftSafetyFixture.threadB],
            failurePoint: .startTurn
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not finish its initial load") {
            model.canRunAgent
                && model.selectedThreadID == DraftSafetyFixture.threadA.id
                && model.timeline == [DraftSafetyFixture.itemA]
        }

        let exactDraft = "  Message intended for A  "
        let followUpForA = "A follow-up typed while its turn starts"
        let draftForB = "Do not replace B's draft"
        model.composerText = exactDraft
        model.sendComposer()
        await waitUntilAsync("The start-turn call did not reach the runtime") {
            await fixture.runtime.recordedStartTurns().count == 1
        }

        model.composerText = followUpForA
        model.selectThread(DraftSafetyFixture.threadB.id)
        await waitUntil("Thread B did not finish loading") {
            model.selectedThreadID == DraftSafetyFixture.threadB.id
                && model.timeline == [DraftSafetyFixture.itemB]
        }
        model.composerText = draftForB

        await fixture.runtime.releaseFailure()
        await waitUntil("The start-turn failure was not shown") {
            model.notice?.title == "Could not send"
        }

        let restoredForA = exactDraft + "\n\n" + followUpForA
        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.threadB.id)
        XCTAssertEqual(model.composerText, draftForB)
        XCTAssertEqual(persistedDrafts(fixture)[DraftSafetyFixture.threadA.id], restoredForA)
        XCTAssertEqual(
            model.threads.first(where: { $0.id == DraftSafetyFixture.threadA.id })?.status,
            .idle
        )

        model.selectThread(DraftSafetyFixture.threadA.id)
        XCTAssertEqual(model.composerText, restoredForA)
        XCTAssertEqual(persistedDrafts(fixture)[DraftSafetyFixture.threadB.id], draftForB)
    }

    func testImageOnlySendReachesRuntimeAndAppearsOptimisticallyInTimeline() async throws {
        let fixture = makeFixture(
            initialThreads: [DraftSafetyFixture.threadA],
            capabilities: [.streaming, .images]
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }

        model.addPastedComposerImages([makeImage(color: .systemPurple)])
        let draft = try XCTUnwrap(model.composerImages.first)
        model.sendComposer()

        await waitUntilAsync("The image-only turn never reached the runtime") {
            await fixture.runtime.recordedStartTurns().count == 1
        }
        let recordedTurns = await fixture.runtime.recordedStartTurns()
        let request = try XCTUnwrap(recordedTurns.first)
        XCTAssertEqual(request.inputs, [draft.input])
        XCTAssertTrue(model.composerText.isEmpty)
        XCTAssertTrue(model.composerImages.isEmpty)
        let optimistic = try XCTUnwrap(model.timeline.last(where: { $0.id.hasPrefix("optimistic:") }))
        XCTAssertEqual(optimistic.body, "")
        XCTAssertEqual(optimistic.attachments.map(\.source), [draft.timelineAttachment.source])
    }

    func testFailedImageSendRestoresOnlyItsOriginatingDraftAcrossNavigation() async throws {
        let fixture = makeFixture(
            initialThreads: [DraftSafetyFixture.threadA, DraftSafetyFixture.threadB],
            failurePoint: .startTurn,
            capabilities: [.streaming, .images]
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }

        model.addPastedComposerImages([makeImage(color: .systemRed)])
        let sentID = try XCTUnwrap(model.composerImages.first?.id)
        model.sendComposer()
        await waitUntilAsync("The image turn did not begin") {
            await fixture.runtime.recordedStartTurns().count == 1
        }

        model.addPastedComposerImages([makeImage(color: .systemOrange)])
        let laterAID = try XCTUnwrap(model.composerImages.first?.id)
        model.selectThread(DraftSafetyFixture.threadB.id)
        await waitUntil("Thread B did not load") { model.selectedThreadID == DraftSafetyFixture.threadB.id }
        model.addPastedComposerImages([makeImage(color: .systemBlue)])
        let draftBIDs = model.composerImages.map(\.id)

        await fixture.runtime.releaseFailure()
        await waitUntil("The failure was not surfaced") { model.notice?.title == "Could not send" }

        XCTAssertEqual(model.selectedThreadID, DraftSafetyFixture.threadB.id)
        XCTAssertEqual(model.composerImages.map(\.id), draftBIDs)
        model.selectThread(DraftSafetyFixture.threadA.id)
        XCTAssertEqual(model.composerImages.map(\.id), [sentID, laterAID])
    }

    func testRuntimeWithoutImageCapabilityRejectsPasteWithoutChangingDraft() async {
        let fixture = makeFixture(initialThreads: [DraftSafetyFixture.threadA])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Thread A did not load") {
            model.canRunAgent && model.selectedThreadID == DraftSafetyFixture.threadA.id
        }

        model.addPastedComposerImages([makeImage(color: .systemPurple)])

        XCTAssertFalse(model.canAttachImages)
        XCTAssertTrue(model.composerImages.isEmpty)
        XCTAssertEqual(model.notice?.title, "Images are not available")
    }

    private func makeImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        return image
    }

    private func makeFixture(
        initialThreads: [RuntimeThread],
        failurePoint: DraftSafetyRuntime.FailurePoint = .none,
        workspacePath: String? = DraftSafetyFixture.workspacePath,
        capabilities: RuntimeCapabilities = [.streaming]
    ) -> DraftSafetyFixture {
        let suiteName = "OnyxAppModelDraftSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let workspacePath {
            defaults.set(workspacePath, forKey: "Onyx.lastWorkspacePath")
        }
        let runtime = DraftSafetyRuntime(
            initialThreads: initialThreads,
            failurePoint: failurePoint,
            capabilities: capabilities
        )
        return DraftSafetyFixture(
            model: OnyxAppModel(runtime: runtime, defaults: defaults),
            runtime: runtime,
            defaults: defaults,
            defaultsSuiteName: suiteName
        )
    }

    private func persistedDrafts(_ fixture: DraftSafetyFixture) -> [String: String] {
        fixture.defaults.dictionary(forKey: "Onyx.composerDrafts") as? [String: String] ?? [:]
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

private struct DraftSafetyFixture {
    static let welcomeThreadID = "onyx:welcome"
    static let workspacePath = "/tmp"
    static let threadA = makeThread(id: "draft-safety-A", title: "Thread A", updatedAt: 3)
    static let threadB = makeThread(id: "draft-safety-B", title: "Thread B", updatedAt: 2)
    static let createdThread = makeThread(id: "draft-safety-created", title: "Created task", updatedAt: 4)
    static let itemA = makeItem(id: "item-A", body: "A history")
    static let itemB = makeItem(id: "item-B", body: "B history")

    let model: OnyxAppModel
    let runtime: DraftSafetyRuntime
    let defaults: UserDefaults
    let defaultsSuiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private static func makeThread(
        id: String,
        title: String,
        updatedAt: TimeInterval
    ) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: title,
            preview: title,
            cwd: workspacePath,
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

private actor DraftSafetyRuntime: AgentRuntime {
    enum FailurePoint: Sendable {
        case none
        case startThread
        case startTurn
    }

    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let continuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let initialThreads: [RuntimeThread]
    private let failurePoint: FailurePoint
    private let capabilities: RuntimeCapabilities
    private var createdThreads: [String: RuntimeThread] = [:]
    private var startThreadRequests: [StartThreadRequest] = []
    private var startTurns: [StartTurnRequest] = []
    private var failureContinuation: CheckedContinuation<Void, Never>?

    init(
        initialThreads: [RuntimeThread],
        failurePoint: FailurePoint,
        capabilities: RuntimeCapabilities
    ) {
        self.initialThreads = initialThreads
        self.failurePoint = failurePoint
        self.capabilities = capabilities
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        continuation.yield(.connectionChanged(.connected("Draft safety runtime")))
        return RuntimeSession(
            runtime: .codex,
            displayName: "Draft safety runtime",
            accountLabel: "draft-safety@example.com",
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: .chatgpt,
                email: "draft-safety@example.com",
                planLabel: nil,
                requiresAuthentication: true
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: capabilities
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        guard !archived else { return [] }
        return (initialThreads + createdThreads.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        switch id {
        case DraftSafetyFixture.threadA.id:
            RuntimeConversation(thread: DraftSafetyFixture.threadA, items: [DraftSafetyFixture.itemA])
        case DraftSafetyFixture.threadB.id:
            RuntimeConversation(thread: DraftSafetyFixture.threadB, items: [DraftSafetyFixture.itemB])
        default:
            if let thread = createdThreads[id] {
                RuntimeConversation(thread: thread, items: [])
            } else {
                throw AgentRuntimeError.missingField("test thread \(id)")
            }
        }
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await readThread(id: id)
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        startThreadRequests.append(request)
        if failurePoint == .startThread {
            await suspendFailure()
            throw AgentRuntimeError.protocolFailure("simulated start-thread failure")
        }
        let thread = DraftSafetyFixture.createdThread
        createdThreads[thread.id] = thread
        return thread
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        startTurns.append(request)
        if failurePoint == .startTurn {
            await suspendFailure()
            throw AgentRuntimeError.protocolFailure("simulated start-turn failure")
        }
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

    func startThreadRequestCount() -> Int {
        startThreadRequests.count
    }

    func recordedStartTurns() -> [StartTurnRequest] {
        startTurns
    }

    func releaseFailure() {
        failureContinuation?.resume()
        failureContinuation = nil
    }

    private func suspendFailure() async {
        await withCheckedContinuation { continuation in
            failureContinuation = continuation
        }
    }
}
