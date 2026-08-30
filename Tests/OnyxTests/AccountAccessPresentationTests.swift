import Foundation
import XCTest
@testable import Onyx

@MainActor
final class AccountAccessPresentationTests: XCTestCase {
    func testRecoveryCardSuppressesOnlyItsDuplicateTranscriptFailure() {
        let ordinaryFailure = TimelineItem(
            id: "ordinary-failure",
            kind: .error,
            title: "Response failed",
            body: "The provider is temporarily unavailable.",
            status: .failed,
            timestamp: .distantPast,
            detail: nil
        )
        let authenticationFailure = TimelineItem(
            id: "authentication-failure",
            kind: .error,
            title: RuntimeAuthenticationRecovery.signInExpired.title,
            body: RuntimeAuthenticationRecovery.signInExpired.detail,
            status: .failed,
            timestamp: .distantPast,
            detail: nil
        )
        let assistantMessage = TimelineItem(
            id: "assistant-message",
            kind: .assistantMessage,
            title: nil,
            body: "Your access token could not be refreshed. Please log out and sign in again.",
            status: .completed,
            timestamp: .distantPast,
            detail: nil
        )
        let transcript = [assistantMessage, ordinaryFailure, authenticationFailure]

        XCTAssertEqual(
            AccountAccessPresentation.transcriptItems(transcript, recoveryActive: true),
            [assistantMessage, ordinaryFailure]
        )
        XCTAssertEqual(
            AccountAccessPresentation.transcriptItems(transcript, recoveryActive: false),
            transcript
        )
        XCTAssertEqual(transcript.count, 3, "Filtering must not mutate durable transcript data")
    }

    func testCodexRecoveryPresentsSignInAndSettingsTogether() {
        let actions = AccountAccessPresentation.idleActions(
            hasLoginMethod: true,
            hasDeviceCodeMethod: true,
            runtimeName: "Codex"
        )

        XCTAssertEqual(
            actions,
            [
                .openSettings(prominent: false),
                .moreSignInOptions,
                .signIn(runtimeName: "Codex"),
            ]
        )
        XCTAssertEqual(actions.map(\.title), ["Open Settings", "More sign-in options", "Sign In"])
    }

    func testAccountRecoveryActionsHaveSemanticAccessibilityCopyAndGenerousTargets() {
        let actions = AccountAccessPresentation.idleActions(
            hasLoginMethod: true,
            hasDeviceCodeMethod: false,
            runtimeName: "Codex"
        )

        XCTAssertEqual(
            actions,
            [.openSettings(prominent: false), .signIn(runtimeName: "Codex")]
        )
        XCTAssertEqual(Set(actions.map(\.accessibilityLabel)).count, actions.count)
        XCTAssertTrue(actions.allSatisfy { !$0.accessibilityHint.isEmpty })
        XCTAssertTrue(actions.allSatisfy { $0.minimumHeight >= OnyxHitTarget.compact })
        XCTAssertEqual(
            AccountAccessPresentation.idleActions(
                hasLoginMethod: false,
                hasDeviceCodeMethod: false,
                runtimeName: "Codex"
            ),
            [.openSettings(prominent: true)]
        )
    }

    func testRecoveryCardAlsoSuppressesLegacyRawAuthenticationFailure() {
        let rawFailure = TimelineItem(
            id: "legacy-authentication-failure",
            kind: .error,
            title: "Response failed",
            body: "Your access token could not be refreshed. Please log out and sign in again.",
            status: .failed,
            timestamp: .distantPast,
            detail: nil
        )

        XCTAssertTrue(AccountAccessPresentation.isAuthenticationRecoveryItem(rawFailure))
        XCTAssertTrue(
            AccountAccessPresentation.transcriptItems([rawFailure], recoveryActive: true).isEmpty
        )
    }

    func testSessionlessRecoveryMountsWithoutAColdSignedOutFlash() {
        XCTAssertTrue(
            AccountAccessPresentation.shouldShow(
                sessionAvailable: false,
                recoveryActive: true,
                loginAttemptActive: false,
                requiresAuthentication: true,
                signedIn: false
            )
        )
        XCTAssertFalse(
            AccountAccessPresentation.shouldShow(
                sessionAvailable: false,
                recoveryActive: false,
                loginAttemptActive: false,
                requiresAuthentication: true,
                signedIn: false
            )
        )
        XCTAssertTrue(
            AccountAccessPresentation.shouldShow(
                sessionAvailable: true,
                recoveryActive: false,
                loginAttemptActive: false,
                requiresAuthentication: true,
                signedIn: false
            )
        )
    }

    func testRecoveryCardSuppressesAStaleWorkspaceAlertAtPresentationTime() {
        XCTAssertFalse(
            AccountAccessPresentation.shouldShowNotice(
                noticePresent: true,
                recoveryActive: true
            ),
            "A raw runtime alert must never cover the attached Sign In actions"
        )
        XCTAssertTrue(
            AccountAccessPresentation.shouldShowNotice(
                noticePresent: true,
                recoveryActive: false
            )
        )
        XCTAssertFalse(
            AccountAccessPresentation.shouldShowNotice(
                noticePresent: false,
                recoveryActive: false
            )
        )
    }

