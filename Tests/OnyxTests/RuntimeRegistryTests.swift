import XCTest
@testable import Onyx

final class RuntimeRegistryTests: XCTestCase {
    func testProviderIdentifiersAndModelReferencesRoundTripAsOpaqueValues() throws {
        let adapterID = RuntimeAdapterID("test.adapter")
        let connectionID = ProviderConnectionID("test.connection")
        let model = ModelRef(connectionID: connectionID, modelID: "shared-model-name")

        let encodedAdapter = try JSONEncoder().encode(adapterID)
        let encodedConnection = try JSONEncoder().encode(connectionID)
        let encodedModel = try JSONEncoder().encode(model)

        XCTAssertEqual(try JSONDecoder().decode(RuntimeAdapterID.self, from: encodedAdapter), adapterID)
        XCTAssertEqual(try JSONDecoder().decode(ProviderConnectionID.self, from: encodedConnection), connectionID)
        XCTAssertEqual(try JSONDecoder().decode(ModelRef.self, from: encodedModel), model)
        XCTAssertNotEqual(
            model,
            ModelRef(
                connectionID: ProviderConnectionID("another.connection"),
                modelID: model.modelID
            )
        )
    }

    func testProductionRegistryRegistersExactlyTheDefaultCodexConnection() {
        let registry = RuntimeRegistry.codexOnly

        XCTAssertEqual(registry.providers.map(\.id), [.codexAppServer])
        XCTAssertEqual(registry.providers.map(\.displayName), ["Codex"])
        XCTAssertEqual(
            registry.connections,
            [
                RuntimeConnectionRegistration(
                    id: .codexDefault,
                    adapterID: .codexAppServer
                ),
            ]
        )
    }

    func testRegistryResolvesTheFactoryBoundToAConnection() async throws {
        let adapterID = RuntimeAdapterID("test.fake")
        let connectionID = ProviderConnectionID("test.fake.primary")
        let fake = RegistryFakeRuntime()
        let provider = RuntimeProviderDescriptor(id: adapterID, displayName: "Fake") { requestedID in
            guard requestedID == connectionID else {
                throw RuntimeRegistryError.connectionNotRegistered(requestedID)
            }
            return fake
        }
        let registry = try RuntimeRegistry(
            providers: [provider],
            connections: [
                RuntimeConnectionRegistration(id: connectionID, adapterID: adapterID),
            ]
        )

        let runtime = try registry.resolve(connectionID)
        let resolvedFake = try XCTUnwrap(runtime as? RegistryFakeRuntime)
        let session = try await runtime.connect()

        XCTAssertTrue(resolvedFake === fake)
        XCTAssertEqual(session.displayName, "Fake runtime")
    }

    func testRegistryPassesDynamicToolHandlerOnlyToOptInFactory() throws {
        let adapterID = RuntimeAdapterID("test.dynamic-tools")
        let connectionID = ProviderConnectionID("test.dynamic-tools.primary")
        let provider = RuntimeProviderDescriptor(
            id: adapterID,
            displayName: "Dynamic tools",
            dynamicToolFactory: { requestedID, handler in
                guard requestedID == connectionID else {
                    throw RuntimeRegistryError.connectionNotRegistered(requestedID)
                }
                return RegistryFakeRuntime(hasDynamicToolHandler: handler != nil)
            }
        )
        let registry = try RuntimeRegistry(
            providers: [provider],
            connections: [
                RuntimeConnectionRegistration(id: connectionID, adapterID: adapterID),
            ]
        )

        let runtime = try registry.resolve(
            connectionID,
            dynamicToolHandler: RegistryDynamicToolHandler()
        )

        XCTAssertTrue(try XCTUnwrap(runtime as? RegistryFakeRuntime).hasDynamicToolHandler)
    }

