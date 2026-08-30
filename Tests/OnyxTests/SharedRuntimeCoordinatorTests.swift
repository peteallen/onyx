import Foundation
import XCTest
@testable import Onyx

final class SharedRuntimeCoordinatorTests: XCTestCase {
    func testEverySubscriberReceivesEveryRuntimeEventInOrder() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let first = CoordinatorEventRecorder()
        let second = CoordinatorEventRecorder()
        await first.start(stream: coordinator.events)
        await second.start(stream: coordinator.events)

        let expected: [AgentRuntimeEvent] = [
            .connectionChanged(.connecting),
            .runtimeNotice(title: "First", detail: "one"),
            .runtimeNotice(title: "Second", detail: "two"),
        ]
        for event in expected {
            runtime.emit(event)
        }

        try await first.waitForCount(expected.count)
        try await second.waitForCount(expected.count)
        let firstEvents = await first.snapshot()
        let secondEvents = await second.snapshot()
        XCTAssertEqual(firstEvents, expected)
        XCTAssertEqual(secondEvents, expected)
        XCTAssertEqual(runtime.eventStreamAccessCount, 1)
    }

    func testAuthenticationRecoveryReplaysToWindowsThatAttachLater() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let first = CoordinatorEventRecorder()
        await first.start(stream: coordinator.events)

        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        try await first.waitForCount(1)

        let attachedLater = CoordinatorEventRecorder()
        await attachedLater.start(stream: coordinator.events)
        try await attachedLater.waitForCount(1)

        let expected = [AgentRuntimeEvent.authenticationRecoveryRequired(.signInExpired)]
        let firstEvents = await first.snapshot()
        let laterEvents = await attachedLater.snapshot()
        XCTAssertEqual(firstEvents, expected)
        XCTAssertEqual(laterEvents, expected)
    }

    func testRoutineSignedInRefreshAndAccountEventDoNotClearRecovery() async throws {
        let signedIn = Self.authenticatedSession(label: "Still stale")
        let runtime = CoordinatorFakeRuntime(refreshSession: signedIn)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let current = CoordinatorEventRecorder()
        await current.start(stream: coordinator.events)

        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        try await current.waitForCount(1)
        _ = try await coordinator.refreshAccount()
        runtime.emit(.accountUpdated(signedIn.auth))
        try await current.waitForCount(2)

        let attachedLater = CoordinatorEventRecorder()
        await attachedLater.start(stream: coordinator.events)
        try await attachedLater.waitForCount(1)
        let laterEvents = await attachedLater.snapshot()
        XCTAssertEqual(
            laterEvents,
            [.authenticationRecoveryRequired(.signInExpired)],
            "A routine signed-in projection must not masquerade as successful reauthentication."
        )
    }

    func testUnrelatedSuccessfulLoginCannotConfirmRecovery() async throws {
        let signedIn = Self.authenticatedSession(label: "Unrelated login")
        let runtime = CoordinatorFakeRuntime(refreshSession: signedIn)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let current = CoordinatorEventRecorder()
        await current.start(stream: coordinator.events)

        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        try await current.waitForCount(1)
        runtime.emit(.loginCompleted(RuntimeLoginCompletion(
            loginID: "not-started-through-onyx",
            success: true,
            error: nil
        )))
        let marker = AgentRuntimeEvent.runtimeNotice(
            title: "After unrelated login",
            detail: "The stale completion was suppressed"
        )
        runtime.emit(marker)
        try await current.waitForCount(2)
        let currentEvents = await current.snapshot()
        XCTAssertEqual(
            currentEvents,
            [.authenticationRecoveryRequired(.signInExpired), marker]
        )

        _ = try await coordinator.refreshAccount()
        let attachedLater = CoordinatorEventRecorder()
        await attachedLater.start(stream: coordinator.events)
        try await attachedLater.waitForCount(1)
        let laterEvents = await attachedLater.snapshot()
        XCTAssertEqual(
            laterEvents,
            [.authenticationRecoveryRequired(.signInExpired)]
        )
    }

    func testConfirmedRecoveryReplaysLoginToWindowAttachingBeforeRefreshThenClears() async throws {
        let signedIn = Self.authenticatedSession(label: "Recovered provider")
        let login = RuntimeLoginStart(
            method: RuntimeLoginMethod(
                id: "fake-login",
                displayName: "Sign in",
                detail: "Sign in",
                ceremony: .browser
            ),
            loginID: "recovery-login",
            authURL: URL(string: "https://example.com/login"),
            verificationURL: nil,
            userCode: nil
        )
        let runtime = CoordinatorFakeRuntime(
            refreshSession: signedIn,
            loginStartResult: login
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let current = CoordinatorEventRecorder()
        await current.start(stream: coordinator.events)

        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        try await current.waitForCount(1)
        _ = try await coordinator.startLogin(methodID: login.method.id)
        runtime.emit(.loginCompleted(RuntimeLoginCompletion(
            loginID: login.loginID,
            success: true,
            error: nil
        )))
        try await current.waitForCount(2)

        // This window missed the live completion but still needs both durable
        // pieces of recovery state so it participates in account confirmation.
        let attachedDuringConfirmation = CoordinatorEventRecorder()
        await attachedDuringConfirmation.start(stream: coordinator.events)
        try await attachedDuringConfirmation.waitForCount(2)
        let completion = RuntimeLoginCompletion(
            loginID: login.loginID,
            success: true,
            error: nil
        )
        let confirmationEvents = await attachedDuringConfirmation.snapshot()
        XCTAssertEqual(
            confirmationEvents,
            [
                .authenticationRecoveryRequired(.signInExpired),
                .loginCompleted(completion),
            ]
        )

        _ = try await coordinator.refreshAccount()

        let attachedAfterConfirmation = CoordinatorEventRecorder()
        await attachedAfterConfirmation.start(stream: coordinator.events)
        let marker = AgentRuntimeEvent.runtimeNotice(
            title: "After confirmation",
            detail: "No recovery should replay"
        )
        runtime.emit(marker)
        try await current.waitForCount(3)
        try await attachedAfterConfirmation.waitForCount(1)
        let afterConfirmationEvents = await attachedAfterConfirmation.snapshot()
        XCTAssertEqual(
            afterConfirmationEvents,
            [marker],
            "Successful login plus a signed-in refresh must clear durable recovery."
        )

        // The same connected provider must still be able to expire again.
        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        try await current.waitForCount(4)
        let attachedAfterSecondExpiration = CoordinatorEventRecorder()
        await attachedAfterSecondExpiration.start(stream: coordinator.events)
        try await attachedAfterSecondExpiration.waitForCount(1)
        let secondExpirationEvents = await attachedAfterSecondExpiration.snapshot()
        XCTAssertEqual(
            secondExpirationEvents,
            [.authenticationRecoveryRequired(.signInExpired)]
        )
    }

    func testAuthoritativeSignedOutEventClearsRecoveryForLaterWindows() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let current = CoordinatorEventRecorder()
        await current.start(stream: coordinator.events)

        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        try await current.waitForCount(1)
        runtime.emit(.accountUpdated(.signedOut))
        try await current.waitForCount(2)
        let currentEvents = await current.snapshot()
        XCTAssertEqual(
            currentEvents,
            [
                .authenticationRecoveryRequired(.signInExpired),
                .accountUpdated(.signedOut),
            ],
            "Signed out remains an authoritative account boundary during recovery."
        )

        // A delayed auth failure from the retired provider must be rejected
        // after the authoritative provider account event, rather than
        // re-arming the sticky recovery state.
        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        let attachedLater = CoordinatorEventRecorder()
        await attachedLater.start(stream: coordinator.events)
        let marker = AgentRuntimeEvent.runtimeNotice(
            title: "After sign out",
            detail: "Recovery must be gone"
        )
        runtime.emit(marker)
        try await current.waitForCount(3)
        try await attachedLater.waitForCount(2)
        let laterEvents = await attachedLater.snapshot()
        XCTAssertEqual(laterEvents, [.accountUpdated(.signedOut), marker])

        let currentAfterLateRecovery = await current.snapshot()
        XCTAssertEqual(
            currentAfterLateRecovery,
            [
                .authenticationRecoveryRequired(.signInExpired),
                .accountUpdated(.signedOut),
                marker,
            ]
        )
    }

    func testColdSignedOutConnectSnapshotDoesNotEstablishAccountBoundary() async throws {
        let signedOutSession = RuntimeSession(
            runtime: .local,
            displayName: "Signed-out provider",
            accountLabel: nil,
            planLabel: nil,
            auth: .signedOut,
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )
        let runtime = CoordinatorFakeRuntime(connectSession: signedOutSession)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let connected = try await coordinator.connect()
        XCTAssertEqual(connected.auth, .signedOut)

        // A cold signed-out snapshot is not an explicit account event. Local
        // task history remains readable until the provider reports a boundary.
        _ = try await coordinator.listThreads(limit: 1, archived: false)
        let listThreadsCallCount = await runtime.listThreadsCallCount
        XCTAssertEqual(listThreadsCallCount, 1)
    }

    func testSuccessfulLoginClearsDurableSignedOutBoundaryForLaterWindows() async throws {
        let login = Self.loginStart(loginID: "boundary-login")
        let runtime = CoordinatorFakeRuntime(loginStartResult: login)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let current = CoordinatorEventRecorder()
        await current.start(stream: coordinator.events)

        runtime.emit(.accountUpdated(.signedOut))
        try await current.waitForCount(1)
        _ = try await coordinator.startLogin(methodID: login.method.id)
        let completion = RuntimeLoginCompletion(
            loginID: login.loginID,
            success: true,
            error: nil
        )
        runtime.emit(.loginCompleted(completion))
        try await current.waitForCount(2)

        let attachedLater = CoordinatorEventRecorder()
        await attachedLater.start(stream: coordinator.events)
        let marker = AgentRuntimeEvent.runtimeNotice(
            title: "After reauthentication",
            detail: "The signed-out boundary no longer replays"
        )
        runtime.emit(marker)
        try await current.waitForCount(3)
        try await attachedLater.waitForCount(1)

        let laterEvents = await attachedLater.snapshot()
        XCTAssertEqual(
            laterEvents,
            [marker],
            "A successful admitted login must clear the durable boundary replay."
        )
    }

    func testLateRecoveryAfterSyntheticLogoutDoesNotReplayToLaterWindows() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let current = CoordinatorEventRecorder()
        await current.start(stream: coordinator.events)

        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        try await current.waitForCount(1)

        // The coordinator's synthetic boundary is what every window receives
        // even when the provider emits no account notification of its own.
        try await coordinator.logout()
        try await current.waitForCount(2)

        // A stopping app-server can report a delayed auth failure after the
        // logout boundary. It must not become sticky again or leak into a
        // window opened after sign-out.
        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        let attachedLater = CoordinatorEventRecorder()
        await attachedLater.start(stream: coordinator.events)
        let marker = AgentRuntimeEvent.runtimeNotice(
            title: "After sign out",
            detail: "Only the signed-out surface should remain"
        )
        runtime.emit(marker)
        try await current.waitForCount(3)
        try await attachedLater.waitForCount(2)

        let currentEvents = await current.snapshot()
        let laterEvents = await attachedLater.snapshot()
        XCTAssertEqual(
            currentEvents,
            [
                .authenticationRecoveryRequired(.signInExpired),
                .accountUpdated(.signedOut),
                marker,
            ]
        )
        XCTAssertEqual(
            laterEvents,
            [.accountUpdated(.signedOut), marker],
            "A late retired-transport auth event must not replay after logout."
        )
    }

    func testRecoveryAuthorizedBeforeLogoutIsDroppedWhenDeliveryResumesAfterLogout() async throws {
        let runtime = CoordinatorFakeRuntime()
        let recoveryDeliveryGate = InvocationGate(isOpen: false)
        let coordinator = SharedRuntimeCoordinator(
            runtime: runtime,
            eventAuthorizationBarrier: { event in
                guard case .authenticationRecoveryRequired = event else { return }
                await recoveryDeliveryGate.enter()
            }
        )
        let current = CoordinatorEventRecorder()
        await current.start(stream: coordinator.events)

        // Pause after the recovery event has been authorized but before its
        // authorization is revalidated at the serialized delivery boundary.
        runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        await recoveryDeliveryGate.waitForInvocationCount(1)

        // Logout advances the auth generation while the accepted recovery is
        // suspended. Once delivery resumes, it belongs to the old generation
        // and must not reach any window or become sticky for later windows.
        try await coordinator.logout()
        await recoveryDeliveryGate.open()
        let processed = AgentRuntimeEvent.runtimeNotice(
            title: "After delayed recovery",
            detail: "The stale recovery was discarded"
        )
        runtime.emit(processed)
        try await current.waitForCount(2)

        let attachedLater = CoordinatorEventRecorder()
        await attachedLater.start(stream: coordinator.events)
        let laterMarker = AgentRuntimeEvent.runtimeNotice(
            title: "Later window",
            detail: "No stale recovery replayed"
        )
        runtime.emit(laterMarker)
        try await current.waitForCount(3)
        try await attachedLater.waitForCount(2)

        let currentEvents = await current.snapshot()
        let laterEvents = await attachedLater.snapshot()
        XCTAssertEqual(
            currentEvents,
            [.accountUpdated(.signedOut), processed, laterMarker]
        )
        XCTAssertEqual(laterEvents, [.accountUpdated(.signedOut), laterMarker])
    }

    func testStalledSubscriberCoalescesAdjacentDeltasWhileActiveConsumerKeepsExactOrder() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(
            runtime: runtime,
            subscriberEventLimit: 2
        )
        let stalledStream = coordinator.events
        let active = CoordinatorEventRecorder()
        await active.start(stream: coordinator.events)

        let firstDelta = AgentRuntimeEvent.itemDelta(
            threadID: "thread-1",
            itemID: "item-1",
            delta: "hel"
        )
        let secondDelta = AgentRuntimeEvent.itemDelta(
            threadID: "thread-1",
            itemID: "item-1",
            delta: "lo"
        )
        let boundary = AgentRuntimeEvent.runtimeNotice(title: "Boundary", detail: "after delta")

        runtime.emit(firstDelta)
        try await active.waitForCount(1)
        runtime.emit(secondDelta)
        try await active.waitForCount(2)
        runtime.emit(boundary)
        try await active.waitForCount(3)

        let stalled = CoordinatorEventRecorder()
        await stalled.start(stream: stalledStream)
        try await stalled.waitForCount(2)

        let activeEvents = await active.snapshot()
        let stalledEvents = await stalled.snapshot()
        XCTAssertEqual(activeEvents, [firstDelta, secondDelta, boundary])
        XCTAssertEqual(
            stalledEvents,
            [
                .itemDelta(threadID: "thread-1", itemID: "item-1", delta: "hello"),
                boundary,
            ]
        )
    }

    func testStalledSubscriberBackpressuresSourceInsteadOfDroppingEvents() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(
            runtime: runtime,
            subscriberEventLimit: 2
        )
        let stalledStream = coordinator.events
        let active = CoordinatorEventRecorder()
        await active.start(stream: coordinator.events)

        let events: [AgentRuntimeEvent] = [
            .runtimeNotice(title: "First", detail: "one"),
            .runtimeNotice(title: "Second", detail: "two"),
            .runtimeNotice(title: "Third", detail: "three"),
            .runtimeNotice(title: "Fourth", detail: "four"),
        ]
        for (index, event) in events.enumerated() {
            runtime.emit(event)
            if index < 3 {
                try await active.waitForCount(index + 1)
            }
        }
        // The stalled subscriber's two-slot queue is full after the first
        // two events. The third event can still reach the active consumer,
        // but the shared source pump must remain blocked on the stalled
        // subscriber before it can process the fourth event. Waiting for the
        // active third event makes that backpressure boundary deterministic;
        // a bare Task.yield() was racy because the active consumer could
        // legitimately receive the third event before the snapshot.
        try await active.waitForCount(3)
        let activeBeforeDrain = await active.snapshot()
        XCTAssertEqual(activeBeforeDrain, Array(events.prefix(3)))

        let stalled = CoordinatorEventRecorder()
        await stalled.start(stream: stalledStream)
        try await stalled.waitForCount(events.count)
        try await active.waitForCount(events.count)

        let activeEvents = await active.snapshot()
        let stalledEvents = await stalled.snapshot()
        XCTAssertEqual(activeEvents, events)
        XCTAssertEqual(stalledEvents, events)
    }

    func testConcurrentConnectsShareOneHandshakeAndLaterWindowsUseItsSnapshot() async throws {
        let gate = InvocationGate(isOpen: false)
        let session = Self.session(label: "Connected once")
        let runtime = CoordinatorFakeRuntime(connectSession: session, connectGate: gate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let first = Task { try await coordinator.connect() }
        await gate.waitForInvocationCount(1)
        let second = Task { try await coordinator.connect() }
        for _ in 0 ..< 20 { await Task.yield() }

        let countBeforeOpening = await gate.invocationCount
        XCTAssertEqual(countBeforeOpening, 1)
        await gate.open()
        let firstSession = try await first.value
        let secondSession = try await second.value
        let attachedLater = try await coordinator.connect()

        XCTAssertEqual(firstSession, session)
        XCTAssertEqual(secondSession, session)
        XCTAssertEqual(attachedLater, session)
        let finalCount = await gate.invocationCount
        XCTAssertEqual(finalCount, 1)
    }

    func testRuntimeModelUpdateReplacesCachedCatalogForLaterWindows() async throws {
        let initial = Self.model("provider-model", executionMode: .checkingAgent)
        let verified = Self.model("provider-model", executionMode: .agent)
        let runtime = CoordinatorFakeRuntime(
            connectSession: Self.session(label: "Adaptive provider", models: [initial])
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let events = CoordinatorEventRecorder()
        await events.start(stream: coordinator.events)

        let firstWindow = try await coordinator.connect()
        XCTAssertEqual(firstWindow.availableModels, [initial])

        runtime.emit(.runtimeModelsUpdated([verified]))
        try await events.waitForCount(1)

        let attachedLater = try await coordinator.connect()
        XCTAssertEqual(attachedLater.availableModels, [verified])
        let connectCallCount = await runtime.connectCallCount
        let receivedEvents = await events.snapshot()
        XCTAssertEqual(connectCallCount, 1)
        XCTAssertEqual(receivedEvents, [.runtimeModelsUpdated([verified])])
    }

    func testRuntimeModelUpdateDuringConnectWinsOverOlderProviderSnapshot() async throws {
        let connectGate = InvocationGate(isOpen: false)
        let initial = Self.model("provider-model", executionMode: .checkingAgent)
        let verified = Self.model("provider-model", executionMode: .agent)
        let runtime = CoordinatorFakeRuntime(
            connectSession: Self.session(label: "Adaptive provider", models: [initial]),
            connectGate: connectGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let events = CoordinatorEventRecorder()
        await events.start(stream: coordinator.events)

        let connecting = Task { try await coordinator.connect() }
        await connectGate.waitForInvocationCount(1)
        runtime.emit(.runtimeModelsUpdated([verified]))
        try await events.waitForCount(1)
        await connectGate.open()

        let connected = try await connecting.value
        let attachedLater = try await coordinator.connect()
        XCTAssertEqual(connected.availableModels, [verified])
        XCTAssertEqual(attachedLater.availableModels, [verified])
        let connectCallCount = await runtime.connectCallCount
        XCTAssertEqual(connectCallCount, 1)
    }

    func testPaginationCompatibilityFailureDowngradesEveryWindowAndStopsAllEntryPointRetries() async throws {
        enum EntryPoint: CaseIterable {
            case read
            case resume
            case list

            var name: String {
                switch self {
                case .read: "read"
                case .resume: "resume"
                case .list: "list"
                }
            }
        }

        for code in [-32_601, -32_602] {
            for entryPoint in EntryPoint.allCases {
                let session = Self.session(
                    label: "History capable",
                    capabilities: [.threadHistoryPagination, .threadHistoryRevert]
                )
                let runtime = CoordinatorFakeRuntime(
                    connectSession: session,
                    historyPaginationFailureCode: code
                )
                let coordinator = SharedRuntimeCoordinator(runtime: runtime)
                let firstWindow = CoordinatorEventRecorder()
                let secondWindow = CoordinatorEventRecorder()
                await firstWindow.start(stream: coordinator.events)
                await secondWindow.start(stream: coordinator.events)

                let firstSession = try await coordinator.connect()
                let secondSession = try await coordinator.connect()
                XCTAssertTrue(firstSession.capabilities.contains(.threadHistoryPagination))
                XCTAssertTrue(secondSession.capabilities.contains(.threadHistoryPagination))

                do {
                    switch entryPoint {
                    case .read:
                        _ = try await coordinator.readThread(
                            id: "history-thread",
                            initialHistoryPage: RuntimeThreadHistoryPageRequest(limit: 12)
                        )
                    case .resume:
                        _ = try await coordinator.resumeThread(
                            id: "history-thread",
                            initialHistoryPage: RuntimeInitialThreadHistoryPageRequest(limit: 12)
                        )
                    case .list:
                        _ = try await coordinator.listThreadHistory(
                            id: "history-thread",
                            page: RuntimeThreadHistoryPageRequest(limit: 12)
                        )
                    }
                    XCTFail("The simulated older runtime accepted \(entryPoint.name).")
                } catch let AgentRuntimeError.requestFailed(receivedCode, _) {
                    XCTAssertEqual(receivedCode, code)
                } catch {
                    XCTFail("Unexpected pagination error: \(error)")
                }

                try await firstWindow.waitForCount(1)
                try await secondWindow.waitForCount(1)
                let expected = [AgentRuntimeEvent.runtimeCapabilitiesDowngraded(
                    .threadHistoryPagination
                )]
                let firstEvents = await firstWindow.snapshot()
                let secondEvents = await secondWindow.snapshot()
                XCTAssertEqual(firstEvents, expected)
                XCTAssertEqual(secondEvents, expected)

                let attachedLater = try await coordinator.connect()
                XCTAssertFalse(attachedLater.capabilities.contains(.threadHistoryPagination))
                XCTAssertTrue(attachedLater.capabilities.contains(.threadHistoryRevert))

                for retry in EntryPoint.allCases {
                    do {
                        switch retry {
                        case .read:
                            _ = try await coordinator.readThread(
                                id: "history-thread",
                                initialHistoryPage: RuntimeThreadHistoryPageRequest(limit: 12)
                            )
                        case .resume:
                            _ = try await coordinator.resumeThread(
                                id: "history-thread",
                                initialHistoryPage: RuntimeInitialThreadHistoryPageRequest(limit: 12)
                            )
                        case .list:
                            _ = try await coordinator.listThreadHistory(
                                id: "history-thread",
                                page: RuntimeThreadHistoryPageRequest(limit: 12)
                            )
                        }
                        XCTFail("A downgraded coordinator retried \(retry.name).")
                    } catch let AgentRuntimeError.unsupported(feature) {
                        XCTAssertEqual(feature, "paginated thread history")
                    } catch {
                        XCTFail("Unexpected retry error: \(error)")
                    }
                }

                let providerCalls = await runtime.historyOperationMethods
                XCTAssertEqual(providerCalls, [entryPoint.name])
            }
        }
    }

    func testHistoryRevertCompatibilityFailureDowngradesEveryWindowAndCachedSession() async throws {
        let session = Self.session(
            label: "Editable history",
            capabilities: [.threadHistoryPagination, .threadHistoryRevert]
        )
        let runtime = CoordinatorFakeRuntime(
            connectSession: session,
            historyRevertFailureCode: -32_601
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let firstWindow = CoordinatorEventRecorder()
        let secondWindow = CoordinatorEventRecorder()
        await firstWindow.start(stream: coordinator.events)
        await secondWindow.start(stream: coordinator.events)

        _ = try await coordinator.connect()
        _ = try await coordinator.connect()
        do {
            _ = try await coordinator.revertThread(
                id: "history-thread",
                beforeTurnID: "turn-new"
            )
            XCTFail("The simulated older runtime accepted native history editing.")
        } catch let AgentRuntimeError.requestFailed(code, _) {
            XCTAssertEqual(code, -32_601)
        }

        try await firstWindow.waitForCount(1)
        try await secondWindow.waitForCount(1)
        let expected = [AgentRuntimeEvent.runtimeCapabilitiesDowngraded(.threadHistoryRevert)]
        let firstEvents = await firstWindow.snapshot()
        let secondEvents = await secondWindow.snapshot()
        XCTAssertEqual(firstEvents, expected)
        XCTAssertEqual(secondEvents, expected)

        let attachedLater = try await coordinator.connect()
        XCTAssertFalse(attachedLater.capabilities.contains(.threadHistoryRevert))
        XCTAssertTrue(attachedLater.capabilities.contains(.threadHistoryPagination))

        do {
            _ = try await coordinator.revertThread(
                id: "history-thread",
                beforeTurnID: "turn-new"
            )
            XCTFail("A downgraded coordinator retried native history editing.")
        } catch let AgentRuntimeError.unsupported(feature) {
            XCTAssertEqual(feature, "thread history editing")
        }
        let revertCalls = await runtime.historyRevertCallCount
        XCTAssertEqual(revertCalls, 1)
    }

    func testDisconnectEventInvalidatesTheCachedSessionBeforeSubscribersSeeIt() async throws {
        let gate = InvocationGate(isOpen: true)
        let runtime = CoordinatorFakeRuntime(connectGate: gate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let events = CoordinatorEventRecorder()
        await events.start(stream: coordinator.events)

        _ = try await coordinator.connect()
        _ = try await coordinator.connect()
        let countBeforeDisconnect = await gate.invocationCount
        XCTAssertEqual(countBeforeDisconnect, 1)

        runtime.emit(.connectionChanged(.disconnected))
        try await events.waitForCount(1)
        _ = try await coordinator.connect()

        let countAfterDisconnect = await gate.invocationCount
        XCTAssertEqual(countAfterDisconnect, 2)
    }

    func testConcurrentAccountRefreshesAreCoalescedAndReplaceTheCachedSnapshot() async throws {
        let refreshGate = InvocationGate(isOpen: false)
        let initial = Self.session(label: "Initial")
        let refreshed = Self.session(label: "Refreshed")
        let runtime = CoordinatorFakeRuntime(
            connectSession: initial,
            refreshSession: refreshed,
            refreshGate: refreshGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        _ = try await coordinator.connect()

        let first = Task { try await coordinator.refreshAccount() }
        await refreshGate.waitForInvocationCount(1)
        let second = Task { try await coordinator.refreshAccount() }
        for _ in 0 ..< 20 { await Task.yield() }

        let countBeforeOpening = await refreshGate.invocationCount
        XCTAssertEqual(countBeforeOpening, 1)
        await refreshGate.open()
        let firstSession = try await first.value
        let secondSession = try await second.value
        let attachedLater = try await coordinator.connect()
        let finalRefreshCount = await refreshGate.invocationCount
        let finalConnectCount = await runtime.connectCallCount
        XCTAssertEqual(firstSession, refreshed)
        XCTAssertEqual(secondSession, refreshed)
        XCTAssertEqual(attachedLater, refreshed)
        XCTAssertEqual(finalRefreshCount, 1)
        XCTAssertEqual(finalConnectCount, 1)
    }

    func testRetirementRejectsEveryNewOperationClassBeforeDisconnectFinishes() async throws {
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(
            disconnectGate: disconnectGate,
            loginStartResult: Self.loginStart(loginID: "must-not-start")
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let retirement = Task { await coordinator.retire() }
        await disconnectGate.waitForInvocationCount(1)

        await assertRetiredBoundary { _ = try await coordinator.connect() }
        await assertRetiredBoundary { _ = try await coordinator.refreshAccount() }
        await assertRetiredBoundary {
            _ = try await coordinator.startLogin(methodID: "chatgpt")
        }
        await assertRetiredBoundary { try await coordinator.cancelLogin(id: "login-1") }
        await assertRetiredBoundary { try await coordinator.logout() }
        await assertRetiredBoundary {
            _ = try await coordinator.listThreads(limit: 1, archived: false)
        }
        await assertRetiredBoundary {
            _ = try await coordinator.readThread(
                id: "thread-1",
                initialHistoryPage: RuntimeThreadHistoryPageRequest(limit: 1)
            )
        }

        let providerCalls = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(
            providerCalls,
            CoordinatorFakeRuntime.RetirementSensitiveCallCounts(disconnect: 1)
        )

        await disconnectGate.open()
        await retirement.value
    }

    func testRetirementDropsLateProviderEventsAndFinishesEverySubscriber() async throws {
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(disconnectGate: disconnectGate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let first = CoordinatorEventRecorder()
        let second = CoordinatorEventRecorder()
        await first.start(stream: coordinator.events)
        await second.start(stream: coordinator.events)

        let beforeRetirement = AgentRuntimeEvent.runtimeNotice(
            title: "Current generation",
            detail: "visible"
        )
        runtime.emit(beforeRetirement)
        try await first.waitForCount(1)
        try await second.waitForCount(1)

        let retirement = Task { await coordinator.retire() }
        await disconnectGate.waitForInvocationCount(1)
        runtime.emit(.runtimeNotice(title: "Retired generation", detail: "must be ignored"))
        runtime.emit(.itemDelta(threadID: "old-thread", itemID: "old-item", delta: "stale"))
        await disconnectGate.open()
        await retirement.value
        try await first.waitForFinish()
        try await second.waitForFinish()

        let firstEvents = await first.snapshot()
        let secondEvents = await second.snapshot()
        XCTAssertEqual(firstEvents, [beforeRetirement])
        XCTAssertEqual(secondEvents, [beforeRetirement])
    }

    func testRetirementAbortsAFullUndrainedSubscriberQueue() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(
            runtime: runtime,
            subscriberEventLimit: 1
        )
        // Keep the stream alive without starting a consumer. The first event
        // fills its queue and the second suspends the shared source pump.
        let stalledStream = coordinator.events
        runtime.emit(.runtimeNotice(title: "Buffered", detail: "must be discarded"))
        runtime.emit(.runtimeNotice(title: "Blocked", detail: "must be unblocked"))
        for _ in 0 ..< 50 { await Task.yield() }

        let retirement = Task { await coordinator.retire() }
        try await Self.awaitCompletion(retirement)

        // Retiring is a generation fence, so neither the buffered event nor
        // the yield that was waiting for queue space may drain afterward.
        let recorder = CoordinatorEventRecorder()
        await recorder.start(stream: stalledStream)
        try await recorder.waitForFinish()
        let events = await recorder.snapshot()
        XCTAssertEqual(events, [])
        let disconnects = await runtime.disconnectCallCount
        XCTAssertEqual(disconnects, 1)
    }

    func testRetirementDiscardsEventsBufferedBeforeReplacementCanObserveThem() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(
            runtime: runtime,
            subscriberEventLimit: 4
        )
        let oldWindowStream = coordinator.events

        runtime.emit(.runtimeNotice(title: "Old generation", detail: "queued"))
        for _ in 0 ..< 50 { await Task.yield() }
        await coordinator.retire()

        let recorder = CoordinatorEventRecorder()
        await recorder.start(stream: oldWindowStream)
        try await recorder.waitForFinish()
        let events = await recorder.snapshot()
        XCTAssertTrue(events.isEmpty, "A retired runtime leaked a buffered event to an old window.")
    }

    func testRetirementWaitsForSuspendedTurnBeforeDisconnecting() async throws {
        let startTurnGate = InvocationGate(isOpen: false)
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(
            disconnectGate: disconnectGate,
            startTurnGate: startTurnGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let turn = Task {
            try await coordinator.startTurn(
                StartTurnRequest(threadID: "thread-1", text: "Finish with the old settings")
            )
        }
        await startTurnGate.waitForInvocationCount(1)

        let retirement = Task { await coordinator.retire() }
        try await waitForRetirementAdmission(coordinator)
        await assertRetiredBoundary { _ = try await coordinator.connect() }
        let disconnectsWhileTurnWasSuspended = await runtime.disconnectCallCount
        XCTAssertEqual(disconnectsWhileTurnWasSuspended, 0)

        await startTurnGate.open()
        try await turn.value
        await disconnectGate.waitForInvocationCount(1)
        await disconnectGate.open()
        await retirement.value

        let counts = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(counts.startTurn, 1)
        XCTAssertEqual(counts.disconnect, 1)
    }

    func testRetirementWaitsForInFlightConnectAttempt() async throws {
        let connectGate = InvocationGate(isOpen: false)
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(
            connectGate: connectGate,
            disconnectGate: disconnectGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let connect = Task { try await coordinator.connect() }
        await connectGate.waitForInvocationCount(1)
        let retirement = Task { await coordinator.retire() }
        try await waitForRetirementAdmission(coordinator)
        await assertRetiredBoundary {
            _ = try await coordinator.listThreads(limit: 1, archived: false)
        }
        let disconnectsWhileConnectWasSuspended = await runtime.disconnectCallCount
        XCTAssertEqual(disconnectsWhileConnectWasSuspended, 0)

        await connectGate.open()
        do {
            _ = try await connect.value
            XCTFail("An in-flight connection returned a session after retirement.")
        } catch {
            assertRetiredBoundary(error)
        }
        await disconnectGate.waitForInvocationCount(1)
        await disconnectGate.open()
        await retirement.value

        let counts = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(counts.connect, 1)
        XCTAssertEqual(counts.disconnect, 1)
    }

    func testRetirementWaitsForInFlightRefreshAttempt() async throws {
        let refreshGate = InvocationGate(isOpen: false)
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(
            refreshGate: refreshGate,
            disconnectGate: disconnectGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let refresh = Task { try await coordinator.refreshAccount() }
        await refreshGate.waitForInvocationCount(1)
        let retirement = Task { await coordinator.retire() }
        try await waitForRetirementAdmission(coordinator)
        await assertRetiredBoundary { _ = try await coordinator.connect() }
        let disconnectsWhileRefreshWasSuspended = await runtime.disconnectCallCount
        XCTAssertEqual(disconnectsWhileRefreshWasSuspended, 0)

        await refreshGate.open()
        do {
            _ = try await refresh.value
            XCTFail("An in-flight refresh returned a session after retirement.")
        } catch {
            assertRetiredBoundary(error)
        }
        await disconnectGate.waitForInvocationCount(1)
        await disconnectGate.open()
        await retirement.value

        let counts = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(counts.refresh, 1)
        XCTAssertEqual(counts.disconnect, 1)
    }

    func testRetirementWaitsForInFlightLoginBeforeDisconnecting() async throws {
        let loginGate = InvocationGate(isOpen: false)
        let disconnectGate = InvocationGate(isOpen: false)
        let loginStart = Self.loginStart(loginID: "retiring-login")
        let runtime = CoordinatorFakeRuntime(
            disconnectGate: disconnectGate,
            loginStartResult: loginStart,
            loginStartGate: loginGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let login = Task { try await coordinator.startLogin(methodID: loginStart.method.id) }
        await loginGate.waitForInvocationCount(1)
        let retirement = Task { await coordinator.retire() }
        try await waitForRetirementAdmission(coordinator)
        await assertRetiredBoundary { _ = try await coordinator.connect() }
        let disconnectsWhileLoginWasSuspended = await runtime.disconnectCallCount
        XCTAssertEqual(disconnectsWhileLoginWasSuspended, 0)

        await loginGate.open()
        do {
            _ = try await login.value
            XCTFail("An in-flight login crossed the retired provider boundary.")
        } catch {
            assertRetiredBoundary(error)
        }
        await disconnectGate.waitForInvocationCount(1)
        await disconnectGate.open()
        await retirement.value

        let counts = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(counts.startLogin, 1)
        XCTAssertEqual(counts.cancelLogin, 1)
        XCTAssertEqual(counts.disconnect, 1)
    }

    func testRetirementWaitsForAlreadyStartedLogoutBeforeDisconnecting() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(
            disconnectGate: disconnectGate,
            logoutGate: logoutGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let logout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)
        let retirement = Task { await coordinator.retire() }
        try await waitForRetirementAdmission(coordinator)
        await assertRetiredBoundary {
            _ = try await coordinator.listThreads(limit: 1, archived: false)
        }
        let disconnectsWhileLogoutWasSuspended = await runtime.disconnectCallCount
        XCTAssertEqual(disconnectsWhileLogoutWasSuspended, 0)

        await logoutGate.open()
        try await logout.value
        await disconnectGate.waitForInvocationCount(1)
        await disconnectGate.open()
        await retirement.value

        let counts = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(counts.logout, 1)
        XCTAssertEqual(counts.disconnect, 1)
    }

    func testOperationsWaitingForLogoutRecheckRetirementBeforeCallingProvider() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(
            disconnectGate: disconnectGate,
            logoutGate: logoutGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let logout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)
        let connect = Task { try await coordinator.connect() }
        let refresh = Task { try await coordinator.refreshAccount() }
        let cancellation = Task { try await coordinator.cancelLogin(id: "waiting-login") }
        for _ in 0 ..< 20 { await Task.yield() }

        let callsBeforeRetirement = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(callsBeforeRetirement.connect, 0)
        XCTAssertEqual(callsBeforeRetirement.refresh, 0)
        XCTAssertEqual(callsBeforeRetirement.cancelLogin, 0)

        let retirement = Task { await coordinator.retire() }
        try await waitForRetirementAdmission(coordinator)
        await assertRetiredBoundary {
            _ = try await coordinator.listThreads(limit: 1, archived: false)
        }
        await logoutGate.open()
        try await logout.value

        do {
            _ = try await connect.value
            XCTFail("A connect waiting for logout crossed retirement.")
        } catch {
            assertRetiredBoundary(error)
        }
        do {
            _ = try await refresh.value
            XCTFail("A refresh waiting for logout crossed retirement.")
        } catch {
            assertRetiredBoundary(error)
        }
        do {
            try await cancellation.value
            XCTFail("A login cancellation waiting for logout crossed retirement.")
        } catch {
            assertRetiredBoundary(error)
        }

        await disconnectGate.waitForInvocationCount(1)
        await disconnectGate.open()
        await retirement.value
        let finalCalls = await runtime.retirementSensitiveCallCounts
        XCTAssertEqual(finalCalls.connect, 0)
        XCTAssertEqual(finalCalls.refresh, 0)
        XCTAssertEqual(finalCalls.cancelLogin, 0)
    }

    func testConcurrentRetirementsAndLaterDisconnectShareOneProviderDisconnect() async {
        let disconnectGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(disconnectGate: disconnectGate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let first = Task { await coordinator.retire() }
        let second = Task { await coordinator.retire() }
        let third = Task { await coordinator.retire() }
        await disconnectGate.waitForInvocationCount(1)
        for _ in 0 ..< 50 { await Task.yield() }
        let callsWhileRetirementsWerePending = await runtime.disconnectCallCount
        XCTAssertEqual(callsWhileRetirementsWerePending, 1)

        await disconnectGate.open()
        await first.value
        await second.value
        await third.value
        await coordinator.disconnect()
        await coordinator.retire()

        let finalCalls = await runtime.disconnectCallCount
        XCTAssertEqual(finalCalls, 1)
    }

    func testLogoutInvalidatesCachedSessionBeforeProviderFinishes() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(logoutGate: logoutGate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        _ = try await coordinator.connect()

        let logout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)
        let reconnect = Task { try await coordinator.connect() }
        for _ in 0 ..< 20 { await Task.yield() }

        let connectsDuringLogout = await runtime.connectCallCount
        XCTAssertEqual(connectsDuringLogout, 1)

        await logoutGate.open()
        try await logout.value
        _ = try await reconnect.value
        let connectsAfterLogout = await runtime.connectCallCount
        XCTAssertEqual(connectsAfterLogout, 2)
    }

    func testSuccessfulLogoutBroadcastsSignedOutBoundaryWhenProviderEmitsNoAccountEvent() async throws {
        let runtime = CoordinatorFakeRuntime()
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let first = CoordinatorEventRecorder()
        let second = CoordinatorEventRecorder()
        await first.start(stream: coordinator.events)
        await second.start(stream: coordinator.events)

        try await coordinator.logout()
        try await first.waitForCount(1)
        try await second.waitForCount(1)

        let expected = [AgentRuntimeEvent.accountUpdated(.signedOut)]
        let firstEvents = await first.snapshot()
        let secondEvents = await second.snapshot()
        XCTAssertEqual(firstEvents, expected)
        XCTAssertEqual(secondEvents, expected)
    }

    func testConcurrentLogoutsInvokeProviderOnceAndBroadcastOneSyntheticBoundary() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(logoutGate: logoutGate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let firstRecorder = CoordinatorEventRecorder()
        let secondRecorder = CoordinatorEventRecorder()
        await firstRecorder.start(stream: coordinator.events)
        await secondRecorder.start(stream: coordinator.events)

        let firstLogout = Task { try await coordinator.logout() }
        let secondLogout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)
        for _ in 0 ..< 100 { await Task.yield() }

        let callsWhileBothCallersAreWaiting = await runtime.logoutCallCount
        XCTAssertEqual(callsWhileBothCallersAreWaiting, 1)

        await logoutGate.open()
        try await firstLogout.value
        try await secondLogout.value
        try await firstRecorder.waitForCount(1)
        try await secondRecorder.waitForCount(1)

        let expected = [AgentRuntimeEvent.accountUpdated(.signedOut)]
        let firstEvents = await firstRecorder.snapshot()
        let secondEvents = await secondRecorder.snapshot()
        let finalProviderCallCount = await runtime.logoutCallCount
        XCTAssertEqual(finalProviderCallCount, 1)
        XCTAssertEqual(firstEvents, expected)
        XCTAssertEqual(secondEvents, expected)
    }

    func testLogoutDoesNotReleaseConnectWaitersUntilBoundaryBroadcastFinishes() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(logoutGate: logoutGate)
        let coordinator = SharedRuntimeCoordinator(
            runtime: runtime,
            subscriberEventLimit: 1
        )
        let stalledStream = coordinator.events
        let active = CoordinatorEventRecorder()
        await active.start(stream: coordinator.events)

        _ = try await coordinator.connect()
        runtime.emit(.runtimeNotice(title: "Fill", detail: "stalled subscriber queue"))
        try await active.waitForCount(1)

        let logout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)
        let reconnect = Task { try await coordinator.connect() }
        await logoutGate.open()
        try await active.waitForCount(2)

        // The stalled subscriber still owns the first queue slot. The shared
        // logout attempt must remain in-flight until its synthetic boundary
        // can be delivered, so a waiting connect cannot start early.
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        let connectsBeforeBoundaryDrain = await runtime.connectCallCount
        XCTAssertEqual(
            connectsBeforeBoundaryDrain,
            1,
            "A reconnect started before every window observed sign-out."
        )

        let stalled = CoordinatorEventRecorder()
        await stalled.start(stream: stalledStream)
        try await stalled.waitForCount(2)
        try await logout.value
        _ = try await reconnect.value

        let finalConnects = await runtime.connectCallCount
        XCTAssertEqual(finalConnects, 2)
    }

    func testAccountOperationIsRejectedWhileProviderLogoutIsPending() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(logoutGate: logoutGate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let logout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)

        do {
            try await coordinator.startTurn(
                StartTurnRequest(threadID: "thread-1", text: "Must not cross sign-out")
            )
            XCTFail("A sibling window sent a turn while logout was pending.")
        } catch {
            assertAccountBoundary(error)
        }

        let providerStartTurnCount = await runtime.startTurnCallCount
        XCTAssertEqual(providerStartTurnCount, 0)

        await logoutGate.open()
        try await logout.value
    }

    func testLogoutWaitsForInFlightAccountOperationBeforeProviderLogoutBegins() async throws {
        let startTurnGate = InvocationGate(isOpen: false)
        let logoutGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(
            logoutGate: logoutGate,
            startTurnGate: startTurnGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let turn = Task {
            try await coordinator.startTurn(
                StartTurnRequest(threadID: "thread-1", text: "Finish before sign-out")
            )
        }
        await startTurnGate.waitForInvocationCount(1)

        let logout = Task { try await coordinator.logout() }
        let boundaryBecameActive = await waitForAccountBoundary(coordinator)
        XCTAssertTrue(boundaryBecameActive, "Logout never established its account boundary.")
        let providerLogoutsWhileTurnWasActive = await runtime.logoutCallCount
        XCTAssertEqual(
            providerLogoutsWhileTurnWasActive,
            0,
            "Provider logout crossed an in-flight account operation."
        )

        await startTurnGate.open()
        try await turn.value
        await logoutGate.waitForInvocationCount(1)
        await logoutGate.open()
        try await logout.value

        let startTurnCalls = await runtime.startTurnCallCount
        let logoutCalls = await runtime.logoutCallCount
        XCTAssertEqual(startTurnCalls, 1)
        XCTAssertEqual(logoutCalls, 1)
    }

    func testLateLoginIsCancelledBeforeProviderLogoutBegins() async throws {
        let loginStartGate = InvocationGate(isOpen: false)
        let cancelLoginGate = InvocationGate(isOpen: false)
        let logoutGate = InvocationGate(isOpen: false)
        let loginStart = Self.loginStart(loginID: "late-login")
        let runtime = CoordinatorFakeRuntime(
            logoutGate: logoutGate,
            loginStartResult: loginStart,
            loginStartGate: loginStartGate,
            cancelLoginGate: cancelLoginGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let login = Task { try await coordinator.startLogin(methodID: loginStart.method.id) }
        await loginStartGate.waitForInvocationCount(1)

        let logout = Task { try await coordinator.logout() }
        let boundaryBecameActive = await waitForAccountBoundary(coordinator)
        XCTAssertTrue(boundaryBecameActive, "Logout never established its account boundary.")
        let providerLogoutsBeforeLoginReturns = await runtime.logoutCallCount
        XCTAssertEqual(providerLogoutsBeforeLoginReturns, 0)

        await loginStartGate.open()
        await cancelLoginGate.waitForInvocationCount(1)

        let cancelledIDs = await runtime.cancelledLoginIDs
        let providerLogoutsDuringCancellation = await runtime.logoutCallCount
        XCTAssertEqual(cancelledIDs, [loginStart.loginID])
        XCTAssertEqual(
            providerLogoutsDuringCancellation,
            0,
            "Provider logout began before the invalidated login was cancelled."
        )

        await cancelLoginGate.open()
        await logoutGate.waitForInvocationCount(1)

        do {
            _ = try await login.value
            XCTFail("A login created before logout crossed the account boundary.")
        } catch {
            assertAccountBoundary(error)
        }

        await logoutGate.open()
        try await logout.value

        let loginStartCalls = await runtime.loginStartCallCount
        let cancelLoginCalls = await runtime.cancelLoginCallCount
        let logoutCalls = await runtime.logoutCallCount
        XCTAssertEqual(loginStartCalls, 1)
        XCTAssertEqual(cancelLoginCalls, 1)
        XCTAssertEqual(logoutCalls, 1)
    }

    func testPendingCompletedLoginIsCancelledBeforeLogoutBegins() async throws {
        let cancelLoginGate = InvocationGate(isOpen: false)
        let logoutGate = InvocationGate(isOpen: false)
        let loginStart = Self.loginStart(loginID: "pending-login")
        let runtime = CoordinatorFakeRuntime(
            logoutGate: logoutGate,
            loginStartResult: loginStart,
            cancelLoginGate: cancelLoginGate
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        _ = try await coordinator.startLogin(methodID: loginStart.method.id)
        let loginStartCallCount = await runtime.loginStartCallCount
        XCTAssertEqual(loginStartCallCount, 1)

        let logout = Task { try await coordinator.logout() }
        await cancelLoginGate.waitForInvocationCount(1)
        let logoutCallCountBeforeCancellation = await runtime.logoutCallCount
        XCTAssertEqual(
            logoutCallCountBeforeCancellation,
            0,
            "Provider logout began before the pending login was cancelled."
        )

        await cancelLoginGate.open()
        await logoutGate.waitForInvocationCount(1)
        await logoutGate.open()
        try await logout.value

        let cancelledLoginIDs = await runtime.cancelledLoginIDs
        let logoutCallCount = await runtime.logoutCallCount
        XCTAssertEqual(cancelledLoginIDs, [loginStart.loginID])
        XCTAssertEqual(logoutCallCount, 1)
    }

    func testLoginRequestedDuringLogoutIsRejectedWithoutProviderCall() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let loginStart = Self.loginStart(loginID: "blocked-login")
        let runtime = CoordinatorFakeRuntime(
            logoutGate: logoutGate,
            loginStartResult: loginStart
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        let logout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)

        do {
            _ = try await coordinator.startLogin(methodID: loginStart.method.id)
            XCTFail("A login requested during logout crossed the account boundary.")
        } catch {
            assertAccountBoundary(error)
        }

        let loginStartCallCount = await runtime.loginStartCallCount
        XCTAssertEqual(loginStartCallCount, 0)
        await logoutGate.open()
        try await logout.value
    }

    func testFailedLoginStartDoesNotLeaveLogoutWaitingForever() async throws {
        let logoutGate = InvocationGate(isOpen: false)
        let runtime = CoordinatorFakeRuntime(logoutGate: logoutGate)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)

        do {
            _ = try await coordinator.startLogin(methodID: "unsupported")
            XCTFail("The fake runtime unexpectedly started a login.")
        } catch {
            // Expected provider failure; the operation token must still drain.
        }

        let logout = Task { try await coordinator.logout() }
        await logoutGate.waitForInvocationCount(1)
        await logoutGate.open()
        try await logout.value

        let logoutCallCount = await runtime.logoutCallCount
        XCTAssertEqual(logoutCallCount, 1)
    }

    func testProviderLogoutEventIsReplacedByOneCanonicalBoundaryForEverySubscriber() async throws {
        for iteration in 0 ..< 25 {
            let providerAuth = RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: "provider-boundary-\(iteration)",
                requiresAuthentication: true
            )
            let providerEvent = AgentRuntimeEvent.accountUpdated(providerAuth)
            let syntheticEvent = AgentRuntimeEvent.accountUpdated(.signedOut)
            let processed = AgentRuntimeEvent.runtimeNotice(
                title: "Processed \(iteration)",
                detail: "after provider boundary"
            )
            let runtime = CoordinatorFakeRuntime(logoutEvent: providerEvent)
            let coordinator = SharedRuntimeCoordinator(runtime: runtime)
            let first = CoordinatorEventRecorder()
            let second = CoordinatorEventRecorder()
            await first.start(stream: coordinator.events)
            await second.start(stream: coordinator.events)

            try await coordinator.logout()
            runtime.emit(processed)
            try await first.waitForCount(2)
            try await second.waitForCount(2)

            let firstEvents = await first.snapshot()
            let secondEvents = await second.snapshot()
            XCTAssertEqual(firstEvents, secondEvents, "Subscribers diverged in iteration \(iteration).")
            XCTAssertEqual(firstEvents, [syntheticEvent, processed])
            XCTAssertEqual(secondEvents, [syntheticEvent, processed])
        }
    }

    func testSignedInProviderEventsCannotReopenLogoutBoundary() async throws {
        let staleSignedIn = AgentRuntimeEvent.accountUpdated(
            RuntimeAuthState(
                mode: .chatgpt,
                email: "stale@example.com",
                planLabel: "plus",
                requiresAuthentication: true
            )
        )
        let syntheticEvent = AgentRuntimeEvent.accountUpdated(.signedOut)
        let processed = AgentRuntimeEvent.runtimeNotice(
            title: "Processed",
            detail: "after stale signed-in events"
        )
        let runtime = CoordinatorFakeRuntime(logoutEvent: staleSignedIn)
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let first = CoordinatorEventRecorder()
        let second = CoordinatorEventRecorder()
        await first.start(stream: coordinator.events)
        await second.start(stream: coordinator.events)

        try await coordinator.logout()
        runtime.emit(staleSignedIn)
        runtime.emit(processed)
        try await first.waitForCount(2)
        try await second.waitForCount(2)

        let firstEvents = await first.snapshot()
        let secondEvents = await second.snapshot()
        XCTAssertEqual(firstEvents, [syntheticEvent, processed])
        XCTAssertEqual(secondEvents, [syntheticEvent, processed])
    }

    private func assertAccountBoundary(
        _ error: any Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let AgentRuntimeError.requestFailed(code, message) = error else {
            XCTFail("Expected an account-boundary error, got \(error).", file: file, line: line)
            return
        }
        XCTAssertEqual(code, -32_100, file: file, line: line)
        XCTAssertEqual(message, "Account sign-out is in progress.", file: file, line: line)
    }

    private func assertRetiredBoundary<Result>(
        _ operation: () async throws -> Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("A provider operation crossed retirement.", file: file, line: line)
        } catch {
            assertRetiredBoundary(error, file: file, line: line)
        }
    }

    private func assertRetiredBoundary(
        _ error: any Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let AgentRuntimeError.requestFailed(code, message) = error else {
            XCTFail("Expected a retired-runtime error, got \(error).", file: file, line: line)
            return
        }
        XCTAssertEqual(code, -32_101, file: file, line: line)
        XCTAssertEqual(
            message,
            "Provider settings changed. Reconnect using the current configuration.",
            file: file,
            line: line
        )
    }

    private func waitForAccountBoundary(_ coordinator: SharedRuntimeCoordinator) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            do {
                _ = try await coordinator.listThreads(limit: 1, archived: false)
            } catch let AgentRuntimeError.requestFailed(code, _) where code == -32_100 {
                return true
            } catch {
                XCTFail("Unexpected account operation error: \(error)")
                return false
            }
            await Task.yield()
        }
        return false
    }

    private func waitForRetirementAdmission(
        _ coordinator: SharedRuntimeCoordinator
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await coordinator.isRetired { return }
            await Task.yield()
        }
        throw CoordinatorEventRecorder.WaitError.timedOut
    }

    private static func loginStart(loginID: String) -> RuntimeLoginStart {
        RuntimeLoginStart(
            method: RuntimeLoginMethod(
                id: "chatgpt",
                displayName: "ChatGPT",
                detail: "Browser sign-in",
                ceremony: .browser
            ),
            loginID: loginID,
            authURL: URL(string: "https://example.test/login"),
            verificationURL: nil,
            userCode: nil
        )
    }

    private static func session(
        label: String,
        models: [RuntimeModel] = [],
        capabilities: RuntimeCapabilities = []
    ) -> RuntimeSession {
        RuntimeSession(
            runtime: .local,
            displayName: label,
            accountLabel: label,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: models,
            capabilities: capabilities
        )
    }

    private static func authenticatedSession(label: String) -> RuntimeSession {
        let auth = RuntimeAuthState(
            mode: .chatgpt,
            email: "person@example.com",
            planLabel: "pro",
            requiresAuthentication: true
        )
        return RuntimeSession(
            runtime: .local,
            displayName: label,
            accountLabel: auth.email,
            planLabel: auth.planLabel,
            auth: auth,
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )
    }

    private static func model(
        _ id: String,
        executionMode: RuntimeModelExecutionMode
    ) -> RuntimeModel {
        RuntimeModel(
            id: id,
            displayName: id,
            description: nil,
            isDefault: true,
            defaultReasoningEffort: nil,
            reasoningEfforts: [],
            executionMode: executionMode,
            taskCapabilities: executionMode == .agent ? [.tools, .terminal] : []
        )
    }

    private static func awaitCompletion(
        _ task: Task<Void, Never>,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw CoordinatorEventRecorder.WaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private actor CoordinatorFakeRuntime: AgentRuntime {
    struct RetirementSensitiveCallCounts: Equatable {
        var connect = 0
        var disconnect = 0
        var refresh = 0
        var startLogin = 0
        var cancelLogin = 0
        var logout = 0
        var listThreads = 0
        var startTurn = 0
        var history = 0
    }

    nonisolated let kind = AgentRuntimeKind.local
    nonisolated var events: AsyncStream<AgentRuntimeEvent> {
        eventAccessProbe.recordAccess()
        return sourceEvents
    }

    nonisolated var eventStreamAccessCount: Int { eventAccessProbe.count }

    private nonisolated let sourceEvents: AsyncStream<AgentRuntimeEvent>
    private nonisolated let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private nonisolated let eventAccessProbe = EventAccessProbe()
    private let connectSession: RuntimeSession
    private let refreshSession: RuntimeSession
    private let connectGate: InvocationGate?
    private let refreshGate: InvocationGate?
    private let disconnectGate: InvocationGate?
    private let logoutGate: InvocationGate?
    private let loginStartResult: RuntimeLoginStart?
    private let loginStartGate: InvocationGate?
    private let cancelLoginGate: InvocationGate?
    private let startTurnGate: InvocationGate?
    private let logoutEvent: AgentRuntimeEvent?
    private let historyPaginationFailureCode: Int?
    private let historyRevertFailureCode: Int?
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var logoutCallCount = 0
    private(set) var loginStartCallCount = 0
    private(set) var cancelLoginCallCount = 0
    private(set) var startTurnCallCount = 0
    private(set) var listThreadsCallCount = 0
    private(set) var historyOperationMethods: [String] = []
    private(set) var historyRevertCallCount = 0
    private(set) var cancelledLoginIDs: [String] = []

    init(
        connectSession: RuntimeSession? = nil,
        refreshSession: RuntimeSession? = nil,
        connectGate: InvocationGate? = nil,
        refreshGate: InvocationGate? = nil,
        disconnectGate: InvocationGate? = nil,
        logoutGate: InvocationGate? = nil,
        loginStartResult: RuntimeLoginStart? = nil,
        loginStartGate: InvocationGate? = nil,
        cancelLoginGate: InvocationGate? = nil,
        startTurnGate: InvocationGate? = nil,
        logoutEvent: AgentRuntimeEvent? = nil,
        historyPaginationFailureCode: Int? = nil,
        historyRevertFailureCode: Int? = nil
    ) {
        let fallback = RuntimeSession(
            runtime: .local,
            displayName: "Fake",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )
        self.connectSession = connectSession ?? fallback
        self.refreshSession = refreshSession ?? connectSession ?? fallback
        self.connectGate = connectGate
        self.refreshGate = refreshGate
        self.disconnectGate = disconnectGate
        self.logoutGate = logoutGate
        self.loginStartResult = loginStartResult
        self.loginStartGate = loginStartGate
        self.cancelLoginGate = cancelLoginGate
        self.startTurnGate = startTurnGate
        self.logoutEvent = logoutEvent
        self.historyPaginationFailureCode = historyPaginationFailureCode
        self.historyRevertFailureCode = historyRevertFailureCode
        let pair = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        sourceEvents = pair.stream
        eventContinuation = pair.continuation
    }

    nonisolated func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func connect() async throws -> RuntimeSession {
        connectCallCount += 1
        if let connectGate { await connectGate.enter() }
        return connectSession
    }

    func disconnect() async {
        disconnectCallCount += 1
        if let disconnectGate { await disconnectGate.enter() }
    }

    func startLogin(methodID _: String) async throws -> RuntimeLoginStart {
        loginStartCallCount += 1
        if let loginStartGate { await loginStartGate.enter() }
        guard let loginStartResult else {
            throw AgentRuntimeError.unsupported("fake account login")
        }
        return loginStartResult
    }

    func cancelLogin(id: String) async throws {
        cancelLoginCallCount += 1
        cancelledLoginIDs.append(id)
        if let cancelLoginGate { await cancelLoginGate.enter() }
    }

    func refreshAccount() async throws -> RuntimeSession {
        refreshCallCount += 1
        if let refreshGate { await refreshGate.enter() }
        return refreshSession
    }

    func logout() async throws {
        logoutCallCount += 1
        if let logoutGate { await logoutGate.enter() }
        if let logoutEvent { emit(logoutEvent) }
    }

    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] {
        listThreadsCallCount += 1
        return []
    }

    var retirementSensitiveCallCounts: RetirementSensitiveCallCounts {
        RetirementSensitiveCallCounts(
            connect: connectCallCount,
            disconnect: disconnectCallCount,
            refresh: refreshCallCount,
            startLogin: loginStartCallCount,
            cancelLogin: cancelLoginCallCount,
            logout: logoutCallCount,
            listThreads: listThreadsCallCount,
            startTurn: startTurnCallCount,
            history: historyOperationMethods.count
        )
    }

    func readThread(id _: String) async throws -> RuntimeConversation {
        throw AgentRuntimeError.unsupported("fake thread reading")
    }

    func readThread(
        id _: String,
        initialHistoryPage _: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        historyOperationMethods.append("read")
        try throwHistoryPaginationFailure()
    }

    func resumeThread(
        id _: String,
        initialHistoryPage _: RuntimeInitialThreadHistoryPageRequest
    ) async throws -> RuntimeThreadResumeResult {
        historyOperationMethods.append("resume")
        try throwHistoryPaginationFailure()
    }

    func listThreadHistory(
        id _: String,
        page _: RuntimeThreadHistoryPageRequest
    ) async throws -> RuntimeThreadHistoryPage {
        historyOperationMethods.append("list")
        try throwHistoryPaginationFailure()
    }

    func revertThread(
        id _: String,
        beforeTurnID _: String
    ) async throws -> RuntimeThreadRevertResult {
        historyRevertCallCount += 1
        if let historyRevertFailureCode {
            throw AgentRuntimeError.requestFailed(
                code: historyRevertFailureCode,
                message: "simulated unsupported history revert"
            )
        }
        throw AgentRuntimeError.unsupported("fake history revert")
    }

    private func throwHistoryPaginationFailure() throws -> Never {
        if let historyPaginationFailureCode {
            throw AgentRuntimeError.requestFailed(
                code: historyPaginationFailureCode,
                message: "simulated unsupported history pagination"
            )
        }
        throw AgentRuntimeError.unsupported("fake paginated history")
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("fake thread creation")
    }

    func startTurn(_: StartTurnRequest) async throws {
        startTurnCallCount += 1
        if let startTurnGate { await startTurnGate.enter() }
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
}

private final class EventAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var accessCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return accessCount
    }

    func recordAccess() {
        lock.lock()
        accessCount += 1
        lock.unlock()
    }
}

