import Foundation
import XCTest
@testable import Onyx

@MainActor
final class OnyxAppModelAuthBoundaryTests: XCTestCase {
    func testSignOutImmediatelyDisablesSendingAndInteractionResponses() async throws {
        let fixture = makeFixture(logoutBehavior: .suspended)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        await fixture.runtime.emit(.userInteractionRequested(AuthBoundaryFixture.interaction))
        await waitUntil("The interaction did not reach the app model") {
            model.activeUserInteraction == AuthBoundaryFixture.interaction
        }
        model.composerText = "Do not send this after sign out starts"

        model.signOut()

        XCTAssertTrue(model.isSigningOut)
        XCTAssertFalse(model.canRunAgent)
        XCTAssertNil(model.activeUserInteraction)

        model.sendComposer()
        model.respondToApproval(.accept, for: AuthBoundaryFixture.interaction)
        await fixture.runtime.waitForLogoutCall()

        let callsWhileLogoutWasBlocked = await fixture.runtime.recordedPrivilegedCalls()
        XCTAssertTrue(callsWhileLogoutWasBlocked.startTurns.isEmpty)
        XCTAssertTrue(callsWhileLogoutWasBlocked.responses.isEmpty)

        await fixture.runtime.finishLogout()
        await waitUntil("Sign out did not finish") {
            model.authState == .signedOut && !model.isSigningOut
        }
    }

    func testLogoutSuccessRemainsSignedOutWhenAccountRefreshFails() async {
        let fixture = makeFixture(refreshBehavior: .failure)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.signOut()
        await fixture.runtime.waitForRefreshToFinish()

        XCTAssertEqual(model.authState, .signedOut)
        XCTAssertEqual(model.session?.auth, .signedOut)
        XCTAssertNil(model.session?.accountLabel)
        XCTAssertFalse(model.canRunAgent)
        XCTAssertFalse(model.isSigningOut)
    }

    func testLogoutSuccessRejectsStaleSignedInAccountRefresh() async {
        let fixture = makeFixture(refreshBehavior: .staleSignedIn)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.signOut()
        await fixture.runtime.waitForRefreshToFinish()
        await yieldSeveralTimes()

        XCTAssertEqual(model.authState, .signedOut)
        XCTAssertEqual(model.session?.auth, .signedOut)
        XCTAssertFalse(model.canRunAgent)
        assertSignedOutWelcomeState(model)
    }

    func testStaleLoginStartCompletionCannotReopenLoginAfterAccountBoundary() async {
        let fixture = makeFixture(suspendedOperations: [.startLogin])
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.startLogin(AuthBoundaryTestRuntime.loginMethod)
        await fixture.runtime.waitUntilSuspended(.startLogin)

        await fixture.runtime.emit(.accountUpdated(.signedOut))
        await waitUntil("The signed-out boundary did not close the account") {
            model.authState == .signedOut && !model.isAuthenticating
        }
        await fixture.runtime.release(.startLogin)
        await fixture.runtime.waitUntilCompleted(.startLogin)
        await yieldSeveralTimes()

        assertSignedOutWelcomeState(model)
        XCTAssertNil(model.loginAttempt)
        XCTAssertNil(model.authenticationRecovery)
        XCTAssertNil(model.notice)
    }

