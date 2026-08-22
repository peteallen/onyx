import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelRaceTests: XCTestCase {
    func testLateInitialReadPreservesNewerLiveItemsCollaborationAndPlan() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let livePlan = RuntimePlan(
            turnID: "startup-live-turn",
            explanation: "Live work arrived while history was loading",
            steps: [RuntimePlanStep(text: "Keep the live update", status: .inProgress)]
        )
        let liveItem = TimelineItem(
            id: "startup-live-agent",
            kind: .tool,
            title: "Agent started",
            body: "Working while history loads",
            status: .running,
            timestamp: Date(timeIntervalSince1970: 20),
            detail: nil,
            collaboration: RuntimeCollaborationActivity(
                action: .interacted,
                agents: [RuntimeCollaborationAgent(
                    id: "startup-child",
                    path: "/root/startup_child",
                    status: .working,
                    message: "Working while history loads",
                    updatedAt: Date(timeIntervalSince1970: 20)
                )]
            )
        )

        await fixture.runtime.prepareSuspendedRead(for: Fixture.threadAID)
        model.start()
        await fixture.runtime.waitUntilReadIsSuspended(for: Fixture.threadAID)
        await waitUntil("The startup selection did not begin loading") {
            model.selectedThreadID == Fixture.threadAID && model.isLoadingThread
        }

        await fixture.runtime.emit(
            .turnStarted(threadID: Fixture.threadAID, turnID: livePlan.turnID)
        )
        await fixture.runtime.emit(.planUpdated(threadID: Fixture.threadAID, plan: livePlan))
        await fixture.runtime.emit(.itemCompleted(threadID: Fixture.threadAID, item: liveItem))
        await fixture.runtime.emit(.runtimeNotice(title: "Startup live events settled", detail: "Barrier"))
        await waitUntil("The live events did not arrive before the read completed") {
            model.notice?.title == "Startup live events settled"
                && model.selectedPlan == livePlan
                && model.collaborationAgents.first?.id == "startup-child"
        }

        await fixture.runtime.releaseSuspendedRead(for: Fixture.threadAID)
        await waitUntil("The delayed history read did not finish") {
            !model.isLoadingThread
        }

        XCTAssertTrue(model.timeline.contains(Fixture.itemA))
        XCTAssertTrue(model.timeline.contains(liveItem))
        XCTAssertTrue(model.timeline.contains { $0.id == "runtime-plan:\(livePlan.turnID)" })
        XCTAssertEqual(model.selectedPlan, livePlan)
        XCTAssertEqual(model.collaborationAgents.first?.id, "startup-child")
        XCTAssertEqual(model.collaborationAgents.first?.status, .working)
    }

    func testSendRemainsBoundToThreadSelectedWhenComposerWasSubmitted() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
                && model.timeline == [Fixture.itemA]
        }

        model.composerText = "Message intended for A"
        model.sendComposer()
        model.selectThread(Fixture.threadBID)

        let startedTurn = await firstStartedTurn(from: fixture.runtime)
        let request = try XCTUnwrap(startedTurn, "The composer never started a turn")
        XCTAssertEqual(request.threadID, Fixture.threadAID)
        XCTAssertEqual(request.text, "Message intended for A")
        XCTAssertEqual(model.selectedThreadID, Fixture.threadBID)
    }

    func testBufferedDeltaFromPreviousThreadCannotAppearInNewSelection() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
                && model.timeline == [Fixture.itemA]
        }

        await fixture.runtime.emit(
            .itemDelta(
                threadID: Fixture.threadAID,
                itemID: Fixture.sharedItemID,
                delta: Fixture.deltaFromA
            )
        )
        // AsyncStream preserves event order. This notice is an observable barrier
        // proving the preceding delta reached Onyx while A was still selected.
        await fixture.runtime.emit(.runtimeNotice(title: "Delta buffered", detail: "Barrier"))
        await waitUntil("The delta event did not reach the app model") {
            model.notice?.title == "Delta buffered"
        }

        model.selectThread(Fixture.threadBID)
        await waitUntil("Thread B did not finish loading") {
            model.selectedThreadID == Fixture.threadBID && model.timeline == [Fixture.itemB]
        }

        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.timeline, [Fixture.itemB])
        XCTAssertFalse(model.timeline.contains { $0.body.contains(Fixture.deltaFromA) })
    }

    func testBufferedDeltaMergesWithRefreshSnapshotExactlyOnceAndStaysWithinSelection() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
                && model.timeline == [Fixture.itemA]
                && !model.isLoadingThread
        }

        await fixture.runtime.setReadItems(
            [Fixture.refreshedItem],
            for: Fixture.threadAID
        )
        await fixture.runtime.prepareSuspendedRead(for: Fixture.threadAID)
        await fixture.runtime.emit(.threadRefreshRequested(threadID: Fixture.threadAID))
        await fixture.runtime.waitUntilReadIsSuspended(for: Fixture.threadAID)
        await waitUntil("The refresh did not begin loading") {
            model.selectedThreadID == Fixture.threadAID && model.isLoadingThread
        }

        await fixture.runtime.emit(
            .itemDelta(
                threadID: Fixture.threadAID,
                itemID: Fixture.sharedItemID,
                delta: Fixture.deltaDuringRefresh
            )
        )
        // This barrier proves the delta was handled while the read remained
        // suspended, before its 24 ms coalescing timer can normally fire.
        await fixture.runtime.emit(.runtimeNotice(title: "Refresh delta buffered", detail: "Barrier"))
        await waitUntil("The refresh delta did not reach the app model") {
            model.notice?.title == "Refresh delta buffered"
        }

        await fixture.runtime.releaseSuspendedRead(for: Fixture.threadAID)
        await waitUntil("The refreshed history did not finish loading") {
            !model.isLoadingThread
        }

        var expected = Fixture.refreshedItem
        expected.body += Fixture.deltaDuringRefresh
        XCTAssertEqual(model.timeline, [expected])

        // The pending buffer's scheduled flush must not append the same delta
        // a second time after snapshot application has consumed it.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.timeline, [expected])

        model.selectThread(Fixture.threadBID)
        await waitUntil("Thread B did not finish loading") {
            model.selectedThreadID == Fixture.threadBID
                && model.timeline == [Fixture.itemB]
                && !model.isLoadingThread
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.timeline, [Fixture.itemB])
        XCTAssertFalse(model.timeline.contains { $0.body.contains(Fixture.deltaDuringRefresh) })
    }

    func testInteractionForThreadSurvivesAwayAndBackSelection() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
        }
        model.selectThread(Fixture.threadBID)
        await waitUntil("Thread B did not finish loading") {
            model.selectedThreadID == Fixture.threadBID && model.timeline == [Fixture.itemB]
        }

        await fixture.runtime.emit(.userInteractionRequested(Fixture.interactionForB))
        await waitUntil("The interaction request did not reach the app model") {
            model.pendingUserInteractions.contains(Fixture.interactionForB)
        }
        XCTAssertEqual(model.activeUserInteraction, Fixture.interactionForB)

        model.selectThread(Fixture.threadAID)
        XCTAssertNil(model.activeUserInteraction)
        XCTAssertTrue(model.pendingUserInteractions.contains(Fixture.interactionForB))

        await fixture.runtime.emit(.userInteractionRequested(Fixture.interactionForA))
        await waitUntil("Thread A's interaction request did not reach the app model") {
            model.pendingUserInteractions.contains(Fixture.interactionForA)
        }
        XCTAssertEqual(model.activeUserInteraction, Fixture.interactionForA)
        XCTAssertTrue(model.pendingUserInteractions.contains(Fixture.interactionForB))

        model.selectThread(Fixture.threadBID)
        XCTAssertEqual(model.activeUserInteraction, Fixture.interactionForB)
        XCTAssertTrue(model.pendingUserInteractions.contains(Fixture.interactionForB))
        XCTAssertTrue(model.pendingUserInteractions.contains(Fixture.interactionForA))
    }

    func testTwoInteractionsOnSameThreadSurviveSuccessAndFailedResponseCanRetry() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await fixture.runtime.failResponseAttempts([2])
        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
        }

        await fixture.runtime.emit(.userInteractionRequested(Fixture.interactionForA))
        await fixture.runtime.emit(.userInteractionRequested(Fixture.secondInteractionForA))
        await waitUntil("The two interaction requests did not reach the app model") {
            model.pendingUserInteractions == [
                Fixture.interactionForA,
                Fixture.secondInteractionForA,
            ]
        }

        model.respond(to: Fixture.interactionForA, with: .approval(.accept))
        await waitUntil("Responding to the first interaction removed the second one") {
            model.pendingUserInteractions == [Fixture.secondInteractionForA]
                && model.respondingInteractionIDs.isEmpty
        }
        XCTAssertEqual(model.activeUserInteraction, Fixture.secondInteractionForA)

        model.respond(to: Fixture.secondInteractionForA, with: .approval(.decline))
        await waitUntil("The simulated response failure did not finish") {
            model.notice?.title == "Response failed"
                && model.respondingInteractionIDs.isEmpty
        }
        XCTAssertEqual(model.pendingUserInteractions, [Fixture.secondInteractionForA])
        XCTAssertEqual(model.activeUserInteraction, Fixture.secondInteractionForA)

        model.respond(to: Fixture.secondInteractionForA, with: .approval(.acceptForSession))
        await waitUntil("The failed interaction could not be retried") {
            model.pendingUserInteractions.isEmpty
                && model.respondingInteractionIDs.isEmpty
        }

        let attempts = await fixture.runtime.recordedResponses()
        XCTAssertEqual(
            attempts,
            [
                RecordedInteractionResponse(
                    id: Fixture.interactionForA.id,
                    response: .approval(.accept)
                ),
                RecordedInteractionResponse(
                    id: Fixture.secondInteractionForA.id,
                    response: .approval(.decline)
                ),
                RecordedInteractionResponse(
                    id: Fixture.secondInteractionForA.id,
                    response: .approval(.acceptForSession)
                ),
            ]
        )
    }

    func testDelayedNewThreadStartDoesNotStealNewerSelectionOrDraft() async throws {
        let fixture = makeFixture { defaults in
            defaults.set(Fixture.workspacePath, forKey: "Onyx.lastWorkspacePath")
        }
        defer { fixture.cleanUp() }
        let model = fixture.model

        await fixture.runtime.prepareDelayedThreadStart(returning: Fixture.createdThread)
        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
        }

        model.newTask()
        model.composerText = Fixture.initialNewThreadPrompt
        model.sendComposer()
        await waitUntilAsync("The new-thread request never reached the runtime") {
            await fixture.runtime.recordedStartThreadRequestCount() == 1
        }

        model.composerText = Fixture.createdThreadFollowUp
        model.setThreadListScope(.archived)
        await waitUntil("The archived task did not finish loading") {
            model.threadListScope == .archived
                && model.selectedThreadID == Fixture.archivedThreadID
                && model.timeline == [Fixture.archivedItem]
        }
        model.composerText = Fixture.unrelatedArchivedDraft

        await fixture.runtime.completeDelayedThreadStart()
        let startedTurn = await firstStartedTurn(from: fixture.runtime)
        XCTAssertEqual(startedTurn?.threadID, Fixture.createdThreadID)
        XCTAssertEqual(startedTurn?.text, Fixture.initialNewThreadPrompt)

        XCTAssertEqual(model.threadListScope, .archived)
        XCTAssertEqual(model.selectedThreadID, Fixture.archivedThreadID)
        XCTAssertEqual(model.composerText, Fixture.unrelatedArchivedDraft)
        XCTAssertEqual(model.timeline, [Fixture.archivedItem])

        let draftsAfterCreation = fixture.defaults.dictionary(forKey: "Onyx.composerDrafts") as? [String: String]
        XCTAssertEqual(draftsAfterCreation?[Fixture.createdThreadID], Fixture.createdThreadFollowUp)

        model.setThreadListScope(.active)
        await waitUntil("The created task did not restore its follow-up draft") {
            model.threadListScope == .active
                && model.selectedThreadID == Fixture.createdThreadID
                && model.composerText == Fixture.createdThreadFollowUp
        }

        let persistedDrafts = fixture.defaults.dictionary(forKey: "Onyx.composerDrafts") as? [String: String]
        XCTAssertEqual(persistedDrafts?[Fixture.archivedThreadID], Fixture.unrelatedArchivedDraft)
    }

    func testBlockingInteractionTakesPriorityOverEarlierNonblockingQuestion() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }

        await fixture.runtime.emit(.userInteractionRequested(Fixture.nonblockingQuestionForA))
        await waitUntil("The nonblocking question did not reach Onyx") {
            model.activeUserInteraction == Fixture.nonblockingQuestionForA
        }
        XCTAssertEqual(
            model.threads.first(where: { $0.id == Fixture.threadAID })?.status,
            .idle
        )
        XCTAssertEqual(model.selectedTaskAttention, .needsInput)
        XCTAssertFalse(model.isTurnRunning)

        await fixture.runtime.emit(.userInteractionRequested(Fixture.interactionForA))
        await waitUntil("The blocking approval did not take priority") {
            model.activeUserInteraction == Fixture.interactionForA
        }
        XCTAssertEqual(
            model.threads.first(where: { $0.id == Fixture.threadAID })?.status,
            .waitingForApproval
        )
        XCTAssertEqual(model.selectedTaskAttention, .needsApproval)
        XCTAssertTrue(model.pendingUserInteractions.contains(Fixture.nonblockingQuestionForA))
    }

    func testGlobalBlockingInteractionDisablesTaskActionsAndIsHiddenInArchivedScope() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }

        let globalInteraction = RuntimeUserInteraction(
            id: .string("global-approval"),
            threadID: nil,
            providerMethod: "item/commandExecution/requestApproval",
            title: "Approve command",
            detail: "Global provider request",
            kind: .approval(RuntimeApprovalPrompt(
                subject: .command,
                command: "echo test",
                supportsSessionApproval: false
            ))
        )
        await fixture.runtime.emit(.userInteractionRequested(globalInteraction))
        await waitUntil("The global interaction did not arrive") {
            model.activeUserInteraction == globalInteraction
        }

        let selected = try XCTUnwrap(model.selectedThread)
        XCTAssertFalse(model.canStartReview)
        XCTAssertFalse(model.canForkThread(selected))
        XCTAssertFalse(model.canCompactThread(selected))
        XCTAssertFalse(model.canArchiveThread(selected))

        model.setThreadListScope(.archived)
        await waitUntil("Archived scope did not load") {
            model.isShowingArchivedThreads && model.selectedThreadID == Fixture.archivedThreadID
        }
        XCTAssertNil(model.activeUserInteraction)
    }

    func testPlanUpdatesReplaceAuthoritativeChecklistAndCollaborationSummarizesAgents() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
                && model.timeline == [Fixture.itemA]
        }

        let firstPlan = RuntimePlan(
            turnID: "turn-plan",
            explanation: "Initial pass",
            steps: [RuntimePlanStep(text: "Inspect", status: .inProgress)]
        )
        let replacementPlan = RuntimePlan(
            turnID: "turn-plan",
            explanation: "Implementation pass",
            steps: [
                RuntimePlanStep(text: "Inspect", status: .completed),
                RuntimePlanStep(text: "Verify", status: .inProgress),
            ]
        )
        await fixture.runtime.emit(.turnStarted(threadID: Fixture.threadAID, turnID: "turn-plan"))
        await fixture.runtime.emit(.planUpdated(threadID: Fixture.threadAID, plan: firstPlan))
        await fixture.runtime.emit(.planUpdated(threadID: Fixture.threadAID, plan: replacementPlan))

        let collaborationItem = CodexProjection.timelineItem(
            from: .object([
                "type": .string("subAgentActivity"),
                "id": .string("agent-activity"),
                "agentThreadId": .string("child-thread"),
                "agentPath": .string("/root/protocol_hardening"),
                "kind": .string("started"),
            ])
        )
        await fixture.runtime.emit(
            .itemCompleted(threadID: Fixture.threadAID, item: collaborationItem)
        )

        await waitUntil("Plan and agent state did not reach the model") {
            model.selectedPlan == replacementPlan
                && model.collaborationAgents.first?.displayName == "Protocol Hardening"
        }

        XCTAssertEqual(model.timeline.filter { $0.id == "runtime-plan:turn-plan" }.count, 1)
        XCTAssertEqual(
            model.timeline.first(where: { $0.id == "runtime-plan:turn-plan" })?.body,
            "[x] Inspect\n[~] Verify"
        )
        XCTAssertEqual(model.collaborationAgents.first?.status, .working)
    }

    func testPlanUpdatesFromInactiveTurnsAreIgnoredAndReloadClearsLiveSnapshot() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.connectionState == .connected("Race test runtime")
                && model.selectedThreadID == Fixture.threadAID
                && model.timeline == [Fixture.itemA]
        }

        let oldPlan = RuntimePlan(
            turnID: "turn-old",
            explanation: nil,
            steps: [RuntimePlanStep(text: "Old work", status: .inProgress)]
        )
        let currentPlan = RuntimePlan(
            turnID: "turn-current",
            explanation: nil,
            steps: [RuntimePlanStep(text: "Current work", status: .inProgress)]
        )

        await fixture.runtime.emit(.turnStarted(threadID: Fixture.threadAID, turnID: oldPlan.turnID))
        await fixture.runtime.emit(.planUpdated(threadID: Fixture.threadAID, plan: oldPlan))
        await fixture.runtime.emit(.turnStarted(threadID: Fixture.threadAID, turnID: currentPlan.turnID))
        await fixture.runtime.emit(.planUpdated(threadID: Fixture.threadAID, plan: oldPlan))
        await fixture.runtime.emit(.planUpdated(threadID: Fixture.threadAID, plan: currentPlan))

        await waitUntil("The active turn plan did not win") {
            model.selectedPlan == currentPlan
        }

        await fixture.runtime.emit(.threadRefreshRequested(threadID: Fixture.threadAID))
        await waitUntil("The authoritative reload retained a stale live plan") {
            model.selectedPlan == nil && model.timeline == [Fixture.itemA]
        }
    }

    func testOlderCollaborationActivityCannotRegressCompletedAgent() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
                && !model.isLoadingThread
                && model.timeline == [Fixture.itemA]
        }

        let newer = Date(timeIntervalSince1970: 20)
        let older = Date(timeIntervalSince1970: 10)
        let completed = TimelineItem(
            id: "agent-completed",
            kind: .tool,
            title: "Agent completed",
            body: "Done",
            status: .completed,
            timestamp: newer,
            detail: nil,
            collaboration: RuntimeCollaborationActivity(
                action: .wait,
                agents: [RuntimeCollaborationAgent(
                    id: "child",
                    path: "/root/child",
                    status: .completed,
                    message: "Done",
                    updatedAt: newer
                )]
            )
        )
        let staleWorking = TimelineItem(
            id: "agent-stale",
            kind: .tool,
            title: "Agent working",
            body: "Still working",
            status: .running,
            timestamp: older,
            detail: nil,
            collaboration: RuntimeCollaborationActivity(
                action: .interacted,
                agents: [RuntimeCollaborationAgent(
                    id: "child",
                    path: "/root/child",
                    status: .working,
                    message: "Still working",
                    updatedAt: older
                )]
            )
        )

        await fixture.runtime.emit(.itemCompleted(threadID: Fixture.threadAID, item: completed))
        await fixture.runtime.emit(.itemCompleted(threadID: Fixture.threadAID, item: staleWorking))
        await fixture.runtime.emit(.runtimeNotice(title: "Collaboration settled", detail: "Barrier"))
        await waitUntil("The collaboration state did not settle") {
            model.notice?.title == "Collaboration settled"
        }

        XCTAssertEqual(model.collaborationAgents.first?.status, .completed)
        XCTAssertEqual(model.collaborationAgents.first?.message, "Done")
    }

    func testDisconnectDowngradesLiveAgentsAndLifecycleUpdateResortsRecentTasks() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
                && !model.isLoadingThread
                && model.timeline == [Fixture.itemA]
        }

        let working = CodexProjection.timelineItem(
            from: .object([
                "type": .string("subAgentActivity"),
                "id": .string("working-agent"),
                "agentThreadId": .string("child"),
                "agentPath": .string("/root/child"),
                "kind": .string("started"),
            ])
        )
        await fixture.runtime.emit(.itemCompleted(threadID: Fixture.threadAID, item: working))
        await fixture.runtime.emit(.threadStatusChanged(threadID: Fixture.threadBID, status: .running))
        await fixture.runtime.emit(.runtimeNotice(title: "Lifecycle settled", detail: "Barrier"))
        await waitUntil("The lifecycle update did not reorder recent tasks") {
            model.notice?.title == "Lifecycle settled"
        }
        XCTAssertEqual(model.threads.first?.id, Fixture.threadBID)
        XCTAssertEqual(model.collaborationAgents.first?.status, .working)

        await fixture.runtime.emit(.connectionChanged(.disconnected))
        await fixture.runtime.emit(.runtimeNotice(title: "Disconnect settled", detail: "Barrier"))
        await waitUntil("Disconnect left an agent marked live") {
            model.notice?.title == "Disconnect settled"
        }
        XCTAssertEqual(model.collaborationAgents.first?.status, .unavailable)
    }

    func testReplacedInteractionCannotSubmitStalePromptState() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }

        await fixture.runtime.emit(.userInteractionRequested(Fixture.interactionForA))
        await waitUntil("The first interaction did not arrive") {
            model.activeUserInteraction == Fixture.interactionForA
        }
        await fixture.runtime.emit(.userInteractionRequested(Fixture.replacementInteractionForA))
        await waitUntil("The replacement interaction did not arrive") {
            model.activeUserInteraction == Fixture.replacementInteractionForA
        }

        model.respond(to: Fixture.interactionForA, with: .approval(.accept))
        await Task.yield()
        let staleResponses = await fixture.runtime.recordedResponses()
        XCTAssertTrue(staleResponses.isEmpty)

        model.respond(to: Fixture.replacementInteractionForA, with: .approval(.decline))
        await waitUntilAsync("The replacement interaction was not submitted") {
            await fixture.runtime.recordedResponses().count == 1
        }
        let submittedResponses = await fixture.runtime.recordedResponses()
        XCTAssertEqual(
            submittedResponses.first,
            RecordedInteractionResponse(
                id: Fixture.replacementInteractionForA.id,
                response: .approval(.decline)
            )
        )
    }

    func testQuestionDraftSurvivesTaskSwitchAndResetsForReplacementPrompt() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }
        await fixture.runtime.emit(.userInteractionRequested(Fixture.questionForA))
        await waitUntil("The question did not arrive") {
            model.activeUserInteraction == Fixture.questionForA
        }

        let partial = RuntimeQuestionDraft(
            selections: ["workspace": "Current folder"],
            freeform: ["note": "keep this answer"],
            usesOther: ["note"]
        )
        model.updateQuestionDraft(partial, for: Fixture.questionForA)
        model.selectThread(Fixture.threadBID)
        model.selectThread(Fixture.threadAID)

        XCTAssertEqual(model.questionDraft(for: Fixture.questionForA), partial)

        await fixture.runtime.emit(.userInteractionRequested(Fixture.replacementQuestionForA))
        await waitUntil("The replacement question did not arrive") {
            model.activeUserInteraction == Fixture.replacementQuestionForA
        }
        XCTAssertEqual(
            model.questionDraft(for: Fixture.replacementQuestionForA),
            RuntimeQuestionDraft()
        )
    }

    func testFormDraftSurvivesTaskSwitchAndPurgesOnResolution() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }
        await fixture.runtime.emit(.userInteractionRequested(Fixture.formForA))
        await waitUntil("The form did not arrive") {
            model.activeUserInteraction == Fixture.formForA
        }

        var draft = model.formDraft(for: Fixture.formForA)
        XCTAssertEqual(draft.textValues["name"], "Default name")
        draft.textValues["name"] = "Partially typed"
        draft.boolValues["notify"] = true
        draft.touchedBoolFields.insert("notify")
        model.updateFormDraft(draft, for: Fixture.formForA)

        model.selectThread(Fixture.threadBID)
        model.selectThread(Fixture.threadAID)
        XCTAssertEqual(model.formDraft(for: Fixture.formForA), draft)

        await fixture.runtime.emit(.userInteractionResolved(Fixture.formForA.id))
        await waitUntil("The resolved form remained pending") {
            !model.pendingUserInteractions.contains(Fixture.formForA)
        }
        let reset = model.formDraft(for: Fixture.formForA)
        XCTAssertEqual(reset.textValues["name"], "Default name")
        XCTAssertNil(reset.boolValues["notify"])
    }

    func testBlockingInteractionPreventsProgrammaticComposerSend() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }
        await fixture.runtime.emit(.userInteractionRequested(Fixture.interactionForA))
        await waitUntil("The blocking interaction did not arrive") {
            model.activeUserInteraction == Fixture.interactionForA
        }

        model.composerText = "This must not become a turn while approval is pending"
        model.sendComposer()
        await Task.yield()

        let startedTurns = await fixture.runtime.recordedStartTurns()
        XCTAssertTrue(startedTurns.isEmpty)
        XCTAssertEqual(model.notice?.title, "Answer the pending request first")
        XCTAssertEqual(model.composerText, "This must not become a turn while approval is pending")
    }

    func testArchiveRejectsTaskWithPendingInteraction() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }
        await fixture.runtime.emit(.userInteractionRequested(Fixture.nonblockingQuestionForA))
        await waitUntil("The pending interaction did not arrive") {
            model.activeUserInteraction == Fixture.nonblockingQuestionForA
        }

        model.archive(Fixture.threadAID)
        await Task.yield()

        XCTAssertEqual(model.notice?.title, "Task is still active")
        XCTAssertTrue(model.threads.contains(where: { $0.id == Fixture.threadAID }))
        let archivedThreadIDs = await fixture.runtime.recordedArchivedThreadIDs()
        XCTAssertTrue(archivedThreadIDs.isEmpty)
    }

    func testExternalArchivePurgesPendingInteractionAndDraft() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await waitUntil("The runtime did not finish its initial load") {
            model.selectedThreadID == Fixture.threadAID
        }
        await fixture.runtime.emit(.userInteractionRequested(Fixture.questionForA))
        await waitUntil("The question did not arrive") {
            model.activeUserInteraction == Fixture.questionForA
        }
        model.updateQuestionDraft(
            RuntimeQuestionDraft(freeform: ["note": "discard me"]),
            for: Fixture.questionForA
        )

        await fixture.runtime.emit(.threadArchived(threadID: Fixture.threadAID))
        await waitUntil("The archived task's interaction remained actionable") {
            !model.pendingUserInteractions.contains(Fixture.questionForA)
        }

        XCTAssertEqual(model.questionDraft(for: Fixture.questionForA), RuntimeQuestionDraft())
    }

    private func makeFixture(
        configureDefaults: (UserDefaults) -> Void = { _ in }
    ) -> Fixture {
        let suiteName = "OnyxAppModelRaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        configureDefaults(defaults)
        let runtime = RaceTestRuntime()
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        return Fixture(
            model: model,
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

    private func firstStartedTurn(
        from runtime: RaceTestRuntime,
        timeout: Duration = .seconds(1)
    ) async -> StartTurnRequest? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let request = await runtime.recordedStartTurns().first {
                return request
            }
            await Task.yield()
        }
        return nil
    }
}