private actor InvocationGate {
    private(set) var invocationCount = 0
    private var isOpen: Bool
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(isOpen: Bool) {
        self.isOpen = isOpen
    }

    func enter() async {
        invocationCount += 1
        let ready = countWaiters.filter { invocationCount >= $0.count }
        countWaiters.removeAll { invocationCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }

        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitForInvocationCount(_ count: Int) async {
        guard invocationCount < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func open() {
        isOpen = true
        let waiting = blocked
        blocked.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor CoordinatorEventRecorder {
    enum WaitError: Error {
        case timedOut
    }

    private var events: [AgentRuntimeEvent] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false
    private var task: Task<Void, Never>?

    func start(stream: AsyncStream<AgentRuntimeEvent>) {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await event in stream {
                await self?.record(event)
            }
            await self?.recordFinish()
        }
    }

    deinit {
        task?.cancel()
    }

    func snapshot() -> [AgentRuntimeEvent] { events }

    func waitForCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.suspendUntilCount(count)
            }
            group.addTask {
                try await clock.sleep(for: .seconds(2))
                throw WaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func waitForFinish() async throws {
        let clock = ContinuousClock()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.suspendUntilFinished()
            }
            group.addTask {
                try await clock.sleep(for: .seconds(2))
                throw WaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func record(_ event: AgentRuntimeEvent) {
        events.append(event)
        let ready = waiters.filter { events.count >= $0.count }
        waiters.removeAll { events.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func recordFinish() {
        isFinished = true
        let ready = finishWaiters
        finishWaiters.removeAll()
        for waiter in ready { waiter.resume() }
    }

    private func suspendUntilCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    private func suspendUntilFinished() async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
    }
}
