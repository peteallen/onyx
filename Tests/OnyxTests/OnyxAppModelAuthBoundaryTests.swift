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

    func testSharedLogoutClosesEveryWindowAndRejectsStaleSignedInRefresh() async {
        let suiteName = "OnyxAppModelAuthBoundaryTests.shared.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let runtime = AuthBoundaryTestRuntime(
            logoutBehavior: .immediate,
            refreshBehavior: .staleSignedIn,
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

    func testRevokedRefreshTokenPreservesTaskAndDraftButGatesWritesUntilSignIn() async throws {
        let fixture = makeFixture(refreshBehavior: .staleSignedIn)
        defer { fixture.cleanUp() }
        let model = fixture.model

        await startAndLoad(fixture)
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
        XCTAssertEqual(model.composerText, "Keep this draft while I sign back in")
    }

    private func makeFixture(
        logoutBehavior: AuthBoundaryTestRuntime.LogoutBehavior = .immediate,
        refreshBehavior: AuthBoundaryTestRuntime.RefreshBehavior = .signedOut,
        suspendedOperations: Set<AuthBoundaryTestRuntime.SuspendedOperation> = [],
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
            suspendedOperations: suspendedOperations
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
        case listThreads
        case readThread
        case resumeThread
    }

    enum LogoutBehavior: Sendable {
        case immediate
        case suspended
    }

    enum RefreshBehavior: Sendable {
        case signedOut
        case failure
        case staleSignedIn
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
    private let suspendedOperations: Set<SuspendedOperation>
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
        suspendedOperations: Set<SuspendedOperation>
    ) {
        self.logoutBehavior = logoutBehavior
        self.refreshBehavior = refreshBehavior
        self.suspendedOperations = suspendedOperations
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
        return RuntimeLoginStart(
            method: Self.loginMethod,
            loginID: "recovery-login",
            authURL: nil,
            verificationURL: nil,
            userCode: nil
        )
    }

    func logout() async throws {
        logoutCallCount += 1
        let waiters = logoutCallWaiters
        logoutCallWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard logoutBehavior == .suspended else { return }
        await withCheckedContinuation { continuation in
            if logoutWasReleased {
                continuation.resume()
            } else {
                logoutContinuation = continuation
            }
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
        }
    }

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        await suspendIfRequested(.listThreads)
        return archived ? [] : [AuthBoundaryFixture.accountThread]
    }

    func readThread(id: String) async throws -> RuntimeConversation {
        await suspendIfRequested(.readThread)
        return try conversation(id: id)
    }

    func resumeThread(id: String) async throws -> RuntimeConversation {
        await suspendIfRequested(.resumeThread)
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
            capabilities: [.streaming, .approvals]
        )
    }
}
