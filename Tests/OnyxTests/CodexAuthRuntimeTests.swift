import Foundation
import XCTest
@testable import Onyx

final class CodexAuthRuntimeTests: XCTestCase {
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
    private var loginStartResponses: [JSONValue]
    private var requests: [Request] = []

    init(
        accountResponse: JSONValue = .object([
            "account": .null,
            "requiresOpenaiAuth": .bool(true),
        ]),
        failModelList: Bool = false,
        loginStartResponses: [JSONValue] = []
    ) {
        self.accountResponse = accountResponse
        self.failModelList = failModelList
        self.loginStartResponses = loginStartResponses
        let eventStream = AsyncStream.makeStream(of: AppServerEvent.self)
        events = eventStream.stream
        eventContinuation = eventStream.continuation
    }

    func start() async throws -> AppServerConnection {
        AppServerConnection(generation: 1, initializeResponse: .object([:]))
    }

    func stop() async {}

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        requests.append(Request(method: method, params: params))

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

    func emitNotification(method: String, params: JSONValue) {
        eventContinuation.yield(
            .notification(
                generation: 1,
                AppServerNotification(method: method, params: params)
            )
        )
    }
}
