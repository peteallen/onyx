import Foundation
import Network

/// A launch-scoped credential boundary between Codex app-server and an
/// OpenAI-compatible Responses endpoint. The listener accepts only literal
/// IPv4 loopback clients, requires one disposable bearer token, forwards only
/// `POST /v1/responses`, and injects the configured provider credential on the
/// outbound request.
actor OpenAICompatibleResponsesProxy {
    struct Limits: Sendable, Equatable {
        let maximumHeaderBytes: Int
        let maximumRequestBodyBytes: Int
        /// Maximum serialized byte size of the upstream HTTP response head.
        /// This is enforced before any provider header is exposed to
        /// app-server, including headers that would otherwise be filtered.
        let maximumUpstreamResponseHeaderBytes: Int
        let maximumResponseBytes: Int
        let maximumConcurrentConnections: Int
        let clientRequestTimeout: TimeInterval
        let requestTimeout: TimeInterval
        let resourceTimeout: TimeInterval

        init(
            maximumHeaderBytes: Int = 32 * 1_024,
            maximumRequestBodyBytes: Int = 16 * 1_024 * 1_024,
            maximumUpstreamResponseHeaderBytes: Int = 32 * 1_024,
            maximumResponseBytes: Int = 64 * 1_024 * 1_024,
            maximumConcurrentConnections: Int = 16,
            clientRequestTimeout: TimeInterval = 10,
            requestTimeout: TimeInterval = 120,
            resourceTimeout: TimeInterval = 3_600
        ) {
            self.maximumHeaderBytes = max(1_024, maximumHeaderBytes)
            self.maximumRequestBodyBytes = max(1_024, maximumRequestBodyBytes)
            self.maximumUpstreamResponseHeaderBytes = max(
                1_024,
                maximumUpstreamResponseHeaderBytes
            )
            self.maximumResponseBytes = max(1_024, maximumResponseBytes)
            self.maximumConcurrentConnections = max(1, maximumConcurrentConnections)
            self.clientRequestTimeout = max(0.05, clientRequestTimeout)
            self.requestTimeout = max(1, requestTimeout)
            self.resourceTimeout = max(self.requestTimeout, resourceTimeout)
        }

        static let `default` = Limits()
    }

    struct LaunchBinding: Sendable, Equatable {
        let baseURL: URL
        let bearerToken: String
    }

    private enum ProxyError: Error, Equatable {
        case invalidConfiguration
        case invalidRequest
        case requestTooLarge
        case unauthorized
        case unsupportedRoute
        case unsupportedContentEncoding
        case unsupportedUpstreamContentEncoding
        case upstreamFailure
        case upstreamResponseHeadersTooLarge
        case upstreamResponseTooLarge
    }

    private struct HTTPRequestHead: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let bodyPrefix: Data
    }

    private struct UpstreamResponseHead: Sendable {
        let statusCode: Int
        let headers: [(String, String)]
    }

    private let upstreamURL: URL
    private let upstreamCredential: String?
    private let disposableToken: String
    private let limits: Limits
    private let session: URLSession
    private var listener: NWListener?
    private var binding: LaunchBinding?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    init(
        connection: ProviderConnectionRecord,
        upstreamCredential: ProviderBearerCredential?,
        disposableToken: String = OpenAICompatibleResponsesProxy.makeDisposableToken(),
        session: URLSession? = nil,
        limits: Limits = .default
    ) throws {
        guard let responsesURL = OpenAICompatibleResponsesCompatibilityProbe.responsesURL(
            from: connection.baseURL
        ), responsesURL.scheme?.lowercased() == "https"
            || (responsesURL.scheme?.lowercased() == "http"
                && connection.transportSecurity == .allowInsecureHTTP
                && responsesURL.host.map(ProviderBaseURLNormalizer.isAllowedInsecureHTTPHost) == true)
        else {
            throw ProxyError.invalidConfiguration
        }

        let credential = try upstreamCredential?.withValue { raw in
            guard !raw.isEmpty,
                  !raw.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw ProxyError.invalidConfiguration
            }
            return raw
        }
        if connection.authMode == .bearer, credential == nil {
            throw ProxyError.invalidConfiguration
        }
        guard !disposableToken.isEmpty,
              !disposableToken.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw ProxyError.invalidConfiguration
        }

        upstreamURL = responsesURL
        self.upstreamCredential = credential
        self.disposableToken = disposableToken
        self.limits = limits

        let baseSession = session ?? Self.makeDefaultSession(limits: limits)
        self.session = URLSession(
            configuration: baseSession.configuration,
            delegate: ResponsesProxyNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        listener?.cancel()
        session.invalidateAndCancel()
        for task in connectionTasks.values { task.cancel() }
    }

    func start() async throws -> LaunchBinding {
        if let binding { return binding }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let queue = DispatchQueue(label: "app.onyx.responses-proxy.listener")
        let port = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
                let resolver = ListenerStartResolver(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            resolver.fail(ProxyError.invalidConfiguration)
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
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }

        self.listener = listener
        let binding = LaunchBinding(
            baseURL: URL(string: "http://127.0.0.1:\(port.rawValue)/v1")!,
            bearerToken: disposableToken
        )
        self.binding = binding
        return binding
    }

    func stop() {
        listener?.cancel()
        listener = nil
        binding = nil
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        session.invalidateAndCancel()
    }

    private func accept(_ connection: NWConnection) {
        guard connectionTasks.count < limits.maximumConcurrentConnections else {
            // The listener is private loopback infrastructure, not a general
            // local HTTP server. Bound unauthenticated sockets before giving
            // each one a task, so a slow local process cannot exhaust the app.
            connection.cancel()
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handle(connection, id: id)
        }
        connectionTasks[id] = task
    }

    private func handle(_ connection: NWConnection, id: UUID) async {
        defer {
            connection.cancel()
            connectionTasks[id] = nil
        }
        guard Self.isLiteralIPv4Loopback(connection.endpoint) else {
            connection.cancel()
            return
        }

        do {
            try await Self.start(connection)
            let body = try await readValidatedRequestBody(from: connection)
            try await forwardWhileMonitoringClient(body: body, to: connection)
        } catch is CancellationError {
            connection.cancel()
        } catch let error as ProxyError {
            try? await sendFailure(error, to: connection)
        } catch {
            try? await sendFailure(.upstreamFailure, to: connection)
        }
    }

    private func readValidatedRequestBody(from connection: NWConnection) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let request = try await self.readRequest(from: connection)
                try await self.validate(request)
                return try await self.readRequestBody(request, from: connection)
            }
            group.addTask {
                let nanoseconds = UInt64(
                    min(self.limits.clientRequestTimeout, 86_400) * 1_000_000_000
                )
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ProxyError.invalidRequest
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ProxyError.invalidRequest
            }
            return first
        }
    }

    private func readRequest(from connection: NWConnection) async throws -> HTTPRequestHead {
        var buffer = Data()
        while true {
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound <= limits.maximumHeaderBytes else {
                    throw ProxyError.requestTooLarge
                }
                let headerData = buffer[..<boundary.lowerBound]
                let bodyStart = boundary.upperBound
                guard let text = String(data: headerData, encoding: .utf8) else {
                    throw ProxyError.invalidRequest
                }
                let lines = text.components(separatedBy: "\r\n")
                guard let requestLine = lines.first else { throw ProxyError.invalidRequest }
                let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[2] == "HTTP/1.1" else {
                    throw ProxyError.invalidRequest
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else {
                        throw ProxyError.invalidRequest
                    }
                    let name = line[..<colon]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, headers[name] == nil else {
                        throw ProxyError.invalidRequest
                    }
                    headers[name] = value
                }
                return HTTPRequestHead(
                    method: String(parts[0]),
                    target: String(parts[1]),
                    headers: headers,
                    bodyPrefix: Data(buffer[bodyStart...])
                )
            }
            guard buffer.count <= limits.maximumHeaderBytes else {
                throw ProxyError.requestTooLarge
            }
            guard let chunk = try await Self.receive(from: connection), !chunk.isEmpty else {
                throw ProxyError.invalidRequest
            }
            buffer.append(chunk)
        }
    }

    private func validate(_ request: HTTPRequestHead) throws {
        let expectedHost = binding?.baseURL.host.map { host in
            if let port = binding?.baseURL.port { return "\(host):\(port)" }
            return host
        }
        let rawLength = request.headers["content-length"]
        let lengthIsCanonical = rawLength?.allSatisfy(\.isNumber) == true
        guard request.method == "POST",
              request.target == "/v1/responses",
              request.headers["host"]?.lowercased() == expectedHost?.lowercased(),
              request.headers["content-type"]?.lowercased()
                .split(separator: ";").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "application/json",
              request.headers["transfer-encoding"] == nil,
              request.headers["expect"] == nil,
              Self.isIdentityContentEncoding(request.headers["content-encoding"]),
              request.headers["connection"]?.lowercased() != "upgrade",
              lengthIsCanonical,
              let contentLength = rawLength,
              let count = Int(contentLength), count >= 0,
              count <= limits.maximumRequestBodyBytes,
              request.headers["authorization"] == "Bearer \(disposableToken)"
        else {
            if request.headers["authorization"] != "Bearer \(disposableToken)" {
                throw ProxyError.unauthorized
            }
            if let raw = request.headers["content-length"],
               Int(raw).map({ $0 > limits.maximumRequestBodyBytes }) == true {
                throw ProxyError.requestTooLarge
            }
            if !Self.isIdentityContentEncoding(request.headers["content-encoding"]) {
                throw ProxyError.unsupportedContentEncoding
            }
            throw ProxyError.unsupportedRoute
        }
    }

    private func readRequestBody(
        _ request: HTTPRequestHead,
        from connection: NWConnection
    ) async throws -> Data {
        guard let rawLength = request.headers["content-length"],
              let length = Int(rawLength),
              request.bodyPrefix.count <= length else {
            throw ProxyError.invalidRequest
        }
        var body = request.bodyPrefix
        while body.count < length {
            guard let chunk = try await Self.receive(from: connection), !chunk.isEmpty else {
                throw ProxyError.invalidRequest
            }
            guard body.count + chunk.count <= length else {
                throw ProxyError.invalidRequest
            }
            body.append(chunk)
        }
        return body
    }

    private func forward(body: Data, to connection: NWConnection) async throws {
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.timeoutInterval = limits.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let upstreamCredential {
            request.setValue("Bearer \(upstreamCredential)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxyError.upstreamFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProxyError.upstreamFailure
        }
        let upstreamTask = bytes.task
        defer { upstreamTask.cancel() }
        // A redirect is never a valid response for the app-server-facing
        // endpoint. URLSession's delegate normally rejects redirects before
        // they reach this point, but custom transports and URLProtocol-based
        // implementations can still surface a raw 3xx response. Do not pass
        // its Location header through to app-server: that could make it
        // replay the request, including prompts and tool output, elsewhere.
        guard !(300 ..< 400).contains(http.statusCode) else {
            throw ProxyError.upstreamFailure
        }
        // The proxy deliberately asks URLSession for an identity response and
        // forwards the bytes as an SSE stream. Passing compressed bytes (or
        // trusting a URLProtocol implementation that ignored that request)
        // would make app-server see a body it cannot decode and would
        // invalidate both response limits and credential scrubbing. Reject
        // every content-coding other than the explicit identity token before
        // exposing any response headers to app-server.
        guard Self.isIdentityContentEncoding(
            http.value(forHTTPHeaderField: "Content-Encoding")
        ) else {
            throw ProxyError.unsupportedUpstreamContentEncoding
        }
        // Bound the complete upstream head before filtering. A provider must
        // not be able to allocate or send an arbitrarily large credential,
        // cookie, or otherwise blocked header merely because it would later
        // be removed from the app-server-facing response.
        guard Self.serializedResponseHeaderByteCount(http)
            <= limits.maximumUpstreamResponseHeaderBytes else {
            throw ProxyError.upstreamResponseHeadersTooLarge
        }
        let filteredHead = Self.filteredResponseHead(
            http,
            upstreamCredential: upstreamCredential
        )
        let encodedHead = Self.encodedResponseHead(filteredHead)
        guard encodedHead.count <= limits.maximumUpstreamResponseHeaderBytes else {
            throw ProxyError.upstreamResponseHeadersTooLarge
        }
        try await Self.send(encodedHead, over: connection)

        var byteCount = 0
        var batch = Data()
        batch.reserveCapacity(16 * 1_024)
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(
            credential: upstreamCredential
        )
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                byteCount += 1
                guard byteCount <= limits.maximumResponseBytes else {
                    throw ProxyError.upstreamResponseTooLarge
                }
                batch.append(byte)
                // Responses is an SSE protocol. Flush a complete event as
                // soon as its blank-line delimiter arrives so app-server can
                // render progress while the provider is still working. Keep
                // the size guard as a fallback for malformed/non-SSE output;
                // it also prevents an unbounded batch when a provider omits
                // delimiters altogether.
                if Self.endsSSEFrame(batch) || batch.count >= 16 * 1_024 {
                    let output = try sanitizer.append(batch)
                    // Stop the provider as soon as a terminal event is
                    // observed. A provider that keeps writing after a
                    // completed/failed response must not consume resources or
                    // smuggle post-terminal bytes through this boundary.
                    if output.terminal != nil {
                        upstreamTask.cancel()
                    }
                    if !output.frames.isEmpty {
                        try await Self.sendChunk(output.frames, over: connection)
                    }
                    batch.removeAll(keepingCapacity: true)
                    if output.terminal != nil {
                        try await Self.send(Data("0\r\n\r\n".utf8), over: connection)
                        return
                    }
                }
            }
            if !batch.isEmpty {
                let output = try sanitizer.append(batch)
                if output.terminal != nil {
                    upstreamTask.cancel()
                }
                if !output.frames.isEmpty {
                    try await Self.sendChunk(output.frames, over: connection)
                }
                if output.terminal != nil {
                    try await Self.send(Data("0\r\n\r\n".utf8), over: connection)
                    return
                }
            }
            let finalOutput = try sanitizer.finish()
            if finalOutput.terminal != nil {
                upstreamTask.cancel()
            }
            if !finalOutput.frames.isEmpty {
                try await Self.sendChunk(finalOutput.frames, over: connection)
            }
            // EOF without a Responses terminal is a truncated provider stream.
            // Do not send the clean terminating HTTP chunk: app-server must
            // observe an interrupted transport rather than mistake this for a
            // successfully completed response.
            guard finalOutput.terminal != nil || sanitizer.didReachTerminal else {
                throw ProxyError.upstreamFailure
            }
            try await Self.send(Data("0\r\n\r\n".utf8), over: connection)
        } catch is CancellationError {
            throw CancellationError()
        } catch is ProxyError {
            // Once an HTTP response head is visible, another status response
            // would create a request-smuggling-shaped byte stream. Closing the
            // client also cancels the URLSession task through the defer above.
            throw CancellationError()
        } catch {
            // The response head has already been sent. A second complete HTTP
            // response here would be ambiguous to the client (and could be
            // interpreted as a smuggled retry), so every post-head failure is
            // represented by a clean connection close.
            throw CancellationError()
        }
    }

    /// Once the exact request body has been consumed, no further client bytes
    /// are valid for this one-request connection. Keep one read pending while
    /// the upstream request runs so a Stop/interrupt that closes app-server's
    /// socket cancels the provider request even when the provider has not sent
    /// response headers yet. The losing read is canceled without closing the
    /// socket, allowing a successful upstream response to finish normally.
    private func forwardWhileMonitoringClient(
        body: Data,
        to connection: NWConnection
    ) async throws {
        enum RaceResult: Sendable {
            case upstreamCompleted
            case clientDisconnected
        }

        try await withThrowingTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                try await self.forward(body: body, to: connection)
                return .upstreamCompleted
            }
            group.addTask {
                try await Self.waitForClientDisconnect(connection)
                return .clientDisconnected
            }
            defer { group.cancelAll() }

            guard let first = try await group.next() else {
                throw ProxyError.upstreamFailure
            }
            switch first {
            case .upstreamCompleted:
                return
            case .clientDisconnected:
                throw CancellationError()
            }
        }
    }

    private static func endsSSEFrame(_ data: Data) -> Bool {
        data.count >= 2 && (
            data.suffix(2).elementsEqual([0x0A, 0x0A])
                || (data.count >= 4 && data.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]))
        )
    }

    /// The proxy does not implement decompression. A missing header or an
    /// explicit `identity` coding is safe; every other coding is rejected
    /// before response headers are exposed to app-server.
    private static func isIdentityContentEncoding(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let codings = raw
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !codings.isEmpty else { return false }
        return codings.allSatisfy { $0 == "identity" }
    }

    private func sendFailure(_ error: ProxyError, to connection: NWConnection) async throws {
        let status: (Int, String) = switch error {
        case .unauthorized: (401, "Unauthorized")
        case .unsupportedRoute: (404, "Not Found")
        case .unsupportedContentEncoding: (415, "Unsupported Media Type")
        case .requestTooLarge: (413, "Payload Too Large")
        case .invalidRequest: (400, "Bad Request")
        case .invalidConfiguration, .unsupportedUpstreamContentEncoding, .upstreamFailure,
             .upstreamResponseHeadersTooLarge,
             .upstreamResponseTooLarge:
            (502, "Bad Gateway")
        }
        let body = Data("{\"error\":\"provider_request_failed\"}".utf8)
        let head = "HTTP/1.1 \(status.0) \(status.1)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        try await Self.send(Data(head.utf8) + body, over: connection)
    }

    private static func filteredResponseHead(
        _ response: HTTPURLResponse,
        upstreamCredential: String?
    ) -> UpstreamResponseHead {
        let blocked = Set([
            "api-key", "authentication-info", "authorization", "connection", "content-encoding",
            "content-length", "keep-alive", "proxy-authenticate", "proxy-authentication-info",
            "proxy-authorization", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade",
            "www-authenticate", "x-api-key", "x-auth-token", "x-openai-api-key",
        ])
        let headers = response.allHeaderFields.compactMap { rawName, rawValue -> (String, String)? in
            let name = String(describing: rawName)
            // URLSession normally supplies validated HTTP field names, but a
            // custom URLProtocol (and a future transport implementation) can
            // hand us arbitrary Foundation objects.  Never interpolate a
            // non-token name into the app-server response head: a CR/LF here
            // would become a response-splitting primitive.
            guard Self.isHTTPFieldName(name),
                  !blocked.contains(name.lowercased()) else { return nil }
            let rawValue = String(describing: rawValue)
            // Normalize the two line delimiters to visible spacing, then
            // reject the remaining C0/DEL controls.  Forwarding NUL or other
            // controls can produce malformed framing in downstream parsers;
            // dropping that one provider header is safer than failing the
            // whole otherwise-valid Responses stream.
            let value = rawValue
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            guard value.unicodeScalars.allSatisfy({ scalar in
                let code = scalar.value
                return code == 0x09 || code >= 0x20 && code != 0x7F
            }) else { return nil }
            guard upstreamCredential.map({ credential in
                !name.contains(credential) && !value.contains(credential)
            }) ?? true else { return nil }
            return (name, value)
        }
        return UpstreamResponseHead(statusCode: response.statusCode, headers: headers)
    }

    /// RFC 9110 `field-name` token validation.  Keep this ASCII-only and
    /// explicit rather than relying on `Character` classification so a weird
    /// Unicode scalar cannot be serialized into an ambiguous header line.
    private static func isHTTPFieldName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case 0x21, 0x23 ... 0x27, 0x2A, 0x2B, 0x2D, 0x2E,
                 0x30 ... 0x39, 0x41 ... 0x5A, 0x5E, 0x5F, 0x60,
                 0x61 ... 0x7A, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }
    }

    private static func serializedResponseHeaderByteCount(
        _ response: HTTPURLResponse
    ) -> Int {
        var count = Data(
            "HTTP/1.1 \(response.statusCode) \(reasonPhrase(response.statusCode))\r\n"
                .utf8
        ).count
        for (rawName, rawValue) in response.allHeaderFields {
            let line = "\(String(describing: rawName)): \(String(describing: rawValue))\r\n"
            let (next, overflow) = count.addingReportingOverflow(line.utf8.count)
            if overflow { return Int.max }
            count = next
        }
        let (withDelimiter, overflow) = count.addingReportingOverflow(2)
        return overflow ? Int.max : withDelimiter
    }

    private static func encodedResponseHead(_ response: UpstreamResponseHead) -> Data {
        var lines = ["HTTP/1.1 \(response.statusCode) \(reasonPhrase(response.statusCode))"]
        lines.append(contentsOf: response.headers.map { "\($0.0): \($0.1)" })
        lines.append("Transfer-Encoding: chunked")
        lines.append("Cache-Control: no-store")
        lines.append("Connection: close")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func sendChunk(_ data: Data, over connection: NWConnection) async throws {
        let prefix = Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8)
        try await send(prefix + data + Data("\r\n".utf8), over: connection)
    }

    private static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Response"
        }
    }

    private static func start(_ connection: NWConnection) async throws {
        let queue = DispatchQueue(label: "app.onyx.responses-proxy.connection")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let resolver = ConnectionStartResolver(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resolver.succeed()
                    case let .failed(error): resolver.fail(error)
                    case .cancelled: resolver.fail(CancellationError())
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func receive(from connection: NWConnection) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data?, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                    data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if isComplete { continuation.resume(returning: nil) }
                    else { continuation.resume(returning: Data()) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func waitForClientDisconnect(_ connection: NWConnection) async throws {
        let resolver = ClientDisconnectReadResolver()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                resolver.install(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
                    _, _, _, _ in
                    // The request's declared body has already been consumed.
                    // EOF/reset is a disconnect; any additional byte is
                    // unsupported pipelining and terminates this transaction.
                    resolver.clientSignalled()
                }
            }
        } onCancel: {
            // Do not cancel the NWConnection here. When upstream wins, its
            // final response must remain writable. The outer handler closes
            // the connection after the forwarding task has completed.
            resolver.cancelWait()
        }
    }

    private static func send(_ data: Data, over connection: NWConnection) async throws {
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

    private static func isLiteralIPv4Loopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        return host.debugDescription == "127.0.0.1"
            || host.debugDescription.hasPrefix("127.")
    }

    private static func makeDisposableToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeDefaultSession(limits: Limits) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limits.requestTimeout
        configuration.timeoutIntervalForResource = limits.resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

private final class ListenerStartResolver: @unchecked Sendable {
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

private final class ConnectionStartResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func succeed() { resolve(.success(())) }
    func fail(_ error: any Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Void, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

/// Resolves a pending client-liveness read exactly once. Task cancellation can
/// race continuation installation, and the Network callback can arrive later
/// after cancellation; both cases are intentionally harmless.
private final class ClientDisconnectReadResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancelled = false
    private var finished = false

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !finished else { return true }
            if cancelled {
                finished = true
                return true
            }
            self.continuation = continuation
            return false
        }
        if shouldCancel { continuation.resume(throwing: CancellationError()) }
    }

    func clientSignalled() {
        let pending = lock.withLock { takeContinuation(markCancelled: false) }
        pending?.resume()
    }

    func cancelWait() {
        let pending = lock.withLock { takeContinuation(markCancelled: true) }
        pending?.resume(throwing: CancellationError())
    }

    private func takeContinuation(
        markCancelled: Bool
    ) -> CheckedContinuation<Void, any Error>? {
        if markCancelled { cancelled = true }
        guard !finished else { return nil }
        guard let continuation else { return nil }
        finished = true
        self.continuation = nil
        return continuation
    }
}

/// The configured Responses URL is exact. Even a same-origin redirect can
/// change the request path or method semantics, so the proxy never follows it.
private final class ResponsesProxyNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
