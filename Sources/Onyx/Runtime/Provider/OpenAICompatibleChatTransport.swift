import Foundation

/// The stable subset of token accounting reported by OpenAI-compatible APIs.
/// Providers may omit any individual count, especially on streamed requests.
struct OpenAICompatibleChatUsage: Sendable, Equatable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

struct OpenAICompatibleChatResponse: Sendable, Equatable {
    struct Choice: Sendable, Equatable {
        let index: Int
        let role: String?
        let content: String?
        /// Reasoning is progress evidence, not answer text. Keep only its
        /// presence so hidden provider thinking cannot leak through this
        /// transport abstraction or be retained by the runtime.
        let hasReasoning: Bool
        let toolCalls: [OpenAICompatibleChatToolCall]
        let finishReason: String?
    }

    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: OpenAICompatibleChatUsage?
}

/// One server-sent chat-completion chunk. Empty strings and an empty choices
/// array are intentionally preserved: vLLM sends both an initial empty role
/// chunk and a later usage-only chunk.
struct OpenAICompatibleChatStreamChunk: Sendable, Equatable {
    struct Choice: Sendable, Equatable {
        struct Delta: Sendable, Equatable {
            let role: String?
            let content: String?
            let hasReasoning: Bool
            /// Raw fragments from this SSE chunk. Function arguments are
            /// commonly split at arbitrary byte-safe string boundaries.
            let toolCalls: [OpenAICompatibleChatToolCallDelta]
        }

        let index: Int
        let delta: Delta
        /// Complete snapshots accumulated for this choice through the current
        /// chunk. Callers should wait for a terminal `tool_calls` finish reason
        /// before executing them.
        let toolCalls: [OpenAICompatibleChatToolCall]
        let finishReason: String?
    }

    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: OpenAICompatibleChatUsage?
}

/// A single streamed fragment for one function call. Identity and function
/// fields are optional because providers generally send them only on the first
/// chunk; the numeric index is the stable accumulation key.
struct OpenAICompatibleChatToolCallDelta: Sendable, Equatable {
    let index: Int
    let id: String?
    let name: String?
    let arguments: String?
}

/// Accumulates fragmented function calls independently for every response
/// choice and tool-call index. It never parses the arguments string as JSON:
/// models can produce invalid arguments and the later execution boundary must
/// validate them against the advertised schema.
struct OpenAICompatibleChatToolCallAccumulator: Sendable {
    private struct PartialCall: Sendable {
        var id: String?
        var name: String?
        var arguments = ""
        var sawArguments = false
    }

    private var partialCalls: [Int: [Int: PartialCall]] = [:]

    mutating func accumulate(
        _ chunk: OpenAICompatibleChatStreamChunk
    ) throws -> OpenAICompatibleChatStreamChunk {
        var choices: [OpenAICompatibleChatStreamChunk.Choice] = []
        choices.reserveCapacity(chunk.choices.count)
        for choice in chunk.choices {
            var byIndex = partialCalls[choice.index] ?? [:]
            for delta in choice.delta.toolCalls {
                var partial = byIndex[delta.index] ?? PartialCall()
                try Self.merge(delta.id, into: &partial.id)
                try Self.merge(delta.name, into: &partial.name)
                if let arguments = delta.arguments {
                    partial.arguments += arguments
                    partial.sawArguments = true
                }
                byIndex[delta.index] = partial
            }
            partialCalls[choice.index] = byIndex
            choices.append(
                .init(
                    index: choice.index,
                    delta: choice.delta,
                    toolCalls: try Self.completedCalls(from: byIndex, requireComplete: false),
                    finishReason: choice.finishReason
                )
            )
        }
        return OpenAICompatibleChatStreamChunk(
            id: chunk.id,
            model: chunk.model,
            choices: choices,
            usage: chunk.usage
        )
    }

    /// Validates that every started call has the identity, name, and argument
    /// string required to continue the Chat Completions tool loop.
    func finalize() throws -> [Int: [OpenAICompatibleChatToolCall]] {
        var result: [Int: [OpenAICompatibleChatToolCall]] = [:]
        result.reserveCapacity(partialCalls.count)
        for (choiceIndex, calls) in partialCalls {
            result[choiceIndex] = try Self.completedCalls(
                from: calls,
                requireComplete: true
            )
        }
        return result
    }

