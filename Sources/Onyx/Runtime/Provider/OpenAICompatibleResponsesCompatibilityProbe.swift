import CryptoKit
import Foundation

/// Credential-free identity for a behavioral Responses compatibility check.
/// The opaque digest includes the normalized endpoint, model, probe revision,
/// and the connection scope that rotates when its credential identity changes.
struct OpenAICompatibleResponsesProbeFingerprint: Codable, Equatable, Hashable, Sendable {
    let value: String

    /// Internal construction supports bounded state validation and corruption
    /// fixtures. Production identities should normally use the scoped
    /// connection/model initializer below.
    init(value: String) {
        self.value = value
    }

    init(connection: ProviderConnectionRecord, modelID: String) {
        let endpoint = OpenAICompatibleResponsesCompatibilityProbe.responsesURL(
            from: connection.baseURL
        )?.absoluteString ?? connection.baseURL.absoluteString
        let material = [
            // Bump this whenever the behavioral request contract changes so a
            // cached failure from an older probe cannot keep a repaired model
            // on the chat lane until that failure expires.
            "onyx-responses-tool-probe-v3",
            endpoint,
            modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            connection.conversationScopeID,
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
        value = digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct OpenAICompatibleResponsesProbeEvidence: Codable, Equatable, Hashable, Sendable {
    let usedServerSentEvents: Bool
    let receivedFunctionCall: Bool
    let submittedCorrelatedOutput: Bool
    let completedAfterFunctionOutput: Bool
}

enum OpenAICompatibleResponsesProbeFailure: Codable, Equatable, Hashable, Sendable {
    enum ConfigurationReason: String, Codable, Equatable, Hashable, Sendable {
        case invalidEndpoint
        case invalidModel
        case insecureEndpoint
        case insecureBearerCredential
        case invalidCredential
    }

    case configuration(ConfigurationReason)
    case credentialUnavailable
    case timedOut
    case networkUnavailable
    case invalidHTTPResponse
    case httpFailure(statusCode: Int)
    case unexpectedContentType
    case responseTooLarge
    case malformedEventStream
    case missingFunctionCall
    case invalidFunctionCall
    case missingCompletion
    case functionOutputRejected

    /// Transient failures get a deliberately short cache lifetime. A protocol
    /// rejection remains cacheable longer, but neither category is permanent.
    var isTransient: Bool {
        switch self {
        case .credentialUnavailable, .timedOut, .networkUnavailable,
             .invalidHTTPResponse:
            true
        case let .httpFailure(statusCode):
            statusCode == 401 || statusCode == 403 || statusCode == 408
                || statusCode == 425 || statusCode == 429 || statusCode >= 500
        case .configuration, .unexpectedContentType, .responseTooLarge,
             .malformedEventStream, .missingFunctionCall, .invalidFunctionCall,
             .missingCompletion, .functionOutputRejected:
            false
        }
    }
}

enum OpenAICompatibleResponsesProbeOutcome: Codable, Equatable, Hashable, Sendable {
    case compatible(OpenAICompatibleResponsesProbeEvidence)
    case failed(OpenAICompatibleResponsesProbeFailure)
}

/// A small persisted-cache value. It deliberately contains no endpoint,
/// model name, server identifier, response body, or credential-derived data.
struct OpenAICompatibleResponsesProbeRecord: Codable, Equatable, Hashable, Sendable {
    /// Keep persisted probe evidence bounded even if a future caller creates a
    /// record by hand. The state store applies the same defaults and may use a
    /// tighter test limit, but this value also protects the in-memory resolver
    /// cache before anything is written to disk.
    static let maximumReusableLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let maximumFutureClockSkew: TimeInterval = 5 * 60

    let fingerprint: OpenAICompatibleResponsesProbeFingerprint
    let testedAt: Date
    let expiresAt: Date
    let outcome: OpenAICompatibleResponsesProbeOutcome

    func isReusable(
        for fingerprint: OpenAICompatibleResponsesProbeFingerprint,
        at date: Date = Date()
    ) -> Bool {
        guard self.fingerprint == fingerprint,
              date.timeIntervalSinceReferenceDate.isFinite,
              testedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > testedAt,
              expiresAt.timeIntervalSince(testedAt) <= Self.maximumReusableLifetime,
              testedAt <= date.addingTimeInterval(Self.maximumFutureClockSkew),
              date < expiresAt else {
            return false
        }
        switch outcome {
        case let .compatible(evidence):
            return evidence.usedServerSentEvents
                && evidence.receivedFunctionCall
                && evidence.submittedCorrelatedOutput
                && evidence.completedAfterFunctionOutput
        case .failed:
            return true
        }
    }
}

protocol OpenAICompatibleResponsesCompatibilityProbing: Sendable {
    func probe(
        connection: ProviderConnectionRecord,
        modelID: String
    ) async throws -> OpenAICompatibleResponsesProbeRecord
}

/// A bounded two-request behavioral check of the OpenAI Responses function
/// protocol. The synthetic tool is forced on the first request; its harmless
/// result is correlated back on the second request and must reach a terminal
/// streamed response. This proves more than a catalog flag without executing
/// a command, reading a file, or including user conversation content.
struct OpenAICompatibleResponsesCompatibilityProbe: OpenAICompatibleResponsesCompatibilityProbing, Sendable {
    struct Limits: Sendable, Equatable {
        let timeout: Duration
        let timeoutInterval: TimeInterval
        let maximumResponseBytes: Int
        let compatibleCacheLifetime: TimeInterval
        let incompatibleCacheLifetime: TimeInterval
        let transientFailureCacheLifetime: TimeInterval

        init(
            timeout: Duration = .seconds(20),
            timeoutInterval: TimeInterval = 20,
            maximumResponseBytes: Int = 256 * 1_024,
            compatibleCacheLifetime: TimeInterval = 24 * 60 * 60,
            incompatibleCacheLifetime: TimeInterval = 60 * 60,
            transientFailureCacheLifetime: TimeInterval = 5 * 60
        ) {
            self.timeout = timeout
            self.timeoutInterval = max(0.1, timeoutInterval)
            self.maximumResponseBytes = max(1_024, maximumResponseBytes)
            self.compatibleCacheLifetime = max(0, compatibleCacheLifetime)
            self.incompatibleCacheLifetime = max(0, incompatibleCacheLifetime)
            self.transientFailureCacheLifetime = max(0, transientFailureCacheLifetime)
        }

        static let `default` = Limits()
    }

    private struct FunctionCall: Sendable, Equatable {
        let callID: String
        let arguments: JSONValue
        let item: JSONValue
    }

    private struct StreamSummary: Sendable {
        var responseID: String?
        var functionCall: FunctionCall?
        var completedOutputItems: [JSONValue] = []
        var sawCreated = false
        var sawCompleted = false
    }

    private enum InternalFailure: Error, Sendable, Equatable {
        case failure(OpenAICompatibleResponsesProbeFailure)
        case timeout
    }

    private static let functionName = "onyx_responses_compatibility_probe"
    private static let maximumIdentifierBytes = 1_024
    private static let maximumRequestBytes = 32 * 1_024

    private let credentialStore: any CredentialStore
    private let session: URLSession
    private let limits: Limits
    private let now: @Sendable () -> Date

    init(
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        session: URLSession? = nil,
        limits: Limits = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.limits = limits
        self.now = now

        let configuration = (session ?? Self.makeDefaultSession()).configuration
        configuration.timeoutIntervalForRequest = limits.timeoutInterval
        configuration.timeoutIntervalForResource = limits.timeoutInterval
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func probe(
        connection: ProviderConnectionRecord,
        modelID: String
    ) async throws -> OpenAICompatibleResponsesProbeRecord {
        let fingerprint = OpenAICompatibleResponsesProbeFingerprint(
            connection: connection,
            modelID: modelID
        )
        let testedAt = now()

        let outcome: OpenAICompatibleResponsesProbeOutcome
        do {
            let evidence = try await withThrowingTaskGroup(
                of: OpenAICompatibleResponsesProbeEvidence.self
            ) { group in
                group.addTask {
                    try await performProbe(connection: connection, modelID: modelID)
                }
                group.addTask {
                    try await Task.sleep(for: limits.timeout)
                    throw InternalFailure.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw InternalFailure.failure(.networkUnavailable)
                }
                return first
            }
            outcome = .compatible(evidence)
        } catch is CancellationError {
            throw CancellationError()
        } catch InternalFailure.timeout {
            outcome = .failed(.timedOut)
        } catch let InternalFailure.failure(failure) {
            outcome = .failed(failure)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Never retain arbitrary URLSession/credential error text: it can
            // contain request URLs, headers, or server-controlled material.
            outcome = .failed(.networkUnavailable)
        }

        let lifetime: TimeInterval
        switch outcome {
        case .compatible:
            lifetime = limits.compatibleCacheLifetime
        case let .failed(failure):
            lifetime = failure.isTransient
                ? limits.transientFailureCacheLifetime
                : limits.incompatibleCacheLifetime
        }
        return OpenAICompatibleResponsesProbeRecord(
            fingerprint: fingerprint,
            testedAt: testedAt,
            expiresAt: testedAt.addingTimeInterval(lifetime),
            outcome: outcome
        )
    }

    private func performProbe(
        connection: ProviderConnectionRecord,
        modelID rawModelID: String
    ) async throws -> OpenAICompatibleResponsesProbeEvidence {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, modelID.utf8.count <= 512 else {
            throw InternalFailure.failure(.configuration(.invalidModel))
        }
        guard let endpoint = Self.responsesURL(from: connection.baseURL) else {
            throw InternalFailure.failure(.configuration(.invalidEndpoint))
        }
        if endpoint.scheme?.lowercased() == "http" {
            guard connection.transportSecurity == .allowInsecureHTTP,
                  let host = endpoint.host,
                  ProviderBaseURLNormalizer.isAllowedInsecureHTTPHost(host) else {
                throw InternalFailure.failure(.configuration(.insecureEndpoint))
            }
            guard connection.authMode == .none else {
                throw InternalFailure.failure(.configuration(.insecureBearerCredential))
            }
        }

        let credential: ProviderBearerCredential?
        do {
            credential = connection.authMode == .bearer
                ? try await credentialStore.credential(for: connection.credentialKey)
                : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InternalFailure.failure(.credentialUnavailable)
        }
        if connection.authMode == .bearer, credential == nil {
            throw InternalFailure.failure(.credentialUnavailable)
        }

        let bearerToken: String?
        do {
            bearerToken = try credential?.withValue { token in
                guard !token.isEmpty,
                      !token.contains(where: { $0.isNewline || $0 == "\0" }) else {
                    throw InternalFailure.failure(.configuration(.invalidCredential))
                }
                return token
            }
        } catch let error as InternalFailure {
            throw error
        } catch {
            throw InternalFailure.failure(.configuration(.invalidCredential))
        }

        let protectedSession = ProviderRedirectProtectedSession(
            wrapping: session,
            transportSecurity: connection.transportSecurity,
            hasBearerCredential: bearerToken != nil
        )
        let initialPayload = Self.initialPayload(modelID: modelID)
        let first = try await performStream(
            endpoint: endpoint,
            payload: initialPayload,
            bearerToken: bearerToken,
            session: protectedSession.session,
            expectsFunctionCall: true
        )
        guard first.responseID != nil,
              let functionCall = first.functionCall else {
            throw InternalFailure.failure(.missingFunctionCall)
        }

        let followup = try await performStream(
            endpoint: endpoint,
            payload: Self.followupPayload(
                modelID: modelID,
                priorOutputItems: first.completedOutputItems,
                callID: functionCall.callID
            ),
            bearerToken: bearerToken,
            session: protectedSession.session,
            expectsFunctionCall: false
        )
        guard followup.sawCompleted, followup.functionCall == nil else {
            throw InternalFailure.failure(.functionOutputRejected)
        }
        return OpenAICompatibleResponsesProbeEvidence(
            usedServerSentEvents: true,
            receivedFunctionCall: true,
            submittedCorrelatedOutput: true,
            completedAfterFunctionOutput: true
        )
    }

    private func performStream(
        endpoint: URL,
        payload: JSONValue,
        bearerToken: String?,
        session: URLSession,
        expectsFunctionCall: Bool
    ) async throws -> StreamSummary {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = limits.timeoutInterval
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body: Data
        do {
            body = try encoder.encode(payload)
        } catch {
            throw InternalFailure.failure(.configuration(.invalidModel))
        }
        guard body.count <= Self.maximumRequestBytes else {
            throw InternalFailure.failure(.configuration(.invalidModel))
        }
        request.httpBody = body

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw InternalFailure.failure(.networkUnavailable)
        }
        guard let http = response as? HTTPURLResponse else {
            throw InternalFailure.failure(.invalidHTTPResponse)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw InternalFailure.failure(.httpFailure(statusCode: http.statusCode))
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "text/event-stream" else {
            throw InternalFailure.failure(.unexpectedContentType)
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length"),
           let count = Int(length), count > limits.maximumResponseBytes {
            throw InternalFailure.failure(.responseTooLarge)
        }

        var parser = OpenAICompatibleSSEParser()
        var receivedBytes = 0
        var summary = StreamSummary()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                receivedBytes += 1
                guard receivedBytes <= limits.maximumResponseBytes else {
                    throw InternalFailure.failure(.responseTooLarge)
                }
                for event in try parser.append(byte) {
                    try Self.consume(event, into: &summary)
                    if summary.sawCompleted {
                        return try Self.validated(summary, expectsFunctionCall: expectsFunctionCall)
                    }
                }
            }
            for event in try parser.finish() {
                try Self.consume(event, into: &summary)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as InternalFailure {
            throw error
        } catch {
            throw InternalFailure.failure(.malformedEventStream)
        }
        return try Self.validated(summary, expectsFunctionCall: expectsFunctionCall)
    }

    private static func consume(
        _ payload: Data,
        into summary: inout StreamSummary
    ) throws {
        if String(data: payload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return
        }
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: payload)
        } catch {
            throw InternalFailure.failure(.malformedEventStream)
        }
        guard let type = root["type"]?.stringValue else {
            throw InternalFailure.failure(.malformedEventStream)
        }
        if type == "error" || type == "response.failed" || type == "response.incomplete" {
            throw InternalFailure.failure(.functionOutputRejected)
        }

        switch type {
        case "response.created":
            guard let responseID = boundedIdentifier(root["response"]?["id"]?.stringValue) else {
                throw InternalFailure.failure(.malformedEventStream)
            }
            summary.sawCreated = true
            summary.responseID = responseID
        case "response.output_item.done":
            guard let item = root["item"], item.objectValue != nil else {
                throw InternalFailure.failure(.malformedEventStream)
            }
            try recordCompletedOutputItem(
                item,
                into: &summary,
                allowProviderSnapshotCallIDChange: false
            )
        case "response.completed":
            guard let response = root["response"], response.objectValue != nil,
                  let responseID = boundedIdentifier(response["id"]?.stringValue),
                  response["status"]?.stringValue == "completed",
                  summary.responseID == nil || summary.responseID == responseID else {
                throw InternalFailure.failure(.malformedEventStream)
            }
            summary.sawCompleted = true
            summary.responseID = responseID
            if let outputValue = response["output"] {
                guard let output = outputValue.arrayValue else {
                    throw InternalFailure.failure(.malformedEventStream)
                }
                // A provider may repeat the one function-call item from an
                // earlier `response.output_item.done` event here, sometimes
                // with a generated call ID. That is the only terminal
                // snapshot for which a call-ID change is tolerated. Two
                // function-call items in the same terminal output represent
                // two calls, even when name and arguments happen to match;
                // do not collapse them into one probe call.
                var terminalFunctionCallCount = 0
                for item in output {
                    guard item.objectValue != nil else {
                        throw InternalFailure.failure(.malformedEventStream)
                    }
                    if item["type"]?.stringValue == "function_call" {
                        terminalFunctionCallCount += 1
                        guard terminalFunctionCallCount == 1 else {
                            throw InternalFailure.failure(.invalidFunctionCall)
                        }
                    }
                    try recordCompletedOutputItem(
                        item,
                        into: &summary,
                        allowProviderSnapshotCallIDChange: true
                    )
                }
            }
        default:
            // Responses adds lifecycle events over time. Unknown typed events
            // are safe to ignore within the overall byte and time bounds.
            break
        }
    }

    private static func validated(
        _ summary: StreamSummary,
        expectsFunctionCall: Bool
    ) throws -> StreamSummary {
        guard summary.sawCreated, summary.responseID != nil else {
            throw InternalFailure.failure(.malformedEventStream)
        }
        guard summary.sawCompleted else {
            throw InternalFailure.failure(.missingCompletion)
        }
        if expectsFunctionCall, summary.functionCall == nil {
            throw InternalFailure.failure(.missingFunctionCall)
        }
        if !expectsFunctionCall, summary.functionCall != nil {
            throw InternalFailure.failure(.invalidFunctionCall)
        }
        return summary
    }

    private static func functionCall(from value: JSONValue?) throws -> FunctionCall? {
        guard let value, value["type"]?.stringValue == "function_call" else { return nil }
        guard value["status"] == nil || value["status"]?.stringValue == "completed",
              value["name"]?.stringValue == functionName,
              let callID = boundedIdentifier(value["call_id"]?.stringValue),
              let arguments = value["arguments"]?.stringValue,
              arguments.utf8.count <= 1_024,
              let argumentData = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: argumentData),
              decoded == .object([:]) else {
            throw InternalFailure.failure(.invalidFunctionCall)
        }
        return FunctionCall(callID: callID, arguments: decoded, item: value)
    }

    private static func recordCompletedOutputItem(
        _ item: JSONValue,
        into summary: inout StreamSummary,
        allowProviderSnapshotCallIDChange: Bool
    ) throws {
        if let call = try functionCall(from: item) {
            if let existing = summary.functionCall {
                // vLLM's Responses adapter can assign one call ID to the
                // `response.output_item.done` snapshot and another generated
                // ID to the same function item repeated in
                // `response.completed.output`.  The function name and
                // validated arguments are the stable identity here; prefer
                // the latest complete snapshot because its call ID is the
                // one the provider expects in the correlated follow-up.
                guard (allowProviderSnapshotCallIDChange || existing.callID == call.callID),
                      existing.arguments == call.arguments,
                      existing.item["name"] == call.item["name"] else {
                    throw InternalFailure.failure(.invalidFunctionCall)
                }

                // `response.output_item.done` and `response.completed.output`
                // commonly carry the same call. Keep one item, preferring the
                // latest complete snapshot so the replay matches app-server.
                if let index = summary.completedOutputItems.firstIndex(where: {
                    $0["type"]?.stringValue == "function_call"
                        && $0["name"] == existing.item["name"]
                        && $0["arguments"] == existing.item["arguments"]
                }) {
                    summary.completedOutputItems[index] = item
                }
                summary.functionCall = call
                return
            }
            summary.functionCall = call
            summary.completedOutputItems.append(item)
            return
        }

        // A provider may repeat a completed lifecycle snapshot. Preserve the
        // original output order while avoiding duplicate replay items.
        if !summary.completedOutputItems.contains(item) {
            summary.completedOutputItems.append(item)
        }
    }

    private static func boundedIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.utf8.count <= maximumIdentifierBytes else { return nil }
        return value
    }

    private static func initialPayload(modelID: String) -> JSONValue {
        var payload: [String: JSONValue] = [
            "model": .string(modelID),
            "input": .array(initialInputItems),
            "tools": .array([functionTool]),
            "tool_choice": .object([
                "type": .string("function"),
                "name": .string(functionName),
            ]),
            "stream": .bool(true),
            "max_output_tokens": .integer(64),
        ]
        addProbeReasoningMode(to: &payload, modelID: modelID)
        return .object(payload)
    }

    private static func followupPayload(
        modelID: String,
        priorOutputItems: [JSONValue],
        callID: String
    ) -> JSONValue {
        var input = initialInputItems
        input.append(contentsOf: priorOutputItems)
        input.append(.object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string(#"{"ok":true}"#),
        ]))
        var payload: [String: JSONValue] = [
            "model": .string(modelID),
            "input": .array(input),
            "tools": .array([functionTool]),
            "tool_choice": .string("none"),
            "stream": .bool(true),
            "max_output_tokens": .integer(64),
        ]
        addProbeReasoningMode(to: &payload, modelID: modelID)
        return .object(payload)
    }

