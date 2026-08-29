import Foundation
import XCTest
@testable import Onyx

final class CodexAuthRuntimeTests: XCTestCase {
    private static let revokedRefreshTokenDiagnostic =
        "Your access token could not be refreshed because your refresh token was revoked. Please log out and sign in again."

    func testBrowserLoginStartMapsExactRequestAndResult() async throws {
        let authURL = try XCTUnwrap(URL(string: "https://auth.openai.test/authorize?state=browser-state"))
        let transport = AuthCodexTransport(
            loginStartResponses: [
                .object([
                    "loginId": .string("browser-login"),
                    "authUrl": .string(authURL.absoluteString),
                ]),
            ]
        )
        let runtime = CodexRuntime(client: transport)

        let result = try await runtime.startLogin(methodID: "codex.chatgpt.browser")

        XCTAssertEqual(
            result,
            RuntimeLoginStart(
                method: RuntimeLoginMethod(
                    id: "codex.chatgpt.browser",
                    displayName: "Continue with ChatGPT",
                    detail: "Sign in securely in your browser",
                    ceremony: .browser
                ),
                loginID: "browser-login",
                authURL: authURL,
                verificationURL: nil,
                userCode: nil
            )
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests,
            [
                AuthCodexTransport.Request(
                    method: "account/login/start",
                    params: .object([
                        "type": .string("chatgpt"),
                        "useHostedLoginSuccessPage": .bool(true),
                        "appBrand": .string("codex"),
                    ])
                ),
            ]
        )
    }

    func testDeviceCodeLoginStartMapsExactRequestAndResult() async throws {
        let verificationURL = try XCTUnwrap(URL(string: "https://auth.openai.test/device"))
        let transport = AuthCodexTransport(
            loginStartResponses: [
                .object([
                    "loginId": .string("device-login"),
                    "verificationUrl": .string(verificationURL.absoluteString),
                    "userCode": .string("ONYX-CODE"),
                ]),
            ]
        )
        let runtime = CodexRuntime(client: transport)

        let result = try await runtime.startLogin(methodID: "codex.chatgpt.device-code")

        XCTAssertEqual(
            result,
            RuntimeLoginStart(
                method: RuntimeLoginMethod(
                    id: "codex.chatgpt.device-code",
                    displayName: "Use a device code",
                    detail: "Enter a one-time code at OpenAI",
                    ceremony: .deviceCode
                ),
                loginID: "device-login",
                authURL: nil,
                verificationURL: verificationURL,
                userCode: "ONYX-CODE"
            )
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests,
            [
                AuthCodexTransport.Request(
                    method: "account/login/start",
                    params: .object(["type": .string("chatgptDeviceCode")])
                ),
            ]
        )
    }

