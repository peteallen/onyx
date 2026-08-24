import Foundation
import XCTest
@testable import Onyx

/// Focused coverage for the unauthenticated socket limits in the loopback
/// Responses proxy. A local process must not be able to consume unbounded
/// connection tasks by opening sockets and withholding headers or bodies.
final class OpenAICompatibleResponsesProxyBoundaryTests: XCTestCase {
    func testConcurrentConnectionLimitRejectsOverflowAndReleasesCapacity() async throws {
        let proxy = try makeProxy(
            limits: .init(
                maximumConcurrentConnections: 1,
                clientRequestTimeout: 1,
                requestTimeout: 2,
                resourceTimeout: 3
            )
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }
        let port = try XCTUnwrap(binding.baseURL.port)

        // Occupy the only slot with a valid request head whose declared body
        // never finishes. A short settling interval lets the listener assign
        // this connection before the overflow client reaches it.
        let occupant = try RawLoopbackConnection(port: port)
        try await occupant.start()
        defer { occupant.cancel() }
        try await occupant.send(
            makeRequest(
                port: port,
                token: binding.bearerToken,
                declaredBodyLength: 64,
                bodyPrefix: Data("{".utf8)
            )
        )
        try await Task.sleep(for: .milliseconds(100))

        let overflow = try RawLoopbackConnection(port: port)
        defer { overflow.cancel() }
        let overflowBytes = try await sendAndCaptureRejectedConnection(
            makeCompleteRequest(port: port, token: "wrong-token"),
            over: overflow,
            timeout: .milliseconds(350)
        )
        XCTAssertTrue(
            overflowBytes?.isEmpty ?? true,
            "A connection above the configured limit must close without an HTTP response"
        )

        let timedOutOccupant = try await receiveUntilClosed(
            occupant,
            timeout: .seconds(2)
        )
        assertSlowClientWasTerminated(timedOutOccupant)

        // The timed-out task must retire from the connection count so a later
        // socket can be handled normally. Authentication fails intentionally,
        // keeping this entire regression on the pre-upstream boundary.
        try await Task.sleep(for: .milliseconds(50))
        let successor = try RawLoopbackConnection(port: port)
        defer { successor.cancel() }
        try await successor.start()
        try await successor.send(makeCompleteRequest(port: port, token: "wrong-token"))
        let successorBytes = try await receiveUntilClosed(
            successor,
            timeout: .seconds(1)
        )
        XCTAssertEqual(statusCode(in: successorBytes), 401)
    }

    func testIncompleteRequestHeadersTimeOut() async throws {
        let proxy = try makeProxy(
            limits: .init(
                clientRequestTimeout: 0.2,
                requestTimeout: 2,
                resourceTimeout: 3
            )
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }
        let port = try XCTUnwrap(binding.baseURL.port)
        let client = try RawLoopbackConnection(port: port)
        defer { client.cancel() }

        try await client.start()
        let incompleteHead = "POST /v1/responses HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Authorization: Bearer \(binding.bearerToken)\r\n"
        let startedAt = ContinuousClock.now
        try await client.send(Data(incompleteHead.utf8))

        let response = try await receiveUntilClosed(client, timeout: .seconds(1))
        XCTAssertGreaterThanOrEqual(
            ContinuousClock.now - startedAt,
            .milliseconds(100),
            "An incomplete header must remain open until the configured deadline"
        )
        assertSlowClientWasTerminated(response)
    }

    func testIncompleteRequestBodyTimesOut() async throws {
        let proxy = try makeProxy(
            limits: .init(
                clientRequestTimeout: 0.2,
                requestTimeout: 2,
                resourceTimeout: 3
            )
        )
        let binding = try await proxy.start()
        addTeardownBlock { await proxy.stop() }
        let port = try XCTUnwrap(binding.baseURL.port)
        let client = try RawLoopbackConnection(port: port)
        defer { client.cancel() }
        let completeBody = Data(#"{"model":"fixture-model","stream":true}"#.utf8)

        try await client.start()
        let startedAt = ContinuousClock.now
        try await client.send(
            makeRequest(
                port: port,
                token: binding.bearerToken,
                declaredBodyLength: completeBody.count,
                bodyPrefix: completeBody.prefix(4)
            )
        )

        let response = try await receiveUntilClosed(client, timeout: .seconds(1))
        XCTAssertGreaterThanOrEqual(
            ContinuousClock.now - startedAt,
            .milliseconds(100),
            "An incomplete body must remain open until the configured deadline"
        )
        assertSlowClientWasTerminated(response)
    }

    private func makeProxy(
        limits: OpenAICompatibleResponsesProxy.Limits
    ) throws -> OpenAICompatibleResponsesProxy {
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("responses.proxy.boundary.fixture"),
            displayName: "Responses proxy boundary fixture",
            baseURL: URL(string: "https://provider.example.test/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none
        )
        return try OpenAICompatibleResponsesProxy(
            connection: connection,
            upstreamCredential: nil,
            disposableToken: "boundary-local-token",
            session: URLSession(configuration: .ephemeral),
            limits: limits
        )
    }

    private func makeCompleteRequest(port: Int, token: String) -> Data {
        let body = Data(#"{"model":"fixture-model","stream":true}"#.utf8)
        return makeRequest(
            port: port,
            token: token,
            declaredBodyLength: body.count,
            bodyPrefix: body
        )
    }

    private func makeRequest(
        port: Int,
        token: String,
        declaredBodyLength: Int,
        bodyPrefix: some DataProtocol
    ) -> Data {
        let head = "POST /v1/responses HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Content-Type: application/json\r\n"
            + "Authorization: Bearer \(token)\r\n"
            + "Content-Length: \(declaredBodyLength)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + Data(bodyPrefix)
    }

    /// An overflow socket can be reset before `ready`, while sending, or while
    /// receiving. All three are equivalent evidence that it was rejected. A
    /// timeout is kept distinct because an accepted, stalled socket is a limit
    /// regression rather than a successful close.
    private func sendAndCaptureRejectedConnection(
        _ request: Data,
        over client: RawLoopbackConnection,
        timeout: Duration
    ) async throws -> Data? {
        do {
            try await client.start()
            try await client.send(request)
            return try await receiveUntilClosed(client, timeout: timeout)
        } catch ProxyBoundaryTestError.timedOut {
            throw ProxyBoundaryTestError.timedOut
        } catch {
            return nil
        }
    }

    private func receiveUntilClosed(
        _ client: RawLoopbackConnection,
        timeout: Duration
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await client.receiveUntilClosed() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProxyBoundaryTestError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ProxyBoundaryTestError.timedOut
            }
            return first
        }
    }

    private func statusCode(in response: Data) -> Int? {
        let firstLine = String(decoding: response, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .first
        return firstLine?
            .split(separator: " ", maxSplits: 2)
            .dropFirst()
            .first
            .flatMap { Int($0) }
    }

    private func assertSlowClientWasTerminated(
        _ response: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Closing without a response is appropriate for a pre-auth slow
        // client. A 400 is also safe if the proxy can write it before closing.
        guard !response.isEmpty else { return }
        XCTAssertEqual(statusCode(in: response), 400, file: file, line: line)
    }
}

private enum ProxyBoundaryTestError: Error {
    case timedOut
}
