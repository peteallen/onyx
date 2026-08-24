import Foundation

/// The bounded work plan for applying a coalesced stream of transcript
/// deltas.  A flush can contain many item updates while the conversation may
/// already contain tens of thousands of rows; resolve every existing item
/// from one ID index instead of repeatedly calling `firstIndex(where:)`.
///
/// This stays provider-neutral and intentionally contains only row indexes and
/// text.  The app model remains responsible for publishing the resulting
/// snapshot and for creating rows that did not exist when the deltas arrived.
struct TranscriptDeltaFlushPlan: Equatable, Sendable {
    struct Delta: Equatable, Sendable {
        let itemID: String
        let text: String
    }

    struct ExistingUpdate: Equatable, Sendable {
        let index: Int
        let text: String
    }

    struct AppendedUpdate: Equatable, Sendable {
        let itemID: String
        let text: String
    }

    let existingUpdates: [ExistingUpdate]
    let appendedUpdates: [AppendedUpdate]
    /// Number of timeline rows inspected while constructing the ID index.
    /// This is useful both as a performance contract and as a regression-test
    /// guard: it must stay independent of the number of streamed deltas.
    let inspectedItemCount: Int

    static func make(
        items: [TimelineItem],
        deltas: [Delta]
    ) -> Self {
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            // Timeline IDs are expected to be unique. Preserve the existing
            // first-match behavior if a malformed provider payload repeats an
            // ID instead of allowing a later duplicate to redirect a delta.
            if indexByID[item.id] == nil {
                indexByID[item.id] = index
            }
        }

        var existingUpdates: [ExistingUpdate] = []
        var appendedUpdates: [AppendedUpdate] = []
        existingUpdates.reserveCapacity(deltas.count)
        appendedUpdates.reserveCapacity(deltas.count)

        for delta in deltas where !delta.text.isEmpty {
            if let index = indexByID[delta.itemID] {
                existingUpdates.append(
                    ExistingUpdate(index: index, text: delta.text)
                )
            } else {
                appendedUpdates.append(
                    AppendedUpdate(itemID: delta.itemID, text: delta.text)
                )
            }
        }

        return Self(
            existingUpdates: existingUpdates,
            appendedUpdates: appendedUpdates,
            inspectedItemCount: items.count
        )
    }
}
