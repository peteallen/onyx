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

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

        static func json(body: String, delay: Int = 0) -> Self {
            Self(statusCode: 200, contentType: "application/json", body: Data(body.utf8), finishes: true, delayMilliseconds: delay)
        }

        static func eventStream(body: String, delay: Int = 0) -> Self {
            Self(statusCode: 200, contentType: "text/event-stream", body: Data(body.utf8), finishes: true, delayMilliseconds: delay)
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
        if stub.delayMilliseconds > 0 {
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
