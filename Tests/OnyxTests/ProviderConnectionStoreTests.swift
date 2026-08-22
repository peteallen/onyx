import Foundation
import XCTest
@testable import Onyx

final class ProviderConnectionStoreTests: XCTestCase {
    func testNormalizesHTTPSAndRequiresAcknowledgedLiteralLocalHTTP() throws {
        XCTAssertEqual(
            try ProviderBaseURLNormalizer.normalize(" HTTPS://Example.COM:443/v1/// ")
                .absoluteString,
            "https://example.com/v1"
        )

        XCTAssertThrowsError(
            try ProviderBaseURLNormalizer.normalize("http://127.0.0.1:8000/v1/")
        ) { error in
            XCTAssertEqual(
                error as? ProviderConnectionRecordError,
                .insecureHTTPRequiresExplicitOptIn("http://127.0.0.1:8000/v1/")
            )
        }
        XCTAssertEqual(
            try ProviderBaseURLNormalizer.normalize(
                "http://127.0.0.1:8000/v1/",
                transportSecurity: .allowInsecureHTTP
            )
                .absoluteString,
            "http://127.0.0.1:8000/v1"
        )

        XCTAssertThrowsError(
            try ProviderBaseURLNormalizer.normalize(
                "http://localhost:8000/v1",
                transportSecurity: .allowInsecureHTTP
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderConnectionRecordError,
                .insecureHTTPHostNotAllowed("http://localhost:8000/v1")
            )
        }
        XCTAssertThrowsError(
            try ProviderBaseURLNormalizer.normalize(
                "http://8.8.8.8:8000/v1",
                transportSecurity: .allowInsecureHTTP
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderConnectionRecordError,
                .insecureHTTPHostNotAllowed("http://8.8.8.8:8000/v1")
            )
        }
        XCTAssertThrowsError(
            try ProviderBaseURLNormalizer.normalize(
                "http://lan-provider.example.test:8002/v1",
                transportSecurity: .allowInsecureHTTP
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderConnectionRecordError,
                .insecureHTTPHostNotAllowed("http://lan-provider.example.test:8002/v1")
            )
        }

        XCTAssertThrowsError(
            try ProviderBaseURLNormalizer.normalize("https://secret@example.com/v1")
        ) { error in
            XCTAssertEqual(
                error as? ProviderConnectionRecordError,
                .invalidBaseURL("https://secret@example.com/v1")
            )
        }
        XCTAssertThrowsError(
            try ProviderBaseURLNormalizer.normalize("https://example.com/v1?token=secret")
        )
        XCTAssertThrowsError(
            try ProviderBaseURLNormalizer.normalize("file:///tmp/provider")
        )
    }

    func testExplicitInsecureHTTPAllowsLiteralPrivateIPNoKeyConnectionAndPersistsAcknowledgement() async throws {
        let connection = try makeQwenConnection()
        XCTAssertEqual(connection.baseURL.absoluteString, "http://192.168.2.170:8002/v1")
        XCTAssertEqual(connection.authMode, .none)
        XCTAssertEqual(connection.transportSecurity, .allowInsecureHTTP)
        XCTAssertEqual(connection.selectedModelID, "Qwen/Qwen3.8-27B-FP8")
        XCTAssertEqual(connection.requestBehavior.enableThinking, false)

        let storage = InMemoryProviderConnectionStorage()
        let store = ProviderConnectionStore(storage: storage)
        try await store.upsert(connection)

        let reopened = ProviderConnectionStore(storage: storage)
        let reopenedConnections = try await reopened.connections()
        XCTAssertEqual(reopenedConnections, [connection])

        let data = try XCTUnwrap(storage.storedData())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("allowInsecureHTTP"))
        XCTAssertTrue(json.contains("enableThinking"))
        XCTAssertTrue(json.contains("Qwen"))
        XCTAssertTrue(json.contains("Qwen3.8-27B-FP8"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("bearerToken"))
        XCTAssertFalse(json.contains("test-secret"))
    }

    func testClearTextHTTPRejectsBearerModeAndAllowsPrivateAndLinkLocalRanges() throws {
        for endpoint in [
            "http://10.0.0.12/v1",
            "http://172.16.4.2/v1",
            "http://192.168.4.2/v1",
            "http://169.254.12.3/v1",
            "http://[::1]/v1",
            "http://[fc00::12]/v1",
            "http://[fe80::12]/v1",
        ] {
            XCTAssertNoThrow(
                try ProviderConnectionRecord(
                    id: ProviderConnectionID("allowed.\(endpoint.hashValue)"),
                    displayName: "Allowed",
                    baseURL: URL(string: endpoint)!,
                    authMode: .none,
                    transportSecurity: .allowInsecureHTTP
                ),
                "Expected local/private HTTP endpoint to be accepted: \(endpoint)"
            )
        }

        XCTAssertThrowsError(
            try ProviderConnectionRecord(
                id: ProviderConnectionID("private.bearer"),
                displayName: "Private bearer",
                baseURL: URL(string: "http://192.168.1.10/v1")!,
                authMode: .bearer,
                transportSecurity: .allowInsecureHTTP
            )
        ) { error in
            guard case .insecureHTTPBearerCredentialNotAllowed = error as? ProviderConnectionRecordError else {
                return XCTFail("Expected bearer-over-HTTP rejection, got \(error)")
            }
        }
    }

