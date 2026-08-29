import Foundation

/// Incrementally validates and canonicalizes an OpenAI Responses SSE stream.
/// HTTP framing, compression, cancellation, and total-response limits remain
/// transport concerns owned by the proxy.
struct OpenAICompatibleResponsesSSESanitizer: Sendable {
    struct Limits: Sendable, Equatable {
        let maximumEventBytes: Int
        let maximumJSONDepth: Int
        let maximumNestedJSONStringDepth: Int
        let maximumSemanticStreams: Int
        let maximumIdentifierBytes: Int
        let maximumRetainedSemanticBytes: Int

        init(
            maximumEventBytes: Int = 1_024 * 1_024,
            maximumJSONDepth: Int = 64,
            maximumNestedJSONStringDepth: Int = 4,
            maximumSemanticStreams: Int = 256,
            maximumIdentifierBytes: Int = 256,
            maximumRetainedSemanticBytes: Int = 1_024 * 1_024
        ) {
            self.maximumEventBytes = max(1, maximumEventBytes)
            self.maximumJSONDepth = max(1, maximumJSONDepth)
            self.maximumNestedJSONStringDepth = max(0, maximumNestedJSONStringDepth)
            self.maximumSemanticStreams = max(1, maximumSemanticStreams)
            self.maximumIdentifierBytes = max(1, maximumIdentifierBytes)
            self.maximumRetainedSemanticBytes = max(1, maximumRetainedSemanticBytes)
        }

        static let `default` = Limits()
    }

    enum Terminal: Sendable, Equatable {
        case completed
        case failed
        case incomplete
        case done
    }

    struct Output: Sendable, Equatable {
        let frames: Data
        let terminal: Terminal?
        /// False while a bounded semantic delta is intentionally withheld to
        /// decide whether it reconstructs the provider credential.
        let canFlushDownstream: Bool

        static let empty = Output(frames: Data(), terminal: nil, canFlushDownstream: true)
    }

    enum SanitizationError: Error, Equatable, LocalizedError {
        case invalidState
        case malformedEvent
        case eventTooLarge
        case jsonDepthExceeded
        case nestedJSONStringDepthExceeded
        case credentialCouldNotBeSanitized

        var errorDescription: String? {
            switch self {
            case .invalidState:
                "The response stream is no longer available."
            case .malformedEvent:
                "The provider returned an invalid response event."
            case .eventTooLarge:
                "The provider returned a response event that was too large."
            case .jsonDepthExceeded, .nestedJSONStringDepthExceeded:
                "The provider returned a response event that was too deeply nested."
            case .credentialCouldNotBeSanitized:
                "The provider response could not be sanitized."
            }
        }
    }

    private struct EventFields: Sendable {
        var dataLines: [Data] = []
        var eventName: String?
        var sawEventField = false

        mutating func reset() {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            sawEventField = false
        }
    }

    private struct MappedByte: Sendable {
        let value: UInt8
        let sourceRange: Range<Int>
    }

    private struct SemanticKey: Hashable, Sendable {
        let kind: String
        let itemID: String
        let outputIndex: Int
        let contentIndex: Int
    }

    /// The provider's stream identity is the semantic kind plus item id. The
    /// output/content indexes are metadata on that identity, not a way to
    /// create a new stream when a provider changes them mid-response.
    private struct StreamIdentity: Hashable, Sendable {
        let kind: String
        let itemID: String
    }

    private struct StreamState: Sendable {
        let isArguments: Bool
        var retainedText: String
    }

    private struct SemanticFragment: Sendable {
        let key: SemanticKey
        let text: String
        let isDone: Bool
        let isArguments: Bool
    }

    private let credential: String?
    private let credentialBytes: [UInt8]?
    private let limits: Limits
    private var currentLine = Data()
    private var currentEventByteCount = 0
    private var fields = EventFields()
    private var terminal: Terminal?
    private var isFinished = false
    private var hasFailed = false
    private var withheldFrames = Data()
    /// Only credential-prefix suffixes are retained for text/refusal streams.
    /// Function arguments retain the complete cumulative argument string until
    /// the provider supplies its matching `.done` snapshot.
    private var semanticStates: [SemanticKey: StreamState] = [:]
    /// `knownSemanticKeys` is intentionally never pruned during a response:
    /// active plus completed identities are bounded together, and a completed
    /// stream can never be reopened.
    private var knownSemanticKeys: Set<SemanticKey> = []
    private var completedSemanticKeys: Set<SemanticKey> = []
    private var metadataByIdentity: [StreamIdentity: SemanticKey] = [:]
    private var retainedSemanticByteCount = 0
    /// Text, refusal, and function-argument events remain visible to app-server
    /// even when providers split them across item IDs. Retain the shortest
    /// response-wide suffix that could still begin the credential so separate
    /// semantic identities cannot launder its fragments.
    private var globalSemanticCredentialSuffix = ""
    private var globalSemanticLastKey: SemanticKey?

    var didReachTerminal: Bool { terminal != nil }
    var terminalState: Terminal? { terminal }

    init(credential: String?, limits: Limits = .default) {
        let nonemptyCredential = credential.flatMap { $0.isEmpty ? nil : $0 }
        self.credential = nonemptyCredential
        credentialBytes = nonemptyCredential.map { Array($0.utf8) }
        self.limits = limits
    }