    func testStaleCancelLoginFailureCannotShowAuthErrorAfterAccountBoundary() async {
        let fixture = makeFixture(
            suspendedOperations: [.cancelLogin],
            failingOperations: [.cancelLogin]
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.startLogin(AuthBoundaryTestRuntime.loginMethod)
        await waitUntil("The login ceremony did not start") {
            model.loginAttempt?.loginID == "recovery-login"
        }
        model.cancelLogin()
        await fixture.runtime.waitUntilSuspended(.cancelLogin)

        await fixture.runtime.emit(.accountUpdated(.signedOut))
        await waitUntil("The signed-out boundary did not close the account") {
            model.authState == .signedOut && !model.isAuthenticating
        }
        await fixture.runtime.release(.cancelLogin)
        await fixture.runtime.waitUntilCompleted(.cancelLogin)
        await yieldSeveralTimes()

        assertSignedOutWelcomeState(model)
        XCTAssertNil(model.loginAttempt)
        XCTAssertNil(model.authenticationRecovery)
        XCTAssertNil(model.notice)
    }

    func testStaleLogoutFailureCannotShowAuthErrorAfterSharedSignedOutEvent() async {
        let fixture = makeFixture(logoutBehavior: .suspendedFailure)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.signOut()
        await fixture.runtime.waitForLogoutCall()

        await fixture.runtime.emit(.accountUpdated(.signedOut))
        await waitUntil("The signed-out event did not close the account") {
            model.authState == .signedOut
        }
        await fixture.runtime.finishLogout()
        await yieldSeveralTimes()

        assertSignedOutWelcomeState(model)
        XCTAssertNil(model.authenticationRecovery)
        XCTAssertNil(model.notice)
    }

    func testSharedLogoutClosesEveryWindowAndRejectsStaleSignedInRefresh() async {
        let suiteName = "OnyxAppModelAuthBoundaryTests.shared.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let runtime = AuthBoundaryTestRuntime(
            logoutBehavior: .immediate,
            refreshBehavior: .staleSignedIn,
            startTurnBehavior: .succeed,
            suspendedOperations: []
        )
        let coordinator = SharedRuntimeCoordinator(runtime: runtime)
        let first = OnyxAppModel(
            runtime: coordinator,
            defaults: defaults,
            preferenceKeyPrefix: "Onyx.window.first"
        )
        let second = OnyxAppModel(
            runtime: coordinator,
            defaults: defaults,
            preferenceKeyPrefix: "Onyx.window.second"
        )

        first.start()
        second.start()
        await waitUntil("Both signed-in windows did not finish loading") {
            first.selectedThreadID == AuthBoundaryFixture.accountThread.id
                && second.selectedThreadID == AuthBoundaryFixture.accountThread.id
                && first.timeline == [AuthBoundaryFixture.sensitiveTranscriptItem]
                && second.timeline == [AuthBoundaryFixture.sensitiveTranscriptItem]
        }

        first.signOut()
        await runtime.waitForRefreshToFinish()
        await waitUntil("The shared logout did not close both account boundaries") {
            first.authState == .signedOut && second.authState == .signedOut
        }
        await yieldSeveralTimes()

        assertSignedOutWelcomeState(first)
        assertSignedOutWelcomeState(second)
    }

    func testSuccessfulSignOutClearsPendingInteractionsAndVisibleAccountHistory() async {
        let fixture = makeFixture(seedSensitivePersistence: true)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        await fixture.runtime.emit(.userInteractionRequested(AuthBoundaryFixture.interaction))
        await waitUntil("The interaction did not reach the app model") {
            model.pendingUserInteractions == [AuthBoundaryFixture.interaction]
        }
        model.selectTaskModel("account-a-private-override")
        XCTAssertEqual(model.selectedTaskModelOverrideID, "account-a-private-override")
        XCTAssertEqual(model.selectedTaskDefaultModelID, "test-model")

        model.signOut()
        await fixture.runtime.waitForRefreshToFinish()

        XCTAssertTrue(model.pendingUserInteractions.isEmpty)
        XCTAssertNil(model.activeUserInteraction)
        XCTAssertFalse(
            model.threads.contains { $0.id == AuthBoundaryFixture.accountThread.id },
            "A signed-out window must not keep the previous account's task visible."
        )
        XCTAssertNotEqual(
            model.selectedThreadID,
            AuthBoundaryFixture.accountThread.id,
            "The previous account's task must no longer be selected after sign out."
        )
        XCTAssertFalse(
            model.timeline.contains { $0.id == AuthBoundaryFixture.sensitiveTranscriptItem.id },
            "A signed-out window must not keep the previous account's transcript visible."
        )
        XCTAssertEqual(model.selectedThreadID, AuthBoundaryFixture.welcomeThreadID)
        XCTAssertEqual(model.threads.map(\.id), [AuthBoundaryFixture.welcomeThreadID])
        XCTAssertEqual(model.timeline.map(\.id), ["onyx-welcome"])
        XCTAssertEqual(model.composerText, "")
        XCTAssertNil(model.draftWorkspacePath)
        XCTAssertTrue(model.taskModelOverrides.isEmpty)
        XCTAssertTrue(model.taskModelDefaults.isEmpty)
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.selectedThreadID"))
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.composerDrafts"))
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.taskModelOverrides"))
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.taskModelDefaults"))
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.lastWorkspacePath"))
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.pinnedThreadIDs"))
    }

    func testStaleListCompletionCannotRestorePreviousAccountAfterLogout() async {
        let fixture = makeFixture(suspendedOperations: [.listThreads])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await fixture.runtime.waitUntilSuspended(.listThreads)
        XCTAssertTrue(model.authState.isSignedIn)

        model.signOut()
        await fixture.runtime.waitForRefreshToFinish()
        await fixture.runtime.release(.listThreads)
        await fixture.runtime.waitUntilCompleted(.listThreads)
        await yieldSeveralTimes()

        assertSignedOutWelcomeState(model)
    }

