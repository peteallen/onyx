import Foundation

struct AppServerNotification: Sendable, Equatable {
    let method: String
    let params: JSONValue
}

struct AppServerRequest: Sendable, Equatable {
    let id: RuntimeRequestID
    let method: String
    let params: JSONValue
}

struct AppServerConnection: Sendable, Equatable {
    let generation: UInt64
    let initializeResponse: JSONValue
}

enum AppServerEvent: Sendable, Equatable {
    case notification(generation: UInt64, AppServerNotification)
    case request(generation: UInt64, AppServerRequest)
    case stderr(generation: UInt64, String)
    case stopped(generation: UInt64, String)
}

protocol CodexAppServerTransport: Sendable {
    var events: AsyncStream<AppServerEvent> { get }

    func start() async throws -> AppServerConnection
    func stop() async
    func request(method: String, params: JSONValue) async throws -> JSONValue
    func respond(id: RuntimeRequestID, result: JSONValue) async throws
    func respondError(id: RuntimeRequestID, code: Int, message: String) async throws
}

extension CodexAppServerTransport {
    func respondError(id _: RuntimeRequestID, code _: Int, message _: String) async throws {
        throw AgentRuntimeError.unsupported("JSON-RPC error responses")
    }
}

private struct OutgoingRequest: Encodable {
    let method: String
    let id: Int
    let params: JSONValue
}

private struct OutgoingNotification: Encodable {
    let method: String
    let params: JSONValue
}

private struct OutgoingResponse: Encodable {
    let id: JSONValue
    let result: JSONValue
}

private struct OutgoingErrorResponse: Encodable {
    struct ErrorBody: Encodable {
        let code: Int
        let message: String
    }

    let id: JSONValue
    let error: ErrorBody
}

enum CodexAppServerHandshake {
    static let initializeParams = JSONValue.object([
        "clientInfo": .object([
            "name": .string("onyx"),
            "title": .string("Onyx"),
            "version": .string("0.1.3"),
        ]),
        "capabilities": .object([
            // `item/tool/requestUserInput` and the richer approval fields that
            // Onyx handles are gated behind this app-server capability.
            "experimentalApi": .bool(true),
        ]),
    ])
}

/// Bridges the process termination callback to the actor without waiting for
/// the actor hop. Stdout EOF and `Process.terminationHandler` are delivered
/// independently, so the callback must publish its status synchronously; the
/// actor task that reports the stopped event can arrive later.
private final class ProcessTerminationObserver: @unchecked Sendable {
    private let statusLock = NSLock()
    private let stream: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation
    private var status: Int32?