    func testCancelAndLogoutMapExactRequests() async throws {
        let transport = AuthCodexTransport()
        let runtime = CodexRuntime(client: transport)

        try await runtime.cancelLogin(id: "pending-login")
        try await runtime.logout()

        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests,
            [
                AuthCodexTransport.Request(
                    method: "account/login/cancel",
                    params: .object(["loginId": .string("pending-login")])
                ),
                AuthCodexTransport.Request(
                    method: "account/logout",
                    params: .null
                ),
            ]
        )
    }

    func testSignedOutAccountReadProjectsProviderNeutralSession() async throws {
        let transport = AuthCodexTransport(
            accountResponse: .object([
                "account": .null,
                "requiresOpenaiAuth": .bool(true),
            ])
        )
        let runtime = CodexRuntime(client: transport)

        let session = try await runtime.refreshAccount()

        XCTAssertEqual(session.auth, .signedOut)
        XCTAssertFalse(session.auth.isSignedIn)
        XCTAssertEqual(session.auth.displayLabel, "Not signed in")
        XCTAssertNil(session.accountLabel)
        XCTAssertNil(session.planLabel)
        XCTAssertEqual(
            session.availableLoginMethods,
            [
                RuntimeLoginMethod(
                    id: "codex.chatgpt.browser",
                    displayName: "Continue with ChatGPT",
                    detail: "Sign in securely in your browser",
                    ceremony: .browser
                ),
                RuntimeLoginMethod(
                    id: "codex.chatgpt.device-code",
                    displayName: "Use a device code",
                    detail: "Enter a one-time code at OpenAI",
                    ceremony: .deviceCode
                ),
            ]
        )
        let requests = await transport.recordedRequests()
        let accountRequest = try XCTUnwrap(requests.first(where: { $0.method == "account/read" }))
        XCTAssertEqual(accountRequest.params, .object(["refreshToken": .bool(false)]))
    }

    func testSignedInAccountReadProjectsIdentityAndPlan() async throws {
        let transport = AuthCodexTransport(
            accountResponse: .object([
                "account": .object([
                    "type": .string("chatgpt"),
                    "email": .string("person@example.com"),
                    "planType": .string("pro"),
                ]),
                "requiresOpenaiAuth": .bool(true),
            ])
        )
        let runtime = CodexRuntime(client: transport)

        let session = try await runtime.refreshAccount()

        XCTAssertEqual(
            session.auth,
            RuntimeAuthState(
                mode: .chatgpt,
                email: "person@example.com",
                planLabel: "pro",
                requiresAuthentication: true
            )
        )
        XCTAssertTrue(session.auth.isSignedIn)
        XCTAssertEqual(session.auth.displayLabel, "person@example.com")
        XCTAssertEqual(session.accountLabel, "person@example.com")
        XCTAssertEqual(session.planLabel, "pro")
    }

    func testModelCatalogFailureDoesNotBlockSignedOutRecovery() async throws {
        let transport = AuthCodexTransport(
            accountResponse: .object([
                "account": .null,
                "requiresOpenaiAuth": .bool(true),
            ]),
            failModelList: true
        )
        let runtime = CodexRuntime(client: transport)

        let session = try await runtime.connect()
        await runtime.disconnect()

        XCTAssertEqual(session.auth, .signedOut)
        XCTAssertFalse(session.availableLoginMethods.isEmpty)
        XCTAssertTrue(session.availableModels.isEmpty)
    }

    func testModelCatalogAuthenticationFailurePublishesRecoveryInsteadOfHealthySession() async throws {
        let transport = AuthCodexTransport(
            accountResponse: Self.signedInAccountResponse
        )
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        let recoveryEvent = Task { () -> AgentRuntimeEvent? in
            for await event in runtime.events {
                if case .authenticationRecoveryRequired = event { return event }
            }
            return nil
        }
        await transport.setRequestFailure(
            Self.revokedRefreshTokenDiagnostic,
            for: "model/list"
        )

        do {
            _ = try await runtime.refreshAccount()
            XCTFail("An authentication failure while refreshing models must not return a healthy session")
        } catch let error as AgentRuntimeError {
            guard case .authenticationRecoveryRequired(.signInExpired) = error else {
                XCTFail("Expected structured authentication recovery, got (error)")
                return
            }
        }

        let observedRecoveryEvent = await recoveryEvent.value
        XCTAssertEqual(
            observedRecoveryEvent,
            .authenticationRecoveryRequired(.signInExpired)
        )
        await runtime.disconnect()
    }

    func testUnauthenticatedProviderCanRunWithoutLookingSignedIn() {
        let state = RuntimeAuthState(
            mode: nil,
            email: nil,
            planLabel: nil,
            requiresAuthentication: false
        )

        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.canRun)
        XCTAssertEqual(state.displayLabel, "Authentication not required")
    }

    func testAccountNotificationsMapToProviderNeutralEvents() async throws {
        let transport = AuthCodexTransport(
            accountResponse: .object([
                "account": .null,
                "requiresOpenaiAuth": .bool(true),
            ])
        )
        let runtime = CodexRuntime(client: transport)

        let observedEvents = try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
            group.addTask {
                var events: [AgentRuntimeEvent] = []
                for await event in runtime.events {
                    events.append(event)
                    if events.count == 4 { return events }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AuthCodexTransport.TestFailure.timedOutWaitingForEvents
            }

            _ = try await runtime.connect()
            await transport.emitNotification(
                method: "account/updated",
                params: .object([
                    "authMode": .string("chatgpt"),
                    "planType": .string("team"),
                ])
            )
            await transport.emitNotification(
                method: "account/login/completed",
                params: .object([
                    "loginId": .string("browser-login"),
                    "success": .bool(false),
                    "error": .string("The browser flow was canceled"),
                ])
            )

            guard let firstResult = try await group.next() else {
                throw AuthCodexTransport.TestFailure.eventStreamEnded
            }
            group.cancelAll()
            return firstResult
        }
        await runtime.disconnect()

        XCTAssertEqual(
            observedEvents,
            [
                .connectionChanged(.connecting),
                .connectionChanged(.connected("Codex")),
                .accountUpdated(
                    RuntimeAuthState(
                        mode: .chatgpt,
                        email: nil,
                        planLabel: "team",
                        requiresAuthentication: true
                    )
                ),
                .loginCompleted(
                    RuntimeLoginCompletion(
                        loginID: "browser-login",
                        success: false,
                        error: "The browser flow was canceled"
                    )
                ),
            ]
        )
    }

    func testAccountNotificationsPreserveNoAuthProviderContractFromAccountRead() async throws {
        let transport = AuthCodexTransport(
            accountResponse: .object([
                "account": .null,
                "requiresOpenaiAuth": .bool(false),
            ])
        )
        let runtime = CodexRuntime(client: transport)

        let observedEvents = try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
            group.addTask {
                var events: [AgentRuntimeEvent] = []
                for await event in runtime.events {
                    events.append(event)
                    if events.count == 3 { return events }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AuthCodexTransport.TestFailure.timedOutWaitingForEvents
            }

            _ = try await runtime.connect()
            await transport.emitNotification(
                method: "account/updated",
                params: .object([
                    "authMode": .null,
                    "planType": .null,
                ])
            )

            guard let firstResult = try await group.next() else {
                throw AuthCodexTransport.TestFailure.eventStreamEnded
            }
            group.cancelAll()
            return firstResult
        }
        await runtime.disconnect()

        XCTAssertEqual(
            observedEvents,
            [
                .connectionChanged(.connecting),
                .connectionChanged(.connected("Codex")),
                .accountUpdated(
                    RuntimeAuthState(
                        mode: nil,
                        email: nil,
                        planLabel: nil,
                        requiresAuthentication: false
                    )
                ),
            ]
        )
    }

    func testRevokedRefreshTokenErrorPublishesStructuredAuthenticationRecovery() async throws {
        let transport = AuthCodexTransport(
            accountResponse: .object([
                "account": .object([
                    "type": .string("chatgpt"),
                    "email": .string("person@example.com"),
                ]),
                "requiresOpenaiAuth": .bool(true),
            ])
        )
        let runtime = CodexRuntime(client: transport)
        let diagnostic =
            "Your access token could not be refreshed because your refresh token was revoked. Please log out and sign in again."

        let observedEvents = try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
            group.addTask {
                var events: [AgentRuntimeEvent] = []
                for await event in runtime.events {
                    events.append(event)
                    if events.contains(.authenticationRecoveryRequired(.signInExpired)) {
                        return events
                    }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AuthCodexTransport.TestFailure.timedOutWaitingForEvents
            }

            _ = try await runtime.connect()
            await transport.emitNotification(
                method: "error",
                params: .object(["message": .string(diagnostic)])
            )
            guard let firstResult = try await group.next() else {
                throw AuthCodexTransport.TestFailure.eventStreamEnded
            }
            group.cancelAll()
            return firstResult
        }
        await runtime.disconnect()

        XCTAssertTrue(observedEvents.contains(.authenticationRecoveryRequired(.signInExpired)))
    }

    func testRevokedRefreshTokenRequestFailurePublishesStructuredAuthenticationRecovery() async throws {
        let diagnostic = Self.revokedRefreshTokenDiagnostic
        let transport = AuthCodexTransport(requestFailures: ["turn/start": diagnostic])
        let runtime = CodexRuntime(client: transport)
        _ = try await runtime.connect()

        let eventTask = Task { () -> AgentRuntimeEvent? in
            for await event in runtime.events {
                if case .authenticationRecoveryRequired = event { return event }
            }
            return nil
        }
        do {
            try await runtime.startTurn(StartTurnRequest(
                threadID: "task-1",
                inputs: [.text("Continue")],
                model: nil,
                cwd: nil,
                reasoningEffort: nil,
                sandboxMode: .workspaceWrite,
                approvalPolicy: .onRequest
            ))
            XCTFail("turn/start should fail with the revoked refresh token")
        } catch {
            guard case .authenticationRecoveryRequired? = error as? AgentRuntimeError else {
                XCTFail("Expected structured authentication recovery, got \(error)")
                return
            }
        }
        let event = await eventTask.value
        XCTAssertEqual(event, .authenticationRecoveryRequired(.signInExpired))
        await runtime.disconnect()
    }

    func testRevokedAccountReadDuringConnectPublishesOneStructuredRecoveryWithoutRawNotice() async throws {
        let transport = AuthCodexTransport(
            requestFailures: ["account/read": Self.revokedRefreshTokenDiagnostic]
        )
        let runtime = CodexRuntime(client: transport)
        let recordedEvents = Task {
            try await collectAuthEventsThroughConnectionFailure(from: runtime.events)
        }

        await assertAuthenticationRecoveryError {
            _ = try await runtime.connect()
        }

        let events = try await recordedEvents.value
        assertSingleStructuredRecoveryWithoutRuntimeNotice(events)
        let failedDetail = events.compactMap { event -> String? in
            guard case let .connectionChanged(.failed(detail)) = event else { return nil }
            return detail
        }.last
        XCTAssertEqual(failedDetail, "Sign in required")
        await runtime.disconnect()
    }

    func testInitialAuthenticationFailureKeepsTransportForLoginCeremony() async throws {
        let authURL = try XCTUnwrap(URL(string: "https://auth.openai.test/recover"))
        let transport = AuthCodexTransport(
            loginStartResponses: [
                .object([
                    "loginId": .string("recovery-login"),
                    "authUrl": .string(authURL.absoluteString),
                ]),
            ],
            requestFailures: ["account/read": Self.revokedRefreshTokenDiagnostic]
        )
        let runtime = CodexRuntime(client: transport)

        await assertAuthenticationRecoveryError("initial account/read") {
            _ = try await runtime.connect()
        }

        // The account snapshot failed, but the initialized app-server must
        // remain available for the recovery card's login/start request.
        let login = try await runtime.startLogin(methodID: "codex.chatgpt.browser")
        XCTAssertEqual(login.loginID, "recovery-login")
        XCTAssertEqual(login.authURL, authURL)
        let stopCountBeforeDisconnect = await transport.stopCount()
        XCTAssertEqual(stopCountBeforeDisconnect, 0)

        await transport.setRequestFailure(nil, for: "account/read")
        _ = try await runtime.refreshAccount()
        _ = try await runtime.connect()
        let startCountAfterRecovery = await transport.startCount()
        XCTAssertEqual(startCountAfterRecovery, 1)

        await runtime.disconnect()
        let stopCountAfterDisconnect = await transport.stopCount()
        XCTAssertEqual(stopCountAfterDisconnect, 1)
    }

    func testRevokedAccountReadDuringRefreshPublishesOneStructuredRecoveryWithoutRawNotice() async throws {
        let transport = AuthCodexTransport(accountResponse: Self.signedInAccountResponse)
        let runtime = CodexRuntime(client: transport)
        let marker = "refresh-failure-marker"
        let recordedEvents = Task {
            try await collectAuthEventsThroughAccountMarker(from: runtime.events, marker: marker)
        }

        _ = try await runtime.connect()
        await transport.setRequestFailure(Self.revokedRefreshTokenDiagnostic, for: "account/read")
        await assertAuthenticationRecoveryError {
            _ = try await runtime.refreshAccount()
        }
        await transport.emitNotification(
            method: "error",
            params: .object(["message": .string(Self.revokedRefreshTokenDiagnostic)])
        )
        await transport.emitAccountMarker(marker)

        let events = try await recordedEvents.value
        assertSingleStructuredRecoveryWithoutRuntimeNotice(events)
        await runtime.disconnect()
    }

    func testInvalidatedTokenOnStderrPublishesRecoveryWithoutRawRuntimeNotice() async throws {
        let transport = AuthCodexTransport(accountResponse: Self.signedInAccountResponse)
        let runtime = CodexRuntime(client: transport)
        let marker = "stderr-auth-marker"
        let recordedEvents = Task {
            try await collectAuthEventsThroughAccountMarker(from: runtime.events, marker: marker)
        }

        _ = try await runtime.connect()
        await transport.emitStderr(#"{"timestamp":"2026-08-29T21:23:22Z","level":"WARN","fields":{"message":"events failed with status 401 Unauthorized: {\n  \"error\": {\n    \"message\": \"Your authentication token has been invalidated. Please try signing in again.\",\n    \"type\": \"invalid_request_error\",\n    \"code\": \"token_invalidated\",\n    \"param\": null\n  },\n  \"status\": 401\n}"},"target":"codex_analytics::client"}"#)
        await transport.emitNotification(
            method: "account/updated",
            params: .object([
                "authMode": .string("chatgpt"),
                "planType": .string(marker),
            ])
        )

        let events = try await recordedEvents.value
        assertSingleStructuredRecoveryWithoutRuntimeNotice(events, "stderr token invalidation")
        await runtime.disconnect()
    }

    func testInvalidatedTokenFromModelRefreshStderrPublishesRecoveryWithoutRawRuntimeNotice() async throws {
        let transport = AuthCodexTransport(accountResponse: Self.signedInAccountResponse)
        let runtime = CodexRuntime(client: transport)
        let marker = "model-refresh-stderr-auth-marker"
        let recordedEvents = Task {
            try await collectAuthEventsThroughAccountMarker(from: runtime.events, marker: marker)
        }

        _ = try await runtime.connect()
        // This is the alternate app-server diagnostic observed in the running
        // preview. It has no nested error object, so keep the complete shape as
        // a regression instead of relying only on the analytics-client form.
        await transport.emitStderr(#"{"timestamp":"2026-08-29T21:26:00.048491Z","level":"ERROR","fields":{"message":"failed to refresh available models: unexpected status 401 Unauthorized: Your authentication token has been invalidated. Please try signing in again., url: https://chatgpt.com/backend-api/codex/models?client_version=0.149.0, cf-ray: a32ea1a90e29f4b9-DEN, auth error: 401, auth error code: token_invalidated"},"target":"codex_models_manager::manager"}"#)
        await transport.emitNotification(
            method: "account/updated",
            params: .object([
                "authMode": .string("chatgpt"),
                "planType": .string(marker),
            ])
        )

        let events = try await recordedEvents.value
        assertSingleStructuredRecoveryWithoutRuntimeNotice(events, "model refresh token invalidation")
        await runtime.disconnect()
    }

    func testRemoteControlAuthenticationWaitIsIgnoredWithoutRecoveryOrNoticeFlood() async throws {
        let transport = AuthCodexTransport(accountResponse: Self.signedInAccountResponse)
        let runtime = CodexRuntime(client: transport)
        let marker = "remote-control-auth-wait-marker"
        let recordedEvents = Task {
            try await collectAuthEventsThroughAccountMarker(from: runtime.events, marker: marker)
        }

        _ = try await runtime.connect()
        let repeatedDiagnostic =
            "waiting to resolve remote control preference until authentication is available error=remote control requires ChatGPT authentication"
        await transport.emitStderr(repeatedDiagnostic)
        await transport.emitStderr(repeatedDiagnostic)
        await transport.emitAccountMarker(marker)

        let events = try await recordedEvents.value
        XCTAssertFalse(events.contains(.authenticationRecoveryRequired(.signInExpired)))
        XCTAssertFalse(events.contains(where: \.isRuntimeNotice))
        await runtime.disconnect()
    }

    func testConversationAndTurnRequestAuthenticationFailuresShareOneStructuredBoundary() async throws {
        for operation in AuthenticationFailingOperation.allCases {
            let transport = AuthCodexTransport(accountResponse: Self.signedInAccountResponse)
            let runtime = CodexRuntime(client: transport)
            let marker = "request-failure-\(operation.rawValue)"
            let recordedEvents = Task {
                try await collectAuthEventsThroughAccountMarker(from: runtime.events, marker: marker)
            }

            _ = try await runtime.connect()
            await transport.setRequestFailure(
                Self.revokedRefreshTokenDiagnostic,
                for: operation.requestMethod
            )
            await assertAuthenticationRecoveryError(operation.rawValue) {
                try await operation.run(on: runtime)
            }
            // App-server can report the same provider failure both as the
            // thrown JSON-RPC response and as a notification. It is still one
            // recovery state, not two user-visible errors.
            await transport.emitNotification(
                method: "error",
                params: .object(["message": .string(Self.revokedRefreshTokenDiagnostic)])
            )
            await transport.emitAccountMarker(marker)

            let events = try await recordedEvents.value
            assertSingleStructuredRecoveryWithoutRuntimeNotice(events, operation.rawValue)
            await runtime.disconnect()
        }
    }

    func testAuthenticationNotificationCarriesFriendlyFailureIntoErrorlessTurnCompletion() async throws {
        let transport = AuthCodexTransport(accountResponse: Self.signedInAccountResponse)
        let runtime = CodexRuntime(client: transport)
        let threadID = "expired-session-thread"
        let turnID = "expired-session-turn"
        let recordedEvents = Task {
            try await collectAuthEventsThroughTurnCompletion(
                from: runtime.events,
                threadID: threadID
            )
        }

        _ = try await runtime.connect()
        await transport.emitNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object(["id": .string(turnID)]),
            ])
        )
        await transport.emitNotification(
            method: "error",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "willRetry": .bool(false),
                "error": .object([
                    "message": .string(Self.revokedRefreshTokenDiagnostic),
                ]),
            ])
        )
        await transport.emitNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string(turnID),
                    "status": .string("failed"),
                ]),
            ])
        )

        let events = try await recordedEvents.value
        assertSingleStructuredRecoveryWithoutRuntimeNotice(events)
        let failures = events.compactMap { event -> TimelineItem? in
            guard case let .itemCompleted(completedThreadID, item) = event,
                  completedThreadID == threadID,
                  item.kind == .error else { return nil }
            return item
        }
        let failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failure.id, "codex-turn-error:\(turnID)")
        XCTAssertEqual(failure.title, "Sign in required")
        XCTAssertEqual(failure.body, RuntimeAuthenticationRecovery.signInExpired.detail)
        XCTAssertFalse(failure.body.localizedCaseInsensitiveContains("token"))
        await runtime.disconnect()
    }

    func testOnlyConfirmedSignedInRefreshRearmsRecoveryForAFutureExpiration() async throws {
        let transport = AuthCodexTransport(accountResponse: Self.signedInAccountResponse)
        let runtime = CodexRuntime(client: transport)
        let finalMarker = "second-expiration-marker"
        let loginCompleted = expectation(description: "runtime observed successful login ceremony")
        let recordedEvents = Task { () throws -> [AgentRuntimeEvent] in
            try await collectAuthEventsThroughAccountMarker(
                from: runtime.events,
                marker: finalMarker,
                onLoginCompleted: { loginCompleted.fulfill() }
            )
        }

        _ = try await runtime.connect()
        await transport.setRequestFailure(Self.revokedRefreshTokenDiagnostic, for: "turn/start")
        await assertAuthenticationRecoveryError("first expiration") {
            try await AuthenticationFailingOperation.turnStart.run(on: runtime)
        }

        // A routine signed-in snapshot can still describe cached identity. It
        // must not rearm recovery without a successful login ceremony.
        await transport.setRequestFailure(nil, for: "turn/start")
        _ = try await runtime.refreshAccount()
        await transport.setRequestFailure(Self.revokedRefreshTokenDiagnostic, for: "turn/start")
        await assertAuthenticationRecoveryError("duplicate expiration before login") {
            try await AuthenticationFailingOperation.turnStart.run(on: runtime)
        }

        await transport.emitNotification(
            method: "account/login/completed",
            params: .object([
                "loginId": .string("replacement-login"),
                "success": .bool(true),
            ])
        )
        await fulfillment(of: [loginCompleted], timeout: 2)
        await transport.setRequestFailure(nil, for: "turn/start")
        let refreshed = try await runtime.refreshAccount()
        XCTAssertTrue(refreshed.auth.isSignedIn)

        await transport.setRequestFailure(Self.revokedRefreshTokenDiagnostic, for: "turn/start")
        await assertAuthenticationRecoveryError("future expiration after confirmed login") {
            try await AuthenticationFailingOperation.turnStart.run(on: runtime)
        }
        await transport.emitAccountMarker(finalMarker)

        let events = try await recordedEvents.value
        XCTAssertEqual(
            events.filter(\.isAuthenticationRecoveryRequired).count,
            2,
            "The duplicate pre-login failure stays latched; the post-login failure is a new recovery"
        )
        XCTAssertFalse(events.contains(where: \.isRuntimeNotice))
        await runtime.disconnect()
    }

    private static let signedInAccountResponse = JSONValue.object([
        "account": .object([
            "type": .string("chatgpt"),
            "email": .string("person@example.com"),
            "planType": .string("pro"),
        ]),
        "requiresOpenaiAuth": .bool(true),
    ])

    private func assertAuthenticationRecoveryError(
        _ context: String = "request",
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("\(context) should require a new sign-in")
        } catch let error as AgentRuntimeError {
            guard case .authenticationRecoveryRequired(.signInExpired) = error else {
                return XCTFail("Expected structured authentication recovery for \(context), got \(error)")
            }
        } catch {
            XCTFail("Expected structured authentication recovery for \(context), got \(error)")
        }
    }

    private func assertSingleStructuredRecoveryWithoutRuntimeNotice(
        _ events: [AgentRuntimeEvent],
        _ context: String = "request"
    ) {
        XCTAssertEqual(
            events.filter(\.isAuthenticationRecoveryRequired).count,
            1,
            "\(context) must publish exactly one attached sign-in recovery"
        )
        XCTAssertFalse(
            events.contains(where: \.isRuntimeNotice),
            "\(context) must not also surface a raw or generic runtime notice"
        )
    }
}

