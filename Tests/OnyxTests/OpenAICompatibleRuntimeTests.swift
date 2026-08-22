import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleRuntimeTests: XCTestCase {
    override func tearDown() {
        RuntimeFixtureURLProtocol.reset()
        super.tearDown()
    }

    func testConnectDiscoversExactModelAndStreamsIntoDurableConversation() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeTests")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.qwen"),
            displayName: "Fixture Qwen",
            baseURL: URL(string: "https://provider.example/v1/chat/completions")!,
            selectedModelID: "Qwen/Qwen3.8-27B-FP8",
            authMode: .none,
            transportCapabilities: [.streaming],
            requestBehavior: .init(enableThinking: false)
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let session = makeFixtureSession()
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path == "/v1/models" else {
                return .eventStream(body: """
                data: {"id":"chatcmpl-fixture","model":"Qwen/Qwen3.8-27B-FP8","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

                data: {"id":"chatcmpl-fixture","model":"Qwen/Qwen3.8-27B-FP8","choices":[{"index":0,"delta":{"content":"ONYX_"},"finish_reason":null}]}

                data: {"id":"chatcmpl-fixture","model":"Qwen/Qwen3.8-27B-FP8","choices":[{"index":0,"delta":{"content":"QWEN_OK"},"finish_reason":"stop"}]}

                data: [DONE]

                """)
            }
            return .json(body: """
            {"object":"list","data":[{"id":"Qwen/Qwen3.8-27B-FP8","object":"model"}]}
            """)
        }

        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: conversationStore,
            session: session
        )
        let sessionSnapshot = try await runtime.connect()
        XCTAssertTrue(sessionSnapshot.auth.canRun)
        XCTAssertEqual(sessionSnapshot.availableModels.map(\.id), ["Qwen/Qwen3.8-27B-FP8"])

        let thread = try await runtime.startThread(
            StartThreadRequest(cwd: "/tmp/project", model: "Qwen/Qwen3.8-27B-FP8")
        )
        let events = await collectUntilTurnCompletion(runtime: runtime, threadID: thread.id) {
            try await runtime.startTurn(
                StartTurnRequest(
                    threadID: thread.id,
                    inputs: [.text("Reply exactly with a fixture response")]
                )
            )
        }
        XCTAssertTrue(events.contains {
            if case let .itemDelta(_, _, delta) = $0 { return delta.contains("ONYX_") }
            return false
        })
        XCTAssertTrue(events.contains {
            if case let .itemCompleted(_, item) = $0 {
                return item.kind == .assistantMessage && item.body == "ONYX_QWEN_OK"
            }
            return false
        })

        let conversation = try await runtime.readThread(id: thread.id)
        XCTAssertEqual(conversation.items.map(\.body), [
            "Reply exactly with a fixture response",
            "ONYX_QWEN_OK",
        ])
        let listed = try await runtime.listThreads(limit: 10, archived: false)
        XCTAssertEqual(listed.first?.id, thread.id)
    }

    func testLegacyEmptyTransportCapabilitiesRemainUsable() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeLegacyTransport")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.legacy-transport"),
            displayName: "Legacy vLLM",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            transportCapabilities: []
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { _ in
            .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
        }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: OpenAICompatibleConversationStore(
                fileURL: location.appendingPathComponent("conversations.json")
            ),
            session: makeFixtureSession()
        )

        let snapshot = try await runtime.connect()

        XCTAssertTrue(snapshot.capabilities.contains(.streaming))
        XCTAssertTrue(snapshot.capabilities.contains(.interruption))
        XCTAssertTrue(snapshot.capabilities.contains(.usage))
    }

    func testConnectUsesManuallySavedModelWhenDiscoveryReturnsNoModels() async throws {
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.manual-model"),
            displayName: "Fixture vLLM",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "Qwen/Qwen3.8-27B-FP8",
            authMode: .none,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path == "/v1/models" else {
                return .eventStream(body: "data: [DONE]\n\n")
            }
            // Some local servers expose chat but do not implement a usable
            // model catalog. The saved model ID should remain selectable.
            return .json(body: "{\"object\":\"list\",\"data\":[]}")
        }

        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: OpenAICompatibleConversationStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("OnyxManualModel-(UUID().uuidString).json")
            ),
            session: makeFixtureSession()
        )

        let snapshot = try await runtime.connect()
        XCTAssertEqual(snapshot.availableModels.map(\.id), ["Qwen/Qwen3.8-27B-FP8"])
        XCTAssertEqual(snapshot.availableModels.first?.displayName, "Qwen/Qwen3.8-27B-FP8")
    }

    func testManuallySavedModelRemainsExecutableWhenDiscoveryOmitsIt() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimePartialCatalog")
        defer { try? FileManager.default.removeItem(at: location) }
        let manualModelID = "Qwen/Qwen3.8-27B-FP8"
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.partial-catalog"),
            displayName: "Fixture vLLM",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: manualModelID,
            authMode: .none,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(
            storage: InMemoryProviderConnectionStorage()
        )
        try await connectionStore.upsert(connection)
        let captured = RequestBodySequenceCapture()
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path != "/v1/models" else {
                return .json(body: """
                {"data":[{"id":"catalog-only-model","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}
                """)
            }
            captured.record(request)
            return .eventStream(body: """
            data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}

            data: [DONE]

            """)
        }

        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: OpenAICompatibleConversationStore(
                fileURL: location.appendingPathComponent("conversations.json")
            ),
            session: makeFixtureSession()
        )

        let snapshot = try await runtime.connect()
        XCTAssertEqual(snapshot.availableModels.map(\.id), ["catalog-only-model", manualModelID])
        let manualModel = try XCTUnwrap(
            snapshot.availableModels.first(where: { $0.id == manualModelID })
        )
        XCTAssertTrue(manualModel.isDefault)
        XCTAssertEqual(manualModel.capabilityEvidence, .unknown)
        XCTAssertEqual(manualModel.inputModalities, [.text])
        XCTAssertTrue(manualModel.reasoningEfforts.isEmpty)
        XCTAssertTrue(manualModel.supportedRequestParameters.isEmpty)

        let storedConnection = try await connectionStore.connection(id: connection.id)
        let stored = try XCTUnwrap(storedConnection)
        XCTAssertEqual(stored.discovery.discoveredModelIDs, ["catalog-only-model"])

        let thread = try await runtime.startThread(
            StartThreadRequest(cwd: "/tmp/project", model: manualModelID)
        )
        let events = await collectUntilTurnCompletion(runtime: runtime, threadID: thread.id) {
            try await runtime.startTurn(
                StartTurnRequest(threadID: thread.id, text: "Use the configured model")
            )
        }
        XCTAssertTrue(events.contains {
            if case let .turnCompleted(id, status) = $0 {
                return id == thread.id && status == .idle
            }
            return false
        })
        let body = try XCTUnwrap(captured.bodies.last)
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(request["model"] as? String, manualModelID)
    }

    func testBearerCredentialIsSentOnlyAsAuthorizationHeaderAndMissingBearerCannotRun() async throws {
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.bearer"),
            displayName: "Bearer fixture",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .bearer,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let credentials = InMemoryCredentialStore()
        let secret = try ProviderBearerCredential("fixture-secret")
        await credentials.setCredential(secret, for: connection.credentialKey)
        let conversationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAICompatibleRuntimeTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: conversationURL) }
        let conversationStore = OpenAICompatibleConversationStore(fileURL: conversationURL)
        let observed = RequestCapture()
        RuntimeFixtureURLProtocol.configure { request in
            observed.record(request)
            return .json(body: "{" +
                "\"data\":[{\"id\":\"fixture-model\"}]}")
        }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: credentials,
            conversationStore: conversationStore,
            session: makeFixtureSession()
        )
        let snapshot = try await runtime.connect()
        XCTAssertTrue(snapshot.auth.canRun)
        XCTAssertEqual(observed.path, "/v1/models")
        XCTAssertEqual(observed.authorization, "Bearer fixture-secret")
        XCTAssertFalse(String(decoding: observed.body ?? Data(), as: UTF8.self).contains("fixture-secret"))

        let missingConnection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.missing-bearer"),
            displayName: "Missing bearer",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .bearer,
            transportCapabilities: [.streaming],
            discovery: .init(discoveredModelIDs: ["fixture-model"])
        )
        try await connectionStore.upsert(missingConnection)
        let missingRuntime = OpenAICompatibleRuntime(
            connectionID: missingConnection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: conversationStore,
            session: makeFixtureSession()
        )
        let missingSnapshot = try await missingRuntime.connect()
        XCTAssertFalse(missingSnapshot.auth.canRun)
        XCTAssertTrue(missingSnapshot.auth.requiresAuthentication)
    }

    func testAdvertisedVisionModelEnablesImageAttachmentCapability() async throws {
        let connection = try makeFixtureConnection(id: "fixture.vision")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path == "/v1/models" else {
                return .eventStream(body: "data: [DONE]\\n\\n")
            }
            return .json(body: """
            {
              "data": [{
                "id": "fixture-model",
                "architecture": {
                  "input_modalities": ["text", "image"],
                  "output_modalities": ["text"]
                }
              }]
            }
            """)
        }
        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: OpenAICompatibleConversationStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("OnyxVision-\(UUID().uuidString).json")
            )
        )

        let snapshot = try await runtime.connect()

        XCTAssertTrue(snapshot.capabilities.contains(.images))
        XCTAssertTrue(snapshot.availableModels.first?.inputModalities.contains(.image) == true)
    }

    func testFollowUpRequestRetainsResolvedOrderedImageHistoryAfterPersistence() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeImageHistory")
        defer { try? FileManager.default.removeItem(at: location) }
        let imageURL = location.appendingPathComponent("reference.png")
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47])
        try imageBytes.write(to: imageURL)
        let expectedDataURL = "data:image/png;base64,\(imageBytes.base64EncodedString())"

        let connection = try makeFixtureConnection(id: "fixture.image-history")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let captured = RequestBodySequenceCapture()
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path != "/v1/models" else {
                return .json(body: """
                {"data":[{"id":"fixture-model","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}
                """)
            }
            captured.record(request)
            return .eventStream(body: "data: [DONE]\n\n")
        }
        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: conversationStore
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))

        _ = await collectUntilTurnCompletion(runtime: runtime, threadID: thread.id) {
            try await runtime.startTurn(StartTurnRequest(
                threadID: thread.id,
                inputs: [
                    .text("Before image"),
                    .localImagePath(imageURL.path),
                    .text("After image"),
                ]
            ))
        }

        let storedConversation = try await conversationStore.conversation(
            connectionID: connection.id,
            id: thread.id
        )
        let persisted = try XCTUnwrap(storedConversation)
        XCTAssertEqual(persisted.messages[0].contentParts, [
            .text("Before image"),
            .imageURL(expectedDataURL),
            .text("After image"),
        ])
        let reloadedConversation = try await runtime.readThread(id: thread.id)
        XCTAssertEqual(reloadedConversation.items[0].attachments.map(\.source), [
            .dataURL(expectedDataURL),
        ])

        _ = await collectUntilTurnCompletion(runtime: runtime, threadID: thread.id) {
            try await runtime.startTurn(
                StartTurnRequest(threadID: thread.id, text: "Follow up")
            )
        }

        let bodies = captured.bodies
        XCTAssertEqual(bodies.count, 2)
        let followUpDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(bodies.last)) as? [String: Any]
        )
        let messages = try XCTUnwrap(followUpDocument["messages"] as? [[String: Any]])
        let historicalParts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(historicalParts.compactMap { $0["type"] as? String }, [
            "text",
            "image_url",
            "text",
        ])
        XCTAssertEqual(historicalParts[0]["text"] as? String, "Before image")
        XCTAssertEqual(
            (historicalParts[1]["image_url"] as? [String: Any])?["url"] as? String,
            expectedDataURL
        )
        XCTAssertEqual(historicalParts[2]["text"] as? String, "After image")
        XCTAssertFalse(String(decoding: try XCTUnwrap(bodies.last), as: UTF8.self)
            .contains(imageURL.path))
    }

    func testUnsupportedCodexControlsAreExplicitAndInterruptCompletesAsFailed() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeInterrupt")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.interrupt"),
            displayName: "Interrupt fixture",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let notices = NoticeCapture()
        RuntimeFixtureURLProtocol.configure { request in
            notices.record(request)
            guard request.url?.path == "/v1/models" else {
                return .eventStream(body: "data: [DONE]\n\n", delay: 500)
            }
            return .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
        }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: conversationStore,
            session: makeFixtureSession()
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))
        let eventTask = Task { () -> [AgentRuntimeEvent] in
            var result: [AgentRuntimeEvent] = []
            for await event in runtime.events {
                result.append(event)
                if case let .turnCompleted(threadID, _) = event, threadID == thread.id {
                    break
                }
            }
            return result
        }
        try await runtime.startTurn(
            StartTurnRequest(
                threadID: thread.id,
                inputs: [.text("interrupt")],
                sandboxMode: .readOnly,
                approvalPolicy: .never
            )
        )
        try await Task.sleep(for: .milliseconds(30))
        try await runtime.interrupt(threadID: thread.id)
        let events = await eventTask.value
        XCTAssertTrue(events.contains {
            if case let .runtimeNotice(title, _) = $0 { return title == "Provider controls unavailable" }
            return false
        })
        XCTAssertTrue(events.contains {
            if case let .turnCompleted(threadID, status) = $0 {
                return threadID == thread.id && status == .failed
            }
            return false
        })
    }

    func testRenameArchiveUnarchiveResumeAndDeleteAreLocallyDurable() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeControls")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.controls"),
            displayName: "Controls fixture",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { _ in
            .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
        }
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: conversationStore,
            session: makeFixtureSession()
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp/project"))

        try await runtime.renameThread(id: thread.id, name: "Renamed locally")
        let resumed = try await runtime.resumeThread(id: thread.id)
        XCTAssertEqual(resumed.thread.title, "Renamed locally")
        try await runtime.archiveThread(id: thread.id)
        let activeAfterArchive = try await runtime.listThreads(limit: 10, archived: false)
        let archived = try await runtime.listThreads(limit: 10, archived: true)
        XCTAssertTrue(activeAfterArchive.isEmpty)
        XCTAssertEqual(archived.map(\.id), [thread.id])
        try await runtime.unarchiveThread(id: thread.id)
        let activeAfterUnarchive = try await runtime.listThreads(limit: 10, archived: false)
        XCTAssertEqual(activeAfterUnarchive.map(\.id), [thread.id])
        try await runtime.deleteThread(id: thread.id)
        let activeAfterDelete = try await runtime.listThreads(limit: 10, archived: false)
        XCTAssertTrue(activeAfterDelete.isEmpty)
        do {
            _ = try await runtime.readThread(id: thread.id)
            XCTFail("Expected deleted conversation to be absent")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleRuntimeError,
                .conversationNotFound(thread.id)
            )
        }

        do {
            _ = try await runtime.forkThread(id: "anything")
            XCTFail("Expected unsupported fork")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not support thread forking"))
        }
        do {
            try await runtime.compactThread(id: "anything")
            XCTFail("Expected unsupported compaction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not support thread compaction"))
        }
    }

    func testConcurrentStartsReserveOneTurnAndPersistOneUserMessage() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeConcurrentStart")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.concurrent-start"),
            displayName: "Concurrent start fixture",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { request in
            if request.url?.path == "/v1/models" {
                return .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
            }
            return .eventStream(body: "data: [DONE]\n\n", delay: 500)
        }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: OpenAICompatibleConversationStore(
                fileURL: location.appendingPathComponent("conversations.json")
            ),
            session: makeFixtureSession()
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))
        let first = Task {
            try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "first"))
        }
        let second = Task {
            try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "second"))
        }
        let results = await [first.result, second.result]
        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(results.filter { result in
            guard case let .failure(error) = result else { return false }
            return error as? OpenAICompatibleRuntimeError == .activeTurn(thread.id)
        }.count, 1)

        await runtime.disconnect()
        let conversation = try await runtime.readThread(id: thread.id)
        XCTAssertEqual(
            conversation.items.filter { $0.kind == .userMessage }.count,
            1
        )
    }

    func testDisconnectInvalidatesTurnStartBeforeItsDurableWriteCommits() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeDisconnectStart")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try makeFixtureConnection(id: "fixture.disconnect-start")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { request in
            request.url?.path == "/v1/models"
                ? .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
                : .eventStream(body: "data: [DONE]\n\n")
        }
        let gate = PersistenceGate()
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json"),
            beforePersist: { _ in gate.waitIfArmed() }
        )
        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: conversationStore
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))

        gate.arm()
        let start = Task {
            try await runtime.startTurn(
                StartTurnRequest(threadID: thread.id, text: "disconnect during start")
            )
        }
        await gate.waitUntilEntered()
        await runtime.disconnect()
        gate.release()

        do {
            _ = try await start.value
            XCTFail("Expected startTurn to lose the connection boundary")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleRuntimeError, .notConnected)
        }

        let persisted = try await conversationStore.conversation(
            connectionID: connection.id,
            id: thread.id
        )
        XCTAssertEqual(persisted?.status, .idle)
        XCTAssertTrue(persisted?.messages.isEmpty == true)

        _ = try await runtime.connect()
        _ = await collectUntilTurnCompletion(runtime: runtime, threadID: thread.id) {
            try await runtime.startTurn(
                StartTurnRequest(threadID: thread.id, text: "retry after disconnect")
            )
        }
        let retried = try await conversationStore.conversation(
            connectionID: connection.id,
            id: thread.id
        )
        XCTAssertEqual(
            retried?.messages.filter { $0.role == .user }.map(\.text),
            ["retry after disconnect"]
        )
    }

    func testDisconnectFinalizesTurnWhenStreamingPersistenceIsInFlight() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeDisconnectStream")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try makeFixtureConnection(id: "fixture.disconnect-stream")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)

        let streamGate = StreamRequestGate()
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path != "/v1/models" else {
                return .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
            }
            streamGate.waitUntilReleased()
            return .eventStream(body: "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\\n\\ndata: [DONE]\\n\\n")
        }

        let persistenceGate = PersistenceGate()
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json"),
            beforePersist: { _ in persistenceGate.waitIfArmed() }
        )
        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: conversationStore
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))

        try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "disconnect while streaming"))
        await streamGate.waitUntilEntered()
        persistenceGate.arm()
        streamGate.release()
        await persistenceGate.waitUntilEntered()

        let disconnectedEvent = Task { () -> Bool in
            for await event in runtime.events {
                if case .connectionChanged(.disconnected) = event { return true }
            }
            return false
        }
        let disconnected = Task { await runtime.disconnect() }
        // `disconnect()` invalidates the generation and publishes its state
        // before waiting on the blocked persistence transaction.
        let didDisconnect = await disconnectedEvent.value
        XCTAssertTrue(didDisconnect)
        persistenceGate.release()
        await disconnected.value

        let persisted = try await conversationStore.conversation(
            connectionID: connection.id,
            id: thread.id
        )
        XCTAssertEqual(persisted?.status, .failed)
        XCTAssertFalse(persisted?.messages.contains(where: { $0.status == .running }) ?? true)
    }

    func testOldDisconnectCleanupCannotFailAReplacementTurnAfterReconnect() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeDisconnectReconnect")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try makeFixtureConnection(id: "fixture.disconnect-reconnect")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)

        let oldStreamGate = StreamRequestGate()
        let replacementStreamGate = StreamRequestGate()
        let requests = SequencedRequestCounter()
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path != "/v1/models" else {
                return .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
            }
            switch requests.next() {
            case 1:
                return .eventStream(body: "data: [DONE]\n\n", gate: oldStreamGate)
            case 2:
                return .eventStream(body: "data: [DONE]\n\n", gate: replacementStreamGate)
            default:
                return .eventStream(body: "data: [DONE]\n\n")
            }
        }

        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let cleanupGate = AsyncRuntimeGate()
        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: conversationStore,
            beforeDisconnectedTurnCleanup: { await cleanupGate.wait() }
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))
        try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "old turn"))
        await oldStreamGate.waitUntilEntered()

        let disconnect = Task { await runtime.disconnect() }
        await cleanupGate.waitUntilEntered()
        oldStreamGate.release()

        _ = try await runtime.connect()
        try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "replacement turn"))
        await replacementStreamGate.waitUntilEntered()

        await cleanupGate.release()
        await disconnect.value

        let persisted = try await conversationStore.conversation(
            connectionID: connection.id,
            id: thread.id
        )
        XCTAssertEqual(persisted?.status, .running)
        XCTAssertEqual(persisted?.messages.last?.status, .running)

        let replacementCompleted = Task { () -> Bool in
            for await event in runtime.events {
                if case let .turnCompleted(threadID, status) = event,
                   threadID == thread.id {
                    return status == .idle
                }
            }
            return false
        }
        replacementStreamGate.release()
        let didCompleteReplacement = await replacementCompleted.value
        XCTAssertTrue(didCompleteReplacement)
    }

    func testDeleteDuringStreamingCannotResurrectConversation() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeDeleteStream")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try makeFixtureConnection(id: "fixture.delete-stream")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let streamGate = StreamRequestGate()
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path != "/v1/models" else {
                return .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
            }
            streamGate.waitUntilReleased()
            return .eventStream(body: "data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\\n\\ndata: [DONE]\\n\\n")
        }
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: conversationStore
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))
        try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "delete me"))
        await streamGate.waitUntilEntered()

        try await runtime.deleteThread(id: thread.id)
        let deletedImmediately = try await conversationStore.conversation(
            connectionID: connection.id,
            id: thread.id
        )
        XCTAssertNil(deletedImmediately)

        streamGate.release()
        try await Task.sleep(for: .milliseconds(80))
        let deletedAfterLateStream = try await conversationStore.conversation(
            connectionID: connection.id,
            id: thread.id
        )
        XCTAssertNil(deletedAfterLateStream)
    }

    func testDisconnectDuringInterruptedTurnRecoveryCannotPublishConnected() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeRecoveryRace")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try makeFixtureConnection(id: "fixture.recovery-race")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { _ in
            .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
        }
        let gate = PersistenceGate()
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json"),
            beforePersist: { _ in gate.waitIfArmed() }
        )
        var running = try await conversationStore.create(
            connectionID: connection.id,
            title: "Interrupted",
            cwd: "/tmp",
            modelID: "fixture-model",
            scopeID: connection.conversationScopeID
        )
        running.status = .running
        running.messages = [OpenAICompatibleStoredMessage(
            role: .assistant,
            text: "partial",
            status: .running
        )]
        try await conversationStore.upsert(running)

        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: conversationStore
        )
        let events = Task { () -> [AgentRuntimeEvent] in
            var values: [AgentRuntimeEvent] = []
            for await event in runtime.events {
                values.append(event)
                if case .connectionChanged(.disconnected) = event { break }
            }
            return values
        }
        gate.arm()
        let connect = Task { try await runtime.connect() }
        await gate.waitUntilEntered()
        await runtime.disconnect()
        gate.release()

        do {
            _ = try await connect.value
            XCTFail("Expected stale connect to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError || error is URLError)
        }
        let recorded = await events.value
        XCTAssertFalse(recorded.contains {
            if case .connectionChanged(.connected) = $0 { return true }
            return false
        })
    }

    func testFinalPersistenceFailureClearsTurnReservationAndNextTurnRecoversStaleMarker() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimePersistFailure")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try makeFixtureConnection(id: "fixture.persist-failure")
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        RuntimeFixtureURLProtocol.configure { request in
            guard request.url?.path != "/v1/models" else {
                return .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
            }
            return .eventStream(body: "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"answer\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n")
        }
        let failures = FailingPersistence(failOnCall: 4)
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json"),
            beforePersist: { _ in try failures.check() }
        )
        let runtime = makeRuntime(
            connection: connection,
            connectionStore: connectionStore,
            conversationStore: conversationStore
        )
        _ = try await runtime.connect()
        let thread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp"))
        let events = Task { () -> [AgentRuntimeEvent] in
            var values: [AgentRuntimeEvent] = []
            for await event in runtime.events {
                values.append(event)
                if case let .turnCompleted(id, _) = event, id == thread.id { break }
            }
            return values
        }
        try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "persist failure"))
        let recorded = await events.value
        XCTAssertTrue(recorded.contains {
            if case let .turnCompleted(id, status) = $0 {
                return id == thread.id && status == .failed
            }
            return false
        })

        failures.disable()
        // This must not report `.activeTurn`: the failed final write cleared
        // the in-memory reservation and the stale disk marker is recoverable.
        let retryEvents = Task { () -> [AgentRuntimeEvent] in
            var values: [AgentRuntimeEvent] = []
            for await event in runtime.events {
                values.append(event)
                if case let .turnCompleted(id, _) = event, id == thread.id { break }
            }
            return values
        }
        try await runtime.startTurn(StartTurnRequest(threadID: thread.id, text: "retry"))
        let retryRecorded = await retryEvents.value
        XCTAssertTrue(retryRecorded.contains {
            if case let .turnCompleted(id, status) = $0 {
                return id == thread.id && status == .idle
            }
            return false
        })
    }

    func testRefreshRetriesDiscoveryWhenEndpointChangesInFlight() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeRefreshScope")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.refresh-scope"),
            displayName: "First endpoint",
            baseURL: URL(string: "https://first.example/v1")!,
            selectedModelID: "first-model",
            authMode: .none,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let gate = ModelDiscoveryGate()
        RuntimeFixtureURLProtocol.configure { request in
            switch request.url?.host {
            case "first.example":
                if gate.shouldBlockFirstRefresh() {
                    gate.waitUntilReleased()
                }
                return .json(body: "{\"data\":[{\"id\":\"first-model\"}]}")
            case "second.example":
                gate.recordSecondEndpointRequest()
                return .json(body: "{\"data\":[{\"id\":\"second-model\"}]}")
            default:
                return .json(body: "{\"data\":[]}")
            }
        }
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: conversationStore,
            session: makeFixtureSession()
        )
        _ = try await runtime.connect()
        let oldThread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp/old"))
        let oldScopeID = connection.conversationScopeID

        gate.arm()
        let refresh = Task { try await runtime.refreshAccount() }
        await gate.waitUntilEntered()
        _ = try await connectionStore.update(id: connection.id) { latest in
            latest.displayName = "Second endpoint"
            latest.baseURL = URL(string: "https://second.example/v1")!
            latest.selectedModelID = "second-model"
            latest.discovery = .init()
        }
        gate.release()

        let snapshot = try await refresh.value
        XCTAssertEqual(snapshot.displayName, "Second endpoint")
        XCTAssertEqual(snapshot.availableModels.map(\.id), ["second-model"])
        XCTAssertFalse(snapshot.availableModels.contains { $0.id == "first-model" })
        XCTAssertEqual(gate.secondEndpointRequests, 1)

        let storedConnection = try await connectionStore.connection(id: connection.id)
        let stored = try XCTUnwrap(storedConnection)
        XCTAssertEqual(stored.baseURL.host, "second.example")
        XCTAssertEqual(stored.discovery.discoveredModelIDs, ["second-model"])
        XCTAssertNotEqual(stored.conversationScopeID, oldScopeID)
        let currentThreads = try await runtime.listAllThreads(archived: false)
        XCTAssertTrue(currentThreads.isEmpty)
        do {
            _ = try await runtime.readThread(id: oldThread.id)
            XCTFail("Expected the first endpoint's task to be outside the new scope")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleRuntimeError,
                .conversationNotFound(oldThread.id)
            )
        }
        let preservedOldThread = try await conversationStore.conversation(
            connectionID: connection.id,
            id: oldThread.id
        )
        XCTAssertEqual(preservedOldThread?.conversationScopeID, oldScopeID)
        let newThread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp/new"))
        let persistedNewThread = try await conversationStore.conversation(
            connectionID: connection.id,
            id: newThread.id
        )
        XCTAssertEqual(persistedNewThread?.conversationScopeID, stored.conversationScopeID)
    }

    func testCredentialRotationCannotRestoreCatalogDiscoveredWithOldCredential() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeCredentialScope")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.credential-scope"),
            displayName: "Credential scope",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: nil,
            authMode: .bearer,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let credentials = InMemoryCredentialStore()
        try await credentials.setCredential(
            ProviderBearerCredential("credential-a"),
            for: connection.credentialKey
        )
        let gate = ModelDiscoveryGate()
        let authorizations = RequestAuthorizationSequenceCapture()
        gate.arm()
        RuntimeFixtureURLProtocol.configure { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            authorizations.record(authorization)
            switch authorization {
            case "Bearer credential-a":
                if gate.shouldBlockFirstRefresh() { gate.waitUntilReleased() }
                return .json(body: "{\"data\":[{\"id\":\"credential-a-model\"}]}")
            case "Bearer credential-b":
                return .json(body: "not valid model JSON")
            default:
                return .json(body: "{\"data\":[]}")
            }
        }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: credentials,
            conversationStore: OpenAICompatibleConversationStore(
                fileURL: location.appendingPathComponent("conversations.json")
            ),
            session: makeFixtureSession()
        )

        let connect = Task { try await runtime.connect() }
        await gate.waitUntilEntered()
        try await credentials.setCredential(
            ProviderBearerCredential("credential-b"),
            for: connection.credentialKey
        )
        gate.release()

        do {
            _ = try await connect.value
            XCTFail("Expected discovery with the replacement credential to fail")
        } catch {
            XCTAssertTrue(error is OpenAICompatibleRuntimeError)
        }
        XCTAssertEqual(authorizations.values, [
            "Bearer credential-a",
            "Bearer credential-b",
        ])
        let storedConnection = try await connectionStore.connection(id: connection.id)
        let stored = try XCTUnwrap(storedConnection)
        XCTAssertNotEqual(stored.conversationScopeID, connection.conversationScopeID)
        XCTAssertTrue(stored.discovery.discoveredModelIDs.isEmpty)
        XCTAssertFalse(stored.discovery.discoveredModels.contains {
            $0.id == "credential-a-model"
        })
    }

    func testCredentialRefreshFailureCannotReusePriorCredentialCatalog() async throws {
        let location = try makeTemporaryDirectory(
            prefix: "OpenAICompatibleRuntimeCredentialRefreshCatalog"
        )
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.credential-refresh-catalog"),
            displayName: "Credential refresh catalog",
            baseURL: URL(string: "https://provider.example/v1")!,
            authMode: .bearer,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let credentials = InMemoryCredentialStore()
        try await credentials.setCredential(
            ProviderBearerCredential("credential-a"),
            for: connection.credentialKey
        )
        RuntimeFixtureURLProtocol.configure { request in
            switch request.value(forHTTPHeaderField: "Authorization") {
            case "Bearer credential-a":
                return .json(body: "{\"data\":[{\"id\":\"credential-a-model\"}]}")
            case "Bearer credential-b":
                return .json(body: "not valid model JSON")
            default:
                return .json(body: "{\"data\":[]}")
            }
        }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: credentials,
            conversationStore: OpenAICompatibleConversationStore(
                fileURL: location.appendingPathComponent("conversations.json")
            ),
            session: makeFixtureSession()
        )

        let initial = try await runtime.connect()
        XCTAssertEqual(initial.availableModels.map(\.id), ["credential-a-model"])

        try await credentials.setCredential(
            ProviderBearerCredential("credential-b"),
            for: connection.credentialKey
        )
        do {
            _ = try await runtime.refreshAccount()
            XCTFail("Expected replacement-credential discovery to fail")
        } catch {
            XCTAssertTrue(error is OpenAICompatibleRuntimeError)
        }

        let storedConnection = try await connectionStore.connection(id: connection.id)
        let stored = try XCTUnwrap(storedConnection)
        XCTAssertNotEqual(stored.conversationScopeID, connection.conversationScopeID)
        XCTAssertTrue(stored.discovery.discoveredModelIDs.isEmpty)
        XCTAssertTrue(stored.discovery.discoveredModels.isEmpty)
    }

    func testCredentialRefreshRotatesConversationScopeAndRejectsOldHistory() async throws {
        let location = try makeTemporaryDirectory(prefix: "OpenAICompatibleRuntimeCredentialHistory")
        defer { try? FileManager.default.removeItem(at: location) }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("fixture.credential-history"),
            displayName: "Credential history",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .bearer,
            transportCapabilities: [.streaming]
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let credentials = InMemoryCredentialStore()
        try await credentials.setCredential(
            ProviderBearerCredential("credential-a"),
            for: connection.credentialKey
        )
        let requests = RequestPathSequenceCapture()
        RuntimeFixtureURLProtocol.configure { request in
            requests.record(request)
            if request.url?.path == "/v1/models" {
                return .json(body: "{\"data\":[{\"id\":\"fixture-model\"}]}")
            }
            return .eventStream(body: "data: [DONE]\n\n")
        }
        let conversationStore = OpenAICompatibleConversationStore(
            fileURL: location.appendingPathComponent("conversations.json")
        )
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: credentials,
            conversationStore: conversationStore,
            session: makeFixtureSession()
        )
        _ = try await runtime.connect()
        let oldThread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp/old"))

        try await credentials.setCredential(
            ProviderBearerCredential("credential-b"),
            for: connection.credentialKey
        )
        _ = try await runtime.refreshAccount()

        let refreshedConnection = try await connectionStore.connection(id: connection.id)
        let rotatedRecord = try XCTUnwrap(refreshedConnection)
        XCTAssertNotEqual(rotatedRecord.conversationScopeID, connection.conversationScopeID)
        do {
            try await runtime.startTurn(
                StartTurnRequest(threadID: oldThread.id, text: "do not send old history")
            )
            XCTFail("Expected the old credential's task to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenAICompatibleRuntimeError,
                .conversationNotFound(oldThread.id)
            )
        }
        XCTAssertFalse(
            requests.chatAuthorizationHeaders.contains("Bearer credential-b"),
            "An old-scope turn must be rejected before sending history with the replacement credential."
        )

        let newThread = try await runtime.startThread(StartThreadRequest(cwd: "/tmp/new"))
        let persistedNewThread = try await conversationStore.conversation(
            connectionID: connection.id,
            id: newThread.id
        )
        XCTAssertEqual(
            persistedNewThread?.conversationScopeID,
            rotatedRecord.conversationScopeID
        )
    }

    func testLiveModelDiscoveryAndStreamingIsOptIn() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ONYX_LIVE_OPENAI_COMPATIBLE_TEST"] == "1",
            "Set ONYX_LIVE_OPENAI_COMPATIBLE_TEST=1 to contact a configured OpenAI-compatible endpoint."
        )
        let environment = ProcessInfo.processInfo.environment
        guard let endpointString = environment["ONYX_LIVE_OPENAI_COMPATIBLE_URL"],
              let endpoint = URL(string: endpointString),
              let modelID = environment["ONYX_LIVE_OPENAI_COMPATIBLE_MODEL"],
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip(
                "Also set ONYX_LIVE_OPENAI_COMPATIBLE_URL and ONYX_LIVE_OPENAI_COMPATIBLE_MODEL for the live endpoint."
            )
        }
        let connection = try ProviderConnectionRecord(
            id: ProviderConnectionID("live.qwen"),
            displayName: "Configured OpenAI-compatible endpoint",
            baseURL: endpoint,
            selectedModelID: modelID,
            authMode: .none,
            transportSecurity: .allowInsecureHTTP,
            transportCapabilities: [.streaming],
            requestBehavior: .init(enableThinking: false)
        )
        let connectionStore = ProviderConnectionStore(storage: InMemoryProviderConnectionStorage())
        try await connectionStore.upsert(connection)
        let location = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxLiveQwen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: location) }
        let runtime = OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: OpenAICompatibleConversationStore(fileURL: location)
        )
        let snapshot = try await runtime.connect()
        XCTAssertTrue(snapshot.availableModels.contains { $0.id == connection.selectedModelID })
        let thread = try await runtime.startThread(StartThreadRequest(cwd: FileManager.default.currentDirectoryPath))
        let eventTask = Task { () -> String in
            var answer = ""
            for await event in runtime.events {
                switch event {
                case let .itemDelta(threadID, _, delta) where threadID == thread.id:
                    answer += delta
                case let .turnCompleted(threadID, _) where threadID == thread.id:
                    return answer
                default:
                    break
                }
            }
            return answer
        }
        try await runtime.startTurn(
            StartTurnRequest(
                threadID: thread.id,
                inputs: [.text("Reply with the exact token ONYX_QWEN_LIVE_OK")]
            )
        )
        let answer = await eventTask.value
        XCTAssertTrue(
            answer.contains("ONYX_QWEN_LIVE_OK"),
            "Expected exact live marker in streamed answer, got: \(answer)"
        )
    }

    private func collectUntilTurnCompletion(
        runtime: OpenAICompatibleRuntime,
        threadID: String,
        start: () async throws -> Void
    ) async -> [AgentRuntimeEvent] {
        let task = Task { () -> [AgentRuntimeEvent] in
            var events: [AgentRuntimeEvent] = []
            for await event in runtime.events {
                events.append(event)
                if case let .turnCompleted(id, _) = event, id == threadID { break }
            }
            return events
        }
        do {
            try await start()
        } catch {
            task.cancel()
            return await task.value
        }
        return await task.value
    }

    private func makeFixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeFixtureConnection(id: String) throws -> ProviderConnectionRecord {
        try ProviderConnectionRecord(
            id: ProviderConnectionID(id),
            displayName: "Fixture provider",
            baseURL: URL(string: "https://provider.example/v1")!,
            selectedModelID: "fixture-model",
            authMode: .none,
            transportCapabilities: [.streaming]
        )
    }

    private func makeRuntime(
        connection: ProviderConnectionRecord,
        connectionStore: ProviderConnectionStore,
        conversationStore: OpenAICompatibleConversationStore,
        beforeDisconnectedTurnCleanup: (@Sendable () async -> Void)? = nil
    ) -> OpenAICompatibleRuntime {
        OpenAICompatibleRuntime(
            connectionID: connection.id,
            connectionStore: connectionStore,
            credentialStore: InMemoryCredentialStore(),
            conversationStore: conversationStore,
            session: makeFixtureSession(),
            beforeDisconnectedTurnCleanup: beforeDisconnectedTurnCleanup
        )
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class PersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var isArmed = false
    private var didEnter = false

    func arm() {
        lock.withLock { isArmed = true }
    }

    func waitIfArmed() {
        let shouldWait = lock.withLock { () -> Bool in
            guard isArmed, !didEnter else { return false }
            didEnter = true
            return true
        }
        guard shouldWait else { return }
        entered.signal()
        releaseSemaphore.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.withLock { isArmed = false }
        releaseSemaphore.signal()
    }
}