    /// Returns every complete frame found in an arbitrary transport chunk.
    /// The proxy should forward each returned value before requesting the next
    /// upstream chunk so one malformed later event cannot hide earlier output.
    /// Once a terminal frame has been returned, later calls fail closed; bytes
    /// already coalesced after that terminal in the same transport chunk are
    /// discarded because the caller will immediately cancel upstream work.
    mutating func append(_ data: Data) throws -> Output {
        guard !isFinished, !hasFailed, terminal == nil else {
            throw SanitizationError.invalidState
        }

        do {
            var output = Data()
            var emittedTerminal: Terminal?
            var canFlushDownstream = true
            for byte in data {
                guard emittedTerminal == nil else {
                    // Ignore bytes already delivered in the same transport
                    // chunk after a valid terminal. The proxy will cancel the
                    // upstream immediately after receiving this disposition.
                    continue
                }
                currentEventByteCount += 1
                guard currentEventByteCount <= limits.maximumEventBytes else {
                    throw SanitizationError.eventTooLarge
                }
                if byte == 0x0A {
                    let line = try consumeTerminatedLine()
                    if line.isEmpty {
                        var emitted = try emitCurrentEvent()
                        guard emitted.frames.count <= limits.maximumEventBytes else {
                            throw SanitizationError.eventTooLarge
                        }
                        emitted = try validateCrossEventCredentialBoundary(emitted)
                        output.append(emitted.frames)
                        canFlushDownstream = emitted.canFlushDownstream
                        fields.reset()
                        currentEventByteCount = 0
                        if let reached = emitted.terminal {
                            terminal = reached
                            emittedTerminal = reached
                        }
                    } else {
                        try consumeEventLine(line)
                    }
                } else {
                    currentLine.append(byte)
                }
            }
            return Output(
                frames: output,
                terminal: emittedTerminal,
                canFlushDownstream: canFlushDownstream
            )
        } catch let error as SanitizationError {
            failClosed()
            throw error
        } catch {
            failClosed()
            throw SanitizationError.malformedEvent
        }
    }

    /// Dispatches a final event whose last line was terminated even when a
    /// provider omitted its trailing blank line. Unterminated data is rejected.
    mutating func finish() throws -> Output {
        guard !isFinished, !hasFailed else { throw SanitizationError.invalidState }
        if let terminal {
            isFinished = true
            return Output(frames: Data(), terminal: terminal, canFlushDownstream: true)
        }
        do {
            guard currentLine.isEmpty else { throw SanitizationError.malformedEvent }
            var output = Output.empty
            if !fields.dataLines.isEmpty {
                output = try emitCurrentEvent()
                guard output.frames.count <= limits.maximumEventBytes else {
                    throw SanitizationError.eventTooLarge
                }
                output = try validateCrossEventCredentialBoundary(output)
                terminal = output.terminal
            }

            // EOF is enough to disambiguate a short text/refusal prefix: no
            // future delta can complete the configured credential. A function
            // argument stream is different; without its matching `.done`
            // snapshot we cannot safely hand app-server a partial call.
            guard !hasActiveFunctionArgumentStream else {
                throw SanitizationError.malformedEvent
            }
            output = releaseTextHoldbackIfNeeded(output)
            fields.reset()
            currentEventByteCount = 0
            isFinished = true
            return output
        } catch let error as SanitizationError {
            failClosed()
            throw error
        } catch {
            failClosed()
            throw SanitizationError.malformedEvent
        }
    }

    private mutating func consumeTerminatedLine() throws -> Data {
        defer { currentLine.removeAll(keepingCapacity: true) }
        if currentLine.last == 0x0D {
            guard !currentLine.dropLast().contains(0x0D) else {
                throw SanitizationError.malformedEvent
            }
            return currentLine.dropLast()
        }
        guard !currentLine.contains(0x0D) else { throw SanitizationError.malformedEvent }
        return currentLine
    }

    private mutating func consumeEventLine(_ lineData: Data) throws {
        if lineData.first == 0x3A { return }
        let fieldName: Data
        var fieldValue: Data
        if let separator = lineData.firstIndex(of: 0x3A) {
            fieldName = lineData[..<separator]
            fieldValue = lineData[lineData.index(after: separator)...]
            if fieldValue.first == 0x20 { fieldValue = fieldValue.dropFirst() }
        } else {
            fieldName = lineData
            fieldValue = Data()
        }
        switch fieldName {
        case Data("data".utf8):
            // Preserve raw data bytes until the complete JSON payload is
            // assembled. A transport chunk may split a multi-byte UTF-8 scalar
            // anywhere, including in the middle of one data line.
            fields.dataLines.append(fieldValue)
        case Data("event".utf8):
            guard !fields.sawEventField else { throw SanitizationError.malformedEvent }
            guard let eventName = String(data: fieldValue, encoding: .utf8) else {
                throw SanitizationError.malformedEvent
            }
            fields.sawEventField = true
            fields.eventName = eventName
        case Data("id".utf8), Data("retry".utf8): break
        default: break // Unknown SSE fields are valid and ignored.
        }
    }