    private static func merge(
        _ fragment: String?,
        into accumulated: inout String?
    ) throws {
        guard let fragment else { return }
        if let accumulated, accumulated != fragment {
            throw OpenAICompatibleChatTransportError.malformedStreamEvent
        }
        accumulated = fragment
    }

    private static func completedCalls(
        from partials: [Int: PartialCall],
        requireComplete: Bool
    ) throws -> [OpenAICompatibleChatToolCall] {
        try partials.keys.sorted().compactMap { index in
            guard let partial = partials[index],
                  let id = partial.id,
                  let name = partial.name,
                  partial.sawArguments else {
                if requireComplete {
                    throw OpenAICompatibleChatTransportError.malformedStreamEvent
                }
                return nil
            }
            return OpenAICompatibleChatToolCall(
                id: id,
                name: name,
                arguments: partial.arguments
            )
        }
    }
}

enum OpenAICompatibleChatStreamEvent: Sendable, Equatable {
    case chunk(OpenAICompatibleChatStreamChunk)
    /// Emitted only after the server's `data: [DONE]` sentinel.
    case completed
}

enum OpenAICompatibleChatTransportError: LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case insecureEndpoint
    case insecureBearerToken
    case invalidBearerToken
    case requestModeMismatch(expectedStreaming: Bool)
    case invalidHTTPResponse
    case httpFailure(statusCode: Int, message: String?)
    case providerFailure(message: String, type: String?, code: String?)
    case malformedResponse
    case malformedStreamEvent
    case streamEndedBeforeDone
    case networkFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The provider endpoint is not a valid HTTP(S) base URL."
        case .insecureEndpoint:
            "Clear-text HTTP is allowed only after acknowledgement and only for a literal loopback, private-network, or link-local IP address. Use HTTPS for hostnames and public IPs."
        case .insecureBearerToken:
            "Bearer credentials cannot be sent over clear-text HTTP. Use HTTPS or choose a provider without authentication."
        case .invalidBearerToken:
            "The provider bearer token contains characters that are not valid in an HTTP header."
        case let .requestModeMismatch(expectedStreaming):
            expectedStreaming
                ? "The streaming transport requires a request with stream enabled."
                : "The non-streaming transport requires a request with stream disabled."
        case .invalidHTTPResponse:
            "The provider returned a response that was not HTTP."
        case let .httpFailure(statusCode, message):
            if let message, !message.isEmpty {
                "The provider request failed with HTTP \(statusCode): \(message)"
            } else {
                "The provider request failed with HTTP \(statusCode)."
            }
        case let .providerFailure(message, type, code):
            if type == nil, code == nil {
                message
            } else {
                "\(message) (\([type.map { "type=\($0)" }, code.map { "code=\($0)" }].compactMap { $0 }.joined(separator: ", ")))"
            }
        case .malformedResponse:
            "The provider returned malformed chat-completion JSON."
        case .malformedStreamEvent:
            "The provider returned a malformed server-sent event."
        case .streamEndedBeforeDone:
            "The provider stream ended before its completion sentinel."
        case let .networkFailure(message):
            "The provider request failed: \(message)"
        }
    }
}

/// URLSession transport for the OpenAI-compatible `/chat/completions` wire
/// protocol. It has no conversation persistence or runtime semantics; those
/// remain app-owned integration concerns.
struct OpenAICompatibleChatTransport: Sendable {
    private let chatCompletionsURL: URL
    private let bearerToken: String?
    private let protectedSession: ProviderRedirectProtectedSession