    func testStaleReadCompletionCannotRestorePreviousTranscriptAfterLogout() async {
        let fixture = makeFixture(suspendedOperations: [.readThread])
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.start()
        await fixture.runtime.waitUntilSuspended(.readThread)
        XCTAssertEqual(model.selectedThreadID, AuthBoundaryFixture.accountThread.id)

        model.signOut()
        await fixture.runtime.waitForRefreshToFinish()
        await fixture.runtime.release(.readThread)
        await fixture.runtime.waitUntilCompleted(.readThread)
        await yieldSeveralTimes()

        assertSignedOutWelcomeState(model)
    }

    func testStaleSendCompletionCannotRestoreTaskOrStartTurnAfterLogout() async {
        let fixture = makeFixture(suspendedOperations: [.resumeThread])
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.composerText = "Previous account send"
        model.sendComposer()
        await fixture.runtime.waitUntilSuspended(.resumeThread)

        model.signOut()
        await fixture.runtime.waitForRefreshToFinish()
        await fixture.runtime.release(.resumeThread)
        await fixture.runtime.waitUntilCompleted(.resumeThread)
        await yieldSeveralTimes()

        assertSignedOutWelcomeState(model)
        let calls = await fixture.runtime.recordedPrivilegedCalls()
        XCTAssertTrue(calls.startTurns.isEmpty)
    }

