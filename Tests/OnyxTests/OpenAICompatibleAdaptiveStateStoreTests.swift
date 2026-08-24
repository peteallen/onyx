import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleAdaptiveStateStoreTests: XCTestCase {
    func testReopenRecoversChatAndAgentTaskOwnership() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let connectionID = ProviderConnectionID("provider.reopen")
        let scopeID = "scope.reopen"
        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let chat = try await store.recordTaskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: "chat-thread",
            lane: .chat,
            modelID: "chat-model",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let agent = try await store.recordTaskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: "agent-thread",
            lane: .agent,
            modelID: "agent-model",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let reopened = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let reopenedChat = try await reopened.taskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: chat.threadID
        )
        let reopenedAgent = try await reopened.taskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: agent.threadID
        )
        let chatOwners = try await reopened.taskOwnerships(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            lane: .chat
        )
        let agentOwners = try await reopened.taskOwnerships(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            lane: .agent
        )

        XCTAssertEqual(reopenedChat, chat)
        XCTAssertEqual(reopenedAgent, agent)
        XCTAssertEqual(chatOwners, [chat])
        XCTAssertEqual(agentOwners, [agent])
    }

    func testSameRawThreadIDRemainsIndependentAcrossScopesAndConnections() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let firstConnection = ProviderConnectionID("provider.first")
        let secondConnection = ProviderConnectionID("provider.second")
        let rawThreadID = "provider-reused-thread"
        let persistedAt = Date(timeIntervalSince1970: 1_000)
        let first = try await store.recordTaskOwnership(
            connectionID: firstConnection,
            conversationScopeID: "scope.first",
            threadID: rawThreadID,
            lane: .chat,
            modelID: "first-model",
            updatedAt: persistedAt
        )
        let rotatedScope = try await store.recordTaskOwnership(
            connectionID: firstConnection,
            conversationScopeID: "scope.rotated",
            threadID: rawThreadID,
            lane: .agent,
            modelID: "rotated-model",
            updatedAt: persistedAt
        )
        let second = try await store.recordTaskOwnership(
            connectionID: secondConnection,
            conversationScopeID: "scope.first",
            threadID: rawThreadID,
            lane: .agent,
            modelID: "second-model",
            updatedAt: persistedAt
        )

        let recoveredFirst = try await store.taskOwnership(
            connectionID: firstConnection,
            conversationScopeID: "scope.first",
            threadID: rawThreadID
        )
        let recoveredRotatedScope = try await store.taskOwnership(
            connectionID: firstConnection,
            conversationScopeID: "scope.rotated",
            threadID: rawThreadID
        )
        let recoveredSecond = try await store.taskOwnership(
            connectionID: secondConnection,
            conversationScopeID: "scope.first",
            threadID: rawThreadID
        )
        XCTAssertEqual(recoveredFirst, first)
        XCTAssertEqual(recoveredRotatedScope, rotatedScope)
        XCTAssertEqual(recoveredSecond, second)
    }

    func testOppositeLaneClaimFailsWithoutChangingDurableOwner() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let connectionID = ProviderConnectionID("provider.conflict")
        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let original = try await store.recordTaskOwnership(
            connectionID: connectionID,
            conversationScopeID: "scope.conflict",
            threadID: "thread.conflict",
            lane: .chat,
            modelID: "original-model",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        do {
            _ = try await store.recordTaskOwnership(
                connectionID: connectionID,
                conversationScopeID: "scope.conflict",
                threadID: "thread.conflict",
                lane: .agent,
                modelID: "replacement-model",
                updatedAt: Date(timeIntervalSince1970: 200)
            )
            XCTFail("A task must never move between chat and agent histories")
        } catch let error as OpenAICompatibleAdaptiveStateStoreError {
            XCTAssertEqual(
                error,
                .ownershipConflict(
                    connectionID: connectionID,
                    conversationScopeID: "scope.conflict",
                    threadID: "thread.conflict"
                )
            )
        }

        let reopened = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let durableOwner = try await reopened.taskOwnership(
            connectionID: connectionID,
            conversationScopeID: "scope.conflict",
            threadID: "thread.conflict"
        )
        XCTAssertEqual(durableOwner, original)
    }

    func testInterleavedStoreInstancesDoNotLoseOwnershipOrProbeUpdates() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let firstStore = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let secondStore = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let connectionID = ProviderConnectionID("provider.concurrent")
        let scopeID = "scope.concurrent"
        let now = Date(timeIntervalSince1970: 10_000)
        let threadIDs = Set((0 ..< 16).map { "thread-\($0)" })
        let probeRecords = try (0 ..< 8).map { index in
            makeProbeRecord(
                fingerprint: try makeFingerprint("concurrent-model-\(index)"),
                testedAt: now.addingTimeInterval(-10),
                expiresAt: now.addingTimeInterval(1_000),
                outcome: .failed(.missingFunctionCall)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 16 {
                let store = index.isMultiple(of: 2) ? firstStore : secondStore
                group.addTask {
                    _ = try await store.recordTaskOwnership(
                        connectionID: connectionID,
                        conversationScopeID: scopeID,
                        threadID: "thread-\(index)",
                        lane: index.isMultiple(of: 2) ? .chat : .agent,
                        modelID: "model-\(index)",
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
                    )
                }
            }
            for (index, record) in probeRecords.enumerated() {
                let store = index.isMultiple(of: 2) ? secondStore : firstStore
                group.addTask {
                    try await store.storeProbeRecord(record, at: now)
                }
            }
            try await group.waitForAll()
        }

        let reopened = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let ownerships = try await reopened.taskOwnerships(
            connectionID: connectionID,
            conversationScopeID: scopeID
        )
        XCTAssertEqual(ownerships.count, threadIDs.count)
        XCTAssertEqual(Set(ownerships.map(\.threadID)), threadIDs)
        for record in probeRecords {
            let recovered = try await reopened.probeRecord(
                for: record.fingerprint,
                at: now
            )
            XCTAssertEqual(recovered, record)
        }
    }

    func testBatchProbeLookupReturnsOnlyRequestedReusableFailures() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let storedAt = Date(timeIntervalSince1970: 15_000)
        let lookupDate = storedAt.addingTimeInterval(50)
        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let first = makeProbeRecord(
            fingerprint: try makeFingerprint("batch-first"),
            testedAt: storedAt,
            expiresAt: storedAt.addingTimeInterval(100),
            outcome: .failed(.missingFunctionCall)
        )
        let second = makeProbeRecord(
            fingerprint: try makeFingerprint("batch-second"),
            testedAt: storedAt,
            expiresAt: storedAt.addingTimeInterval(100),
            outcome: .failed(.functionOutputRejected)
        )
        let expired = makeProbeRecord(
            fingerprint: try makeFingerprint("batch-expired"),
            testedAt: storedAt,
            expiresAt: storedAt.addingTimeInterval(25),
            outcome: .failed(.malformedEventStream)
        )
        let unrequested = makeProbeRecord(
            fingerprint: try makeFingerprint("batch-unrequested"),
            testedAt: storedAt,
            expiresAt: storedAt.addingTimeInterval(100),
            outcome: .failed(.missingCompletion)
        )
        for record in [first, second, expired, unrequested] {
            try await store.storeProbeRecord(record, at: storedAt)
        }

        let records = try await store.probeRecords(
            for: [first.fingerprint, second.fingerprint, expired.fingerprint],
            at: lookupDate
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[first.fingerprint], first)
        XCTAssertEqual(records[second.fingerprint], second)
        XCTAssertNil(records[expired.fingerprint])
        XCTAssertNil(records[unrequested.fingerprint])
    }

    func testOnlyValidFailedProbeEvidenceMayBePersisted() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let now = Date(timeIntervalSince1970: 20_000)
        let limits = OpenAICompatibleAdaptiveStateStore.Limits(
            maximumProbeRecordLifetime: 1_000,
            maximumFutureClockSkew: 5
        )
        let store = OpenAICompatibleAdaptiveStateStore(
            fileURL: location.file,
            limits: limits
        )
        let incompleteEvidence = [
            OpenAICompatibleResponsesProbeEvidence(
                usedServerSentEvents: false,
                receivedFunctionCall: true,
                submittedCorrelatedOutput: true,
                completedAfterFunctionOutput: true
            ),
            OpenAICompatibleResponsesProbeEvidence(
                usedServerSentEvents: true,
                receivedFunctionCall: false,
                submittedCorrelatedOutput: true,
                completedAfterFunctionOutput: true
            ),
            OpenAICompatibleResponsesProbeEvidence(
                usedServerSentEvents: true,
                receivedFunctionCall: true,
                submittedCorrelatedOutput: false,
                completedAfterFunctionOutput: true
            ),
            OpenAICompatibleResponsesProbeEvidence(
                usedServerSentEvents: true,
                receivedFunctionCall: true,
                submittedCorrelatedOutput: true,
                completedAfterFunctionOutput: false
            ),
        ]
        let incompleteRecords = try incompleteEvidence.enumerated().map { index, evidence in
            makeProbeRecord(
                fingerprint: try makeFingerprint("incomplete-model-\(index)"),
                testedAt: now,
                expiresAt: now.addingTimeInterval(100),
                outcome: .compatible(evidence)
            )
        }
        for record in incompleteRecords {
            XCTAssertFalse(record.isReusable(for: record.fingerprint, at: now))
        }
        let completeCompatibleRecord = makeProbeRecord(
            fingerprint: try makeFingerprint("complete-compatible-model"),
            testedAt: now,
            expiresAt: now.addingTimeInterval(100),
            outcome: .compatible(Self.completeEvidence)
        )
        XCTAssertTrue(
            completeCompatibleRecord.isReusable(
                for: completeCompatibleRecord.fingerprint,
                at: now
            )
        )
        var invalidRecords = incompleteRecords + [completeCompatibleRecord]
        invalidRecords.append(makeProbeRecord(
            fingerprint: try decodeFingerprint("not-a-digest"),
            testedAt: now,
            expiresAt: now.addingTimeInterval(100),
            outcome: .failed(.missingFunctionCall)
        ))
        invalidRecords.append(makeProbeRecord(
            fingerprint: try makeFingerprint("future-tested-model"),
            testedAt: now.addingTimeInterval(6),
            expiresAt: now.addingTimeInterval(100),
            outcome: .failed(.missingFunctionCall)
        ))
        invalidRecords.append(makeProbeRecord(
            fingerprint: try makeFingerprint("reversed-dates-model"),
            testedAt: now,
            expiresAt: now.addingTimeInterval(-1),
            outcome: .failed(.missingFunctionCall)
        ))
        invalidRecords.append(makeProbeRecord(
            fingerprint: try makeFingerprint("excessive-ttl-model"),
            testedAt: now,
            expiresAt: now.addingTimeInterval(1_001),
            outcome: .failed(.missingFunctionCall)
        ))

        for record in invalidRecords {
            do {
                try await store.storeProbeRecord(record, at: now)
                XCTFail("Invalid compatibility evidence must not become reusable")
            } catch let error as OpenAICompatibleAdaptiveStateStoreError {
                XCTAssertEqual(error, .invalidRecord)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))
    }

    func testForgedPersistedCompatibleEvidenceCannotUnlockAfterRestart() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let connectionID = ProviderConnectionID("provider.unauthenticated-state")
        let scopeID = "scope.unauthenticated-state"
        let now = Date(timeIntervalSince1970: 25_000)
        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let owner = try await store.recordTaskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: "durable-owner",
            lane: .chat,
            modelID: "durable-model",
            updatedAt: now
        )
        let compatible = makeProbeRecord(
            fingerprint: try makeFingerprint("persisted-compatible-model"),
            testedAt: now,
            expiresAt: now.addingTimeInterval(100),
            outcome: .compatible(Self.completeEvidence)
        )
        let invalidFingerprintSource = makeProbeRecord(
            fingerprint: try makeFingerprint("invalid-fingerprint-source"),
            testedAt: now,
            expiresAt: now.addingTimeInterval(100),
            outcome: .failed(.missingFunctionCall)
        )
        var invalidFingerprintObject = try jsonObject(for: invalidFingerprintSource)
        invalidFingerprintObject["fingerprint"] = ["value": "not-a-valid-digest"]

        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: location.file))
                as? [String: Any]
        )
        document["probeRecords"] = [
            try jsonObject(for: compatible),
            invalidFingerprintObject,
        ]
        try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: location.file, options: .atomic)

        let reopened = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let recoveredOwner = try await reopened.taskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: owner.threadID
        )
        let compatibleLookup = try await reopened.probeRecord(
            for: compatible.fingerprint,
            at: now
        )
        let invalidLookup = try await reopened.probeRecord(
            for: invalidFingerprintSource.fingerprint,
            at: now
        )
        XCTAssertEqual(recoveredOwner, owner)
        XCTAssertNil(compatibleLookup)
        XCTAssertNil(invalidLookup)
    }

    func testProbeEvictionIsDeterministicWhenCapacityIsReached() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let now = Date(timeIntervalSince1970: 30_000)
        let store = OpenAICompatibleAdaptiveStateStore(
            fileURL: location.file,
            limits: .init(maximumProbeRecords: 2)
        )
        let tieBreakFingerprints = try ["a", "b", "c"]
            .map(makeFingerprint)
            .sorted { $0.value < $1.value }
        let firstByTieBreak = makeProbeRecord(
            fingerprint: tieBreakFingerprints[0],
            testedAt: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(500),
            outcome: .failed(.missingFunctionCall)
        )
        let secondByTieBreak = makeProbeRecord(
            fingerprint: tieBreakFingerprints[1],
            testedAt: firstByTieBreak.testedAt,
            expiresAt: firstByTieBreak.expiresAt,
            outcome: .failed(.missingFunctionCall)
        )
        let newest = makeProbeRecord(
            fingerprint: tieBreakFingerprints[2],
            testedAt: now,
            expiresAt: now.addingTimeInterval(600),
            outcome: .failed(.functionOutputRejected)
        )

        // Deliberately write the tie in reverse lexical order. Eviction must
        // still use expiry, test time, then fingerprint rather than insertion.
        try await store.storeProbeRecord(secondByTieBreak, at: now)
        try await store.storeProbeRecord(firstByTieBreak, at: now)
        try await store.storeProbeRecord(newest, at: now)

        let evicted = try await store.probeRecord(for: firstByTieBreak.fingerprint, at: now)
        let retainedTie = try await store.probeRecord(
            for: secondByTieBreak.fingerprint,
            at: now
        )
        let retainedNewest = try await store.probeRecord(for: newest.fingerprint, at: now)
        XCTAssertNil(evicted)
        XCTAssertEqual(retainedTie, secondByTieBreak)
        XCTAssertEqual(retainedNewest, newest)
    }

    func testOversizedStateFileIsRejectedBeforeDecoding() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        try FileManager.default.createDirectory(
            at: location.file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x20, count: 1_025).write(to: location.file)
        let store = OpenAICompatibleAdaptiveStateStore(
            fileURL: location.file,
            limits: .init(maximumStateFileBytes: 1_024)
        )

        do {
            _ = try await store.taskOwnership(
                connectionID: ProviderConnectionID("provider.oversized"),
                conversationScopeID: "scope.oversized",
                threadID: "thread.oversized"
            )
            XCTFail("Oversized state must be rejected before JSON decoding")
        } catch let error as OpenAICompatibleAdaptiveStateStoreError {
            XCTAssertEqual(error, .stateLimitExceeded)
        }
    }

    func testCorruptProbeCacheIsDiscardedWithoutLosingValidTaskOwnership() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let connectionID = ProviderConnectionID("provider.corrupt-probes")
        let scopeID = "scope.corrupt-probes"
        let now = Date(timeIntervalSince1970: 40_000)
        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let owner = try await store.recordTaskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: "durable-thread",
            lane: .agent,
            modelID: "durable-model",
            updatedAt: now
        )
        let validProbe = makeProbeRecord(
            fingerprint: try makeFingerprint("corrupt-cache-valid-failure"),
            testedAt: now,
            expiresAt: now.addingTimeInterval(300),
            outcome: .failed(.missingFunctionCall)
        )
        try await store.storeProbeRecord(validProbe, at: now)

        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: location.file))
                as? [String: Any]
        )
        document["probeRecords"] = [[
            "fingerprint": ["value": "malformed"],
            "testedAt": "not-a-date",
            "outcome": ["compatible": [:]],
        ]]
        try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: location.file, options: .atomic)

        let reopened = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let recoveredOwner = try await reopened.taskOwnership(
            connectionID: connectionID,
            conversationScopeID: scopeID,
            threadID: owner.threadID
        )
        let recoveredProbe = try await reopened.probeRecord(
            for: validProbe.fingerprint,
            at: now
        )
        XCTAssertEqual(recoveredOwner, owner)
        XCTAssertNil(recoveredProbe)
    }

    func testInvalidHTTPStatusFailureCannotBeStoredOrReused() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let now = Date(timeIntervalSince1970: 45_000)
        let fingerprint = try makeFingerprint("invalid-http-status")
        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let invalid = makeProbeRecord(
            fingerprint: fingerprint,
            testedAt: now,
            expiresAt: now.addingTimeInterval(300),
            outcome: .failed(.httpFailure(statusCode: 700))
        )

        do {
            try await store.storeProbeRecord(invalid, at: now)
            XCTFail("An out-of-range HTTP status must not enter the adaptive cache")
        } catch let error as OpenAICompatibleAdaptiveStateStoreError {
            XCTAssertEqual(error, .invalidRecord)
        }

        // Also exercise the restart/read path: a hand-edited record must fail
        // closed instead of becoming reusable evidence.
        let valid = makeProbeRecord(
            fingerprint: fingerprint,
            testedAt: now,
            expiresAt: now.addingTimeInterval(300),
            outcome: .failed(.missingFunctionCall)
        )
        try await store.storeProbeRecord(valid, at: now)
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: location.file))
                as? [String: Any]
        )
        var recordObject = try jsonObject(for: invalid)
        recordObject["outcome"] = [
            "failed": [
                "httpFailure": ["statusCode": 700],
            ],
        ]
        document["probeRecords"] = [recordObject]
        try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: location.file, options: .atomic)

        let reopened = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        let recovered = try await reopened.probeRecord(for: fingerprint, at: now)
        XCTAssertNil(recovered)
    }

    func testPersistedStateUsesPrivateFilePermissionsWithoutChangingInjectedParent() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        let stateDirectory = location.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: stateDirectory.path
        )
        let store = OpenAICompatibleAdaptiveStateStore(fileURL: location.file)
        _ = try await store.recordTaskOwnership(
            connectionID: ProviderConnectionID("provider.private-state"),
            conversationScopeID: "scope.private-state",
            threadID: "thread.private-state",
            lane: .chat,
            modelID: "owned-model"
        )
        let probeConnection = try ProviderConnectionRecord(
            id: ProviderConnectionID("private-probe-provider-marker"),
            displayName: "Private probe display marker",
            baseURL: URL(string: "https://private-upstream-marker.example.test/v1")!,
            selectedModelID: "private-selected-model-marker",
            authMode: .none,
            transportCapabilities: [.streaming],
            conversationScopeID: "private-probe-scope-marker"
        )
        let probeModelID = "private-probe-model-marker"
        let now = Date(timeIntervalSince1970: 50_000)
        let probe = makeProbeRecord(
            fingerprint: OpenAICompatibleResponsesProbeFingerprint(
                connection: probeConnection,
                modelID: probeModelID
            ),
            testedAt: now,
            expiresAt: now.addingTimeInterval(300),
            outcome: .failed(.missingFunctionCall)
        )
        try await store.storeProbeRecord(probe, at: now)

        XCTAssertEqual(permissions(at: stateDirectory), 0o755)
        XCTAssertEqual(permissions(at: location.file), 0o600)
        let persisted = try String(contentsOf: location.file, encoding: .utf8)
        let selectedModelID = try XCTUnwrap(probeConnection.selectedModelID)
        for forbiddenValue in [
            probeConnection.displayName,
            probeConnection.baseURL.absoluteString,
            "private-upstream-marker.example.test",
            selectedModelID,
            probeModelID,
            probeConnection.id.rawValue,
            probeConnection.conversationScopeID,
        ] {
            XCTAssertFalse(
                persisted.contains(forbiddenValue),
                "Probe cache leaked a private probe input: \(forbiddenValue)"
            )
        }

        // An existing permissive item can come from an older preview or a
        // copied backup. Every successful rewrite must repair its permissions.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: stateDirectory.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: location.file.path
        )
        _ = try await store.recordTaskOwnership(
            connectionID: ProviderConnectionID("provider.private-state"),
            conversationScopeID: "scope.private-state",
            threadID: "second-private-thread",
            lane: .agent,
            modelID: "owned-model"
        )
        XCTAssertEqual(permissions(at: stateDirectory), 0o755)
        XCTAssertEqual(permissions(at: location.file), 0o600)
    }

    func testDefaultStateStoreProtectsOwnedParentDirectory() async throws {
        let location = temporaryLocation()
        defer { try? FileManager.default.removeItem(at: location.root) }

        // Feed the production/default ownership path a fixture Application
        // Support root so the test does not touch the user's real Onyx data.
        let fileManager = FixtureApplicationSupportFileManager(root: location.root)
        let store = OpenAICompatibleAdaptiveStateStore(
            fileURL: nil,
            fileManager: fileManager
        )
        let expectedFile = location.root
            .appendingPathComponent("Onyx", isDirectory: true)
            .appendingPathComponent(
                "openai-compatible-adaptive-state.json",
                isDirectory: false
            )
        let actualFile = await store.fileURL
        XCTAssertEqual(actualFile.standardizedFileURL, expectedFile.standardizedFileURL)

        _ = try await store.recordTaskOwnership(
            connectionID: ProviderConnectionID("provider.default-permissions"),
            conversationScopeID: "scope.default-permissions",
            threadID: "thread.default-permissions",
            lane: .chat,
            modelID: "default-model"
        )

        let ownedDirectory = expectedFile.deletingLastPathComponent()
        XCTAssertEqual(permissions(at: ownedDirectory), 0o700)
        XCTAssertEqual(permissions(at: expectedFile), 0o600)
    }

    private func temporaryLocation() -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAICompatibleAdaptiveStateStoreTests-\(UUID().uuidString)")
        return (
            root,
            root.appendingPathComponent("private/adaptive-state.json", isDirectory: false)
        )
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static let completeEvidence = OpenAICompatibleResponsesProbeEvidence(
        usedServerSentEvents: true,
        receivedFunctionCall: true,
        submittedCorrelatedOutput: true,
        completedAfterFunctionOutput: true
    )
}