private enum AuthenticationFailingOperation: String, CaseIterable {
    case threadRead = "thread/read"
    case threadResume = "thread/resume"
    case paginatedThreadRead = "thread/read paginated metadata"
    case paginatedThreadResume = "thread/resume paginated history"
    case olderHistoryPage = "thread/turns/list pagination"
    case turnStart = "turn/start"

    var requestMethod: String {
        switch self {
        case .threadRead, .paginatedThreadRead:
            "thread/read"
        case .threadResume, .paginatedThreadResume:
            "thread/resume"
        case .olderHistoryPage:
            "thread/turns/list"
        case .turnStart:
            "turn/start"
        }
    }

    func run(on runtime: CodexRuntime) async throws {
        switch self {
        case .threadRead:
            _ = try await runtime.readThread(id: "auth-test-thread")
        case .threadResume:
            _ = try await runtime.resumeThread(id: "auth-test-thread")
        case .paginatedThreadRead:
            _ = try await runtime.readThread(
                id: "auth-test-thread",
                initialHistoryPage: RuntimeThreadHistoryPageRequest(limit: 20)
            )
        case .paginatedThreadResume:
            _ = try await runtime.resumeThread(
                id: "auth-test-thread",
                initialHistoryPage: RuntimeInitialThreadHistoryPageRequest(limit: 20)
            )
        case .olderHistoryPage:
            _ = try await runtime.listThreadHistory(
                id: "auth-test-thread",
                page: RuntimeThreadHistoryPageRequest(cursor: "older", limit: 20)
            )
        case .turnStart:
            try await runtime.startTurn(
                StartTurnRequest(
                    threadID: "auth-test-thread",
                    inputs: [.text("Continue")]
                )
            )
        }
    }
}