    func testRecoveryWithSameKnownAccountPreservesTaskTranscriptWorkspaceAndDraft() async throws {
        let fixture = makeFixture(refreshBehavior: .staleSignedIn)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        let originalThreadID = try XCTUnwrap(model.selectedThreadID)
        let originalTranscript = model.timeline
        let originalWorkspace = model.selectedProjectPath
        model.composerText = "Keep this draft while I sign back in"
        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))

        await waitUntil("The sign-in recovery state did not reach the app model") {
            model.authenticationRecovery == .signInExpired
        }

        XCTAssertTrue(model.authState.isSignedIn, "Recovery must not pretend the account was signed out")
        XCTAssertFalse(model.canRunAgent)
        XCTAssertNil(model.notice, "Recovery belongs to the attached account surface, not a duplicate modal")
        XCTAssertEqual(model.selectedThreadID, AuthBoundaryFixture.accountThread.id)
        XCTAssertEqual(model.timeline, [AuthBoundaryFixture.sensitiveTranscriptItem])
        XCTAssertEqual(model.composerText, "Keep this draft while I sign back in")

        model.sendComposer()
        await yieldSeveralTimes()
        let blockedCalls = await fixture.runtime.recordedPrivilegedCalls()
        XCTAssertTrue(blockedCalls.startTurns.isEmpty)
        XCTAssertEqual(model.composerText, "Keep this draft while I sign back in")

        await fixture.runtime.emit(.accountUpdated(AuthBoundaryTestRuntime.signedInAuthForTests))
        await yieldSeveralTimes()
        XCTAssertEqual(
            model.authenticationRecovery,
            .signInExpired,
            "A stale signed-in event must not clear recovery without a new login ceremony"
        )

        model.startLogin(AuthBoundaryTestRuntime.loginMethod)
        await waitUntil("The recovery login did not start") {
            model.loginAttempt?.loginID == "recovery-login"
        }
        await fixture.runtime.emit(.loginCompleted(RuntimeLoginCompletion(
            loginID: "recovery-login",
            success: true,
            error: nil
        )))
        await fixture.runtime.waitForRefreshToFinish()
        await waitUntil("Successful sign-in did not clear account recovery") {
            model.authenticationRecovery == nil && model.canRunAgent
        }
        XCTAssertEqual(model.authState.email, "account-a@example.com")
        XCTAssertEqual(model.selectedThreadID, originalThreadID)
        XCTAssertEqual(model.timeline, originalTranscript)
        XCTAssertEqual(model.selectedProjectPath, originalWorkspace)
        XCTAssertEqual(model.composerText, "Keep this draft while I sign back in")
    }

    func testRecoveryWithDifferentKnownAccountClosesOldAccountBoundary() async throws {
        let fixture = makeFixture(
            refreshBehavior: .replacementSignedIn,
            seedSensitivePersistence: true
        )
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.composerText = "Private draft from account A"
        model.selectTaskModel("account-a-private-override")
        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        await waitUntil("The sign-in recovery state did not reach the app model") {
            model.authenticationRecovery == .signInExpired
        }

        model.startLogin(AuthBoundaryTestRuntime.loginMethod)
        await waitUntil("The replacement-account login did not start") {
            model.loginAttempt?.loginID == "recovery-login"
        }
        await fixture.runtime.emit(.loginCompleted(RuntimeLoginCompletion(
            loginID: "recovery-login",
            success: true,
            error: nil
        )))
        await fixture.runtime.waitForRefreshToFinish()
        await waitUntil("The replacement account did not close the old boundary") {
            model.authenticationRecovery == nil
                && model.authState.email == "account-b@example.com"
                && model.selectedThreadID == AuthBoundaryFixture.welcomeThreadID
        }

        XCTAssertTrue(model.canRunAgent)
        XCTAssertEqual(model.session?.auth.email, "account-b@example.com")
        XCTAssertEqual(model.threads.map(\.id), [AuthBoundaryFixture.welcomeThreadID])
        XCTAssertEqual(model.timeline.map(\.id), ["onyx-welcome"])
        XCTAssertEqual(model.composerText, "")
        XCTAssertNil(model.selectedProjectPath)
        XCTAssertTrue(model.taskModelOverrides.isEmpty)
        XCTAssertTrue(model.taskModelDefaults.isEmpty)
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.selectedThreadID"))
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.composerDrafts"))
        XCTAssertNil(fixture.defaults.object(forKey: "Onyx.lastWorkspacePath"))
    }

    func testRevokedTokenSendFailureUsesOnlyRecoverySurfaceAndPreservesTaskAndDraft() async {
        let fixture = makeFixture(startTurnBehavior: .authenticationRecoveryRequired)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        let taskID = try! XCTUnwrap(model.selectedThreadID)
        let existingTimeline = model.timeline
        let draft = "Keep this exact draft while Codex sign-in is repaired"
        model.composerText = draft

        model.sendComposer()

        await waitUntil("The typed sign-in recovery did not settle the send") {
            model.authenticationRecovery == .signInExpired && !model.isTurnRunning
        }
        XCTAssertEqual(model.selectedThreadID, taskID)
        XCTAssertEqual(model.timeline, existingTimeline)
        XCTAssertEqual(model.composerText, draft)
        XCTAssertNil(model.notice, "The attached recovery surface must be the only auth message")
        XCTAssertFalse(
            model.timeline.contains { item in
                item.title == "Could not send"
                    || item.body.localizedCaseInsensitiveContains("refresh token")
            },
            "A revoked-token request must not race a raw or generic failure row against recovery."
        )
    }

    func testRawRevokedRuntimeNoticeUsesRecoveryWithoutShowingTheRawModal() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        let taskID = try XCTUnwrap(model.selectedThreadID)
        let transcript = model.timeline
        let workspace = model.selectedProjectPath
        model.composerText = "Keep this draft while I sign back in"

        let rawDiagnostic = #"{"timestamp":"2026-08-29T21:23:22.434005Z","level":"WARN","fields":{"message":"events failed with status 401 Unauthorized: {\n  \"error\": { \"message\": \"Your authentication token has been invalidated. Please try signing in again.\", \"type\": \"invalid_request_error\", \"code\": \"token_invalidated\" },\n  \"status\": 401\n}"},"target":"codex_analytics::client"}"#
        await fixture.runtime.emit(.runtimeNotice(title: "Codex runtime", detail: rawDiagnostic))

        await waitUntil("The raw runtime diagnostic did not enter recovery") {
            model.authenticationRecovery == .signInExpired
        }

        XCTAssertNil(model.notice, "Authentication recovery must not open a raw JSON modal")
        XCTAssertEqual(model.selectedThreadID, taskID)
        XCTAssertEqual(model.timeline, transcript)
        XCTAssertEqual(model.selectedProjectPath, workspace)
        XCTAssertEqual(model.composerText, "Keep this draft while I sign back in")
    }

    func testRecoveryRemovesArawAuthenticationModalThatRacedBeforeTheRecoveryEvent() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        let rawDiagnostic = #"{"error":{"message":"Your authentication token has been invalidated. Please try signing in again.","code":"token_invalidated"}}"#
        model.notice = ("Codex runtime", rawDiagnostic)

        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        await waitUntil("The recovery state did not reach the model") {
            model.authenticationRecovery == .signInExpired
        }

        // The recovery card is the sole actionable surface. A raw alert that
        // arrived one event earlier must not remain behind it.
        XCTAssertNil(model.notice)
    }

    func testAuthenticationRecoveryDoesNotClearAnUnrelatedNotice() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.notice = ("Project needs attention", "This notice is unrelated to account access.")
        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))

        await waitUntil("The sign-in recovery state did not reach the app model") {
            model.authenticationRecovery == .signInExpired
        }
        XCTAssertEqual(model.notice?.title, "Project needs attention")
        XCTAssertEqual(model.notice?.detail, "This notice is unrelated to account access.")
    }

    func testTaskListAuthenticationFailureUsesRecoveryWithoutGenericNotice() async {
        let fixture = makeFixture(failingOperations: [.listThreads])
        defer { fixture.cleanUp() }

        fixture.model.start()

        await waitUntil("The task-list failure did not enter sign-in recovery") {
            fixture.model.authenticationRecovery == .signInExpired
                && !fixture.model.isLoadingThreadList
        }
        XCTAssertNil(fixture.model.notice)
        XCTAssertFalse(fixture.model.timeline.contains { $0.kind == .error })
    }

    func testSelectedTaskAuthenticationFailurePreservesTaskDraftAndAvoidsErrorRow() async {
        let fixture = makeFixture(
            failingOperations: [.readThread],
            seedSensitivePersistence: true
        )
        defer { fixture.cleanUp() }

        fixture.model.start()

        await waitUntil("The selected-task read failure did not enter sign-in recovery") {
            fixture.model.authenticationRecovery == .signInExpired
                && !fixture.model.isLoadingThread
        }
        XCTAssertEqual(fixture.model.selectedThreadID, AuthBoundaryFixture.accountThread.id)
        XCTAssertEqual(fixture.model.composerText, "Private draft from account A")
        XCTAssertFalse(fixture.model.timeline.contains { $0.kind == .error })
        XCTAssertNil(fixture.model.notice)
    }

    func testNavigationReadAuthenticationFailureRestoresPreviouslyVisibleTaskContext() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        let originalThreadID = try! XCTUnwrap(model.selectedThreadID)
        let originalTimeline = model.timeline
        let originalTranscriptRevision = model.transcriptSnapshot.revision
        let originalWorkspace = model.selectedProjectPath
        model.composerText = "Keep this draft while opening another task"
        model.threads = [
            AuthBoundaryFixture.accountThread,
            AuthBoundaryFixture.secondAccountThread,
        ]
        await fixture.runtime.fail(.readThread)

        model.selectThread(AuthBoundaryFixture.secondAccountThread.id)

        await waitUntil("The navigation read failure did not enter sign-in recovery") {
            model.authenticationRecovery == .signInExpired
                && !model.isLoadingThread
        }

        XCTAssertEqual(model.selectedThreadID, originalThreadID)
        XCTAssertFalse(
            model.isTurnRunning,
            "A restored task must not keep showing stale work while sign-in recovery owns the workspace."
        )
        XCTAssertEqual(model.timeline, originalTimeline)
        XCTAssertGreaterThan(model.transcriptSnapshot.revision, originalTranscriptRevision)
        XCTAssertEqual(model.selectedProjectPath, originalWorkspace)
        XCTAssertEqual(
            fixture.defaults.string(forKey: "Onyx.lastWorkspacePath"),
            originalWorkspace
        )
        XCTAssertEqual(model.composerText, "Keep this draft while opening another task")
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.timeline.contains { $0.kind == .error })
    }

    func testAuthenticationConnectionFailureKeepsPendingInteractionQuarantined() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        await fixture.runtime.emit(.threadStatusChanged(
            threadID: AuthBoundaryFixture.accountThread.id,
            status: .running
        ))
        await waitUntil("The active turn did not reach the model") {
            model.isTurnRunning
        }
        model.composerText = "Queue this after the current response"
        model.sendComposer()
        await waitUntil("The queued follow-up did not reach the model") {
            model.pendingSteeringMessagesForSelectedThread.count == 1
        }
        await fixture.runtime.emit(.userInteractionRequested(AuthBoundaryFixture.interaction))
        await waitUntil("The approval did not reach the model") {
            model.activeUserInteraction == AuthBoundaryFixture.interaction
        }

        await fixture.runtime.emit(.authenticationRecoveryRequired(.signInExpired))
        await fixture.runtime.emit(.connectionChanged(.failed("Sign in required")))
        await fixture.runtime.emit(.threadStatusChanged(
            threadID: AuthBoundaryFixture.accountThread.id,
            status: .running
        ))
        await yieldSeveralTimes()

        XCTAssertEqual(model.authenticationRecovery, .signInExpired)
        XCTAssertFalse(
            model.isTurnRunning,
            "A late running event must not resurrect working feedback beside sign-in recovery."
        )
        XCTAssertEqual(model.activeUserInteraction, AuthBoundaryFixture.interaction)
        XCTAssertFalse(model.canRespond(to: AuthBoundaryFixture.interaction))
        XCTAssertEqual(
            model.pendingSteeringMessagesForSelectedThread.first?.text,
            "Queue this after the current response"
        )
        XCTAssertNil(model.notice)
    }

    func testRawAuthenticationConnectionFailureIsNormalizedBeforeRecoveryEvent() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        let rawDiagnostic = "401 Unauthorized: token_invalidated; please sign in again"
        await fixture.runtime.emit(.connectionChanged(.failed(rawDiagnostic)))
        await waitUntil("The raw connection diagnostic did not enter recovery") {
            model.authenticationRecovery == .signInExpired
        }

        if case let .failed(detail) = model.connectionState {
            XCTAssertEqual(detail, "Sign in required")
        } else {
            XCTFail("Authentication transport failure should be normalized")
        }
        XCTAssertNil(model.notice)
    }

    func testFailedLoginCompletionDoesNotExposeCredentialDiagnostic() async {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
        model.startLogin(AuthBoundaryTestRuntime.loginMethod)
        await waitUntil("The login ceremony did not start") {
            model.loginAttempt?.loginID == "recovery-login"
        }
        let rawDiagnostic = #"{"error":{"code":"token_invalidated","message":"Your authentication token has been invalidated. Please sign in again."}}"#
        await fixture.runtime.emit(.loginCompleted(RuntimeLoginCompletion(
            loginID: "recovery-login",
            success: false,
            error: rawDiagnostic
        )))
        await waitUntil("The failed login completion did not settle") {
            model.isAuthenticating == false && model.loginAttempt == nil
        }

        XCTAssertEqual(model.authenticationRecovery, .signInExpired)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.timeline.contains { $0.body.contains("token_invalidated") })
    }

    private func makeFixture(
        logoutBehavior: AuthBoundaryTestRuntime.LogoutBehavior = .immediate,
        refreshBehavior: AuthBoundaryTestRuntime.RefreshBehavior = .signedOut,
        startTurnBehavior: AuthBoundaryTestRuntime.StartTurnBehavior = .succeed,
        suspendedOperations: Set<AuthBoundaryTestRuntime.SuspendedOperation> = [],
        failingOperations: Set<AuthBoundaryTestRuntime.SuspendedOperation> = [],
        seedSensitivePersistence: Bool = false
    ) -> AuthBoundaryFixture {
        let suiteName = "OnyxAppModelAuthBoundaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if seedSensitivePersistence {
            defaults.set(AuthBoundaryFixture.accountThread.id, forKey: "Onyx.selectedThreadID")
            defaults.set(
                [
                    AuthBoundaryFixture.accountThread.id: "Private draft from account A",
                    AuthBoundaryFixture.welcomeThreadID: "Private new-task draft from account A",
                ],
                forKey: "Onyx.composerDrafts"
            )
            defaults.set(AuthBoundaryFixture.accountThread.cwd, forKey: "Onyx.lastWorkspacePath")
            defaults.set([AuthBoundaryFixture.accountThread.id], forKey: "Onyx.pinnedThreadIDs")
        }
        let runtime = AuthBoundaryTestRuntime(
            logoutBehavior: logoutBehavior,
            refreshBehavior: refreshBehavior,
            startTurnBehavior: startTurnBehavior,
            suspendedOperations: suspendedOperations,
            failingOperations: failingOperations
        )
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        return AuthBoundaryFixture(
            model: model,
            runtime: runtime,
            defaults: defaults,
            defaultsSuiteName: suiteName
        )
    }

    private func startAndLoad(_ fixture: AuthBoundaryFixture) async {
        fixture.model.start()
        await waitUntil("The signed-in fixture did not finish loading") {
            fixture.model.canRunAgent
                && fixture.model.selectedThreadID == AuthBoundaryFixture.accountThread.id
                && fixture.model.timeline == [AuthBoundaryFixture.sensitiveTranscriptItem]
        }
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

    private func yieldSeveralTimes() async {
        for _ in 0 ..< 10 { await Task.yield() }
    }

    private func assertSignedOutWelcomeState(
        _ model: OnyxAppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(model.authState, .signedOut, file: file, line: line)
        XCTAssertEqual(model.threads.map(\.id), [AuthBoundaryFixture.welcomeThreadID], file: file, line: line)
        XCTAssertEqual(model.selectedThreadID, AuthBoundaryFixture.welcomeThreadID, file: file, line: line)
        XCTAssertEqual(model.timeline.map(\.id), ["onyx-welcome"], file: file, line: line)
        XCTAssertTrue(model.pendingUserInteractions.isEmpty, file: file, line: line)
        XCTAssertFalse(model.isTurnRunning, file: file, line: line)
    }
}

