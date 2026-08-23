import Foundation

enum OnyxComposerDraftPersistenceMode: Sendable {
    case background
    case synchronous
}

/// A bounded composer-draft update. Passing one of these across the persistence
/// boundary avoids retaining the model's complete Dictionary storage while a
/// background write is pending. Retaining that storage would force the next
/// main-actor edit to copy every saved draft before changing one entry.
enum OnyxComposerDraftMutation: Equatable, Sendable {
    case set(draftID: String, text: String)
    case remove(draftID: String)

    static func replacingDraft(_ text: String, for draftID: String) -> Self {
        text.isEmpty ? .remove(draftID: draftID) : .set(draftID: draftID, text: text)
    }

    fileprivate func apply(to drafts: inout [String: String]) {
        switch self {
        case let .set(draftID, text):
            if text.isEmpty {
                drafts.removeValue(forKey: draftID)
            } else {
                drafts[draftID] = text
            }
        case let .remove(draftID):
            drafts.removeValue(forKey: draftID)
        }
    }
}

/// Keeps property-list serialization and UserDefaults I/O off the main actor
/// during ordinary composer activity. Revisions make rapid navigation and
/// repeated New Task clicks last-write-wins even when older writes are still
/// waiting on the serial persistence queue.
protocol OnyxComposerDraftPersisting: Sendable {
    func persist(
        _ drafts: [String: String],
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    )

    /// Persists only the entries that changed. `currentDrafts` exists as a
    /// compatibility snapshot for simple injected persistence implementations;
    /// the production writer deliberately does not retain or inspect it.
    func persistChanges(
        _ mutations: [OnyxComposerDraftMutation],
        currentDrafts: [String: String],
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    )

    func remove(
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    )
}

extension OnyxComposerDraftPersisting {
    /// Existing lightweight test doubles can continue recording complete
    /// snapshots. Production dispatch reaches the writer's delta override.
    func persistChanges(
        _ mutations: [OnyxComposerDraftMutation],
        currentDrafts: [String: String],
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    ) {
        persist(currentDrafts, forKey: key, revision: revision, mode: mode)
    }
}

final class OnyxComposerDraftPersistenceWriter: OnyxComposerDraftPersisting, @unchecked Sendable {
    struct Diagnostics: Equatable, Sendable {
        let fullSnapshotSubmissionCount: Int
        let mutationSubmissionCount: Int
        let largestMutationBatchSize: Int
    }

    private let defaults: UserDefaults
    private let queue = DispatchQueue(
        label: "app.onyx.composer-draft-persistence",
        qos: .utility
    )
    /// Accessed only on `queue`.
    private var appliedRevisionByKey: [String: UInt64] = [:]
    /// Queue-owned working sets let each delta update one entry without asking
    /// the main actor for another whole snapshot. The first mutation for a key
    /// is seeded lazily from UserDefaults on this queue.
    private var cachedDraftsByKey: [String: [String: String]] = [:]
    private var fullSnapshotSubmissionCount = 0
    private var mutationSubmissionCount = 0
    private var largestMutationBatchSize = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func persist(
        _ drafts: [String: String],
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    ) {
        submit(revision: revision, key: key, mode: mode) { [self] in
            // Capture the writer (which is explicitly unchecked-Sendable),
            // rather than the raw UserDefaults reference, so Swift 6 does
            // not treat the closure as smuggling a non-Sendable value across
            // the persistence queue boundary.
            self.fullSnapshotSubmissionCount += 1
            self.cachedDraftsByKey[key] = drafts
            self.defaults.set(drafts, forKey: key)
        }
    }

    func persistChanges(
        _ mutations: [OnyxComposerDraftMutation],
        currentDrafts _: [String: String],
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    ) {
        // Only this bounded payload escapes the caller. In particular, do not
        // mention `currentDrafts` in the closure: keeping that Dictionary alive
        // until the utility queue runs would reintroduce the main-actor COW.
        submit(revision: revision, key: key, mode: mode) { [self, mutations] in
            self.mutationSubmissionCount += 1
            self.largestMutationBatchSize = max(self.largestMutationBatchSize, mutations.count)
            if self.cachedDraftsByKey[key] == nil {
                self.cachedDraftsByKey[key] = self.defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            }
            for mutation in mutations {
                mutation.apply(to: &self.cachedDraftsByKey[key, default: [:]])
            }
            self.defaults.set(self.cachedDraftsByKey[key] ?? [:], forKey: key)
        }
    }

    func remove(
        forKey key: String,
        revision: UInt64,
        mode: OnyxComposerDraftPersistenceMode
    ) {
        submit(revision: revision, key: key, mode: mode) { [self] in
            self.cachedDraftsByKey[key] = [:]
            self.defaults.removeObject(forKey: key)
        }
    }

    func diagnostics() -> Diagnostics {
        queue.sync {
            Diagnostics(
                fullSnapshotSubmissionCount: fullSnapshotSubmissionCount,
                mutationSubmissionCount: mutationSubmissionCount,
                largestMutationBatchSize: largestMutationBatchSize
            )
        }
    }

    private func submit(
        revision: UInt64,
        key: String,
        mode: OnyxComposerDraftPersistenceMode,
        operation: @escaping @Sendable () -> Void
    ) {
        let work: @Sendable () -> Void = { [self] in
            guard revision > appliedRevisionByKey[key, default: 0] else { return }
            appliedRevisionByKey[key] = revision
            operation()
        }
        switch mode {
        case .background:
            queue.async(execute: work)
        case .synchronous:
            queue.sync(execute: work)
        }
    }
}
