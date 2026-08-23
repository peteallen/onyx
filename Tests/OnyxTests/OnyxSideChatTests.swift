import AppKit
import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxSideChatTests: XCTestCase {
    func testSideChatPanelLayoutOverlaysWithoutShrinkingMainConversation() {
        XCTAssertEqual(SideChatPanelLayout.resolve(availableWidth: 860).panelWidth, 380)
        XCTAssertEqual(SideChatPanelLayout.resolve(availableWidth: 420).panelWidth, 380)
        XCTAssertEqual(SideChatPanelLayout.resolve(availableWidth: 340).panelWidth, 320)
        XCTAssertEqual(SideChatPanelLayout.resolve(availableWidth: 250).panelWidth, 300)
    }

    func testSideChatForkAndStreamingStayIsolatedFromDurableTask() async {
        let fixture = makeFixture(capabilities: [.streaming, .interruption, .ephemeralThreadForking])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Parent task did not load") {
            model.selectedThreadID == SideChatFixture.parent.id
                && model.timeline == [SideChatFixture.parentItem]
        }
        let durableThreadsBefore = model.threads
        let durableTimelineBefore = model.timeline

        model.openSideChat()
        await waitUntil("Ephemeral fork did not open") {
            model.sideChatThreadID == SideChatFixture.fork.id
                && model.sideChatTimeline == [SideChatFixture.parentItem]
        }

        let forkRequests = await fixture.runtime.forkRequests()
        XCTAssertEqual(forkRequests, [SideChatFixture.parent.id])
        XCTAssertEqual(model.threads, durableThreadsBefore)
        XCTAssertEqual(model.timeline, durableTimelineBefore)

        model.sideChatComposerText = "What is the smallest safe change?"
        model.sendSideChat()
        await waitUntilAsync("Side-chat turn did not reach the runtime") {
            await fixture.runtime.startTurnRequests().count == 1
        }

        let requests = await fixture.runtime.startTurnRequests()
        let request = requests.first
        XCTAssertEqual(request?.threadID, SideChatFixture.fork.id)
        XCTAssertEqual(request?.text, "What is the smallest safe change?")
        XCTAssertEqual(request?.model, "codex-side-model")
        XCTAssertEqual(request?.reasoningEffort, "high")
        XCTAssertEqual(request?.cwd, SideChatFixture.parent.cwd)

        let userItem = SideChatFixture.item(
            id: "side-user",
            kind: .userMessage,
            body: "What is the smallest safe change?",
            status: .completed
        )
        let assistantStarted = SideChatFixture.item(
            id: "side-answer",
            kind: .assistantMessage,
            body: "",
            status: .running
        )
        await fixture.runtime.emit(.itemStarted(threadID: SideChatFixture.fork.id, item: userItem))
        await fixture.runtime.emit(.itemStarted(threadID: SideChatFixture.fork.id, item: assistantStarted))
        await fixture.runtime.emit(
            .itemDelta(threadID: SideChatFixture.fork.id, itemID: assistantStarted.id, delta: "Use the narrow path.")
        )
        await waitUntil("Side-chat stream did not publish an atomic row hint") {
            model.sideChatTimeline.contains(where: {
                $0.id == assistantStarted.id && $0.body == "Use the narrow path."
            })
        }
        guard case let .rowsChanged(indices, fromRevision, toRevision)? =
            model.sideChatTranscriptSnapshot.changeHint else {
            return XCTFail("Expected the side-chat delta to publish a row-change hint")
        }
        XCTAssertEqual(indices, IndexSet(integer: model.sideChatTimeline.count - 1))
        XCTAssertEqual(toRevision, model.sideChatTranscriptSnapshot.revision)
        XCTAssertEqual(fromRevision + 1, toRevision)
        await fixture.runtime.emit(
            .itemCompleted(
                threadID: SideChatFixture.fork.id,
                item: SideChatFixture.item(
                    id: assistantStarted.id,
                    kind: .assistantMessage,
                    body: "Use the narrow path.",
                    status: .completed
                )
            )
        )
        await fixture.runtime.emit(.turnCompleted(threadID: SideChatFixture.fork.id, status: .idle))

        await waitUntil("Side-chat stream did not finish") {
            !model.isSideChatTurnRunning
                && model.sideChatTimeline.contains(where: { $0.id == assistantStarted.id && $0.body == "Use the narrow path." })
        }
        XCTAssertEqual(
            model.sideChatTimeline.filter { $0.kind == .userMessage && $0.body == userItem.body }.count,
            1,
            "The provider user event must replace, not duplicate, the optimistic row"
        )
        XCTAssertEqual(model.threads, durableThreadsBefore)
        XCTAssertEqual(model.timeline, durableTimelineBefore)
        XCTAssertFalse(model.threads.contains(where: { $0.id == SideChatFixture.fork.id }))
    }

    func testPastedImageInSideChatBecomesVisibleAttachmentAndTurnInput() async throws {
        let fixture = makeFixture(
            capabilities: [.streaming, .interruption, .images, .ephemeralThreadForking]
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Parent task did not load") {
            model.selectedThreadID == SideChatFixture.parent.id
        }
        model.openSideChat()
        await waitUntil("Fork did not open") {
            model.sideChatThreadID == SideChatFixture.fork.id
        }

        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 8).fill()
        image.unlockFocus()
        model.addPastedSideChatImages([image])

        await waitUntil("Pasted side-chat image did not finish preparing") {
            model.sideChatComposerImages.count == 1
        }
        XCTAssertEqual(model.sideChatComposerImages.count, 1)
        XCTAssertTrue(model.canSendSideChat, "An image-only side-chat message should be sendable")
        model.sendSideChat()

        await waitUntilAsync("Image turn did not reach the runtime") {
            await fixture.runtime.startTurnRequests().count == 1
        }
        let requests = await fixture.runtime.startTurnRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.inputs.count, 1)
        guard case let .imageURL(dataURL) = request.inputs[0] else {
            return XCTFail("Pasted side-chat image must be sent as an image input")
        }
        XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"))
        XCTAssertTrue(model.sideChatComposerImages.isEmpty)
        XCTAssertEqual(
            model.sideChatTimeline.last(where: { $0.kind == .userMessage })?.attachments.count,
            1
        )
    }

    func testSideChatKeepsDeltaThatArrivesBeforeMatchingItemStart() async {
        let fixture = makeFixture(capabilities: [.streaming, .interruption, .ephemeralThreadForking])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Parent task did not load") {
            model.selectedThreadID == SideChatFixture.parent.id
        }
        model.openSideChat()
        await waitUntil("Fork did not open") { model.sideChatThreadID == SideChatFixture.fork.id }

        await fixture.runtime.emit(
            .itemDelta(
                threadID: SideChatFixture.fork.id,
                itemID: "early-side-answer",
                delta: "Keep this early chunk."
            )
        )
        await waitUntil("Early side-chat delta did not render") {
            model.sideChatTimeline.contains {
                $0.id == "early-side-answer" && $0.body == "Keep this early chunk."
            }
        }

        await fixture.runtime.emit(
            .itemStarted(
                threadID: SideChatFixture.fork.id,
                item: SideChatFixture.item(
                    id: "early-side-answer",
                    kind: .assistantMessage,
                    body: "",
                    status: .running
                )
            )
        )
        await waitUntil("The matching start erased already-rendered side-chat text") {
            model.sideChatTimeline.contains {
                $0.id == "early-side-answer"
                    && $0.body == "Keep this early chunk."
                    && $0.timestamp == Date(timeIntervalSince1970: 1)
            }
        }
        XCTAssertEqual(
            model.sideChatTimeline.filter { $0.id == "early-side-answer" }.count,
            1
        )
    }

    func testNavigationClosesSideChatAndRejectsLateForkCompletion() async {
        let fixture = makeFixture(
            capabilities: [.streaming, .interruption, .ephemeralThreadForking],
            delayedFork: true
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Parent task did not load") {
            model.selectedThreadID == SideChatFixture.parent.id
        }
        model.openSideChat()
        await waitUntilAsync("Fork request did not start") {
            await fixture.runtime.forkRequests() == [SideChatFixture.parent.id]
        }
        XCTAssertTrue(model.isSideChatPresented)
        XCTAssertTrue(model.isSideChatLoading)

        model.selectThread(SideChatFixture.other.id)
        await waitUntil("Navigation did not clear the side chat") {
            model.selectedThreadID == SideChatFixture.other.id
                && !model.isSideChatPresented
                && model.sideChatThreadID == nil
                && model.sideChatTimeline.isEmpty
                && model.timeline == [SideChatFixture.otherItem]
        }

        await fixture.runtime.completeDelayedFork()
        await Task.yield()
        XCTAssertFalse(model.isSideChatPresented)
        XCTAssertNil(model.sideChatThreadID)
        XCTAssertEqual(model.timeline, [SideChatFixture.otherItem])
        XCTAssertFalse(model.threads.contains(where: { $0.id == SideChatFixture.fork.id }))
    }

    func testUnsupportedRuntimeDoesNotOfferOrAttemptSideChat() async {
        let fixture = makeFixture(capabilities: [.streaming, .interruption])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Parent task did not load") {
            model.selectedThreadID == SideChatFixture.parent.id
        }

        XCTAssertFalse(model.canOpenSideChat)
        model.openSideChat()
        await Task.yield()
        XCTAssertFalse(model.isSideChatPresented)
        let forkRequests = await fixture.runtime.forkRequests()
        XCTAssertEqual(forkRequests, [])
    }

    func testClosingRunningSideChatInterruptsForkAndDropsAllLocalState() async {
        let fixture = makeFixture(capabilities: [.streaming, .interruption, .ephemeralThreadForking])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Parent task did not load") {
            model.selectedThreadID == SideChatFixture.parent.id
        }
        model.openSideChat()
        await waitUntil("Fork did not open") { model.sideChatThreadID == SideChatFixture.fork.id }
        model.sideChatComposerText = "Keep this ephemeral"
        model.sendSideChat()
        await waitUntilAsync("Turn did not start") {
            await fixture.runtime.startTurnRequests().count == 1
        }

        model.closeSideChat()
        await waitUntilAsync("Closing did not interrupt the ephemeral fork") {
            await fixture.runtime.interruptRequests() == [SideChatFixture.fork.id]
        }
        XCTAssertFalse(model.isSideChatPresented)
        XCTAssertNil(model.sideChatParentThreadID)
        XCTAssertNil(model.sideChatThreadID)
        XCTAssertTrue(model.sideChatTimeline.isEmpty)
        XCTAssertEqual(model.sideChatComposerText, "")
        XCTAssertFalse(model.isSideChatTurnRunning)
        XCTAssertEqual(model.timeline, [SideChatFixture.parentItem])

        let lateInteraction = RuntimeUserInteraction(
            id: .string("late-side-approval"),
            threadID: SideChatFixture.fork.id,
            providerMethod: "item/commandExecution/requestApproval",
            title: "Late approval",
            detail: "This arrived after the panel closed.",
            kind: .approval(
                RuntimeApprovalPrompt(
                    subject: .command,
                    command: "pwd",
                    allowedDecisions: [.decline]
                )
            )
        )
        await fixture.runtime.emit(.userInteractionRequested(lateInteraction))
        await fixture.runtime.emit(
            .itemCompleted(
                threadID: SideChatFixture.fork.id,
                item: SideChatFixture.item(
                    id: "late-answer",
                    kind: .assistantMessage,
                    body: "Late output",
                    status: .completed
                )
            )
        )
        await Task.yield()
        XCTAssertTrue(model.pendingUserInteractions.isEmpty)
        XCTAssertEqual(model.timeline, [SideChatFixture.parentItem])
    }

    func testSideChatInteractionUsesFullResponseSurfaceWithoutLeakingToMainTask() async {
        let fixture = makeFixture(capabilities: [.streaming, .interruption, .approvals, .ephemeralThreadForking])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("Parent task did not load") {
            model.selectedThreadID == SideChatFixture.parent.id
        }
        model.openSideChat()
        await waitUntil("Fork did not open") { model.sideChatThreadID == SideChatFixture.fork.id }

        let interaction = RuntimeUserInteraction(
            id: .string("side-approval"),
            threadID: SideChatFixture.fork.id,
            providerMethod: "item/commandExecution/requestApproval",
            title: "Allow command?",
            detail: "The ephemeral branch wants to inspect context.",
            kind: .approval(
                RuntimeApprovalPrompt(
                    subject: .command,
                    command: "git status --short",
                    allowedDecisions: [.accept, .decline]
                )
            )
        )
        await fixture.runtime.emit(.userInteractionRequested(interaction))
        await waitUntil("Side interaction did not appear") {
            model.sideChatInteraction == interaction
        }

        XCTAssertNil(model.activeUserInteraction)
        XCTAssertTrue(model.pendingUserInteractions.isEmpty)
        model.respondToApproval(.accept, for: interaction)
        await waitUntilAsync("Side interaction response did not reach the runtime") {
            await fixture.runtime.interactionResponses().count == 1
        }
        await waitUntil("Side interaction was not cleared") {
            model.sideChatInteraction == nil && !model.isRespondingToSideChatInteraction
        }

        let responses = await fixture.runtime.interactionResponses()
        XCTAssertEqual(responses.first?.id, interaction.id)
        XCTAssertEqual(responses.first?.response, .approval(.accept))
        XCTAssertEqual(model.timeline, [SideChatFixture.parentItem])
        XCTAssertFalse(model.threads.contains(where: { $0.id == SideChatFixture.fork.id }))
    }

    private func makeFixture(
        capabilities: RuntimeCapabilities,
        delayedFork: Bool = false
    ) -> SideChatTestFixture {
        let suiteName = "OnyxSideChatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(SideChatFixture.parent.id, forKey: "Onyx.selectedThreadID")
        defaults.set("codex-window-model", forKey: "Onyx.selectedModelID")
        defaults.set("high", forKey: "Onyx.reasoningEffort")
        let runtime = SideChatTestRuntime(capabilities: capabilities, delayedFork: delayedFork)
        return SideChatTestFixture(
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

private struct SideChatTestFixture {
    let model: OnyxAppModel
    let runtime: SideChatTestRuntime
    let defaults: UserDefaults
    let suiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum SideChatFixture {
    static let parent = thread(id: "parent-thread", title: "Parent task", updatedAt: 2)
    static let other = thread(id: "other-thread", title: "Other task", updatedAt: 1)
    static let fork = thread(id: "ephemeral-side-thread", title: "Side chat", updatedAt: 3)
    static let parentItem = item(
        id: "parent-history",
        kind: .assistantMessage,
        body: "Parent context",
        status: .completed
    )
    static let otherItem = item(
        id: "other-history",
        kind: .assistantMessage,
        body: "Other context",
        status: .completed
    )

    static func thread(id: String, title: String, updatedAt: TimeInterval) -> RuntimeThread {
        RuntimeThread(
            id: id,
            title: title,
            preview: title,
            cwd: "/tmp/onyx-side-chat-tests",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            status: .idle,
            isPinned: false,
            runtime: .codex,
            model: "codex-side-model",
            branch: "main"
        )
    }

    static func item(
        id: String,
        kind: TimelineItemKind,
        body: String,
        status: TimelineItemStatus
    ) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: kind,
            title: nil,
            body: body,
            status: status,
            timestamp: Date(timeIntervalSince1970: 1),
            detail: nil
        )
    }
}

private actor SideChatTestRuntime: AgentRuntime {
    struct RecordedResponse: Sendable, Equatable {
        let id: RuntimeRequestID
        let response: RuntimeUserInteractionResponse
    }

    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let continuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let capabilities: RuntimeCapabilities
    private let delayedFork: Bool
    private var forkedParents: [String] = []
    private var turns: [StartTurnRequest] = []
    private var steeredThreads: [String] = []
    private var interruptedThreads: [String] = []
    private var responses: [RecordedResponse] = []
    private var delayedForkContinuation: CheckedContinuation<RuntimeConversation, any Error>?

    init(capabilities: RuntimeCapabilities, delayedFork: Bool) {
        self.capabilities = capabilities
        self.delayedFork = delayedFork
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        continuation.yield(.connectionChanged(.connected("Side chat test runtime")))
        return RuntimeSession(
            runtime: .codex,
            displayName: "Side chat test runtime",
            accountLabel: "Side chat tester",
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: .chatgpt,
                email: "side-chat@example.com",
                planLabel: nil,
                requiresAuthentication: true
            ),
            availableLoginMethods: [],
            availableModels: [
                RuntimeModel(
                    id: "codex-side-model",
                    displayName: "Codex Side Model",
                    description: nil,
                    isDefault: false,
                    defaultReasoningEffort: "high",
                    reasoningEfforts: ["medium", "high"]
                ),
                RuntimeModel(
                    id: "codex-window-model",
                    displayName: "Codex Window Model",
                    description: nil,
                    isDefault: true,
                    defaultReasoningEffort: "high",
                    reasoningEfforts: ["medium", "high"]
                ),
            ],
            capabilities: capabilities
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : [SideChatFixture.parent, SideChatFixture.other]
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        switch id {
        case SideChatFixture.parent.id:
            RuntimeConversation(thread: SideChatFixture.parent, items: [SideChatFixture.parentItem])
        case SideChatFixture.other.id:
            RuntimeConversation(thread: SideChatFixture.other, items: [SideChatFixture.otherItem])
        default:
            throw AgentRuntimeError.missingField("side-chat fixture thread \(id)")
        }
    }

    func forkEphemeralThread(id: String) async throws -> RuntimeConversation {
        forkedParents.append(id)
        if delayedFork {
            return try await withCheckedThrowingContinuation { delayedForkContinuation = $0 }
        }
        return RuntimeConversation(thread: SideChatFixture.fork, items: [SideChatFixture.parentItem])
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("durable thread creation in side-chat tests")
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        turns.append(request)
        continuation.yield(.turnStarted(threadID: request.threadID, turnID: "side-turn"))
    }

    func steer(threadID: String, text _: String) async throws {
        steeredThreads.append(threadID)
    }

    func interrupt(threadID: String) async throws {
        interruptedThreads.append(threadID)
    }

    func respond(to id: RuntimeRequestID, with response: RuntimeUserInteractionResponse) async throws {
        responses.append(RecordedResponse(id: id, response: response))
    }
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    func completeDelayedFork() {
        delayedForkContinuation?.resume(
            returning: RuntimeConversation(thread: SideChatFixture.fork, items: [SideChatFixture.parentItem])
        )
        delayedForkContinuation = nil
    }

    func emit(_ event: AgentRuntimeEvent) {
        continuation.yield(event)
    }

    func forkRequests() -> [String] { forkedParents }
    func startTurnRequests() -> [StartTurnRequest] { turns }
    func interruptRequests() -> [String] { interruptedThreads }
    func interactionResponses() -> [RecordedResponse] { responses }
}