    /// The probe intentionally has a very small output allowance. Qwen 3.8's
    /// vLLM Responses adapter otherwise spends that allowance on hidden
    /// reasoning and can emit a complete forced function call inside a
    /// `response.completed` event whose embedded status is still `incomplete`.
    /// That does not give us the clean two-request completion evidence needed
    /// to enable local tools. The exact Qwen profile has independently verified
    /// support for the standard `none` effort, so probe it in direct mode while
    /// leaving unknown model families on the generic Responses request shape.
    private static func addProbeReasoningMode(
        to payload: inout [String: JSONValue],
        modelID: String
    ) {
        guard KnownOpenAICompatibleModelProfile.profile(for: modelID) == .qwen38 else {
            return
        }
        payload["reasoning"] = .object(["effort": .string("none")])
    }

    private static var initialInputItems: [JSONValue] {
        [.object([
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string("Call the supplied compatibility probe exactly once."),
            ])]),
        ])]
    }

    private static var functionTool: JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(functionName),
            "description": .string("Returns a fixed, side-effect-free compatibility acknowledgement."),
            "parameters": .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
                "required": .array([]),
            ]),
            "strict": .bool(true),
        ])
    }

    static func responsesURL(from baseURL: URL) -> URL? {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        }
        if !path.hasSuffix("/responses") {
            path = (path.isEmpty || path == "/") ? "/responses" : path + "/responses"
        }
        components.percentEncodedPath = path
        return components.url
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}