    /// - Parameters:
    ///   - endpoint: Provider base URL (for example `https://host/v1`) or the
    ///     full `/chat/completions` URL.
    ///   - bearerToken: Optional so trusted local vLLM servers can be used
    ///     without inventing a credential.
    ///   - allowsInsecureHTTP: An explicit user acknowledgement for clear-text
    ///     HTTP. It is required even for local IPs, and is accepted only for a
    ///     literal loopback/private/link-local IP with no bearer token.
    ///   - session: Injectable to support deterministic URLProtocol fixtures.
    init(
        endpoint: URL,
        bearerToken: String? = nil,
        allowsInsecureHTTP: Bool = false,
        session: URLSession? = nil
    ) throws {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw OpenAICompatibleChatTransportError.invalidEndpoint
        }
        let token = bearerToken.flatMap { $0.isEmpty ? nil : $0 }
        if let token, token.contains(where: { $0.isNewline || $0 == "\0" }) {
            throw OpenAICompatibleChatTransportError.invalidBearerToken
        }

        if scheme == "http" {
            guard ProviderBaseURLNormalizer.isAllowedInsecureHTTPHost(host),
                  allowsInsecureHTTP
            else {
                throw OpenAICompatibleChatTransportError.insecureEndpoint
            }
            guard token == nil else {
                throw OpenAICompatibleChatTransportError.insecureBearerToken
            }
        }