    func testRegistryRejectsUnknownConnectionsAndInvalidRegistrations() throws {
        let connectionID = ProviderConnectionID("test.missing")
        let adapterID = RuntimeAdapterID("test.missing-adapter")
        let empty = try RuntimeRegistry(providers: [], connections: [])

        XCTAssertThrowsError(try empty.resolve(connectionID)) { error in
            XCTAssertEqual(
                error as? RuntimeRegistryError,
                .connectionNotRegistered(connectionID)
            )
        }

        XCTAssertThrowsError(
            try RuntimeRegistry(
                providers: [],
                connections: [
                    RuntimeConnectionRegistration(id: connectionID, adapterID: adapterID),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeRegistryError,
                .connectionReferencesMissingAdapter(
                    connectionID: connectionID,
                    adapterID: adapterID
                )
            )
        }
    }

    func testRegistryRejectsDuplicateIDsWithoutTrapping() {
        let adapterID = RuntimeAdapterID("test.duplicate-adapter")
        let connectionID = ProviderConnectionID("test.duplicate-connection")
        let first = RuntimeProviderDescriptor(id: adapterID, displayName: "First") { _ in
            RegistryFakeRuntime()
        }
        let second = RuntimeProviderDescriptor(id: adapterID, displayName: "Second") { _ in
            RegistryFakeRuntime()
        }

        XCTAssertThrowsError(
            try RuntimeRegistry(providers: [first, second], connections: [])
        ) { error in
            XCTAssertEqual(error as? RuntimeRegistryError, .duplicateAdapterID(adapterID))
        }

        let connection = RuntimeConnectionRegistration(id: connectionID, adapterID: adapterID)
        XCTAssertThrowsError(
            try RuntimeRegistry(
                providers: [first],
                connections: [connection, connection]
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeRegistryError, .duplicateConnectionID(connectionID))
        }
    }
}

private actor RegistryFakeRuntime: AgentRuntime {
    nonisolated let kind = AgentRuntimeKind.local
    nonisolated let hasDynamicToolHandler: Bool
    nonisolated let events: AsyncStream<AgentRuntimeEvent> = AsyncStream { continuation in
        continuation.finish()
    }

    init(hasDynamicToolHandler: Bool = false) {
        self.hasDynamicToolHandler = hasDynamicToolHandler
    }

    func connect() async throws -> RuntimeSession {
        RuntimeSession(
            runtime: .local,
            displayName: "Fake runtime",
            accountLabel: nil,
            planLabel: nil,
            auth: RuntimeAuthState(
                mode: nil,
                email: nil,
                planLabel: nil,
                requiresAuthentication: false
            ),
            availableLoginMethods: [],
            availableModels: [],
            capabilities: []
        )
    }

    func disconnect() async {}

    func listThreads(limit _: Int, archived _: Bool) async throws -> [RuntimeThread] {
        throw AgentRuntimeError.unsupported("fake thread listing")
    }

    func readThread(id _: String) async throws -> RuntimeConversation {
        throw AgentRuntimeError.unsupported("fake thread reading")
    }

    func startThread(_: StartThreadRequest) async throws -> RuntimeThread {
        throw AgentRuntimeError.unsupported("fake thread creation")
    }

    func startTurn(_: StartTurnRequest) async throws {
        throw AgentRuntimeError.unsupported("fake turns")
    }

    func steer(threadID _: String, text _: String) async throws {
        throw AgentRuntimeError.unsupported("fake steering")
    }

    func interrupt(threadID _: String) async throws {
        throw AgentRuntimeError.unsupported("fake interruption")
    }

    func respond(
        to _: RuntimeRequestID,
        with _: RuntimeUserInteractionResponse
    ) async throws {
        throw AgentRuntimeError.unsupported("fake responses")
    }

    func renameThread(id _: String, name _: String) async throws {
        throw AgentRuntimeError.unsupported("fake renaming")
    }

    func archiveThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("fake archiving")
    }

    func unarchiveThread(id _: String) async throws {
        throw AgentRuntimeError.unsupported("fake restoring")
    }
}

private actor RegistryDynamicToolHandler: CodexDynamicToolHandler {
    func handleDynamicToolCall(
        _: CodexDynamicToolCall
    ) async throws -> CodexDynamicToolResult {
        .succeeded("unused")
    }
}