private struct Fixture {
    static let threadAID = "race-thread-A"
    static let threadBID = "race-thread-B"
    static let archivedThreadID = "race-thread-archived"
    static let createdThreadID = "race-thread-created"
    static let sharedItemID = "shared-stream-item"
    static let deltaFromA = " [buffered delta from A]"
    static let workspacePath = "/tmp/onyx-race-tests"
    static let initialNewThreadPrompt = "Build the new task"
    static let createdThreadFollowUp = "Follow up after the first turn"
    static let unrelatedArchivedDraft = "Draft for the archived task"

    static let threadA = makeThread(id: threadAID, title: "Thread A", updatedAt: 2)
    static let threadB = makeThread(id: threadBID, title: "Thread B", updatedAt: 1)
    static let archivedThread = makeThread(
        id: archivedThreadID,
        title: "Archived thread",
        updatedAt: 1
    )
    static let createdThread = makeThread(
        id: createdThreadID,
        title: "Created thread",
        updatedAt: 3
    )
    static let itemA = makeItem(body: "A history")
    static let itemB = makeItem(body: "B history")
    static let refreshedItem = makeItem(body: "A history from the refreshed snapshot")
    static let archivedItem = makeItem(body: "Archived history")
    static let deltaDuringRefresh = " [buffered refresh delta]"
    static let interactionForA = makeInteraction(
        id: "interaction-for-A",
        threadID: threadAID,
        title: "Run the A command?"
    )
    static let secondInteractionForA = makeInteraction(
        id: "second-interaction-for-A",
        threadID: threadAID,
        title: "Run another A command?"
    )
    static let replacementInteractionForA = RuntimeUserInteraction(
        id: interactionForA.id,
        threadID: threadAID,
        providerMethod: interactionForA.providerMethod,
        title: "Replacement approval for A",
        detail: "This newer request supersedes the previous prompt.",
        kind: interactionForA.kind
    )
    static let nonblockingQuestionForA = RuntimeUserInteraction(
        id: .string("nonblocking-question-for-A"),
        threadID: threadAID,
        providerMethod: "item/tool/requestUserInput",
        title: "Optional preference",
        detail: "This should not hide a later approval.",
        kind: .questions(
            RuntimeQuestionPrompt(
                questions: [
                    RuntimeQuestion(
                        id: "preference",
                        header: "Preference",
                        prompt: "Choose when convenient.",
                        options: [],
                        allowsOther: true,
                        isSecret: false
                    ),
                ],
                isBlocking: false
            )
        )
    )
    static let questionForA = RuntimeUserInteraction(
        id: .string("draft-question-for-A"),
        threadID: threadAID,
        providerMethod: "item/tool/requestUserInput",
        title: "A couple of details",
        detail: "These answers should survive navigation.",
        kind: .questions(
            RuntimeQuestionPrompt(
                questions: [
                    RuntimeQuestion(
                        id: "workspace",
                        header: "Workspace",
                        prompt: "Where should this run?",
                        options: [
                            RuntimeQuestionOption(label: "Current folder", detail: "Use this project"),
                        ],
                        allowsOther: false,
                        isSecret: false
                    ),
                    RuntimeQuestion(
                        id: "note",
                        header: "Note",
                        prompt: "Anything else?",
                        options: [],
                        allowsOther: true,
                        isSecret: false
                    ),
                ],
                isBlocking: true
            )
        )
    )
    static let replacementQuestionForA = RuntimeUserInteraction(
        id: questionForA.id,
        threadID: threadAID,
        providerMethod: questionForA.providerMethod,
        title: "Replacement question",
        detail: "This prompt must start clean.",
        kind: .questions(
            RuntimeQuestionPrompt(
                questions: [
                    RuntimeQuestion(
                        id: "replacement",
                        header: "Replacement",
                        prompt: "Choose again.",
                        options: [],
                        allowsOther: true,
                        isSecret: false
                    ),
                ],
                isBlocking: true
            )
        )
    )
    static let formForA = RuntimeUserInteraction(
        id: .string("draft-form-for-A"),
        threadID: threadAID,
        providerMethod: "mcpServer/elicitation/request",
        title: "Form",
        detail: "Fill out the form.",
        kind: .form(
            RuntimeFormPrompt(
                sourceName: "Test MCP",
                fields: [
                    RuntimeFormField(
                        id: "name",
                        label: "Name",
                        detail: nil,
                        isRequired: true,
                        kind: .text(format: nil),
                        initialValue: .string("Default name")
                    ),
                    RuntimeFormField(
                        id: "notify",
                        label: "Notify",
                        detail: nil,
                        isRequired: false,
                        kind: .toggle,
                        initialValue: nil
                    ),
                ]
            )
        )
    )
    static let interactionForB = makeInteraction(
        id: "interaction-for-B",
        threadID: threadBID,
        title: "Run the B command?"
    )