        self.chatCompletionsURL = Self.resolveChatCompletionsURL(from: endpoint)
        self.bearerToken = token
        self.protectedSession = ProviderRedirectProtectedSession(
            wrapping: session ?? Self.makeDefaultSession(),
            transportSecurity: allowsInsecureHTTP ? .allowInsecureHTTP : .requireTLS,
            hasBearerCredential: token != nil
        )
    }

    func complete(
        _ chatRequest: OpenAICompatibleChatRequest
    ) async throws -> OpenAICompatibleChatResponse {
        guard !chatRequest.stream else {
            throw OpenAICompatibleChatTransportError.requestModeMismatch(
                expectedStreaming: false
            )
        }

        let request = try makeURLRequest(for: chatRequest)
        do {
            let (data, response) = try await protectedSession.session.data(for: request)
            try Task.checkCancellation()
            let http = try validatedHTTPResponse(response)
            guard (200 ..< 300).contains(http.statusCode) else {
                throw httpError(statusCode: http.statusCode, data: data)
            }
            return try Self.decodeResponse(data, redacting: bearerToken)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAICompatibleChatTransportError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OpenAICompatibleChatTransportError.networkFailure(
                Self.sanitize(error.localizedDescription, secret: bearerToken)
            )
        }
    }

    func stream(
        _ chatRequest: OpenAICompatibleChatRequest
    ) -> AsyncThrowingStream<OpenAICompatibleChatStreamEvent, any Error> {
        guard chatRequest.stream else {
            return Self.failedStream(
                OpenAICompatibleChatTransportError.requestModeMismatch(
                    expectedStreaming: true
                )
            )
        }

        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(for: chatRequest)
        } catch {
            return Self.failedStream(error)
        }

        let session = protectedSession.session
        let secret = bearerToken
        let pair = AsyncThrowingStream.makeStream(
            of: OpenAICompatibleChatStreamEvent.self,
            throwing: (any Error).self
        )
        let worker = Task.detached {
            do {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                let http = try Self.validatedHTTPResponse(response)
                guard (200 ..< 300).contains(http.statusCode) else {
                    let data = try await Self.collect(bytes: bytes)
                    throw Self.httpError(
                        statusCode: http.statusCode,
                        data: data,
                        redacting: secret
                    )
                }

                var parser = OpenAICompatibleSSEParser()
                var toolCallAccumulator = OpenAICompatibleChatToolCallAccumulator()
                var sawDone = false
                streamLoop: for try await byte in bytes {
                    try Task.checkCancellation()
                    for payload in try parser.append(byte) {
                        switch try Self.decodeStreamPayload(payload, redacting: secret) {
                        case let .chunk(chunk):
                            pair.continuation.yield(
                                .chunk(try toolCallAccumulator.accumulate(chunk))
                            )
                        case .done:
                            _ = try toolCallAccumulator.finalize()
                            sawDone = true
                            pair.continuation.yield(.completed)
                            break streamLoop
                        }
                    }
                }

                if !sawDone {
                    for payload in try parser.finish() {
                        switch try Self.decodeStreamPayload(payload, redacting: secret) {
                        case let .chunk(chunk):
                            pair.continuation.yield(
                                .chunk(try toolCallAccumulator.accumulate(chunk))
                            )
                        case .done:
                            _ = try toolCallAccumulator.finalize()
                            sawDone = true
                            pair.continuation.yield(.completed)
                        }
                    }
                }
                guard sawDone else {
                    throw OpenAICompatibleChatTransportError.streamEndedBeforeDone
                }
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish(throwing: CancellationError())
            } catch let error as OpenAICompatibleChatTransportError {
                pair.continuation.finish(throwing: error)
            } catch {
                if Task.isCancelled {
                    pair.continuation.finish(throwing: CancellationError())
                } else {
                    pair.continuation.finish(
                        throwing: OpenAICompatibleChatTransportError.networkFailure(
                            Self.sanitize(error.localizedDescription, secret: secret)
                        )
                    )
                }
            }
        }
        pair.continuation.onTermination = { @Sendable _ in
            worker.cancel()
        }
        return pair.stream
    }

    private func makeURLRequest(
        for chatRequest: OpenAICompatibleChatRequest
    ) throws -> URLRequest {
        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if chatRequest.stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try chatRequest.encodedData()
        return request
    }

    private func validatedHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        try Self.validatedHTTPResponse(response)
    }

    private func httpError(statusCode: Int, data: Data) -> OpenAICompatibleChatTransportError {
        Self.httpError(statusCode: statusCode, data: data, redacting: bearerToken)
    }

    private static func validatedHTTPResponse(
        _ response: URLResponse
    ) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw OpenAICompatibleChatTransportError.invalidHTTPResponse
        }
        return response
    }

    private static func decodeResponse(
        _ data: Data,
        redacting secret: String?
    ) throws -> OpenAICompatibleChatResponse {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw OpenAICompatibleChatTransportError.malformedResponse
        }
        if let providerError = providerError(from: root, redacting: secret) {
            throw providerError
        }
        guard let choices = root["choices"]?.arrayValue else {
            throw OpenAICompatibleChatTransportError.malformedResponse
        }
        let decodedChoices = try choices.map { value in
            guard let index = value["index"]?.intValue,
                  let message = value["message"]?.objectValue else {
                throw OpenAICompatibleChatTransportError.malformedResponse
            }
            return OpenAICompatibleChatResponse.Choice(
                index: index,
                role: message["role"]?.stringValue,
                content: Self.optionalString(message["content"]),
                hasReasoning: Self.containsReasoning(in: message),
                toolCalls: try Self.completeToolCalls(
                    from: message["tool_calls"],
                    malformedAs: .malformedResponse
                ),
                finishReason: Self.optionalString(value["finish_reason"])
            )
        }
        return OpenAICompatibleChatResponse(
            id: root["id"]?.stringValue,
            model: root["model"]?.stringValue,
            choices: decodedChoices,
            usage: usage(from: root["usage"])
        )
    }

    private enum DecodedStreamPayload {
        case chunk(OpenAICompatibleChatStreamChunk)
        case done
    }

    private static func decodeStreamPayload(
        _ payload: Data,
        redacting secret: String?
    ) throws -> DecodedStreamPayload {
        guard let string = String(data: payload, encoding: .utf8) else {
            throw OpenAICompatibleChatTransportError.malformedStreamEvent
        }
        if string.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return .done
        }

        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: payload)
        } catch {
            throw OpenAICompatibleChatTransportError.malformedStreamEvent
        }
        if let providerError = providerError(from: root, redacting: secret) {
            throw providerError
        }
        guard let choices = root["choices"]?.arrayValue else {
            throw OpenAICompatibleChatTransportError.malformedStreamEvent
        }
        let decodedChoices = try choices.map { value in
            guard let index = value["index"]?.intValue,
                  let delta = value["delta"]?.objectValue else {
                throw OpenAICompatibleChatTransportError.malformedStreamEvent
            }
            return OpenAICompatibleChatStreamChunk.Choice(
                index: index,
                delta: .init(
                    role: delta["role"]?.stringValue,
                    content: optionalString(delta["content"]),
                    hasReasoning: containsReasoning(in: delta),
                    toolCalls: try toolCallDeltas(from: delta["tool_calls"])
                ),
                toolCalls: [],
                finishReason: optionalString(value["finish_reason"])
            )
        }
        return .chunk(
            OpenAICompatibleChatStreamChunk(
                id: root["id"]?.stringValue,
                model: root["model"]?.stringValue,
                choices: decodedChoices,
                usage: usage(from: root["usage"])
            )
        )
    }

    private static func usage(from value: JSONValue?) -> OpenAICompatibleChatUsage? {
        guard let value, value.objectValue != nil else { return nil }
        return OpenAICompatibleChatUsage(
            promptTokens: value["prompt_tokens"]?.intValue,
            completionTokens: value["completion_tokens"]?.intValue,
            totalTokens: value["total_tokens"]?.intValue
        )
    }

    private static func completeToolCalls(
        from value: JSONValue?,
        malformedAs error: OpenAICompatibleChatTransportError
    ) throws -> [OpenAICompatibleChatToolCall] {
        guard let value else { return [] }
        if value == .null { return [] }
        guard let values = value.arrayValue else { throw error }
        return try values.map { call in
            guard let object = call.objectValue,
                  isFunctionType(object["type"]),
                  let id = strictString(object["id"]),
                  let function = object["function"]?.objectValue,
                  let name = strictString(function["name"]),
                  let arguments = strictString(function["arguments"]) else {
                throw error
            }
            return OpenAICompatibleChatToolCall(
                id: id,
                name: name,
                arguments: arguments
            )
        }
    }

    private static func toolCallDeltas(
        from value: JSONValue?
    ) throws -> [OpenAICompatibleChatToolCallDelta] {
        guard let value else { return [] }
        if value == .null { return [] }
        guard let values = value.arrayValue else {
            throw OpenAICompatibleChatTransportError.malformedStreamEvent
        }
        return try values.map { call in
            guard let object = call.objectValue,
                  let index = object["index"]?.intValue,
                  isFunctionType(object["type"]) else {
                throw OpenAICompatibleChatTransportError.malformedStreamEvent
            }
            let function: [String: JSONValue]
            if let value = object["function"] {
                guard let object = value.objectValue else {
                    throw OpenAICompatibleChatTransportError.malformedStreamEvent
                }
                function = object
            } else {
                function = [:]
            }
            return OpenAICompatibleChatToolCallDelta(
                index: index,
                id: try optionalStrictString(
                    object["id"],
                    malformedAs: .malformedStreamEvent
                ),
                name: try optionalStrictString(
                    function["name"],
                    malformedAs: .malformedStreamEvent
                ),
                arguments: try optionalStrictString(
                    function["arguments"],
                    malformedAs: .malformedStreamEvent
                )
            )
        }
    }

    private static func isFunctionType(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        return strictString(value) == "function"
    }

    private static func strictString(_ value: JSONValue?) -> String? {
        guard case let .string(value)? = value else { return nil }
        return value
    }

    private static func optionalStrictString(
        _ value: JSONValue?,
        malformedAs error: OpenAICompatibleChatTransportError
    ) throws -> String? {
        guard let value else { return nil }
        if value == .null { return nil }
        guard let value = strictString(value) else { throw error }
        return value
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return value.stringValue
    }

    private static func containsReasoning(in object: [String: JSONValue]) -> Bool {
        for key in ["reasoning_content", "reasoning", "reasoning_details", "analysis"] {
            guard let value = object[key] else { continue }
            switch value {
            case let .string(text):
                if !text.isEmpty { return true }
            case let .array(values):
                if !values.isEmpty { return true }
            case let .object(fields):
                if !fields.isEmpty { return true }
            case let .bool(value):
                if value { return true }
            case .integer, .number, .null:
                continue
            }
        }
        return false
    }

    private static func providerError(
        from root: JSONValue,
        redacting secret: String?
    ) -> OpenAICompatibleChatTransportError? {
        guard let error = root["error"], error.objectValue != nil else { return nil }
        let rawMessage = error["message"]?.stringValue ?? "The provider reported an error."
        return .providerFailure(
            message: sanitize(rawMessage, secret: secret),
            type: error["type"]?.stringValue.map { sanitize($0, secret: secret) },
            code: error["code"]?.stringValue.map { sanitize($0, secret: secret) }
        )
    }

    private static func httpError(
        statusCode: Int,
        data: Data,
        redacting secret: String?
    ) -> OpenAICompatibleChatTransportError {
        if let root = try? JSONDecoder().decode(JSONValue.self, from: data),
           case let .providerFailure(message, _, _) = providerError(
               from: root,
               redacting: secret
           ) {
            return .httpFailure(statusCode: statusCode, message: message)
        }
        return .httpFailure(statusCode: statusCode, message: nil)
    }

    private static func sanitize(_ value: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return value }
        return value.replacingOccurrences(of: secret, with: "[REDACTED]")
    }

    private static func collect(
        bytes: URLSession.AsyncBytes,
        maximumBytes: Int = 1_048_576
    ) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { break }
            data.append(byte)
        }
        return data
    }

    private static func failedStream(
        _ error: any Error
    ) -> AsyncThrowingStream<OpenAICompatibleChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    private static func resolveChatCompletionsURL(from endpoint: URL) -> URL {
        let components = endpoint.path.split(separator: "/")
        if components.suffix(2).map(String.init) == ["chat", "completions"] {
            return endpoint
        }
        return endpoint
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("completions", isDirectory: false)
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }
}