    func testCodexSessionWithEmptyLoginMethodsStillOffersSignIn() {
        // Some app-server versions return a signed-out session with no
        // availableLoginMethods. The recovery card must remain actionable;
        // an empty catalog is not evidence that Codex has no login ceremony.
        let model = OnyxAppModel(runtime: nil)
        model.session = RuntimeSession(
            runtime: .codex,
            displayName: "Codex",
            accountLabel: nil,
            planLabel: nil,
            auth: .signedOut,
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )
        model.authState = .signedOut

        XCTAssertEqual(model.primaryLoginMethod?.id, "codex.chatgpt.browser")
        XCTAssertEqual(model.deviceCodeLoginMethod?.id, "codex.chatgpt.device-code")

        let actions = AccountAccessPresentation.idleActions(
            hasLoginMethod: model.primaryLoginMethod != nil,
            hasDeviceCodeMethod: model.deviceCodeLoginMethod != nil,
            runtimeName: "Codex"
        )
        XCTAssertEqual(actions.map(\.title), ["Open Settings", "More sign-in options", "Sign In"])
        XCTAssertEqual(actions.last?.title, "Sign In")
    }

    func testEmptyGenericSessionDoesNotInventLoginCeremonies() {
        let model = OnyxAppModel(runtime: nil)
        model.session = RuntimeSession(
            runtime: .openRouter,
            displayName: "OpenAI-compatible",
            accountLabel: nil,
            planLabel: nil,
            auth: .signedOut,
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )

        XCTAssertNil(model.primaryLoginMethod)
        XCTAssertNil(model.deviceCodeLoginMethod)

        // A provider rebind can briefly leave the old Codex runtime kind on a
        // window while the new session is already projected. The session kind
        // must win so that stale Codex state cannot invent an OAuth button for
        // this generic connection.
        let reboundModel = OnyxAppModel(runtime: SessionlessCodexRecoveryRuntime())
        reboundModel.session = model.session
        XCTAssertNil(reboundModel.primaryLoginMethod)
        XCTAssertNil(reboundModel.deviceCodeLoginMethod)

        XCTAssertEqual(
            AccountAccessPresentation.idleActions(
                hasLoginMethod: model.primaryLoginMethod != nil,
                hasDeviceCodeMethod: model.deviceCodeLoginMethod != nil,
                runtimeName: model.runtimeDisplayName
            ),
            [.openSettings(prominent: true)]
        )
    }

    func testSessionlessCodexRecoveryExposesBothLoginCeremonies() async {
        let suite = "AccountAccessPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let runtime = SessionlessCodexRecoveryRuntime()
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        model.start()

        await waitUntil {
            model.authenticationRecovery == .signInExpired
        }

        XCTAssertNil(model.session)
        XCTAssertNil(model.notice)
        if case let .failed(message) = model.connectionState {
            XCTAssertEqual(message, "Sign in required")
            XCTAssertFalse(message.localizedCaseInsensitiveContains("token"))
        } else {
            XCTFail("Sessionless recovery should settle as an attached connection failure")
        }
        XCTAssertEqual(model.primaryLoginMethod?.id, "codex.chatgpt.browser")
        XCTAssertEqual(model.deviceCodeLoginMethod?.id, "codex.chatgpt.device-code")
        XCTAssertEqual(model.primaryLoginMethod?.ceremony, .browser)
        XCTAssertEqual(model.deviceCodeLoginMethod?.ceremony, .deviceCode)

        if let method = model.primaryLoginMethod {
            model.startLogin(method)
        } else {
            XCTFail("Sessionless recovery should provide a browser login method")
        }
        let loginMethodID = await runtime.waitForLoginMethodID()
        XCTAssertEqual(loginMethodID, "codex.chatgpt.browser")
        await waitUntil {
            model.loginAttempt?.loginID == "sessionless-login"
        }
    }

    func testSessionlessCodexRecoveryCompletesConnectionAndLoadsTaskCatalog() async throws {
        let suite = "AccountAccessPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let runtime = SessionlessCodexRecoveryRuntime()
        let model = OnyxAppModel(runtime: runtime, defaults: defaults)
        model.start()

        await waitUntil {
            model.authenticationRecovery == .signInExpired
        }
        let method = try XCTUnwrap(model.primaryLoginMethod)
        model.startLogin(method)
        await waitUntil {
            model.loginAttempt?.loginID == "sessionless-login"
        }

        await runtime.completeLogin()

        await waitUntil(timeout: .seconds(2)) {
            model.authenticationRecovery == nil
                && model.connectionState == .connected("person@example.com")
                && model.canRunAgent
                && model.threads.contains { $0.id == SessionlessCodexRecoveryRuntime.recoveredThread.id }
        }
        XCTAssertEqual(model.authState.email, "person@example.com")
        XCTAssertNil(model.notice)
    }