    let model: OnyxAppModel
    let runtime: RaceTestRuntime
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

    private static func makeItem(body: String) -> TimelineItem {
        TimelineItem(
            id: sharedItemID,
            kind: .assistantMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1),
            detail: nil
        )
    }

    private static func makeInteraction(
        id: String,
        threadID: String,
        title: String
    ) -> RuntimeUserInteraction {
        RuntimeUserInteraction(
            id: .string(id),
            threadID: threadID,
            providerMethod: "item/commandExecution/requestApproval",
            title: title,
            detail: "This request belongs only to \(threadID).",
            kind: .approval(
                RuntimeApprovalPrompt(
                    subject: .command,
                    command: "swift test",
                    supportsSessionApproval: true
                )
            )
        )
    }
}

private struct RecordedInteractionResponse: Sendable, Equatable {
    let id: RuntimeRequestID
    let response: RuntimeUserInteractionResponse
}

private actor RaceTestRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private var startTurns: [StartTurnRequest] = []
    private var startThreadRequests: [StartThreadRequest] = []
    private var createdThreads: [String: RuntimeThread] = [:]
    private var delayedThread: RuntimeThread?
    private var delayedThreadContinuation: CheckedContinuation<RuntimeThread, Never>?
    private var responseAttempts: [RecordedInteractionResponse] = []
    private var failingResponseAttempts: Set<Int> = []
    private var archivedThreadIDs: [String] = []
    private var readItemsByThreadID: [String: [TimelineItem]] = [:]
    private var readsToSuspend: Set<String> = []
    private var suspendedReadIDs: Set<String> = []
    private var suspendedReadContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var suspendedReadWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init() {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        eventContinuation.yield(.connectionChanged(.connected("Race test runtime")))
        return RuntimeSession(
            runtime: .codex,
            displayName: "Race test runtime",
            accountLabel: "Race test runtime",
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: .chatgpt,
                email: "race-tests@example.com",
                planLabel: nil,
                requiresAuthentication: true
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: [.streaming, .approvals]
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        if archived { return [Fixture.archivedThread] }
        return ([Fixture.threadA, Fixture.threadB] + createdThreads.values)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        if readsToSuspend.remove(id) != nil {
            await withCheckedContinuation { continuation in
                suspendedReadContinuations[id] = continuation
                suspendedReadIDs.insert(id)
                let waiters = suspendedReadWaiters.removeValue(forKey: id) ?? []
                for waiter in waiters { waiter.resume() }
            }
        }
        switch id {
        case Fixture.threadAID:
            return RuntimeConversation(
                thread: Fixture.threadA,
                items: readItemsByThreadID[id] ?? [Fixture.itemA]
            )
        case Fixture.threadBID:
            return RuntimeConversation(thread: Fixture.threadB, items: [Fixture.itemB])
        case Fixture.archivedThreadID:
            return RuntimeConversation(thread: Fixture.archivedThread, items: [Fixture.archivedItem])
        default:
            if let thread = createdThreads[id] {
                return RuntimeConversation(thread: thread, items: [])
            }
            throw AgentRuntimeError.missingField("test conversation for \(id)")
        }
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        try await readThread(id: id)
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        startThreadRequests.append(request)
        guard delayedThread != nil else {
            throw AgentRuntimeError.unsupported("starting a thread in race tests")
        }
        let thread = await withCheckedContinuation { continuation in
            delayedThreadContinuation = continuation
        }
        createdThreads[thread.id] = thread
        return thread
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        startTurns.append(request)
    }

    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {
        responseAttempts.append(RecordedInteractionResponse(id: interactionID, response: response))
        if failingResponseAttempts.contains(responseAttempts.count) {
            throw AgentRuntimeError.protocolFailure("simulated response failure")
        }
    }
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id: String) async throws {
        archivedThreadIDs.append(id)
    }
    func unarchiveThread(id _: String) async throws {}

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func prepareSuspendedRead(for threadID: String) {
        readsToSuspend.insert(threadID)
    }

    func setReadItems(_ items: [TimelineItem], for threadID: String) {
        readItemsByThreadID[threadID] = items
    }

    func waitUntilReadIsSuspended(for threadID: String) async {
        guard !suspendedReadIDs.contains(threadID) else { return }
        await withCheckedContinuation { continuation in
            suspendedReadWaiters[threadID, default: []].append(continuation)
        }
    }

    func releaseSuspendedRead(for threadID: String) {
        suspendedReadContinuations.removeValue(forKey: threadID)?.resume()
    }

    func recordedStartTurns() -> [StartTurnRequest] {
        startTurns
    }

    func recordedStartThreadRequestCount() -> Int {
        startThreadRequests.count
    }

    func prepareDelayedThreadStart(returning thread: RuntimeThread) {
        delayedThread = thread
    }

    func completeDelayedThreadStart() {
        guard let thread = delayedThread, let continuation = delayedThreadContinuation else { return }
        delayedThread = nil
        delayedThreadContinuation = nil
        continuation.resume(returning: thread)
    }

    func failResponseAttempts(_ attempts: Set<Int>) {
        failingResponseAttempts = attempts
    }

    func recordedResponses() -> [RecordedInteractionResponse] {
        responseAttempts
    }

    func recordedArchivedThreadIDs() -> [String] {
        archivedThreadIDs
    }
}
