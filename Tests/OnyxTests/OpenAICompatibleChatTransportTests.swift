import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleChatTransportTests: XCTestCase {
    override func tearDown() {
        MockChatURLProtocol.reset()
        super.tearDown()
    }

    func testNonStreamingRequestPreservesModelTypedTemplateOptionAndUsage() async throws {
        let requestProbe = RecordedRequestProbe()
        MockChatURLProtocol.configure { request in
            requestProbe.record(request)
            return .json(
                statusCode: 200,
                body: """
                {
                  "id":"chatcmpl-1",
                  "model":"Qwen/Qwen3.8-27B-FP8",
                  "choices":[{
                    "index":0,
                    "message":{"role":"assistant","content":"ONYX_QWEN_OK"},
                    "finish_reason":"stop"
                  }],
                  "usage":{"prompt_tokens":9,"completion_tokens":3,"total_tokens":12}
                }
                """
            )
        }
        let transport = try makeTransport(bearerToken: "fixture-secret")

        let response = try await transport.complete(
            makeRequest(
                stream: false,
                requestBehavior: .init(enableThinking: false)
            )
        )

        XCTAssertEqual(response.id, "chatcmpl-1")
        XCTAssertEqual(response.model, "Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(response.choices.first?.content, "ONYX_QWEN_OK")
        XCTAssertEqual(response.choices.first?.finishReason, "stop")
        XCTAssertEqual(
            response.usage,
            .init(promptTokens: 9, completionTokens: 3, totalTokens: 12)
        )

        let sent = try XCTUnwrap(requestProbe.request)
        XCTAssertEqual(sent.url?.path, "/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        let body = try XCTUnwrap(requestProbe.body)
        let payload = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(payload["model"], .string("Qwen/Qwen3.8-27B-FP8"))
        XCTAssertEqual(payload["stream"], .bool(false))
        XCTAssertEqual(
            payload["chat_template_kwargs"],
            .object(["enable_thinking": .bool(false)])
        )
    }

    func testTemplateOptionIsAbsentByDefaultAndBearerTokenIsOptional() async throws {
        let requestProbe = RecordedRequestProbe()
        MockChatURLProtocol.configure { request in
            requestProbe.record(request)
            return .json(
                statusCode: 200,
                body: """
                {"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
                """
            )
        }
        let transport = try makeTransport()

        _ = try await transport.complete(makeRequest(stream: false))

        let sent = try XCTUnwrap(requestProbe.request)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        let payload = try JSONDecoder().decode(
            JSONValue.self,
            from: try XCTUnwrap(requestProbe.body)
        )
        XCTAssertNil(payload["chat_template_kwargs"])
    }

    func testStreamingPreservesRoleEmptyContentFinishUsageOnlyAndDoneChunks() async throws {
        let body = """
        : keepalive\r
        data: {"id":"chatcmpl-2","model":"Qwen/Qwen3.8-27B-FP8","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}\r
        \r
        data: {"id":"chatcmpl-2","model":"Qwen/Qwen3.8-27B-FP8","choices":[{"index":0,"delta":{"content":"Hi 🪨"},"finish_reason":null}]}\r
        \r
        data: {"id":"chatcmpl-2","model":"Qwen/Qwen3.8-27B-FP8","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\r
        \r
        data: {"id":"chatcmpl-2","model":"Qwen/Qwen3.8-27B-FP8","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}\r
        \r
        data: [DONE]\r
        \r
        """
        let bytes = Data(body.utf8)
        let emojiStart = try XCTUnwrap(bytes.range(of: Data("🪨".utf8))?.lowerBound)
        MockChatURLProtocol.configure { _ in
            .eventStream(chunks: [
                Data(bytes[..<bytes.index(after: emojiStart)]),
                Data(bytes[bytes.index(after: emojiStart)...]),
            ])
        }
        let transport = try makeTransport()

        var events: [OpenAICompatibleChatStreamEvent] = []
        for try await event in transport.stream(makeRequest(stream: true)) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 5)
        guard case let .chunk(roleChunk) = events[0] else {
            return XCTFail("Expected role chunk")
        }
        XCTAssertEqual(roleChunk.choices[0].delta.role, "assistant")
        XCTAssertEqual(roleChunk.choices[0].delta.content, "")

        guard case let .chunk(contentChunk) = events[1] else {
            return XCTFail("Expected content chunk")
        }
        XCTAssertEqual(contentChunk.choices[0].delta.content, "Hi 🪨")

        guard case let .chunk(finishChunk) = events[2] else {
            return XCTFail("Expected finish chunk")
        }
        XCTAssertEqual(finishChunk.choices[0].finishReason, "stop")
        XCTAssertNil(finishChunk.choices[0].delta.content)

        guard case let .chunk(usageChunk) = events[3] else {
            return XCTFail("Expected usage chunk")
        }
        XCTAssertTrue(usageChunk.choices.isEmpty)
        XCTAssertEqual(
            usageChunk.usage,
            .init(promptTokens: 5, completionTokens: 2, totalTokens: 7)
        )
        XCTAssertEqual(events[4], .completed)
    }

    func testSSEParserWaitsForCompleteUTF8EventAcrossArbitraryByteBoundaries() throws {
        let event = Data("data: {\"choices\":[],\"label\":\"a🪨b\"}\r\n\r\n".utf8)
        let emoji = try XCTUnwrap(event.range(of: Data("🪨".utf8)))
        var parser = OpenAICompatibleSSEParser()

        let first = try parser.append(Data(event[..<event.index(after: emoji.lowerBound)]))
        XCTAssertTrue(first.isEmpty)
        let second = try parser.append(Data(event[event.index(after: emoji.lowerBound)...]))

        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(
            String(data: second[0], encoding: .utf8),
            "{\"choices\":[],\"label\":\"a🪨b\"}"
        )
    }

    func testHTTPErrorRedactsBearerTokenFromTypedAndLocalizedErrors() async throws {
        let secret = "sk-fixture-do-not-leak"
        MockChatURLProtocol.configure { _ in
            .json(
                statusCode: 401,
                body: """
                {"error":{"message":"Rejected \(secret)","type":"auth","code":"invalid_key"}}
                """
            )
        }
        let transport = try makeTransport(bearerToken: secret)

        do {
            _ = try await transport.complete(makeRequest(stream: false))
            XCTFail("Expected HTTP failure")
        } catch let error as OpenAICompatibleChatTransportError {
            XCTAssertEqual(
                error,
                .httpFailure(statusCode: 401, message: "Rejected [REDACTED]")
            )
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testStreamingProviderErrorRedactsBearerToken() async throws {
        let secret = "stream-secret"
        MockChatURLProtocol.configure { _ in
            .eventStream(
                chunks: [Data("data: {\"error\":{\"message\":\"bad \(secret)\"}}\n\n".utf8)]
            )
        }
        let transport = try makeTransport(bearerToken: secret)

        do {
            for try await _ in transport.stream(makeRequest(stream: true)) {}
            XCTFail("Expected provider failure")
        } catch let error as OpenAICompatibleChatTransportError {
            XCTAssertEqual(
                error,
                .providerFailure(message: "bad [REDACTED]", type: nil, code: nil)
            )
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testStreamWithoutDoneSentinelFailsInsteadOfSilentlyCompleting() async throws {
        MockChatURLProtocol.configure { _ in
            .eventStream(
                chunks: [Data("data: {\"choices\":[]}\n\n".utf8)]
            )
        }
        let transport = try makeTransport()

        do {
            for try await _ in transport.stream(makeRequest(stream: true)) {}
            XCTFail("Expected incomplete stream failure")
        } catch let error as OpenAICompatibleChatTransportError {
            XCTAssertEqual(error, .streamEndedBeforeDone)
        }
    }

    func testCancellingStreamConsumerCancelsUnderlyingURLLoading() async throws {
        let stopped = expectation(description: "URL loading stopped")
        MockChatURLProtocol.configure { _ in
            .neverFinishingEventStream(onStop: { stopped.fulfill() })
        }
        let transport = try makeTransport()
        let request = makeRequest(stream: true)
        let consumer = Task {
            for try await _ in transport.stream(request) {}
        }

        try await Task.sleep(for: .milliseconds(30))
        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        _ = try? await consumer.value
        XCTAssertTrue(consumer.isCancelled)
    }

    func testRejectsUnsafeHTTPAndRequiresAcknowledgementWithoutBearerForPrivateIP() async throws {
        XCTAssertThrowsError(
            try OpenAICompatibleChatTransport(
                endpoint: URL(string: "http://192.168.2.170:8002/v1")!,
                session: makeMockSession()
            )
        ) { error in
            XCTAssertEqual(error as? OpenAICompatibleChatTransportError, .insecureEndpoint)
        }
        XCTAssertNoThrow(
            try OpenAICompatibleChatTransport(
                endpoint: URL(string: "http://192.168.2.170:8002/v1")!,
                allowsInsecureHTTP: true,
                session: makeMockSession()
            )
        )
        for endpoint in [
            "http://provider.example.test:8002/v1",
            "http://8.8.8.8:8002/v1",
        ] {
            XCTAssertThrowsError(
                try OpenAICompatibleChatTransport(
                    endpoint: URL(string: endpoint)!,
                    allowsInsecureHTTP: true,
                    session: makeMockSession()
                )
            ) { error in
                XCTAssertEqual(
                    error as? OpenAICompatibleChatTransportError,
                    .insecureEndpoint
                )
            }
        }
        XCTAssertThrowsError(
            try OpenAICompatibleChatTransport(
                endpoint: URL(string: "http://127.0.0.1:8002/v1")!,
                bearerToken: "must-not-send",
                allowsInsecureHTTP: true,
                session: makeMockSession()
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenAICompatibleChatTransportError,
                .insecureBearerToken
            )
        }

        let transport = try makeTransport()
        do {
            for try await _ in transport.stream(makeRequest(stream: false)) {}
            XCTFail("Expected mode mismatch")
        } catch let error as OpenAICompatibleChatTransportError {
            XCTAssertEqual(error, .requestModeMismatch(expectedStreaming: true))
        }
    }

    func testRedirectPolicyBlocksTLSDowngradeAndAllOriginChanges() throws {
        let secureEndpoint = try XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions"))
        let sameOriginEndpoint = try XCTUnwrap(URL(string: "https://provider.example/v2/chat/completions"))
        let localHTTP = try XCTUnwrap(URL(string: "http://192.168.2.170:8002/v1/chat/completions"))
        let alternateSecureEndpoint = try XCTUnwrap(URL(string: "https://regional.provider.example/v1/chat/completions"))
        let localHTTPS = try XCTUnwrap(URL(string: "https://192.168.2.170:8443/v1/chat/completions"))

        XCTAssertFalse(
            ProviderHTTPRedirectPolicy.allowsRedirect(
                from: secureEndpoint,
                to: localHTTP,
                transportSecurity: .allowInsecureHTTP,
                hasBearerCredential: false
            ),
            "An HTTPS provider request must never be redirected down to HTTP."
        )
        XCTAssertFalse(
            ProviderHTTPRedirectPolicy.allowsRedirect(
                from: secureEndpoint,
                to: alternateSecureEndpoint,
                transportSecurity: .requireTLS,
                hasBearerCredential: false
            ),
            "An unauthenticated request still contains private chat history and must not follow a cross-origin redirect."
        )
        XCTAssertFalse(
            ProviderHTTPRedirectPolicy.allowsRedirect(
                from: secureEndpoint,
                to: alternateSecureEndpoint,
                transportSecurity: .requireTLS,
                hasBearerCredential: true
            ),
            "A bearer-authenticated request must not follow a cross-origin redirect."
        )
        XCTAssertFalse(
            ProviderHTTPRedirectPolicy.allowsRedirect(
                from: secureEndpoint,
                to: localHTTPS,
                transportSecurity: .requireTLS,
                hasBearerCredential: false
            ),
            "A redirect to another host must be rejected even when both URLs use TLS."
        )
        XCTAssertTrue(
            ProviderHTTPRedirectPolicy.allowsRedirect(
                from: secureEndpoint,
                to: sameOriginEndpoint,
                transportSecurity: .requireTLS,
                hasBearerCredential: false
            )
        )
        XCTAssertTrue(
            ProviderHTTPRedirectPolicy.allowsRedirect(
                from: secureEndpoint,
                to: sameOriginEndpoint,
                transportSecurity: .requireTLS,
                hasBearerCredential: true
            )
        )
    }

    private func makeTransport(
        bearerToken: String? = nil
    ) throws -> OpenAICompatibleChatTransport {
        try OpenAICompatibleChatTransport(
            endpoint: URL(string: "https://provider.example/v1")!,
            bearerToken: bearerToken,
            session: makeMockSession()
        )
    }

    private func makeRequest(
        stream: Bool,
        requestBehavior: OpenAICompatibleRequestBehavior = .init()
    ) -> OpenAICompatibleChatRequest {
        OpenAICompatibleChatRequest(
            model: "Qwen/Qwen3.8-27B-FP8",
            messages: [.init(role: .user, text: "Reply exactly ONYX_QWEN_OK")],
            stream: stream,
            reasoningEffort: nil,
            includeStreamingUsage: true,
            requestBehavior: requestBehavior
        )
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockChatURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RecordedRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var body: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        lock.lock()
        storedRequest = request
        storedBody = body
        lock.unlock()
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

private final class MockChatURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: @unchecked Sendable {
        let statusCode: Int
        let headers: [String: String]
        let chunks: [Data]
        let finishes: Bool
        let onStop: (@Sendable () -> Void)?

        static func json(statusCode: Int, body: String) -> Self {
            Self(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(body.utf8)],
                finishes: true,
                onStop: nil
            )
        }

        static func eventStream(chunks: [Data]) -> Self {
            Self(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: chunks,
                finishes: true,
                onStop: nil
            )
        }

        static func neverFinishingEventStream(
            onStop: @escaping @Sendable () -> Void
        ) -> Self {
            Self(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [],
                finishes: false,
                onStop: onStop
            )
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Stub

    private static let handlerLock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?
    private let stateLock = NSLock()
    private var activeStub: Stub?
    private var stopped = false

    static func configure(_ handler: @escaping Handler) {
        handlerLock.lock()
        self.handler = handler
        handlerLock.unlock()
    }

    static func reset() {
        handlerLock.lock()
        handler = nil
        handlerLock.unlock()
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handlerLock.lock()
        let handler = Self.handler
        Self.handlerLock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }
        let stub = handler(request)
        stateLock.lock()
        activeStub = stub
        let shouldDeliver = !stopped
        stateLock.unlock()
        guard shouldDeliver else { return }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if stub.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let onStop = activeStub?.onStop
        stateLock.unlock()
        onStop?()
    }
}