private final class FixtureApplicationSupportFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        if directory == .applicationSupportDirectory {
            return [root]
        }
        return super.urls(for: directory, in: domainMask)
    }
}

private func makeProbeRecord(
    fingerprint: OpenAICompatibleResponsesProbeFingerprint,
    testedAt: Date,
    expiresAt: Date,
    outcome: OpenAICompatibleResponsesProbeOutcome
) -> OpenAICompatibleResponsesProbeRecord {
    OpenAICompatibleResponsesProbeRecord(
        fingerprint: fingerprint,
        testedAt: testedAt,
        expiresAt: expiresAt,
        outcome: outcome
    )
}

private func makeFingerprint(
    _ modelID: String
) throws -> OpenAICompatibleResponsesProbeFingerprint {
    let connection = try ProviderConnectionRecord(
        id: ProviderConnectionID("adaptive-state-fingerprint-fixture"),
        displayName: "Adaptive state fingerprint fixture",
        baseURL: URL(string: "https://fingerprint.example.test/v1")!,
        selectedModelID: modelID,
        authMode: .none,
        transportCapabilities: [.streaming],
        conversationScopeID: "adaptive-state-fingerprint-scope"
    )
    return OpenAICompatibleResponsesProbeFingerprint(
        connection: connection,
        modelID: modelID
    )
}

private func decodeFingerprint(
    _ value: String
) throws -> OpenAICompatibleResponsesProbeFingerprint {
    try JSONDecoder().decode(
        OpenAICompatibleResponsesProbeFingerprint.self,
        from: JSONSerialization.data(withJSONObject: ["value": value])
    )
}

private func jsonObject(
    for record: OpenAICompatibleResponsesProbeRecord
) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
    )
}