private struct AuthBoundaryFixture {
    static let welcomeThreadID = "onyx:welcome"
    static let accountThread = RuntimeThread(
        id: "account-a-private-task",
        title: "Account A private task",
        preview: "Private work from account A",
        cwd: "/tmp/onyx-auth-boundary-tests",
        updatedAt: Date(timeIntervalSince1970: 2),
        status: .idle,
        isPinned: false,
        runtime: .codex,
        model: "test-model",
        branch: nil
    )

    static let secondAccountThread = RuntimeThread(
        id: "account-a-second-task",
        title: "Account A second task",
        preview: "Another private task from account A",
        cwd: "/tmp/onyx-auth-boundary-tests/second",
        updatedAt: Date(timeIntervalSince1970: 3),
        status: .idle,
        isPinned: false,
        runtime: .codex,
        model: "test-model",
        branch: nil
    )

    static let sensitiveTranscriptItem = TimelineItem(
        id: "account-a-sensitive-transcript",
        kind: .assistantMessage,
        title: nil,
        body: "Sensitive transcript from account A",
        status: .completed,
        timestamp: Date(timeIntervalSince1970: 1),
        detail: nil
    )

    static let interaction = RuntimeUserInteraction(
        id: .string("account-a-approval"),
        threadID: accountThread.id,
        providerMethod: "item/commandExecution/requestApproval",
        title: "Run a command for account A?",
        detail: "This approval belongs to account A.",
        kind: .approval(
            RuntimeApprovalPrompt(
                subject: .command,
                command: "swift test",
                supportsSessionApproval: true
            )
        )
    )

