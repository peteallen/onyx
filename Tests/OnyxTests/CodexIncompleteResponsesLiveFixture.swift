import Foundation
import Network

/// Literal-loopback Responses fixture for the opt-in app-server integration
/// proof. It accepts one or more ordinary Content-Length requests and returns
/// a standards-shaped partial assistant message followed by
/// `response.incomplete(max_output_tokens)`.
final class CodexIncompleteResponsesLiveFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.onyx.tests.codex-incomplete-responses")
    private let lock = NSLock()
    private var requestBodiesStorage: [Data] = []

    private(set) var port: Int = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> CodexIncompleteResponsesLiveFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let fixture = CodexIncompleteResponsesLiveFixture(listener: listener)
        listener.newConnectionHandler = { [weak fixture] connection in
            fixture?.accept(connection)
        }

        let resolvedPort = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
                let resolver = CodexIncompleteListenerResolver(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            resolver.fail(CodexIncompleteFixtureError.listenerDidNotPublishPort)
                            return
                        }
                        resolver.succeed(port)
                    case let .failed(error):
                        resolver.fail(error)
                    case .cancelled:
                        resolver.fail(CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: fixture.queue)
            }
        } onCancel: {
            listener.cancel()
        }
        fixture.port = Int(resolvedPort.rawValue)
        return fixture
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    var requestBodies: [Data] {
        lock.withLock { requestBodiesStorage }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLiteralIPv4Loopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receiveRequest(from: connection, buffer: Data())
    }

    private func receiveRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let request = Self.completeRequest(in: accumulated) {
                record(request.body)
                sendIncompleteResponse(over: connection)
                return
            }
            guard !isComplete, accumulated.count <= 8 * 1_024 * 1_024 else {
                connection.cancel()
                return
            }
            receiveRequest(from: connection, buffer: accumulated)
        }
    }

    private func record(_ body: Data) {
        lock.withLock { requestBodiesStorage.append(body) }
    }

    private func sendIncompleteResponse(over connection: NWConnection) {
        let body = Data(Self.incompleteEventStream.utf8)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + body,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func completeRequest(in data: Data) -> (body: Data, consumed: Int)? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<boundary.lowerBound], encoding: .utf8)
        else { return nil }
        var contentLength: Int?
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            contentLength = Int(value)
            break
        }
        guard let contentLength, contentLength >= 0 else { return nil }
        let bodyStart = boundary.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return (
            body: Data(data[bodyStart ..< bodyStart + contentLength]),
            consumed: bodyStart + contentLength
        )
    }

    private static func isLiteralIPv4Loopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        return host.debugDescription == "127.0.0.1"
            || host.debugDescription.hasPrefix("127.")
    }

    static let partialText = "ONYX_PARTIAL_BEFORE_OUTPUT_LIMIT"

    private static let incompleteEventStream = """
    data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_onyx_incomplete","object":"response","created_at":1787500000,"status":"in_progress","error":null,"incomplete_details":null,"instructions":null,"max_output_tokens":8,"model":"fixture-incomplete-model","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":false,"temperature":null,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":null,"truncation":"disabled","usage":null,"user":null,"metadata":{}}}

    data: {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"msg_onyx_partial","type":"message","status":"in_progress","role":"assistant","content":[]}}

    data: {"type":"response.content_part.added","sequence_number":2,"item_id":"msg_onyx_partial","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}

    data: {"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_onyx_partial","output_index":0,"content_index":0,"delta":"ONYX_PARTIAL_BEFORE_OUTPUT_LIMIT","logprobs":[]}

    data: {"type":"response.output_text.done","sequence_number":4,"item_id":"msg_onyx_partial","output_index":0,"content_index":0,"text":"ONYX_PARTIAL_BEFORE_OUTPUT_LIMIT","logprobs":[]}

    data: {"type":"response.content_part.done","sequence_number":5,"item_id":"msg_onyx_partial","output_index":0,"content_index":0,"part":{"type":"output_text","text":"ONYX_PARTIAL_BEFORE_OUTPUT_LIMIT","annotations":[]}}

    data: {"type":"response.output_item.done","sequence_number":6,"output_index":0,"item":{"id":"msg_onyx_partial","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"ONYX_PARTIAL_BEFORE_OUTPUT_LIMIT","annotations":[]}]}}

    data: {"type":"response.incomplete","sequence_number":7,"response":{"id":"resp_onyx_incomplete","object":"response","created_at":1787500000,"status":"incomplete","error":null,"incomplete_details":{"reason":"max_output_tokens"},"instructions":null,"max_output_tokens":8,"model":"fixture-incomplete-model","output":[{"id":"msg_onyx_partial","type":"message","status":"incomplete","role":"assistant","content":[{"type":"output_text","text":"ONYX_PARTIAL_BEFORE_OUTPUT_LIMIT","annotations":[]}]}],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":false,"temperature":null,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":null,"truncation":"disabled","usage":{"input_tokens":12,"input_tokens_details":{"cached_tokens":0},"output_tokens":8,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":20},"user":null,"metadata":{}}}

    data: [DONE]

    """
}

enum CodexIncompleteFixtureError: Error {
    case listenerDidNotPublishPort
}

private final class CodexIncompleteListenerResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint.Port, any Error>?

    init(_ continuation: CheckedContinuation<NWEndpoint.Port, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ port: NWEndpoint.Port) { resolve(.success(port)) }
    func fail(_ error: any Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<NWEndpoint.Port, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<NWEndpoint.Port, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