private final class StreamRequestGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func waitUntilReleased() {
        entered.signal()
        releaseSemaphore.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class SequencedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private actor AsyncRuntimeGate {
    private var isOpen = false
    private var hasEntered = false
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        for continuation in entryContinuations { continuation.resume() }
        entryContinuations.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryContinuations.append(continuation)
        }
    }

    func release() {
        isOpen = true
        waitContinuation?.resume()
        waitContinuation = nil
    }
}

private final class ModelDiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var didBlock = false
    private var secondRequests = 0

    var secondEndpointRequests: Int { lock.withLock { secondRequests } }

    func arm() {
        lock.withLock { armed = true }
    }

    func shouldBlockFirstRefresh() -> Bool {
        lock.withLock {
            guard armed, !didBlock else { return false }
            didBlock = true
            return true
        }
    }

    func waitUntilReleased() {
        entered.signal()
        releaseSemaphore.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }

    func recordSecondEndpointRequest() {
        lock.withLock { secondRequests += 1 }
    }
}

private final class FailingPersistence: @unchecked Sendable {
    private let lock = NSLock()
    private let failOnCall: Int
    private var callCount = 0
    private var enabled = true

    init(failOnCall: Int) {
        self.failOnCall = failOnCall
    }

    func check() throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard enabled else { return false }
            callCount += 1
            return callCount == failOnCall
        }
        if shouldFail {
            throw NSError(
                domain: "OpenAICompatibleRuntimeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "simulated persistence failure"]
            )
        }
    }

    func disable() {
        lock.withLock { enabled = false }
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var data: Data?

    var authorization: String? {
        lock.withLock { request?.value(forHTTPHeaderField: "Authorization") }
    }

    var path: String? { lock.withLock { request?.url?.path } }

    var body: Data? { lock.withLock { data } }

    func record(_ request: URLRequest) {
        let body = request.httpBody
        lock.withLock {
            self.request = request
            self.data = body
        }
    }
}

