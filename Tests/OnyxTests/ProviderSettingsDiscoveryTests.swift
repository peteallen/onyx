import Foundation
import XCTest
@testable import Onyx

final class ProviderSettingsDiscoveryTests: XCTestCase {
    override func tearDown() {
        ProviderSettingsURLProtocol.reset()
        super.tearDown()
    }

    func testProductionDiscoveryUsesModelsEndpointAndBearerHeader() async throws {
        let probe = ProviderSettingsRequestProbe()
        ProviderSettingsURLProtocol.configure { request in
            probe.record(request)
            return .json(
                statusCode: 200,
                body: """
                {
                  "object": "list",
                  "data": [
                    {
                      "id": "Qwen/Qwen3.8-27B-FP8",
                      "object": "model",
                      "owned_by": "vllm"
                    }
                  ]
                }
                """
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderSettingsURLProtocol.self]
        let discovery = URLSessionProviderModelDiscovery(
            session: URLSession(configuration: configuration)
        )
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("local.qwen"),
            displayName: "Qwen",
            baseURL: URL(string: "http://lan-provider.example.test:8002/v1")!,
            authMode: .bearer,
            transportSecurity: .allowInsecureHTTP
        )
        let credential = try ProviderBearerCredential("fixture-key")

        let models = try await discovery.discoverModels(
            for: connection,
            credential: credential
        )

        XCTAssertEqual(models.map(\.id), ["Qwen/Qwen3.8-27B-FP8"])
        let request = try XCTUnwrap(probe.request)
        XCTAssertEqual(request.url?.absoluteString, "http://lan-provider.example.test:8002/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
    }

    func testConnectionInitializerRejectsLANHTTPWithoutPersistedOptIn() throws {
        XCTAssertThrowsError(
            try ProviderConnectionRecord(
                id: ProviderConnectionID("unsafe"),
                displayName: "Unsafe",
                baseURL: URL(string: "http://lan-provider.example.test:8002/v1")!,
                authMode: .none
            )
        ) { error in
            guard case .insecureHTTPRequiresExplicitOptIn = error as? ProviderConnectionRecordError else {
                return XCTFail("Expected explicit insecure HTTP acknowledgement error")
            }
        }
    }
}

private final class ProviderSettingsRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?

    var request: URLRequest? {
        lock.withLock { value }
    }

    func record(_ request: URLRequest) {
        lock.withLock { value = request }
    }
}

private final class ProviderSettingsURLProtocol: URLProtocol {
    struct Response: Sendable {
        let statusCode: Int
        let body: Data

        static func json(statusCode: Int, body: String) -> Self {
            Self(statusCode: statusCode, body: Data(body.utf8))
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?

    static func configure(
        _ handler: @escaping @Sendable (URLRequest) -> Response
    ) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.lock.withLock { Self.handler }?(request)
            ?? Response(statusCode: 500, body: Data())
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