    private func emitCurrentEvent() throws -> Output {
        guard !fields.dataLines.isEmpty else { return .empty }
        var payloadData = Data()
        for (index, line) in fields.dataLines.enumerated() {
            if index > 0 { payloadData.append(0x0A) }
            payloadData.append(line)
        }
        if payloadData == Data("[DONE]".utf8) {
            guard fields.eventName == nil else {
                throw SanitizationError.malformedEvent
            }
            return Output(
                frames: try encodeFrame(eventName: nil, payload: Data("[DONE]".utf8)),
                terminal: .done,
                canFlushDownstream: true
            )
        }

        try validateJSONStructure(payloadData, rejectDuplicateKeys: true)
        let decoded = try decodeJSON(payloadData)
        guard var object = decoded as? [String: Any],
              let originalType = object["type"] as? String else {
            throw SanitizationError.malformedEvent
        }
        guard fields.eventName == nil || fields.eventName == originalType else {
            throw SanitizationError.malformedEvent
        }

        var canonicalType = originalType
        let hiddenReasoningEvent = Self.isHiddenReasoningType(originalType)
            || fields.eventName.map(Self.isHiddenReasoningType) == true
        if hiddenReasoningEvent {
            // Bounded fixed liveness: raw reasoning and provider-controlled
            // metadata do not cross the app-server boundary.
            object = ["type": "response.in_progress"]
            canonicalType = "response.in_progress"
        } else {
            object = try sanitizeJSONObject(
                object,
                containerDepth: 0,
                nestedJSONStringDepth: 0
            )
            object = try scrubReasoningContainers(in: object)
            canonicalType = try canonicalTerminalType(
                originalType: originalType,
                object: &object
            )
        }

        try assertCredentialAbsent(from: object, nestedJSONStringDepth: 0)
        let canonicalPayload = try encodeJSON(object)
        try assertCanonicalBytesDoNotContainCredential(canonicalPayload)
        let emittedEventName = hiddenReasoningEvent ? "response.in_progress" : (
            fields.eventName == originalType ? canonicalType : fields.eventName
        )
        return Output(
            frames: try encodeFrame(eventName: emittedEventName, payload: canonicalPayload),
            terminal: Self.terminal(for: canonicalType),
            canFlushDownstream: true
        )
    }

    /// Treats the nested response status as authoritative at a terminal
    /// boundary. Some compatible providers have emitted `response.completed`
    /// for incomplete or failed responses; forwarding that label unchanged
    /// would let app-server persist a false success. Known terminal statuses
    /// are canonicalized, while missing or unknown states fail closed.
    private func canonicalTerminalType(
        originalType: String,
        object: inout [String: Any]
    ) throws -> String {
        let expectedStatus: String?
        switch originalType {
        case "response.completed": expectedStatus = nil
        case "response.incomplete": expectedStatus = "incomplete"
        case "response.failed": expectedStatus = "failed"
        default: return originalType
        }

        guard let response = object["response"] as? [String: Any],
              let status = response["status"] as? String else {
            throw SanitizationError.malformedEvent
        }
        if let expectedStatus {
            guard status == expectedStatus else {
                throw SanitizationError.malformedEvent
            }
            return originalType
        }

        let canonicalType: String
        switch status {
        case "completed": canonicalType = "response.completed"
        case "incomplete": canonicalType = "response.incomplete"
        case "failed": canonicalType = "response.failed"
        default: throw SanitizationError.malformedEvent
        }
        object["type"] = canonicalType
        return canonicalType
    }

    private func encodeFrame(eventName: String?, payload: Data) throws -> Data {
        var frame = Data()
        if let eventName, !eventName.isEmpty {
            let safeName = try redactCredentialRepresentations(in: eventName)
            guard !safeName.isEmpty,
                  !safeName.contains("\r"),
                  !safeName.contains("\n"),
                  !safeName.contains("\0") else {
                throw SanitizationError.malformedEvent
            }
            frame.append(Data("event: \(safeName)\n".utf8))
        }
        frame.append(Data("data: ".utf8))
        frame.append(payload)
        frame.append(Data("\n\n".utf8))
        return frame
    }

    private func sanitizeJSONObject(
        _ object: [String: Any],
        containerDepth: Int,
        nestedJSONStringDepth: Int
    ) throws -> [String: Any] {
        guard containerDepth < limits.maximumJSONDepth else {
            throw SanitizationError.jsonDepthExceeded
        }
        var sanitized: [String: Any] = [:]
        for (key, child) in object {
            let safeKey = try sanitizeJSONString(key, nestedJSONStringDepth: nestedJSONStringDepth)
            guard sanitized[safeKey] == nil else { throw SanitizationError.malformedEvent }
            sanitized[safeKey] = try sanitizeJSONValue(
                child,
                containerDepth: containerDepth + 1,
                nestedJSONStringDepth: nestedJSONStringDepth
            )
        }
        return sanitized
    }

    private func sanitizeJSONValue(
        _ value: Any,
        containerDepth: Int,
        nestedJSONStringDepth: Int
    ) throws -> Any {
        if let object = value as? [String: Any] {
            return try sanitizeJSONObject(
                object,
                containerDepth: containerDepth,
                nestedJSONStringDepth: nestedJSONStringDepth
            )
        }
        if let array = value as? [Any] {
            guard containerDepth < limits.maximumJSONDepth else {
                throw SanitizationError.jsonDepthExceeded
            }
            return try array.map {
                try sanitizeJSONValue(
                    $0,
                    containerDepth: containerDepth + 1,
                    nestedJSONStringDepth: nestedJSONStringDepth
                )
            }
        }
        if let string = value as? String {
            return try sanitizeJSONString(string, nestedJSONStringDepth: nestedJSONStringDepth)
        }
        guard value is NSNumber || value is NSNull else {
            throw SanitizationError.malformedEvent
        }
        return value
    }

    private func sanitizeJSONString(
        _ string: String,
        nestedJSONStringDepth: Int
    ) throws -> String {
        let direct = try redactCredentialRepresentations(in: string)
        guard direct == string else { return direct }
        guard nestedJSONStringDepth < limits.maximumNestedJSONStringDepth else { return string }
        guard let nested = try decodeNestedJSON(string) else { return string }
        if try containsCredential(
            in: nested,
            nestedJSONStringDepth: nestedJSONStringDepth + 1
        ) {
            // Replacing the complete leaf is safer than trying to splice a
            // deeply escaped representation without changing its semantics.
            return ""
        }
        return string
    }