    init() {
        let stream = AsyncStream.makeStream(
            of: Int32.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream.stream
        continuation = stream.continuation
    }

    func record(_ status: Int32) {
        statusLock.lock()
        defer { statusLock.unlock() }
        self.status = status
        continuation.yield(status)
        continuation.finish()
    }

    var recordedStatus: Int32? {
        statusLock.lock()
        defer { statusLock.unlock() }
        return status
    }

    func finish() {
        statusLock.lock()
        defer { statusLock.unlock() }
        continuation.finish()
    }

    func wait(for timeout: Duration) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask { [stream] in
                for await status in stream {
                    return status
                }
                return nil
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return nil
                }
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

actor CodexAppServerClient: CodexAppServerTransport {
    nonisolated let events: AsyncStream<AppServerEvent>

    private let eventContinuation: AsyncStream<AppServerEvent>.Continuation
    private let executableURL: URL
    private let processArguments: [String]
    private let processEnvironment: [String: String]?
    private let stateDirectoryPreparation: (@Sendable () throws -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    /// A stdout EOF can arrive just before `Process.terminationHandler` runs.
    /// Keep the connection alive briefly so the termination status wins that
    /// race; `finishStreamEnd` still provides a bounded protocol fallback for
    /// a server that closes stdout while remaining alive.
    private var streamEndTask: Task<Void, Never>?
    private var terminationObserver: ProcessTerminationObserver?
    private var outputFramer = JSONLFramer()
    private var errorFramer = JSONLFramer(maximumRecordBytes: 8 * 1_024 * 1_024)
    private var nextRequestID = 1
    private var nextConnectionGeneration: UInt64 = 0
    private var activeConnectionGeneration: UInt64?
    private var pending: [Int: PendingRequest] = [:]

    /// Process termination is normally delivered immediately after stdout
    /// closes, but the two callbacks are independent.  This short grace
    /// period avoids classifying a normal process exit as a protocol failure.
    /// Keep this comfortably above stdout/termination callback scheduling
    /// jitter seen on slower CI runners. A one-second upper bound still makes
    /// a live server's broken transport fail promptly without misclassifying
    /// a legitimate process exit as a protocol failure.
    private static let streamEndGracePeriod: Duration = .seconds(1)

    private struct PendingRequest {
        let connectionGeneration: UInt64
        let method: String
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timeoutTask: Task<Void, Never>
    }

    init(
        executableURL: URL,
        processArguments: [String] = ["app-server", "--listen", "stdio://"],
        processEnvironment: [String: String]? = nil,
        stateDirectoryPreparation: (@Sendable () throws -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.processArguments = processArguments
        self.processEnvironment = processEnvironment
        self.stateDirectoryPreparation = stateDirectoryPreparation
        let stream = AsyncStream.makeStream(of: AppServerEvent.self)
        events = stream.stream
        eventContinuation = stream.continuation
    }

    deinit {
        outputTask?.cancel()
        errorTask?.cancel()
        streamEndTask?.cancel()
        terminationObserver?.finish()
        process?.terminate()
        eventContinuation.finish()
    }

    func start() async throws -> AppServerConnection {
        if process?.isRunning == true, activeConnectionGeneration != nil {
            guard let generation = activeConnectionGeneration else {
                throw AgentRuntimeError.protocolFailure("app-server connection has no generation")
            }
            return AppServerConnection(generation: generation, initializeResponse: .object([:]))
        }

        if let generation = activeConnectionGeneration {
            closeConnection(
                generation: generation,
                pendingError: AgentRuntimeError.protocolFailure("Replacing a stopped app-server connection")
            )
        }

        try stateDirectoryPreparation?()

        nextConnectionGeneration &+= 1
        let generation = nextConnectionGeneration
        activeConnectionGeneration = generation
        outputFramer.reset()
        errorFramer.reset()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        let terminationObserver = ProcessTerminationObserver()
        process.executableURL = executableURL
        process.arguments = processArguments
        process.environment = processEnvironment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self, terminationObserver] process in
            let status = process.terminationStatus
            terminationObserver.record(status)
            Task { [weak self] in
                await self?.processExited(status: status, generation: generation)
            }
        }

        do {
            try process.run()
        } catch {
            activeConnectionGeneration = nil
            terminationObserver.finish()
            throw error
        }
        self.process = process
        self.terminationObserver = terminationObserver
        input = stdinPipe.fileHandleForWriting

        let output = stdoutPipe.fileHandleForReading
        outputHandle = output
        let outputStream = AsyncStream.makeStream(of: Data.self)
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outputStream.continuation.finish()
            } else {
                outputStream.continuation.yield(data)
            }
        }
        outputTask = Task.detached(priority: .userInitiated) { [weak self, stream = outputStream.stream] in
            for await data in stream {
                await self?.consumeOutput(data, generation: generation)
            }
            await self?.streamEnded(
                generation: generation,
                reason: "Codex app-server closed its output stream."
            )
        }

        let errors = stderrPipe.fileHandleForReading
        errorHandle = errors
        let errorStream = AsyncStream.makeStream(of: Data.self)
        errors.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                errorStream.continuation.finish()
            } else {
                errorStream.continuation.yield(data)
            }
        }
        errorTask = Task.detached(priority: .utility) { [weak self, stream = errorStream.stream] in
            for await data in stream {
                await self?.consumeError(data, generation: generation)
            }
        }

        do {
            let initialize = try await request(
                method: "initialize",
                params: CodexAppServerHandshake.initializeParams
            )
            try notify(method: "initialized", params: .object([:]))
            return AppServerConnection(generation: generation, initializeResponse: initialize)
        } catch {
            closeConnection(generation: generation, pendingError: error)
            throw error
        }
    }

    func stop() async {
        guard let generation = activeConnectionGeneration else { return }
        closeConnection(
            generation: generation,
            pendingError: AgentRuntimeError.protocolFailure("Connection closed")
        )
    }

    func request(method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard process?.isRunning == true, let connectionGeneration = activeConnectionGeneration else {
            throw AgentRuntimeError.protocolFailure("app-server is not running")
        }

        let id = nextRequestID
        nextRequestID += 1
        let message = OutgoingRequest(method: method, id: id, params: params)
        try write(message)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.expireRequest(id: id, method: method)
            }
            pending[id] = PendingRequest(
                connectionGeneration: connectionGeneration,
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
        }
    }

    func notify(method: String, params: JSONValue = .object([:])) throws {
        try write(OutgoingNotification(method: method, params: params))
    }

    func respond(id: RuntimeRequestID, result: JSONValue) async throws {
        let wireID = wireID(from: id)
        try write(OutgoingResponse(id: wireID, result: result))
    }

    func respondError(id: RuntimeRequestID, code: Int, message: String) async throws {
        try write(
            OutgoingErrorResponse(
                id: wireID(from: id),
                error: .init(code: code, message: message)
            )
        )
    }

    private func write(_ message: some Encodable) throws {
        guard let input else {
            throw AgentRuntimeError.protocolFailure("app-server input is unavailable")
        }

        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func consumeOutput(_ data: Data, generation: UInt64) {
        guard activeConnectionGeneration == generation else { return }
        do {
            for line in try outputFramer.append(data) {
                receive(line, generation: generation)
            }
        } catch {
            closeMalformedTransport(error, generation: generation)
        }
    }

    private func consumeError(_ data: Data, generation: UInt64) {
        guard activeConnectionGeneration == generation else { return }
        do {
            for line in try errorFramer.append(data) where !line.isEmpty {
                eventContinuation.yield(.stderr(generation: generation, String(decoding: line, as: UTF8.self)))
            }
        } catch {
            closeMalformedTransport(error, generation: generation)
        }
    }

    private func closeMalformedTransport(_ error: any Error, generation: UInt64) {
        guard activeConnectionGeneration == generation else { return }
        let message = "app-server transport failed: \(error.localizedDescription)"
        closeConnection(
            generation: generation,
            pendingError: AgentRuntimeError.protocolFailure(message)
        )
        eventContinuation.yield(.stopped(generation: generation, message))
    }

    private func receive(_ line: Data, generation: UInt64) {
        guard activeConnectionGeneration == generation else { return }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: line)
            guard let object = value.objectValue else {
                throw AgentRuntimeError.protocolFailure("Received a non-object JSON-RPC message")
            }

            if let method = object["method"]?.stringValue {
                let params = object["params"] ?? .object([:])
                if let id = requestID(from: object["id"]) {
                    eventContinuation.yield(
                        .request(generation: generation, .init(id: id, method: method, params: params))
                    )
                } else {
                    eventContinuation.yield(
                        .notification(generation: generation, .init(method: method, params: params))
                    )
                }
                return
            }

            guard let id = object["id"]?.intValue,
                  let request = pending[id],
                  request.connectionGeneration == generation else {
                return
            }
            pending.removeValue(forKey: id)
            request.timeoutTask.cancel()

            if let error = object["error"] {
                request.continuation.resume(
                    throwing: AgentRuntimeError.requestFailed(
                        code: error["code"]?.intValue ?? -1,
                        message: error["message"]?.stringValue ?? error.compactDescription
                    )
                )
            } else if let result = object["result"] {
                request.continuation.resume(returning: result)
            } else {
                request.continuation.resume(
                    throwing: AgentRuntimeError.protocolFailure(
                        "app-server response to \(request.method) contained neither result nor error"
                    )
                )
            }
        } catch {
            // Stdout is protocol-only. A corrupt record may have been the sole
            // response to any pending ID, so continuing would strand callers
            // until their timeout instead of exposing a reconnectable failure.
            closeMalformedTransport(error, generation: generation)
        }
    }

    private func streamEnded(generation: UInt64, reason: String) {
        guard activeConnectionGeneration == generation else { return }

        // stdout EOF and Process.terminationHandler can be delivered in
        // either order. Defer the protocol-failure decision long enough for
        // the termination handler to provide the real exit status, while
        // retaining a bounded fallback for a live server.
        streamEndTask?.cancel()
        let terminationObserver = self.terminationObserver
        streamEndTask = Task { [weak self, terminationObserver] in
            let status = await terminationObserver?.wait(for: Self.streamEndGracePeriod)
            guard !Task.isCancelled else { return }
            await self?.finishStreamEnd(
                generation: generation,
                reason: reason,
                terminationStatus: status
            )
        }
    }

    private func finishStreamEnd(
        generation: UInt64,
        reason: String,
        terminationStatus: Int32?
    ) {
        guard activeConnectionGeneration == generation else { return }
        streamEndTask = nil

        if let terminationStatus = terminationStatus ?? terminationObserver?.recordedStatus {
            processExited(status: terminationStatus, generation: generation)
            return
        }
        if let process, !process.isRunning {
            processExited(status: process.terminationStatus, generation: generation)
            return
        }
        closeConnection(
            generation: generation,
            pendingError: AgentRuntimeError.protocolFailure(reason)
        )
        eventContinuation.yield(.stopped(generation: generation, reason))
    }

    private func processExited(status: Int32, generation: UInt64) {
        guard activeConnectionGeneration == generation else { return }
        let error = AgentRuntimeError.processExited(status)
        let reason = error.localizedDescription
        closeConnection(generation: generation, pendingError: error)
        eventContinuation.yield(.stopped(generation: generation, reason))
    }

    private func publish(_ event: AppServerEvent) {
        eventContinuation.yield(event)
    }

    private func expireRequest(id: Int, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(
            throwing: AgentRuntimeError.protocolFailure("\(method) timed out after 15 seconds")
        )
    }

    private func closeConnection(generation: UInt64, pendingError: any Error) {
        guard activeConnectionGeneration == generation else { return }
        activeConnectionGeneration = nil

        outputTask?.cancel()
        errorTask?.cancel()
        streamEndTask?.cancel()
        terminationObserver?.finish()
        outputTask = nil
        errorTask = nil
        streamEndTask = nil
        terminationObserver = nil

        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        input?.closeFile()
        outputHandle?.closeFile()
        errorHandle?.closeFile()
        input = nil
        outputHandle = nil
        errorHandle = nil

        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        outputFramer.reset()
        errorFramer.reset()

        let requestIDs = pending.compactMap { id, request in
            request.connectionGeneration == generation ? id : nil
        }
        for id in requestIDs {
            guard let request = pending.removeValue(forKey: id) else { continue }
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: pendingError)
        }
    }

    private func requestID(from value: JSONValue?) -> RuntimeRequestID? {
        guard let value else { return nil }
        switch value {
        case let .integer(id): return .integer(id)
        case let .string(id): return .string(id)
        default: return nil
        }
    }

    private func wireID(from id: RuntimeRequestID) -> JSONValue {
        switch id {
        case let .integer(value): .integer(value)
        case let .string(value): .string(value)
        }
    }
}