    func testCodexSignedOutRecoveryKeepsTheDraftPromiseAndClearAction() {
        XCTAssertEqual(
            AccountAccessPresentation.signedOutTitle(isCodex: true, runtimeName: "Codex app-server"),
            "Codex is signed out"
        )
        XCTAssertEqual(
            AccountAccessPresentation.signedOutDetail(isCodex: true, runtimeName: "Codex app-server"),
            "Your draft is safe here. Sign in again to send it or continue this task."
        )
        XCTAssertEqual(AccountAccessPresentation.primaryActionTitle(hasLoginMethod: true), "Sign In")
        XCTAssertEqual(AccountAccessPresentation.resumeActionTitle(hasDeviceCode: false), "Open Sign In Again")
        XCTAssertEqual(AccountAccessPresentation.settingsActionTitle, "Open Settings")
    }

    func testCredentialRecoveryNamesTheAffectedConnectionWithoutPretendingItIsCodex() {
        XCTAssertEqual(
            AccountAccessPresentation.signedOutTitle(isCodex: false, runtimeName: "Studio gateway"),
            "Studio gateway needs credentials"
        )
        XCTAssertEqual(
            AccountAccessPresentation.signedOutDetail(isCodex: false, runtimeName: "Studio gateway"),
            "Your draft is safe here. Add or replace credentials for Studio gateway to continue."
        )
        XCTAssertEqual(AccountAccessPresentation.primaryActionTitle(hasLoginMethod: false), "Open Settings")
        XCTAssertEqual(AccountAccessPresentation.resumeActionTitle(hasDeviceCode: true), "Open Sign In")
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }
}

/// Minimal runtime used to prove the account-recovery projection does not
/// depend on a successful session snapshot. The real Codex runtime supplies
/// the same method IDs after its app-server has initialized.
private actor SessionlessCodexRecoveryRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.codex
    nonisolated let events: AsyncStream<AgentRuntimeEvent>
    nonisolated static let recoveredThread = RuntimeThread(
        id: "recovered-task",
        title: "Recovered task",
        preview: "Available after signing in",
        cwd: "/tmp/onyx-sessionless-recovery",
        updatedAt: Date(timeIntervalSince1970: 1),
        status: .idle,
        isPinned: false,
        runtime: .codex,
        model: "test-model",
        branch: nil
    )

    private let eventContinuation: AsyncStream<AgentRuntimeEvent>.Continuation
    private var loginMethodID: String?
    private var loginMethodContinuation: CheckedContinuation<Void, Never>?
    private var didCompleteLogin = false

    init() {
        let stream = AsyncStream.makeStream(of: AgentRuntimeEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func connect() async throws -> RuntimeSession {
        guard didCompleteLogin else {
            throw AgentRuntimeError.authenticationRecoveryRequired(.signInExpired)
        }
        return Self.recoveredSession
    }

    func disconnect() async {}

    func startLogin(methodID: String) async throws -> RuntimeLoginStart {
        loginMethodID = methodID
        loginMethodContinuation?.resume()
        loginMethodContinuation = nil
        let method = RuntimeLoginMethod(
            id: methodID,
            displayName: methodID == "codex.chatgpt.device-code" ? "Use a device code" : "Continue with ChatGPT",
            detail: methodID == "codex.chatgpt.device-code"
                ? "Enter a one-time code at OpenAI"
                : "Sign in securely in your browser",
            ceremony: methodID == "codex.chatgpt.device-code" ? .deviceCode : .browser
        )
        return RuntimeLoginStart(
            method: method,
            loginID: "sessionless-login",
            authURL: nil,
            verificationURL: nil,
            userCode: nil
        )
    }

    func listThreads(limit _: Int, archived: Bool) async throws -> [RuntimeThread] {
        archived ? [] : [Self.recoveredThread]
    }

    func readThread(id _: String) async throws -> RuntimeConversation {
        throw AgentRuntimeError.unsupported("reading a sessionless recovery task")
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("starting a sessionless recovery task")
    }

    func startTurn(_: StartTurnRequest) async throws {
        throw AgentRuntimeError.unsupported("starting a sessionless recovery task")
    }

    func steer(threadID _: String, text _: String) async throws {}
    func interrupt(threadID _: String) async throws {}
    func respond(to _: RuntimeRequestID, with _: RuntimeUserInteractionResponse) async throws {}
    func renameThread(id _: String, name _: String) async throws {}
    func archiveThread(id _: String) async throws {}
    func unarchiveThread(id _: String) async throws {}

    func waitForLoginMethodID() async -> String? {
        if let loginMethodID { return loginMethodID }
        await withCheckedContinuation { continuation in
            loginMethodContinuation = continuation
        }
        return loginMethodID
    }

    func completeLogin() {
        didCompleteLogin = true
        eventContinuation.yield(.loginCompleted(RuntimeLoginCompletion(
            loginID: "sessionless-login",
            success: true,
            error: nil
        )))
    }

    private nonisolated static let recoveredSession = RuntimeSession(
        runtime: .codex,
        displayName: "Codex",
        accountLabel: "person@example.com",
        planLabel: "pro",
        auth: RuntimeAuthState(
            mode: .chatgpt,
            email: "person@example.com",
            planLabel: "pro",
            requiresAuthentication: true
        ),
        availableLoginMethods: [],
        availableModels: [],
        capabilities: []
    )
}