private extension AgentRuntimeEvent {
    var isAuthenticationRecoveryRequired: Bool {
        if case .authenticationRecoveryRequired = self { return true }
        return false
    }

    var isRuntimeNotice: Bool {
        if case .runtimeNotice = self { return true }
        return false
    }
}

private func collectAuthEventsThroughConnectionFailure(
    from stream: AsyncStream<AgentRuntimeEvent>
) async throws -> [AgentRuntimeEvent] {
    try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
        group.addTask {
            var events: [AgentRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case .connectionChanged(.failed) = event {
                    return events
                }
            }
            throw AuthCodexTransport.TestFailure.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw AuthCodexTransport.TestFailure.timedOutWaitingForEvents
        }

        guard let events = try await group.next() else {
            throw AuthCodexTransport.TestFailure.eventStreamEnded
        }
        group.cancelAll()
        return events
    }
}

private func collectAuthEventsThroughAccountMarker(
    from stream: AsyncStream<AgentRuntimeEvent>,
    marker: String,
    onLoginCompleted: (@Sendable () -> Void)? = nil
) async throws -> [AgentRuntimeEvent] {
    try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
        group.addTask {
            var events: [AgentRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case .loginCompleted = event {
                    onLoginCompleted?()
                }
                if case let .accountUpdated(auth) = event,
                   auth.planLabel == marker {
                    return events
                }
            }
            throw AuthCodexTransport.TestFailure.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw AuthCodexTransport.TestFailure.timedOutWaitingForEvents
        }

        guard let events = try await group.next() else {
            throw AuthCodexTransport.TestFailure.eventStreamEnded
        }
        group.cancelAll()
        return events
    }
}