/// Incremental newline framing for app-server's JSONL transport. The scan
/// cursor only advances through newly appended bytes, so a multi-megabyte
/// `thread/read` response is inspected once instead of once per pipe chunk.
enum JSONLFramerError: LocalizedError, Equatable {
    case recordTooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case let .recordTooLarge(limit):
            "A JSONL record exceeded the \(limit)-byte transport limit."
        }
    }
}

struct JSONLFramer {
    static let defaultMaximumRecordBytes = 128 * 1_024 * 1_024

    private(set) var bytesInspected = 0
    let maximumRecordBytes: Int
    private var buffer = Data()
    private var scanOffset = 0

    init(maximumRecordBytes: Int = Self.defaultMaximumRecordBytes) {
        precondition(maximumRecordBytes > 0)
        self.maximumRecordBytes = maximumRecordBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var lineStart = 0
        var index = scanOffset

        while index < buffer.count {
            bytesInspected += 1
            if buffer[index] == 0x0A {
                lines.append(Data(buffer[lineStart..<index]))
                lineStart = index + 1
            } else if index - lineStart + 1 > maximumRecordBytes {
                buffer.removeAll(keepingCapacity: false)
                scanOffset = 0
                throw JSONLFramerError.recordTooLarge(limit: maximumRecordBytes)
            }
            index += 1
        }

        if lineStart > 0 {
            buffer.removeSubrange(0..<lineStart)
            scanOffset = buffer.count
        } else {
            scanOffset = index
        }
        return lines
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        scanOffset = 0
        bytesInspected = 0
    }
}