    let model: OnyxAppModel
    let runtime: AuthBoundaryTestRuntime
    let defaults: UserDefaults
    let defaultsSuiteName: String

    @MainActor
    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

private actor AuthBoundaryTestRuntime: AgentRuntime {
    nonisolated static let loginMethod = RuntimeLoginMethod(
        id: "auth-boundary.browser",
        displayName: "Sign In",
        detail: "Sign in securely",
        ceremony: .browser
    )
    enum SuspendedOperation: Hashable, Sendable {
        case startLogin
        case cancelLogin
        case listThreads
        case readThread
        case resumeThread
    }

    enum LogoutBehavior: Sendable {
        case immediate
        case suspended
        case suspendedFailure
    }

    enum RefreshBehavior: Sendable {
        case signedOut
        case failure
        case staleSignedIn
        case replacementSignedIn
    }

    enum StartTurnBehavior: Sendable {
        case succeed
        case authenticationRecoveryRequired
    }

    struct PrivilegedCalls: Sendable {
        let startTurns: [StartTurnRequest]
        let responses: [(RuntimeRequestID, RuntimeUserInteractionResponse)]
    }

    enum TestFailure: Error {
        case accountRefreshFailed
    }

    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private let logoutBehavior: LogoutBehavior
    private let refreshBehavior: RefreshBehavior
    private let startTurnBehavior: StartTurnBehavior
    private let suspendedOperations: Set<SuspendedOperation>
    private var failingOperations: Set<SuspendedOperation>
    private var enteredOperations: Set<SuspendedOperation> = []
    private var releasedOperations: Set<SuspendedOperation> = []
    private var completedOperations: Set<SuspendedOperation> = []
    private var operationContinuations: [SuspendedOperation: CheckedContinuation<Void, Never>] = [:]
    private var entryWaiters: [SuspendedOperation: [CheckedContinuation<Void, Never>]] = [:]
    private var completionWaiters: [SuspendedOperation: [CheckedContinuation<Void, Never>]] = [:]
    private var logoutContinuation: CheckedContinuation<Void, Never>?
    private var logoutWasReleased = false
    private var logoutCallCount = 0
    private var logoutCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshFinishedCount = 0
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var startTurns: [StartTurnRequest] = []
    private var responses: [(RuntimeRequestID, RuntimeUserInteractionResponse)] = []

    init(
        logoutBehavior: LogoutBehavior,
        refreshBehavior: RefreshBehavior,
        startTurnBehavior: StartTurnBehavior = .succeed,
        suspendedOperations: Set<SuspendedOperation>,
        failingOperations: Set<SuspendedOperation> = []
    ) {
        self.logoutBehavior = logoutBehavior
        self.refreshBehavior = refreshBehavior
        self.startTurnBehavior = startTurnBehavior
        self.suspendedOperations = suspendedOperations
        self.failingOperations = failingOperations
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        eventContinuation.yield(.connectionChanged(.connected("Auth boundary runtime")))
        return Self.session(auth: Self.signedInAuth)
    }

    func disconnect() async {}

    func startLogin(methodID: String) async throws -> RuntimeLoginStart {
        guard methodID == Self.loginMethod.id else {
            throw AgentRuntimeError.unsupported("unknown auth-boundary login method")
        }
        await suspendIfRequested(.startLogin)
        if failingOperations.contains(.startLogin) {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
        return RuntimeLoginStart(
            method: Self.loginMethod,
            loginID: "recovery-login",
            authURL: nil,
            verificationURL: nil,
            userCode: nil
        )
    }

    func cancelLogin(id _: String) async throws {
        await suspendIfRequested(.cancelLogin)
        if failingOperations.contains(.cancelLogin) {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
    }

    func logout() async throws {
        logoutCallCount += 1
        let waiters = logoutCallWaiters
        logoutCallWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard logoutBehavior != .immediate else { return }
        await withCheckedContinuation { continuation in
            if logoutWasReleased {
                continuation.resume()
            } else {
                logoutContinuation = continuation
            }
        }
        if logoutBehavior == .suspendedFailure {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
    }

    func refreshAccount() async throws -> RuntimeSession {
        defer {
            refreshFinishedCount += 1
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        switch refreshBehavior {
        case .signedOut:
            return Self.session(auth: .signedOut)
        case .failure:
            throw TestFailure.accountRefreshFailed
        case .staleSignedIn:
            return Self.session(auth: Self.signedInAuth)
        case .replacementSignedIn:
            return Self.session(auth: Self.replacementSignedInAuth)
        }
    }

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        await suspendIfRequested(.listThreads)
        if failingOperations.contains(.listThreads) {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
        return archived ? [] : [AuthBoundaryFixture.accountThread]
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        await suspendIfRequested(.readThread)
        if failingOperations.contains(.readThread) {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
        return try conversation(id: id)
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        await suspendIfRequested(.resumeThread)
        if failingOperations.contains(.resumeThread) {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
        return try conversation(id: id)
    }

    private func conversation(id: String) throws -> RuntimeConversation {
        guard id == AuthBoundaryFixture.accountThread.id else {
            throw AgentRuntimeError.missingField("auth-boundary fixture thread")
        }
        return RuntimeConversation(
            thread: AuthBoundaryFixture.accountThread,
            items: [AuthBoundaryFixture.sensitiveTranscriptItem]
        )
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("starting a thread in auth-boundary tests")
    }

    func startTurn(_ request: StartTurnRequest) async throws {
        startTurns.append(request)
        if startTurnBehavior == .authenticationRecoveryRequired {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
    }

    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}

    func respond(
        to interactionID: RuntimeRequestID,
        with response: RuntimeUserInteractionResponse
    ) async throws {
        responses.append((interactionID, response))
    }

    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    func emit(_ event: AgentRuntimeEvent) {
        eventContinuation.yield(event)
    }

    func fail(_ operation: SuspendedOperation) {
        failingOperations.insert(operation)
    }

    func waitForLogoutCall() async {
        guard logoutCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            logoutCallWaiters.append(continuation)
        }
    }

    func finishLogout() {
        logoutWasReleased = true
        logoutContinuation?.resume()
        logoutContinuation = nil
    }

    func waitForRefreshToFinish() async {
        guard refreshFinishedCount == 0 else { return }
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
        }
    }

    func recordedPrivilegedCalls() -> PrivilegedCalls {
        PrivilegedCalls(startTurns: startTurns, responses: responses)
    }

    func waitUntilSuspended(_ operation: SuspendedOperation) async {
        guard !enteredOperations.contains(operation) else { return }
        await withCheckedContinuation { continuation in
            entryWaiters[operation, default: []].append(continuation)
        }
    }

    func release(_ operation: SuspendedOperation) {
        releasedOperations.insert(operation)
        operationContinuations.removeValue(forKey: operation)?.resume()
    }

    func waitUntilCompleted(_ operation: SuspendedOperation) async {
        guard !completedOperations.contains(operation) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[operation, default: []].append(continuation)
        }
    }

    private func suspendIfRequested(_ operation: SuspendedOperation) async {
        guard suspendedOperations.contains(operation) else { return }
        enteredOperations.insert(operation)
        let waiters = entryWaiters.removeValue(forKey: operation) ?? []
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            if releasedOperations.contains(operation) {
                continuation.resume()
            } else {
                operationContinuations[operation] = continuation
            }
        }

        completedOperations.insert(operation)
        let completedWaiters = completionWaiters.removeValue(forKey: operation) ?? []
        completedWaiters.forEach { $0.resume() }
    }

    private static let signedInAuth = RuntimeAuthState(
        mode: .chatgpt,
        email: "account-a@example.com",
        planLabel: "pro",
        requiresAuthentication: true
    )

    private static let replacementSignedInAuth = RuntimeAuthState(
        mode: .chatgpt,
        email: "account-b@example.com",
        planLabel: "plus",
        requiresAuthentication: true
    )

    static var signedInAuthForTests: RuntimeAuthState { signedInAuth }

    private static func session(auth: RuntimeAuthState) -> RuntimeSession {
        RuntimeSession(
            runtime: .codex,
            displayName: "Auth boundary runtime",
            accountLabel: auth.email,
            planLabel: auth.planLabel,
            auth: auth,
            availableLoginMethods: [loginMethod],
            availableModels: [],
            capabilities: [.streaming, .steering, .approvals]
        )
    }
}