    private func scrubReasoningContainers(in object: [String: Any]) throws -> [String: Any] {
        var result = object
        if var item = result["item"] as? [String: Any],
           item["type"] as? String == "reasoning" {
            item = try scrubReasoningItem(item)
            result["item"] = item
        }
        if var response = result["response"] as? [String: Any] {
            if let output = response["output"] as? [Any] {
                response["output"] = try output.map { value in
                    guard let item = value as? [String: Any],
                          item["type"] as? String == "reasoning" else { return value }
                    return try scrubReasoningItem(item)
                }
            }
            for key in response.keys where Self.isPlaintextReasoningField(key) {
                response[key] = Self.blankValue(response[key])
            }
            result["response"] = response
        }
        return result
    }

    private func scrubReasoningItem(_ item: [String: Any]) throws -> [String: Any] {
        // Reasoning item schemas have evolved across Responses providers. Keep
        // only the bounded protocol metadata app-server may need, plus opaque
        // encrypted content. Copy only expected scalar shapes: allowing an
        // object or array through an otherwise-safe metadata key would give a
        // malformed provider another place to hide plaintext reasoning.
        // `codex-app-server` decodes lifecycle snapshots as a ResponseItem.
        // Its reasoning variant requires `summary` even when Onyx strips the
        // provider's plaintext reasoning, so retain the safe empty container.
        var scrubbed: [String: Any] = [
            "type": "reasoning",
            "summary": [Any](),
        ]
        for key in ["id", "status", "item_id"] {
            if let value = item[key] as? String {
                scrubbed[key] = value
            }
        }
        for key in ["sequence_number", "output_index"] {
            if let value = item[key] as? NSNumber {
                scrubbed[key] = value
            }
        }
        if let rawEncrypted = item["encrypted_content"] {
            guard let encrypted = rawEncrypted as? String else {
                scrubbed["encrypted_content"] = ""
                return scrubbed
            }
            scrubbed["encrypted_content"] = try redactCredentialRepresentations(in: encrypted)
        }
        return scrubbed
    }

    private static func isPlaintextReasoningField(_ key: String) -> Bool {
        let key = key.lowercased()
        return key != "encrypted_content" && (
            key == "content" || key == "text" || key == "delta"
                || key == "summary" || key == "reasoning"
                || key.contains("reasoning") || key.contains("summary")
        )
        // `encrypted_content` and opaque IDs intentionally survive.
    }

    private static func blankValue(_ value: Any?) -> Any {
        if value is [Any] { return [Any]() }
        if value is [String: Any] { return [String: Any]() }
        return ""
    }

    private func decodeJSON(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch { throw SanitizationError.malformedEvent }
    }

    private func decodeNestedJSON(_ string: String) throws -> Any? {
        let data = Data(string.utf8)
        do {
            try validateJSONStructure(data, rejectDuplicateKeys: true)
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch SanitizationError.jsonDepthExceeded {
            throw SanitizationError.jsonDepthExceeded
        } catch { return nil }
    }

    private func encodeJSON(_ value: Any) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch { throw SanitizationError.malformedEvent }
    }

    /// Rejects duplicate object keys before Foundation silently chooses one.
    /// Key strings are decoded so escaped spellings of the same key collide.
    private func validateJSONStructure(_ data: Data, rejectDuplicateKeys: Bool) throws {
        var stack: [(delimiter: UInt8, keys: Set<String>, expectingKey: Bool)] = []
        var index = 0
        var isInsideString = false
        var stringStart = 0
        var isEscaped = false
        while index < data.count {
            let byte = data[index]
            if isInsideString {
                if isEscaped { isEscaped = false }
                else if byte == 0x5C { isEscaped = true }
                else if byte == 0x22 {
                    isInsideString = false
                    if rejectDuplicateKeys,
                       stack.last?.delimiter == 0x7B,
                       stack.last?.expectingKey == true
                    {
                        let token = Data(data[stringStart ... index])
                        guard let key = try decodeJSON(token) as? String else {
                            throw SanitizationError.malformedEvent
                        }
                        guard stack[stack.count - 1].keys.insert(key).inserted else {
                            throw SanitizationError.malformedEvent
                        }
                        stack[stack.count - 1].expectingKey = false
                    }
                } else if byte < 0x20 { throw SanitizationError.malformedEvent }
                index += 1
                continue
            }
            switch byte {
            case 0x22:
                isInsideString = true
                stringStart = index
            case 0x7B:
                stack.append((0x7B, [], true))
                guard stack.count <= limits.maximumJSONDepth else {
                    throw SanitizationError.jsonDepthExceeded
                }
            case 0x5B:
                stack.append((0x5B, [], false))
                guard stack.count <= limits.maximumJSONDepth else {
                    throw SanitizationError.jsonDepthExceeded
                }
            case 0x7D:
                guard stack.popLast()?.delimiter == 0x7B else {
                    throw SanitizationError.malformedEvent
                }
            case 0x5D:
                guard stack.popLast()?.delimiter == 0x5B else {
                    throw SanitizationError.malformedEvent
                }
            case 0x2C:
                if stack.last?.delimiter == 0x7B {
                    stack[stack.count - 1].expectingKey = true
                }
            default: break
            }
            index += 1
        }
        guard !isInsideString, !isEscaped, stack.isEmpty else {
            throw SanitizationError.malformedEvent
        }
    }

