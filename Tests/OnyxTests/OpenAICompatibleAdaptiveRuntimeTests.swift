import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleAdaptiveRuntimeTests: XCTestCase {
    func testConnectHydratesOwnersBeforeBufferedLaneEventsAndMergedCatalogKeepsRawIDCollisionDistinct() async throws {
        let rawID = "same-provider-thread"
        let agentID = publicAgentThreadID(rawID)
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            threads: [makeAdaptiveThread(id: rawID, title: "Chat", updatedAt: 20)],
            connectEvents: [.threadNameChanged(threadID: rawID, name: "Chat restored")]
        )
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID, title: "Agent", updatedAt: 10)],
            connectEvents: [.threadNameChanged(threadID: rawID, name: "Agent restored")]
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [agent],
            ownerships: [
                (rawID, .chat, "chat-model"),
                (agentID, .agent, "agent-model"),
            ]
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }

        _ = try await harness.runtime.connect()
        try await eventually("chat connect event") {
            await eventLog.events().contains {
                if case let .threadNameChanged(id, _) = $0 { return id == rawID }
                return false
            }
        }

        let catalog = try await harness.runtime.listAllThreads(archived: false)
        try await eventually("agent connect event") {
            await eventLog.events().contains {
                if case let .threadNameChanged(id, _) = $0 { return id == agentID }
                return false
            }
        }

        XCTAssertEqual(Set(catalog.map(\.id)), Set([rawID, agentID]))
        XCTAssertEqual(catalog.map(\.title), ["Chat", "Agent"])
        let agentCalls = await agent.invocations()
        XCTAssertLessThan(
            try XCTUnwrap(agentCalls.firstIndex { $0.name == .connect }),
            try XCTUnwrap(agentCalls.firstIndex { $0.name == .listAllThreads })
        )
        XCTAssertEqual(harness.factory.preparationCount, 1)

        await harness.runtime.disconnect()
    }

    func testStalledAgentTurnFailsInPlaceAndNextAttemptUsesCleanPrivateLane() async throws {
        let rawID = "stalled-agent-turn"
        let publicID = publicAgentThreadID(rawID)
        let chat = AdaptiveRuntimeFake(kind: .local)
        let stalledAgent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID, model: "agent-model")]
        )
        let replacementAgent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID, model: "agent-model")]
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [stalledAgent, replacementAgent],
            ownerships: [(publicID, .agent, "agent-model")],
            turnLivenessPolicy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .milliseconds(60)
            )
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }

        _ = try await harness.runtime.connect()
        try await harness.runtime.startTurn(.init(
            threadID: publicID,
            inputs: [.text("Do not leave this task working forever")],
            model: "agent-model"
        ))
        await stalledAgent.emit(.turnStarted(threadID: rawID, turnID: "stalled-turn"))

        try await eventually("friendly stalled-turn failure") {
            await eventLog.events().contains { event in
                guard case let .itemCompleted(threadID, item) = event else { return false }
                return threadID == publicID
                    && item.id.hasPrefix("onyx-provider-liveness:")
                    && item.title == "Model stopped responding"
                    && item.body.contains("choose another model")
            }
        }
        let failedEvents = await eventLog.events()
        XCTAssertTrue(failedEvents.contains(
            .threadStatusChanged(threadID: publicID, status: .failed)
        ))
        XCTAssertTrue(failedEvents.contains(
            .turnCompleted(threadID: publicID, status: .failed)
        ))
        XCTAssertFalse(failedEvents.contains { event in
            if case .connectionChanged(.failed) = event { return true }
            return false
        }, "A dead private lane must not disconnect the visible provider")
        try await eventually("stalled private proxy retirement") {
            harness.factory.proxyStopCount == 1
        }

        try await harness.runtime.startTurn(.init(
            threadID: publicID,
            inputs: [.text("Retry with a clean lane")],
            model: "agent-model"
        ))
        await replacementAgent.emit(.turnStarted(threadID: rawID, turnID: "retry-turn"))
        await replacementAgent.emit(.turnCompleted(threadID: rawID, status: .idle))

        XCTAssertEqual(harness.factory.preparationCount, 2)
        let replacementStartTurnIDs = await replacementAgent.threadIDs(for: .startTurn)
        XCTAssertEqual(replacementStartTurnIDs, [rawID])
        await harness.runtime.disconnect()
    }

    func testEndedAgentEventLaneFailsInPlaceAndNextAttemptUsesCleanPrivateLane() async throws {
        let rawID = "ended-agent-lane"
        let publicID = publicAgentThreadID(rawID)
        let first = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID, model: "agent-model")]
        )
        let replacement = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID, model: "agent-model")]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [first, replacement],
            ownerships: [(publicID, .agent, "agent-model")],
            turnLivenessPolicy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .seconds(10)
            )
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }

        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.readThread(id: publicID)
        await first.emit(.turnStarted(threadID: rawID, turnID: "ended-turn"))
        try await eventually("agent turn start was not observed") {
            await eventLog.events().contains(
                .turnStarted(threadID: publicID, turnID: "ended-turn")
            )
        }

        // The wrapped app-server lane can terminate without a connection
        // notification (for example, a dropped SSE stream). The liveness
        // boundary must materialize one attached failure and retire only the
        // private lane so a subsequent turn gets a fresh runtime.
        await first.finishEvents()
        try await eventually("ended agent lane did not fail the active turn") {
            await eventLog.events().contains { event in
                guard case let .itemCompleted(threadID, item) = event else { return false }
                return threadID == publicID
                    && item.id.hasPrefix("onyx-provider-liveness:")
                    && item.title == "Model stopped responding"
            }
        }
        try await eventually("ended agent lane was not retired") {
            harness.factory.proxyStopCount == 1
        }

        try await harness.runtime.startTurn(.init(
            threadID: publicID,
            inputs: [.text("Retry after EOF")],
            model: "agent-model"
        ))
        await replacement.emit(.turnStarted(threadID: rawID, turnID: "replacement-turn"))
        await replacement.emit(.turnCompleted(threadID: rawID, status: .idle))

        XCTAssertEqual(harness.factory.preparationCount, 2)
        let replacementStartTurnIDs = await replacement.threadIDs(for: .startTurn)
        XCTAssertEqual(replacementStartTurnIDs, [rawID])
        let events = await eventLog.events()
        XCTAssertTrue(events.contains(
            .turnCompleted(threadID: publicID, status: .failed)
        ))
        XCTAssertFalse(events.contains { event in
            if case .connectionChanged(.failed) = event { return true }
            return false
        }, "Private EOF must not disconnect the visible provider")

        await harness.runtime.disconnect()
    }

    @MainActor
    func testStalledAgentTurnEndsWorkingAndOffersAttachedRetryInAppModel() async throws {
        let rawID = "stalled-agent-app-model"
        let publicID = publicAgentThreadID(rawID)
        let thread = makeAdaptiveThread(id: rawID, model: "agent-model")
        let previousUser = TimelineItem(
            id: "previous-user",
            kind: .userMessage,
            title: nil,
            body: "Earlier prompt",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        let previousAnswer = makeAdaptiveItem(id: "previous-answer", body: "Earlier answer")
        let conversation = RuntimeConversation(
            thread: thread,
            items: [previousUser, previousAnswer],
            turns: [
                RuntimeConversationTurn(
                    id: "previous-turn",
                    items: [previousUser, previousAnswer],
                    status: .completed,
                    itemDetail: .full,
                    startedAt: .now,
                    completedAt: .now,
                    durationMilliseconds: 1
                ),
            ]
        )
        let chat = AdaptiveRuntimeFake(kind: .local)
        let stalledAgent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [thread],
            conversations: [rawID: conversation]
        )
        let replacementAgent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [thread],
            conversations: [rawID: conversation]
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [stalledAgent, replacementAgent],
            ownerships: [(publicID, .agent, "agent-model")],
            turnLivenessPolicy: OpenAICompatibleAgentTurnLivenessPolicy(
                inactivityTimeout: .milliseconds(60)
            )
        )
        defer { harness.removeTemporaryState() }
        let suiteName = "OpenAICompatibleAdaptiveRuntimeTests.liveness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OnyxAppModel(runtime: harness.runtime, defaults: defaults)

        model.start()
        for _ in 0..<400 {
            if model.selectedThreadID == publicID && !model.isLoadingThread { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.selectedThreadID, publicID)
        XCTAssertFalse(model.isLoadingThread)

        model.composerText = "Please retry this exact work"
        model.sendComposer()
        // Reproduce compatible endpoints that accept the request but never
        // publish an upstream turn-start notification before stalling. The
        // liveness boundary must still create a failed loaded turn so Retry is
        // attached to this optimistic user message.
        for _ in 0..<400 {
            if model.retryableFailedResponseItemID != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(model.isTurnRunning)
        XCTAssertEqual(model.selectedThread?.status, .failed)
        let failureID = try XCTUnwrap(model.retryableFailedResponseItemID)
        let failure = try XCTUnwrap(model.timeline.first(where: { $0.id == failureID }))
        XCTAssertEqual(failure.title, "Model stopped responding")
        XCTAssertTrue(failure.body.contains("Retry this response"))
        XCTAssertTrue(failure.body.contains("choose another model"))
        XCTAssertNotNil(model.retryUserMessageID(forFailedResponseItemID: failureID))
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.canRunAgent)

        await harness.runtime.disconnect()
    }

    func testTaskOperationsAlwaysRouteToTheDurableOwner() async throws {
        let chatRawID = "chat-owned"
        let agentRawID = "agent-owned"
        let agentID = publicAgentThreadID(agentRawID)
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            threads: [makeAdaptiveThread(id: chatRawID, model: "chat-model")],
            forkResult: makeAdaptiveThread(id: "chat-fork", model: "chat-model")
        )
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: agentRawID, model: "agent-model")],
            forkResult: makeAdaptiveThread(id: "agent-fork", model: "agent-model"),
            ephemeralResult: RuntimeConversation(
                thread: makeAdaptiveThread(id: "agent-side-chat", model: "agent-model"),
                items: []
            )
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [agent],
            ownerships: [
                (chatRawID, .chat, "chat-model"),
                (agentID, .agent, "agent-model"),
            ]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        _ = try await harness.runtime.readThread(id: chatRawID)
        _ = try await harness.runtime.readThread(id: agentID)
        _ = try await harness.runtime.resumeThread(id: chatRawID)
        _ = try await harness.runtime.resumeThread(id: agentID)
        _ = try await harness.runtime.revertThread(id: chatRawID, beforeTurnID: "chat-turn")
        _ = try await harness.runtime.revertThread(id: agentID, beforeTurnID: "agent-turn")

        let chatFork = try await harness.runtime.forkThread(id: chatRawID)
        let agentFork = try await harness.runtime.forkThread(id: agentID)
        XCTAssertEqual(chatFork.id, "chat-fork")
        XCTAssertEqual(agentFork.id, publicAgentThreadID("agent-fork"))

        let sideChat = try await harness.runtime.forkEphemeralThread(id: agentID)
        XCTAssertEqual(sideChat.thread.id, publicAgentThreadID("agent-side-chat"))

        try await harness.runtime.compactThread(id: chatRawID)
        try await harness.runtime.compactThread(id: agentID)
        try await harness.runtime.startTurn(.init(
            threadID: chatRawID,
            inputs: [.text("chat")],
            model: "chat-model"
        ))
        try await harness.runtime.startTurn(.init(
            threadID: agentID,
            inputs: [.text("agent")],
            model: "agent-model"
        ))

        let chatReview = try await harness.runtime.startReview(.init(threadID: chatRawID))
        let agentReview = try await harness.runtime.startReview(.init(threadID: agentID))
        XCTAssertEqual(chatReview.threadID, chatRawID)
        XCTAssertEqual(agentReview.threadID, agentID)

        try await harness.runtime.steer(threadID: chatRawID, text: "chat steer")
        try await harness.runtime.steer(threadID: agentID, text: "agent steer")
        try await harness.runtime.steer(threadID: chatRawID, inputs: [.text("chat inputs")])
        try await harness.runtime.steer(threadID: agentID, inputs: [.text("agent inputs")])
        try await harness.runtime.interrupt(threadID: chatRawID)
        try await harness.runtime.interrupt(threadID: agentID)
        try await harness.runtime.renameThread(id: chatRawID, name: "Chat renamed")
        try await harness.runtime.renameThread(id: agentID, name: "Agent renamed")
        try await harness.runtime.archiveThread(id: chatRawID)
        try await harness.runtime.archiveThread(id: agentID)
        try await harness.runtime.unarchiveThread(id: chatRawID)
        try await harness.runtime.unarchiveThread(id: agentID)

        let routedNames: Set<AdaptiveRuntimeInvocation.Name> = [
            .readThread, .resumeThread, .revertThread, .forkThread, .compactThread,
            .startTurn, .startReview, .steerText, .steerInputs, .interrupt,
            .renameThread, .archiveThread, .unarchiveThread,
        ]
        let chatInvocations = await chat.invocations()
        let agentInvocations = await agent.invocations()
        let chatRoutedIDs = Set(
            chatInvocations.filter { routedNames.contains($0.name) }.compactMap(\.threadID)
        )
        let agentRoutedIDs = Set(
            agentInvocations.filter { routedNames.contains($0.name) }.compactMap(\.threadID)
        )
        let chatEphemeralIDs = await chat.threadIDs(for: .forkEphemeralThread)
        let agentEphemeralIDs = await agent.threadIDs(for: .forkEphemeralThread)
        XCTAssertEqual(chatRoutedIDs, [chatRawID])
        XCTAssertEqual(agentRoutedIDs, [agentRawID])
        XCTAssertEqual(chatEphemeralIDs, [])
        XCTAssertEqual(agentEphemeralIDs, [agentRawID])

        try await harness.runtime.deleteThread(id: chatRawID)
        try await harness.runtime.deleteThread(id: agentID)
        let chatDeletedIDs = await chat.threadIDs(for: .deleteThread)
        let agentDeletedIDs = await agent.threadIDs(for: .deleteThread)
        let removedChatOwner = try await harness.stateStore.taskOwnership(
            connectionID: harness.connection.id,
            conversationScopeID: harness.connection.conversationScopeID,
            threadID: chatRawID
        )
        let removedAgentOwner = try await harness.stateStore.taskOwnership(
            connectionID: harness.connection.id,
            conversationScopeID: harness.connection.conversationScopeID,
            threadID: agentID
        )
        XCTAssertEqual(chatDeletedIDs, [chatRawID])
        XCTAssertEqual(agentDeletedIDs, [agentRawID])
        XCTAssertNil(removedChatOwner)
        XCTAssertNil(removedAgentOwner)

        await harness.runtime.disconnect()
    }

    func testPaginatedChatReadAndResumeDecodeReservedRawIDsAndReprojectTheConversation() async throws {
        for rawID in ["onyx.agent.raw-chat-id", "onyx.chat.raw-chat-id"] {
            let publicID = publicChatThreadID(rawID)
            let chat = AdaptiveRuntimeFake(
                kind: .local,
                threads: [makeAdaptiveThread(id: rawID, model: "chat-model")]
            )
            let harness = try await makeAdaptiveHarness(
                chat: chat,
                agents: [],
                ownerships: [(publicID, .chat, "chat-model")]
            )
            defer { harness.removeTemporaryState() }
            _ = try await harness.runtime.connect()

            let read = try await harness.runtime.readThread(
                id: publicID,
                initialHistoryPage: RuntimeThreadHistoryPageRequest(limit: 5)
            )
            let resumed = try await harness.runtime.resumeThread(
                id: publicID,
                initialHistoryPage: RuntimeInitialThreadHistoryPageRequest(limit: 5)
            )

            let paginatedReadIDs = await chat.threadIDs(for: .readThread)
            let paginatedResumeIDs = await chat.threadIDs(for: .resumeThread)
            XCTAssertEqual(paginatedReadIDs, [rawID])
            XCTAssertEqual(paginatedResumeIDs, [rawID])
            XCTAssertEqual(read.conversation.thread.id, publicID)
            XCTAssertEqual(resumed.conversation.thread.id, publicID)
            XCTAssertTrue(read.conversation.thread.taskCapabilities?.contains(.tools) == false)
            XCTAssertTrue(resumed.conversation.thread.taskCapabilities?.contains(.tools) == false)

            await harness.runtime.disconnect()
        }
    }

    func testSwitchingAgentTaskModelDoesNotWaitForOrStartProbe() async throws {
        let rawID = "agent-model-switch"
        let agentID = publicAgentThreadID(rawID)
        let now = Date(timeIntervalSince1970: 50_000)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["verified-model": .compatible(adaptiveCompatibleEvidence)],
            testedAt: now
        )
        let chat = AdaptiveRuntimeFake(kind: .local)
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID, model: "original-model")]
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [agent],
            ownerships: [(agentID, .agent, "original-model")],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        try await harness.runtime.startTurn(.init(
            threadID: agentID,
            inputs: [.text("continue with the selected model")],
            model: "verified-model"
        ))
        let probedModelIDs = await probe.modelIDs()
        let acceptedTurnIDs = await agent.threadIDs(for: .startTurn)
        XCTAssertEqual(probedModelIDs, [])
        XCTAssertEqual(acceptedTurnIDs, [rawID])
        let owner = try await harness.stateStore.taskOwnership(
            connectionID: harness.connection.id,
            conversationScopeID: harness.connection.conversationScopeID,
            threadID: agentID
        )
        XCTAssertEqual(owner?.lane, .agent)
        XCTAssertEqual(owner?.modelID, "verified-model")

        await harness.runtime.disconnect()
    }

    func testFailedDiagnosticProbeCannotBlockAgentTaskModelSwitch() async throws {
        let rawID = "agent-incompatible-model-switch"
        let agentID = publicAgentThreadID(rawID)
        let now = Date(timeIntervalSince1970: 50_500)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["chat-model": .failed(.missingFunctionCall)],
            testedAt: now
        )
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID, model: "original-model")]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [agent],
            ownerships: [(agentID, .agent, "original-model")],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }
        try await harness.resolver.beginProbe(
            connection: harness.connection,
            modelID: "chat-model"
        )
        try await eventually("failed diagnostic probe is recorded") {
            guard let decision = try? await harness.resolver.resolveNewTask(
                connection: harness.connection,
                modelID: "chat-model"
            ) else { return false }
            return decision.basis == .failedProbe(.missingFunctionCall)
        }
        _ = try await harness.runtime.connect()

        try await harness.runtime.startTurn(.init(
            threadID: agentID,
            inputs: [.text("continue despite the diagnostic result")],
            model: "chat-model"
        ))

        let dispatchedTurnIDs = await agent.threadIDs(for: .startTurn)
        XCTAssertEqual(dispatchedTurnIDs, [rawID])
        let owner = try await harness.stateStore.taskOwnership(
            connectionID: harness.connection.id,
            conversationScopeID: harness.connection.conversationScopeID,
            threadID: agentID
        )
        XCTAssertEqual(owner?.modelID, "chat-model")

        await harness.runtime.disconnect()
    }

    func testAgentLaneProjectsSelectedModelCapabilitiesAndRejectsUnsupportedInputs() async throws {
        let rawID = "text-only-agent"
        let publicID = publicAgentThreadID(rawID)
        let now = Date(timeIntervalSince1970: 55_000)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["agent-model": .compatible(adaptiveCompatibleEvidence)],
            testedAt: now
        )
        let textOnlyModel = makeAdaptiveModel(
            id: "agent-model",
            isDefault: true,
            inputModalities: [.text],
            reasoningEfforts: [],
            capabilityEvidence: .advertised
        )
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            models: [textOnlyModel],
            threads: [makeAdaptiveThread(id: rawID, model: "agent-model")]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local, models: [textOnlyModel]),
            agents: [agent],
            ownerships: [(publicID, .agent, "agent-model")],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }

        let session = try await harness.runtime.connect()
        let model = try XCTUnwrap(session.availableModels.first)
        XCTAssertFalse(model.taskCapabilities?.contains(.images) == true)
        XCTAssertFalse(model.taskCapabilities?.contains(.reasoning) == true)

        let conversation = try await harness.runtime.readThread(id: publicID)
        XCTAssertFalse(conversation.thread.taskCapabilities?.contains(.images) == true)
        XCTAssertFalse(conversation.thread.taskCapabilities?.contains(.reasoning) == true)

        do {
            try await harness.runtime.startTurn(.init(
                threadID: publicID,
                inputs: [.localImagePath("/tmp/unsupported.png")],
                model: "agent-model"
            ))
            XCTFail("A text-only model must reject image input before dispatch")
        } catch let error as AgentRuntimeError {
            XCTAssertTrue(error.localizedDescription.contains("image input"))
        }
        do {
            try await harness.runtime.startTurn(.init(
                threadID: publicID,
                inputs: [.text("reasoning should fail")],
                model: "agent-model",
                reasoningEffort: "medium"
            ))
            XCTFail("A model without reasoning metadata must reject an effort")
        } catch let error as AgentRuntimeError {
            XCTAssertTrue(error.localizedDescription.contains("reasoning effort"))
        }
        let dispatchedTurnIDs = await agent.threadIDs(for: .startTurn)
        XCTAssertEqual(dispatchedTurnIDs, [])

        await harness.runtime.disconnect()
    }

    func testAgentLaneRejectsTextForModelWithoutTextModality() async throws {
        let rawID = "image-only-agent"
        let publicID = publicAgentThreadID(rawID)
        let now = Date(timeIntervalSince1970: 56_000)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["image-model": .compatible(adaptiveCompatibleEvidence)],
            testedAt: now
        )
        let imageOnlyModel = makeAdaptiveModel(
            id: "image-model",
            isDefault: true,
            inputModalities: [.image],
            capabilityEvidence: .advertised
        )
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            models: [imageOnlyModel],
            threads: [makeAdaptiveThread(id: rawID, model: "image-model")]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local, models: [imageOnlyModel]),
            agents: [agent],
            ownerships: [(publicID, .agent, "image-model")],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }

        _ = try await harness.runtime.connect()
        do {
            try await harness.runtime.startTurn(.init(
                threadID: publicID,
                inputs: [.text("unsupported text")],
                model: "image-model"
            ))
            XCTFail("A model without text input must reject text before dispatch")
        } catch let error as AgentRuntimeError {
            XCTAssertTrue(error.localizedDescription.contains("text input"))
        }
        let dispatchedTurnIDs = await agent.threadIDs(for: .startTurn)
        XCTAssertEqual(dispatchedTurnIDs, [])

        await harness.runtime.disconnect()
    }

    func testConnectProjectsEveryGenericModelAsAgentWithoutStartingProbe() async throws {
        let now = Date(timeIntervalSince1970: 60_000)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["agent-model": .compatible(adaptiveCompatibleEvidence)],
            testedAt: now
        )
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            models: [
                makeAdaptiveModel(id: "agent-model", isDefault: true),
                makeAdaptiveModel(id: "large-catalog-model"),
            ]
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }
        let session = try await harness.runtime.connect()
        XCTAssertEqual(session.availableModels.map(\.executionMode), [.agent, .agent])
        try await Task.sleep(for: .milliseconds(20))
        let probedModelIDs = await probe.modelIDs()
        XCTAssertEqual(probedModelIDs, [])

        await harness.runtime.disconnect()
    }

    func testFirstMetadataPoorTaskStartsAgentImmediatelyWithoutProbe() async throws {
        let now = Date(timeIntervalSince1970: 65_000)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["agent-model": .compatible(adaptiveCompatibleEvidence)],
            testedAt: now
        )
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            models: [makeAdaptiveModel(id: "agent-model", isDefault: true)]
        )
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            startThreadResult: makeAdaptiveThread(
                id: "first-capable-task",
                model: "agent-model"
            )
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [agent],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }

        let session = try await harness.runtime.connect()
        XCTAssertEqual(session.availableModels.first?.executionMode, .agent)
        let thread = try await harness.runtime.startThread(.init(
            cwd: "/tmp/project",
            model: "agent-model"
        ))
        XCTAssertEqual(thread.id, publicAgentThreadID("first-capable-task"))
        let chatInvocations = await chat.invocations()
        let agentInvocations = await agent.invocations()
        XCTAssertFalse(chatInvocations.contains { $0.name == .startThread })
        XCTAssertEqual(
            agentInvocations.filter { $0.name == .startThread }.count,
            1
        )
        let probedModelIDs = await probe.modelIDs()
        XCTAssertEqual(probedModelIDs, [])

        await harness.runtime.disconnect()
    }

    func testAgentCreationEventIsQuarantinedUntilOwnershipCommitThenReplayed() async throws {
        let now = Date(timeIntervalSince1970: 70_000)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["agent-model": .compatible(adaptiveCompatibleEvidence)],
            testedAt: now
        )
        let startGate = AdaptiveAsyncGate()
        let rawID = "new-agent-task"
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            startThreadResult: makeAdaptiveThread(id: rawID, model: "agent-model"),
            startThreadEvents: [
                .itemStarted(
                    threadID: rawID,
                    item: makeAdaptiveItem(id: "first-output", body: "Started")
                ),
            ],
            startThreadGate: startGate
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [agent],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }

        let creation = Task {
            try await harness.runtime.startThread(.init(cwd: "/tmp/project", model: "agent-model"))
        }
        try await eventually("agent startThread call") {
            await agent.invocations().contains { $0.name == .startThread }
        }
        try await Task.sleep(for: .milliseconds(50))
        let eventsBeforeOwnership = await eventLog.events()
        XCTAssertFalse(eventsBeforeOwnership.contains {
            if case .itemStarted = $0 { return true }
            return false
        })

        await startGate.open()
        let thread = try await creation.value
        XCTAssertEqual(thread.id, publicAgentThreadID(rawID))
        try await eventually("buffered creation event replay") {
            await eventLog.events().contains { event in
                guard case let .itemStarted(threadID, item) = event else { return false }
                return threadID == publicAgentThreadID(rawID) && item.id == "first-output"
            }
        }
        let createdOwner = try await harness.stateStore.taskOwnership(
            connectionID: harness.connection.id,
            conversationScopeID: harness.connection.conversationScopeID,
            threadID: publicAgentThreadID(rawID)
        )
        XCTAssertEqual(createdOwner?.lane, .agent)

        await harness.runtime.disconnect()
    }

    func testAgentLanePreservesDynamicToolSuppressionWhenRoutingThreadStart() async throws {
        let now = Date(timeIntervalSince1970: 72_000)
        let probe = AdaptiveRuntimeProbe(
            outcomes: ["agent-model": .compatible(adaptiveCompatibleEvidence)],
            testedAt: now
        )
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            startThreadResult: makeAdaptiveThread(id: "suppressed-agent", model: "agent-model")
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [agent],
            probe: probe,
            now: now
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        _ = try await harness.runtime.startThread(StartThreadRequest(
            cwd: "/tmp/project",
            model: "agent-model",
            allowsDynamicTools: false
        ))
        let invocations = await agent.invocations()
        let start = try XCTUnwrap(
            invocations.first(where: { $0.name == .startThread })
        )
        XCTAssertEqual(start.allowsDynamicTools, false)
        await harness.runtime.disconnect()
    }

    func testEventsAreForwardedOnlyFromTheirExactOwnedLaneAndUnknownTasksStayPrivate() async throws {
        let chatRawID = "owned-chat"
        let agentRawID = "owned-agent"
        let agentID = publicAgentThreadID(agentRawID)
        let chat = AdaptiveRuntimeFake(kind: .local)
        let agent = AdaptiveRuntimeFake(kind: .codex, threads: [makeAdaptiveThread(id: agentRawID)])
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [agent],
            ownerships: [
                (chatRawID, .chat, "chat-model"),
                (agentID, .agent, "agent-model"),
            ]
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }
        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.listAllThreads(archived: false)

        await chat.emit(.threadNameChanged(threadID: chatRawID, name: "chat-owned"))
        await chat.emit(.threadNameChanged(threadID: agentRawID, name: "wrong-chat-lane"))
        await chat.emit(.threadNameChanged(threadID: "unknown-chat", name: "unknown"))
        await agent.emit(.threadNameChanged(threadID: agentRawID, name: "agent-owned"))
        await agent.emit(.threadNameChanged(threadID: chatRawID, name: "wrong-agent-lane"))
        await agent.emit(.threadNameChanged(threadID: "unknown-agent", name: "unknown"))

        try await eventually("two owned lane events") {
            await eventLog.threadNameChanges().count == 2
        }
        try await Task.sleep(for: .milliseconds(40))
        let laneChanges = await eventLog.threadNameChanges()
        XCTAssertEqual(Set(laneChanges), Set([
            .init(threadID: chatRawID, name: "chat-owned"),
            .init(threadID: agentID, name: "agent-owned"),
        ]))

        await harness.runtime.disconnect()
    }

    func testThreadlessTypedInteractionsAreNamespacedAndResponsesReturnToOriginLane() async throws {
        let agentRawID = "agent-for-interactions"
        let agentID = publicAgentThreadID(agentRawID)
        let chat = AdaptiveRuntimeFake(kind: .local)
        let agent = AdaptiveRuntimeFake(kind: .codex, threads: [makeAdaptiveThread(id: agentRawID)])
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [agent],
            ownerships: [(agentID, .agent, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }
        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.listAllThreads(archived: false)

        await chat.emit(.userInteractionRequested(makeAdaptiveInteraction(id: .integer(7))))
        await agent.emit(.userInteractionRequested(makeAdaptiveInteraction(id: .integer(7))))
        await agent.emit(.userInteractionRequested(makeAdaptiveInteraction(id: .string("7"))))
        try await eventually("three projected interactions") {
            await eventLog.interactions().count == 3
        }

        let interactions = await eventLog.interactions()
        XCTAssertTrue(interactions.allSatisfy { $0.threadID == nil })
        XCTAssertEqual(Set(interactions.map(\.id)).count, 3)
        XCTAssertTrue(interactions.allSatisfy {
            if case .string = $0.id { return true }
            return false
        })

        for interaction in interactions {
            try await harness.runtime.respond(to: interaction.id, with: .approval(.accept))
        }
        let chatResponseIDs = await chat.requestIDs(for: .respond)
        let agentResponseIDs = await agent.requestIDs(for: .respond)
        XCTAssertEqual(chatResponseIDs, [.integer(7)])
        XCTAssertEqual(Set(agentResponseIDs), Set([.integer(7), .string("7")]))

        await agent.emit(.userInteractionResolved(.integer(7)))
        try await eventually("typed interaction resolution") {
            await eventLog.events().contains { event in
                guard case let .userInteractionResolved(id) = event else { return false }
                return id == interactions.first { $0.id.description.contains("agent") }?.id
            }
        }

        await harness.runtime.disconnect()
    }

    func testEphemeralAgentConversationRoutesParentAndForwardsChildEvents() async throws {
        let parentRawID = "parent-agent"
        let parentID = publicAgentThreadID(parentRawID)
        let childRawID = "ephemeral-child"
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: parentRawID)],
            ephemeralResult: RuntimeConversation(
                thread: makeAdaptiveThread(id: childRawID),
                items: [makeAdaptiveItem(id: "side-history", body: "Earlier side-chat output")]
            ),
            ephemeralEvents: [
                .itemStarted(
                    threadID: childRawID,
                    item: makeAdaptiveItem(id: "synchronous-side-output", body: "Synchronous")
                ),
            ]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [agent],
            ownerships: [(parentID, .agent, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }
        _ = try await harness.runtime.connect()

        let sideChat = try await harness.runtime.forkEphemeralThread(id: parentID)
        let ephemeralParentIDs = await agent.threadIDs(for: .forkEphemeralThread)
        XCTAssertEqual(ephemeralParentIDs, [parentRawID])
        XCTAssertEqual(sideChat.thread.id, publicAgentThreadID(childRawID))

        try await eventually("synchronous ephemeral child event") {
            await eventLog.events().contains { event in
                guard case let .itemStarted(threadID, item) = event else { return false }
                return threadID == publicAgentThreadID(childRawID)
                    && item.id == "synchronous-side-output"
            }
        }

        await agent.emit(.itemStarted(
            threadID: childRawID,
            item: makeAdaptiveItem(id: "live-side-output", body: "Live")
        ))
        try await eventually("ephemeral child event") {
            await eventLog.events().contains { event in
                guard case let .itemStarted(threadID, item) = event else { return false }
                return threadID == publicAgentThreadID(childRawID)
                    && item.id == "live-side-output"
            }
        }

        await harness.runtime.disconnect()
    }

    func testCollaborationDestinationsDistinguishNativeChildrenFromAbsoluteCrossProviderTargets() async throws {
        let parentRawID = "collaboration-parent"
        let parentID = publicAgentThreadID(parentRawID)
        let remoteConnectionID = ProviderConnectionID("another-provider")
        let collaboration = RuntimeCollaborationActivity(
            action: .spawn,
            agents: [
                RuntimeCollaborationAgent(
                    id: "local-child",
                    path: "local",
                    status: .working,
                    message: nil,
                    updatedAt: .now,
                    destination: RuntimeCollaborationAgentDestination(
                        connectionID: .codexDefault,
                        threadID: "native-child",
                        inheritsParentConnection: true
                    )
                ),
                RuntimeCollaborationAgent(
                    id: "codex-delegated-child",
                    path: "codex-delegated",
                    status: .completed,
                    message: nil,
                    updatedAt: .now,
                    destination: RuntimeCollaborationAgentDestination(
                        connectionID: .codexDefault,
                        threadID: "codex-child"
                    )
                ),
                RuntimeCollaborationAgent(
                    id: "same-provider-child",
                    path: "same-provider",
                    status: .working,
                    message: nil,
                    updatedAt: .now,
                    destination: RuntimeCollaborationAgentDestination(
                        connectionID: ProviderConnectionID("adaptive-runtime-test"),
                        threadID: publicAgentThreadID("already-public-child"),
                        lane: .agent
                    )
                ),
                RuntimeCollaborationAgent(
                    id: "remote-child",
                    path: "remote",
                    status: .working,
                    message: nil,
                    updatedAt: .now,
                    destination: RuntimeCollaborationAgentDestination(
                        connectionID: remoteConnectionID,
                        threadID: "remote-child-thread",
                        lane: .chat
                    )
                ),
            ]
        )
        var item = makeAdaptiveItem(id: "collaboration", body: "Delegating")
        item.collaboration = collaboration
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: parentRawID)],
            conversations: [
                parentRawID: RuntimeConversation(
                    thread: makeAdaptiveThread(id: parentRawID),
                    items: [item]
                ),
            ]
        )
        let reconnectedAgent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [
                makeAdaptiveThread(id: parentRawID),
                makeAdaptiveThread(id: "native-child"),
            ]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [agent, reconnectedAgent],
            ownerships: [(parentID, .agent, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        let conversation = try await harness.runtime.readThread(id: parentID)
        let projectedAgents = try XCTUnwrap(conversation.items.first?.collaboration?.agents)
        let local = try XCTUnwrap(projectedAgents.first { $0.id == "local-child" }?.destination)
        XCTAssertEqual(local.connectionID, harness.connection.id)
        XCTAssertEqual(local.threadID, publicAgentThreadID("native-child"))
        XCTAssertEqual(local.lane, .agent)
        XCTAssertFalse(local.inheritsParentConnection)

        let delegatedCodex = try XCTUnwrap(
            projectedAgents.first { $0.id == "codex-delegated-child" }?.destination
        )
        XCTAssertEqual(delegatedCodex.connectionID, .codexDefault)
        XCTAssertEqual(delegatedCodex.threadID, "codex-child")
        XCTAssertNil(delegatedCodex.lane)
        XCTAssertFalse(delegatedCodex.inheritsParentConnection)

        let sameProvider = try XCTUnwrap(
            projectedAgents.first { $0.id == "same-provider-child" }?.destination
        )
        XCTAssertEqual(sameProvider.connectionID, harness.connection.id)
        XCTAssertEqual(sameProvider.threadID, publicAgentThreadID("already-public-child"))
        XCTAssertEqual(sameProvider.lane, .agent)

        let remote = try XCTUnwrap(projectedAgents.first { $0.id == "remote-child" }?.destination)
        XCTAssertEqual(remote.connectionID, remoteConnectionID)
        XCTAssertEqual(remote.threadID, "remote-child-thread")
        XCTAssertEqual(remote.lane, .chat)

        let nativeChildID = publicAgentThreadID("native-child")
        let nativeOwner = try await harness.stateStore.taskOwnership(
            connectionID: harness.connection.id,
            conversationScopeID: harness.connection.conversationScopeID,
            threadID: nativeChildID
        )
        XCTAssertEqual(nativeOwner?.lane, .agent)
        let wronglyAdoptedCodexChild = try await harness.stateStore.taskOwnership(
            connectionID: harness.connection.id,
            conversationScopeID: harness.connection.conversationScopeID,
            threadID: publicAgentThreadID("codex-child")
        )
        XCTAssertNil(wronglyAdoptedCodexChild)

        await harness.runtime.disconnect()
        _ = try await harness.runtime.connect()
        let restoredCatalog = try await harness.runtime.listAllThreads(archived: false)
        XCTAssertTrue(restoredCatalog.contains { $0.id == nativeChildID })
        _ = try await harness.runtime.readThread(id: nativeChildID)
        let restoredChildReads = await reconnectedAgent.threadIDs(for: .readThread)
        XCTAssertEqual(restoredChildReads, ["native-child"])

        await harness.runtime.disconnect()
    }

    func testConcurrentAgentPreparationIsCoalescedAndConnectCompletesBeforeRequests() async throws {
        let rawID = "coalesced-agent"
        let agentID = publicAgentThreadID(rawID)
        let connectGate = AdaptiveAsyncGate()
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID)],
            connectGate: connectGate
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [agent],
            ownerships: [(agentID, .agent, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        let read = Task { try await harness.runtime.readThread(id: agentID) }
        let resume = Task { try await harness.runtime.resumeThread(id: agentID) }
        try await eventually("one shared agent preparation") {
            let calls = await agent.invocations()
            return harness.factory.preparationCount == 1
                && calls.contains { $0.name == .connect }
        }
        XCTAssertEqual(harness.factory.preparationCount, 1)
        await connectGate.open()
        _ = try await read.value
        _ = try await resume.value

        let calls = await agent.invocations()
        XCTAssertEqual(calls.filter { $0.name == .connect }.count, 1)
        let connectIndex = try XCTUnwrap(calls.firstIndex { $0.name == .connect })
        XCTAssertLessThan(connectIndex, try XCTUnwrap(calls.firstIndex { $0.name == .readThread }))
        XCTAssertLessThan(connectIndex, try XCTUnwrap(calls.firstIndex { $0.name == .resumeThread }))

        await harness.runtime.disconnect()
        XCTAssertEqual(harness.factory.proxyStopCount, 1)
    }

    func testDisconnectCancelsStalePreparationAndReconnectBuildsFreshAgentRuntime() async throws {
        let rawID = "stale-preparation"
        let agentID = publicAgentThreadID(rawID)
        let firstConnectGate = AdaptiveAsyncGate()
        let first = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID)],
            connectGate: firstConnectGate
        )
        let second = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID)]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [first, second],
            ownerships: [(agentID, .agent, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        let staleRequest = Task { try await harness.runtime.readThread(id: agentID) }
        try await eventually("first preparation starts") {
            await first.invocations().contains { $0.name == .connect }
        }
        await harness.runtime.disconnect()
        await firstConnectGate.open()
        let staleResult = await staleRequest.result
        if case .success = staleResult { XCTFail("A request from the retired generation succeeded") }
        try await eventually("stale prepared runtime shutdown") {
            await first.invocations().contains { $0.name == .disconnect }
                && harness.factory.proxyStopCount == 1
        }

        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.readThread(id: agentID)
        XCTAssertEqual(harness.factory.preparationCount, 2)
        let freshReadIDs = await second.threadIDs(for: .readThread)
        XCTAssertEqual(freshReadIDs, [rawID])

        await harness.runtime.disconnect()
        XCTAssertEqual(harness.factory.proxyStopCount, 2)
    }

    func testDisconnectedGenerationEventsDoNotReplayAfterReconnect() async throws {
        let chatRawID = "reconnect-chat"
        let agentRawID = "reconnect-agent"
        let agentID = publicAgentThreadID(agentRawID)
        let chat = AdaptiveRuntimeFake(kind: .local)
        let firstAgent = AdaptiveRuntimeFake(kind: .codex, threads: [makeAdaptiveThread(id: agentRawID)])
        let secondAgent = AdaptiveRuntimeFake(kind: .codex, threads: [makeAdaptiveThread(id: agentRawID)])
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [firstAgent, secondAgent],
            ownerships: [
                (chatRawID, .chat, "chat-model"),
                (agentID, .agent, "agent-model"),
            ]
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }

        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.listAllThreads(archived: false)
        await harness.runtime.disconnect()
        await chat.emit(.threadNameChanged(threadID: chatRawID, name: "stale chat"))
        await firstAgent.emit(.threadNameChanged(threadID: agentRawID, name: "stale agent"))

        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.listAllThreads(archived: false)
        try await eventually("reconnected event pumps subscribe") {
            let chatSubscribers = await chat.subscriberCount()
            let agentSubscribers = await secondAgent.subscriberCount()
            return chatSubscribers >= 2 && agentSubscribers >= 1
        }
        try await Task.sleep(for: .milliseconds(40))
        let changesAfterReconnect = await eventLog.threadNameChanges()
        XCTAssertFalse(changesAfterReconnect.contains { $0.name?.hasPrefix("stale") == true })

        for _ in 0..<20 {
            await secondAgent.emit(.threadNameChanged(threadID: agentRawID, name: "fresh agent"))
            let names = await eventLog.threadNameChanges().compactMap(\.name)
            if names.contains("fresh agent") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let freshNames = await eventLog.threadNameChanges().compactMap(\.name)
        XCTAssertTrue(freshNames.contains("fresh agent"))

        await harness.runtime.disconnect()
    }

    func testChatLifecycleEventsRemainVisibleWhileAgentGlobalEventsStayPrivate() async throws {
        let agentRawID = "lifecycle-agent"
        let agentID = publicAgentThreadID(agentRawID)
        let chat = AdaptiveRuntimeFake(kind: .local)
        let agent = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: agentRawID)]
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [agent],
            ownerships: [(agentID, .agent, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        let eventLog = AdaptiveEventLog()
        let collector = collectEvents(from: harness.runtime.events, into: eventLog)
        defer { collector.cancel() }

        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.listAllThreads(archived: false)
        try await eventually("both lane event pumps subscribe") {
            let chatSubscribers = await chat.subscriberCount()
            let agentSubscribers = await agent.subscriberCount()
            return chatSubscribers >= 1 && agentSubscribers >= 1
        }

        let chatModels = [makeAdaptiveModel(id: "chat-visible")]
        await chat.emit(.runtimeModelsUpdated(chatModels))
        await chat.emit(.runtimeNotice(title: "chat notice", detail: "visible"))
        await agent.emit(.runtimeModelsUpdated([makeAdaptiveModel(id: "agent-private")]))
        await agent.emit(.runtimeNotice(title: "agent notice", detail: "private"))

        try await eventually("chat provider-wide events") {
            let events = await eventLog.events()
            let hasModels = events.contains { event in
                guard case let .runtimeModelsUpdated(models) = event else { return false }
                return models.map(\.id) == ["chat-visible"]
            }
            let hasNotice = events.contains { event in
                guard case let .runtimeNotice(title, _) = event else { return false }
                return title == "chat notice"
            }
            return hasModels && hasNotice
        }
        let events = await eventLog.events()
        XCTAssertFalse(events.contains { event in
            guard case let .runtimeModelsUpdated(models) = event else { return false }
            return models.contains { $0.id == "agent-private" }
        })
        XCTAssertFalse(events.contains { event in
            guard case let .runtimeNotice(title, _) = event else { return false }
            return title == "agent notice"
        })

        await harness.runtime.disconnect()
    }

    func testConcurrentRefreshesShareOneProviderRequest() async throws {
        let refreshGate = AdaptiveAsyncGate()
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            models: [makeAdaptiveModel(id: "agent-model")],
            refreshGate: refreshGate
        )
        let harness = try await makeAdaptiveHarness(chat: chat, agents: [])
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        let first = Task { try await harness.runtime.refreshAccount() }
        try await eventually("first provider refresh starts") {
            await chat.invocations().filter { $0.name == .refreshAccount }.count == 1
        }
        let second = Task { try await harness.runtime.refreshAccount() }
        try await Task.sleep(for: .milliseconds(30))
        let callsWhileSuspended = await chat.invocations()
        XCTAssertEqual(callsWhileSuspended.filter { $0.name == .refreshAccount }.count, 1)

        await refreshGate.open()
        let firstSession = try await first.value
        let secondSession = try await second.value
        XCTAssertEqual(firstSession.availableModels.map(\.id), secondSession.availableModels.map(\.id))
        let finalCalls = await chat.invocations()
        XCTAssertEqual(finalCalls.filter { $0.name == .refreshAccount }.count, 1)

        await harness.runtime.disconnect()
    }

    func testConcurrentDirectConnectsShareOneHandshakeAndProbeSubscription() async throws {
        let connectGate = AdaptiveAsyncGate()
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            models: [makeAdaptiveModel(id: "agent-model")],
            connectGate: connectGate
        )
        let harness = try await makeAdaptiveHarness(chat: chat, agents: [])
        defer { harness.removeTemporaryState() }

        let first = Task { try await harness.runtime.connect() }
        try await eventually("first direct connect starts") {
            await chat.invocations().filter { $0.name == .connect }.count == 1
        }
        let second = Task { try await harness.runtime.connect() }
        try await Task.sleep(for: .milliseconds(30))
        let suspendedConnectCount = await chat.invocations().filter { $0.name == .connect }.count
        XCTAssertEqual(suspendedConnectCount, 1)

        await connectGate.open()
        let firstSession = try await first.value
        let secondSession = try await second.value
        XCTAssertEqual(firstSession.availableModels.map(\.id), secondSession.availableModels.map(\.id))
        let connectedSubscriptionCount = await harness.resolver
            .activeProbeUpdateSubscriptionCount()
        XCTAssertEqual(connectedSubscriptionCount, 1)

        await harness.runtime.disconnect()
        let disconnectedSubscriptionCount = await harness.resolver
            .activeProbeUpdateSubscriptionCount()
        XCTAssertEqual(disconnectedSubscriptionCount, 0)
    }

    func testTerminalAgentShutdownBlocksReplacementPreparation() async throws {
        let rawID = "terminal-agent"
        let agentID = publicAgentThreadID(rawID)
        let proxyStopGate = AdaptiveAsyncGate()
        let first = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID)]
        )
        let second = AdaptiveRuntimeFake(
            kind: .codex,
            threads: [makeAdaptiveThread(id: rawID)]
        )
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: [first, second],
            ownerships: [(agentID, .agent, "agent-model")],
            proxyStopGate: proxyStopGate
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()
        _ = try await harness.runtime.readThread(id: agentID)

        await first.emit(.connectionChanged(.disconnected))
        try await eventually("terminal proxy shutdown starts") {
            harness.factory.proxyStopCount == 1
        }

        let replacementRead = Task { try await harness.runtime.readThread(id: agentID) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(harness.factory.preparationCount, 1)
        let replacementStartedDuringShutdown = await second.invocations().contains {
            $0.name == .connect
        }
        XCTAssertFalse(replacementStartedDuringShutdown)

        await proxyStopGate.open()
        _ = try await replacementRead.value
        XCTAssertEqual(harness.factory.preparationCount, 2)
        let replacementStartedAfterShutdown = await second.invocations().contains {
            $0.name == .connect
        }
        XCTAssertTrue(replacementStartedAfterShutdown)

        await harness.runtime.disconnect()
    }

    func testProbeSubscriptionIsRemovedOnDisconnectAndReconnectInstallsOnlyOneReplacement() async throws {
        let harness = try await makeAdaptiveHarness(
            chat: AdaptiveRuntimeFake(kind: .local),
            agents: []
        )
        defer { harness.removeTemporaryState() }

        _ = try await harness.runtime.connect()
        let connectedSubscriptions = await harness.resolver.activeProbeUpdateSubscriptionCount()
        XCTAssertEqual(connectedSubscriptions, 1)

        await harness.runtime.disconnect()
        let disconnectedSubscriptions = await harness.resolver.activeProbeUpdateSubscriptionCount()
        XCTAssertEqual(disconnectedSubscriptions, 0)

        _ = try await harness.runtime.connect()
        let reconnectedSubscriptions = await harness.resolver.activeProbeUpdateSubscriptionCount()
        XCTAssertEqual(reconnectedSubscriptions, 1)

        await harness.runtime.disconnect()
        let finalSubscriptions = await harness.resolver.activeProbeUpdateSubscriptionCount()
        XCTAssertEqual(finalSubscriptions, 0)
    }

    func testScopeRotationFencesOperationsUntilReplacementConnectCompletes() async throws {
        let refreshGate = AdaptiveAsyncGate()
        let disconnectGate = AdaptiveAsyncGate()
        let rawID = "scope-rotation-chat"
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            threads: [makeAdaptiveThread(id: rawID)],
            disconnectGate: disconnectGate,
            refreshGate: refreshGate
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [],
            ownerships: [(rawID, .chat, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        let refresh = Task { try await harness.runtime.refreshAccount() }
        try await eventually("refresh starts") {
            await chat.invocations().contains { $0.name == AdaptiveRuntimeInvocation.Name.refreshAccount }
        }
        var replacement = harness.connection
        replacement.conversationScopeID = "replacement-scope"
        try await harness.connectionStore.upsert(replacement)
        await refreshGate.open()
        try await eventually("scope teardown starts") {
            await chat.invocations().contains { $0.name == AdaptiveRuntimeInvocation.Name.disconnect }
        }

        do {
            _ = try await harness.runtime.listAllThreads(archived: false)
            XCTFail("Operations during scope teardown must fail closed")
        } catch let error as OpenAICompatibleRuntimeError {
            XCTAssertEqual(error, .notConnected)
        }

        await disconnectGate.open()
        _ = try await refresh.value
        let refreshed = try await harness.runtime.listAllThreads(archived: false)
        XCTAssertEqual(refreshed.map { $0.id }, [rawID])
        await harness.runtime.disconnect()
    }

    func testDisconnectDuringScopeReplacementConnectCancelsRefreshAndOwnsCleanup() async throws {
        let replacementConnectGate = AdaptiveNthCallGate(call: 2)
        let rawID = "scope-replacement-disconnect"
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            threads: [makeAdaptiveThread(id: rawID)],
            connectCallGate: replacementConnectGate
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [],
            ownerships: [(rawID, .chat, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        var replacement = harness.connection
        replacement.conversationScopeID = "scope-replacement-disconnect-next"
        try await harness.connectionStore.upsert(replacement)
        let refresh = Task { try await harness.runtime.refreshAccount() }
        try await eventually("replacement connect starts") {
            await chat.invocations().filter { $0.name == .connect }.count == 2
        }

        let disconnect = Task { await harness.runtime.disconnect() }
        try await Task.sleep(for: .milliseconds(30))
        let connectCountWhileDisconnecting = await chat.invocations()
            .filter { $0.name == .connect }.count
        XCTAssertEqual(connectCountWhileDisconnecting, 2)

        await replacementConnectGate.open()
        await disconnect.value
        if case .success = await refresh.result {
            XCTFail("A replacement refresh must not commit after disconnect")
        }
        let connectCountAfterDisconnect = await chat.invocations()
            .filter { $0.name == .connect }.count
        let subscriptionCountAfterDisconnect = await harness.resolver
            .activeProbeUpdateSubscriptionCount()
        XCTAssertEqual(connectCountAfterDisconnect, 2)
        XCTAssertEqual(subscriptionCountAfterDisconnect, 0)

        do {
            _ = try await harness.runtime.listAllThreads(archived: false)
            XCTFail("Disconnect must leave the facade disconnected")
        } catch let error as OpenAICompatibleRuntimeError {
            XCTAssertEqual(error, .notConnected)
        }

        _ = try await harness.runtime.connect()
        await harness.runtime.disconnect()
    }

    func testReplacementConnectFailureLeavesFacadeDisconnectedAndAllowsLaterReconnect() async throws {
        let rawID = "replacement-failure-chat"
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            threads: [makeAdaptiveThread(id: rawID)],
            connectFailures: [false, true, false]
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [],
            ownerships: [(rawID, .chat, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()

        var replacement = harness.connection
        replacement.conversationScopeID = "replacement-failure-scope"
        try await harness.connectionStore.upsert(replacement)
        do {
            _ = try await harness.runtime.refreshAccount()
            XCTFail("Replacement connect should fail")
        } catch let error as AdaptiveRuntimeTestError {
            XCTAssertEqual(error, .connectFailed)
        }

        do {
            _ = try await harness.runtime.listAllThreads(archived: false)
            XCTFail("A failed replacement must leave the facade disconnected")
        } catch let error as OpenAICompatibleRuntimeError {
            XCTAssertEqual(error, .notConnected)
        }

        _ = try await harness.runtime.connect()
        let recoveredIDs = try await harness.runtime.listAllThreads(archived: false).map(\.id)
        XCTAssertEqual(recoveredIDs, [rawID])
        await harness.runtime.disconnect()
    }

    func testConcurrentDisconnectSharesOneTeardownWithoutLeakingAChatPump() async throws {
        let disconnectGate = AdaptiveAsyncGate()
        let rawID = "double-disconnect-chat"
        let chat = AdaptiveRuntimeFake(
            kind: .local,
            threads: [makeAdaptiveThread(id: rawID)],
            disconnectGate: disconnectGate
        )
        let harness = try await makeAdaptiveHarness(
            chat: chat,
            agents: [],
            ownerships: [(rawID, .chat, "agent-model")]
        )
        defer { harness.removeTemporaryState() }
        _ = try await harness.runtime.connect()
        let initialPumpCount = await harness.runtime.chatEventPumpStartsForTesting()
        XCTAssertEqual(initialPumpCount, 1)

        let first = Task { await harness.runtime.disconnect() }
        try await eventually("first teardown starts") {
            await chat.invocations().contains { $0.name == .disconnect }
        }
        let second = Task { await harness.runtime.disconnect() }
        try await Task.sleep(for: .milliseconds(30))
        let disconnectCount = await chat.invocations().filter { $0.name == .disconnect }.count
        XCTAssertEqual(disconnectCount, 1)
        await disconnectGate.open()
        await first.value
        await second.value
        let retiredPumpCount = await harness.runtime.chatEventPumpStartsForTesting()
        XCTAssertEqual(retiredPumpCount, 1)

        _ = try await harness.runtime.connect()
        let reconnectedPumpCount = await harness.runtime.chatEventPumpStartsForTesting()
        XCTAssertEqual(reconnectedPumpCount, 2)
        await harness.runtime.disconnect()
    }
}

private struct AdaptiveHarness {
    let runtime: OpenAICompatibleAdaptiveRuntime
    let connection: ProviderConnectionRecord
    let connectionStore: ProviderConnectionStore
    let stateStore: OpenAICompatibleAdaptiveStateStore
    let resolver: OpenAICompatibleAdaptiveRuntimeResolver
    let factory: AdaptiveAgentFactoryQueue
    let temporaryDirectory: URL

    func removeTemporaryState() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

private func makeAdaptiveHarness(
    chat: AdaptiveRuntimeFake,
    agents: [AdaptiveRuntimeFake],
    ownerships: [(String, OpenAICompatibleTaskLane, String)] = [],
    probe: AdaptiveRuntimeProbe? = nil,
    now: Date = Date(),
    proxyStopGate: AdaptiveAsyncGate? = nil,
    turnLivenessPolicy: OpenAICompatibleAgentTurnLivenessPolicy = .production
) async throws -> AdaptiveHarness {
    let connection = try ProviderConnectionRecord(
        id: ProviderConnectionID("adaptive-runtime-test"),
        displayName: "Adaptive runtime test",
        baseURL: URL(string: "https://provider.example.test/v1")!,
        selectedModelID: "agent-model",
        authMode: .none,
        transportCapabilities: [.streaming],
        conversationScopeID: "adaptive-runtime-scope"
    )
    let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
    try await connectionStore.upsert(connection)
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "onyx-adaptive-runtime-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    let stateStore = OpenAICompatibleAdaptiveStateStore(
        fileURL: temporaryDirectory.appendingPathComponent("adaptive-state.json")
    )
    for (threadID, lane, modelID) in ownerships {
        _ = try await stateStore.recordTaskOwnership(
            connectionID: connection.id,
            conversationScopeID: connection.conversationScopeID,
            threadID: threadID,
            lane: lane,
            modelID: modelID,
            updatedAt: now
        )
    }
    let activeProbe = probe ?? AdaptiveRuntimeProbe(outcomes: [:], testedAt: now)
    let resolver = OpenAICompatibleAdaptiveRuntimeResolver(
        probe: activeProbe,
        stateStore: stateStore,
        now: { now }
    )
    let factoryQueue = AdaptiveAgentFactoryQueue(
        runtimes: agents,
        proxyStopGate: proxyStopGate,
        turnLivenessPolicy: turnLivenessPolicy
    )
    let runtime = OpenAICompatibleAdaptiveRuntime(
        connectionID: connection.id,
        connectionStore: connectionStore,
        stateStore: stateStore,
        resolver: resolver,
        agentFactory: factoryQueue.makeFactory(),
        chatRuntime: chat
    )
    return AdaptiveHarness(
        runtime: runtime,
        connection: connection,
        connectionStore: connectionStore,
        stateStore: stateStore,
        resolver: resolver,
        factory: factoryQueue,
        temporaryDirectory: temporaryDirectory
    )
}

private struct AdaptiveRuntimeInvocation: Equatable, Sendable {
    enum Name: Equatable, Hashable, Sendable {
        case connect
        case disconnect
        case refreshAccount
        case listThreads
        case listAllThreads
        case readThread
        case readThreadPaginated
        case resumeThread
        case resumeThreadPaginated
        case revertThread
        case startThread
        case forkThread
        case forkEphemeralThread
        case compactThread
        case deleteThread
        case startTurn
        case startReview
        case steerText
        case steerInputs
        case interrupt
        case respond
        case renameThread
        case archiveThread
        case unarchiveThread
    }

    let name: Name
    let threadID: String?
    let modelID: String?
    let requestID: RuntimeRequestID?
    let allowsDynamicTools: Bool?

    init(
        _ name: Name,
        threadID: String? = nil,
        modelID: String? = nil,
        requestID: RuntimeRequestID? = nil,
        allowsDynamicTools: Bool? = nil
    ) {
        self.name = name
        self.threadID = threadID
        self.modelID = modelID
        self.requestID = requestID
        self.allowsDynamicTools = allowsDynamicTools
    }
}

private actor AdaptiveRuntimeFake: AgentRuntime {
    nonisolated let kind: AgentRuntimeKind
    nonisolated let events: AsyncStream<AgentRuntimeEvent>
    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let models: [RuntimeModel]
    private let threads: [RuntimeThread]
    private let conversations: [String: RuntimeConversation]
    private let connectEvents: [AgentRuntimeEvent]
    private let connectGate: AdaptiveAsyncGate?
    private let connectCallGate: AdaptiveNthCallGate?
    private let disconnectGate: AdaptiveAsyncGate?
    private let refreshGate: AdaptiveAsyncGate?
    private var queuedConnectFailures: [Bool]
    private let startThreadResult: RuntimeThread
    private let startThreadEvents: [AgentRuntimeEvent]
    private let startThreadGate: AdaptiveAsyncGate?
    private let forkResult: RuntimeThread
    private let ephemeralResult: RuntimeConversation
    private let ephemeralEvents: [AgentRuntimeEvent]
    private var recordedInvocations: [AdaptiveRuntimeInvocation] = []

    init(
        kind: AgentRuntimeKind,
        models: [RuntimeModel] = [],
        threads: [RuntimeThread] = [],
        conversations: [String: RuntimeConversation] = [:],
        connectEvents: [AgentRuntimeEvent] = [],
        connectGate: AdaptiveAsyncGate? = nil,
        connectCallGate: AdaptiveNthCallGate? = nil,
        disconnectGate: AdaptiveAsyncGate? = nil,
        refreshGate: AdaptiveAsyncGate? = nil,
        connectFailures: [Bool] = [],
        startThreadResult: RuntimeThread = makeAdaptiveThread(id: "started-thread"),
        startThreadEvents: [AgentRuntimeEvent] = [],
        startThreadGate: AdaptiveAsyncGate? = nil,
        forkResult: RuntimeThread = makeAdaptiveThread(id: "forked-thread"),
        ephemeralResult: RuntimeConversation = RuntimeConversation(
            thread: makeAdaptiveThread(id: "ephemeral-thread"),
            items: []
        ),
        ephemeralEvents: [AgentRuntimeEvent] = []
    ) {
        self.kind = kind
        self.models = models
        self.threads = threads
        self.conversations = conversations
        self.connectEvents = connectEvents
        self.connectGate = connectGate
        self.connectCallGate = connectCallGate
        self.disconnectGate = disconnectGate
        self.refreshGate = refreshGate
        self.queuedConnectFailures = connectFailures
        self.startThreadResult = startThreadResult
        self.startThreadEvents = startThreadEvents
        self.startThreadGate = startThreadGate
        self.forkResult = forkResult
        self.ephemeralResult = ephemeralResult
        self.ephemeralEvents = ephemeralEvents
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        recordedInvocations.append(.init(.connect))
        let call = recordedInvocations.filter { $0.name == .connect }.count
        for event in connectEvents { eventContinuation.yield(event) }
        if let connectGate { try await connectGate.wait() }
        if let connectCallGate { try await connectCallGate.waitIfTarget(call) }
        let shouldFail = queuedConnectFailures.isEmpty
            ? false
            : queuedConnectFailures.removeFirst()
        if shouldFail { throw AdaptiveRuntimeTestError.connectFailed }
        return RuntimeSession(
            runtime: kind,
            displayName: "Adaptive fake",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: models,
            capabilities: []
        )
    }

    func disconnect() async {
        recordedInvocations.append(.init(.disconnect))
        if let disconnectGate { try? await disconnectGate.wait() }
    }

    func refreshAccount() async throws -> RuntimeSession {
        recordedInvocations.append(.init(.refreshAccount))
        if let refreshGate { try await refreshGate.wait() }
        return RuntimeSession(
            runtime: kind,
            displayName: "Adaptive fake",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: models,
            capabilities: []
        )
    }

    func listThreads(limit: Int, archived _: Bool) async throws -> [RuntimeThread] {
        recordedInvocations.append(.init(.listThreads))
        return Array(threads.prefix(max(0, limit)))
    }

    func listAllThreads(archived _: Bool) async throws -> [RuntimeThread] {
        recordedInvocations.append(.init(.listAllThreads))
        return threads
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        recordedInvocations.append(.init(.readThread, threadID: id))
        return conversation(id: id)
    }

    func readThread(
        id: String,
        initialHistoryPage _: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        recordedInvocations.append(.init(.readThreadPaginated, threadID: id))
        return RuntimeThreadResumeResult(
            conversation: conversation(id: id),
            initialHistoryPage: nil,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil
        )
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        recordedInvocations.append(.init(.resumeThread, threadID: id))
        return conversation(id: id)
    }

    func resumeThread(
        id: String,
        initialHistoryPage _: RuntimeInitialThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        recordedInvocations.append(.init(.resumeThreadPaginated, threadID: id))
        return RuntimeThreadResumeResult(
            conversation: conversation(id: id),
            initialHistoryPage: nil,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil
        )
    }

    func revertThread(id: String, beforeTurnID _: String) async throws -> RuntimeThreadRevertResult {
        recordedInvocations.append(.init(.revertThread, threadID: id))
        return RuntimeThreadRevertResult(
            thread: conversation(id: id).thread,
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil
        )
    }

    func startThread(_ request: StartThreadRequest) async throws -> RuntimeThread {
        recordedInvocations.append(.init(
            .startThread,
            modelID: request.model,
            allowsDynamicTools: request.allowsDynamicTools
        ))
        for event in startThreadEvents { eventContinuation.yield(event) }
        if let startThreadGate { try await startThreadGate.wait() }
        return startThreadResult
    }

    func forkThread(id: String) async throws -> RuntimeThread {
        recordedInvocations.append(.init(.forkThread, threadID: id))
        return forkResult
    }

    func forkEphemeralThread(id: String) async throws -> RuntimeConversation {
        recordedInvocations.append(.init(.forkEphemeralThread, threadID: id))
        for event in ephemeralEvents { eventContinuation.yield(event) }
        return ephemeralResult
    }

    func compactThread(id: String) async throws {
        recordedInvocations.append(.init(.compactThread, threadID: id))
    }

    func deleteThread(id: String) async throws {
        recordedInvocations.append(.init(.deleteThread, threadID: id))
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        recordedInvocations.append(.init(
            .startTurn,
            threadID: request.threadID,
            modelID: request.model
        ))
    }

    func startReview(_ request: StartReviewRequest) async throws -> RuntimeReviewRun {
        recordedInvocations.append(.init(.startReview, threadID: request.threadID))
        return RuntimeReviewRun(threadID: request.threadID, turnID: "review-turn")
    }

    func steer(threadID: String, text _: String) async throws {
        recordedInvocations.append(.init(.steerText, threadID: threadID))
    }

    func steer(threadID: String, inputs _: [RuntimeTurnInput]) async throws {
        recordedInvocations.append(.init(.steerInputs, threadID: threadID))
    }

    func interrupt(threadID: String) async throws {
        recordedInvocations.append(.init(.interrupt, threadID: threadID))
    }

    func respond(
        to interactionID: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {
        recordedInvocations.append(.init(.respond, requestID: interactionID))
    }

    func renameThread(id: String, name _: String) async throws {
        recordedInvocations.append(.init(.renameThread, threadID: id))
    }

    func archiveThread(id: String) async throws {
        recordedInvocations.append(.init(.archiveThread, threadID: id))
    }

    func unarchiveThread(id: String) async throws {
        recordedInvocations.append(.init(.unarchiveThread, threadID: id))
    }

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func finishEvents() {
        eventContinuation.finish()
    }

    func invocations() -> [AdaptiveRuntimeInvocation] {
        recordedInvocations
    }

    func threadIDs(for name: AdaptiveRuntimeInvocation.Name) -> [String] {
        recordedInvocations.filter { $0.name == name }.compactMap(\.threadID)
    }

    func requestIDs(for name: AdaptiveRuntimeInvocation.Name) -> [RuntimeRequestID] {
        recordedInvocations.filter { $0.name == name }.compactMap(\.requestID)
    }

    func subscriberCount() -> Int {
        // AsyncStream does not expose iterator count. A zero-duration marker is
        // used only as a scheduling barrier in reconnect tests.
        eventContinuation.yield(.runtimeNotice(title: "fixture-barrier", detail: "fixture"))
        return recordedInvocations.filter { $0.name == .connect }.count
    }

    private func conversation(id: String) -> RuntimeConversation {
        if let value = conversations[id] { return value }
        let thread = threads.first { $0.id == id } ?? makeAdaptiveThread(id: id)
        return RuntimeConversation(thread: thread, items: [])
    }
}

private final class AdaptiveAgentFactoryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [AdaptiveRuntimeFake]
    private var storedPreparationCount = 0
    private var storedProxyStopCount = 0
    private let proxyStopGate: AdaptiveAsyncGate?
    private let turnLivenessPolicy: OpenAICompatibleAgentTurnLivenessPolicy

    init(
        runtimes: [AdaptiveRuntimeFake],
        proxyStopGate: AdaptiveAsyncGate? = nil,
        turnLivenessPolicy: OpenAICompatibleAgentTurnLivenessPolicy = .production
    ) {
        self.runtimes = runtimes
        self.proxyStopGate = proxyStopGate
        self.turnLivenessPolicy = turnLivenessPolicy
    }

    var preparationCount: Int { lock.withLock { storedPreparationCount } }
    var proxyStopCount: Int { lock.withLock { storedProxyStopCount } }

    func makeFactory() -> OpenAICompatibleAgentRuntimeFactory {
        OpenAICompatibleAgentRuntimeFactory(
            credentialStore: InMemoryCredentialStore(),
            turnLivenessPolicy: turnLivenessPolicy,
            proxyFactory: { [self] _, _ in
                lock.withLock { storedPreparationCount += 1 }
                return OpenAICompatibleAgentProxyLease(
                    baseURL: URL(string: "http://127.0.0.1:43123/v1")!,
                    disposableAPIKey: "adaptive-runtime-test-token",
                    stop: { [self] in
                        lock.withLock { storedProxyStopCount += 1 }
                        if let proxyStopGate { try? await proxyStopGate.wait() }
                    }
                )
            },
            runtimeFactory: { [self] _, _ in
                try lock.withLock {
                    guard !runtimes.isEmpty else { throw AdaptiveRuntimeTestError.noAgentRuntime }
                    return runtimes.removeFirst()
                }
            }
        )
    }
}

private enum AdaptiveRuntimeTestError: Error {
    case noAgentRuntime
    case connectFailed
}

private actor AdaptiveRuntimeProbe: OpenAICompatibleResponsesCompatibilityProbing {
    private let outcomes: [String: OpenAICompatibleResponsesProbeOutcome]
    private let gate: AdaptiveAsyncGate?
    private let testedAt: Date
    private var calls: [String] = []

    init(
        outcomes: [String: OpenAICompatibleResponsesProbeOutcome],
        gate: AdaptiveAsyncGate? = nil,
        testedAt: Date
    ) {
        self.outcomes = outcomes
        self.gate = gate
        self.testedAt = testedAt
    }

    func probe(
        connection: ProviderConnectionRecord,
        modelID: String
    ) async throws -> OpenAICompatibleResponsesProbeRecord {
        calls.append(modelID)
        if let gate { try await gate.wait() }
        return OpenAICompatibleResponsesProbeRecord(
            fingerprint: OpenAICompatibleResponsesProbeFingerprint(
                connection: connection,
                modelID: modelID
            ),
            testedAt: testedAt,
            expiresAt: testedAt.addingTimeInterval(60 * 60),
            outcome: outcomes[modelID] ?? .failed(.missingFunctionCall)
        )
    }

    func modelIDs() -> [String] { calls }
}

private actor AdaptiveAsyncGate {
    private var isOpen = false

    func wait() async throws {
        while !isOpen {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        isOpen = true
    }
}

private actor AdaptiveNthCallGate {
    private let targetCall: Int
    private var isOpen = false

    init(call: Int) {
        targetCall = call
    }

    func waitIfTarget(_ call: Int) async throws {
        guard call == targetCall else { return }
        while !isOpen {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        isOpen = true
    }
}

private actor AdaptiveEventLog {
    struct ThreadNameChange: Equatable, Hashable {
        let threadID: String
        let name: String?
    }

    private var values: [AgentRuntimeEvent] = []

    func append(_ event: AgentRuntimeEvent) { values.append(event) }
    func events() -> [AgentRuntimeEvent] { values }

    func threadNameChanges() -> [ThreadNameChange] {
        values.compactMap { event in
            guard case let .threadNameChanged(threadID, name) = event else { return nil }
            return ThreadNameChange(threadID: threadID, name: name)
        }
    }

    func interactions() -> [RuntimeUserInteraction] {
        values.compactMap { event in
            guard case let .userInteractionRequested(interaction) = event else { return nil }
            return interaction
        }
    }
}

private func collectEvents(
    from stream: AsyncStream<AgentRuntimeEvent>,
    into log: AdaptiveEventLog
) -> Task<Void, Never> {
    Task {
        for await event in stream {
            await log.append(event)
        }
    }
}

private func eventually(
    _ description: String,
    attempts: Int = 200,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for \(description)")
}

private let adaptiveCompatibleEvidence = OpenAICompatibleResponsesProbeEvidence(
    usedServerSentEvents: true,
    receivedFunctionCall: true,
    submittedCorrelatedOutput: true,
    completedAfterFunctionOutput: true
)

private func makeAdaptiveModel(
    id: String,
    isDefault: Bool = false,
    inputModalities: Set<ProviderInputModality> = [.text, .image],
    reasoningEfforts: [String] = [],
    capabilityEvidence: ProviderCapabilityEvidence = .advertised
) -> RuntimeModel {
    RuntimeModel(
        id: id,
        displayName: id,
        description: nil,
        isDefault: isDefault,
        defaultReasoningEffort: nil,
        reasoningEfforts: reasoningEfforts,
        inputModalities: inputModalities,
        capabilityEvidence: capabilityEvidence
    )
}

private func makeAdaptiveThread(
    id: String,
    title: String = "Thread",
    model: String? = nil,
    updatedAt: TimeInterval = 1
) -> RuntimeThread {
    RuntimeThread(
        id: id,
        title: title,
        preview: title,
        cwd: "/tmp/project",
        updatedAt: Date(timeIntervalSince1970: updatedAt),
        status: .idle,
        isPinned: false,
        runtime: .local,
        model: model,
        branch: nil
    )
}

private func makeAdaptiveItem(id: String, body: String) -> TimelineItem {
    TimelineItem(
        id: id,
        kind: .assistantMessage,
        title: nil,
        body: body,
        status: .completed,
        timestamp: .now,
        detail: nil
    )
}

private func makeAdaptiveInteraction(id: RuntimeRequestID) -> RuntimeUserInteraction {
    RuntimeUserInteraction(
        id: id,
        threadID: nil,
        providerMethod: "fixture/approval",
        title: "Approval",
        detail: "Approve fixture",
        kind: .approval(RuntimeApprovalPrompt(
            subject: .permissions,
            command: nil
        ))
    )
}

private func publicAgentThreadID(_ rawID: String) -> String {
    let opaqueID = Data(rawID.utf8).base64EncodedString()
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "=", with: "")
    return "onyx.agent.\(opaqueID)"
}

private func publicChatThreadID(_ rawID: String) -> String {
    guard rawID.hasPrefix("onyx.agent.") || rawID.hasPrefix("onyx.chat.") else { return rawID }
    let opaqueID = Data(rawID.utf8).base64EncodedString()
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "=", with: "")
    return "onyx.chat.\(opaqueID)"
}