private final class RequestBodySequenceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    var bodies: [Data] { lock.withLock { values } }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        guard let body else { return }
        lock.withLock { values.append(body) }
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class RequestAuthorizationSequenceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String?] = []

    var values: [String?] { lock.withLock { recorded } }

    func record(_ authorization: String?) {
        lock.withLock { recorded.append(authorization) }
    }
}

private final class RequestPathSequenceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var pathsAndAuthorizations: [(String?, String?)] = []

    var chatAuthorizationHeaders: [String?] {
        lock.withLock {
            pathsAndAuthorizations.compactMap { path, authorization in
                path == "/v1/chat/completions" ? authorization : nil
            }
        }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            pathsAndAuthorizations.append((
                request.url?.path,
                request.value(forHTTPHeaderField: "Authorization")
            ))
        }
    }
}

private final class NoticeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class RuntimeFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: @unchecked Sendable {
        let statusCode: Int
        let contentType: String
        let body: Data
        let finishes: Bool

        let delayMilliseconds: Int
        let gate: StreamRequestGate?

        static func json(body: String, delay: Int = 0) -> Self {
            Self(
                statusCode: 200,
                contentType: "application/json",
                body: Data(body.utf8),
                finishes: true,
                delayMilliseconds: delay,
                gate: nil
            )
        }

        static func eventStream(
            body: String,
            delay: Int = 0,
            gate: StreamRequestGate? = nil
        ) -> Self {
            Self(
                statusCode: 200,
                contentType: "text/event-stream",
                body: Data(body.utf8),
                finishes: true,
                delayMilliseconds: delay,
                gate: gate
            )
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Stub
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func configure(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": stub.contentType]
        )!
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !stub.body.isEmpty { self.client?.urlProtocol(self, didLoad: stub.body) }
            if stub.finishes { self.client?.urlProtocolDidFinishLoading(self) }
        }
        if let gate = stub.gate {
            DispatchQueue.global().async {
                gate.waitUntilReleased()
                deliver()
            }
        } else if stub.delayMilliseconds > 0 {
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(stub.delayMilliseconds),
                execute: deliver
            )
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}