    /// Removes a credential reconstructed by any mixture of legal JSON escape
    /// layers, including nested JSON encoded inside a string.
    private func redactCredentialRepresentations(in string: String) throws -> String {
        guard let credentialBytes else { return string }
        let source = Array(string.utf8)
        var mapped = source.indices.map {
            MappedByte(value: source[$0], sourceRange: $0 ..< $0 + 1)
        }
        var sourceRangesToRemove: [Range<Int>] = []
        var escapeDepth = 0
        while true {
            var start = 0
            while start + credentialBytes.count <= mapped.count {
                if mapped[start ..< start + credentialBytes.count]
                    .map(\.value).elementsEqual(credentialBytes) {
                    guard escapeDepth <= limits.maximumNestedJSONStringDepth else {
                        throw SanitizationError.nestedJSONStringDepthExceeded
                    }
                    sourceRangesToRemove.append(
                        mergedSourceRange(mapped[start ..< start + credentialBytes.count])
                    )
                    start += max(1, credentialBytes.count)
                } else { start += 1 }
            }
            let decoded = decodeOneJSONEscapeLayer(mapped)
            guard decoded.didDecode else { break }
            mapped = decoded.bytes
            escapeDepth += 1
        }
        guard !sourceRangesToRemove.isEmpty else { return string }
        let mergedRanges = mergedRemovalRanges(sourceRangesToRemove)
        var redacted: [UInt8] = []
        redacted.reserveCapacity(source.count)
        var sourceIndex = 0
        for range in mergedRanges {
            if sourceIndex < range.lowerBound {
                redacted.append(contentsOf: source[sourceIndex ..< range.lowerBound])
            }
            sourceIndex = max(sourceIndex, range.upperBound)
        }
        if sourceIndex < source.count {
            redacted.append(contentsOf: source[sourceIndex...])
        }
        guard let result = String(bytes: redacted, encoding: .utf8) else {
            throw SanitizationError.credentialCouldNotBeSanitized
        }
        return result
    }

    private func decodeOneJSONEscapeLayer(
        _ input: [MappedByte]
    ) -> (bytes: [MappedByte], didDecode: Bool) {
        var output: [MappedByte] = []
        var index = 0
        var didDecode = false
        while index < input.count {
            guard input[index].value == 0x5C, index + 1 < input.count else {
                output.append(input[index]); index += 1; continue
            }
            let escaped = input[index + 1].value
            let simple: UInt8? = switch escaped {
            case 0x22: 0x22
            case 0x5C: 0x5C
            case 0x2F: 0x2F
            case 0x62: 0x08
            case 0x66: 0x0C
            case 0x6E: 0x0A
            case 0x72: 0x0D
            case 0x74: 0x09
            default: nil
            }
            if let simple {
                output.append(MappedByte(
                    value: simple,
                    sourceRange: mergedSourceRange(input[index ..< index + 2])
                ))
                index += 2; didDecode = true; continue
            }
            if escaped == 0x75, let first = decodeHexCodeUnit(input, start: index + 2) {
                var consumed = 6
                var scalarValue = UInt32(first)
                if (0xD800 ... 0xDBFF).contains(first) {
                    guard index + 11 < input.count,
                          input[index + 6].value == 0x5C,
                          input[index + 7].value == 0x75,
                          let second = decodeHexCodeUnit(input, start: index + 8),
                          (0xDC00 ... 0xDFFF).contains(second) else {
                        output.append(input[index]); index += 1; continue
                    }
                    scalarValue = 0x1_0000
                        + (UInt32(first - 0xD800) << 10)
                        + UInt32(second - 0xDC00)
                    consumed = 12
                } else if (0xDC00 ... 0xDFFF).contains(first) {
                    output.append(input[index]); index += 1; continue
                }
                guard let scalar = Unicode.Scalar(scalarValue) else {
                    output.append(input[index]); index += 1; continue
                }
                let sourceRange = mergedSourceRange(input[index ..< index + consumed])
                output.append(contentsOf: String(scalar).utf8.map {
                    MappedByte(value: $0, sourceRange: sourceRange)
                })
                index += consumed; didDecode = true; continue
            }
            output.append(input[index]); index += 1
        }
        return (output, didDecode)
    }

    private func decodeHexCodeUnit(_ input: [MappedByte], start: Int) -> UInt16? {
        guard start + 4 <= input.count else { return nil }
        var result: UInt16 = 0
        for byte in input[start ..< start + 4].map(\.value) {
            let digit: UInt16
            switch byte {
            case 0x30 ... 0x39: digit = UInt16(byte - 0x30)
            case 0x41 ... 0x46: digit = UInt16(byte - 0x41 + 10)
            case 0x61 ... 0x66: digit = UInt16(byte - 0x61 + 10)
            default: return nil
            }
            result = (result << 4) | digit
        }
        return result
    }

    private func mergedSourceRange(_ bytes: ArraySlice<MappedByte>) -> Range<Int> {
        guard let first = bytes.first, let last = bytes.last else { return 0 ..< 0 }
        return first.sourceRange.lowerBound ..< last.sourceRange.upperBound
    }

