import Foundation
import XCTest
@testable import Onyx

/// Integration coverage for the short-lived loopback boundary used when a
/// compatible provider is routed through Codex app-server. These tests use a
/// real localhost listener for the client side and URLProtocol only for the
/// HTTPS provider side, so credentials and byte framing cross the same
/// boundaries they do in a running app without requiring an external server.
final class OpenAICompatibleResponsesProxyTests: XCTestCase {
    private static let completedEvent = "data: {\"type\":\"response.completed\","
        + "\"response\":{\"id\":\"resp_fixture\",\"status\":\"completed\"}}\n\n"

    private static func outputTextDelta(_ delta: String) -> String {
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"\(delta)\"}\n\n"
    }

    private static func outputTextDone(text: String) -> String {
        "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\","
            + "\"output_index\":0,\"content_index\":0,\"text\":\"\(text)\"}\n\n"
    }

    override func tearDown() {
        ProxyUpstreamURLProtocol.reset()
        super.tearDown()
    }

    func testListenerRejectsUnauthorizedAndUnsupportedRoutesBeforeForwarding() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(
            credential: nil,
            authMode: .none,
            disposableToken: "local-token"
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let unauthorized = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: "wrong-token"
        )
        XCTAssertEqual(unauthorized.response.statusCode, 401)