    func testHTTPHostClassifierDistinguishesEveryAllowedAndRejectedClass() {
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("127.2.3.4"),
            .loopback
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("10.1.2.3"),
            .privateNetwork
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("172.31.255.254"),
            .privateNetwork
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("169.254.1.2"),
            .linkLocal
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("[fd12::1]"),
            .privateNetwork
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("fe80::1%en0"),
            .linkLocal
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("8.8.8.8"),
            .publicIP
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("2001:4860:4860::8888"),
            .publicIP
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("localhost"),
            .hostname
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("127.1"),
            .hostname
        )
        XCTAssertEqual(
            ProviderBaseURLNormalizer.insecureHTTPHostClassification("0127.0.0.1"),
            .hostname
        )
    }

    func testBearerCredentialLivesOnlyInCredentialStoreAndConnectionJSONCannotEncodeIt() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let connectionStore = ProviderConnectionStore(storage: storage)
        let credentialStore = InMemoryCredentialStore()
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("openrouter.primary"),
            displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1/")!,
            selectedModelID: "openai/gpt-5",
            authMode: .bearer,
            transportCapabilities: [.streaming, .streamUsage]
        )
        let secretText = "test-secret-that-must-not-be-serialized"
        let credential = try ProviderBearerCredential(secretText)

        try await connectionStore.upsert(connection)
        await credentialStore.setCredential(credential, for: connection.credentialKey)

        let storedConnection = try await connectionStore.connection(id: connection.id)
        XCTAssertEqual(storedConnection, connection)
        let loadedCredential = await credentialStore.credential(for: connection.credentialKey)
        XCTAssertEqual(loadedCredential, credential)
        XCTAssertEqual(try loadedCredential?.withValue { $0 }, secretText)

        let data = try XCTUnwrap(storage.storedData())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains(secretText))
        XCTAssertFalse(json.contains("ProviderBearerCredential"))
        XCTAssertEqual(connection.credentialKey.description, "provider credential")

        await credentialStore.removeCredential(for: connection.credentialKey)
        let removedCredential = await credentialStore.credential(for: connection.credentialKey)
        XCTAssertNil(removedCredential)
    }

    func testStoreUpsertsRemovesAndNormalizesDiscoveryMetadata() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let store = ProviderConnectionStore(storage: storage)
        var connection = try makeQwenConnection()

        try await store.upsert(connection)
        connection.displayName = "Local Qwen"
        connection.discovery = ProviderConnectionDiscoveryMetadata(
            lastAttemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSucceededAt: Date(timeIntervalSince1970: 1_700_000_001),
            discoveredModelIDs: [
                " Qwen/Qwen3.8-27B-FP8 ",
                "Qwen/Qwen3.8-27B-FP8",
                "",
                "another-model",
            ]
        )
        try await store.upsert(connection)

        let storedConnection = try await store.connection(id: connection.id)
        XCTAssertEqual(
            storedConnection?.discovery.discoveredModelIDs,
            ["Qwen/Qwen3.8-27B-FP8", "another-model"]
        )
        let countAfterUpsert = try await store.connections().count
        XCTAssertEqual(countAfterUpsert, 1)
        let removed = try await store.remove(id: connection.id)
        XCTAssertEqual(removed, connection)
        let connectionsAfterRemove = try await store.connections()
        XCTAssertEqual(connectionsAfterRemove, [])
        let missingRemove = try await store.remove(id: connection.id)
        XCTAssertNil(missingRemove)
    }

    func testStoreRevalidatesFieldScopedMutationsBeforePersisting() async throws {
        let store = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        let connection = try makeQwenConnection()
        try await store.upsert(connection)

        do {
            _ = try await store.update(id: connection.id) { record in
                record.authMode = .bearer
            }
            XCTFail("Expected mutated bearer-over-HTTP record to be rejected")
        } catch let error as ProviderConnectionRecordError {
            guard case .insecureHTTPBearerCredentialNotAllowed = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
        }

        let unchanged = try await store.connection(id: connection.id)
        XCTAssertEqual(unchanged, connection)
    }

    func testAtomicUpdatePreservesUnrelatedConnectionFields() async throws {
        let storage = InMemoryProviderConnectionStorage()
        let store = ProviderConnectionStore(storage: storage)
        let connection = try makeQwenConnection()
        try await store.upsert(connection)

        let updated = try await store.update(id: connection.id) { record in
            record.discovery = ProviderConnectionDiscoveryMetadata(
                lastAttemptedAt: Date(timeIntervalSince1970: 10),
                lastSucceededAt: Date(timeIntervalSince1970: 11),
                discoveredModelIDs: ["new-model"]
            )
        }
        XCTAssertEqual(updated.displayName, connection.displayName)
        XCTAssertEqual(updated.baseURL, connection.baseURL)
        XCTAssertEqual(updated.selectedModelID, connection.selectedModelID)
        XCTAssertEqual(updated.discovery.discoveredModelIDs, ["new-model"])

        do {
            _ = try await store.update(id: ProviderConnectionID("missing")) { _ in }
            XCTFail("Expected missing connection update to fail")
        } catch {
            XCTAssertEqual(
                error as? ProviderConnectionStoreError,
                .connectionNotFound(ProviderConnectionID("missing"))
            )
        }
    }

    func testDecodeRevalidatesHTTPPolicyAndRejectsDuplicateIDsAndUnknownSchema() async throws {
        let connection = try makeQwenConnection()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try encoder.encode(
                    ProviderConnectionSnapshot(connections: [connection])
                )
            ) as? [String: Any]
        )
        var connections = try XCTUnwrap(object["connections"] as? [[String: Any]])
        connections[0]["transportSecurity"] = "requireTLS"
        object["connections"] = connections
        let unsafeData = try JSONSerialization.data(withJSONObject: object)
        let unsafeStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage(data: unsafeData)
        )
        await assertThrowsConnectionStoreError(
            { _ = try await unsafeStore.snapshot() },
            matching: { error in
                guard case let .malformedDocument(detail) = error else { return false }
                return detail.contains("explicit insecure-HTTP acknowledgement")
            }
        )

        var hostnameObject = object
        var hostnameConnections = try XCTUnwrap(
            hostnameObject["connections"] as? [[String: Any]]
        )
        hostnameConnections[0]["baseURL"] = "http://provider.example.test:8002/v1"
        hostnameConnections[0]["transportSecurity"] = "allowInsecureHTTP"
        hostnameObject["connections"] = hostnameConnections
        let hostnameData = try JSONSerialization.data(withJSONObject: hostnameObject)
        let hostnameStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage(data: hostnameData)
        )
        await assertThrowsConnectionStoreError(
            { _ = try await hostnameStore.snapshot() },
            matching: { error in
                guard case let .malformedDocument(detail) = error else { return false }
                return detail.contains("literal loopback")
            }
        )

        let duplicateData = try encoder.encode(
            ProviderConnectionSnapshot(connections: [connection, connection])
        )
        let duplicateStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage(data: duplicateData)
        )
        await assertThrowsConnectionStoreError(
            { _ = try await duplicateStore.snapshot() },
            matching: { $0 == .duplicateConnectionID(connection.id) }
        )

        let futureData = try encoder.encode(
            ProviderConnectionSnapshot(schemaVersion: 99, connections: [])
        )
        let futureStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage(data: futureData)
        )
        await assertThrowsConnectionStoreError(
            { _ = try await futureStore.snapshot() },
            matching: { $0 == .unsupportedSchemaVersion(99) }
        )
    }

    func testApplicationSupportStorageCreatesNestedDirectoryAndRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderConnectionStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("nested/provider-connections.json")
        let store = ProviderConnectionStore(
            storage: ApplicationSupportProviderConnectionStorage(fileURL: fileURL)
        )
        let connection = try makeQwenConnection()

        try await store.upsert(connection)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reopened = ProviderConnectionStore(
            storage: ApplicationSupportProviderConnectionStorage(fileURL: fileURL)
        )
        let reopenedConnections = try await reopened.connections()
        XCTAssertEqual(reopenedConnections, [connection])
    }

    func testInMemoryCredentialStoreRejectsEmptyBearerValue() async throws {
        XCTAssertThrowsError(try ProviderBearerCredential("")) { error in
            XCTAssertEqual(error as? ProviderCredentialStoreError, .emptyCredential)
        }

        let store = InMemoryCredentialStore()
        let key = ProviderCredentialKey(connectionID: ProviderConnectionID("missing"))
        let missing = await store.credential(for: key)
        XCTAssertNil(missing)
        await store.removeCredential(for: key)
    }

    private func makeQwenConnection() throws -> ProviderConnectionRecord {
        try ProviderConnectionRecord(
            id: ProviderConnectionID("local.qwen.primary"),
            displayName: "Qwen LAN",
            baseURL: URL(string: "http://192.168.2.170:8002/v1/")!,
            selectedModelID: " Qwen/Qwen3.8-27B-FP8 ",
            authMode: .none,
            transportSecurity: .allowInsecureHTTP,
            transportCapabilities: [.streaming],
            requestBehavior: OpenAICompatibleRequestBehavior(enableThinking: false)
        )
    }

    private func assertThrowsConnectionStoreError(
        _ body: () async throws -> Void,
        matching: (ProviderConnectionStoreError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Expected ProviderConnectionStoreError", file: file, line: line)
        } catch let error as ProviderConnectionStoreError {
            XCTAssertTrue(matching(error), "Unexpected error: \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }
}