/// Byte-oriented SSE framing keeps a partial Unicode scalar buffered until a
/// complete event is available, rather than decoding arbitrary URLSession
/// chunks as independently valid UTF-8 strings.
struct OpenAICompatibleSSEParser: Sendable {
    private static let maximumLineBytes = 8 * 1_024 * 1_024
    private static let maximumEventBytes = 8 * 1_024 * 1_024

    private var currentLine = Data()
    private var dataLines: [Data] = []
    private var eventBytes = 0

    mutating func append(_ byte: UInt8) throws -> [Data] {
        if byte == 0x0A {
            return try consumeCurrentLine()
        }
        guard currentLine.count < Self.maximumLineBytes else {
            throw OpenAICompatibleChatTransportError.malformedStreamEvent
        }
        currentLine.append(byte)
        return []
    }

    mutating func append(_ data: Data) throws -> [Data] {
        var events: [Data] = []
        for byte in data {
            events.append(contentsOf: try append(byte))
        }
        return events
    }

    mutating func finish() throws -> [Data] {
        var events: [Data] = []
        if !currentLine.isEmpty {
            events.append(contentsOf: try consumeCurrentLine())
        }
        if let pending = takeEvent() {
            events.append(pending)
        }
        return events
    }

    private mutating func consumeCurrentLine() throws -> [Data] {
        if currentLine.last == 0x0D {
            currentLine.removeLast()
        }
        defer { currentLine.removeAll(keepingCapacity: true) }

        if currentLine.isEmpty {
            return takeEvent().map { [$0] } ?? []
        }
        if currentLine.first == 0x3A { return [] } // SSE comment/heartbeat.

        let separator = currentLine.firstIndex(of: 0x3A) ?? currentLine.endIndex
        guard currentLine[..<separator].elementsEqual(Data("data".utf8)) else {
            return [] // Ignore `event`, `id`, `retry`, and future fields.
        }
        var valueStart = separator
        if valueStart < currentLine.endIndex {
            valueStart = currentLine.index(after: valueStart)
            if valueStart < currentLine.endIndex, currentLine[valueStart] == 0x20 {
                valueStart = currentLine.index(after: valueStart)
            }
        }
        let value = Data(currentLine[valueStart...])
        eventBytes += value.count
        guard eventBytes <= Self.maximumEventBytes else {
            throw OpenAICompatibleChatTransportError.malformedStreamEvent
        }
        dataLines.append(value)
        return []
    }

    private mutating func takeEvent() -> Data? {
        guard !dataLines.isEmpty else { return nil }
        var event = Data()
        for (index, line) in dataLines.enumerated() {
            if index > 0 { event.append(0x0A) }
            event.append(line)
        }
        dataLines.removeAll(keepingCapacity: true)
        eventBytes = 0
        return event
    }
}