        let unsupported = try await sendClientRequest(
            binding: binding,
            target: "/v1/models",
            token: "local-token"
        )
        XCTAssertEqual(unsupported.response.statusCode, 404)
        XCTAssertTrue(requests.requests.isEmpty)
    }

    func testRejectsCompressedClientRequestBeforeForwarding() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken,
            extraHeaders: ["Content-Encoding": "gzip"]
        )

        XCTAssertEqual(result.response.statusCode, 415)
        XCTAssertTrue(requests.requests.isEmpty)
    }

    func testInjectsProviderCredentialOnlyUpstreamAndDoesNotEchoItToClient() async throws {
        let secret = "fixture-provider-secret"
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sseChunks([
                Data(
                    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\","
                        .appending("\"output_index\":0,\"content_index\":0,\"delta\":\"prefix ")
                        .appending(String(secret.prefix(9)))
                        .utf8
                ),
                Data(
                    String(secret.dropFirst(9))
                        .appending(" suffix\"}\n\n")
                        .appending(Self.outputTextDone(text: "prefix \(secret) suffix"))
                        .appending(Self.completedEvent)
                        .utf8
                ),
            ])
        }
        let proxy = try makeProxy(
            credential: secret,
            authMode: .bearer,
            disposableToken: "local-token"
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken,
            body: Data(#"{"model":"fixture-model","stream":true}"#.utf8)
        )
        let body = String(decoding: result.body, as: UTF8.self)
        let sent = try XCTUnwrap(requests.requests.first)

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
        XCTAssertFalse(body.contains(secret))
        XCTAssertTrue(body.contains("prefix  suffix"))
        XCTAssertFalse(body.contains(binding.bearerToken))
    }

    func testInjectsDefaultOutputBudgetWhenAppServerOmitsIt() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken,
            body: Data(#"{"model":"fixture-model","stream":true}"#.utf8)
        )
        let upstreamBody = try XCTUnwrap(requests.bodies.first ?? nil)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any]
        )

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(
            payload["max_output_tokens"] as? Int,
            OpenAICompatibleResponsesProxy.defaultMaximumOutputTokens
        )
    }

    func testPreservesCallerSpecifiedOutputBudgetByteForByte() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }
        let original = Data(
            #"{ "stream" : true, "max_output_tokens" : 777, "model" : "fixture-model" }"#.utf8
        )

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken,
            body: original
        )

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(requests.bodies.first ?? nil, original)
    }

    func testClampsInjectedOutputBudgetToRequestedModelsAdvertisedLimit() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            completionLimits: ["small-model": 8_192, "fixture-model": 12_000]
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken,
            body: Data(#"{"model":"small-model","stream":true}"#.utf8)
        )
        let upstreamBody = try XCTUnwrap(requests.bodies.first ?? nil)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any]
        )

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 8_192)
    }

    func testDerivesInjectedOutputBudgetFromModelContextWhenCompletionLimitIsAbsent() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            contextLimits: ["context-model": 8_192]
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken,
            body: Data(#"{"model":"context-model","stream":true}"#.utf8)
        )
        let upstreamBody = try XCTUnwrap(requests.bodies.first ?? nil)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: upstreamBody) as? [String: Any]
        )

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 4_096)
    }

    func testRejectsMalformedAndNonObjectJSONBeforeCredentialedForwarding() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(
            credential: "fixture-provider-secret",
            authMode: .bearer,
            disposableToken: "local-token"
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        for body in [Data(#"{"model":"unterminated""#.utf8), Data(#"["not","an","object"]"#.utf8)] {
            let result = try await sendClientRequest(
                binding: binding,
                target: "/v1/responses",
                token: binding.bearerToken,
                body: body
            )
            XCTAssertEqual(result.response.statusCode, 400)
        }
        XCTAssertTrue(requests.requests.isEmpty)
    }

    func testOversizedRequestStillFailsBeforeJSONRewriteOrForwarding() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            limits: .init(maximumRequestBodyBytes: 1_024)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }
        let oversized = Data(
            (#"{"model":"fixture-model","input":""#
                + String(repeating: "x", count: 1_024)
                + #""}"#).utf8
        )

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken,
            body: oversized
        )

        XCTAssertEqual(result.response.statusCode, 413)
        XCTAssertTrue(requests.requests.isEmpty)
    }

    func testRedirectIsNotFollowedToAnotherProviderURL() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            if request.url?.path == "/v1/responses" {
                return .redirect(
                    location: "https://attacker.example.test/v1/responses"
                )
            }
            return .sse(Self.completedEvent)
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )

        // Redirect refusal is surfaced as a typed provider failure and must
        // never issue the redirected request.
        XCTAssertEqual(result.response.statusCode, 502)
        XCTAssertEqual(requests.requests.count, 1)
        XCTAssertEqual(requests.requests.first?.url?.absoluteString,
                       "https://provider.example.test/v1/responses")
    }

    func testRejectsCompressedUpstreamBodyBeforeSendingResponseHead() async throws {
        let requests = ProxyRequestRecorder()
        ProxyUpstreamURLProtocol.configure { request in
            requests.record(request)
            return .sse(
                "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
                headers: ["Content-Encoding": "gzip"]
            )
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )

        XCTAssertEqual(result.response.statusCode, 502)
        XCTAssertEqual(requests.requests.count, 1)
        XCTAssertFalse(String(decoding: result.body, as: UTF8.self).contains("gzip"))
    }

    func testStopsUpstreamImmediatelyAfterTerminalEvent() async throws {
        let upstreamStarted = CancellationProbe()
        let upstreamCancelled = CancellationProbe()
        let terminal = Self.completedEvent
        let trailing = Self.outputTextDelta("must-not-forward")
        ProxyUpstreamURLProtocol.configure { _ in
            .held(
                prefix: Data((terminal + trailing).utf8),
                started: upstreamStarted,
                cancelled: upstreamCancelled
            )
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            limits: .init(requestTimeout: 5, resourceTimeout: 6)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )
        let body = String(decoding: result.body, as: UTF8.self)

        let didStart = await upstreamStarted.wait(timeout: .seconds(1))
        let didCancel = await upstreamCancelled.wait(timeout: .seconds(1))
        XCTAssertTrue(didStart)
        XCTAssertTrue(didCancel)
        XCTAssertTrue(body.contains("response.completed"))
        XCTAssertFalse(body.contains("must-not-forward"))
    }

    func testFiltersHopByHopAndCredentialBearingResponseHeaders() async throws {
        let upstreamBody = Self.completedEvent
        ProxyUpstreamURLProtocol.configure { _ in
            .sse(
                upstreamBody,
                headers: [
                    "Set-Cookie": "provider-secret=do-not-forward",
                    "Authorization": "Bearer fixture-secret",
                    "X-Api-Key": "fixture-secret",
                    "X-Provider-Trace": "trace fixture-secret",
                    "X-fixture-secret-Trace": "credential-in-name",
                    "Content-Length": String(upstreamBody.utf8.count),
                    "Connection": "keep-alive",
                    "X-Visible-Provider-Header": "visible",
                ]
            )
        }
        let proxy = try makeProxy(
            credential: "fixture-secret",
            authMode: .bearer,
            disposableToken: "local-token"
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )
        let headers = result.headers

        XCTAssertEqual(headers["x-visible-provider-header"], "visible")
        XCTAssertNil(headers["set-cookie"])
        XCTAssertNil(headers["authorization"])
        XCTAssertNil(headers["x-api-key"])
        XCTAssertNil(headers["x-provider-trace"])
        XCTAssertNil(headers["x-fixture-secret-trace"])
        XCTAssertNil(headers["content-length"])
        XCTAssertEqual(headers["connection"]?.lowercased(), "close")
        XCTAssertFalse(headers.values.contains { $0.contains("do-not-forward") })
        // Chunk framing and close behavior are owned by the proxy, not copied
        // from the upstream response.
    }

    func testDropsMalformedResponseHeaderNamesAndControlValues() async throws {
        ProxyUpstreamURLProtocol.configure { _ in
            .sse(
                Self.completedEvent,
                headers: [
                    "X-Bad\r\nInjected": "must-not-become-a-second-header",
                    "X-Nul-Provider": "before\0after",
                    "X-DEL-Provider": "before\u{7F}after",
                    "X-Tab-Provider": "visible\tvalue",
                ]
            )
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertNil(result.headers["x-bad\r\ninjected"])
        XCTAssertNil(result.headers["x-nul-provider"])
        XCTAssertNil(result.headers["x-del-provider"])
        XCTAssertEqual(result.headers["x-tab-provider"], "visible\tvalue")
    }

    func testRejectsOversizedUpstreamResponseHeadersBeforeForwarding() async throws {
        let oversizedHeader = String(repeating: "x", count: 2_048)
        ProxyUpstreamURLProtocol.configure { _ in
            .sse(
                Self.completedEvent,
                headers: ["X-Oversized-Provider-Header": oversizedHeader]
            )
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            limits: .init(maximumUpstreamResponseHeaderBytes: 1_024)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )

        XCTAssertEqual(result.response.statusCode, 502)
        XCTAssertNil(result.headers["x-oversized-provider-header"])
        XCTAssertFalse(
            String(decoding: result.body, as: UTF8.self).contains("response.completed")
        )
    }

    func testAllowsResponseHeadersNearConfiguredBound() async throws {
        let nearBoundHeader = String(repeating: "x", count: 700)
        ProxyUpstreamURLProtocol.configure { _ in
            .sse(
                Self.completedEvent,
                headers: ["X-Near-Bound-Provider-Header": nearBoundHeader]
            )
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            limits: .init(maximumUpstreamResponseHeaderBytes: 1_024)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )

        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(result.headers["x-near-bound-provider-header"], nearBoundHeader)
        XCTAssertTrue(
            String(decoding: result.body, as: UTF8.self).contains("response.completed")
        )
    }

    func testBoundsHeadersThatWouldOtherwiseBeFiltered() async throws {
        let oversizedCookie = String(repeating: "x", count: 2_048)
        ProxyUpstreamURLProtocol.configure { _ in
            .sse(
                Self.completedEvent,
                headers: ["Set-Cookie": oversizedCookie]
            )
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            limits: .init(maximumUpstreamResponseHeaderBytes: 1_024)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )

        XCTAssertEqual(result.response.statusCode, 502)
        XCTAssertNil(result.headers["set-cookie"])
        XCTAssertFalse(
            String(decoding: result.body, as: UTF8.self).contains("response.completed")
        )
    }

    func testClientCancellationCancelsAnUpstreamStream() async throws {
        let upstreamStarted = CancellationProbe()
        let upstreamCancelled = CancellationProbe()
        ProxyUpstreamURLProtocol.configure { _ in
            .held(
                prefix: Data(repeating: 0x20, count: 16 * 1_024),
                started: upstreamStarted,
                cancelled: upstreamCancelled
            )
        }
        let proxy = try makeProxy(
            credential: "fixture-secret",
            authMode: .bearer,
            disposableToken: "local-token",
            limits: .init(requestTimeout: 2, resourceTimeout: 3)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let client = try RawLoopbackConnection(port: try XCTUnwrap(binding.baseURL.port))
        try await client.start()
        let request = makeRawRequest(
            target: "/v1/responses",
            port: try XCTUnwrap(binding.baseURL.port),
            token: binding.bearerToken,
            body: Data(#"{"model":"fixture-model","stream":true}"#.utf8)
        )
        let task = Task {
            do {
                try await client.send(request)
                _ = try await client.receiveUntilClosed()
            } catch {
                // Cancellation and the expected closed local socket both end
                // this task; the upstream observer is the assertion of value.
            }
        }

        let started = await upstreamStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(started)
        task.cancel()
        _ = await task.result
        let cancelled = await upstreamCancelled.wait(timeout: .seconds(2))
        XCTAssertTrue(cancelled)
        client.cancel()
    }

    func testDisconnectBeforeUpstreamResponseCancelsPromptlyRatherThanWaitingForTimeout() async throws {
        let upstreamStarted = CancellationProbe()
        let upstreamCancelled = CancellationProbe()
        ProxyUpstreamURLProtocol.configure { _ in
            .heldBeforeResponse(
                started: upstreamStarted,
                cancelled: upstreamCancelled
            )
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            limits: .init(requestTimeout: 10, resourceTimeout: 12)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let port = try XCTUnwrap(binding.baseURL.port)
        let client = try RawLoopbackConnection(port: port)
        try await client.start()
        try await client.send(
            makeRawRequest(
                target: "/v1/responses",
                port: port,
                token: binding.bearerToken,
                body: Data(#"{"model":"fixture-model","stream":true}"#.utf8)
            )
        )

        let didStart = await upstreamStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(didStart)
        let cancelledBeforeDisconnect = await upstreamCancelled.wait(timeout: .milliseconds(100))
        XCTAssertFalse(
            cancelledBeforeDisconnect,
            "The fixture must remain upstream until the client disconnects"
        )

        client.cancel()
        let cancelledAfterDisconnect = await upstreamCancelled.wait(timeout: .seconds(1))
        XCTAssertTrue(
            cancelledAfterDisconnect,
            "Client disconnect should cancel upstream well before its 10-second timeout"
        )
    }

    func testFlushesACompleteSSEFrameBeforeUpstreamFinishes() async throws {
        let upstreamStarted = CancellationProbe()
        ProxyUpstreamURLProtocol.configure { _ in
            .held(
                prefix: Data(Self.outputTextDelta("first").utf8),
                started: upstreamStarted,
                cancelled: nil
            )
        }
        let proxy = try makeProxy(
            disposableToken: "local-token",
            limits: .init(requestTimeout: 5, resourceTimeout: 6)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let port = try XCTUnwrap(binding.baseURL.port)
        let client = try RawLoopbackConnection(port: port)
        try await client.start()
        try await client.send(
            makeRawRequest(
                target: "/v1/responses",
                port: port,
                token: binding.bearerToken,
                body: Data(#"{"model":"fixture-model","stream":true}"#.utf8)
            )
        )
        defer { client.cancel() }

        let upstreamDidStart = await upstreamStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(upstreamDidStart)

        var received = Data()
        let headerBoundary = Data("\r\n\r\n".utf8)
        while received.range(of: headerBoundary) == nil {
            received.append(
                try await receiveChunkWithin(
                    client,
                    timeout: .milliseconds(750)
                )
            )
        }
        let bodyStart = try XCTUnwrap(received.range(of: headerBoundary)?.upperBound)
        if received.count == bodyStart {
            // The upstream fixture deliberately keeps the connection open.
            // A frame-boundary flush must make the body observable without
            // waiting for that stream to finish.
            received.append(
                try await receiveChunkWithin(
                    client,
                    timeout: .milliseconds(750)
                )
            )
        }

        XCTAssertGreaterThan(received.count, bodyStart)
        XCTAssertTrue(
            String(decoding: received[bodyStart...], as: UTF8.self)
                .contains("first")
        )
    }

    func testPostHeadUpstreamFailureClosesWithoutAppendingASecondHTTPResponse() async throws {
        ProxyUpstreamURLProtocol.configure { _ in
            .failsAfter(prefix: Data(Self.outputTextDelta("partial").utf8))
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let port = try XCTUnwrap(binding.baseURL.port)
        let client = try RawLoopbackConnection(port: port)
        try await client.start()
        defer { client.cancel() }
        try await client.send(
            makeRawRequest(
                target: "/v1/responses",
                port: port,
                token: binding.bearerToken,
                body: Data(#"{"model":"fixture-model","stream":true}"#.utf8)
            )
        )
        let raw = try await client.receiveUntilClosed()
        let responseText = String(decoding: raw, as: UTF8.self)

        XCTAssertEqual(responseText.components(separatedBy: "HTTP/1.1").count - 1, 1)
        XCTAssertFalse(responseText.contains("HTTP/1.1 502"))
    }

    func testEOFWithoutTerminalClosesWithoutCleanChunkCompletion() async throws {
        ProxyUpstreamURLProtocol.configure { _ in
            .sse(Self.outputTextDelta("truncated"))
        }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let port = try XCTUnwrap(binding.baseURL.port)
        let client = try RawLoopbackConnection(port: port)
        try await client.start()
        defer { client.cancel() }
        try await client.send(
            makeRawRequest(
                target: "/v1/responses",
                port: port,
                token: binding.bearerToken,
                body: Data(#"{"model":"fixture-model","stream":true}"#.utf8)
            )
        )
        let raw = try await client.receiveUntilClosed()

        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("truncated"))
        XCTAssertFalse(
            raw.suffix(5).elementsEqual(Data("0\r\n\r\n".utf8)),
            "A truncated provider stream must not look like clean chunked completion"
        )
    }

    func testResponseLimitStopsForwardingAndCancelsUpstream() async throws {
        let upstreamCancelled = CancellationProbe()
        let oversized = Data(repeating: 0x41, count: 1_025)
        ProxyUpstreamURLProtocol.configure { _ in
            .held(
                prefix: oversized,
                started: nil,
                cancelled: upstreamCancelled
            )
        }
        let proxy = try makeProxy(
            credential: "fixture-secret",
            authMode: .bearer,
            disposableToken: "local-token",
            limits: .init(maximumResponseBytes: 1_024, requestTimeout: 2, resourceTimeout: 3)
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        do {
            let result = try await sendClientRequest(
                binding: binding,
                target: "/v1/responses",
                token: binding.bearerToken
            )
            // The proxy sends the response head before it notices an overrun;
            // a complete body or terminating chunk would be a security bug.
            XCTAssertTrue(result.body.isEmpty)
        } catch {
            // A deliberate connection close is the expected bounded-failure
            // surface once an upstream response head is already visible.
        }
        let cancelled = await upstreamCancelled.wait(timeout: .seconds(2))
        XCTAssertTrue(cancelled)
    }

    func testIncompleteIsPreservedAndReasoningIsSuppressed() async throws {
        let reasoning = "raw hidden chain of thought"
        let upstreamBody = """
        data: {"type":"response.reasoning_text.delta","delta":"\(reasoning)"}

        data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

        """
        ProxyUpstreamURLProtocol.configure { _ in .sse(upstreamBody) }
        let proxy = try makeProxy(disposableToken: "local-token")
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }

        let result = try await sendClientRequest(
            binding: binding,
            target: "/v1/responses",
            token: binding.bearerToken
        )
        let body = String(decoding: result.body, as: UTF8.self)

        XCTAssertFalse(body.contains(reasoning))
        XCTAssertTrue(body.contains("response.in_progress"))
        XCTAssertTrue(body.contains("response.incomplete"))
        XCTAssertTrue(body.contains("max_output_tokens"))
    }

    private func receiveChunkWithin(
        _ client: RawLoopbackConnection,
        timeout: Duration
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                while true {
                    guard let chunk = try await client.receiveChunk() else {
                        throw ProxyTestError.connectionClosed
                    }
                    if !chunk.isEmpty { return chunk }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProxyTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ProxyTestError.timedOut
            }
            return first
        }
    }

    private func makeProxy(
        credential: String? = nil,
        authMode: ProviderConnectionAuthMode = .none,
        disposableToken: String = "fixture-local-token",
        limits: OpenAICompatibleResponsesProxy.Limits = .init(),
        completionLimits: [String: Int] = [:],
        contextLimits: [String: Int] = [:]
    ) throws -> OpenAICompatibleResponsesProxy {
        let modelIDs = Set(completionLimits.keys).union(contextLimits.keys).sorted()
        let discoveredModels = try modelIDs.map { modelID in
            try ProviderModelDescriptor(
                id: modelID,
                wireProtocol: .openAIChatCompletions,
                capabilities: ProviderCapabilitySet(),
                contextLength: contextLimits[modelID],
                maxCompletionTokens: completionLimits[modelID]
            )
        }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("responses.proxy.fixture"),
            displayName: "Responses proxy fixture",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: "fixture-model",
            authMode: authMode,
            discovery: ProviderConnectionDiscoveryMetadata(
                discoveredModels: discoveredModels
            )
        )
        let providerCredential = try credential.map(ProviderBearerCredential.init)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyUpstreamURLProtocol.self]
        return try OpenAICompatibleResponsesProxy(
            connection: connection,
            upstreamCredential: providerCredential,
            disposableToken: disposableToken,
            session: URLSession(configuration: configuration),
            limits: limits
        )
    }

    private func sendClientRequest(
        binding: OpenAICompatibleResponsesProxy.LaunchBinding,
        target: String,
        token: String,
        body: Data = Data(#"{"model":"fixture-model","stream":true}"#.utf8),
        extraHeaders: [String: String] = [:]
    ) async throws -> ClientResponse {
        let port = try XCTUnwrap(binding.baseURL.port)
        let client = try RawLoopbackConnection(port: port)
        defer { client.cancel() }
        try await client.start()
        try await client.send(
            makeRawRequest(
                target: target,
                port: port,
                token: token,
                body: body,
                extraHeaders: extraHeaders
            )
        )
        let raw = try await client.receiveUntilClosed()
        return try parseClientResponse(raw, target: target, port: port)
    }

    private func makeRawRequest(
        target: String,
        port: Int,
        token: String,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var head = "POST \(target) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Authorization: Bearer \(token)\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private func parseClientResponse(
        _ raw: Data,
        target: String,
        port: Int
    ) throws -> ClientResponse {
        guard let boundary = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw ProxyTestError.malformedResponse
        }
        let headData = raw[..<boundary.lowerBound]
        guard let headText = String(data: headData, encoding: .utf8) else {
            throw ProxyTestError.malformedResponse
        }
        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ProxyTestError.malformedResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw ProxyTestError.malformedResponse
        }
        var headers: [String: String] = [:]
        var originalHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let rawName = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[rawName.lowercased()] = value
            originalHeaders[rawName] = value
        }
        let bodyStart = boundary.upperBound
        let framedBody = raw[bodyStart...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = decodeChunked(framedBody)
        } else if let count = headers["content-length"].flatMap(Int.init) {
            body = Data(framedBody.prefix(max(0, count)))
        } else {
            body = Data(framedBody)
        }
        let url = URL(string: "http://127.0.0.1:\(port)\(target)")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: originalHeaders
        )!
        return ClientResponse(body: body, response: response, headers: headers)
    }

    private func decodeChunked(_ data: Data) -> Data {
        let bytes = Array(data)
        var offset = 0
        var decoded: [UInt8] = []
        while offset < bytes.count {
            guard let lineEnd = bytes[offset...].firstRange(of: [0x0D, 0x0A]) else { break }
            let sizeText = String(decoding: bytes[offset ..< lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";", maxSplits: 1)[0], radix: 16) else {
                break
            }
            offset = lineEnd.upperBound
            if size == 0 { break }
            guard offset + size <= bytes.count else {
                decoded.append(contentsOf: bytes[offset...])
                break
            }
            decoded.append(contentsOf: bytes[offset ..< offset + size])
            offset += size
            guard offset + 2 <= bytes.count else { break }
            offset += 2
        }
        return Data(decoded)
    }
}

private struct ClientResponse: Sendable {
    let body: Data
    let response: HTTPURLResponse
    let headers: [String: String]
}

enum ProxyTestError: Error {
    case malformedResponse
    case connectionClosed
    case timedOut
}

private final class ProxyRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    private var bodyValues: [Data?] = []

    var requests: [URLRequest] { lock.withLock { values } }
    var bodies: [Data?] { lock.withLock { bodyValues } }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        lock.withLock {
            values.append(request)
            bodyValues.append(body)
        }
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false

    func signal() { lock.withLock { signalled = true } }

    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !lock.withLock({ signalled }) {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

private final class ProxyUpstreamURLProtocol: URLProtocol {
    private var cancellationProbe: CancellationProbe?

    struct Response: @unchecked Sendable {
        enum Body: @unchecked Sendable {
            case complete(Data)
            case chunks([Data])
            case heldBeforeResponse(
                started: CancellationProbe,
                cancelled: CancellationProbe
            )
            case held(
                prefix: Data,
                started: CancellationProbe?,
                cancelled: CancellationProbe?,
                finishImmediately: Bool
            )
            case failure(prefix: Data, error: NSError)
        }

        let statusCode: Int
        let headers: [String: String]
        let body: Body
        let redirectLocation: String?

        static func sse(
            _ body: String,
            headers: [String: String] = [:]
        ) -> Self {
            var merged = ["Content-Type": "text/event-stream"]
            headers.forEach { merged[$0.key] = $0.value }
            return Self(
                statusCode: 200,
                headers: merged,
                body: .complete(Data(body.utf8)),
                redirectLocation: nil
            )
        }

        static func sseChunks(_ chunks: [Data]) -> Self {
            Self(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: .chunks(chunks),
                redirectLocation: nil
            )
        }

        static func held(
            prefix: Data,
            started: CancellationProbe?,
            cancelled: CancellationProbe?,
            finishImmediately: Bool = false
        ) -> Self {
            Self(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: .held(
                    prefix: prefix,
                    started: started,
                    cancelled: cancelled,
                    finishImmediately: finishImmediately
                ),
                redirectLocation: nil
            )
        }

        static func heldBeforeResponse(
            started: CancellationProbe,
            cancelled: CancellationProbe
        ) -> Self {
            Self(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: .heldBeforeResponse(started: started, cancelled: cancelled),
                redirectLocation: nil
            )
        }

        static func failsAfter(prefix: Data) -> Self {
            Self(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: .failure(
                    prefix: prefix,
                    error: NSError(
                        domain: "OnyxTests.ProxyUpstream",
                        code: 1,
                        userInfo: nil
                    )
                ),
                redirectLocation: nil
            )
        }

        static func redirect(location: String) -> Self {
            Self(
                statusCode: 302,
                headers: ["Location": location],
                body: .complete(Data()),
                redirectLocation: location
            )
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?

    static func configure(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme?.lowercased() == "http"
            || request.url?.scheme?.lowercased() == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.lock.withLock { Self.handler }?(request)
            ?? .sse("data: [DONE]\n\n")
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        if let redirectLocation = response.redirectLocation,
           let redirectURL = URL(string: redirectLocation),
           let redirectResponse = httpResponse.copy() as? HTTPURLResponse
        {
            var redirected = request
            redirected.url = redirectURL
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirected,
                redirectResponse: redirectResponse
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        switch response.body {
        case let .heldBeforeResponse(started, cancelled):
            started.signal()
            cancellationProbe = cancelled
        case let .complete(data):
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case let .chunks(chunks):
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            for chunk in chunks where !chunk.isEmpty {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .held(prefix, started, cancelled, finishImmediately):
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            started?.signal()
            if !prefix.isEmpty { client?.urlProtocol(self, didLoad: prefix) }
            if finishImmediately {
                client?.urlProtocolDidFinishLoading(self)
            } else {
                cancellationProbe = cancelled
            }
        case let .failure(prefix, error):
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            if !prefix.isEmpty { client?.urlProtocol(self, didLoad: prefix) }
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        cancellationProbe?.signal()
    }
}
