import Foundation
import Network

/// Small raw TCP client used by proxy tests. URLSession intentionally hides
/// the connection-close boundary that cancellation and bounded-response
/// tests need to observe, so these fixtures speak just enough HTTP/1.1 to
/// capture the proxy's exact bytes.
final class RawLoopbackConnection: @unchecked Sendable {
    private let connection: NWConnection

    init(port: Int) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ProxyTestError.malformedResponse
        }
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: endpointPort,
            using: .tcp
        )
    }

    func start() async throws {
        let resolver = ConnectionStateResolver()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                resolver.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resolver.succeed()
                    case let .failed(error):
                        resolver.fail(error)
                    case .cancelled:
                        resolver.fail(CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "onyx.test.raw-loopback"))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receiveUntilClosed() async throws -> Data {
        var result = Data()
        while true {
            let (data, isComplete) = try await receive()
            if let data, !data.isEmpty { result.append(data) }
            if isComplete { return result }
        }
    }

    /// Returns one currently available TCP read without waiting for the
    /// peer's connection-close. Proxy streaming tests use this to distinguish
    /// a response body flushed at an SSE frame boundary from one buffered
    /// until the provider finishes.
    func receiveChunk() async throws -> Data? {
        let (data, isComplete) = try await receive()
        if let data, !data.isEmpty { return data }
        return isComplete ? nil : Data()
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() async throws -> (Data?, Bool) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data?, Bool), any Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 64 * 1_024
                ) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data, isComplete)) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class ConnectionStateResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func succeed() { resolve(.success(())) }
    func fail(_ error: any Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Void, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
