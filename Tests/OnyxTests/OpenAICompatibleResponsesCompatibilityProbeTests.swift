import CryptoKit
import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleResponsesCompatibilityProbeTests: XCTestCase {
    override func tearDown() {
        ResponsesProbeURLProtocol.reset()
        super.tearDown()
    }

    func testTwoRequestSSEToolRoundTripProducesCacheableCompatibilityEvidence() async throws {
        let requests = ResponsesProbeRequestRecorder()
        let responses = ResponsesProbeResponseQueue([
            .eventStream(Self.initialToolCallStream),
            .eventStream(Self.followupCompletionStream),
        ])
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return responses.next()
        }
        let store = InMemoryCredentialStore()
        let connection = try makeConnection(authMode: .bearer)
        try await store.setCredential(
            ProviderBearerCredential("fixture-secret"),
            for: connection.credentialKey
        )
        let testedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = makeProbe(credentialStore: store, now: testedAt)

        let record = try await probe.probe(connection: connection, modelID: "fixture-model")

        XCTAssertEqual(
            record.outcome,
            .compatible(.init(
                usedServerSentEvents: true,
                receivedFunctionCall: true,
                submittedCorrelatedOutput: true,
                completedAfterFunctionOutput: true
            ))
        )
        XCTAssertEqual(record.testedAt, testedAt)
        XCTAssertEqual(record.expiresAt, testedAt.addingTimeInterval(3_600))
        XCTAssertTrue(record.isReusable(for: record.fingerprint, at: testedAt))

        let sent = requests.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.map(\.url?.path), ["/v1/responses", "/v1/responses"])
        XCTAssertEqual(sent.map { $0.value(forHTTPHeaderField: "Accept") }, [
            "text/event-stream", "text/event-stream",
        ])
        XCTAssertEqual(sent.map { $0.value(forHTTPHeaderField: "Cache-Control") }, [
            "no-store", "no-store",
        ])
        XCTAssertEqual(sent.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer fixture-secret", "Bearer fixture-secret",
        ])

        let first = try payload(from: requests.bodies[0])
        XCTAssertEqual(first["model"], .string("fixture-model"))
        XCTAssertEqual(first["stream"], .bool(true))
        XCTAssertNil(first["reasoning"])
        XCTAssertEqual(first["tool_choice"]?["name"], .string("onyx_responses_compatibility_probe"))
        XCTAssertEqual(first["tools"]?[0]?["type"], .string("function"))
        XCTAssertEqual(first["tools"]?[0]?["parameters"]?["additionalProperties"], .bool(false))

        let second = try payload(from: requests.bodies[1])
        XCTAssertNil(second["previous_response_id"])
        XCTAssertNil(second["reasoning"])
        XCTAssertEqual(second["tool_choice"], .string("none"))
        XCTAssertEqual(second["input"]?.arrayValue?.count, 4)
        XCTAssertEqual(second["input"]?[0]?["role"], .string("user"))
        XCTAssertEqual(second["input"]?[1]?["type"], .string("reasoning"))
        XCTAssertEqual(second["input"]?[1]?["id"], .string("rs_probe"))
        XCTAssertEqual(second["input"]?[2]?["type"], .string("function_call"))
        XCTAssertEqual(second["input"]?[2]?["id"], .string("fc_probe"))
        XCTAssertEqual(second["input"]?[2]?["call_id"], .string("call_probe"))
        XCTAssertEqual(second["input"]?[3]?["type"], .string("function_call_output"))
        XCTAssertEqual(second["input"]?[3]?["call_id"], .string("call_probe"))
        XCTAssertEqual(second["input"]?[3]?["output"], .string(#"{"ok":true}"#))

        let encodedRecord = String(
            decoding: try JSONEncoder().encode(record),
            as: UTF8.self
        )
        XCTAssertFalse(encodedRecord.contains("fixture-secret"))
        XCTAssertFalse(encodedRecord.contains("provider.example.test"))
        XCTAssertFalse(encodedRecord.contains("fixture-model"))
        XCTAssertEqual(record.fingerprint.value.count, 64)
    }

    func testQwen38UsesDirectReasoningModeForBothBoundedProbeRequests() async throws {
        let requests = ResponsesProbeRequestRecorder()
        let responses = ResponsesProbeResponseQueue([
            .eventStream(Self.initialToolCallStream),
            .eventStream(Self.followupCompletionStream),
        ])
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return responses.next()
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "Qwen/Qwen3.8-27B-FP8"
        )

        guard case .compatible = record.outcome else {
            return XCTFail("Expected Qwen's direct-mode probe to be compatible")
        }
        XCTAssertEqual(requests.requests.count, 2)
        for body in requests.bodies {
            let payload = try payload(from: body)
            XCTAssertEqual(payload["reasoning"]?["effort"], .string("none"))
            XCTAssertEqual(payload["max_output_tokens"], .integer(64))
        }
    }

    func testConversationScopeChangeInvalidatesOtherwiseIdenticalEndpointModelCacheEntry() throws {
        let first = try makeConnection(conversationScopeID: "scope-before")
        let second = try makeConnection(conversationScopeID: "scope-after")
        let firstFingerprint = OpenAICompatibleResponsesProbeFingerprint(
            connection: first,
            modelID: "fixture-model"
        )
        let secondFingerprint = OpenAICompatibleResponsesProbeFingerprint(
            connection: second,
            modelID: "fixture-model"
        )
        let record = OpenAICompatibleResponsesProbeRecord(
            fingerprint: firstFingerprint,
            testedAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 100),
            outcome: .compatible(.init(
                usedServerSentEvents: true,
                receivedFunctionCall: true,
                submittedCorrelatedOutput: true,
                completedAfterFunctionOutput: true
            ))
        )

        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
        XCTAssertFalse(
            record.isReusable(
                for: secondFingerprint,
                at: Date(timeIntervalSince1970: 20)
            )
        )
    }

    func testCurrentProbeContractDoesNotReuseCachedVersionTwoFailure() throws {
        let connection = try makeConnection()
        let modelID = "Qwen/Qwen3.8-27B-FP8"
        let current = OpenAICompatibleResponsesProbeFingerprint(
            connection: connection,
            modelID: modelID
        )
        let legacyMaterial = [
            "onyx-responses-tool-probe-v2",
            "https://provider.example.test/v1/responses",
            modelID,
            connection.conversationScopeID,
        ].joined(separator: "\u{0}")
        let legacy = SHA256.hash(data: Data(legacyMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertNotEqual(current.value, legacy)
    }

    func testHTTPFailureReturnsShortLivedTypedFailureWithoutRetainingCredentialOrBody() async throws {
        let secret = "credential-must-never-escape"
        ResponsesProbeURLProtocol.configure { _ in
            .json(
                statusCode: 401,
                body: #"{"error":{"message":"credential-must-never-escape"}}"#
            )
        }
        let store = InMemoryCredentialStore()
        let connection = try makeConnection(authMode: .bearer)
        try await store.setCredential(ProviderBearerCredential(secret), for: connection.credentialKey)
        let testedAt = Date(timeIntervalSince1970: 2_000)
        let probe = makeProbe(credentialStore: store, now: testedAt)

        let record = try await probe.probe(connection: connection, modelID: "fixture-model")

        XCTAssertEqual(record.outcome, .failed(.httpFailure(statusCode: 401)))
        XCTAssertEqual(record.expiresAt, testedAt.addingTimeInterval(30))
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
    }

    func testResponseContentLengthOverBoundFailsBeforeBodyParsing() async throws {
        ResponsesProbeURLProtocol.configure { _ in
            .eventStream(
                Self.initialToolCallStream,
                headers: ["Content-Length": "4097"]
            )
        }
        let probe = makeProbe(
            credentialStore: InMemoryCredentialStore(),
            maximumResponseBytes: 4_096
        )

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.responseTooLarge))
    }

    func testMissingTerminalEventFailsClosed() async throws {
        ResponsesProbeURLProtocol.configure { _ in
            .eventStream("""
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{}"}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.missingCompletion))
    }

    func testCompletedEventWithIncompleteResponseStatusFailsClosed() async throws {
        let requests = ResponsesProbeRequestRecorder()
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return .eventStream("""
            event: response.created
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            event: response.output_item.done
            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{}","status":"completed"}}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_initial","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{}","status":"completed"}]}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.malformedEventStream))
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testIncompleteFunctionCallItemInsideCompletedResponseFailsClosed() async throws {
        let requests = ResponsesProbeRequestRecorder()
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return .eventStream("""
            event: response.created
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed","output":[{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{}","status":"incomplete"}]}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.invalidFunctionCall))
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testWrongFunctionCallFailsWithoutSendingRoundTripRequest() async throws {
        let requests = ResponsesProbeRequestRecorder()
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return .eventStream("""
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"unexpected_tool","call_id":"call_probe","arguments":"{}"}}

            data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed"}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.invalidFunctionCall))
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testUnexpectedArgumentsFailClosedWithoutSendingRoundTripRequest() async throws {
        let requests = ResponsesProbeRequestRecorder()
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return .eventStream("""
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{\\"unexpected\\":true}"}}

            data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed"}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.invalidFunctionCall))
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testMultipleDistinctFunctionCallsFailClosedWithoutSendingRoundTripRequest() async throws {
        let requests = ResponsesProbeRequestRecorder()
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return .eventStream("""
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_one","arguments":"{}"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_two","arguments":"{}"}}

            data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed"}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.invalidFunctionCall))
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testMultipleFunctionCallsInsideOneCompletedOutputFailClosed() async throws {
        let requests = ResponsesProbeRequestRecorder()
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return .eventStream("""
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed","output":[{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_one","arguments":"{}"},{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_two","arguments":"{}"}]}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.invalidFunctionCall))
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testConflictingSnapshotsForOneFunctionCallFailClosed() async throws {
        let requests = ResponsesProbeRequestRecorder()
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return .eventStream("""
            data: {"type":"response.created","response":{"id":"resp_initial"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{}"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{\\"unexpected\\":true}"}}

            data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed"}}

            """)
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.invalidFunctionCall))
        XCTAssertEqual(requests.requests.count, 1)
    }

    func testRepeatedFunctionCallSnapshotMayUseProviderGeneratedCallID() async throws {
        let requests = ResponsesProbeRequestRecorder()
        let responses = ResponsesProbeResponseQueue([
            .eventStream(Self.functionCallSnapshotWithDifferentIDs),
            .eventStream(Self.followupCompletionStream),
        ])
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return responses.next()
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(
            record.outcome,
            .compatible(.init(
                usedServerSentEvents: true,
                receivedFunctionCall: true,
                submittedCorrelatedOutput: true,
                completedAfterFunctionOutput: true
            ))
        )
        XCTAssertEqual(requests.requests.count, 2)
        let followup = try payload(from: requests.bodies[1])
        XCTAssertEqual(
            followup["input"]?.arrayValue?.last?["call_id"],
            .string("call_probe_completed")
        )
    }

    func testFunctionCallAfterToolChoiceNoneFailsClosed() async throws {
        let requests = ResponsesProbeRequestRecorder()
        let responses = ResponsesProbeResponseQueue([
            .eventStream(Self.initialToolCallStream),
            .eventStream("""
            data: {"type":"response.created","response":{"id":"resp_followup"}}

            data: {"type":"response.output_item.done","item":{"type":"function_call","name":"onyx_responses_compatibility_probe","call_id":"call_again","arguments":"{}"}}

            data: {"type":"response.completed","response":{"id":"resp_followup","status":"completed"}}

            """),
        ])
        ResponsesProbeURLProtocol.configure { request in
            requests.record(request)
            return responses.next()
        }
        let probe = makeProbe(credentialStore: InMemoryCredentialStore())

        let record = try await probe.probe(
            connection: makeConnection(),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.invalidFunctionCall))
        XCTAssertEqual(requests.requests.count, 2)
    }

    func testWholeProbeTimeoutIncludesCredentialLookupAndReturnsTypedFailure() async throws {
        let testedAt = Date(timeIntervalSince1970: 5_000)
        let probe = makeProbe(
            credentialStore: DelayedResponsesProbeCredentialStore(),
            timeout: .milliseconds(20),
            now: testedAt
        )
        let clock = ContinuousClock()
        let startedAt = clock.now

        let record = try await probe.probe(
            connection: makeConnection(authMode: .bearer),
            modelID: "fixture-model"
        )

        XCTAssertEqual(record.outcome, .failed(.timedOut))
        XCTAssertEqual(record.expiresAt, testedAt.addingTimeInterval(30))
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
    }

    func testTerminalChatCompletionsEndpointResolvesToSiblingResponsesEndpoint() throws {
        let url = URL(string: "https://provider.example.test/v1/chat/completions")!
        XCTAssertEqual(
            OpenAICompatibleResponsesCompatibilityProbe.responsesURL(from: url)?.absoluteString,
            "https://provider.example.test/v1/responses"
        )
        XCTAssertEqual(
            OpenAICompatibleResponsesCompatibilityProbe.responsesURL(
                from: URL(string: "https://provider.example.test/v1/responses")!
            )?.absoluteString,
            "https://provider.example.test/v1/responses"
        )
    }

    private func makeProbe(
        credentialStore: any CredentialStore,
        timeout: Duration = .seconds(2),
        maximumResponseBytes: Int = 256 * 1_024,
        now: Date = Date(timeIntervalSince1970: 100)
    ) -> OpenAICompatibleResponsesCompatibilityProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesProbeURLProtocol.self]
        return OpenAICompatibleResponsesCompatibilityProbe(
            credentialStore: credentialStore,
            session: URLSession(configuration: configuration),
            limits: .init(
                timeout: timeout,
                timeoutInterval: 2,
                maximumResponseBytes: maximumResponseBytes,
                compatibleCacheLifetime: 3_600,
                incompatibleCacheLifetime: 300,
                transientFailureCacheLifetime: 30
            ),
            now: { now }
        )
    }

    private func makeConnection(
        authMode: ProviderConnectionAuthMode = .none,
        conversationScopeID: String = "scope-fixture"
    ) throws -> ProviderConnectionRecord {
        try ProviderConnectionRecord(
            id: ProviderConnectionID("responses.fixture"),
            displayName: "Responses fixture",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: "fixture-model",
            authMode: authMode,
            conversationScopeID: conversationScopeID
        )
    }

    private func payload(from body: Data?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(body))
    }

    private static let initialToolCallStream = """
    data: {"type":"response.created","response":{"id":"resp_initial"}}

    data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_probe","summary":[]}}

    data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc_probe","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":""}}

    data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_probe","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{}"}}

    data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed","output":[{"type":"reasoning","id":"rs_probe","summary":[]},{"type":"function_call","id":"fc_probe","name":"onyx_responses_compatibility_probe","call_id":"call_probe","arguments":"{}"}]}}

    """

    private static let functionCallSnapshotWithDifferentIDs = """
    data: {"type":"response.created","response":{"id":"resp_initial"}}

    data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_probe_done","name":"onyx_responses_compatibility_probe","call_id":"call_probe_done","arguments":"{}"}}

    data: {"type":"response.completed","response":{"id":"resp_initial","status":"completed","output":[{"type":"function_call","id":"fc_probe_completed","name":"onyx_responses_compatibility_probe","call_id":"call_probe_completed","arguments":"{}"}]}}

    """

    private static let followupCompletionStream = """
    data: {"type":"response.created","response":{"id":"resp_followup"}}

    data: {"type":"response.output_text.done","text":"Compatibility acknowledged."}

    data: {"type":"response.completed","response":{"id":"resp_followup","status":"completed"}}

    """
}

private final class ResponsesProbeRequestRecorder: @unchecked Sendable {
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

private final class ResponsesProbeResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ResponsesProbeURLProtocol.Response]

    init(_ values: [ResponsesProbeURLProtocol.Response]) {
        self.values = values
    }

    func next() -> ResponsesProbeURLProtocol.Response {
        lock.withLock {
            values.isEmpty ? .json(statusCode: 500, body: "{}") : values.removeFirst()
        }
    }
}

private actor DelayedResponsesProbeCredentialStore: CredentialStore {
    func credential(for _: ProviderCredentialKey) async throws -> ProviderBearerCredential? {
        try await Task.sleep(for: .seconds(30))
        return nil
    }

    func setCredential(
        _: ProviderBearerCredential,
        for _: ProviderCredentialKey
    ) async throws {}

    func removeCredential(for _: ProviderCredentialKey) async throws {}
}

private final class ResponsesProbeURLProtocol: URLProtocol {
    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        static func eventStream(
            _ body: String,
            headers: [String: String] = [:]
        ) -> Self {
            var merged = ["Content-Type": "text/event-stream"]
            headers.forEach { merged[$0.key] = $0.value }
            return Self(statusCode: 200, headers: merged, body: Data(body.utf8))
        }

        static func json(statusCode: Int, body: String) -> Self {
            Self(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
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
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result = Self.lock.withLock { Self.handler }?(request)
            ?? .json(statusCode: 500, body: "{}")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.statusCode,
            httpVersion: nil,
            headerFields: result.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
