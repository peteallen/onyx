import Foundation
import XCTest
@testable import Onyx

@MainActor
final class ComposerDraftPersistenceWriterTests: XCTestCase {
    func testModelStagesOneBackgroundMutationInsteadOfRetainingItsLargeDraftCache() throws {
        let suiteName = "ComposerDraftPersistenceWriterTests.model-delta.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "Onyx.composerDrafts"
        let existingDraftCount = 20_000
        var existingDrafts = Dictionary(uniqueKeysWithValues: (0..<existingDraftCount).map {
            ("task-\($0)", "Draft \($0)")
        })
        existingDrafts["onyx:welcome"] = "Old welcome draft"
        defaults.set(existingDrafts, forKey: key)
        let writer = OnyxComposerDraftPersistenceWriter(defaults: defaults)
        let model = OnyxAppModel(
            runtime: nil,
            defaults: defaults,
            composerDraftPersistence: writer
        )

        model.composerText = "Current welcome draft"
        model.stageWindowStateForReplacement()

        // Reading diagnostics is also the deterministic queue fence for the
        // background staging call above.
        XCTAssertEqual(
            writer.diagnostics(),
            .init(
                fullSnapshotSubmissionCount: 0,
                mutationSubmissionCount: 1,
                largestMutationBatchSize: 1
            )
        )
        let persisted = try XCTUnwrap(defaults.dictionary(forKey: key) as? [String: String])
        XCTAssertEqual(persisted.count, existingDraftCount + 1)
        XCTAssertEqual(persisted["onyx:welcome"], "Current welcome draft")
        XCTAssertEqual(persisted["task-19999"], "Draft 19999")
    }

    func testDeltaWritePreservesUntouchedDraftsAndDoesNotSubmitFullSnapshot() throws {
        let suiteName = "ComposerDraftPersistenceWriterTests.delta.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "drafts"
        let existingDraftCount = 20_000
        let existingDrafts = Dictionary(uniqueKeysWithValues: (0..<existingDraftCount).map {
            ("task-\($0)", "Draft \($0)")
        })
        defaults.set(existingDrafts, forKey: key)
        let writer = OnyxComposerDraftPersistenceWriter(defaults: defaults)

        // This argument intentionally resembles the model's large live cache.
        // The production overload ignores it and hands only one mutation to
        // the persistence queue.
        writer.persistChanges(
            [.set(draftID: "task-42", text: "Updated")],
            currentDrafts: existingDrafts.merging(["task-42": "Updated"]) { _, latest in latest },
            forKey: key,
            revision: 1,
            mode: .synchronous
        )

        let persisted = try XCTUnwrap(defaults.dictionary(forKey: key) as? [String: String])
        XCTAssertEqual(persisted.count, existingDraftCount)
        XCTAssertEqual(persisted["task-42"], "Updated")
        XCTAssertEqual(persisted["task-19999"], "Draft 19999")
        XCTAssertEqual(
            writer.diagnostics(),
            .init(
                fullSnapshotSubmissionCount: 0,
                mutationSubmissionCount: 1,
                largestMutationBatchSize: 1
            )
        )
    }

    func testQueuedDeltaWritesRemainLastWriteWinsThroughSynchronousTeardownFence() throws {
        let suiteName = "ComposerDraftPersistenceWriterTests.order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "drafts"
        defaults.set(["untouched": "Keep me"], forKey: key)
        let writer = OnyxComposerDraftPersistenceWriter(defaults: defaults)

        writer.persistChanges(
            [.set(draftID: "active", text: "First")],
            currentDrafts: [:],
            forKey: key,
            revision: 1,
            mode: .background
        )
        writer.persistChanges(
            [.set(draftID: "active", text: "Final")],
            currentDrafts: [:],
            forKey: key,
            revision: 2,
            mode: .background
        )
        writer.persistChanges(
            [.remove(draftID: "obsolete")],
            currentDrafts: [:],
            forKey: key,
            revision: 3,
            mode: .synchronous
        )

        let persisted = try XCTUnwrap(defaults.dictionary(forKey: key) as? [String: String])
        XCTAssertEqual(persisted["active"], "Final")
        XCTAssertEqual(persisted["untouched"], "Keep me")

        writer.persistChanges(
            [.set(draftID: "active", text: "Stale")],
            currentDrafts: [:],
            forKey: key,
            revision: 2,
            mode: .synchronous
        )
        XCTAssertEqual(
            (defaults.dictionary(forKey: key) as? [String: String])?["active"],
            "Final"
        )
    }
}