private func collectAuthEventsThroughTurnCompletion(
    from stream: AsyncStream<AgentRuntimeEvent>,
    threadID: String
) async throws -> [AgentRuntimeEvent] {
    try await withThrowingTaskGroup(of: [AgentRuntimeEvent].self) { group in
        group.addTask {
            var events: [AgentRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case let .turnCompleted(completedThreadID, _) = event,
                   completedThreadID == threadID {
                    return events
                }
            }
            throw AuthCodexTransport.TestFailure.eventStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw AuthCodexTransport.TestFailure.timedOutWaitingForEvents
        }

        guard let events = try await group.next() else {
            throw AuthCodexTransport.TestFailure.eventStreamEnded
        }
        group.cancelAll()
        return events
    }
}

private actor AuthCodexTransport: CodexAppServerTransport {
    struct Request: Sendable, Equatable {
        let method: String
        let params: JSONValue
    }

    enum TestFailure: Error {
        case eventStreamEnded
        case modelCatalogUnavailable
        case timedOutWaitingForEvents
    }

    nonisolated let events: AsyncStream<AppServerEvent>

    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation
    private let accountResponse: JSONValue
    private let failModelList: Bool
    private var requestFailures: [String: String]
    private var loginStartResponses: [JSONValue]
    private var requests: [Request] = []
    private var starts = 0
    private var stops = 0

    init(
        accountResponse: JSONValue = .object([
            "account": .null,
            "requiresOpenaiAuth": .bool(true),
        ]),
        failModelList: Bool = false,
        loginStartResponses: [JSONValue] = [],
        requestFailures: [String: String] = [:]
    ) {
        self.accountResponse = accountResponse
        self.failModelList = failModelList
        self.loginStartResponses = loginStartResponses
        self.requestFailures = requestFailures
        let eventStream = AsyncStream.makeStream(of: AppServerEvent.self)
        events = eventStream.stream
        eventContinuation = eventStream.continuation
    }

    func start() async throws -> AppServerConnection {
        starts += 1
        return AppServerConnection(generation: 1, initializeResponse: .object([:]))
    }

    func stop() async {
        stops += 1
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        requests.append(Request(method: method, params: params))

        if let failure = requestFailures[method] {
            throw AgentRuntimeError.requestFailed(code: -32_000, message: failure)
        }

        switch method {
        case "account/login/start":
            guard !loginStartResponses.isEmpty else { return .object([:]) }
            return loginStartResponses.removeFirst()
        case "account/read":
            return accountResponse
        case "model/list":
            if failModelList { throw TestFailure.modelCatalogUnavailable }
            return .object(["data": .array([])])
        default:
            return .object([:])
        }
    }

    func respond(id _: RuntimeRequestID, result _: JSONValue) async throws {}

    func recordedRequests() -> [Request] {
        requests
    }

    func stopCount() -> Int {
        stops
    }

    func startCount() -> Int {
        starts
    }

    func setRequestFailure(_ message: String?, for method: String) {
        requestFailures[method] = message
    }

    func emitAccountMarker(_ marker: String) {
        emitNotification(
            method: "account/updated",
            params: .object([
                "authMode": .string("chatgpt"),
                "planType": .string(marker),
            ])
        )
    }

    func emitStderr(_ message: String) {
        eventContinuation.yield(.stderr(generation: 1, message))
    }

    func emitNotification(method: String, params: JSONValue) {
        eventContinuation.yield(
            .notification(
                generation: 1,
                AppServerNotification(method: method, params: params)
            )
        )
    }
}