    private func mergedRemovalRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let ordered = ranges.sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        var result: [Range<Int>] = []
        result.reserveCapacity(ordered.count)
        for range in ordered {
            guard let last = result.last, range.lowerBound <= last.upperBound else {
                result.append(range)
                continue
            }
            result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
        }
        return result
    }

    private func assertCredentialAbsent(from value: Any, nestedJSONStringDepth: Int) throws {
        guard credential != nil else { return }
        if let object = value as? [String: Any] {
            for (key, child) in object {
                try assertCredentialAbsent(from: key, nestedJSONStringDepth: nestedJSONStringDepth)
                try assertCredentialAbsent(from: child, nestedJSONStringDepth: nestedJSONStringDepth)
            }
        } else if let array = value as? [Any] {
            for child in array {
                try assertCredentialAbsent(from: child, nestedJSONStringDepth: nestedJSONStringDepth)
            }
        } else if let string = value as? String {
            guard try redactCredentialRepresentations(in: string) == string else {
                throw SanitizationError.credentialCouldNotBeSanitized
            }
            if nestedJSONStringDepth < limits.maximumNestedJSONStringDepth,
               let nested = try decodeNestedJSON(string) {
                try assertCredentialAbsent(
                    from: nested,
                    nestedJSONStringDepth: nestedJSONStringDepth + 1
                )
            }
        }
    }

    private func containsCredential(in value: Any, nestedJSONStringDepth: Int) throws -> Bool {
        guard credential != nil else { return false }
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if try containsCredential(in: key, nestedJSONStringDepth: nestedJSONStringDepth)
                    || containsCredential(in: child,
                                          nestedJSONStringDepth: nestedJSONStringDepth)
                {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            for child in array where try containsCredential(
                in: child,
                nestedJSONStringDepth: nestedJSONStringDepth
            ) {
                return true
            }
        } else if let string = value as? String {
            if try redactCredentialRepresentations(in: string) != string { return true }
            if nestedJSONStringDepth < limits.maximumNestedJSONStringDepth,
               let nested = try decodeNestedJSON(string) {
                return try containsCredential(
                    in: nested,
                    nestedJSONStringDepth: nestedJSONStringDepth + 1
                )
            }
        }
        return false
    }

    private func assertCanonicalBytesDoNotContainCredential(_ data: Data) throws {
        guard let credential else { return }
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.range(of: credential, options: .literal) == nil,
              try redactCredentialRepresentations(in: encoded) == encoded else {
            throw SanitizationError.credentialCouldNotBeSanitized
        }
    }

    /// Withholds only the shortest suffix that could still become the start of
    /// the configured credential. Frames are released in order once that
    /// ambiguity is resolved; a complete match fails before any constituent
    /// fragment crosses the boundary. Function-call argument deltas retain
    /// their complete cumulative argument until a matching `.done` snapshot.
    ///
    /// Holdback is global and ordered. Once one stream is ambiguous, even an
    /// unrelated semantic or metadata event stays behind it; otherwise the
    /// downstream transcript could observe events out of order if the prefix
    /// later turns out to be a credential.
    private mutating func validateCrossEventCredentialBoundary(
        _ output: Output
    ) throws -> Output {
        guard !output.frames.isEmpty else { return output }
        let fragments = try semanticFragments(in: output.frames)
        for fragment in fragments {
            try updateSemanticState(for: fragment)
            try updateGlobalCredentialState(for: fragment)
        }

        if output.terminal != nil {
            // A terminal event closes the response. Text/refusal prefixes can
            // now be released safely, but an unfinished function call cannot.
            guard !hasActiveFunctionArgumentStream else {
                throw SanitizationError.malformedEvent
            }
            return releaseTextHoldbackIfNeeded(output)
        }

        if hasPendingSemanticHoldback {
            try appendToWithheldFrames(output.frames)
            return Output(frames: Data(), terminal: nil, canFlushDownstream: false)
        }

        return releaseWithheldFrames(then: output)
    }

    private mutating func updateSemanticState(for fragment: SemanticFragment) throws {
        let identity = StreamIdentity(kind: fragment.key.kind, itemID: fragment.key.itemID)
        if let priorKey = metadataByIdentity[identity], priorKey != fragment.key {
            // Do not let a changed output/content index masquerade as a new
            // stream and evade the active/completed identity bound.
            throw SanitizationError.malformedEvent
        }
        if completedSemanticKeys.contains(fragment.key) {
            throw SanitizationError.malformedEvent
        }
        if !knownSemanticKeys.contains(fragment.key) {
            guard knownSemanticKeys.count < limits.maximumSemanticStreams else {
                throw SanitizationError.eventTooLarge
            }
            knownSemanticKeys.insert(fragment.key)
            metadataByIdentity[identity] = fragment.key
        }

        let priorState = semanticStates[fragment.key]
        if fragment.isArguments {
            try updateArgumentState(for: fragment, priorState: priorState)
        } else {
            try updateTextState(for: fragment, priorState: priorState)
        }
    }

    private mutating func updateGlobalCredentialState(
        for fragment: SemanticFragment
    ) throws {
        let globalContinuation: String
        if fragment.isDone {
            // Done events are cumulative snapshots of a stream already seen as
            // deltas. They do not add assistant-visible bytes to the global
            // chronology, but must still be safe on their own.
            globalContinuation = ""
        } else {
            globalContinuation = globalSemanticCredentialSuffix
        }
        let combined = globalContinuation + fragment.text
        guard combined.utf8.count <= limits.maximumEventBytes else {
            throw SanitizationError.eventTooLarge
        }
        guard try !containsCredentialReconstruction(combined) else {
            throw SanitizationError.credentialCouldNotBeSanitized
        }
        if fragment.isDone, globalSemanticLastKey == fragment.key {
            // This cumulative snapshot closes the semantic item that supplied
            // the last global delta, so it replaces that item's ambiguous
            // suffix rather than adding a duplicate copy of its text.
            try setGlobalSemanticCredentialSuffix(credentialPrefixSuffix(fragment.text))
        } else if !fragment.isDone {
            try setGlobalSemanticCredentialSuffix(credentialPrefixSuffix(combined))
            globalSemanticLastKey = fragment.key
        }
    }

    private mutating func setGlobalSemanticCredentialSuffix(_ suffix: String) throws {
        guard suffix.utf8.count <= limits.maximumRetainedSemanticBytes else {
            throw SanitizationError.eventTooLarge
        }
        globalSemanticCredentialSuffix = suffix
    }

    private mutating func updateTextState(
        for fragment: SemanticFragment,
        priorState: StreamState?
    ) throws {
        if fragment.isDone {
            // `.done` carries the provider's cumulative snapshot, not another
            // delta. Inspect it on its own, then retire the stream identity.
            guard try !containsCredentialReconstruction(fragment.text) else {
                throw SanitizationError.credentialCouldNotBeSanitized
            }
            removeSemanticState(for: fragment.key)
            completedSemanticKeys.insert(fragment.key)
            return
        }

        let priorSuffix = priorState?.retainedText ?? ""
        let combined = priorSuffix + fragment.text
        guard combined.utf8.count <= limits.maximumEventBytes else {
            throw SanitizationError.eventTooLarge
        }
        guard try !containsCredentialReconstruction(combined) else {
            throw SanitizationError.credentialCouldNotBeSanitized
        }

        let suffix = credentialPrefixSuffix(combined)
        if suffix.isEmpty {
            removeSemanticState(for: fragment.key)
        } else {
            let priorBytes = priorState?.retainedText.utf8.count ?? 0
            let nextBytes = retainedSemanticByteCount - priorBytes + suffix.utf8.count
            guard nextBytes <= limits.maximumRetainedSemanticBytes else {
                throw SanitizationError.eventTooLarge
            }
            semanticStates[fragment.key] = StreamState(
                isArguments: false,
                retainedText: suffix
            )
            retainedSemanticByteCount = nextBytes
        }
    }

    private mutating func updateArgumentState(
        for fragment: SemanticFragment,
        priorState: StreamState?
    ) throws {
        if fragment.isDone {
            guard try !containsCredentialReconstruction(fragment.text) else {
                throw SanitizationError.credentialCouldNotBeSanitized
            }
            if let priorState {
                guard priorState.isArguments,
                      priorState.retainedText == fragment.text else {
                    throw SanitizationError.malformedEvent
                }
            }
            removeSemanticState(for: fragment.key)
            completedSemanticKeys.insert(fragment.key)
            return
        }

        let accumulated = (priorState?.retainedText ?? "") + fragment.text
        guard accumulated.utf8.count <= limits.maximumEventBytes,
              accumulated.utf8.count <= limits.maximumRetainedSemanticBytes else {
            throw SanitizationError.eventTooLarge
        }
        guard try !containsCredentialReconstruction(accumulated) else {
            throw SanitizationError.credentialCouldNotBeSanitized
        }
        let priorBytes = priorState?.retainedText.utf8.count ?? 0
        let nextBytes = retainedSemanticByteCount - priorBytes + accumulated.utf8.count
        guard nextBytes <= limits.maximumRetainedSemanticBytes else {
            throw SanitizationError.eventTooLarge
        }
        semanticStates[fragment.key] = StreamState(
            isArguments: true,
            retainedText: accumulated
        )
        retainedSemanticByteCount = nextBytes
    }

    private mutating func removeSemanticState(for key: SemanticKey) {
        guard let prior = semanticStates.removeValue(forKey: key) else { return }
        retainedSemanticByteCount = max(
            0,
            retainedSemanticByteCount - prior.retainedText.utf8.count
        )
    }

    private var hasActiveFunctionArgumentStream: Bool {
        semanticStates.values.contains { $0.isArguments }
    }

    private var hasPendingSemanticHoldback: Bool {
        !semanticStates.isEmpty || !globalSemanticCredentialSuffix.isEmpty
    }

    private mutating func appendToWithheldFrames(_ frames: Data) throws {
        guard !frames.isEmpty else { return }
        withheldFrames.append(frames)
        // Bound all event bytes held behind an unresolved semantic stream. The
        // product scales with the identity bound while remaining overflow-safe.
        let (limit, overflow) = limits.maximumEventBytes.multipliedReportingOverflow(
            by: max(1, limits.maximumSemanticStreams)
        )
        let maximum = overflow ? Int.max : max(limits.maximumEventBytes, limit)
        guard withheldFrames.count <= maximum else {
            throw SanitizationError.eventTooLarge
        }
    }

    private mutating func releaseWithheldFrames(then output: Output) -> Output {
        guard !withheldFrames.isEmpty else { return output }
        var released = withheldFrames
        released.append(output.frames)
        withheldFrames.removeAll(keepingCapacity: true)
        return Output(
            frames: released,
            terminal: output.terminal,
            canFlushDownstream: true
        )
    }

    private mutating func releaseTextHoldbackIfNeeded(_ output: Output) -> Output {
        // Terminal/EOF makes a text prefix unambiguous. There should be no
        // function state at this point (callers check that separately).
        for key in Array(semanticStates.keys) {
            if semanticStates[key]?.isArguments == false {
                removeSemanticState(for: key)
            }
        }
        globalSemanticCredentialSuffix = ""
        globalSemanticLastKey = nil
        return releaseWithheldFrames(then: output)
    }

    private func credentialPrefixSuffix(_ text: String) -> String {
        guard let credential else { return "" }
        let textScalars = Array(text.unicodeScalars)
        let credentialScalars = Array(credential.unicodeScalars)
        let maximum = min(textScalars.count, max(0, credentialScalars.count - 1))
        guard maximum > 0 else { return "" }
        for length in stride(from: maximum, through: 1, by: -1) {
            if textScalars.suffix(length).elementsEqual(credentialScalars.prefix(length)) {
                return String(String.UnicodeScalarView(textScalars.suffix(length)))
            }
        }
        return ""
    }

    private func semanticFragments(in frame: Data) throws -> [SemanticFragment] {
        let text = String(decoding: frame, as: UTF8.self)
        var fragments: [SemanticFragment] = []
        for dataLine in text.split(separator: "\n") where dataLine.hasPrefix("data: ") {
            let payload = Data(dataLine.dropFirst("data: ".count).utf8)
            if payload == Data("[DONE]".utf8) { continue }
            guard let object = try decodeJSON(payload) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            let kind: String
            let valueKey: String
            let isArguments: Bool
            switch type {
            case "response.output_text.delta", "response.refusal.delta":
                kind = type; valueKey = "delta"; isArguments = false
            case "response.output_text.done", "response.refusal.done":
                kind = type.replacingOccurrences(of: ".done", with: ".delta")
                valueKey = type.hasPrefix("response.refusal") ? "refusal" : "text"
                isArguments = false
            case "response.function_call_arguments.delta":
                kind = type; valueKey = "delta"; isArguments = true
            case "response.function_call_arguments.done":
                kind = "response.function_call_arguments.delta"
                valueKey = "arguments"; isArguments = true
            default:
                if Self.couldConcatenateUnknownEvent(type, object: object) {
                    throw SanitizationError.malformedEvent
                }
                continue
            }
            guard let value = object[valueKey] as? String else {
                throw SanitizationError.malformedEvent
            }
            fragments.append(SemanticFragment(
                key: try semanticKey(kind: kind, object: object),
                text: value,
                isDone: type.hasSuffix(".done"),
                isArguments: isArguments
            ))
        }
        return fragments
    }

    private func semanticKey(kind: String, object: [String: Any]) throws -> SemanticKey {
        guard let itemID = object["item_id"] as? String, !itemID.isEmpty else {
            throw SanitizationError.malformedEvent
        }
        guard itemID.utf8.count <= limits.maximumIdentifierBytes else {
            throw SanitizationError.eventTooLarge
        }
        guard let outputIndex = nonNegativeIndex(object["output_index"]) else {
            throw SanitizationError.malformedEvent
        }
        let isTextOrRefusal = kind == "response.output_text.delta"
            || kind == "response.refusal.delta"
        let contentIndex: Int
        if isTextOrRefusal {
            guard let parsed = nonNegativeIndex(object["content_index"]) else {
                throw SanitizationError.malformedEvent
            }
            contentIndex = parsed
        } else {
            // Function-call argument events use item/output identity. If a
            // provider includes content_index as extra metadata, validate it
            // but do not let its presence/absence create a second stream.
            if let rawContentIndex = object["content_index"] {
                guard nonNegativeIndex(rawContentIndex) != nil else {
                    throw SanitizationError.malformedEvent
                }
            }
            contentIndex = -1
        }
        return SemanticKey(
            kind: kind,
            itemID: itemID,
            outputIndex: outputIndex,
            contentIndex: contentIndex
        )
    }

    private func nonNegativeIndex(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue >= 0,
              doubleValue.rounded() == doubleValue,
              // `Double(Int.max)` rounds to 2^63 on 64-bit platforms. Keep a
              // strict bound so the conversion below can never trap on a
              // numerically out-of-range provider index.
              doubleValue < Double(Int.max) else {
            return nil
        }
        return Int(doubleValue)
    }

    private static let lifecycleSnapshotTypes: Set<String> = [
        "response.output_item.added",
        "response.output_item.done",
        "response.content_part.added",
        "response.content_part.done",
        "response.reasoning_part.added",
        "response.reasoning_part.done",
    ]

    private static func couldConcatenateUnknownEvent(
        _ type: String,
        object: [String: Any]
    ) -> Bool {
        guard type.hasSuffix(".delta") || type.hasSuffix(".done") else {
            return false
        }

        // Responses lifecycle snapshots also end in `.done`, but their
        // strings are identifiers/metadata or complete item snapshots rather
        // than append-only semantic fragments. vLLM emits these for reasoning,
        // messages, and function calls. They are sanitized as complete JSON
        // events above and must not be mistaken for an unknown text stream.
        if lifecycleSnapshotTypes.contains(type) {
            return false
        }

        // Preserve the fail-closed behavior for genuinely unknown semantic
        // events: a provider must not split a credential across an event kind
        // that Onyx does not understand. Lifecycle snapshots are the only
        // known exception; every other unknown `.delta`/`.done` event that
        // carries strings is treated as potentially append-only.
        return object.contains { _, value in value is String }
    }

    private func containsCredentialReconstruction(_ value: String) throws -> Bool {
        try redactCredentialRepresentations(in: value) != value
    }

    private static func isHiddenReasoningType(_ type: String) -> Bool {
        type.hasPrefix("response.reasoning")
    }

    private static func terminal(for type: String) -> Terminal? {
        switch type {
        case "response.completed": .completed
        case "response.failed", "error": .failed
        case "response.incomplete": .incomplete
        default: nil
        }
    }

    private mutating func failClosed() {
        hasFailed = true
        currentLine.removeAll(keepingCapacity: false)
        fields.reset()
        currentEventByteCount = 0
        terminal = nil
        withheldFrames.removeAll(keepingCapacity: false)
        semanticStates.removeAll(keepingCapacity: false)
        knownSemanticKeys.removeAll(keepingCapacity: false)
        completedSemanticKeys.removeAll(keepingCapacity: false)
        metadataByIdentity.removeAll(keepingCapacity: false)
        retainedSemanticByteCount = 0
        globalSemanticCredentialSuffix = ""
        globalSemanticLastKey = nil
    }
}
